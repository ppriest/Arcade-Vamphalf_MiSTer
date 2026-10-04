-- Record MAME's emulated time at two points in a game's program, for a CPI
-- measurement against the RTL (Phase 0). All settings required:
--
--   CORE_OUT       output file
--   CORE_MARKADDR  address of the marking write, aligned to the bus width
--   CORE_MARKMASK  byte-lane mask of that write
--   CORE_MARKA/B   the n-th such write that starts and ends the interval
--   CORE_CPU, CORE_SPACE, CORE_BYTES   from regions.json
--
-- Marks are writes, not access numbers: a prefetching CPU's access count drifts
-- from MAME's, but "the n-th write to X with lanes M" is the same program event
-- on both sides. A byte write is best: one access on any bus. Put the marks in
-- game code, not a BIOS RAM test (LESSONS_LEARNED: a CPI measured on the RAM
-- test is a CPI of the RAM test).
--
-- Precision: machine.time inside a tap is the start of the scheduler timeslice,
-- so a mark can be early by up to the driver's maximum quantum.

local function need(k)
    local v = os.getenv(k)
    assert(v and v ~= "", k .. " not set")
    return v
end
local OUT  = need("CORE_OUT")
local ADDR = tonumber(need("CORE_MARKADDR"))
local MASK = tonumber(need("CORE_MARKMASK"))
local A    = tonumber(need("CORE_MARKA"))
local B    = tonumber(need("CORE_MARKB"))
local SPAN = tonumber(os.getenv("CORE_BYTES") or "4") - 1
local m    = manager.machine
local prog = m.devices[os.getenv("CORE_CPU") or ":maincpu"].spaces[os.getenv("CORE_SPACE") or "program"]

local n, f = 0, assert(io.open(OUT, "w"))
local function hit(offset, data, mask)
    if (offset & ~SPAN) ~= ADDR or mask ~= MASK then return data end
    n = n + 1
    if n == A or n == B then
        f:write(string.format("mark write=%d seconds=%.9f\n", n, m.time:as_double()))
        f:flush()
        if n == B then
            f:close()
            print("CORE_MARK_OK")
            m:exit()
        end
    end
    return data
end

-- Global: a chunk-local subscription is collected when the chunk returns.
_G.__core_mark = { prog:install_write_tap(ADDR, ADDR + SPAN, "mw", hit) }
