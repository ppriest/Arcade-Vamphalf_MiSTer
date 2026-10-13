#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the Limenko .mra files (the Limenko .rbf) and prove each one byte for byte.

    python scripts/build_mra_lm.py                    # every set -> releases/
    python scripts/build_mra_lm.py dynabomb           # one set
    python scripts/build_mra_lm.py --check            # verify only, write nothing
    python scripts/build_mra_lm.py --image dynabomb out.bin   # the download image (benches)

The image is the SDRAM layout of rtl/lm_sdram_map.svh. As scripts/build_mra.py: each region is built
from limenko.cpp's ROM_START records (with ROM_FILL and the region's erase value), the .mra is written,
read back with scripts/mra.py, and the two images must be identical; each interleave map is the
candidate that reproduces the ROM_START bytes.
"""
import argparse
import itertools
import re
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra as bm             # noqa: E402
import extract_romstart as ers     # noqa: E402
import mra as mra_lib              # noqa: E402
from coretools import setting      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DRIVER = Path(setting("MAME_SRC") or "E:/mame/src/mame/misc/vamphalf.cpp").with_name("limenko.cpp")
OUT_DIR = REPO / "releases"

# set: (parent or None, game id for the mod byte (rtl/lm_main.sv))
SETS = {
    "dynabomb": (None, 0),
    "sb2003":   (None, 1),
    "sb2003a":  ("sb2003", 1),
    "legendoh": (None, 2),
    "hrthouse": (None, 3),
    "spotty":   (None, 4),
}
# MiSTer button i is MAME's button i (Limenko.sv lm_pl); "-" pads an unused one, since Start sits at position 4.
# No manual or panel was found: dynabomb, sb2003 and legendoh's names are what each button does in MAME 0.289,
# pressed one at a time in play, with history.xml's button counts (dynabomb 3, sb2003 2, legendoh 4).
# sb2003's how-to-play screen shows the same two, as pictures. legendoh's buttons 3 and 4 showed nothing and
# keep MAME's names (validate_mra --allow-generic-buttons).
BUTTONS = {"dynabomb": ["Bomb", "Throw", "Jump", "-"],
           "sb2003":   ["Jump", "Bubble", "-", "-"],
           "legendoh": ["Attack", "Jump", "Button 3", "Button 4"],
           "hrthouse": ["Hold 1", "Hold 2", "Hold 3", "Hold 4", "Take / Odd", "Bet / Double Up"],
           "spotty":   ["Hold 1", "Hold 2", "Hold 3", "Hold 4", "Bet", "Stop", "Change"]}
# "Volume Boost" (Limenko.sv, switches bits 3:1, 6 dB a step) for the QS1000 sets: the step bringing the set's RMS
# in play nearest misncrft's, both rendered by scripts/qs1000_model.py at the core's settings (HACKS.md).
VOL_BOOST = {"dynabomb": 3, "sb2003": 3, "legendoh": 2, "hrthouse": 4}
VOL_BOOST_IDS = "Off,+6 dB,+12 dB,+18 dB,+24 dB,+30 dB"


def sdram_map():
    text = (REPO / "rtl" / "lm_sdram_map.svh").read_text(encoding="utf-8")
    m = dict((k, int(v, 16)) for k, v in re.findall(r"localparam \[26:0\] (LM_\w+)\s*=\s*27'h([0-9a-fA-F]+);", text))
    for k in ("LM_PRGLO", "LM_MAINCPU", "LM_SNDCPU", "LM_EEPROM", "LM_SAMPLES", "LM_DATA", "LM_WRAM", "LM_GFX"):
        if k not in m:
            sys.exit(f"{k} missing from rtl/lm_sdram_map.svh")
    return m


def game_info(text, setname):
    """build_mra.game_info, with a year such as "200?" (hrthouse)."""
    m = re.search(r"GAME\(\s*([\d?]+)\s*,\s*" + setname + r"\s*,\s*(\w+)\s*,.*?,\s*ROT(\d+)\s*,\s*\"([^\"]*)\"\s*,\s*\"([^\"]*)\"", text)
    if not m:
        sys.exit(f"no GAME line for {setname}")
    return {"year": m.group(1), "rot": int(m.group(3)), "manufacturer": m.group(4), "title": m.group(5)}


def zips_for(setname):
    names = [setname + ".zip"] + ([SETS[setname][0] + ".zip"] if SETS[setname][0] else [])
    found = []
    for n in names:
        for d in [REPO / "roms"] + bm.ROMDIRS:
            if (d / n).exists():
                found.append(d / n)
                break
    return names, found


def region_decl(body, region):
    m = re.search(r'ROM_REGION(\w*)\(\s*(0x[0-9a-fA-F]+)\s*,\s*"' + re.escape(region) + r'"\s*,\s*([^)]*)\)', body)
    if not m:
        return None
    erase = 0xff if "ERASEFF" in m.group(3) else 0x00
    return {"size": int(m.group(2), 16), "erase": erase}


def region_fills(body, region):
    """ROM_FILL(dest, length, value) records of one region (extract_romstart reports them as unknown)."""
    fills, cur = [], None
    for raw in body.split("\n"):
        line = raw.split("//")[0].strip()
        m = re.match(r'ROM_REGION\w*\(\s*0x[0-9a-fA-F]+\s*,\s*"([^"]+)"', line)
        if m:
            cur = m.group(1)
            continue
        m = re.match(r'ROM_FILL\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\)', line)
        if m and cur == region:
            fills.append(tuple(int(g, 16) for g in m.groups()))
    return fills


def load_region(zs, body, region):
    """The region as MAME's loader leaves it: erase value, then the loads and fills in order."""
    decl = region_decl(body, region)
    if not decl:
        return None, []
    recs, unknown = ers.region_records(body, region)
    unknown = [u for u in unknown if not u.startswith("ROM_FILL")]
    if unknown:
        sys.exit(f"region {region}: unparsed {unknown}")
    out = bytearray([decl["erase"]]) * decl["size"]
    for kind, name, dest, length, crc, *rest in recs:
        if kind == "load32_byte":
            data = bm.read_part(zs, name, crc)
            assert len(data) == length, (name, len(data), length)
            out[dest:dest + 4 * length:4] = data
        else:
            part = bm.load_region(zs, [(kind, name, 0, length, crc)], length)
            out[dest:dest + length] = part
    for dest, length, value in region_fills(body, region):
        out[dest:dest + length] = bytes([value]) * length
    return bytes(out), recs


