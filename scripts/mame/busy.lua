-- How much of each frame the main CPU is busy. Per frame (from the frame notifier, vblank begin, where the
-- vblank IRQ is raised): the time of the first read of the idle loop's poll address from one of its PCs,
-- and the start of the last run of such reads (reads less than BUSY_GAP apart) that lasts to the next
-- frame, both as fractions of the frame, and the number of reads. A main loop that waits for the vblank
-- flag in the idle loop leaves it on the first read, so the second figure is the one that shows the work.
-- The time is emu.time() inside the tap, which is the executing CPU's local time.
--
--   BUSY_OUT     output file: "<frame> <first> <last run start | overrun> <reads>" per frame
--   BUSY_ADDR    the idle loop's poll address (hex), the address the driver's speedup handler reads
--   BUSY_PCS     comma-separated hex PCs of that read
--   BUSY_GAP     microseconds between reads that still counts as one run (default 20)
--   BUSY_FRAMES  frames to run, then exit
--   BUSY_COIN    frame to insert a coin and press Start, repeated every 300 frames (0 = never)
--   BUSY_FIRE    frame from which P1 button 1 is tapped, 4 frames down, 4 up (0 = never)

local OUT    = os.getenv("BUSY_OUT")
local ADDR   = tonumber(os.getenv("BUSY_ADDR"), 16)
local GAP    = tonumber(os.getenv("BUSY_GAP") or "20") * 1e-6
local FRAMES = tonumber(os.getenv("BUSY_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("BUSY_COIN") or "0")
local FIRE   = tonumber(os.getenv("BUSY_FIRE") or "0")
local PCS = {}
for n in string.gmatch(os.getenv("BUSY_PCS") or "", "%x+") do PCS[tonumber(n, 16)] = true end

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local f = assert(io.open(OUT, "w"))
f:write("# frame, first idle read, start of the last run of idle reads (fractions of the frame), reads\n")

local frame, t0 = 0, nil
local first, run_start, last, nreads = nil, nil, nil, 0
-- a global, or the tap is garbage-collected (LESSONS_LEARNED)
KEEP_BUSY_R = prog:install_read_tap(ADDR, ADDR + 3, "busy", function(offset, d, mask)
    if t0 and not mach:side_effects_disabled() and PCS[cpu.state["PC"].value] then
        local t = emu.time()
        if not first then first = t end
        if not last or t - last > GAP then run_start = t end
        last = t
        nreads = nreads + 1
    end
    return d
end)

local function press(field, on)
    for _, p in pairs(mach.ioport.ports) do
        local fld = p.fields[field]
        if fld then fld:set_value(on and 1 or 0) end
    end
end

local function frac(t, t_start, period)
    return string.format("%.4f", (t - t_start) / period)
end

KEEP_BUSY_F = emu.add_machine_frame_notifier(function()
    local t = emu.time()
    if t0 then
        local period = t - t0
        -- the last run must reach the frame's end; otherwise the CPU was busy when the frame ended. A run
        -- from before the frame began means only the interrupt handler ran (shorter than BUSY_GAP)
        local rs = (last and t - last <= GAP) and frac(math.max(run_start, t0), t0, period) or "overrun"
        f:write(string.format("%d %s %s %d\n", frame, first and frac(first, t0, period) or "none", rs, nreads))
    end
    t0 = t
    first, nreads = nil, 0
    if last and t - last > GAP then run_start, last = nil, nil end
    frame = frame + 1
    if COIN > 0 and frame >= COIN then
        local k = (frame - COIN) % 300
        press("Coin 1", k < 6)
        press("1 Player Start", k >= 30 and k < 36)
    end
    if FIRE > 0 and frame >= FIRE then press("P1 Button 1", (frame - FIRE) % 8 < 4) end
    if frame >= FRAMES then
        f:close()
        mach:exit()
    end
end)
