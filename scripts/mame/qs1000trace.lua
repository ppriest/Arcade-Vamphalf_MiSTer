-- Per-instruction and per-access trace of the QS1000's 8052 (device :qs1000:cpu), from reset.
-- Driven by scripts/mame_qs1000_trace.py (MAME must run with -debug; the debugger's
-- instruction hook is what this relies on; see docs/QS1000_TRACE_FORMAT.md).
--
--   CORE_OUT      output directory (exists)
--   CORE_TAG      file prefix (set name)
--   CORE_TRACE_N  stop after about this many 8052 instructions (Python trims to exactly N)
--   CORE_FRAMES   backstop: stop at this frame regardless
--   CORE_LATCH    I/O-space offset of the main CPU's sound-latch write (misncrft 0x100,
--                 wivernwg 0x1500)
--
-- `visible_cpu` makes the 8052 the debugger's visible CPU, so `tracelog` from any tap writes into
-- the 8052's trace file at the position between the instruction that was running and the
-- next. The trace line of an instruction is printed BEFORE it executes; accesses it makes
-- follow it, up to the next instruction line.

local OUT    = os.getenv("CORE_OUT") or "."
local TAG    = os.getenv("CORE_TAG") or "trace"
local N      = tonumber(os.getenv("CORE_TRACE_N") or "500000")
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "100000")
local LATCH  = tonumber(os.getenv("CORE_LATCH") or "0x100")
local mach   = manager.machine
local dbg    = mach.debugger
local cpu    = mach.devices[":qs1000:cpu"]
local mcpu   = mach.devices[":maincpu"]
local path   = string.format("%s/%s_q.raw", OUT, TAG)

dbg.visible_cpu = cpu
-- pc a psw sp dptr r0-r7 b ie ip tcon tmod tl0 th0 tl1 th1 (state before the instruction)
local act = 'tracelog "I %04X %02X %02X %02X %04X %02X %02X %02X %02X %02X %02X %02X %02X ' ..
            '%02X %02X %02X %02X %02X %02X %02X %02X %02X ",pc,a,psw,sp,dptr,r0,r1,r2,r3,r4,r5,r6,r7,' ..
            'b,ie,ip,tcon,tmod,tl0,th0,tl1,th1'
dbg:command(string.format("trace %s,:qs1000:cpu,noloop,{%s}", path, act))
dbg:command("go")

local done, err = false, nil
local nbus, nlatch = 0, 0
local rd, ninstr, tail = nil, 0, ""

local function finish()
    if done then return end
    done = true
    local f = io.open(OUT .. "/" .. TAG .. "_q.done", "w")
    f:write(string.format("instr_seen %d bus_logged %d latch_writes %d frame %d\n", ninstr, nbus,
                          nlatch, mach.screens[":screen"]:frame_number()))
    f:close()
    print("QS1000TRACE_OK")
    mach:exit()
end

local function count_instr()
    rd = rd or io.open(path, "rb")
    local chunk = rd:read(1 << 22)
    while chunk do
        local s = tail .. chunk
        for _ in s:gmatch("\nI ") do ninstr = ninstr + 1 end
        tail = s:sub(-2)
        chunk = rd:read(1 << 22)
    end
end

-- The values are expression arguments: a bare `a` or `b` is the ACC or B symbol, so 0x is
-- required (0x0a would otherwise print as 0).
-- Values are debugger expressions: a bare `a` or `b` is the ACC or B symbol, so they are
-- printed with 0x (offset 0x0a would otherwise read as ACC and print 0).
-- kind R/W, space letter I (idata), S (sfr), X (xdata), P (program)
local function mk(sp, kind)
    return function(offset, data, mask)
        if done or mach:side_effects_disabled() then return data end
        local ok, e = pcall(function()
            nbus = nbus + 1
            dbg:command(string.format('tracelog "B %s %s %%04X %%02X\n",%#x,%#x', sp, kind, offset, data & 0xff))
        end)
        if not ok and not err then err = tostring(e); print("QS1000TRACE_ERR " .. err) end
        return data
    end
end

local subs = {}
for _, s in ipairs({ { "idata", "I" }, { "sfr", "S" }, { "xdata", "X" }, { "program", "P" } }) do
    local sp = cpu.spaces[s[1]]
    subs[#subs + 1] = sp:install_read_tap(0, sp.address_mask, "q" .. s[2] .. "r", mk(s[2], "R"))
    subs[#subs + 1] = sp:install_write_tap(0, sp.address_mask, "q" .. s[2] .. "w", mk(s[2], "W"))
end

-- the main CPU's write to the sound latch (asserts INT1 of the 8052)
local ios = mcpu.spaces["io"]
subs[#subs + 1] = ios:install_write_tap(0, ios.address_mask, "qlatch", function(offset, data, mask)
    if done or mach:side_effects_disabled() then return data end
    if offset == LATCH then
        nlatch = nlatch + 1
        dbg:command(string.format('tracelog "L %%02X %%08X\n",%#x,%#x', data & 0xff, offset))
    end
    return data
end)

subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    local fr = mach.screens[":screen"]:frame_number()
    if done then return end
    dbg:command(string.format('tracelog "# frame %%d\n",%d', fr))
    count_instr()
    if ninstr > N or fr >= FRAMES then finish() end
end)
core_subs = subs
