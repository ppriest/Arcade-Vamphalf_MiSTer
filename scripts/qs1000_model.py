#!/usr/bin/env python3
"""MAME's QS1000 wavetable engine (devices/sound/qs1000.cpp, 0.289), sample for sample at 24 MHz / 32.

    python scripts/qs1000_model.py <set> <wave.txt> [--ticks N] [--wav out.wav] [--mix mix.txt]

<wave.txt> is scripts/mame_qs1000_wave.py's capture (each write to 0x200-0x211 with its 750 kHz tick).
The sample ROM is the set's "qs1000" region as the .mra loads it (scripts/build_mra.py --image,
SD_SAMPLES). A write stamped with tick T is applied before sample T is produced, as wave_w updates the
stream to the write's time first.

--mix writes the left/right sums of every tick ("<tick> <left> <right>", the integer sums before MAME's
/4096 scaling) for the RTL bench; --wav writes a 48 kHz 16-bit stereo file decimated by a 16-tick box
filter, for listening and for comparison with MAME's own -wavwrite.

Transcribed, including MAME's limits: no envelopes, no filter, looping disabled (a voice stops at
its loop end), pitch only from the table entry, key-off only clears a flag nothing reads.
"""
import argparse
import math
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

MASK = 0xffffff
KEYON, PLAYING, ADPCM = 1, 2, 4

# okiadpcm.cpp compute_tables
NBL2BIT = [[1, 0, 0, 0], [1, 0, 0, 1], [1, 0, 1, 0], [1, 0, 1, 1], [1, 1, 0, 0], [1, 1, 0, 1], [1, 1, 1, 0], [1, 1, 1, 1],
           [-1, 0, 0, 0], [-1, 0, 0, 1], [-1, 0, 1, 0], [-1, 0, 1, 1], [-1, 1, 0, 0], [-1, 1, 0, 1], [-1, 1, 1, 0], [-1, 1, 1, 1]]
