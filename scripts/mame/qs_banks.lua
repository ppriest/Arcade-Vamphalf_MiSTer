-- Limenko's QS1000: the 8052's reads of its banked data window (0x0100-0xffff, the 64 KB page P3 bits 2:0
-- select, limenko.cpp qs1000_p3_w), counted by page. Per run: reads per page, distinct 16-byte lines per page,
-- and how many reads fall in a different 16-byte line from the previous read (a one-line buffer's misses).
--
--   QB_OUT     output file
--   QB_SKIP    frames before counting; QB_FRAMES frames counted
--   QB_COIN    frame to insert a coin and press Start (0 = attract); QB_IN_* field names
local OUT    = os.getenv("QB_OUT")
local SKIP   = tonumber(os.getenv("QB_SKIP") or "300")
local FRAMES = tonumber(os.getenv("QB_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("QB_COIN") or "0")

local mach = manager.machine
local cpu  = mach.devices[":qs1000:cpu"]
local data = cpu.spaces["xdata"]       -- MOVX space (qs1000_data_map)
local bank = mach.memory.banks[":qs1000_bank"]

local counting = os.getenv("QB_FROM0") == "1"
local reads, lines, changes = {}, {}, 0
for b = 0, 7 do reads[b] = 0; lines[b] = {} end
local last = -1
local first_hi = -1           -- the first frame with a read of bank 2-7, counted from reset
local nframe = 0

_G.__qb_tap = data:install_read_tap(0x0100, 0xffff, "qb", function(offset, d, mask)
    if counting and not mach:side_effects_disabled() then
        local b = bank.entry
        if b >= 2 and first_hi < 0 then first_hi = nframe end
        reads[b] = reads[b] + 1
        local l = b * 0x1000 + (offset >> 4)
        lines[b][l] = true
        if l ~= last then changes = changes + 1 end
        last = l
    end
    return d
end)

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local f_coin, f_start = field(os.getenv("QB_IN_COIN") or "Coin 1"), field(os.getenv("QB_IN_START") or "1 Player Start")
local f_hold, f_pulse = field(os.getenv("QB_IN_HOLD") or "P1 Right"), field(os.getenv("QB_IN_PULSE") or "P1 Button 1")

local n = 0
emu.register_frame_done(function()
    n = n + 1
    nframe = n
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
        f:write(string.format("frames %d\nline_changes %d\nfirst_bank2plus_frame %d\n", FRAMES, changes, first_hi))
        for b = 0, 7 do
            local nl = 0
            for _ in pairs(lines[b]) do nl = nl + 1 end
            f:write(string.format("bank %d reads %d lines %d\n", b, reads[b], nl))
        end
        f:close()
        mach:exit()
    end
end)
