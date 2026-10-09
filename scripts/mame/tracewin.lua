-- Debugger instruction trace of the main CPU over a window of frames (MAME must run with -debug).
--
--   TW_OUT   output file
--   TW_FROM  first frame traced
--   TW_TO    trace stops at the start of this frame; MAME exits

local OUT  = os.getenv("TW_OUT")
local FROM = tonumber(os.getenv("TW_FROM") or "59")
local TO   = tonumber(os.getenv("TW_TO") or "62")

local mach = manager.machine
local dbg  = mach.debugger
dbg:command("go")
local frame = 0
KEEP_TW_F = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == FROM then dbg:command(string.format("trace %s,maincpu,noloop", OUT)) end
    if frame == TO then
        dbg:command("trace off,maincpu")
        mach:exit()
    end
end)
