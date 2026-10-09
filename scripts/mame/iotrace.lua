-- Log every main-CPU I/O access with its frame and PC (scripts/mame_eeprom_trace.py decodes the EEPROM's
-- serial protocol from it). The whole I/O space, unlike prottrace.lua's E1-16 range.
--
--   IT_OUT     output file: "<frame> <pc> W|R <offset> <data>" per access
--   IT_FRAMES  frames to run, then exit
--   IT_COIN    frame to insert a coin and press Start, repeated every 300 frames (0 = never)
--   IT_FIRE    frame from which P1 button 1 is tapped, 4 frames down, 4 up (0 = never)
--   IT_SNAPS   comma-separated frames to take a snapshot at
--   IT_HOLD    an input field held down for the whole run, e.g. "P1 Button 7" (unset = none)

local OUT    = os.getenv("IT_OUT")
local FRAMES = tonumber(os.getenv("IT_FRAMES") or "1200")
local COIN   = tonumber(os.getenv("IT_COIN") or "0")
local FIRE   = tonumber(os.getenv("IT_FIRE") or "0")
local HOLD   = os.getenv("IT_HOLD")
local SNAPS  = {}
for n in string.gmatch(os.getenv("IT_SNAPS") or "", "%d+") do SNAPS[tonumber(n)] = true end

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local iosp = cpu.spaces["io"]
local f = assert(io.open(OUT, "w"))
f:write("# I/O accesses: <frame> <pc> W|R <offset> <data>\n")

local frame = 0
local function pc() return cpu.state["PC"].value end
-- the taps are globals: an unreferenced tap is garbage-collected, and removed with it
KEEP_IT_W = iosp:install_write_tap(0, iosp.address_mask, "itw", function(offset, d, mask)
    if not mach:side_effects_disabled() then f:write(string.format("%d %08x W %04x %08x\n", frame, pc(), offset, d)) end
    return d
end)
KEEP_IT_R = iosp:install_read_tap(0, iosp.address_mask, "itr", function(offset, d, mask)
    if not mach:side_effects_disabled() then f:write(string.format("%d %08x R %04x %08x\n", frame, pc(), offset, d)) end
    return d
end)

local function press(field, on)
    for _, p in pairs(mach.ioport.ports) do
        local fld = p.fields[field]
        if fld then fld:set_value(on and 1 or 0) end
    end
end

KEEP_IT_F = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if COIN > 0 and frame >= COIN then
        local k = (frame - COIN) % 300
        press("Coin 1", k < 6)
        press("1 Player Start", k >= 30 and k < 36)
    end
    if FIRE > 0 and frame >= FIRE then press("P1 Button 1", (frame - FIRE) % 8 < 4) end
    if HOLD then press(HOLD, true) end
    if SNAPS[frame] then mach.video:snapshot() end
    if frame >= FRAMES then
        f:write(string.format("# end %d frames\n", frame))
        f:close()
        mach:exit()
    end
end)
