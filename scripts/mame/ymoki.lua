-- Log the main CPU's writes to the YM2151 and the M6295 (sound_ym_oki boards) with their machine time, for
-- sim/ymoki_tb. Driven by scripts/mame_ymoki.py:
--
--   YO_OUT     output file: "Y <clk> <a0> <data>" (YM2151 address or data port), "O <clk> <data>" (M6295),
--              <clk> the machine time in 56 MHz clocks
--   YO_FRAMES  frames to run, then exit
--   YO_YM      the YM2151's address port in the I/O space (hex), the data port is the next
--   YO_OKI     the M6295's port (hex)
--   YO_COIN    frame to insert a coin and press Start, every 300 frames after (0 = attract only)
--
-- The taps are globals: an unreferenced tap is garbage-collected, and removed with it.

local OUT    = os.getenv("YO_OUT")
local FRAMES = tonumber(os.getenv("YO_FRAMES") or "1800")
local YM     = tonumber(os.getenv("YO_YM") or "50", 16)
local OKI    = tonumber(os.getenv("YO_OKI") or "30", 16)
local COIN   = tonumber(os.getenv("YO_COIN") or "0")

local mach = manager.machine
local iosp = mach.devices[":maincpu"].spaces["io"]
local f = assert(io.open(OUT, "w"))
f:write("# YM2151 / M6295 writes: Y <56 MHz clock> <a0> <data>, O <56 MHz clock> <data>\n")

local function now_clk()
    local t = mach.time
    return t.seconds * 56000000 + math.floor(t.attoseconds / 17857142857)
end

local function byte(d, mask)
    if mask & 0xff ~= 0 then return d & 0xff end
    if mask & 0xff00 ~= 0 then return (d >> 8) & 0xff end
    if mask & 0xff0000 ~= 0 then return (d >> 16) & 0xff end
    return (d >> 24) & 0xff
end

YM_TAP = iosp:install_write_tap(YM, YM + 1, "yo_ym", function(offset, d, mask)
    if not mach:side_effects_disabled() then
        f:write(string.format("Y %d %d %02x\n", now_clk(), offset - YM, byte(d, mask)))
    end
    return d
end)
OKI_TAP = iosp:install_write_tap(OKI, OKI, "yo_oki", function(offset, d, mask)
    if not mach:side_effects_disabled() then
        f:write(string.format("O %d %02x\n", now_clk(), byte(d, mask)))
    end
    return d
end)

local function press(field, on)
    for _, p in pairs(mach.ioport.ports) do
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
    if frame >= FRAMES then
        f:write(string.format("# end %d frames, clock %d\n", frame, now_clk()))
        f:close()
        mach:exit()
    end
end)
