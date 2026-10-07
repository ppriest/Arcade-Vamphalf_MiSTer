-- Log every write to the QS1000 wavetable registers (8052 data space 0x200-0x211, qs1000.cpp wave_w)
-- with its machine time, for scripts/qs1000_model.py and the voice-engine bench.
--
--   QW_OUT     output file: "W <time in 750 kHz ticks> <offset> <data>" per write
--   QW_FRAMES  frames to run, then exit
--   QW_COIN    frame to insert a coin and press Start (0 = attract only); repeated every 300 frames
--   QW_FIRE    frame from which P1 button 1 is tapped, 4 frames down and 4 up (0 = never)
--   QW_LATCH   the sound latch's address in the main CPU's I/O space (hex; misncrft 100, wyvernwg 1500):
--              each write is logged as "L <tick> <data>"
--
-- The time is machine time in units of the engine's stream rate (24 MHz / 32), so a write is applied
-- before the sample of that tick, as MAME's wave_w updates the stream to the write's time first.

local OUT    = os.getenv("QW_OUT")
local FRAMES = tonumber(os.getenv("QW_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("QW_COIN") or "0")
local FIRE   = tonumber(os.getenv("QW_FIRE") or "0")
local LATCH  = os.getenv("QW_LATCH")

local mach = manager.machine
local cpu  = mach.devices[":qs1000:cpu"]
local data = cpu.spaces["xdata"]
local f = io.open(OUT, "w")
f:write("# QS1000 wave register writes: W <750 kHz tick> <offset> <data>\n")

local function now_ticks()
    local t = mach.time
    -- attotime: seconds + attoseconds; the tick count at 750 kHz
    return t.seconds * 750000 + math.floor(t.attoseconds / 1333333333333)
end

local tap = data:install_write_tap(0x200, 0x211, "qw", function(offset, d, mask)
    if mach:side_effects_disabled() then return d end
    f:write(string.format("W %d %x %x\n", now_ticks(), offset - 0x200, d & 0xff))
    return d
end)

KEEP_LTAP = nil   -- a global: an unreferenced tap is garbage-collected, and removed with it
if LATCH and LATCH ~= "" then
    local a = tonumber(LATCH, 16)
    KEEP_LTAP = mach.devices[":maincpu"].spaces["io"]:install_write_tap(a, a + 3, "ql", function(offset, d, mask)
        if not mach:side_effects_disabled() then
            local v = d
            if mask & 0xff == 0 then v = d >> 8 end
            if mask & 0xffff == 0 then v = d >> 16 end
            if mask & 0xffffff == 0 then v = d >> 24 end
            f:write(string.format("L %d %x\n", now_ticks(), v & 0xff))
        end
        return d
    end)
end

local ioport = mach.ioport
local function press(field, on)
    for _, p in pairs(ioport.ports) do
        local fld = p.fields[field]
        if fld then fld:set_value(on and 1 or 0) end
    end
end

local frame = 0
emu.register_frame_done(function()
    frame = frame + 1
    if COIN > 0 and frame >= COIN then
        local k = (frame - COIN) % 300
        press("Coin 1", k < 6)
        press("1 Player Start", k >= 30 and k < 36)
    end
    if FIRE > 0 then press("P1 Button 1", frame >= FIRE and (frame - FIRE) % 8 < 4) end   -- tapped: a held button does not auto-fire
    if frame >= FRAMES then
        f:write(string.format("# end %d frames, tick %d\n", frame, now_ticks()))
        f:close()
        tap:remove()
        mach:exit()
    end
end)
