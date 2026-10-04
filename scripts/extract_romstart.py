#!/usr/bin/env python3
"""Extract a set's ROM_START records for one region straight from the MAME driver.

    python scripts/extract_romstart.py --emit           # the maincpu SETS table
    python scripts/extract_romstart.py <set> <set>      # just these
    python scripts/extract_romstart.py --region gfx1 <set>
    python scripts/extract_romstart.py --driver path/to/driver.cpp --emit

The driver is MAME_SRC (mister.env or the environment) unless --driver is given.

WHY EXTRACT RATHER THAN TYPE
----------------------------
Hand transcription of ROM loads is the interleave-by-reasoning mistake in
slower motion: dozens of sets, several load forms, and offsets that differ by
one between the even and odd ROM of a pair. The driver is the authority.

What this understands (add a driver's own load macros to KINDS):

    ROM_LOAD16_BYTE       one byte lane; dest & 1 selects even or odd
    ROM_LOAD16_WORD_SWAP  whole words, byte-swapped, no pairing
    ROM_LOAD              plain, byte for byte
    ROM_LOAD24_BYTE       one byte every THREE, from dest
    ROM_LOAD24_WORD_SWAP  two byte-swapped bytes every three, from dest
    ROM_CONTINUE          the rest of the PREVIOUS file, at another offset

It deliberately does NOT try to be a general MAME ROM loader. Anything it does
not recognise is reported rather than skipped, so a set is never emitted with a
record silently missing -- which would produce an image that is subtly short
and still looks plausible.
"""
import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coretools import setting   # noqa: E402

SRC = setting("MAME_SRC") or ""

# --- core-specific: edit for this core -------------------------------------
# Load macros the driver uses -> the record kind emitted. Anything in a
# region that is not listed here is reported, not skipped. A driver's own
# macros (ROM_LOAD24_*, ...) go here too.
KINDS = {
    "ROM_LOAD16_BYTE": "load16_byte",
    "ROM_LOAD16_WORD_SWAP": "load16_wswap",
    "ROM_LOAD": "load",
    "ROM_LOAD16_WORD": "load",         # bytes as they are in the file
    "ROM_LOAD32_BYTE": "load32_byte",
    "ROM_LOAD32_WORD": "load32_word",
    # ROM_COPY("src", srcofs, dstofs, len) takes bytes from ANOTHER region
    # rather than from a file, so it carries no CRC.
    "ROM_COPY": "copy",
}
# The sets in scope: the default when none are named.
IN_SCOPE = []
# ---------------------------------------------------------------------------


def blocks(text):
    out = {}
    for m in re.finditer(r"ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END", text, re.S):
        out[m.group(1)] = m.group(2)
    return out


def region_records(body, want="maincpu"):
    """Records for ONE named region, plus anything in it that did not parse.

    The region argument exists because the sprite and tile images need the same
    treatment the program ROM got: "gfx1" is loaded with the same four record
    kinds, and hand-transcribing it would reintroduce exactly the risk this
    script was written to remove.
    """
    records, unknown = [], []
    region = None
    for raw in body.split("\n"):
        line = raw.split("//")[0].strip()
        if not line:
            continue
        m = re.match(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"', line)
        if m:
            region = m.group(2)
            continue
        if region != want:
            continue
        # ROM_COPY has four numeric-ish arguments and a region name in the
        # first slot, so it matches the same shape with a different meaning:
        # (src region, src offset, dest offset, length).
        mc = re.match(r'ROM_COPY\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                      r'\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)', line)
        if mc:
            records.append(("copy", mc.group(1), int(mc.group(3), 16),
                            int(mc.group(4), 16), None,
                            int(mc.group(2), 16)))
            continue

        # Some drivers write `ROM_LOAD24_BYTE     ( "x.u65", ...` with space
        # around the paren; a record that does not parse lands in `unknown`.
        m = re.match(r'(\w+)\s*\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                     r'\s*(0x[0-9a-fA-F]+)(.*)', line)
        if m and m.group(1) in KINDS:
            # The CRC is what actually identifies a dump. In a MERGED romset a
            # ROM is stored ONCE and found by hash, so the filename is not a
            # reliable key.
            crc = re.search(r'CRC\((\w+)\)', m.group(5))
            records.append((KINDS[m.group(1)], m.group(2),
                            int(m.group(3), 16), int(m.group(4), 16),
                            int(crc.group(1), 16) if crc else None))
            continue
        m = re.match(r'ROM_CONTINUE\s*\(\s*(0x[0-9a-fA-F]+)\s*,'
                     r'\s*(0x[0-9a-fA-F]+)', line)
        if m:
            records.append(("continue", None,
                            int(m.group(1), 16), int(m.group(2), 16), None))
            continue
        # ROM_RELOAD(dest, length): the previous file again, from its start
        m = re.match(r'ROM_RELOAD\s*\(\s*(0x[0-9a-fA-F]+)\s*,'
                     r'\s*(0x[0-9a-fA-F]+)', line)
        if m:
            records.append(("reload", None,
                            int(m.group(1), 16), int(m.group(2), 16), None))
            continue
        if line.startswith(("ROM_LOAD", "ROM_CONTINUE", "ROMX_LOAD", "ROM_FILL",
                            "ROM_RELOAD", "ROM_IGNORE", "ROM_COPY")):
            unknown.append(line)
    return records, unknown


def maincpu_records(body):
    """The original entry point, kept because callers import it by name."""
    return region_records(body, "maincpu")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*", help="default: every in-scope set")
    ap.add_argument("--region", default="maincpu",
                    help="ROM_REGION to extract (maincpu, gfx1, ...)")
    ap.add_argument("--emit", action="store_true",
                    help="print a Python SETS table ready to paste")
    ap.add_argument("--driver", help="the MAME driver .cpp (default: MAME_SRC)")
    a = ap.parse_args()

    src = a.driver or SRC
    if not src or not os.path.exists(src):
        sys.exit(f"driver not found at {src!r} (set MAME_SRC or pass --driver)")
    all_blocks = blocks(open(src, encoding="utf8", errors="replace").read())
    wanted = a.sets or IN_SCOPE
    if not wanted:
        sys.exit("name the sets, or fill IN_SCOPE")

    problems = []
    table = {}
    for s in wanted:
        if s not in all_blocks:
            problems.append(f"{s}: no ROM_START in the driver")
            continue
        recs, unknown = region_records(all_blocks[s], a.region)
        if unknown:
            problems.append(f"{s}: {len(unknown)} unrecognised line(s): {unknown[:2]}")
        if not recs:
            problems.append(f"{s}: no {a.region} records found")
            continue
        table[s] = recs

    if a.emit:
        print("SETS = {")
        for s, recs in table.items():
            print(f'    "{s}": [')
            for kind, name, dest, ln, crc, *_ in recs:
                nm = "None" if name is None else f'"{name}"'
                cs = "None" if crc is None else f"{crc:#010x}"
                print(f'        ("{kind}", {nm:38s}, {dest:#08x}, {ln:#07x}, {cs}),')
            print("    ],")
        print("}")
    else:
        for s, recs in table.items():
            print(f"{s}:")
            for r in recs:
                print(f"    {r}")
    for p in problems:
        print("PROBLEM: " + p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
