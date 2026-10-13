#!/usr/bin/env python3
"""The QS1000 wavetable engine as rtl/qs1000/vh_qs1000_voice.sv has it, sample for sample at 24 MHz / 32:
MAME's (devices/sound/qs1000.cpp, 0.289) with IMA ADPCM decoding (--adpcm oki for MAME's).

    python scripts/qs1000_model.py <set> <wave.txt> [--ticks N] [--wav out.wav] [--mix mix.txt]

<wave.txt> is scripts/mame_qs1000_wave.py's capture (each write to 0x200-0x211 with its 750 kHz tick).
The sample ROM is the set's "qs1000" region as the .mra loads it (scripts/build_mra.py --image,
SD_SAMPLES). A write stamped with tick T is applied before sample T is produced, as wave_w updates the
stream to the write's time first.

--mix writes the left/right sums of every tick ("<tick> <left> <right>", the integer sums before MAME's
/4096 scaling) for the RTL bench; --wav writes a 48 kHz 16-bit stereo file decimated by a 16-tick box
filter, for listening and for comparison with MAME's own -wavwrite.

Transcribed from MAME, with its limits: no envelopes, no filter, looping disabled (a voice stops at
its loop end), pitch only from the table entry, key-off only clears a flag nothing reads. ADPCM is IMA's,
high nibble first, its 16-bit signal wrapping, the output signal >> 8 (OKI's 12-bit signal >> 4 with
--adpcm oki); Arcade-Eolith_MiSTer docs/QS1000_FEATURES.md, A firmware reading.
--loop pcb is vh_qs1000_voice's loop_pcb (Arcade-Eolith_MiSTer docs/QS1000_FEATURES.md, Recording): a voice
at its loop end goes back to its loop start, ADPCM with the decoder state it had before the loop start's
nibble (MAME's disabled save/restore); key-off fades it, env -= env >> 8 on every 732nd tick, the voice
volume times env >> 8, >> 8, stopped once env >> 8 is 0; and [204] bends the pitch: the rate x bendmul([204])
>> 14, x (1 + v/128) up and x (1 - v/256) down (MAME ignores [204]).
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


# IMA ADPCM (vh_qs1000_voice.sv): its 89-step table, the 16-bit signal wrapping instead of saturating
IMA_STEP = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
            97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
            724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
            4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
            18500, 20350, 22385, 24623, 27086, 29794, 32767]


class AdpcmIma:
    def __init__(self):
        self.reset()

    def reset(self):
        self.signal = 0
        self.step = 0

    def clock(self, nib):
        st = IMA_STEP[self.step]
        diff = st >> 3
        if nib & 4: diff += st
        if nib & 2: diff += st >> 1
        if nib & 1: diff += st >> 2
        self.signal = (self.signal - diff if nib & 8 else self.signal + diff) & 0xffff
        if self.signal & 0x8000: self.signal -= 0x10000
        self.step = max(0, min(88, self.step + INDEX_SHIFT[nib & 7]))
        return self.signal


def bendmul(v):
    """[204]: bit 7 up, bits 6-0 the magnitude v; the rate x (1 + v/128) up, x (1 - v/256) down, in 2.14, as
    vh_qs1000_voice.sv's bendmul (Arcade-Eolith_MiSTer docs/QS1000_FEATURES.md)"""
    return 16384 + (v & 0x7f) * 128 if v & 0x80 else 16384 - (v & 0x7f) * 64


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
        self.adpcm = AdpcmIma()
        self.loop_start = 0
        self.s_signal = 0
        self.s_step = 0
        self.env = 0xffff
        self.rel = False


