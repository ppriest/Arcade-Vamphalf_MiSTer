#!/usr/bin/env python3
"""Render a QS1000 capture through scripts/qs1000_model.py as separate stems, by the table entry each voice was
keyed from, for comparing the balance of a PCB recording with MAME's.

    python scripts/qs1000_stems.py misncrft <wave.txt> --from 600 --to 1500 --out debug/pcb/stems \\
        --group shot=01aa0c --group sfx=01a9:01aa

Each stem is the sum of its voices' left and right outputs computed as QS1000.sample computes the mix (the
integer sums before MAME's /4096), box-filtered over 16 ticks to 46.875 kHz like the model's --wav, and written
as <out>_<name>.wav (16-bit, /4096 as MAME scales) and <out>_<name>.npy (float, unscaled). A group's entries
are full 24-bit table addresses or 16-bit prefixes (01a9 = 01a900..01a9ff); voices in no group go to "music".
"""
import argparse
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qs1000_model as qm  # noqa: E402

TPF = 12676              # 750 kHz ticks per frame (59.2 Hz)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("wave")
    ap.add_argument("--from", dest="lo", type=int, default=0, help="first frame (750 kHz ticks / 12676)")
    ap.add_argument("--to", dest="hi", type=int, required=True)
    ap.add_argument("--group", action="append", default=[], help="name=entry[:entry...]")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    groups = []
    for g in a.group:
        name, ents = g.split("=")
        groups.append((name, [int(e, 16) for e in ents.split(":")], [len(e) for e in ents.split(":")]))
    names = [g[0] for g in groups] + ["music"]

    def group_of(entry):
        for i, (name, ents, lens) in enumerate(groups):
            for e, n in zip(ents, lens):
                if (n <= 4 and entry >> 8 == e) or entry == e:
                    return i
        return len(groups)

    q = qm.QS1000(qm.sample_rom(a.set))
    writes = qm.load_writes(a.wave)
    owner = [len(groups)] * 32
    orig = q.start_voice

    def sv(ch):
        w = q.wave
        owner[ch] = group_of((w[1] << 16) | (w[2] << 8) | w[3])
        orig(ch)

    q.start_voice = sv
    n_out = (a.hi - a.lo) * TPF // 16
    out = np.zeros((len(names), n_out, 2))
    acc = np.zeros((len(names), 2))
    wi = 0
    k = 0
    for t in range(writes[0][0], a.hi * TPF):
        while wi < len(writes) and writes[wi][0] <= t:
            q.write(writes[wi][1], writes[wi][2])
            wi += 1
        # QS1000.sample, with each voice's contribution kept apart
        parts = np.zeros((len(names), 2))
        for i, c in enumerate(q.ch):
            if not (c.flags & qm.PLAYING):
                continue
            lvol, rvol, vol = c.regs[6], c.regs[7], c.regs[8]
            if c.addr >= c.loop_end:
                c.flags &= ~qm.PLAYING
                continue
            if c.flags & qm.ADPCM:
                while (c.start + c.adpcm_addr) & 0xffffffff != c.addr:
                    c.adpcm_addr = (c.adpcm_addr + 1) & 0xffffffff
                    if c.start + c.adpcm_addr >= c.loop_end:
                        c.adpcm_addr = (c.loop_start - c.start) & 0xffffffff
                    d = q.rb(c.start + (c.adpcm_addr >> 1))
                    nib = (d if c.adpcm_addr & 1 else d >> 4) & 0xf
                    c.adpcm_signal = c.adpcm.clock(nib)
                res = ((c.adpcm_signal >> 4) + 128 & 0xff) - 128
                parts[owner[i], 0] += res * 4 * lvol * vol
                parts[owner[i], 1] += res * 4 * rvol * vol
            else:
                res = ((q.rb(c.addr) - 128 + 128) & 0xff) - 128
                parts[owner[i], 0] += res * lvol * vol
                parts[owner[i], 1] += res * rvol * vol
            c.acc += c.freq
            c.addr = (c.addr + (c.acc >> 18)) & qm.MASK
            c.acc &= (1 << 18) - 1
        if t < a.lo * TPF:
            continue
        acc += parts
        if (t - a.lo * TPF) % 16 == 15:
            if k < n_out:
                out[:, k, :] = acc / 16
            k += 1
            acc[:] = 0
    base = Path(a.out)
    base.parent.mkdir(parents=True, exist_ok=True)
    for gi, name in enumerate(names):
        np.save(f"{base}_{name}.npy", out[gi])
        pcm = np.clip(np.round(out[gi] / 4096), -32768, 32767).astype("<i2")
        with wave.open(f"{base}_{name}.wav", "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(46875)
            w.writeframes(pcm.tobytes())
        rms = np.sqrt((out[gi] ** 2).mean()) / 4096
        print(f"{name}: RMS {rms:.1f} (16-bit units at MAME's /4096), peak {np.abs(out[gi]).max() / 4096:.0f}")


if __name__ == "__main__":
    main()
