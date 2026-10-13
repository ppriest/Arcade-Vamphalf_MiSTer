-- MAME Testers 9371: the main CPU's instruction trace across the bad MCR write (MAME with -debug). The menu
-- steps are mt9371.lua's; the trace runs from TRACE_FROM to TRACE_TO frames.
--
--   CORE_OUT   output directory (exists): trace.txt, done.txt

local OUT  = os.getenv("CORE_OUT") or "."
local FROM = tonumber(os.getenv("TRACE_FROM") or "1919")
local TO   = tonumber(os.getenv("TRACE_TO") or "1926")
local mach = manager.machine
local dbg  = mach.debugger
local cpu  = mach.devices[":maincpu"]

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    error("no input " .. name)
end
local press = {
    { 600, "Service Mode" }, { 780, "P1 Button 1" }, { 900, "P1 Down" }, { 960, "P1 Down" },
    { 1080, "P1 Button 1" }, { 1200, "P1 Down" }, { 1320, "P1 Right" }, { 1440, "P1 Right" },
    { 1560, "P1 Right" }, { 1680, "P1 Right" }, { 1800, "P1 Right" }, { 1920, "P1 Right" },
}
local n = 0
dbg:command("go")
local subs = {}
subs[#subs + 1] = emu.add_machine_frame_notifier(function()
    n = n + 1
    for _, p in ipairs(press) do
        if n == p[1] then field(p[2]):set_value(1) end
        if n == p[1] + 8 then field(p[2]):set_value(0) end
    end
    if n == FROM then
        dbg:command(string.format("trace %s/trace.txt,:maincpu,noloop,{tracelog \"MCR=%%08X SR=%%08X SP=%%08X UB=%%08X \",mcr,sr,sp,ub}", OUT))
    end
    if n == TO then
        dbg:command("trace off,:maincpu")
        local d = io.open(OUT .. "/done.txt", "w")
        d:write(string.format("frame %d MCR %08x PC %08x\n", n, cpu.state["MCR"].value, cpu.state["PC"].value))
        d:close()
        mach:exit()
    end
end)
core_subs = subs
