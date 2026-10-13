-- Spotty's sound commands and M6295 writes per frame (limenko.cpp spotty_state), for sim/lm_tb's +v=1 log.
-- The M6295 writes are derived from the AT89C4051's P1 and P3 writes as the board does (audiocpu_p3_w): a write
-- after a status or latch read with no P1 write between is logged as ??.
--
--   CORE_OUT     output directory (exists)
--   CORE_FRAMES  frames to run
--   CORE_COIN    frame to press Coin 1 at (0: none), held CORE_HOLD frames (default 6)

local OUT    = os.getenv("CORE_OUT") or "."
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "600")
local COIN   = tonumber(os.getenv("CORE_COIN") or "0")
local HOLD   = tonumber(os.getenv("CORE_HOLD") or "6")
local mach   = manager.machine
local f      = io.open(OUT .. "/oki.txt", "w")
local n      = 0
local bp1, bp3 = 0xff, 0xff

local subs = {}
local ios = mach.devices[":maincpu"].spaces["io"]
subs[#subs + 1] = ios:install_write_tap(0x1400, 0x1403, "lo_latch", function(offset, data, mask)
    if not mach:side_effects_disabled() and (mask & 0x00ff0000) ~= 0 then
        f:write(string.format("frame %d: sound latch %02x\n", n, (data >> 16) & 0xff))
    end
    return data
end)
local sfr = mach.devices[":audiocpu"].spaces["sfr"]
subs[#subs + 1] = sfr:install_write_tap(0x90, 0x90, "lo_p1", function(offset, data, mask)
    if not mach:side_effects_disabled() then bp1 = data & 0xff end
    return data
end)
subs[#subs + 1] = sfr:install_write_tap(0xb0, 0xb0, "lo_p3", function(offset, data, mask)
    if mach:side_effects_disabled() then return data end
    local d = data & 0xff
    local low7 = (d & 0x80) == 0
    if (bp3 & 1) ~= 0 and (d & 1) == 0 and low7 then bp1 = -1 end
    if (bp3 & 2) ~= 0 and (d & 2) == 0 and low7 then
        f:write(bp1 < 0 and string.format("frame %d: M6295 write ??\n", n)
                         or string.format("frame %d: M6295 write %02x\n", n, bp1))
    end
    if (bp3 & 8) ~= 0 and (d & 8) == 0 then bp1 = -1 end
    bp3 = d
    return data
end)

local coin
for _, port in pairs(mach.ioport.ports) do
    if port.fields["Coin 1"] then coin = port.fields["Coin 1"] end
end

subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    n = n + 1
    if coin and COIN > 0 then coin:set_value((n >= COIN and n < COIN + HOLD) and 1 or 0) end
    if n >= FRAMES then
        f:close()
        local d = io.open(OUT .. "/oki.done", "w")
        d:write(string.format("frames %d\n", n))
        d:close()
        mach:exit()
    end
end)
core_subs = subs
