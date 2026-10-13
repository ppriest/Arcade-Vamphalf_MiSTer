-- MAME Testers 9371 (coolmini: the sound test freezes past STAGE4 BGM): the report's steps by frame, a
-- snapshot after each, MCR's value per frame and every change to it.
--
--   CORE_OUT   output directory (exists): mt9371.txt, and the snapshots in MAME's -snapshot_directory
--
-- Steps (mametesters.org view.php?id=9371): TEST, Button 1 (Test devices), Down x2 (Audio device), Button 1,
-- Down (BGM), Right until STAGE4 (CLEAR, OTHER, STAGE1-4), Right (the freeze); then Right and Left, which changes the screen only if the
-- game still reads its inputs.

local OUT  = os.getenv("CORE_OUT") or "."
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local scr  = mach.screens[":screen"]
local f    = io.open(OUT .. "/mt9371.txt", "w")

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    error("no input " .. name)
end

local press = {
    { 600,  "Service Mode", "test" },
    { 780,  "P1 Button 1",  "test_devices" },
    { 900,  "P1 Down",      "down1" },
    { 960,  "P1 Down",      "audio_device" },
    { 1080, "P1 Button 1",  "audio_menu" },
    { 1200, "P1 Down",      "bgm" },
    { 1320, "P1 Right",     "other" },
    { 1440, "P1 Right",     "stage1" },
    { 1560, "P1 Right",     "stage2" },
    { 1680, "P1 Right",     "stage3" },
    { 1800, "P1 Right",     "stage4" },
    { 1920, "P1 Right",     "past_stage4" },
    { 2160, "P1 Right",     "responsive_check" },
    { 2400, "P1 Left",      "responsive_check2" },
}
local HOLD, SHOT_AFTER, END = 8, 100, 2700
local n, last_mcr = 0, nil

local subs = {}
subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    n = n + 1
    local mcr = cpu.state["MCR"].value
    if mcr ~= last_mcr then
        f:write(string.format("frame %d: MCR %08x PC %08x\n", n, mcr, cpu.state["PC"].value))
        last_mcr = mcr
    end
    for _, p in ipairs(press) do
        if n == p[1] then field(p[2]):set_value(1); f:write(string.format("frame %d: press %s\n", n, p[2])) end
        if n == p[1] + HOLD then field(p[2]):set_value(0) end
        if n == p[1] + SHOT_AFTER then
            scr:snapshot(p[3] .. ".png")
            f:write(string.format("frame %d: snapshot %s, PC %08x\n", n, p[3], cpu.state["PC"].value))
        end
    end
    if n >= END then
        f:write(string.format("frame %d: end, PC %08x\n", n, cpu.state["PC"].value))
        f:close()
        mach:exit()
    end
end)
core_subs = subs
