-- Limenko sprite census, for scripts/lm_census.py.
--
-- At each write to the sprite-draw command (0x8003e000) MAME swaps the sprite-RAM bank and
-- draws the bank now selected, up to the count latched at the previous command, into a
-- 512 x 512 frame (limenko.cpp spriteram_buffer_w, draw_sprites). This script repeats that
-- walk without drawing and records, per command, the work and the per-line load over the
-- visible 384 x 240; per frame, the commands and the CPU writes to the bank last drawn.
--
--   LC_OUT     output file
--   LC_SKIP    frames before recording; LC_FRAMES frames recorded
--   LC_BITPOS  bit of IN2 that reads spriteram_bit (31; spotty 19)
--   LC_COIN, LC_IN_*, LC_COIN_PERIOD, LC_START_PERIOD, LC_PRESS  as WT_* in wtiming.lua
--
-- Rows:
--   C frame line count enabled visible pix_all pix_vis maxline_vis maxline_full maxspr_line other
--     pix_all: w*h of every enabled sprite drawn (MAME draws all of the 512 x 512 frame);
--     pix_vis: those pixels inside 384 x 240; maxline_vis: the most visible pixels on one line;
--     maxline_full: on one visible line, the summed full widths of the sprites crossing it
--     (what a line renderer fetches); maxspr_line: the most sprites crossing one visible line;
--     other: enabled entries in the bank not drawn
--   F frame commands drawnbank_writes otherbank_writes vr0 vr1 vr2 vr3 bit drawn
--     bit: spriteram_bit as IN2 reads it at the frame's end; drawn: the bank last drawn

