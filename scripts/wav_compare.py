#!/usr/bin/env python3
"""Compare two 16-bit stereo WAV files of the same run: alignment, correlation and level.

    python scripts/wav_compare.py <reference.wav> <test.wav> [--from 1.0] [--seconds 20] [--window 2]

Both are resampled to the reference's rate if they differ (linear). The test is aligned to the reference by
the lag of the cross-correlation peak (searched within +-0.25 s); then, per channel, the correlation
coefficient and the RMS ratio (test / reference) over the compared span, and per window of --window seconds
the worst correlation, so a stretch that is wrong shows up even when the whole is close.
"""
import argparse
import sys
import wave

import numpy as np


def load(path):
    with wave.open(path, "rb") as w:
        n, ch, sw, rate = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
        if sw != 2:
            sys.exit(f"{path}: {8 * sw}-bit, need 16")
        a = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64).reshape(-1, ch)
    if ch == 1:
        a = np.repeat(a, 2, axis=1)
    return a, rate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref")
    ap.add_argument("test")
    ap.add_argument("--from", dest="start", type=float, default=1.0)
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--window", type=float, default=2.0)
    a = ap.parse_args()
    r, rate = load(a.ref)
    t, trate = load(a.test)
    if trate != rate:
        x = np.arange(0, len(t) * rate / trate) * trate / rate
        t = np.stack([np.interp(x, np.arange(len(t)), t[:, c]) for c in range(2)], axis=1)
    s0 = int(a.start * rate)
    n = min(int(a.seconds * rate), len(r) - s0, len(t) - s0) - rate // 2
    ref = r[s0:s0 + n].sum(axis=1)
    best, lag = -2.0, 0
    maxlag = rate // 4
    seg = t[:, 0] + t[:, 1]
    for L in range(-maxlag, maxlag + 1, 4):   # coarse
        if s0 + L < 0:
            continue
        c = np.corrcoef(ref, seg[s0 + L:s0 + L + n])[0, 1]
        if c > best:
            best, lag = c, L
    for L in range(lag - 4, lag + 5):          # fine
        if s0 + L < 0:
            continue
        c = np.corrcoef(ref, seg[s0 + L:s0 + L + n])[0, 1]
        if c > best:
            best, lag = c, L
    print(f"lag {lag} samples ({1000 * lag / rate:.2f} ms), {n / rate:.1f} s compared from {a.start} s")
    for c, name in ((0, "left"), (1, "right")):
        x = r[s0:s0 + n, c]
        y = t[s0 + lag:s0 + lag + n, c]
        cc = np.corrcoef(x, y)[0, 1] if x.std() > 0 and y.std() > 0 else float("nan")
        rms = np.sqrt((y ** 2).mean()) / max(np.sqrt((x ** 2).mean()), 1e-9)
        w = int(a.window * rate)
        worst = min((np.corrcoef(x[i:i + w], y[i:i + w])[0, 1], i) for i in range(0, n - w, w)
                    if x[i:i + w].std() > 50 and y[i:i + w].std() > 0) if n > w else (cc, 0)
        print(f"  {name}: correlation {cc:.4f}, RMS ratio {rms:.3f}; worst {a.window:g} s window "
              f"{worst[0]:.4f} at {a.start + worst[1] / rate:.1f} s")


if __name__ == "__main__":
    main()
