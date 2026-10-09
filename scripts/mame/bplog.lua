-- Print registers at breakpoints over a window of frames (MAME must run with -debug). Each breakpoint's
-- action is a debugger printf, then go; the debugger console log is written to BP_OUT at the end.
--
--   BP_OUT     output file
--   BP_FROM    frame the breakpoints are set at; BP_TO frame MAME exits at
--   BP_LIST    "addr:printf-format:args;addr:..." (format and args as the debugger's printf takes them)

local OUT  = os.getenv("BP_OUT")
local FROM = tonumber(os.getenv("BP_FROM") or "59")
local TO   = tonumber(os.getenv("BP_TO") or "62")
local LIST = os.getenv("BP_LIST") or ""

local mach = manager.machine
local dbg  = mach.debugger
dbg:command("go")
local frame = 0
KEEP_BP_F = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == FROM then
        for spec in string.gmatch(LIST, "[^;]+") do
            local addr, fmt, args = spec:match("^(%x+):([^:]*):(.*)$")
            dbg:command(string.format('bpset %s,1,{printf "f%d %s %s\\n",%s; g}', addr, frame, addr, fmt, args))
        end
    end
    if frame == TO then
        local f = assert(io.open(OUT, "w"))
        for _, line in ipairs(dbg.consolelog) do f:write(line, "\n") end
        f:close()
        mach:exit()
    end
end)
