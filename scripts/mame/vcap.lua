-- Video captures for Vamphalf's software model (scripts/vamphalf_capture.py).
-- One MAME run, many frames. At each frame in VC_FRAMES this dumps, in the same
-- frame notifier as MAME's screenshot (so the three belong together):
--   f<N>_spriteram.bin  256 KB, CPU view, big-endian, address order
--   f<N>_palette.bin     64 KB, same
--   f<N>.png             scr:snapshot (visible area, -snapview native)
--   manifest.txt         one line per capture: frame, flip, clipflip, visible size, flip writes so far
--                        flip = m_flipscreen at the start of this notifier, i.e. at the screen update
--                        whose picture the screenshot shows; clipflip = the same one frame earlier.
--                        MAME changes the screen's visible area inside screen_update (handle_flipped_
--                        visible_area), so the clip an update draws with is the previous update's.
-- and, once, VC_GFX: the whole "gfx" region as a flat file in memory order.
--
--   CORE_CPU CORE_SPACE   as regions.json
--   VC_OUT      output directory
--   VC_FRAMES   comma list of frame numbers
--   VC_GFX      path of the gfx dump ("" = none)
--   VC_FLIPPORT I/O address of the flip write (misncrft 0x40, wivernwg 0x800)
--   VC_POKE     "frame:value,..." writes value to the flip port through the IO space
--               at that frame (the game's own flip handler runs; used because the
--               set has no DIP or menu entry for flip, see manifest.txt "flip_writes")
--   VC_COINLEN  frames each coin and Start press is held (default 6)
--   VC_COINPERIOD, VC_STARTPERIOD  repeat the coin / Start press every N frames (0 = once)
--   VC_COIN     frame to insert a coin (0 = none); Start follows, then HOLD is held
--               and PULSE pulsed, as in wtiming.lua
--   VC_IN_*     input field names
-- Lua faults are caught by run.lua. Callbacks are pcall-guarded: a tap or notifier
-- error is otherwise silent.

local OUT   = assert(os.getenv("VC_OUT"))
local mach  = manager.machine
local cpu   = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local sp    = cpu.spaces[os.getenv("CORE_SPACE") or "program"]
local ios   = cpu.spaces["io"]
local scr   = mach.screens[":screen"]
local FLIPPORT = tonumber(os.getenv("VC_FLIPPORT") or "0x40")
local COIN  = tonumber(os.getenv("VC_COIN") or "0")
local COINLEN = tonumber(os.getenv("VC_COINLEN") or "6")
local GFX   = os.getenv("VC_GFX") or ""

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s or "", "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

local want, last = {}, 0
for _, t in ipairs(split(os.getenv("VC_FRAMES"), ",")) do
    want[tonumber(t)] = true
    if tonumber(t) > last then last = tonumber(t) end
end
local poke = {}
for _, t in ipairs(split(os.getenv("VC_POKE"), ",")) do
    local f, v = t:match("^(%d+):(%x+)$")
    poke[tonumber(f)] = tonumber(v, 16)
end

local function fail(what, err)
    local f = io.open(OUT .. "/ERROR.txt", "a")
    if f then f:write(what, ": ", tostring(err), "\n"); f:close() end
    print("VCAP_ERROR " .. what .. ": " .. tostring(err))
end

core_subs = {}

