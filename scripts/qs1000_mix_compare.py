#!/usr/bin/env python3
"""The whole-board bench's sound against the model, tick for tick.

    python scripts/qs1000_mix_compare.py <set> <wave.txt> <mix.txt>

<wave.txt> and <mix.txt> are sim/sys_tb's +wave and +mix outputs of one run: the wavetable register
writes the bench's 8052 made, stamped with the tick they precede, and the RTL engine's left and right
sums per tick. The writes are replayed through scripts/qs1000_model.py and every tick from the first
write on is compared. This checks the engine inside the board (SDRAM latency and contention on port
1, the 8052's write timing) where sim/qs1000v_tb checks it alone.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import qs1000_model  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("wave")
    ap.add_argument("mix")
    a = ap.parse_args()
    rtl = {}
    for ln in open(a.mix):
        t, l, r = ln.split()
        rtl[int(t)] = (int(l), int(r))
    writes = qs1000_model.load_writes(a.wave)
    if not writes:
        sys.exit("no writes in " + a.wave)
    t0 = writes[0][0]
    last = max(rtl)
    q = qs1000_model.QS1000(qs1000_model.sample_rom(a.set))
    wi = bad = n = nz = 0
    for t in range(t0, last + 1):
        while wi < len(writes) and writes[wi][0] <= t:
            q.write(writes[wi][1], writes[wi][2])
            wi += 1
        m = q.sample()
        g = rtl.get(t)
        if g is None:
            continue
        n += 1
        nz += m != (0, 0)
        if g != m:
            if bad < 10:
                print(f"tick {t}: RTL {g[0]} {g[1]}, model {m[0]} {m[1]}")
            bad += 1
    print(f"{n} ticks compared from tick {t0} ({nz} with sound), {bad} differ; {wi} of {len(writes)} writes applied")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
