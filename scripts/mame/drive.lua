-- Drive a set's inputs on a schedule, take snapshots, and log the main CPU's PC once a frame (a game that
-- has locked up shows one PC, or a short loop, from then on).
--
--   DRV_LOG     output file: "<frame> <pc>" per frame
--   DRV_FRAMES  frames to run, then exit
--   DRV_SNAPS   comma-separated frames to snapshot
--   DRV_SEQ     ';'-separated presses "<frame>+<frames held>=<field name>", e.g. "600+6=Coin 1;640+6=Service 1"

local LOG    = os.getenv("DRV_LOG")
local FRAMES = tonumber(os.getenv("DRV_FRAMES") or "1800")
local SNAPS  = {}
for n in string.gmatch(os.getenv("DRV_SNAPS") or "", "%d+") do SNAPS[tonumber(n)] = true end
local SEQ = {}
for f, d, name in string.gmatch(os.getenv("DRV_SEQ") or "", "(%d+)%+(%d+)=([^;]+)") do
    SEQ[#SEQ + 1] = { from = tonumber(f), to = tonumber(f) + tonumber(d), name = name }
end

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local log  = assert(io.open(LOG, "w"))

local fields = {}
for _, p in pairs(mach.ioport.ports) do
    for name, fld in pairs(p.fields) do fields[name] = fld end
end
for _, s in ipairs(SEQ) do
    if not fields[s.name] then
        local names = {}
        for name in pairs(fields) do names[#names + 1] = name end
        table.sort(names)
        error("no input field named '" .. s.name .. "'; the fields: " .. table.concat(names, " | "))
    end
end

local frame = 0
KEEP_DRV_F = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    for _, s in ipairs(SEQ) do
        if frame == s.from then fields[s.name]:set_value(1) end
        if frame == s.to then fields[s.name]:set_value(0) end
    end
    log:write(string.format("%d %08x\n", frame, cpu.state["PC"].value))
    if SNAPS[frame] then mach.video:snapshot() end
    if frame >= FRAMES then
        log:close()
        mach:exit()
    end
end)
