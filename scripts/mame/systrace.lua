-- The main CPU's view of the machine, frame by frame, as ground truth for the
-- RTL main board's trace. Driven by scripts/mame_sys_trace.py:
--
--   CORE_OUT, CORE_TAG, CORE_FRAMES     output dir, filename prefix, frames to log
--   CORE_CPU, CORE_SPACE, CORE_BYTES    from regions.json
--   CORE_ADDR_HI                        top of the address space, hex
--   CORE_IO                             "lo:hi,lo:hi" hex ranges whose READS are logged
--   CORE_VEC_LO/HI                      vector table: a read marks an interrupt taken
--   CORE_IPL_REG/SHIFT/MASK             CPU state field for the interrupt mask
--                                       column (68k: SR, 8, 7); "-" if unset
--
-- Logged: every write, reads in the I/O range, reads of the vector table, and
-- "# frame N". ROM and work-RAM reads are left out: they are the bulk of the
-- traffic and work-RAM reads return what was written. Compare the main program
-- and each interrupt level as separate streams: where an interrupt lands in the
-- main stream depends on each CPU's speed.

local OUT    = os.getenv("CORE_OUT") or "."
local TAG    = os.getenv("CORE_TAG") or "trace"
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "60")
local function hex(k, d) return tonumber(os.getenv(k) or d, 16) end
local AHI            = hex("CORE_ADDR_HI", "ffffff")
local IO = {}
for lo, hi in string.gmatch(os.getenv("CORE_IO") or "", "(%x+):(%x+)") do
    IO[#IO + 1] = { tonumber(lo, 16), tonumber(hi, 16) }
end
local VEC_LO, VEC_HI = hex("CORE_VEC_LO", "0"), hex("CORE_VEC_HI", "0")
local AFMT = "%0" .. #string.format("%X", AHI) .. "X"
local DFMT = "%0" .. (2 * tonumber(os.getenv("CORE_BYTES") or "4")) .. "X"
local LINE = "%d\t%s\t" .. AFMT .. "\t" .. DFMT .. "\t" .. DFMT .. "\t%s\n"

local mach = manager.machine
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]
local ipl_name = os.getenv("CORE_IPL_REG")
local ipl_reg  = ipl_name and ipl_name ~= "" and cpu.state[ipl_name] or nil
local IPL_SH   = tonumber(os.getenv("CORE_IPL_SHIFT") or "0")
local IPL_M    = tonumber(os.getenv("CORE_IPL_MASK") or "0")

local f = assert(io.open(string.format("%s/%s_sys.trace", OUT, TAG), "w"))
f:write(string.format("# main CPU: all writes, reads of %s (I/O), %X-%X (vectors)\n",
                      os.getenv("CORE_IO") or "", VEC_LO, VEC_HI))
f:write("# seq\trw\taddr\tmask\tdata\tipl\n")

local n, done, first_err = 0, false, nil

local function stop()
    if done then return end
    done = true
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:write(string.format("# %d accesses logged\n", n))
    f:close()
    print(string.format("SYSTRACE %d accesses to %s/%s_sys.trace", n, OUT, TAG))
    mach:exit()
end

local function log(rw, offset, data, mask)
    n = n + 1
    local ipl = ipl_reg and tostring((ipl_reg.value >> IPL_SH) & IPL_M) or "-"
    f:write(string.format(LINE, n, rw, offset & AHI, mask, data, ipl))
end

local function guard(rw)
    return function(offset, data, mask)
        if not done then
            local ok, err = pcall(log, rw, offset, data, mask)
            if not ok and not first_err then first_err = tostring(err) end
        end
        return data
    end
end

-- Global: see boottrace.lua.
core_subs = {}
core_subs[#core_subs + 1] = prog:install_write_tap(0, AHI, "core_sys_w", guard("w"))
for i, r in ipairs(IO) do
    core_subs[#core_subs + 1] = prog:install_read_tap(r[1], r[2], "core_sys_r" .. i, guard("r"))
end
if VEC_HI > VEC_LO then
    core_subs[#core_subs + 1] = prog:install_read_tap(VEC_LO, VEC_HI, "core_sys_vec", guard("r"))
end

local frame = 0
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    frame = frame + 1
    f:write(string.format("# frame %d\n", frame))
    if frame >= FRAMES then stop() end
end)