-- flip I/O writes: the driver latches flip = data & 1 (m_flip_bit = 1, both sets)
local flip, nflipw, flipw_log = false, 0, {}
core_subs[#core_subs + 1] = ios:install_write_tap(FLIPPORT, FLIPPORT, "vc_flip",
    function(offset, data, mask)
        local ok, err = pcall(function()
            if mach:side_effects_disabled() then return end
            flip = (data & 1) ~= 0
            nflipw = nflipw + 1
            if #flipw_log < 40 then
                flipw_log[#flipw_log + 1] = string.format("%d:%x", scr:frame_number(), data & 0xffff)
            end
        end)
        if not ok then fail("flip tap", err) end
        return data
    end)

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin  = field(os.getenv("VC_IN_COIN") or "Coin 1")
local f_start = field(os.getenv("VC_IN_START") or "1 Player Start")
local f_right = field(os.getenv("VC_IN_HOLD") or "P1 Right")
local f_b1    = field(os.getenv("VC_IN_PULSE") or "P1 Button 1")

local function dump(lo, nbytes)
    local t = {}
    for a = lo, lo + nbytes - 4, 4 do t[#t + 1] = string.pack(">I4", sp:read_u32(a)) end
    local s = table.concat(t)
    -- the dump must equal a byte-wise read of the same CPU view
    for i = 0, 63 do
        assert(s:byte(i + 1) == sp:read_u8(lo + i), "u32 dump differs from u8 read at " .. i)
    end
    return s
end

local function write(name, bytes)
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(bytes)
    f:close()
end

local function dump_gfx()
    local r = assert(mach.memory.regions[":gfx"], "no :gfx region")
    local f = assert(io.open(GFX, "wb"))
    local n = r.size
    local chunk = {}
    for a = 0, n - 4, 4 do
        chunk[#chunk + 1] = string.pack("<I4", r:read_u32(a))
        if #chunk == 32768 then f:write(table.concat(chunk)); chunk = {} end
    end
    f:write(table.concat(chunk))
    f:close()
    -- spot check against byte reads
    local g = assert(io.open(GFX, "rb"))
    for _, a in ipairs({ 0, 1, 255, 4097, n // 2 + 3, n - 1 }) do
        g:seek("set", a)
        assert(g:read(1):byte() == r:read_u8(a), "gfx dump differs at " .. a)
    end
    g:close()
    return n
end

local man = assert(io.open(OUT .. "/manifest.txt", "w"))
man:write("set ", mach.system.name, "\nmame ", emu.app_version(), "\n")
man:write("# frame flip clipflip width height flip_writes_so_far\n")
local gfxdone = false
local last_flip = false

core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    local ok, err = pcall(function()
        local fn = scr:frame_number()
        local flip_now = flip
        local clip_flip = last_flip
        last_flip = flip_now
        if COIN > 0 and f_coin and f_start then
            -- A single coin pulse is not credited in either set (measured: one pulse of 1, 3, 20 or
            -- 60 frames at frame 700 or 1500 left CREDIT 0); repeated pulses from frame 400 are.
            local per = tonumber(os.getenv("VC_COINPERIOD") or "0")
            local sper = tonumber(os.getenv("VC_STARTPERIOD") or "0")
            if per > 0 then f_coin:set_value((fn >= COIN and (fn - COIN) % per < COINLEN) and 1 or 0)
            else f_coin:set_value((fn >= COIN and fn < COIN + COINLEN) and 1 or 0) end
            local st = fn - COIN - 90
            if sper > 0 then f_start:set_value((st >= 0 and st % sper < COINLEN) and 1 or 0)
            else f_start:set_value((st >= 0 and st < COINLEN) and 1 or 0) end
            if st >= COINLEN then
                if f_right then f_right:set_value(1) end
                if f_b1 then f_b1:set_value((fn % 20) < 4 and 1 or 0) end
            end
        end
        if poke[fn] ~= nil then
            -- the game's own I/O writes are full bus width (mask ffffffff on the E1-32)
            if (tonumber(os.getenv("CORE_BYTES") or "2")) == 4 then ios:write_u32(FLIPPORT, poke[fn])
            else ios:write_u16(FLIPPORT, poke[fn]) end
        end
        if not gfxdone and GFX ~= "" then
            gfxdone = true
            man:write("gfx ", tostring(dump_gfx()), " bytes -> ", GFX, "\n")
        end
        if want[fn] then
            write(string.format("f%d_spriteram.bin", fn), dump(0x40000000, 0x40000))
            write(string.format("f%d_palette.bin", fn), dump(0x80000000, 0x10000))
            scr:snapshot(string.format("%s/f%d.png", OUT, fn))
            man:write(string.format("%d %d %d %d %d %d\n", fn, flip_now and 1 or 0, clip_flip and 1 or 0,
                scr.width, scr.height, nflipw))
            man:flush()
        end
        if fn >= last then
            man:write("flip_writes ", tostring(nflipw), " first ", table.concat(flipw_log, " "), "\n")
            man:close()
            print("VCAP_OK " .. OUT)
            mach:exit()
        end
    end)
    if not ok then fail("frame", err); mach:exit() end
end)
