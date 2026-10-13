-- Writes per frame to named ranges: the largest frame, and how many frames exceed given counts, for sizing a
-- queue that holds a frame's writes. Frames run interrupt to interrupt (frame_done).
--   WM_OUT     output file
--   WM_TAPS    "name:hexlo:hexhi,..."
--   WM_SKIP, WM_FRAMES, WM_COIN  as read_count.lua
local OUT    = os.getenv("WM_OUT")
local SKIP   = tonumber(os.getenv("WM_SKIP") or "0")
local FRAMES = tonumber(os.getenv("WM_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("WM_COIN") or "0")
local LIMITS = { 256, 512, 1024, 2048, 4096, 8192 }
local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local names, cur, mx, over, total = {}, {}, {}, {}, 0
local all_cur, all_max, all_over = 0, 0, {}
for _, l in ipairs(LIMITS) do all_over[l] = 0 end
_G.__wm = {}
for name, lo, hi in string.gmatch(os.getenv("WM_TAPS") or "", "([%w_]+):(%x+):(%x+)") do
    names[#names + 1] = name
    cur[name], mx[name] = 0, 0
    _G.__wm[#_G.__wm + 1] = prog:install_write_tap(tonumber(lo, 16), tonumber(hi, 16), "wm_" .. name, function(offset, data, mask)
        if not mach:side_effects_disabled() then cur[name] = cur[name] + 1; all_cur = all_cur + 1 end
        return data
    end)
end
local function field(n)
    for _, port in pairs(mach.ioport.ports) do
        if port.fields[n] then return port.fields[n] end
    end
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local f_hold, f_pulse = field("P1 Right"), field("P1 Button 1")
local n = 0
emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 and f_coin and f_start then
        f_coin:set_value((n >= COIN and (n - COIN) % 97 < 5) and 1 or 0)
        local st = n - COIN - 90
        f_start:set_value((st >= 0 and st % 211 < 5) and 1 or 0)
        if st >= 5 then
            if f_hold then f_hold:set_value(((n // 120) % 2 == 0) and 1 or 0) end
            if f_pulse then f_pulse:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if n > SKIP then
        for _, name in ipairs(names) do
            if cur[name] > mx[name] then mx[name] = cur[name] end
        end
        if all_cur > all_max then all_max = all_cur end
        for _, l in ipairs(LIMITS) do if all_cur > l then all_over[l] = all_over[l] + 1 end end
    end
    for _, name in ipairs(names) do cur[name] = 0 end
    all_cur = 0
    if n == SKIP + FRAMES then
        local f = assert(io.open(OUT, "w"))
        for _, name in ipairs(names) do f:write(string.format("max %s %d\n", name, mx[name])) end
        f:write(string.format("max all %d\n", all_max))
        for _, l in ipairs(LIMITS) do f:write(string.format("frames_over %d %d\n", l, all_over[l])) end
        f:close()
        mach:exit()
    end
end)