def build(setname, sm, write=True):
    text = DRIVER.read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    info = game_info(text, setname)
    gid = SETS[setname][1]
    spotty = setname == "spotty"
    names, paths = zips_for(setname)
    if not paths:
        print(f"{setname}: no zip found ({' / '.join(names)}); skipped")
        return False
    zs = [zipfile.ZipFile(p) for p in paths]

    maincpu, r_main = load_region(zs, body, "maincpu")
    data, r_data = load_region(zs, body, "maindata")
    snd, r_snd = load_region(zs, body, "audiocpu" if spotty else "qs1000:cpu")
    smp, r_smp = load_region(zs, body, "oki" if spotty else "qs1000")
    gfx, r_gfx = load_region(zs, body, "gfx")

    # the image this script expects
    if spotty:
        # init_spotty expands "maindata" bytes 0 and 1 of each dword into 8bpp "gfx"; the image keeps the
        # two bytes, so pixel x is the nibble x & 1 of byte x >> 1
        g = bytearray(len(data) // 2)
        g[0::2], g[1::2] = data[0::4], data[1::4]
        gimg = bytes(g)
        exp = bytearray(len(data))
        exp[0::2] = bytes(b & 0x0f for b in gimg)
        exp[1::2] = bytes(b >> 4 for b in gimg)
        ref = bytearray(len(data))
        for x in range(0, len(data), 4):
            ref[x + 1] = (data[x] & 0xf0) >> 4
            ref[x + 0] = data[x] & 0x0f
            ref[x + 3] = (data[x + 1] & 0xf0) >> 4
            ref[x + 2] = data[x + 1] & 0x0f
        assert exp == ref, "spotty: the nibble layout does not reproduce init_spotty"
    else:
        gimg = gfx
    img = bytearray(sm["LM_GFX"] + len(gimg))
    prg2 = len(maincpu) == 0x200000
    assert len(maincpu) in (0x100000, 0x200000)
    img[sm["LM_MAINCPU"]:sm["LM_MAINCPU"] + 0x100000] = maincpu[-0x100000:]
    if prg2:
        img[sm["LM_PRGLO"]:sm["LM_PRGLO"] + 0x100000] = maincpu[:0x100000]
    img[sm["LM_SNDCPU"]:sm["LM_SNDCPU"] + len(snd)] = snd
    img[sm["LM_EEPROM"]:sm["LM_EEPROM"] + 128] = bytes([0xff]) * 128
    smp_len = sm["LM_DATA"] - sm["LM_SAMPLES"]
    assert not any(smp[smp_len:]), "sample data beyond LM_SAMPLES' 4 MB"
    img[sm["LM_SAMPLES"]:sm["LM_SAMPLES"] + min(len(smp), smp_len)] = smp[:smp_len]
    if not spotty and data is not None:
        assert len(data) <= sm["LM_WRAM"] - sm["LM_DATA"]
        img[sm["LM_DATA"]:sm["LM_DATA"] + len(data)] = data
    img[sm["LM_GFX"]:] = gimg
    img = bytes(img)

    # the .mra, part by part
    L = []
    pos = 0

    def pad_to(addr, why, fill=0):
        nonlocal pos
        if addr > pos:
            L.append(f'        <part repeat="0x{addr - pos:X}">{fill:02X}</part>  <!-- {why} -->')
            pos = addr
        assert pos == addr, (why, hex(pos), hex(addr))

    def fill_to(addr, seg, base, why):
        """Pad to addr with seg's bytes (seg starts at base), which must be one value there."""
        vals = set(seg[pos - base:addr - base])
        assert len(vals) <= 1, (why, vals)
        pad_to(addr, why, vals.pop() if vals else 0)

    def plain(region, recs, base, seg):
        """ROM_LOAD records of a region whose bytes are seg, placed at base."""
        nonlocal pos
        for kind, name, dest, length, crc, *rest in sorted(recs, key=lambda r: r[2]):
            assert kind == "load", (region, kind)
            fill_to(base + dest, seg, base, f"{region} 0x{dest:x}")
            L.append(f'        <part name="{escape(name)}" crc="{crc:08x}"/>')
            pos += length
        fill_to(base + len(seg), seg, base, f"{region}, erased or filled")

    def wswap(region, recs, base, src, lo, hi):
        """ROM_LOAD16_WORD_SWAP records of src[lo:hi], placed at base."""
        nonlocal pos
        seg = src[lo:hi]
        for kind, name, dest, length, crc, *rest in sorted(recs, key=lambda r: r[2]):
            assert kind == "load16_wswap", (region, kind)
            if dest + length <= lo or dest >= hi:
                continue
            a, b = max(dest, lo), min(dest + length, hi)
            fill_to(base + a - lo, seg, base, f"{region} 0x{a:x}")
            fdata = bm.read_part(zs, name, crc)[a - dest:b - dest]
            m = next((m for m in ("21", "12") if mra_lib.interleave([(fdata, m)], 16) == src[a:b]), None)
            if not m:
                sys.exit(f"{setname}: no 16-bit map reproduces {region} 0x{a:x}")
            sl = f' offset="0x{a - dest:X}" length="0x{b - a:X}"' if (a, b) != (dest, dest + length) else ""
            L.append('        <interleave output="16">')
            L.append(f'            <part name="{escape(name)}" crc="{crc:08x}" map="{m}"{sl}/>')
            L.append('        </interleave>')
            pos += b - a
        fill_to(base + len(seg), seg, base, f"{region}, erased")

    # maincpu: the first MB at LM_PRGLO, the last at LM_MAINCPU
    L.append("        <!-- maincpu: ROM_LOAD16_WORD_SWAP -->")
    if prg2:
        wswap("maincpu", r_main, sm["LM_PRGLO"], maincpu, 0, 0x100000)
    pad_to(sm["LM_MAINCPU"], "no first MB")
    wswap("maincpu", r_main, sm["LM_MAINCPU"], maincpu, len(maincpu) - 0x100000, len(maincpu))
    L.append(f"        <!-- {'audiocpu' if spotty else 'qs1000:cpu'} -->")
    plain("snd", r_snd, sm["LM_SNDCPU"], snd)
    pad_to(sm["LM_EEPROM"], "eeprom")
    L.append('        <part repeat="0x80">FF</part>  <!-- eeprom: none in the set, the 93C46 erased -->')
    pos += 0x80
    pad_to(sm["LM_SAMPLES"], "samples")
    L.append(f"        <!-- {'oki' if spotty else 'qs1000'} samples -->")
    plain("samples", r_smp, sm["LM_SAMPLES"], smp[:sm["LM_DATA"] - sm["LM_SAMPLES"]])
    if not spotty and data is not None:
        L.append("        <!-- maindata: ROM_LOAD16_WORD_SWAP -->")
        wswap("maindata", r_data, sm["LM_DATA"], data, 0, len(data))
    pad_to(sm["LM_GFX"], "gfx")
    if spotty:
        L.append("        <!-- gfx: maindata's bytes 0 and 1 of each dword (gc_rom1, gc_rom3), 4bpp -->")
        recs = sorted(r_data, key=lambda r: r[2])
        assert [r[0] for r in recs] == ["load32_byte", "load32_byte"] and [r[2] for r in recs] == [0, 1], recs
        parts = [(bm.read_part(zs, r[1], r[4]), r) for r in recs]
        for maps in (("01", "10"), ("10", "01")):
            if mra_lib.interleave([(d, m) for (d, _), m in zip(parts, maps)], 16) == gimg:
                break
        else:
            sys.exit("spotty: no 16-bit interleave reproduces the graphics")
        L.append('        <interleave output="16">')
        for (d, r), m in zip(parts, maps):
            L.append(f'            <part name="{r[1]}" crc="{r[4]:08x}" map="{m}"/>')
        L.append('        </interleave>')
        pos += len(gimg)
    else:
        L.append("        <!-- gfx: ROM_LOAD32_BYTE quads -->")
        gl = sorted(r_gfx, key=lambda r: r[2])
        for i in range(0, len(gl), 4):
            q = gl[i:i + 4]
            assert [r[0] for r in q] == ["load32_byte"] * 4 and [r[2] - q[0][2] for r in q] == [0, 1, 2, 3], q
            assert len({r[3] for r in q}) == 1
            pad_to(sm["LM_GFX"] + q[0][2], "gfx")
            want = gfx[q[0][2]:q[0][2] + 4 * q[0][3]]
            ds = [bm.read_part(zs, r[1], r[4]) for r in q]
            chosen = None
            for perm in itertools.permutations(range(4)):
                maps = ["".join("1" if 3 - k == perm[j] else "0" for k in range(4)) for j in range(4)]
                if mra_lib.interleave(list(zip(ds, maps)), 32) == want:
                    chosen = maps
                    break
            if not chosen:
                sys.exit(f"{setname}: no interleave reproduces gfx 0x{q[0][2]:x}")
            L.append('        <interleave output="32">')
            for r, m in zip(q, chosen):
                L.append(f'            <part name="{r[1]}" crc="{r[4]:08x}" map="{m}"/>')
            L.append('        </interleave>')
            pos += 4 * q[0][3]
    pad_to(len(img), "gfx region past its last ROM")
    assert pos == len(img), (hex(pos), hex(len(img)))

    hrt = setname == "hrthouse"
    mod0 = gid | ((0 if prg2 else 1) << 4)          # [2:0] game, [4] a 1 MB program (0xfff00000)
    game = BUTTONS[SETS[setname][0] or setname]
    boost = VOL_BOOST.get(SETS[setname][0] or setname, 0)
    btn_names = ",".join(game[:4] + ["Start", "Coin", "Pause", "Service Coin", "Service Mode"] + game[4:])
    btn_def = ",".join(["A", "B", "X", "Y"][:min(4, len(game))] + ["Start", "Select", "L", "R"])
    title = info["title"]
    xml = [
        "<misterromdescription>",
        "    <!-- Generated by scripts/build_mra_lm.py from MAME limenko.cpp; the layout is",
        "         rtl/lm_sdram_map.svh. Do not edit by hand. -->",
        f"    <name>{escape(title)}</name>",
        f"    <setname>{setname}</setname>",
        "    <rbf>Limenko</rbf>",
        f"    <mameversion>{bm.mame_version()}</mameversion>",
        f"    <year>{info['year']}</year>",
        f"    <manufacturer>{escape(info['manufacturer'])}</manufacturer>",
        "    <category>Arcade</category>",
        "    <rotation>horizontal</rotation>",
        f'    <buttons names="{btn_names}" default="{btn_def}" count="{len(game)}"/>',
        "",
        "    <!-- mod byte (rtl/lm_main.sv): [2:0] game (0 dynabomb, 1 sb2003, 2 legendoh, 3 hrthouse,",
        "         4 spotty), [4] a 1 MB program at 0xfff00000 -->",
        f'    <rom index="1"><part>{mod0:02X}</part></rom>',
        "",
        ("    <!-- byte 0 bit 0: IN2 bit 29 (limenko.cpp INPUT_PORTS) -->" if spotty else
         "    <!-- byte 0 bit 0: IN2 bit 29 (limenko.cpp INPUT_PORTS); bits 3:1 the QS1000's output shift -->"),
        f'    <switches default="{"01" if spotty else f"{boost << 1:02X}"}" base="0">',
        ('        <dip bits="0" name="Demo Sounds" ids="Off,On"/>' if spotty
         else '        <dip bits="0" name="Sound Enable" ids="On,Off"/>'),
        *([] if spotty else [f'        <dip bits="1,3" name="Volume Boost" ids="{VOL_BOOST_IDS}"/>']),
        "    </switches>",
        "",
        "    <!-- address: the HPS puts the image in DDR3 and the core copies it to SDRAM -->",
        f'    <rom index="0" zip="{"|".join(names)}" md5="none" address="0x30000000">',
        *L,
        "    </rom>",
        "",
        f'    <nvram index="2" size="{0x80 + (0x1000 if hrt else 0)}"/>',   # the EEPROM, then hrthouse's NVRAM
        "</misterromdescription>",
        "",
    ]

    def safe(t):
        return re.sub(r'[\\/:*?"<>|]', "-", t)
    parent = SETS[setname][0]
    pgame = re.sub(r"\s*\([^()]*\)\s*$", "", game_info(text, parent)["title"]) if parent else ""
    folder = OUT_DIR / "_alternatives" / ("_" + safe(pgame)) if parent else OUT_DIR
    fname = folder / (safe(title) + ".mra")
    folder.mkdir(parents=True, exist_ok=True)
    tmp = folder / (fname.name + ".tmp")
    tmp.write_text("\n".join(xml), encoding="utf-8", newline="\n")
    got = mra_lib.build_image(str(tmp), [str(p) for p in paths])
    for z in zs:
        z.close()
    if got != img:
        diff = next((i for i in range(min(len(got), len(img))) if got[i] != img[i]), min(len(got), len(img)))
        tmp.unlink()
        sys.exit(f"{setname}: the .mra image differs from the ROM_START image at 0x{diff:x} "
                 f"({len(got)} vs {len(img)} bytes)")
    if write:
        tmp.replace(fname)
        print(f"{setname}: {fname.name}, image {len(img)} bytes, identical to ROM_START")
    else:
        tmp.unlink()
        print(f"{setname}: image {len(img)} bytes, identical to ROM_START (not written)")
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--image", nargs=2, metavar=("SET", "OUT"))
    a = ap.parse_args()
    sm = sdram_map()
    if a.image:
        img = build(a.image[0], sm, write=False)
        if img is False:
            return 1
        Path(a.image[1]).write_bytes(img)
        print(f"wrote {a.image[1]}")
        return 0
    ok = True
    for s in a.sets or list(SETS):
        if s not in SETS:
            sys.exit(f"unknown set {s}")
        ok = build(s, sm, write=not a.check) is not False and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
