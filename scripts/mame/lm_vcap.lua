-- Video captures for the Limenko software model (scripts/lm_capture.py). One MAME run, many frames.
-- At each frame in LV_FRAMES, in the frame notifier (where MAME's screenshot is the picture screen_update just
-- drew from this RAM), it writes:
--   f<N>_fg.bin, f<N>_md.bin, f<N>_bg.bin   32 KB each, the VRAMs as the CPU sees them, big-endian dwords
--   f<N>_pal.bin                             8 KB, the palette, same
--   f<N>_vreg.bin                            20 bytes, video registers 0-4
--   f<N>_spr.bin                             the list the last draw command drew: (count + 1) entries of two
--                                            dwords, copied in the command's tap (the game rewrites the drawn bank
--                                            within lines of the command; limenko.cpp draws it at the command)
--   f<N>.png                                 the screenshot (-snapview native)
--   manifest.txt                             "frame count bank commands_since_last_capture"
--
--   LV_OUT      output directory
--   LV_FRAMES   comma list of frame numbers
--   LV_BITPOS   bit of IN2 that reads spriteram_bit (31; spotty 19)
--   LV_COIN     frame to insert a coin (0 = none), then Start and play inputs as wtiming.lua; LV_IN_* names
local OUT   = assert(os.getenv("LV_OUT"))
local mach  = manager.machine
local prog  = mach.devices[":maincpu"].spaces["program"]
local scr   = mach.screens[":screen"]
local in2   = mach.ioport.ports[":IN2"]
local BITPOS = tonumber(os.getenv("LV_BITPOS") or "31")
local COIN  = tonumber(os.getenv("LV_COIN") or "0")

local shares = {}
for _, t in ipairs({ "fg_videoram", "md_videoram", "bg_videoram", "spriteram", "palette", "videoreg" }) do
    shares[t] = mach.memory.shares[":" .. t]
end

local want, last = {}, 0
for t in string.gmatch(os.getenv("LV_FRAMES") or "", "(%d+)") do
    want[tonumber(t)] = true
    if tonumber(t) > last then last = tonumber(t) end
end

local function fail(what, err)
    local f = io.open(OUT .. "/ERROR.txt", "a")
    if f then f:write(what, ": ", tostring(err), "\n"); f:close() end
end

local function dump(share, path, bytes)
    local f = assert(io.open(path, "wb"))
    local chunk = {}
    for i = 0, bytes - 4, 4 do
        local v = share:read_u32(i)
        chunk[#chunk + 1] = string.char((v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    end
    f:write(table.concat(chunk))
    f:close()
end

-- the draw command: the bank selected after the toggle, entries 0..the count latched at the previous command
local prev_count, list, list_count, list_bank, ncmd = 0, {}, 0, 0, 0
_G.__lv_cmd = prog:install_write_tap(0x8003e000, 0x8003e003, "lv_cmd", function(offset, data, mask)
    if mach:side_effects_disabled() then return data end
    local ok, err = pcall(function()
        local bank = ((in2:read() >> BITPOS) & 1) ~ 1
        local spr = shares.spriteram
        list = {}
        for i = 0, 2 * prev_count + 1 do
            local idx = bank * 0x400 + i
            list[#list + 1] = idx < 2048 and spr:read_u32(idx * 4) or 0
        end
        list_count, list_bank = prev_count, bank
        ncmd = ncmd + 1
        prev_count = (shares.videoreg:read_u32(0) >> 16) & 0x3ff
    end)
    if not ok then fail("cmd", err) end
    return data
end)

local function field(n)
    for _, port in pairs(mach.ioport.ports) do
        if port.fields[n] then return port.fields[n] end
    end
end
local f_coin, f_start = field(os.getenv("LV_IN_COIN") or "Coin 1"), field(os.getenv("LV_IN_START") or "1 Player Start")
local f_hold, f_pulse = field(os.getenv("LV_IN_HOLD") or "P1 Right"), field(os.getenv("LV_IN_PULSE") or "P1 Button 1")

local man = assert(io.open(OUT .. "/manifest.txt", "w"))
local n = 0
emu.register_frame_done(function()
    n = n + 1
    local ok, err = pcall(function()
        if COIN > 0 and f_coin and f_start then
            f_coin:set_value((n >= COIN and (n - COIN) % 97 < 5) and 1 or 0)
            local st = n - COIN - 90
            f_start:set_value((st >= 0 and st % 211 < 5) and 1 or 0)
            if st >= 5 then
                if f_hold then f_hold:set_value(((n // 120) % 2 == 0) and 1 or 0) end
                if f_pulse then f_pulse:set_value((n % 20) < 4 and 1 or 0) end
            end
        end
        if want[n] then
            local p = string.format("%s/f%d", OUT, n)
            dump(shares.fg_videoram, p .. "_fg.bin", 0x8000)
            dump(shares.md_videoram, p .. "_md.bin", 0x8000)
            dump(shares.bg_videoram, p .. "_bg.bin", 0x8000)
            dump(shares.palette, p .. "_pal.bin", 0x2000)
            dump(shares.videoreg, p .. "_vreg.bin", 20)
            local f = assert(io.open(p .. "_spr.bin", "wb"))
            for _, v in ipairs(list) do
                f:write(string.char((v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff))
            end
            f:close()
            scr:snapshot(p .. ".png")
            man:write(string.format("%d %d %d %d\n", n, list_count, list_bank, ncmd))
            man:flush()
            ncmd = 0
        end
        if n >= last then
            man:close()
            mach:exit()
        end
    end)
    if not ok then fail("frame", err) end
end)
