-- Log the main CPU's I/O accesses with their frame, for comparing the FPGA protection (vamphalf_prot.cpp)
-- with sim/sys_tb +prot. Every access is logged; scripts/mame_prot_trace.py keeps the protection ports.
--
--   PT_OUT     output file: "<frame> W|R <address> <data>" per access
--   PT_FRAMES  frames to run, then exit
--   PT_COIN    frame to insert a coin and press Start, repeated every 300 frames (0 = never)
--   PT_FIRE    frame from which P1 button 1 is held (0 = never)

local OUT    = os.getenv("PT_OUT")
local FRAMES = tonumber(os.getenv("PT_FRAMES") or "1200")

local mach = manager.machine
local iosp = mach.devices[":maincpu"].spaces["io"]
local f = assert(io.open(OUT, "w"))
f:write("# I/O accesses: <frame> W|R <address> <data>\n")

-- the taps are globals: an unreferenced tap is garbage-collected, and removed with it
local frame = 0
KEEP_WTAP = iosp:install_write_tap(0, 0x1ff, "ptw", function(offset, d, mask)
    if not mach:side_effects_disabled() then f:write(string.format("%d W %04x %08x\n", frame, offset, d)) end
    return d
end)
KEEP_RTAP = iosp:install_read_tap(0, 0x1ff, "ptr", function(offset, d, mask)
    if not mach:side_effects_disabled() then f:write(string.format("%d R %04x %08x\n", frame, offset, d)) end
    return d
end)

local COIN = tonumber(os.getenv("PT_COIN") or "0")
local FIRE = tonumber(os.getenv("PT_FIRE") or "0")
local function press(field, on)
    for _, p in pairs(mach.ioport.ports) do
        local fld = p.fields[field]
        if fld then fld:set_value(on and 1 or 0) end
    end
end

emu.register_frame_done(function()
    frame = frame + 1
    if COIN > 0 and frame >= COIN then
        local k = (frame - COIN) % 300
        press("Coin 1", k < 6)
        press("1 Player Start", k >= 30 and k < 36)
    end
    if FIRE > 0 then press("P1 Button 1", frame >= FIRE) end
    if frame >= FRAMES then
        f:write(string.format("# end %d frames\n", frame))
        f:close()
        mach:exit()
    end
end)
