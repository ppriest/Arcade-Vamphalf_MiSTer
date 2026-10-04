-- Log the first N main-CPU bus accesses from reset, as ground truth for the
-- RTL's boot trace (scripts/compare_boot_trace.py). Driven by
-- scripts/mame_boot_trace.py:
--
--   CORE_OUT      directory to write into (must exist)
--   CORE_TAG      output filename prefix (normally the set name)
--   CORE_TRACE_N  accesses to log before stopping
--   CORE_CPU, CORE_SPACE, CORE_BYTES   from regions.json
--   CORE_ADDR_HI  top of the address space, hex (regions.json "trace")
--
-- A read/write tap, not the debugger's `trace`: `trace` logs instruction starts,
-- the RTL sees every bus access (operands, stack, tables). A CPU that prefetches
-- reads ROM words MAME never asks for, so ROM fetches compare as a superset.

local OUT  = os.getenv("CORE_OUT") or "."
local TAG  = os.getenv("CORE_TAG") or "trace"
local N    = tonumber(os.getenv("CORE_TRACE_N") or "512")
local AHI  = tonumber(os.getenv("CORE_ADDR_HI") or "ffffff", 16)
local AFMT = "%0" .. #string.format("%X", AHI) .. "X"
local DFMT = "%0" .. (2 * tonumber(os.getenv("CORE_BYTES") or "4")) .. "X"
local LINE = "%d\t%s\t" .. AFMT .. "\t" .. DFMT .. "\t" .. DFMT .. "\n"

local mach = manager.machine
local prog = mach.devices[os.getenv("CORE_CPU") or ":maincpu"].spaces[os.getenv("CORE_SPACE") or "program"]

local f = assert(io.open(string.format("%s/%s_boot.trace", OUT, TAG), "w"))
f:write("# main-CPU bus accesses from reset, in order.\n")
f:write("# seq\trw\taddr\tmask\tdata\n")

local n, done = 0, false
local hits, logged, first_err = 0, 0, nil

local function stop()
    if done then return end
    done = true
    f:write(string.format("# %d accesses seen, %d logged\n", hits, logged))
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:close()
    print(string.format("TRACE  %d accesses logged to %s/%s_boot.trace", logged, OUT, TAG))
    mach:exit()
end

-- MAME swallows errors inside a tap. The hits count beside the logged count
-- makes a failing callback visible instead of an empty log.
local function record(rw)
    return function(offset, data, mask)
        hits = hits + 1
        if not done then
            local ok, err = pcall(function()
                n = n + 1
                f:write(string.format(LINE, n, rw, offset & AHI, mask, data))
                logged = logged + 1
            end)
            if not ok and not first_err then first_err = tostring(err) end
            if n >= N then stop() end
        end
        return data
    end
end

-- Global: an autoboot chunk's locals are collected once it returns and a
-- collected tap stops firing silently.
_G.__core_trace_taps = {
    prog:install_read_tap(0, AHI, "rd", record("r")),
    prog:install_write_tap(0, AHI, "wr", record("w")),
}

-- Backstop: a boot with fewer than N accesses still writes its file.
_G.__core_trace_notifier = emu.add_machine_frame_notifier(function()
    if mach.screens[":screen"]:frame_number() >= 600 then stop() end
end)
