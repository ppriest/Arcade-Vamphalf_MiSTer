-- Dump MAME memory regions to files, for checking a .mra image against MAME's own bytes.
--   RD_OUT      output directory
--   RD_REGIONS  "tag,tag,..." region tags (":gfx")
-- Each region goes to <RD_OUT>/<tag without ':'>.bin, byte i = region:read_u8(i), after the first frame
-- (driver init has run).
local OUT = os.getenv("RD_OUT")
local done = false
emu.register_frame_done(function()
    if done then return end
    done = true
    for tag in string.gmatch(os.getenv("RD_REGIONS") or "", "([^,]+)") do
        local r = manager.machine.memory.regions[tag]
        local f = assert(io.open(OUT .. "/" .. tag:gsub(":", "") .. ".bin", "wb"))
        local chunk = {}
        for i = 0, r.size - 1 do
            chunk[#chunk + 1] = string.char(r:read_u8(i))
            if #chunk == 65536 then f:write(table.concat(chunk)); chunk = {} end
        end
        f:write(table.concat(chunk))
        f:close()
    end
    manager.machine:exit()
end)
