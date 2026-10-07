-- Per-instruction and per-bus-access trace of the Hyperstone main CPU, from reset.
-- Driven by scripts/mame_e1_trace.py (MAME must run with -debug -nodrc: the debugger's
-- instruction hook and the interpreter are what this relies on; see docs/E1_TRACE_FORMAT.md).
--
--   CORE_OUT      output directory (exists)
--   CORE_TAG      file prefix (set name)
--   CORE_TRACE_N  stop after about this many instructions (Python trims to exactly N)
--   CORE_FRAMES   backstop: stop at this frame regardless
--   CORE_CPU      device tag
--
-- The debugger's `trace` writes one line per instruction BEFORE it executes. Its action
-- (`tracelog`) runs first and prints the register state; the tracer then appends
-- "PC: disassembly". Bus accesses made by the CPU while executing are written into the
-- same file by taps (debugger:command "tracelog"), so they land between the instruction
-- line that caused them and the next one.
--
-- Taps also fire for the debugger's own reads (the disassembler); those run with side
-- effects disabled and are skipped.

local OUT   = os.getenv("CORE_OUT") or "."
local TAG   = os.getenv("CORE_TAG") or "trace"
local N     = tonumber(os.getenv("CORE_TRACE_N") or "200000")
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "100000")
local mach  = manager.machine
local dbg   = mach.debugger
local cpu   = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog  = cpu.spaces["program"]
local ios   = cpu.spaces["io"]

local path = string.format("%s/%s_e1.raw", OUT, TAG)

-- Register order of the state record: g0..g31 by the debugger's names, then S0..S63.
local names = { "PC", "SR", "FER" }
for i = 3, 17 do names[#names + 1] = "G" .. i end
for _, n in ipairs({ "SP", "UB", "BCR", "TPR", "TCR", "TR", "WCR", "ISR", "FCR", "MCR" }) do
    names[#names + 1] = n
end
for i = 28, 31 do names[#names + 1] = "G" .. i end
assert(#names == 32)
for i = 0, 63 do names[#names + 1] = "S" .. i end

local fmt, args = {}, {}
for _, n in ipairs(names) do fmt[#fmt + 1] = "%08X"; args[#args + 1] = n:lower() end
-- three halfwords at PC: the instruction is 1 to 3 halfwords long.
local act = string.format('tracelog "I %%04X %%04X %%04X %s ",w@pc,w@(pc+2),w@(pc+4),%s',
                          table.concat(fmt, " "), table.concat(args, ","))
-- CORE_LEAN=1: PC only and no bus taps, to count instructions per frame over long runs.
local LEAN = os.getenv("CORE_LEAN") == "1"
if LEAN then act = 'tracelog "I %08X ",pc' end
dbg:command(string.format("trace %s,%s,noloop,{%s}", path, "maincpu", act))
dbg:command("go")

local ninstr, nbus, done = 0, 0, false
local rd, rdpos = nil, 0

local function finish()
    if done then return end
    done = true
    local f = io.open(OUT .. "/" .. TAG .. "_e1.done", "w")
    f:write(string.format("instr_seen %d bus_logged %d frame %d\n", ninstr, nbus,
                          mach.screens[":screen"]:frame_number()))
    f:close()
    print("E1TRACE_OK")
    mach:exit()
end

local err

-- kind: 0 read, 1 write; space: 0 program, 1 io
local function mk(kind, space)
    return function(offset, data, mask)
        if done or mach:side_effects_disabled() then return data end
        local ok, e = pcall(function()
            nbus = nbus + 1
            -- Instruction count: the PC-matching read over-counts (extension words are
            -- read at PC too), so count "I " lines in the trace file itself, every 4096
            -- accesses. The converter trims to exactly N.
            if nbus % 4096 == 0 then
                rd = rd or io.open(path, "rb")
                local chunk = rd:read(1 << 22)
                while chunk do
                    for _ in chunk:gmatch("\nI ") do ninstr = ninstr + 1 end
                    if rdpos == 0 and chunk:sub(1, 2) == "I " then ninstr = ninstr + 1 end
                    rdpos = rdpos + #chunk
                    chunk = rd:read(1 << 22)
                end
                if ninstr > N then finish() end
            end
            dbg:command(string.format('tracelog "B %d %d %%08X %%08X %%08X\n",%x,%x,%x', space, kind, offset, data & 0xffffffff, mask & 0xffffffff))
        end)
        if not ok and not err then err = tostring(e); print("E1TRACE_ERR " .. err) end
        return data
    end
end

core_subs = {}
if not LEAN then core_subs = {
    prog:install_read_tap(0, 0xffffffff, "e1r", mk(0, 0)),
    prog:install_write_tap(0, 0xffffffff, "e1w", mk(1, 0)),
    ios:install_read_tap(0, ios.address_mask, "e1ior", mk(0, 1)),
    ios:install_write_tap(0, ios.address_mask, "e1iow", mk(1, 1)),
} end
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    local fr = mach.screens[":screen"]:frame_number()
    if not done then dbg:command(string.format('tracelog "# frame %%d\n",%d', fr)) end
    if fr >= FRAMES then finish() end
end)
