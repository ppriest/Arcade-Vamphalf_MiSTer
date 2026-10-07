-- Count a set's video RAM writes by scanline, for scripts/write_timing.py.
--
--   CORE_CPU, CORE_SPACE  the CPU and address space to tap (regions.json)
--   WT_IN_COIN/START/HOLD/PULSE  input field names (regions.json "inputs")
--   WT_OUT     output file
--   WT_TAPS    "name:hexlo:hexhi,..." regions to count
--   WT_SKIP    frames to run before counting (boot)
--   WT_FRAMES  frames to count
--   WT_COIN    frame to insert a coin and then press Start (0 = attract only);
--              from Start, HOLD is held and PULSE pulsed, so play goes on
--   WT_COIN_PERIOD, WT_START_PERIOD  repeat the coin / Start press every N frames (0 = once);
--              WT_PRESS frames each press is held (default 6)
--   WT_ORDER   name of one tapped region whose write ORDER is recorded per frame: first/last address,
--              first/last line, write count, and the number of writes whose address is not above
--              the previous one (output rows "order ...")
--   a tap named io_* is installed on the CPU's I/O space, the others on CORE_SPACE
--
-- The scanline comes from time_until_pos, as in capture.lua (0.28x's screen
-- binding has no vpos). Writes are binned by line; per frame the last write
-- line of each region is binned too.

local OUT    = os.getenv("WT_OUT")
local TAPS   = os.getenv("WT_TAPS") or ""
local SKIP   = tonumber(os.getenv("WT_SKIP") or "600")
local FRAMES = tonumber(os.getenv("WT_FRAMES") or "1200")
local COIN   = tonumber(os.getenv("WT_COIN") or "0")

local mach = manager.machine
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]
local scr  = mach.screens[":screen"]
local ios  = cpu.spaces["io"]
local PRESS = tonumber(os.getenv("WT_PRESS") or "6")
local COIN_PER = tonumber(os.getenv("WT_COIN_PERIOD") or "0")
local START_PER = tonumber(os.getenv("WT_START_PERIOD") or "0")

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

local frame_period = 1.0 / scr.refresh
local line_period
for _ = 1, 64 do
    local d = scr:time_until_pos(1) - scr:time_until_pos(0)
    if d > 0 and (line_period == nil or d < line_period) then line_period = d end
end
local vtotal = math.floor(frame_period / line_period + 0.5)

local function cur_line()
    return math.floor((frame_period - scr:time_until_pos(0)) / line_period + 0.5) % vtotal
end

-- vblank start line: frame_done runs when MAME finishes a frame, at vblank
-- start, so the line in force there (most common over the skipped frames) is
-- taken as vblank start. (time_until_vblank_start from an autoboot script
-- crashed MAME 0.285.)
local vbstart = -1
local vb_votes = {}

local ORDER = os.getenv("WT_ORDER") or ""
local ord_cur = nil
local ord_pairs, ord_first, ord_last, ord_n, ord_nonasc = {}, {}, {}, {}, 0
local names, hist, lastl = {}, {}, {}
local counting = false
local frame_last = {}
_G.__wt_taps = {}
for _, spec in ipairs(split(TAPS, ",")) do
    local f = split(spec, ":")
    local name, lo, hi = f[1], tonumber(f[2], 16), tonumber(f[3], 16)
    names[#names + 1] = name
    hist[name] = {}
    lastl[name] = {}
    local space = (name:sub(1, 3) == "io_") and ios or prog
    local tap = space:install_write_tap(lo, hi, "wt_" .. name, function(offset, data, mask)
        if counting and not mach:side_effects_disabled() then
            local l = cur_line()
            hist[name][l] = (hist[name][l] or 0) + 1
            frame_last[name] = l
            if name == ORDER then
                if not ord_cur then ord_cur = { fa = offset, fl = l, n = 0, prev = -1 } end
                if offset <= ord_cur.prev then ord_nonasc = ord_nonasc + 1 end
                ord_cur.prev, ord_cur.la, ord_cur.ll = offset, offset, l
                ord_cur.n = ord_cur.n + 1
            end
        end
        return data
    end)
    _G.__wt_taps[#_G.__wt_taps + 1] = tap
end

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin, f_start = field(os.getenv("WT_IN_COIN") or "Coin 1"), field(os.getenv("WT_IN_START") or "1 Player Start")
local f_right, f_b1 = field(os.getenv("WT_IN_HOLD") or "P1 Right"), field(os.getenv("WT_IN_PULSE") or "P1 Button 1")

local n = 0
emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 and f_coin and f_start then
        if COIN_PER > 0 then f_coin:set_value((n >= COIN and (n - COIN) % COIN_PER < PRESS) and 1 or 0)
        else f_coin:set_value((n >= COIN and n < COIN + PRESS) and 1 or 0) end
        local st = n - COIN - 90
        if START_PER > 0 then f_start:set_value((st >= 0 and st % START_PER < PRESS) and 1 or 0)
        else f_start:set_value((st >= 0 and st < PRESS) and 1 or 0) end
        if st >= PRESS then
            if f_right then f_right:set_value(1) end
            if f_b1 then f_b1:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if n > 10 and n <= SKIP then
        local l = cur_line()
        vb_votes[l] = (vb_votes[l] or 0) + 1
    end
    if n == SKIP then
        counting = true
        local best = 0
        for l, c in pairs(vb_votes) do
            if c > best then best = c; vbstart = l end
        end
    end
    if counting and ord_cur then
        local k = string.format("%x-%x", ord_cur.fa, ord_cur.la)
        ord_pairs[k] = (ord_pairs[k] or 0) + 1
        ord_first[ord_cur.fl] = (ord_first[ord_cur.fl] or 0) + 1
        ord_last[ord_cur.ll] = (ord_last[ord_cur.ll] or 0) + 1
        ord_n[ord_cur.n] = (ord_n[ord_cur.n] or 0) + 1
        ord_cur = nil
    end
    if counting then
        -- a frame's last write, binned at the end of the frame MAME rendered
        for name, l in pairs(frame_last) do
            lastl[name][l] = (lastl[name][l] or 0) + 1
        end
        frame_last = {}
    end
    if n == SKIP + FRAMES then
        if os.getenv("WT_SNAP") == "1" then mach.video:snapshot() end
        local f = assert(io.open(OUT, "w"))
        f:write(string.format("vtotal %d\nvbstart %d\nframes %d\n", vtotal, vbstart, FRAMES))
        for _, name in ipairs(names) do
            local parts = {}
            for l = 0, vtotal - 1 do parts[#parts + 1] = tostring(hist[name][l] or 0) end
            f:write("hist " .. name .. " " .. table.concat(parts, ",") .. "\n")
            parts = {}
            for l = 0, vtotal - 1 do parts[#parts + 1] = tostring(lastl[name][l] or 0) end
            f:write("last " .. name .. " " .. table.concat(parts, ",") .. "\n")
        end
        if ORDER ~= "" then
            local function dumpt(tag, t)
                local parts = {}
                for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. v end
                table.sort(parts)
                f:write("order " .. ORDER .. " " .. tag .. " " .. table.concat(parts, ",") .. "\n")
            end
            dumpt("first_last_addr", ord_pairs); dumpt("first_line", ord_first)
            dumpt("last_line", ord_last); dumpt("writes_per_frame", ord_n)
            f:write("order " .. ORDER .. " nonascending " .. ord_nonasc .. "\n")
        end
        f:close()
        mach:exit()
    end
end)
