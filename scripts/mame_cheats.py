#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME cheats (Pugsy's XML, mamecheat.co.uk) to the .mra's <cheats> codes.

    python scripts/mame_cheats.py <set>              # what converts, what does not
    python scripts/mame_cheats.py <set> --mra        # the <cheats> block

The codes are for wickerwaka's read-override cheat engine (references/cheats.md in the
skill): a code replaces, ORs or ANDs a value as the CPU reads it, nothing is written. Each
<cheat> whose scripts only store constants into the CPU's RAM converts:

    maincpu.pb@C08123=03                         replace a byte (pw, pd: word, long)
    maincpu.pb@C08123=maincpu.pb@C08123|80       OR   (& for AND)

A cheat with a <parameter> item list becomes one cheat per item ("Select Stage: 3"). A "run"
script is what the engine does anyway; an "on"/"change" script, which MAME runs once, becomes
the same constant held while the cheat is on (say so in the README). Conditions, temporary
variables, arithmetic, other CPUs and ROM patches are skipped and listed.

A code is 16 bytes, big-endian: flags (method << 8 | size << 4 | compare), address, compare,
data. The engine matches aligned codes only, so a long not on a 4-byte boundary becomes two
words and a word at an odd address two bytes.

Per core (the environment, the core's mister.env or ~/.mister-core.env, or the arguments):

    CHEAT_CPU    the CPU tag in the cheat scripts             (default maincpu)
    CHEAT_RAM    the address ranges the engine sits on, hex   (e.g. C00000-C1FFFF,FF0000-FFFFFF)
    CHEAT_MAX    codes the core's engine holds                (default 16; the .mra's max)
    MAME_CHEATS  the cheat files: a directory of <set>.xml, or cheat.7z/cheat.zip
                 (default: MAME's cheatpath from mame.ini, under MAME_DIR)

A core's .mra generator imports this and calls cheats(set) and mra_block(good).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coretools  # noqa: E402

SIZE = {"b": 1, "w": 2, "d": 4}


def config():
    cpu = coretools.setting("CHEAT_CPU", "maincpu")
    ram = []
    for r in (coretools.setting("CHEAT_RAM", "") or "").split(","):
        if "-" in r:
            lo, hi = r.split("-")
            ram.append((int(lo, 16), int(hi, 16) + 1))
    return cpu, ram, int(coretools.setting("CHEAT_MAX", "16"))


def read_7z(arc, member):
    """A member of a .7z: py7zr if installed, else libarchive's tar (Windows' own tar.exe,
    or bsdtar), which reads 7z. None if it is not there."""
    try:
        import py7zr
    except ImportError:
        tar = shutil.which("bsdtar") or Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32" / "tar.exe"
        if not Path(tar).exists():
            sys.exit(f"{arc}: reading a 7z needs `pip install py7zr`, bsdtar, or the archive unpacked")
        r = subprocess.run([str(tar), "-xOf", str(arc), member], capture_output=True)
        return r.stdout.decode("utf-8", errors="replace") if r.returncode == 0 else None
    with py7zr.SevenZipFile(arc) as z:
        names = [n for n in z.getnames() if Path(n).name == member]
        return z.read(names)[names[0]].read().decode("utf-8", errors="replace") if names else None


def cheat_xml(setname):
    """The set's cheat XML text, or None."""
    base = coretools.setting("MAME_CHEATS", None)
    if base:
        bases = [Path(base)]
    else:
        mdir = coretools.mame_dir()
        cp = "cheat"
        ini = mdir / "mame.ini"
        if ini.exists():
            for ln in ini.read_text(errors="replace").splitlines():
                if ln.startswith("cheatpath"):
                    cp = ln.split(None, 1)[1].strip().split(";")[0]
        bases = [mdir / cp, mdir]
    for b in bases:
        f = b / f"{setname}.xml"
        if f.exists():
            return f.read_text(encoding="utf-8", errors="replace")
        for arc in (b.with_suffix(".zip"), b.with_suffix(".7z"), b / "cheat.zip", b / "cheat.7z"):
            if not arc.is_file():
                continue
            if arc.suffix == ".zip":
                with zipfile.ZipFile(arc) as z:
                    for n in z.namelist():
                        if Path(n).name == f"{setname}.xml":
                            return z.read(n).decode("utf-8", errors="replace")
            else:
                text = read_7z(arc, f"{setname}.xml")
                if text is not None:
                    return text
    return None


def _value(expr, param):
    expr = expr.strip()
    if expr.lower() == "param":
        return param
    m = re.fullmatch(r"(?:0x)?([0-9A-Fa-f]+)", expr)
    return int(m.group(1), 16) if m else None


def _codes(size, addr, method, val):
    """[(flags, addr, compare, data)], split to the engine's alignments."""
    if size == 4 and addr % 4:
        return _codes(2, addr, method, val >> 16) + _codes(2, addr + 2, method, val & 0xFFFF)
    if size == 2 and addr % 2:
        return _codes(1, addr, method, val >> 8) + _codes(1, addr + 1, method, val & 0xFF)
    return [((method << 8) | (size << 4), addr, 0, val & ((1 << (8 * size)) - 1))]


def _convert(cheat, param, cpu, ram, nmax):
    act = re.compile(rf"^\s*{re.escape(cpu)}\.p([bwd])@([0-9A-Fa-f]+)\s*=\s*(.+?)\s*$")
    op = re.compile(rf"^{re.escape(cpu)}\.p([bwd])@([0-9A-Fa-f]+)([|&])(?:0x)?([0-9A-Fa-f]+)$")
    out = []
    for sc in cheat.findall("script"):
        state = sc.get("state", "run")
        if state == "off":
            continue
        if state not in ("run", "on", "change"):
            return None, f"script state {state}"
        for a in sc.findall("action"):
            if a.get("condition"):
                return None, "a condition"
            for part in (a.text or "").split(","):
                if not part.strip():
                    continue
                m = act.match(part)
                if not m:
                    return None, f"not a constant store: {part.strip()}"
                size, addr, rhs = SIZE[m.group(1)], int(m.group(2), 16), m.group(3)
                if ram and not any(lo <= addr < hi for lo, hi in ram):
                    return None, f"address {addr:06x} outside CHEAT_RAM"
                o = op.match(rhs.replace(" ", ""))
                if o and SIZE[o.group(1)] == size and int(o.group(2), 16) == addr:
                    method, v = (1 if o.group(3) == "|" else 2), int(o.group(4), 16)
                else:
                    method, v = 0, _value(rhs, param)
                    if v is None:
                        return None, f"an expression: {rhs}"
                out += _codes(size, addr, method, v)
    if not out:
        return None, "no stores"
    if len(out) > nmax:
        return None, f"{len(out)} codes, the core holds {nmax}"
    return out, None


def cheats(setname, cpu=None, ram=None, nmax=None):
    """[(name, codes)] that convert, [(name, reason)] that do not; None, None without a file."""
    c_cpu, c_ram, c_max = config()
    cpu, ram, nmax = cpu or c_cpu, ram if ram is not None else c_ram, nmax or c_max
    text = cheat_xml(setname)
    if text is None:
        return None, None
    good, bad = [], []
    for c in ET.fromstring(text).iter("cheat"):
        desc = (c.get("desc") or "").strip()
        if not desc or not c.findall("script"):
            continue                                     # a heading or a note
        par = c.find("parameter")
        if par is None:
            codes, why = _convert(c, None, cpu, ram, nmax)
            (good.append((desc, codes)) if codes else bad.append((desc, why)))
            continue
        items = par.findall("item")
        if not items:
            bad.append((desc, "a ranged parameter"))
            continue
        for it in items:
            codes, why = _convert(c, _value(it.get("value", ""), None), cpu, ram, nmax)
            name = f"{desc}: {(it.text or '').strip()}"
            (good.append((name, codes)) if codes else bad.append((name, why)))
    return good, bad


def mra_block(good, nmax=None, indent="    "):
    """The <cheats> element, or "" when there is nothing to put in it."""
    if not good:
        return ""
    nmax = nmax or config()[2]
    w = max(len(n) for n, _ in good) + 2
    lines = [f'{indent}<cheats size="16" max="{nmax}">']
    for name, codes in good:
        hexs = " ".join(f"{f:08X} {a:08X} {c:08X} {d:08X}" for f, a, c, d in codes)
        nm = name.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")
        lines.append(f'{indent}    <cheat name="{nm}"{" " * (w - len(name) - 2)}>{hexs}</cheat>')
    lines.append(f"{indent}</cheats>")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set")
    ap.add_argument("--mra", action="store_true", help="print the <cheats> block")
    ap.add_argument("--cpu", help="CHEAT_CPU")
    ap.add_argument("--ram", help="CHEAT_RAM, e.g. C00000-C1FFFF")
    ap.add_argument("--max", type=int, help="CHEAT_MAX")
    a = ap.parse_args()
    ram = None
    if a.ram:
        ram = [(int(lo, 16), int(hi, 16) + 1) for lo, hi in (r.split("-") for r in a.ram.split(","))]
    good, bad = cheats(a.set, a.cpu, ram, a.max)
    if good is None:
        sys.exit(f"no cheats for {a.set}: set MAME_CHEATS, or install Pugsy's cheat.7z in MAME's cheatpath")
    if a.mra:
        sys.stdout.write(mra_block(good, a.max))
        return
    print(f"{a.set}: {len(good)} cheats convert, {len(bad)} do not")
    for n, codes in good:
        print(f"  + {n}  ({len(codes)} code{'s' if len(codes) > 1 else ''})")
    for n, why in bad:
        print(f"  - {n}: {why}")


if __name__ == "__main__":
    main()
