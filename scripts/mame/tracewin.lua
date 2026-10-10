-- Debugger instruction trace of the main CPU over a window of frames (MAME must run with -debug).
--
--   TW_OUT   output file
--   TW_FROM  first frame traced
--   TW_TO    trace stops at the start of this frame; MAME exits
--   TW_COIN  frame to insert a coin and press Start, repeated every 300 frames (0 = never); P1 button 1 is
--            tapped from 300 frames after it, so play goes on

local OUT  = os.getenv("TW_OUT")
local FROM = tonumber(os.getenv("TW_FROM") or "59")
local TO   = tonumber(os.getenv("TW_TO") or "62")
local COIN = tonumber(os.getenv("TW_COIN") or "0")

local mach = manager.machine
local dbg  = mach.debugger
dbg:command("go")
local frame = 0
local function press(field, on)
    for _, p in pairs(mach.ioport.ports) do
        local fld = p.fields[field]
        if fld then fld:set_value(on and 1 or 0) end
    end
end
KEEP_TW_F = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if COIN > 0 and frame >= COIN then
        local k = (frame - COIN) % 300
        press("Coin 1", k < 6)
        press("1 Player Start", k >= 30 and k < 36)
        if frame >= COIN + 300 then press("P1 Button 1", (frame - COIN) % 8 < 4) end
    end
    if frame == FROM then dbg:command(string.format("trace %s,maincpu,noloop", OUT)) end
    if frame == TO then
        dbg:command("trace off,maincpu")
        mach:exit()
    end
end)