local OUT    = os.getenv("LC_OUT")
local SKIP   = tonumber(os.getenv("LC_SKIP") or "600")
local FRAMES = tonumber(os.getenv("LC_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("LC_COIN") or "0")
local BITPOS = tonumber(os.getenv("LC_BITPOS") or "31")
local PRESS  = tonumber(os.getenv("LC_PRESS") or "6")
local COIN_PER  = tonumber(os.getenv("LC_COIN_PERIOD") or "0")
local START_PER = tonumber(os.getenv("LC_START_PERIOD") or "0")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]
local spr  = mach.memory.shares[":spriteram"]
local vreg = mach.memory.shares[":videoreg"]
local in2  = mach.ioport.ports[":IN2"]
local gfxlen = mach.memory.regions[":gfx"].size

local frame_period = 1.0 / scr.refresh
-- no raw timing: the frame is the 240 visible lines (set_vblank_time 0), and the vblank
-- interrupt comes at line 0
local vtotal = scr.height
local line_period = frame_period / vtotal
local function cur_line()
    return math.floor((frame_period - scr:time_until_pos(0)) / line_period + 0.5) % vtotal
end

local f = assert(io.open(OUT, "w"))
f:write(string.format("vtotal %d\ngfxlen %d\n", vtotal, gfxlen))

local n = 0
local recording = false
local prev_count = 0
local drawn_bank = -1
local cmds, wr_drawn, wr_other = 0, 0, 0

local function u32(share, idx)
    if idx >= 2048 then return 0 end
    return share:read_u32(idx * 4)
end

local function census(line, bank)
    local count = prev_count
    local lv, lf, ls = {}, {}, {}
    for y = 0, 239 do lv[y] = 0; lf[y] = 0; ls[y] = 0 end
    local enabled, visible, pix_all, pix_vis = 0, 0, 0, 0
    local base = bank * 0x400
    for i = 0, count do
        local w0 = u32(spr, base + 2 * i)
        local w1 = u32(spr, base + 2 * i + 1)
        if (w0 & 0x80000000) ~= 0 then
            local x = (w0 >> 16) & 0x1ff
            local w = (((w0 >> 25) & 7) + 1) * 8
            local y = w0 & 0x1ff
            local h = (((w0 >> 9) & 7) + 1) * 8
            local code = (w1 & 0x7ffff) << 6
            if code + w * h <= gfxlen then
                enabled = enabled + 1
                pix_all = pix_all + w * h
                -- visible columns: [x, x+w) modulo 512 inside 0..383
                local vw = 0
                for _, sx in ipairs({ x, x - 512 }) do
                    local a, b = math.max(sx, 0), math.min(sx + w, 384)
                    if b > a then vw = vw + (b - a) end
                end
                local seen = false
                if vw > 0 then
                    for _, sy in ipairs({ y, y - 512 }) do
                        local a, b = math.max(sy, 0), math.min(sy + h, 240)
                        for yy = a, b - 1 do
                            lv[yy] = lv[yy] + vw
                            lf[yy] = lf[yy] + w
                            ls[yy] = ls[yy] + 1
                            pix_vis = pix_vis + vw
                            seen = true
                        end
                    end
                end
                if seen then visible = visible + 1 end
            end
        end
    end
    local mv, mf, ms = 0, 0, 0
    for y = 0, 239 do
        if lv[y] > mv then mv = lv[y] end
        if lf[y] > mf then mf = lf[y] end
        if ls[y] > ms then ms = ls[y] end
    end
    local other = 0
    for i = 0, count do
        if (u32(spr, (bank ~ 1) * 0x400 + 2 * i) & 0x80000000) ~= 0 then other = other + 1 end
    end
    f:write(string.format("C %d %d %d %d %d %d %d %d %d %d %d\n",
        n, line, count, enabled, visible, pix_all, pix_vis, mv, mf, ms, other))
end

_G.__lc_cmd = prog:install_write_tap(0x8003e000, 0x8003e003, "lc_cmd", function(offset, data, mask)
    if mach:side_effects_disabled() then return data end
    -- the tap runs before spriteram_buffer_w: IN2 still reads the bit before the toggle
    local bank = (((in2:read() >> BITPOS) & 1) ~ 1)
    if recording then
        census(cur_line(), bank)
        cmds = cmds + 1
    end
    drawn_bank = bank
    prev_count = (vreg:read_u32(0) >> 16) & 0x3ff
    return data
end)

_G.__lc_spr = prog:install_write_tap(0x80018000, 0x80019fff, "lc_spr", function(offset, data, mask)
    if recording and not mach:side_effects_disabled() then
        local bank = ((offset - 0x80018000) >> 12) & 1
        if bank == drawn_bank then wr_drawn = wr_drawn + 1 else wr_other = wr_other + 1 end
    end
    return data
end)

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    return nil
end
local f_coin, f_start = field(os.getenv("LC_IN_COIN") or "Coin 1"), field(os.getenv("LC_IN_START") or "1 Player Start")
local f_hold, f_pulse = field(os.getenv("LC_IN_HOLD") or "P1 Right"), field(os.getenv("LC_IN_PULSE") or "P1 Button 1")

emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 and f_coin and f_start then
        if COIN_PER > 0 then f_coin:set_value((n >= COIN and (n - COIN) % COIN_PER < PRESS) and 1 or 0)
        else f_coin:set_value((n >= COIN and n < COIN + PRESS) and 1 or 0) end
        local st = n - COIN - 90
        if START_PER > 0 then f_start:set_value((st >= 0 and st % START_PER < PRESS) and 1 or 0)
        else f_start:set_value((st >= 0 and st < PRESS) and 1 or 0) end
        if st >= PRESS then
            if f_hold then f_hold:set_value(1) end
            if f_pulse then f_pulse:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if recording then
        f:write(string.format("F %d %d %d %d %08x %08x %08x %08x %d %d\n", n, cmds, wr_drawn, wr_other,
            vreg:read_u32(0), vreg:read_u32(4), vreg:read_u32(8), vreg:read_u32(12),
            (in2:read() >> BITPOS) & 1, drawn_bank))
    end
    cmds, wr_drawn, wr_other = 0, 0, 0
    if n == SKIP then recording = true end
    if n == SKIP + FRAMES then
        if os.getenv("LC_SNAP") == "1" then mach.video:snapshot() end
        f:close()
        mach:exit()
    end
end)
