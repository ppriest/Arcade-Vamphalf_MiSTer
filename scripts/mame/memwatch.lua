-- Log the main CPU's writes to a program-space range, with frame and PC.
--
--   MW_OUT     output file: "<frame> <pc> <address> <data> <mask>"
--   MW_LO, MW_HI  hex range
--   MW_FRAMES  frames to run, then exit

local OUT    = os.getenv("MW_OUT")
local LO     = tonumber(os.getenv("MW_LO"), 16)
local HI     = tonumber(os.getenv("MW_HI"), 16)
local FRAMES = tonumber(os.getenv("MW_FRAMES") or "200")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local f = assert(io.open(OUT, "w"))
local frame = 0
-- the tap is a global: an unreferenced tap is garbage-collected, and removed with it
KEEP_MW_W = prog:install_write_tap(LO, HI, "mww", function(offset, d, mask)
    if not mach:side_effects_disabled() then
        f:write(string.format("%d %08x %08x %08x %08x\n", frame, cpu.state["PC"].value, offset, d, mask))
    end
    return d
end)
KEEP_MW_F = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame >= FRAMES then f:close(); mach:exit() end
end)
