#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra files and prove each one byte for byte.

    python scripts/build_mra.py                 # every set -> releases/
    python scripts/build_mra.py misncrft        # one set
    python scripts/build_mra.py --check         # verify only, write nothing
    python scripts/build_mra.py --image misncrft out.bin   # write the download image (benches)

The ROM image is the SDRAM layout of rtl/vh_sdram_map.svh, whose SD_* localparams are read here.
Each region is built twice: once by this script's own loader from the driver's ROM_START records
(scripts/extract_romstart.py), and once by re-reading the written .mra with scripts/mra.py
(mra-tools-c's semantics). The two must be identical. The graphics interleave map is not reasoned
about (docs/LESSONS_LEARNED.md): each candidate is tried against the ROM_START image and the one that
reproduces it is written. Where scripts/vamphalf_capture.py has dumped MAME's own "gfx" region
(gfx.bin), the image's graphics are compared with it too.
"""
import argparse
import re
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_romstart as ers     # noqa: E402
import mra as mra_lib              # noqa: E402
from coretools import setting      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DRIVER = Path(setting("MAME_SRC") or "E:/mame/src/mame/misc/vamphalf.cpp")
ROMDIRS = [Path(p) for p in (setting("ROM_DIRS") or "F:/Emulation/roms/MAME ROMs").split(";")]
GFX_DUMPS = {"misncrft": "D:/Arcade-Vamphalf_MiSTer/debug/vcap/misncrft_attract/gfx.bin",
             "wivernwg": "D:/Arcade-Vamphalf_MiSTer/debug/vcap/wivernwg_attract/gfx.bin"}
OUT_DIR = REPO / "releases"

# set: (parent or None, the I/O map family for the mod byte (rtl/vh_main.sv), MAME rotation)
SETS = {
    "misncrft":   (None,       0, 90),
    "misncrfta":  ("misncrft", 0, 90),
    "wivernwg":   (None,       1, 270),
    "wyvernwg":   ("wivernwg", 1, 270),
    "wyvernwga":  ("wivernwg", 1, 270),
    "vamphalf":   (None,       2, 0),
    "vamphalfr1": ("vamphalf", 2, 0),
    "vamphalfk":  ("vamphalf", 2, 0),
    "coolmini":   (None,       3, 0),
    "coolminii":  ("coolmini", 3, 0),
    "dquizgo2":   (None,       3, 0),
    "toyland":    (None,       3, 0),
    "mrkicker":   (None,       4, 0),
    "dtfamily":   (None,       4, 0),
    "jmpbreak":   (None,       5, 0),
    "jmpbreaka":  ("jmpbreak", 5, 0),
    "poosho":     (None,       5, 0),
    "newxpanga":  ("newxpang", 5, 0),
    "newxpang":   (None,       6, 0),
    "mrdig":      (None,       6, 0),
    "suplup":     (None,       7, 0),
    "luplup":     ("suplup",   7, 0),
    "luplup29":   ("suplup",   7, 0),
    "luplup10":   ("suplup",   7, 0),
    "puzlbang":   ("suplup",   7, 0),
    "puzlbanga":  ("suplup",   7, 0),
    "worldadv":   (None,       9, 0),
}
# the families on the E1-32 board (mod byte bit 0)
BUS32 = {1}
CATEGORY = {"misncrft": "Shooter", "wivernwg": "Shooter", "vamphalf": "Platform"}
# Each parent's button names, in the order the core's J1 line reads them (bits 4..7); "-" leaves a
# button unused. MAME's "common" port names none. Wivern Wings: history.xml ("[A] Basic Shot,
# [B] Defense, [C] Special Bomb", 3 buttons). Mission Craft: history.xml gives 4 buttons and no
# names; generic until the game's own screens or manual say (validate_mra --allow-generic-buttons).
BUTTONS = {"misncrft": ["Button 1", "Button 2", "Button 3", "Button 4"],
           "wivernwg": ["Shot", "Defense", "Bomb", "-"],
           "vamphalf": ["Button 1", "Button 2", "Button 3", "Button 4"]}
for _p in ("coolmini", "dquizgo2", "toyland", "mrkicker", "dtfamily", "jmpbreak", "poosho", "newxpang", "mrdig", "suplup",
           "worldadv"):
    BUTTONS[_p] = ["Button 1", "Button 2", "Button 3", "Button 4"]


def sdram_map():
    text = (REPO / "rtl" / "vh_sdram_map.svh").read_text(encoding="utf-8")
    m = dict((k, int(v, 16)) for k, v in re.findall(r"localparam \[26:0\] (SD_\w+)\s*=\s*27'h([0-9a-fA-F]+);", text))
    for k in ("SD_MAINCPU", "SD_SNDCPU", "SD_EEPROM", "SD_SAMPLES", "SD_GFX", "SD_WRAM"):
        if k not in m:
            sys.exit(f"{k} missing from rtl/vh_sdram_map.svh")
    return m


def game_info(text, setname):
    m = re.search(r"GAME\(\s*(\d+)\s*,\s*" + setname + r"\s*,\s*(\w+)\s*,.*?,\s*ROT(\d+)\s*,\s*\"([^\"]*)\"\s*,\s*\"([^\"]*)\"", text)
    if not m:
        sys.exit(f"no GAME line for {setname}")
    return {"year": m.group(1), "rot": int(m.group(3)), "manufacturer": m.group(4), "title": m.group(5)}


def zips_for(setname):
    names = [setname + ".zip"]
    parent = SETS[setname][0]
    if parent:
        names.append(parent + ".zip")
    found = []
    for n in names:
        for d in ROMDIRS:
            if (d / n).exists():
                found.append(d / n)
                break
    return names, found


def read_part(zs, name, crc):
    return mra_lib._zip_read(zs, name, crc)


def load_region(zs, records, size):
    """ROM_START records -> region bytes, as MAME's loader puts them (zero fill)."""
    out = bytearray(size)
    last = None
    for kind, name, dest, length, crc, *rest in records:
        if kind == "load":
            data = read_part(zs, name, crc)
            assert len(data) == length, (name, len(data), length)
            out[dest:dest + length] = data
            last = data
        elif kind == "load32_word":
            data = read_part(zs, name, crc)
            assert len(data) == length, (name, len(data), length)
            for k in range(length // 2):
                out[dest + 4 * k:dest + 4 * k + 2] = data[2 * k:2 * k + 2]
            last = data
        elif kind == "reload":
            out[dest:dest + length] = last[:length]
        else:
            sys.exit(f"record kind {kind} not handled")
    return bytes(out)


def region_size(body, region):
    m = re.search(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"' + re.escape(region) + '"', body)
    return int(m.group(1), 16) if m else 0


def build(setname, sm, write=True):
    text = DRIVER.read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    info = game_info(text, setname)
    family = SETS[setname][1]
    assert info["rot"] == SETS[setname][2], setname
    names, paths = zips_for(setname)
    if not paths:
        print(f"{setname}: no zip found ({' / '.join(names)}); skipped")
        return False
    zs = [zipfile.ZipFile(p) for p in paths]

    rec = {r: ers.region_records(body, r)[0] for r in ("maincpu", "qs1000:cpu", "qs1000", "oki1", "gfx", "eeprom")}
    for r, (recs, unknown) in ((r, ers.region_records(body, r)) for r in rec):
        if unknown:
            sys.exit(f"{setname}: region {r}: unparsed {unknown}")

    # the image this script expects, region by region
    img = bytearray(sm["SD_GFX"] + region_size(body, "gfx"))
    maincpu = load_region(zs, rec["maincpu"], region_size(body, "maincpu"))
    assert len(maincpu) == 0x100000
    img[sm["SD_MAINCPU"]:sm["SD_MAINCPU"] + len(maincpu)] = maincpu
    snd = load_region(zs, rec["qs1000:cpu"], region_size(body, "qs1000:cpu"))[:0x20000]
    img[sm["SD_SNDCPU"]:sm["SD_SNDCPU"] + len(snd)] = snd
    if rec["eeprom"]:
        ee = load_region(zs, rec["eeprom"], region_size(body, "eeprom"))
        assert len(ee) == 128
        img[sm["SD_EEPROM"]:sm["SD_EEPROM"] + 128] = ee
    else:
        # no default image: MAME's 93C46 starts erased (all ones); the download loads the 93C46 from here
        img[sm["SD_EEPROM"]:sm["SD_EEPROM"] + 128] = bytes([0xff]) * 128
    smp_region = "qs1000" if rec["qs1000"] else "oki1"
    samples = load_region(zs, rec[smp_region], region_size(body, smp_region))
    smp_len = sm["SD_GFX"] - sm["SD_SAMPLES"]
    assert not any(samples[smp_len:]), "sample data beyond the space SD_SAMPLES leaves"
    img[sm["SD_SAMPLES"]:sm["SD_GFX"]] = samples[:smp_len]
    gfx = load_region(zs, rec["gfx"], region_size(body, "gfx"))
    img[sm["SD_GFX"]:] = gfx
    img = bytes(img)

    dump = GFX_DUMPS.get(setname)
    if dump and Path(dump).exists():
        ref = Path(dump).read_bytes()
        if ref != gfx:
            diff = next(i for i in range(min(len(ref), len(gfx))) if ref[i] != gfx[i])
            sys.exit(f"{setname}: the ROM_START gfx region differs from MAME's dump {dump} at 0x{diff:x}")
        print(f"{setname}: gfx region identical to MAME's dump ({len(ref)} bytes)")

    # the .mra, part by part
    L = []
    pos = 0

    def pad_to(addr, why):
        nonlocal pos
        if addr > pos:
            L.append(f'        <part repeat="0x{addr - pos:X}">00</part>  <!-- {why} -->')
            pos = addr
        assert pos == addr, (why, hex(pos), hex(addr))

    def part(name, crc, length):
        nonlocal pos
        L.append(f'        <part name="{escape(name)}" crc="{crc:08x}"/>')
        pos += length

    def loads(region, base, limit=None):
        nonlocal pos
        for kind, name, dest, length, crc, *rest in rec[region]:
            if kind == "reload":
                continue
            if limit is not None and dest >= limit:
                continue
            if kind != "load":
                sys.exit(f"{setname}: {region}: {kind} where a plain load was expected")
            pad_to(base + dest, f"{region} 0x{dest:x}")
            part(name, crc, length)

    L.append("        <!-- maincpu -->")
    loads("maincpu", sm["SD_MAINCPU"])
    pad_to(sm["SD_SNDCPU"], "maincpu end")
    if rec["qs1000:cpu"]:
        L.append("        <!-- qs1000:cpu, once -->")
        loads("qs1000:cpu", sm["SD_SNDCPU"])
    pad_to(sm["SD_EEPROM"], "eeprom")
    if rec["eeprom"]:
        L.append("        <!-- eeprom: the 93C46's default image -->")
        loads("eeprom", sm["SD_EEPROM"])
    else:
        L.append('        <part repeat="0x80">FF</part>  <!-- eeprom: none in the set, the 93C46 erased -->')
        pos += 0x80
    pad_to(sm["SD_SAMPLES"], "samples")
    L.append(f"        <!-- {smp_region} samples -->")
    loads(smp_region, sm["SD_SAMPLES"])
    pad_to(sm["SD_GFX"], "gfx")
    L.append("        <!-- gfx: ROM_LOAD32_WORD pairs -->")
    gl = rec["gfx"]
    for i in range(0, len(gl), 2):
        lo, hi = gl[i], gl[i + 1]
        assert lo[0] == hi[0] == "load32_word" and hi[2] == lo[2] + 2 and lo[3] == hi[3], (lo, hi)
        pad_to(sm["SD_GFX"] + lo[2], "gfx")
        want = gfx[lo[2]:lo[2] + 2 * lo[3]]
        dlo, dhi = read_part(zs, lo[1], lo[4]), read_part(zs, hi[1], hi[4])
        chosen = None
        for mlo, mhi in (("0021", "2100"), ("0012", "1200"), ("2100", "0021"), ("1200", "0012")):
            if mra_lib.interleave([(dlo, mlo), (dhi, mhi)], 32) == want:
                chosen = (mlo, mhi)
                break
        if not chosen:
            sys.exit(f"{setname}: no interleave map reproduces gfx 0x{lo[2]:x}")
        L.append('        <interleave output="32">')
        L.append(f'            <part name="{lo[1]}" crc="{lo[4]:08x}" map="{chosen[0]}"/>')
        L.append(f'            <part name="{hi[1]}" crc="{hi[4]:08x}" map="{chosen[1]}"/>')
        L.append('        </interleave>')
        pos += 2 * lo[3]
    pad_to(len(img), "gfx region past its last ROM")
    assert pos == len(img), (hex(pos), hex(len(img)))

    rot = {0: "horizontal", 90: "vertical (cw)", 270: "vertical (ccw)"}[info["rot"]]
    gfx16 = len(gfx) > 0x800000
    mod0 = (1 if family in BUS32 else 0) | ({0: 0, 90: 1, 270: 2}[info["rot"]] << 1) | (family << 3)
    mod1 = 1 if gfx16 else 0
    zipattr = "|".join(names)
    game = BUTTONS[SETS[setname][0] or setname]
    named = [n for n in game if n != "-"]
    btn_names = ",".join(game + ["Start", "Coin", "Pause", "Service"])
    btn_def = ",".join(["A", "B", "X", "Y"][:len(named)] + ["Start", "Select", "L", "R"])
    title = info["title"]
    xml = [
        "<misterromdescription>",
        "    <!-- Generated by scripts/build_mra.py from MAME vamphalf.cpp; the layout is",
        "         rtl/vh_sdram_map.svh. Do not edit by hand. -->",
        f"    <name>{escape(title)}</name>",
        f"    <setname>{setname}</setname>",
        "    <rbf>Vamphalf</rbf>",
        f"    <mameversion>{mame_version()}</mameversion>",
        f"    <year>{info['year']}</year>",
        f"    <manufacturer>{escape(info['manufacturer'])}</manufacturer>",
        f"    <category>{CATEGORY.get(SETS[setname][0] or setname, 'Arcade')}</category>",
        f"    <rotation>{rot}</rotation>",
        f'    <buttons names="{btn_names}" default="{btn_def}" count="{len(named)}"/>',
        "",
        "    <!-- mod bytes (Vamphalf.sv): [0] E1-32 board, [2:1] rotation, [7:3] I/O map family;",
        "         second byte [0] 16-bit sprite codes (gfx above 8 MB) -->",
        f'    <rom index="1"><part>{mod0:02X} {mod1:02X}</part></rom>',
        "",
        "    <!-- address: the HPS puts the image in DDR3 and the core copies it to SDRAM (rtl/memory/vh_rom_loader.sv) -->",
        f'    <rom index="0" zip="{zipattr}" md5="none" address="0x30000000">',
        *L,
        "    </rom>",
        "",
        '    <nvram index="2" size="128"/>',
        "</misterromdescription>",
        "",
    ]
    # the parent's .mra in releases/, a clone's in releases/_alternatives/_<the parent's title>/ (CONVENTIONS)
    def safe(t):
        return re.sub(r'[\\/:*?"<>|]', "-", t)
    parent = SETS[setname][0]
    # the game's name: the parent's description without its trailing "(version ...)" / "(set 1)", as Seta and Fuuki
    game = re.sub(r"\s*\([^()]*\)\s*$", "", game_info(text, parent)["title"]) if parent else ""
    folder = OUT_DIR / "_alternatives" / ("_" + safe(game)) if parent else OUT_DIR
    fname = folder / (safe(title) + ".mra")
    tmp = folder / (fname.name + ".tmp")
    folder.mkdir(parents=True, exist_ok=True)
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


_MAME_VERSION = None


def mame_version():
    global _MAME_VERSION
    if _MAME_VERSION:
        return _MAME_VERSION
    import subprocess
    exe = Path(setting("MAME_DIR") or "C:/Emulation/Emulators/MAME") / (setting("MAME_EXE") or "mame.exe")
    try:
        out = subprocess.run([str(exe), "-version"], capture_output=True, text=True, timeout=30).stdout
    except OSError:
        out = ""
    m = re.match(r"\s*0\.(\d+)", out)
    if not m:
        sys.exit(f"cannot read the MAME version from {exe}")
    _MAME_VERSION = "%04d" % int(m.group(1))
    return _MAME_VERSION


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
        r = build(s, sm, write=not a.check)
        ok = ok and r is not False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
