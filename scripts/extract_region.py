#!/usr/bin/env python3
"""Write one ROM region of a set, as MAME's ROM_START builds it, to a file.

    python scripts/extract_region.py vamphalf oki1 debug/ymoki/vamphalf_oki1.bin

Uses build_mra.py's reader of the driver's ROM_START blocks and its loader; the set's zip (and its parent's)
come from build_mra.ROMDIRS.
"""
import re
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import build_mra as bm  # noqa: E402


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    setname, region, out = sys.argv[1:]
    text = bm.DRIVER.read_text(encoding="utf-8", errors="replace")
    body = bm.ers.blocks(text)[setname]
    m = re.search(r'GAME\(\s*\d+\s*,\s*' + re.escape(setname) + r'\s*,\s*(\w+)', text)
    parent = m.group(1) if m and m.group(1) != "0" else None
    paths = [d / (n + ".zip") for n in [setname] + ([parent] if parent else []) for d in bm.ROMDIRS
             if (d / (n + ".zip")).exists()]
    if not paths:
        sys.exit(f"{setname}: no zip")
    zs = [zipfile.ZipFile(p) for p in paths]
    recs, unknown = bm.ers.region_records(body, region)
    if unknown:
        sys.exit(f"{setname}: region {region}: unparsed {unknown}")
    data = bm.load_region(zs, recs, bm.region_size(body, region))
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_bytes(data)
    print(f"{out}: {len(data)} bytes")


if __name__ == "__main__":
    main()
