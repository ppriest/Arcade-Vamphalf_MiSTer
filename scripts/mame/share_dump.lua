-- Dump a memory share at a frame, with an optional input pressed for some frames before, for finding a game
-- variable (a credit count) by comparing runs.
--   SD_OUT     output file
--   SD_SHARE   share tag (":mainram")
--   SD_FRAME   frame to dump at, then exit
--   SD_PRESS   "<field>:<from>:<frames>" or empty
local OUT   = os.getenv("SD_OUT")
local TAG   = os.getenv("SD_SHARE") or ":mainram"
local AT    = tonumber(os.getenv("SD_FRAME") or "600")
local press = os.getenv("SD_PRESS") or ""
local fname, pfrom, plen = string.match(press, "^(.+):(%d+):(%d+)$")
pfrom, plen = tonumber(pfrom or "0"), tonumber(plen or "0")

local mach = manager.machine
local fld
if fname then
    for _, port in pairs(mach.ioport.ports) do
        if port.fields[fname] then fld = port.fields[fname] end
    end
    assert(fld, "no input field " .. fname)
end
local n = 0
emu.register_frame_done(function()
    n = n + 1
    if fld then fld:set_value((n >= pfrom and n < pfrom + plen) and 1 or 0) end
    if n == AT then
        local sh = mach.memory.shares[TAG]
        local f = assert(io.open(OUT, "wb"))
        local chunk = {}
        for i = 0, sh.size - 1, 4 do
            local v = sh:read_u32(i)
            chunk[#chunk + 1] = string.char((v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
            if #chunk == 16384 then f:write(table.concat(chunk)); chunk = {} end
        end
        f:write(table.concat(chunk))
        f:close()
        mach:exit()
    end
end)