DIFF = []
for step in range(49):
    stepval = math.floor(16.0 * pow(11.0 / 10.0, step))
    for nib in range(16):
        b = NBL2BIT[nib]
        DIFF.append(b[0] * (stepval * b[1] + stepval // 2 * b[2] + stepval // 4 * b[3] + stepval // 8))
INDEX_SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]


class Adpcm:
    def __init__(self):
        self.reset()

    def reset(self):
        self.signal = 0
        self.step = 0

    def clock(self, nib):
        self.signal += DIFF[self.step * 16 + (nib & 15)]
        self.signal = max(-2048, min(2047, self.signal))
        self.step = max(0, min(48, self.step + INDEX_SHIFT[nib & 7]))
        return self.signal


class Chan:
    def __init__(self):
        self.acc = 0
        self.adpcm_signal = 0
        self.start = 0
        self.addr = 0
        self.adpcm_addr = 0
        self.loop_start = 0
        self.loop_end = 0
        self.freq = 0
        self.flags = 0
        self.regs = [0] * 16
        self.adpcm = Adpcm()


class QS1000:
    # (ADPCM, PCM) gain: MAME's (qs1000.cpp:484, :513), or the PCB recording's (MAME_KLUDGES.md, Sound)
    BALANCE = {"mame": (4, 1), "pcb": (2, 4)}

    def __init__(self, rom, balance="mame"):
        self.rom = rom
        self.g_adpcm, self.g_pcm = self.BALANCE[balance]
        self.wave = [0] * 0x12
        self.ch = [Chan() for _ in range(32)]

    def rb(self, a):
        a &= MASK
        return self.rom[a] if a < len(self.rom) else 0

    def write(self, off, data):
        if off == 0:
            ch = self.wave[0xe] & 31
            if data == 0:
                self.ch[ch].regs = list(self.wave[:16])
                self.start_voice(ch)
            elif data == 2:
                self.ch[ch].flags &= ~KEYON
        elif 1 <= off <= 0xd:
            if self.wave[0x11] == 3:
                self.ch[self.wave[0xe] & 31].regs[off] = data
            else:
                self.wave[off] = data
        else:
            self.wave[off] = data

    def start_voice(self, ch):
        c = self.ch[ch]
        r = c.regs
        table = (r[1] << 16) | (r[2] << 8) | r[3]
        freq = (self.rb(table) << 8) | self.rb(table + 1)
        base = (self.rb(table + 4) << 8) | self.rb(table + 5)
        if freq == 0:
            return
        b0 = self.rb(base)
        start = ((b0 << 16) | (self.rb(base + 1) << 8) | self.rb(base + 2)) & MASK
        loop_start = (((b0 & 0xf0) << 16) | (self.rb(base + 3) << 12) | (self.rb(base + 4) << 4) | (self.rb(base + 5) >> 4)) & MASK
        loop_end = (((b0 & 0xf0) << 16) | ((self.rb(base + 5) & 0xf) << 16) | (self.rb(base + 6) << 8) | self.rb(base + 7)) & MASK
        b8 = self.rb(base + 8)
        c.acc = 0
        c.start = start
        c.addr = start
        c.loop_start = loop_start
        c.loop_end = loop_end
        c.freq = freq
        c.flags = PLAYING | KEYON
        if b8 & 0x08:
            c.adpcm.reset()
            c.adpcm_addr = 0xffffffff          # uint32_t -1
            c.flags |= ADPCM

    def sample(self):
        """One tick: the left and right sums (before /4096)."""
        L = R = 0
        for c in self.ch:
            if not (c.flags & PLAYING):
                continue
            lvol, rvol, vol = c.regs[6], c.regs[7], c.regs[8]
            if c.addr >= c.loop_end:
                c.flags &= ~PLAYING
                continue
            if c.flags & ADPCM:
                while (c.start + c.adpcm_addr) & 0xffffffff != c.addr:
                    c.adpcm_addr = (c.adpcm_addr + 1) & 0xffffffff
                    if c.start + c.adpcm_addr >= c.loop_end:
                        c.adpcm_addr = (c.loop_start - c.start) & 0xffffffff
                    d = self.rb(c.start + (c.adpcm_addr >> 1))
                    nib = (d if c.adpcm_addr & 1 else d >> 4) & 0xf
                    c.adpcm_signal = c.adpcm.clock(nib)
                res = c.adpcm_signal >> 4
                res = ((res + 128) & 0xff) - 128     # int8_t
                L += res * self.g_adpcm * lvol * vol
                R += res * self.g_adpcm * rvol * vol
            else:
                res = ((self.rb(c.addr) - 128 + 128) & 0xff) - 128
                L += res * self.g_pcm * lvol * vol
                R += res * self.g_pcm * rvol * vol
            c.acc += c.freq
            c.addr = (c.addr + (c.acc >> 18)) & MASK
            c.acc &= (1 << 18) - 1
        return L, R


def load_writes(path):
    w = []
    for ln in open(path, encoding="utf-8"):
        if ln.startswith("W "):
            _, t, off, d = ln.split()
            w.append((int(t), int(off, 16), int(d, 16)))
    return w


def sample_rom(setname):
    from build_mra import build, sdram_map
    sm = sdram_map()
    img = build(setname, sm, write=False)
    return bytes(img[sm["SD_SAMPLES"]:sm["SD_GFX"]])


def run(setname, wave, ticks=None, mix=None, wav=None, rom=None, balance="mame"):
    rom = rom if rom is not None else sample_rom(setname)
    q = QS1000(rom, balance)
    writes = load_writes(wave)
    t0 = writes[0][0]
    end = ticks if ticks else writes[-1][0] - t0 + 750000
    wi = 0
    mf = open(mix, "w") if mix else None
    out = bytearray()
    accL = accR = 0
    for n in range(end):
        t = t0 + n
        while wi < len(writes) and writes[wi][0] <= t:
            q.write(writes[wi][1], writes[wi][2])
            wi += 1
        L, R = q.sample()
        if mf:
            mf.write(f"{t} {L} {R}\n")
        accL += L
        accR += R
        if (n & 15) == 15:
            l = max(-32768, min(32767, (accL >> 4) >> 12))
            r = max(-32768, min(32767, (accR >> 4) >> 12))
            out += struct.pack("<hh", l, r)
            accL = accR = 0
    if mf:
        mf.close()
    if wav:
        rate = 750000 // 16
        with open(wav, "wb") as f:
            f.write(b"RIFF" + struct.pack("<I", 36 + len(out)) + b"WAVEfmt " +
                    struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16) + b"data" + struct.pack("<I", len(out)))
            f.write(out)
    return q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("wave")
    ap.add_argument("--ticks", type=int)
    ap.add_argument("--mix")
    ap.add_argument("--wav")
    ap.add_argument("--balance", choices=sorted(QS1000.BALANCE), default="mame",
                    help="ADPCM/PCM gains: MAME's, or the PCB recording's (MAME_KLUDGES.md, Sound)")
    a = ap.parse_args()
    run(a.set, a.wave, a.ticks, a.mix, a.wav, balance=a.balance)


if __name__ == "__main__":
    main()
