-- Count the main CPU's reads of named ranges, for deciding whether a write path may defer writes (a range the
-- CPU reads back cannot hold a write the CPU would expect to see).
--   RC_OUT     output file
--   RC_TAPS    "name:hexlo:hexhi,..."
--   RC_SKIP    frames before counting; RC_FRAMES frames counted
--   RC_COIN    frame to insert a coin and press Start (0 = attract), as qs_banks.lua
local OUT    = os.getenv("RC_OUT")
local SKIP   = tonumber(os.getenv("RC_SKIP") or "300")
local FRAMES = tonumber(os.getenv("RC_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("RC_COIN") or "0")
local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local counting = false
local names, cnt = {}, {}
_G.__rc = {}
for name, lo, hi in string.gmatch(os.getenv("RC_TAPS") or "", "([%w_]+):(%x+):(%x+)") do
    names[#names + 1] = name
    cnt[name] = 0
    _G.__rc[#_G.__rc + 1] = prog:install_read_tap(tonumber(lo, 16), tonumber(hi, 16), "rc_" .. name, function(offset, data, mask)
        if counting and not mach:side_effects_disabled() then cnt[name] = cnt[name] + 1 end
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
    if n == SKIP then counting = true end
    if n == SKIP + FRAMES then
        local f = assert(io.open(OUT, "w"))
        for _, name in ipairs(names) do f:write(string.format("%s %d\n", name, cnt[name])) end
        f:close()
        mach:exit()
    end
end)