class QS1000:
    # (ADPCM, PCM) gain: MAME's (qs1000.cpp:484, :513), or the PCB recording's (MAME_KLUDGES.md, Sound): x8, x4
    # with IMA decoding, x2, x4 with OKI's (the music's level is the same)
    BALANCE = {"mame": (4, 1), "pcb": (8, 4)}
    BALANCE_OKI = {"mame": (4, 1), "pcb": (2, 4)}

    def __init__(self, rom, balance="mame", loop="mame", adpcm="ima"):
        self.rom = rom
        self.ima = adpcm == "ima"
        self.g_adpcm, self.g_pcm = (self.BALANCE if self.ima else self.BALANCE_OKI)[balance]
        self.pcb_loop = loop == "pcb"
        self.ticks = 0
        self.wave = [0] * 0x12
        self.ch = [Chan() for _ in range(32)]
        if not self.ima:
            for c in self.ch:
                c.adpcm = Adpcm()

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
                self.ch[ch].rel = True
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
        c.env = 0xffff
        c.rel = False
        if b8 & 0x08:
            c.adpcm.reset()
            c.adpcm_addr = 0xffffffff          # uint32_t -1
            c.flags |= ADPCM

    def sample(self):
        """One tick: the left and right sums (before /4096)."""
        L = R = 0
        env_go = self.ticks > 0 and self.ticks % 732 == 0
        self.ticks += 1
        for c in self.ch:
            if not (c.flags & PLAYING):
                continue
            lvol, rvol, vol = c.regs[7], c.regs[6], c.regs[8]          # [207] left, [206] right (not MAME's)
            if c.addr >= c.loop_end:
                if self.pcb_loop and c.loop_start < c.loop_end:
                    c.addr = c.loop_start
                    if c.flags & ADPCM:
                        c.adpcm_addr = (c.loop_start - c.start - 1) & 0xffffffff
                        c.adpcm.signal, c.adpcm.step = c.s_signal, c.s_step
                else:
                    c.flags &= ~PLAYING
                    continue
            rel = self.pcb_loop and c.rel
            if rel and (c.env >> 8) == 0:
                c.flags &= ~PLAYING
                continue
            if rel:
                vol = (vol * (c.env >> 8)) >> 8
                if env_go:
                    c.env -= c.env >> 8
            if c.flags & ADPCM:
                while (c.start + c.adpcm_addr) & 0xffffffff != c.addr:
                    c.adpcm_addr = (c.adpcm_addr + 1) & 0xffffffff
                    if c.start + c.adpcm_addr >= c.loop_end:
                        c.adpcm_addr = (c.loop_start - c.start) & 0xffffffff
                    if self.pcb_loop and (c.start + c.adpcm_addr) & 0xffffffff == c.loop_start:
                        c.s_signal, c.s_step = c.adpcm.signal, c.adpcm.step
                    d = self.rb(c.start + (c.adpcm_addr >> 1))
                    nib = (d if c.adpcm_addr & 1 else d >> 4) & 0xf
                    c.adpcm_signal = c.adpcm.clock(nib)
                res = c.adpcm_signal >> (8 if self.ima else 4)
                res = ((res + 128) & 0xff) - 128     # int8_t
                L += res * self.g_adpcm * lvol * vol
                R += res * self.g_adpcm * rvol * vol
            else:
                res = ((self.rb(c.addr) - 128 + 128) & 0xff) - 128
                L += res * self.g_pcm * lvol * vol
                R += res * self.g_pcm * rvol * vol
            c.acc += (c.freq * bendmul(c.regs[4])) >> 14 if self.pcb_loop else c.freq
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


def run(setname, wave, ticks=None, mix=None, wav=None, rom=None, balance="mame", loop="mame", adpcm="ima"):
    rom = rom if rom is not None else sample_rom(setname)
    q = QS1000(rom, balance, loop, adpcm)
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
    ap.add_argument("--loop", choices=["mame", "pcb"], default="mame",
                    help="looping and the key-off fade: MAME's none, or the recording's (vh_qs1000_voice loop_pcb)")
    ap.add_argument("--adpcm", choices=["ima", "oki"], default="ima",
                    help="ADPCM decoding: IMA, as vh_qs1000_voice (docs/MAME_KLUDGES.md, Sound), or MAME's OKI")
    a = ap.parse_args()
    run(a.set, a.wave, a.ticks, a.mix, a.wav, balance=a.balance, loop=a.loop, adpcm=a.adpcm)


if __name__ == "__main__":
    main()
