-- Disassemble a range of the main CPU's program space at a given frame (MAME must run with -debug).
--
--   DA_OUT    output file
--   DA_FRAME  frame to disassemble at (code copied to RAM is there by then)
--   DA_START, DA_LEN  hex range

local OUT   = os.getenv("DA_OUT")
local FRAME = tonumber(os.getenv("DA_FRAME") or "100")
local START = os.getenv("DA_START") or "0"
local LEN   = os.getenv("DA_LEN") or "80000"

local mach = manager.machine
local dbg  = mach.debugger
dbg:command("go")
local frame = 0
KEEP_DA_F = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == FRAME then
        dbg:command(string.format("dasm %s,%s,%s,0,maincpu", OUT, START, LEN))
    end
    if frame == FRAME + 2 then mach:exit() end
end)
