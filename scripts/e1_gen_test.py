#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Seeded-random Hyperstone E1 instruction streams for ISA conformance against MAME.

    python scripts/e1_gen_test.py --seed 1 [--irq] [--n 4000] --out debug/e1/s1

Writes <out>/prg-rom2.bin (512 KB, the misncrft main program ROM, loaded at 0xfff80000),
<out>/misncrft.zip (the real set with prg-rom2.bin replaced; MAME runs it with a bad-checksum
warning) and <out>/info.txt. scripts/e1_regress.py runs MAME on it and the Verilator bench on the trace.

The reference is MAME's interpreter, so the generator only has to keep the program on rails:
  - every trap/interrupt entry is RET PC, L0 (0x0500) except the trace exception (clears P in the
    saved SR first) and the reset entry, a branch to 0xfff80000;
  - code is straight-line, branches go forward to instruction boundaries, subroutines sit after
    the main stream and return through RET, the image ends in a self-loop;
  - destinations are g2..g15 and the unreserved locals of the current frame; PC, SR, SP, UB and
    the write-side-effect registers are written only by the controlled sequences;
  - memory operands point into work RAM below 0x100000 (0x180000.. is the register-spill stack),
    sprite RAM, palette RAM, program ROM (reads) and the mapped misncrft I/O ports.
"""
import argparse
import random
import struct
import sys
import zipfile
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

ROM_BASE = 0xfff80000
ROM_SIZE = 0x80000
EMU_BASE = 0xfffffe00          # emulated-code (floating point) handlers, 16 bytes each
TRAP_BASE = 0xffffff00         # trap n at +4n
SP_BASE = 0x00180000
RAM_DATA_TOP = 0x00100000
PORTS = [0x040, 0x080, 0x090, 0x0d0, 0x0f0, 0x100, 0x160, 0x1a0]

M32 = 0xffffffff
EDGE = [0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 33, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xffff,
        0x10000, 0x7fffffff, 0x80000000, 0x80000001, 0xffffffff, 0xfffffffe, 0xffffff80,
        0xffff8000, 0x7ffffffe, 0x55555555, 0xaaaaaaaa, 0x0000ffff, 0xffff0000, 0x12345678,
        0xfffffff0, 0x3fffffff, 0x40000000]

# two-register group: name -> (opcode base, kind)   kind: std, ro (dst only read), pair, div, mul
ALU2 = {
    "chk": (0x00, "ro"), "movd": (0x04, "pair"), "divu": (0x08, "div"), "divs": (0x0c, "div"),
    "cmp": (0x20, "ro"), "mov": (0x24, "std"), "add": (0x28, "std"), "adds": (0x2c, "std"),
    "cmpb": (0x30, "ro"), "andn": (0x34, "std"), "or": (0x38, "std"), "xor": (0x3c, "std"),
    "subc": (0x40, "std"), "not": (0x44, "std"), "sub": (0x48, "std"), "subs": (0x4c, "std"),
    "addc": (0x50, "std"), "and": (0x54, "std"), "neg": (0x58, "std"), "negs": (0x5c, "std"),
    "mulu": (0xb0, "mul2"), "muls": (0xb4, "mul2"), "mul": (0xbc, "mul"),
}
EXT2 = {"xm": 0x10, "mask": 0x14, "sum": 0x18, "sums": 0x1c}
IMMOPS = {"cmpi": 0x60, "movi": 0x64, "addi": 0x68, "addsi": 0x6c,
          "cmpbi": 0x70, "andni": 0x74, "ori": 0x78, "xori": 0x7c}
BASE_NAME = {v[0]: k for k, v in ALU2.items()}
BASE_NAME.update({v: k for k, v in EXT2.items()})
IMM_NAME = {v: k for k, v in IMMOPS.items()}

NONTRAP_2B = ["mov", "add", "sub", "cmp", "and", "or", "xor", "andn", "not", "neg", "addc",
              "subc", "cmpb", "mul", "mulu", "muls", "movd"]
# opcode bytes of the single-word shift/set forms usable inside a region of 2-byte instructions
EXTEND_FUNCS = [0x100, 0x102, 0x104, 0x106, 0x10a, 0x10e, 0x11a, 0x11e]
EXTEND_DSP = [0x02a, 0x02e, 0x046, 0x04e, 0x086, 0x096, 0x296]


class Item:
    __slots__ = ("w", "fix", "tag")

    def __init__(self, words, fix=None, tag=""):
        self.w = list(words)
        self.fix = fix
        self.tag = tag


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def pcrel_words(opbyte, off, long):
    assert off % 2 == 0
    if long:
        o24 = off & 0xffffff
        return [(opbyte << 8) | 0x80 | ((o24 >> 16) & 0x7f), (o24 & 0xfffe) | ((o24 >> 23) & 1)]
    assert -128 <= off <= 126
    return [(opbyte << 8) | (off & 0x7e) | (1 if off < 0 else 0)]


def ext_ldst(d, long, dd):
    """ld/st displacement word(s): 12 bit signed (short) or 28 bit signed (long)."""
    neg = 1 if d < 0 else 0
    if not long:
        assert -4096 <= d < 4096
        return [(neg << 14) | (dd << 12) | (d & 0xfff)]
    v = d & 0xfffffff
    return [0x8000 | (neg << 14) | (dd << 12) | ((v >> 16) & 0xfff), v & 0xffff]


def ext_const14(d, long):
    """mask/sum/sums/call constant: 14 bit signed (short) or 30 bit signed (long)."""
    neg = 1 if d < 0 else 0
    if not long:
        assert -16384 <= d < 16384
        return [(neg << 14) | (d & 0x3fff)]
    v = d & 0x3fffffff
    return [0x8000 | (neg << 14) | ((v >> 16) & 0x3fff), v & 0xffff]


def ext_xm(sub, v, long):
    if not long:
        return [(sub << 12) | (v & 0xfff)]
    return [0x8000 | (sub << 12) | ((v >> 16) & 0xfff), v & 0xffff]


class Gen:
    def __init__(self, seed, irq=False, dsp=False):
        self.r = random.Random(seed)
        self.wrap = seed % 3 == 0
        self.loop_g = None      # global register reserved as the loop counter
        self.irq = irq
        self.dsp = dsp
        self.lmask = 0 if irq else 0x8000
        self.cur = []
        self.subs = []
        self.nlabel = 0
        self.fl = 12
        self.fp = 0
        self.res = set()
        self.depth = 0
        self.fp0 = 0
        self.spidx = 0          # (SP & 0x1fc) >> 2, as MAME's frame/ret maintain it
        self.stats = {}

    # ---- emission -------------------------------------------------------------------------
    def emit(self, words, fix=None, tag=""):
        it = Item(words, fix, tag)
        self.cur.append(it)
        return it

    @contextmanager
    def capture(self):
        saved = self.cur
        self.cur = []
        box = []
        try:
            yield box
        finally:
            box.extend(self.cur)
            self.cur = saved

    @staticmethod
    def nbytes(items):
        return 2 * sum(len(i.w) for i in items)

    def chance(self, p):
        return self.r.random() < p

    # ---- registers and values -------------------------------------------------------------
    def val(self):
        r = self.r.random()
        if r < 0.45:
            return self.r.choice(EDGE)
        if r < 0.58:
            return self.r.randrange(0, 48)
        if r < 0.72:
            return s32(self.r.randrange(-0x8000, 0x8000)) & M32
        return self.r.getrandbits(32)

    def usable_l(self):
        return [i for i in range(min(self.fl, 16)) if i not in self.res]

    def pick_l(self, pair=False):
        u = self.usable_l()
        if pair:
            u = [i for i in u if i + 1 in u]
        return self.r.choice(u)

    def src_l(self, pair=False):
        n = min(self.fl, 16)
        if self.chance(0.04):
            return self.r.randrange(16)
        return self.r.randrange(n)

    def pick_g(self, pair=False):
        while True:
            if pair:
                g = 15 if self.chance(0.03) else self.r.randrange(2, 15)
                ok = self.loop_g not in (g, g + 1)
            else:
                g = self.r.randrange(2, 16)
                ok = g != self.loop_g
            if ok:
                return g

    def src_g(self):
        x = self.r.random()
        if x < 0.04:
            return 0
        if x < 0.09:
            return 1
        return self.r.randrange(2, 16)

    def writable(self, kind, idx):
        return (kind == "G" and 2 <= idx <= 15 and idx != self.loop_g) or (kind == "L" and idx not in self.res)

    # ---- encoders emitting items ------------------------------------------------------------
    def movi_words(self, kind, idx, v, form=None):
        v &= M32
        dl = 1 if kind == "L" else 0
        opb = 0x64 + (dl << 1)
        tab = {16: 0, 32: 4, 64: 5, 128: 6, 0x80000000: 7}
        for i in range(8):
            tab[(0xfffffff8 + i) & M32] = 8 + i
        forms = []
        if v < 16:
            forms.append("s")
        if v in tab:
            forms.append("t")
        if v < 0x10000:
            forms.append("h")
        if v >= 0xffff0000:
            forms.append("n")
        forms.append("w")
        f = form if form in forms else (self.r.choice(forms) if self.chance(0.6) else "w")
        if f == "s":
            return [(opb << 8) | (idx << 4) | v]
        if f == "t":
            return [((opb + 1) << 8) | (idx << 4) | tab[v]]
        if f == "h":
            return [((opb + 1) << 8) | (idx << 4) | 2, v & 0xffff]
        if f == "n":
            return [((opb + 1) << 8) | (idx << 4) | 3, v & 0xffff]
        return [((opb + 1) << 8) | (idx << 4) | 1, v >> 16, v & 0xffff]

    def movi(self, kind, idx, v, form=None, fix=None):
        return self.emit(self.movi_words(kind, idx, v, "w" if fix else form), fix, "movi")

    def init(self, kind, idx, v=None):
        if not self.writable(kind, idx):
            return
        self.movi(kind, idx, self.val() if v is None else v)

    def setflags(self, f=None):
        """movi SR, imm16: the low 16 bits of SR become imm16 (L kept per mode)."""
        if f is None:
            f = self.r.randrange(16)
            if self.chance(0.25):
                f |= (self.r.getrandbits(1) << 4) | (self.r.getrandbits(1) << 7) | (self.r.getrandbits(7) << 8)
        self.emit([(0x65 << 8) | 0x12, self.lmask | (f & 0x7f9f)], tag="flags")

    def hset(self):
        self.emit([0x7914], tag="hset")                                     # ORI SR, $20

    # SP bookkeeping, mirroring hyperstone_frame and the fill loop of RET in e132xsop.hxx.
    # FP - SPidx must stay below 64 or RET's 7-bit difference reads negative and refills
    # registers from the stack: the generator keeps that true instead of testing it.
    @staticmethod
    def sext7(v):
        return ((v & 0x7f) ^ 0x40) - 0x40

    def frame_effect(self, fp, fl):
        v = self.sext7(self.spidx + 54 - (fp + fl))
        if v < 0:
            self.spidx = (self.spidx - v) & 0x7f

    def ret_effect(self, fp):
        v = self.sext7(fp - self.spidx)
        if v < 0:
            self.spidx = (self.spidx + v) & 0x7f

    # ---- single instruction templates --------------------------------------------------------
    def t_alu2(self, name=None, dl=None, sl=None, flags=None, bare=False, rs_g=None):
        name = name or self.r.choice(list(ALU2))
        base, kind = ALU2[name]
        dl = self.r.getrandbits(1) if dl is None else dl
        sl = self.r.getrandbits(1) if sl is None else sl
        pair = kind in ("pair", "div", "mul2")
        dK = "L" if dl else "G"
        sK = "L" if sl else "G"
        degenerate = self.chance(0.04)
        if dl:
            rd = self.pick_l(pair) if kind != "ro" else self.src_l()
        elif kind == "ro":
            rd = self.src_g()
        else:
            rd = self.pick_g(pair)
        if sl:
            rs = self.src_l()
        else:
            rs = self.src_g() if kind in ("std", "ro", "pair") else self.r.randrange(2, 16)
        if kind in ("div",) and not degenerate:
            for _ in range(20):
                if dK != sK or rs not in (rd, rd + 1):
                    break
                rs = self.src_l() if sl else self.r.randrange(2, 16)
            else:
                return self.t_alu2("add")
            if not sl and rs < 2:
                rs = 2 + rs
        if kind in ("mul", "mul2") and not degenerate:
            if not sl and rs < 2:
                rs += 2
        if kind == "pair" and name == "movd" and not dl and rd == 0:
            rd = 2
        if rs_g is not None:
            sl, sK, rs = 0, "G", rs_g
        # operand initialisation
        if dl or kind != "ro":
            pass
        vd = vs = None
        if kind == "div":
            vs = self.r.choice([0, 1, 2, 3, 7, 0xffffffff, 0x80000000, 0x7fffffff, self.val(), self.val()])
            hi = self.r.choice([0, 0, 1, 0x7fffffff, 0x80000000, 0xffffffff, self.val()])
            lo = self.val()
        if not bare and self.chance(0.85):
            if kind == "div":
                self.init(dK, rd, hi)
                if self.writable(dK, rd + 1):
                    self.init(dK, rd + 1, lo)
                self.init(sK, rs, vs)
            else:
                self.init(dK, rd, vd)
                if kind in ("pair", "mul2") and self.chance(0.5) and self.writable(dK, rd + 1):
                    self.init(dK, rd + 1)
                if (sK, rs) != (dK, rd):
                    self.init(sK, rs, vs)
                if name == "movd" and self.writable(sK, rs + 1):
                    self.init(sK, rs + 1)
        if not bare and flags is not False and (flags is not None or self.chance(0.35)):
            self.setflags(flags)
        op = base + (dl << 1) + sl
        self.emit([(op << 8) | (rd << 4) | rs], tag=name)

    def t_ext2(self, name=None, dl=None, sl=None, rs_g=None):
        name = name or self.r.choice(list(EXT2))
        base = EXT2[name]
        dl = self.r.getrandbits(1) if dl is None else dl
        sl = self.r.getrandbits(1) if sl is None else sl
        rd = self.pick_l() if dl else (self.pick_g() if not (name == 'xm' and self.chance(0.05)) else self.r.randrange(2))
        rs = self.src_l() if sl else self.src_g()
        if rs_g is not None:
            sl, rs = 0, rs_g
        long = self.r.getrandbits(1)
        sv = self.val()
        if self.chance(0.85) and (sl or rs >= 2):
            self.init("L" if sl else "G", rs, sv)
        else:
            sv = None
        if self.chance(0.4):
            self.setflags()
        if name == "xm":
            sub = self.r.randrange(8)
            lim = 0xfffffff if long else 0xfff
            c = self.r.choice([0, 1, 0xfff, lim, self.r.randrange(lim + 1)])
            if sv is not None and self.chance(0.5):
                c = max(0, min(lim, (sv + self.r.choice([0, 0, 1, -1])) & M32))
            ext = ext_xm(sub, c, long)
        else:
            lim = 1 << (29 if long else 13)
            c = self.r.choice([0, 1, -1, lim - 1, -lim, self.r.randrange(-lim, lim)])
            if self.chance(0.3):
                c = self.r.randrange(-64, 64)
            ext = ext_const14(c, long)
        op = base + (dl << 1) + sl
        self.emit([(op << 8) | (rd << 4) | rs] + ext, tag=name)

    def t_imm(self, name=None, dl=None, long=None, nib=None):
        name = name or self.r.choice(list(IMMOPS))
        base = IMMOPS[name]
        dl = self.r.getrandbits(1) if dl is None else dl
        long = self.r.getrandbits(1) if long is None else long
        ro = name in ("cmpi", "cmpbi")
        if dl:
            rd = self.pick_l() if not ro else self.src_l()
        else:
            rd = self.pick_g() if not ro else (self.src_g() if self.chance(0.1) else self.pick_g())
        nib = self.r.randrange(16) if nib is None else nib
        if name == "movi" and not ro and not dl and rd < 2:
            rd = 2
        if self.chance(0.8) and (dl or rd >= 2) and (not dl or rd not in self.res):
            self.init("L" if dl else "G", rd)
        if self.chance(0.3):
            self.setflags()
        ext = []
        if long:
            if nib == 1:
                ext = [self.r.choice([0, 0xffff, 0x7fff, 0x8000, self.r.getrandbits(16)]), self.r.getrandbits(16)]
            elif nib in (2, 3):
                ext = [self.r.choice([0, 0xffff, 0x8000, 0x7fff, self.r.getrandbits(16)])]
        op = base + (dl << 1) + long
        self.emit([(op << 8) | (rd << 4) | nib] + ext, tag=name)

    def t_shift(self, form=None, dl=None):
        forms = ["shrdi", "shrd", "shr", "sardi", "sard", "sar", "shldi", "shld", "shl", "rol",
                 "testlz", "shri", "sari", "shli", "res"]
        form = form or self.r.choice(forms)
        counts = [0, 1, 2, 15, 16, 17, 30, 31, 32, 33, 63, 0xffffffe0, 0xffffffff, self.val()]
        if form == "res":
            op = self.r.choice([0x8c, 0x8d, 0xac, 0xad, 0xae, 0xaf])
            self.emit([(op << 8) | self.r.getrandbits(8)], tag="reserved")
            return
        if form in ("shrdi", "sardi", "shldi"):
            op = {"shrdi": 0x80, "sardi": 0x84, "shldi": 0x88}[form] + self.r.getrandbits(1)
            rd = self.pick_l(True)
            self.init("L", rd)
            self.init("L", rd + 1)
            if self.chance(0.3):
                self.setflags()
            self.emit([(op << 8) | (rd << 4) | self.r.choice([0, 1, 2, 7, 15, self.r.randrange(16)])], tag=form)
        elif form in ("shrd", "sard", "shld"):
            op = {"shrd": 0x82, "sard": 0x86, "shld": 0x8a}[form]
            rd = self.pick_l(True)
            rs = self.src_l()
            if rs in (rd, rd + 1) and not self.chance(0.05):
                rs = self.pick_l()
                while rs in (rd, rd + 1):
                    rs = self.src_l()
            self.init("L", rd)
            self.init("L", rd + 1)
            self.init("L", rs, self.r.choice(counts))
            if self.chance(0.3):
                self.setflags()
            self.emit([(op << 8) | (rd << 4) | rs], tag=form)
        elif form in ("shr", "sar", "shl", "rol", "testlz"):
            op = {"shr": 0x83, "sar": 0x87, "shl": 0x8b, "rol": 0x8f, "testlz": 0x8e}[form]
            rd = self.pick_l()
            rs = self.src_l()
            self.init("L", rd)
            if rs != rd or self.chance(0.1):
                self.init("L", rs, self.val() if form == "testlz" else self.r.choice(counts))
            if self.chance(0.3):
                self.setflags()
            self.emit([(op << 8) | (rd << 4) | rs], tag=form)
        else:
            base = {"shri": 0xa0, "sari": 0xa4, "shli": 0xa8}[form]
            dl = self.r.getrandbits(1) if dl is None else dl
            hi = self.r.getrandbits(1)
            rd = self.pick_l() if dl else self.pick_g()
            self.init("L" if dl else "G", rd)
            if self.chance(0.3):
                self.setflags()
            op = base + (dl << 1) + hi
            self.emit([(op << 8) | (rd << 4) | self.r.choice([0, 1, 2, 7, 15, 15, self.r.randrange(16)])], tag=form)

    def t_set(self, dl=None, hi=None, n=None, flags=None):
        dl = self.r.getrandbits(1) if dl is None else dl
        hi = self.r.getrandbits(1) if hi is None else hi
        n = self.r.randrange(16) if n is None else n
        rd = self.pick_l() if dl else (self.pick_g() if not self.chance(0.03) else self.r.randrange(2))
        if flags is not False:
            self.setflags(flags)
        op = 0xb8 + (dl << 1) + hi
        self.emit([(op << 8) | (rd << 4) | n], tag="set")

    def t_trap(self, code=None, trapno=None, flags=None):
        code = self.r.randrange(4, 16) if code is None else code
        if trapno is None:
            trapno = self.r.choice([t for t in range(64) if t != 62])
        if flags is not False:
            self.setflags(flags)
        self.emit([((0xfc | (code >> 2)) << 8) | (trapno << 2) | (code & 3)], tag="trap")

    def t_fp(self, n=None):
        n = self.r.randrange(14) if n is None else n
        rd = self.pick_l()
        rs = self.src_l()
        self.init("L", rs)
        self.init("L", (rs + 1) & 15)
        self.emit([((0xc0 + n) << 8) | (rd << 4) | rs], tag="fp")

    def t_extend(self, func=None):
        if func is None:
            func = self.r.choice(EXTEND_FUNCS if not (self.dsp and self.chance(0.4)) else EXTEND_DSP + [0x103, 0x000, 0x1ff])
        rd = self.src_l()
        rs = self.src_l()
        for g in (14, 15):
            if self.chance(0.7):
                self.init("G", g)
        self.init("L", rd)
        if rs != rd:
            self.init("L", rs)
        self.emit([(0xce << 8) | (rd << 4) | rs, func], tag="extend")

    # ---- memory -----------------------------------------------------------------------------
    def target(self, store, pair=False, io=False):
        """Effective byte address for a data access."""
        if io:
            return (self.r.choice(PORTS) << 13) | self.r.randrange(0, 0x2000, 4)
        x = self.r.random()
        if x < 0.62:
            e = self.r.randrange(0, RAM_DATA_TOP - 16)
        elif x < 0.73:
            e = 0x40000000 + self.r.randrange(0, 0x40000 - 16)
        elif x < 0.84:
            e = 0x80000000 + self.r.randrange(0, 0x10000 - 16)
        elif x < 0.91 and not store:
            e = ROM_BASE + self.r.randrange(0, 0x7f000)
        else:
            e = 0x1000 + 4 * self.r.randrange(0, 16)
        if self.chance(0.5):
            e &= ~3
        return e

    def free_abs_local(self):
        """An absolute local-register index outside every live frame, or None. At main level the
        frames below FP are dead, so the registers just above the frame (modulo 64) are free."""
        if self.res or self.depth:
            return None
        return (self.fp + min(self.fl, 16) + 2 + self.r.randrange(6)) & 63

    def target_low(self, store, io):
        """Address reachable by an absolute or PC-relative 28-bit displacement."""
        if io:
            return self.target(store, io=True)
        x = self.r.random()
        if x < 0.7 or store:
            return self.r.randrange(0, RAM_DATA_TOP - 16)
        return ROM_BASE + self.r.randrange(0, 0x7f000)

    def t_ldst(self, kind=None, dl=None, sl=None, sub=None, long=None, err=None, safe=False, typ=None):
        """ldxx/stxx. dl: pointer register is local; sl: data register is local.
        safe: cannot raise an exception (used in delay slots)."""
        kind = kind or self.r.choice(["ld1", "ld2", "st1", "st2"])
        n_form = kind.endswith("2")
        store = kind.startswith("st")
        dl = self.r.getrandbits(1) if dl is None else dl
        sl = self.r.getrandbits(1) if sl is None else sl
        if sub is None:
            sub = self.r.choice([1, 3]) if (safe and store) else self.r.randrange(4)
        long = self.r.getrandbits(1) if long is None else long
        err = (self.chance(0.05) and not safe) if err is None else err
        typ = (self.r.randrange(4) if typ is None else typ) if sub == 3 else 0
        pair = sub == 3 and (typ == 1 or (typ == 3 and not n_form))
        iod = (not n_form) and sub == 3 and typ >= 2
        stack = n_form and sub == 3 and typ == 3
        special = None
        if n_form:
            rp = self.pick_l() if dl else (self.pick_g() if (safe or not self.chance(0.03)) else self.r.randrange(2))
        elif dl:
            rp = self.pick_l()
        else:
            x = self.r.random()
            rp = 0 if x < 0.08 else (1 if x < 0.2 else self.pick_g())
            special = {0: "pc", 1: "sr"}.get(rp)
        if store:
            rs = self.src_l() if sl else self.src_g()
        else:
            rs = self.pick_l(pair) if sl else self.pick_g(pair)
        if long:
            d = self.r.choice([0, 4, 8, -4, 0x1000, -0x1000, 0xfffc, self.r.randrange(-0x20000, 0x20000),
                               self.r.randrange(-(1 << 27), 1 << 27)])
        else:
            d = self.r.choice([0, 1, 2, 3, 4, 7, 8, 0xff0, 4095, -1, -4, -8, -4096, self.r.randrange(-4096, 4096)])
        if sub == 3:
            d = ((d & ~3) | typ)
            if d >= 4096 and not long:
                d -= 4
            if d < -4096 and not long:
                d += 4

        def em(dd):                     # displacement as the address sees it
            if sub in (0, 1):
                return dd
            if sub == 2 or typ in (0, 1):
                return dd & ~1
            return dd & ~3

        fix = None
        ptr = 0
        e = 0
        if stack and self.chance(0.3):
            stack_mem = True        # dreg below SP: LDW.S/STW.S go to memory
        else:
            stack_mem = False
        if stack and not stack_mem:
            idx = self.free_abs_local() if store else self.r.randrange(64)
            if store and dl and self.chance(0.25) and not self.res:
                idx = (self.fp + rp) & 63        # STW.S into its own pointer register
            if idx is None:
                stack = False
                typ = 0
                d &= ~3
            else:
                ptr = 0x00190000 + (idx << 2) + (self.r.getrandbits(1) << 8)
        if stack_mem:
            stack = False
        if not stack:
            if special:
                e = self.target_low(store, iod)
            else:
                e = self.target(store, pair, iod)
            if stack_mem:
                e = self.r.randrange(0, RAM_DATA_TOP - 16)      # LDW.S/STW.S use memory only below SP
        if special == "sr":
            d = s32((e & ~3) | typ) if sub == 3 else s32(e)
            long = 1
        elif special == "pc":
            long = 1

            def fix(it, lay, e=e, sub=sub, typ=typ):
                dd = (e - (lay.addr(it) + 2 * len(it.w))) & M32
                dd = ((dd & ~3) | typ) if sub == 3 else dd
                it.w[1:] = ext_ldst(s32(dd), 1, sub)
        elif not stack:
            ptr = e if n_form else (e - em(d)) & M32
        if err and not special:
            ptr = 0
        elif ptr == 0 and not special and not stack:
            ptr = 4
        if not special:
            self.init("L" if dl else "G", rp, ptr)
        if store:
            for k in ((0, 1) if pair else (0,)):
                r2 = rs + k
                if r2 > 15 or ((dl, rp) == (sl, r2) and not special):
                    continue
                self.init("L" if sl else "G", r2)
        if self.chance(0.2):
            self.setflags()
        op = {"ld1": 0x90, "ld2": 0x94, "st1": 0x98, "st2": 0x9c}[kind] + (dl << 1) + sl
        self.emit([(op << 8) | (rp << 4) | rs] + ext_ldst(d, long, sub), fix, kind)

    def t_ldwr(self, op=None, sl=None):
        op = self.r.choice(range(0xd0, 0xe0)) if op is None else op
        sl = op & 1
        k = (op - 0xd0) >> 1        # 0 ldwr 1 lddr 2 ldwp 3 lddp 4 stwr 5 stdr 6 stwp 7 stdp
        store = k >= 4
        pair = k in (1, 3, 5, 7)
        post = k in (2, 3, 6, 7)
        rp = self.pick_l()
        err = self.chance(0.06)
        e = self.target(store, pair)
        ptr = 0 if err else (e or 4)
        if store:
            rs = self.src_l() if sl else self.src_g()
        else:
            rs = self.pick_l(pair) if sl else self.pick_g(pair)
        self.init("L", rp, ptr)
        if store:
            self.init("L" if sl else "G", rs)
            if pair:
                self.init("L" if sl else "G", (rs + 1) & 15)
        if self.chance(0.2):
            self.setflags()
        self.emit([(op << 8) | (rp << 4) | rs], tag="ldwr")

    def t_chk_range(self):
        # operands chosen to hit and miss the range checks
        name = self.r.choice(["chk", "adds", "subs", "negs", "chk", "adds"])
        self.t_alu2(name)

    # ---- multiply/divide ----------------------------------------------------------------------
    def t_muldiv(self):
        self.t_alu2(self.r.choice(["divu", "divs", "mul", "mulu", "muls"]))

    # ---- branches -----------------------------------------------------------------------------
    CONDS = list(range(0xf0, 0xfc))

    def simple_template(self):
        """One non-control template for filler and delay slots."""
        c = self.r.random()
        if c < 0.30:
            self.t_alu2(flags=False if self.chance(0.5) else None)
        elif c < 0.45:
            self.t_imm()
        elif c < 0.58:
            self.t_shift()
        elif c < 0.66:
            self.t_ext2()
        elif c < 0.80:
            self.t_ldst()
        elif c < 0.86:
            self.t_ldwr()
        elif c < 0.89:
            self.t_set()
        elif c < 0.92:
            self.t_extend()
        elif c < 0.95:
            self.t_trap()
        else:
            self.t_alu2(self.r.choice(["divu", "mul", "muls", "cmp"]))

    def slot_template(self):
        """One instruction for a delay slot. An exception in a slot returns into the slot
        instruction's last halfword (MAME rewinds PC by the length in halfwords, in bytes), so a
        multi-halfword slot instruction must not be able to trap."""
        c = self.r.random()
        if c < 0.30:
            self.t_alu2()
        elif c < 0.38:
            self.t_shift()
        elif c < 0.42:
            self.t_set()
        elif c < 0.52:
            self.t_imm(self.r.choice(["cmpi", "cmpbi"]) if self.chance(0.2) else None, long=0)
        elif c < 0.62:
            self.t_imm(self.r.choice(["movi", "ori", "xori", "andni", "cmpi", "cmpbi"]), long=1)
        elif c < 0.68:
            self.t_ext2(self.r.choice(["mask", "sum"]))
        elif c < 0.80:
            self.t_ldst(self.r.choice(["ld1", "ld2", "st1", "st2"]), safe=True)
        elif c < 0.88:
            self.t_ldwr()
        elif c < 0.92:
            self.t_extend()
        elif c < 0.96:
            self.t_trap()
        else:
            self.t_fp()

    def two_byte(self):
        """A single-halfword instruction that never traps."""
        c = self.r.random()
        if c < 0.6:
            name = self.r.choice(NONTRAP_2B)
            base, kind = ALU2[name]
            dl = self.r.getrandbits(1)
            sl = self.r.getrandbits(1)
            pair = kind in ("pair", "mul2")
            rd = self.pick_l(pair) if dl else self.pick_g(pair)
            if kind == "ro":
                rd = self.src_l() if dl else self.src_g()
            rs = self.src_l() if sl else (self.src_g() if kind in ("std", "ro", "pair") else self.r.randrange(2, 16))
            if kind in ("mul", "mul2") and not sl and rs < 2:
                rs += 2
            if name == "movd" and not sl and rs < 2:
                rs += 2
            op = base + (dl << 1) + sl
            self.emit([(op << 8) | (rd << 4) | rs], tag=name)
        elif c < 0.85:
            base = self.r.choice([0xa0, 0xa4, 0xa8])
            dl = self.r.getrandbits(1)
            rd = self.pick_l() if dl else self.pick_g()
            self.emit([((base + (dl << 1) + self.r.getrandbits(1)) << 8) | (rd << 4) | self.r.randrange(16)], tag="shiftimm")
        elif c < 0.93:
            dl = self.r.getrandbits(1)
            rd = self.pick_l() if dl else self.pick_g()
            self.emit([((0xb8 + (dl << 1) + self.r.getrandbits(1)) << 8) | (rd << 4) | self.r.randrange(16)], tag="set")
        else:
            op = self.r.choice([0x8e, 0x8f, 0x83, 0x87, 0x8b])
            self.emit([(op << 8) | (self.pick_l() << 4) | self.src_l()], tag="shiftreg")

    def t_branch(self, cond=None, long=None, nskip=None):
        cond = self.r.choice(self.CONDS + [0xfc]) if cond is None else cond
        K = self.r.randrange(1, 6)
        with self.capture() as blk:
            for _ in range(K):
                self.simple_template()
        k = self.r.randrange(K + 1) if nskip is None else min(nskip, K)
        off = self.nbytes(blk[:k])
        if self.chance(0.4):
            self.setflags()
        long = (self.r.getrandbits(1) if long is None else long) or off > 126
        self.emit(pcrel_words(cond, off, long), tag="b")
        self.cur.extend(blk)

    def t_dbranch(self, cond=None, long=None):
        cond = self.r.choice(range(0xe0, 0xed)) if cond is None else cond
        with self.capture() as box:
            self.slot_template()
            if self.chance(0.1):
                self.t_trap(flags=False)
        pre, slot = box[:-1], box[-1]
        K = self.r.randrange(1, 5)
        with self.capture() as blk:
            for _ in range(K):
                self.simple_template()
        k = self.r.randrange(K + 1)
        off = self.nbytes([slot]) + self.nbytes(blk[:k])
        self.cur.extend(pre)
        if self.chance(0.5):
            self.setflags()
        long = (self.r.getrandbits(1) if long is None else long) or off > 126
        self.emit(pcrel_words(cond, off, long), tag="db")
        self.cur.append(slot)
        self.cur.extend(blk)

    def t_dbranch2(self, variant=None):
        """Branch in a delay slot. A region of halfword instructions makes every even offset a
        boundary, so both the taken and not-taken paths of both branches land on one."""
        M = 14
        variant = variant or self.r.choice(["b", "db", "dbr", "br", "b"])
        db1 = self.r.choice(list(range(0xe0, 0xed)))
        with self.capture() as reg:
            for _ in range(M):
                self.two_byte()
        if self.chance(0.6):
            self.setflags()
        a = self.r.randrange(M + 1)
        c = self.r.randrange(M - a + 1)
        long1 = self.r.getrandbits(1)
        long2 = self.r.getrandbits(1)
        if variant in ("b", "br"):
            cond = self.r.choice(self.CONDS) if variant == "b" else 0xfc
            slot_words = len(pcrel_words(cond, 0, long2))
            self.emit(pcrel_words(db1, 2 * slot_words + 2 * a, long1 or 2 * slot_words + 2 * a > 126), tag="db")
            self.emit(pcrel_words(cond, 2 * c, long2), tag="b")
        else:
            cond = 0xec if variant == "dbr" else self.r.choice(range(0xe0, 0xed))
            slot_words = len(pcrel_words(cond, 0, long2))
            self.emit(pcrel_words(db1, 2 * slot_words + 2 * a, long1 or 2 * slot_words + 2 * a > 126), tag="db")
            self.emit(pcrel_words(cond, 2 * c, long2), tag="db")
        self.cur.extend(reg)

    # ---- subroutines ----------------------------------------------------------------------------
    def new_label(self):
        self.nlabel += 1
        return self.nlabel

    def t_call(self, use_frame=None, op=None, ub_err=False):
        if self.depth >= 3:
            return self.simple_template()
        saved = (self.fl, self.fp, set(self.res))
        # the callee's frame starts at caller-relative dd - ls and must lie above the caller's
        # reserved return pair, which a window overlapping it would overwrite
        lo = (max(self.res) + 2) if self.res else 0
        cand = [x for x in list(range(1, 16)) + [0] if (x or 16) >= lo]
        if not cand:
            return self.simple_template()
        d = self.r.choice(cand)
        dd = d or 16
        use_frame = self.chance(0.8) if use_frame is None else use_frame
        if not use_frame and ((self.fp + dd + 6 + 17 - self.spidx) & 0x7f) > 63:
            use_frame = True
        if use_frame:
            ls = self.r.randrange(0, min(dd - lo, 11) + 1)
            flnew = self.r.randrange(ls + 4, 16)
        else:
            ls, flnew = 0, 6
        fpnew = (self.fp + dd - ls) & 0x7f
        # keep every live frame inside one 64-register window above the main frame
        if ((self.fp + dd - ls + flnew - self.fp0) & 0x7f) > 60:
            return self.simple_template()
        flword = flnew & 0xf
        if ub_err and use_frame:
            self.hset()
            self.movi("G", 3, 0x00100000)
        label = self.new_label()
        if op == 0xef:
            form = "reg"
        elif op == 0xee:
            form = self.r.choice(["abs", "pc", "reg"])
        else:
            form = self.r.choice(["abs", "pc", "reg", "reg"])
        sl = 1 if op == 0xef else (0 if op == 0xee else self.r.getrandbits(1))
        if form == "abs":
            self.emit([(0xee << 8) | (d << 4) | 1] + ext_const14(0, 1),
                      lambda it, lay, lb=label: self._call_fix(it, lay, lb, "abs"), "call")
        elif form == "pc":
            self.emit([(0xee << 8) | (d << 4) | 0] + ext_const14(0, 1),
                      lambda it, lay, lb=label: self._call_fix(it, lay, lb, "pc"), "call")
        else:
            rs = self.pick_l() if sl else self.pick_g()
            long = self.r.getrandbits(1)
            c = self.r.randrange(-(1 << 29), 1 << 29) if long else self.r.randrange(-8000, 8000)
            kind = "L" if sl else "G"
            self.movi(kind, rs, 0, fix=lambda it, lay, lb=label, c=c, k=kind, rs=rs: self._movi_fix(it, lay, lb, c, k, rs))
            self.emit([((0xef if sl else 0xee) << 8) | (d << 4) | rs] + ext_const14(c, long), tag="call")
        if ub_err and use_frame:
            pass
        # callee
        self.fl, self.fp = flnew, fpnew
        self.res = {ls, ls + 1} if use_frame else {0, 1}
        self.depth += 1
        outer = self.cur
        self.cur = []
        saved_sp = self.spidx
        if use_frame:
            self.emit([(0xed << 8) | (flword << 4) | ls], tag="frame")
            self.frame_effect(fpnew, flnew)
            if ub_err:
                self.hset()
                self.movi("G", 3, 0x001f0000)
        for _ in range(self.r.randrange(0, 9)):
            self.body_template()
        self.emit([0x0500 | (ls if use_frame else 0)], tag="ret")
        self.ret_effect(saved[1])
        body = self.cur
        self.cur = outer
        self.depth -= 1
        self.subs.append((label, body))
        self.fl, self.fp, self.res = saved

    def _call_fix(self, it, lay, label, mode):
        tgt = lay.labels[label]
        if mode == "abs":
            it.w[1:] = ext_const14(s32(tgt), 1)
        else:
            pc_after = lay.addr(it) + 2 * len(it.w)
            it.w[1:] = ext_const14(s32(tgt - pc_after), 1)

    def _movi_fix(self, it, lay, label, c, kind, idx):
        tgt = lay.labels[label]
        v = (tgt - (c & ~1)) & M32
        dl = 1 if kind == "L" else 0
        it.w[:] = [((0x65 + (dl << 1)) << 8) | (idx << 4) | 1, v >> 16, v & 0xffff]

    def t_frame_main(self):
        """frame at main level: FP kept, FL changed (spill check against SP as MAME computes it)."""
        if self.depth or self.res:
            return self.simple_template()
        flnew = self.r.randrange(8, 16)
        self.emit([(0xed << 8) | ((flnew & 0xf) << 4) | 0], tag="frame")
        self.fl = flnew
        self.frame_effect(self.fp, self.fl)

    def ret_pair(self, user, trace, use_g):
        """Load a (PC, SR) pair and RET through it. The pc is the instruction after the RET; SR keeps
        the current FP and FL so RET's fill loop stays quiet; S comes from bit 0 of the pc."""
        box = []
        if use_g:
            a = self.r.randrange(3, 12 if self.loop_g else 14)
            kind = "G"
        else:
            a = self.pick_l(True)
            kind = "L"
        sbit = 0 if user else 1

        def fix(it, lay, box=box, sbit=sbit, kind=kind, a=a):
            it.w[:] = self.movi_words(kind, a, (lay.addr(box[0]) + 2) | sbit, "w")
        self.movi(kind, a, 0, fix=fix)
        sr = ((self.fp & 0x7f) << 25) | ((self.fl & 0xf) << 21) | ((1 if trace else 0) << 16) | self.lmask | self.r.randrange(16)
        self.movi(kind, a + 1, sr)
        box.append(self.emit([(0x0400 if use_g else 0x0500) | a], tag="ret"))

    def t_mode(self):
        """User mode (S=0) and/or trace mode (T=1) for a few instructions, then back to supervisor.
        The way back from user mode is a RET with S=1: the privilege check fires after the RET and
        the handler's RET resumes at the target."""
        if self.depth or self.res:
            return self.simple_template()
        user = self.chance(0.6)
        trace = self.chance(0.6) or not user
        use_g = self.chance(0.25)
        self.ret_pair(user, trace, use_g)
        for _ in range(self.r.randrange(2, 9)):
            x = self.r.random()
            if user and x < 0.15:
                self.t_hseq()
            elif user and x < 0.25:
                self.t_sr()
            else:
                self.simple_template()
        self.ret_pair(False, False, self.chance(0.25))

    def t_jump(self):
        """Writes to PC: sum/add/sub PC jump forward over a block, to an instruction boundary."""
        K = self.r.randrange(1, 5)
        with self.capture() as blk:
            for _ in range(K):
                self.simple_template()
        k = self.r.randrange(K + 1)
        off = self.nbytes(blk[:k])
        x = self.r.randrange(3)
        if x == 0:
            long = self.r.getrandbits(1)
            self.emit([(0x18 << 8)] + ext_const14(off, long), tag="sum")                       # SUM PC, PC, off
        elif x == 1:
            rs = self.pick_l()
            self.movi("L", rs, off)
            self.emit([(0x29 << 8) | rs], tag="add")                                          # ADD PC, Ls
        else:
            rs = self.pick_l()
            self.movi("L", rs, (-off) & M32)
            self.emit([(0x49 << 8) | rs], tag="sub")                                          # SUB PC, Ls
        self.cur.extend(blk)

    def mem_matrix(self):
        """Every ld/st sub-type and operand-bank combination once."""
        for kind in ("ld1", "ld2", "st1", "st2"):
            for sub, typs in ((0, [0]), (1, [0]), (2, [0]), (3, [0, 1, 2, 3])):
                for typ in typs:
                    for dl in (0, 1):
                        for sl in (0, 1):
                            self.t_ldst(kind, dl, sl, sub, typ=typ if sub == 3 else None)
        for op in range(0xd0, 0xe0):
            self.t_ldwr(op)
            self.t_ldwr(op)

    def imm_matrix(self):
        """Every immediate-group operation with every nibble, short and long form, both banks."""
        for name in IMMOPS:
            for nib in range(16):
                for long in (0, 1):
                    for dl in (0, 1):
                        self.t_imm(name, dl, long, nib)

    def shift_matrix(self):
        """Shift counts 0, 1, 15, 16, 31 in every immediate form, and register counts around 31/32."""
        for form in ("shrdi", "sardi", "shldi", "shri", "sari", "shli"):
            for n in (0, 1, 15, 16, 17, 31):
                hi = n >= 16
                if form.endswith("di"):
                    op = {"shrdi": 0x80, "sardi": 0x84, "shldi": 0x88}[form] + hi
                    rd = self.pick_l(True)
                    self.init("L", rd)
                    self.init("L", rd + 1)
                    self.emit([(op << 8) | (rd << 4) | (n & 15)], tag=form)
                else:
                    for dl in (0, 1):
                        base = {"shri": 0xa0, "sari": 0xa4, "shli": 0xa8}[form]
                        rd = self.pick_l() if dl else self.pick_g()
                        self.init("L" if dl else "G", rd)
                        self.emit([((base + (dl << 1) + hi) << 8) | (rd << 4) | (n & 15)], tag=form)

    def special_src_matrix(self):
        """PC and SR as the source of every two-register and constant-extension operation."""
        for name in ALU2:
            for rs in (0, 1):
                for dl in (0, 1):
                    self.t_alu2(name, dl, 0, rs_g=rs)
        for name in EXT2:
            for rs in (0, 1):
                for dl in (0, 1):
                    self.t_ext2(name, dl, 0, rs_g=rs)

    # ---- status register and H ------------------------------------------------------------------
    def t_sr(self):
        x = self.r.randrange(6)
        if x == 0:
            self.setflags(self.r.getrandbits(7) & 0x1f)
        elif x == 1:
            rs = self.pick_l()
            self.init("L", rs, (self.lmask | (self.r.getrandbits(16) & 0x7f9f)) & 0xffff)
            self.emit([(0x25 << 8) | (1 << 4) | rs], tag="mov")        # MOV SR, Ls
        elif x == 2:
            # ORI/XORI/ANDNI SR with bits that keep L and H as they are
            nib = 2
            op = self.r.choice([0x79, 0x7d, 0x75])
            imm = self.r.getrandbits(16) & 0x7f9f
            if op == 0x75:
                imm &= 0x7f9f
            self.emit([(op << 8) | (1 << 4) | nib, imm], tag="srimm")
        elif x == 3:
            rd = self.pick_g()
            self.emit([(0x24 << 8) | (rd << 4) | 1], tag="mov")      # MOV Gd, SR
        elif x == 4:
            rd = self.pick_l()
            self.emit([(0x26 << 8) | (rd << 4) | 1], tag="mov")        # MOV Ld, SR
        else:
            rd = self.pick_g()
            self.emit([(0x18 << 8) | (rd << 4) | 0] + ext_const14(self.r.randrange(-100, 100), self.r.getrandbits(1)), tag="sum")

    def t_hseq(self):
        """ORI SR,$20 then a MOV/MOVI that addresses g16..g31."""
        x = self.r.randrange(6)
        dst = self.r.choice([0, 1, 12, 13, 14, 15])          # g16 g17 g28..g31, never BCR/TPR/TCR/FCR/MCR/ISR/TR
        if x >= 4:
            # SP keeps its register index (the generator tracks it); UB moves within RAM above the data area
            self.hset()
            if x == 4:
                self.movi("G", 2, SP_BASE + 4 * self.spidx + self.r.randrange(4))
            else:
                self.movi("G", 3, self.r.choice([0x001f0000, 0x001e0003, 0x001fff00]))
            return
        srcs = [s for s in range(16) if s not in (7, 9)]       # not TR (g23), ISR (g25)
        self.hset()
        if x == 0:
            self.emit(self.movi_words("G", dst, self.val()), tag="movi_h")
        elif x == 1:
            rs = self.r.choice(srcs)
            self.emit([(0x24 << 8) | (dst << 4) | rs], tag="mov_h")
        elif x == 2:
            rd = self.pick_l()
            rs = self.r.choice(srcs)
            self.emit([(0x26 << 8) | (rd << 4) | rs], tag="mov_h")
        else:
            rs = self.src_l()
            self.emit([(0x25 << 8) | (dst << 4) | rs], tag="mov_h")

    def t_movd_src(self):
        # movd with SR/PC as the source or a degenerate destination
        rd = self.pick_l(True)
        self.emit([(0x06 << 8) | (rd << 4) | self.r.choice([1, 0])], tag="movd")

    # ---- program structure --------------------------------------------------------------------
    def body_template(self):
        x = self.r.random()
        if x < 0.68:
            self.simple_template()
        elif x < 0.86:
            self.t_branch()
        elif x < 0.93:
            self.t_dbranch()
        else:
            self.t_call()

    def prologue(self):
        self.hset()
        self.movi("G", 2, SP_BASE)
        self.hset()
        self.movi("G", 3, 0x001f0000)
        # CALL PC, 0 continues at the next instruction with FP raised by Ld: the registers below
        # the new FP are dead, and the frame below makes SP spill them. One seed in three goes on
        # to FP near 127, with a frame after each call to keep SP's index within 64 of FP, so the
        # 7-bit FP wraps during the run.
        if self.wrap:
            while self.fp < self.r.randrange(100, 118):
                d = self.r.randrange(8, 16)
                self.emit([(0xee << 8) | (d << 4) | 0] + ext_const14(0, 0), tag="call")
                self.fp += d
                fl = self.r.randrange(8, 16)
                self.emit([(0xed << 8) | ((fl & 0xf) << 4) | 0], tag="frame")
                self.fl = fl
                self.frame_effect(self.fp, fl)
        else:
            while self.fp < 38:
                d = self.r.randrange(8, 16)
                if self.fp + d + 16 > 58:
                    break
                self.emit([(0xee << 8) | (d << 4) | 0] + ext_const14(0, 0), tag="call")
                self.fp += d
        self.fp0 = self.fp
        self.emit([(0xed << 8) | ((self.fl & 0xf) << 4) | 0], tag="frame")
        self.frame_effect(self.fp, self.fl)
        if self.irq:
            # FCR resets to all ones, which inhibits the interrupt inputs (check_interrupts). The
            # driver's vblank is irq1_line_hold = input line 1 = INT2 (trap 52); clear its inhibit
            # bit 29 and INT1's bit 28.
            self.hset()
            self.movi("G", 10, 0xcfffffff)
            self.emit([0x7512, 0x8000], tag="srimm")              # ANDNI SR, $8000: clear L
        for g in range(2, 16):
            self.init("G", g)
        for l in range(self.fl):
            self.init("L", l)

    def cond_matrix(self):
        nonskip = 0
        for f in range(16):
            for cond in self.CONDS + [0xfc]:
                self.setflags(f)
                self.emit(pcrel_words(cond, 2, False), tag="b")
                self.emit([(0x28 << 8) | (3 << 4) | 4], tag="add")
            for cond in range(0xe0, 0xed):
                self.setflags(f)
                self.emit(pcrel_words(cond, 4, False), tag="db")
                self.emit([(0x24 << 8) | (5 << 4) | 6], tag="mov")
                self.emit([(0x28 << 8) | (3 << 4) | 4], tag="add")
            for code in range(4, 16):
                self.setflags(f)
                self.emit([((0xfc | (code >> 2)) << 8) | ((code * 3 % 61) << 2) | (code & 3)], tag="trap")
        for f in range(16):
            for hi in (0, 1):
                for n in range(16):
                    dl = (f + n) & 1
                    self.setflags(f)
                    self.emit([((0xb8 + (dl << 1) + hi) << 8) | ((self.pick_l() if dl else 2 + (n & 7)) << 4) | n], tag="set")

    def opcode_pass(self):
        """At least one instance of every primary opcode except 0xcf."""
        for op in range(256):
            if op == 0xcf:
                continue
            self.force(op)

    def force(self, op):
        hi = op >> 4
        if op < 0x60 or op in range(0xb0, 0xb8) or op in range(0xbc, 0xc0):
            base = op & ~3
            dl, sl = (op >> 1) & 1, op & 1
            if base in EXT2.values():
                self.t_ext2(BASE_NAME[base], dl, sl)
            else:
                self.t_alu2(BASE_NAME[base], dl, sl)
        elif op < 0x80:
            base = op & ~3
            self.t_imm(IMM_NAME[base], (op >> 1) & 1, op & 1)
        elif op < 0x90:
            m = {0x80: "shrdi", 0x81: "shrdi", 0x82: "shrd", 0x83: "shr", 0x84: "sardi", 0x85: "sardi",
                 0x86: "sard", 0x87: "sar", 0x88: "shldi", 0x89: "shldi", 0x8a: "shld", 0x8b: "shl",
                 0x8c: "res", 0x8d: "res", 0x8e: "testlz", 0x8f: "rol"}
            f = m[op]
            if f in ("shrdi", "sardi", "shldi"):
                rd = self.pick_l(True)
                self.init("L", rd)
                self.init("L", rd + 1)
                self.emit([(op << 8) | (rd << 4) | self.r.randrange(16)], tag=f)
            elif f == "res":
                self.emit([(op << 8) | self.r.getrandbits(8)], tag="reserved")
            else:
                self.t_shift(f)
        elif op < 0xa0:
            kind = ["ld1", "ld2", "st1", "st2"][(op - 0x90) >> 2]
            self.t_ldst(kind, (op >> 1) & 1, op & 1)
        elif op < 0xb0:
            if op >= 0xac:
                self.emit([(op << 8) | self.r.getrandbits(8)], tag="reserved")
            else:
                f = ["shri", "sari", "shli"][(op - 0xa0) >> 2]
                self.t_shift(f, ((op - 0xa0) >> 1) & 1)
                self.cur[-1].w[0] = (self.cur[-1].w[0] & 0xff) | (op << 8)
        elif 0xb8 <= op <= 0xbb:
            self.t_set((op >> 1) & 1, op & 1)
        elif op <= 0xcd:
            self.t_fp(op - 0xc0)
        elif op == 0xce:
            self.t_extend()
        elif op < 0xe0:
            self.t_ldwr(op)
        elif op <= 0xec:
            self.t_dbranch(op) if op != 0xec else self.t_dbranch(0xec)
        elif op == 0xed:
            self.t_frame_main()
            if not self.cur or self.cur[-1].tag != "frame":
                self.emit([(0xed << 8) | ((self.fl & 0xf) << 4)], tag="frame")
        elif op <= 0xef:
            self.t_call_op(op)
        elif op <= 0xfc:
            self.t_branch(op)
        else:
            self.t_trap(code=self.r.randrange(4, 16))
            self.cur[-1].w[0] = (self.cur[-1].w[0] & 0xff) | (op << 8)

    def t_call_op(self, op):
        self.t_call(use_frame=True, op=op)
        if not any(i.tag == "call" and i.w[0] >> 8 == op for i in self.cur[-3:]):
            pass

    def random_mix(self, n):
        w = [("alu2", 22), ("imm", 12), ("shift", 8), ("set", 2), ("muldiv", 12 if self.irq else 3),
             ("ext2", 6), ("ldst", 14), ("ldwr", 6), ("branch", 6), ("dbranch", 4), ("dbranch2", 2),
             ("call", 3), ("trap", 2), ("fp", 1), ("extend", 2), ("sr", 2), ("hseq", 2),
             ("chk", 3), ("frame", 1), ("movd", 1), ("mode", 1), ("jump", 2)]
        if self.irq:
            w.append(("divburn", 130))
        if self.loop_g:
            w = [x for x in w if x[0] != "frame"]       # FL must be the same on every pass
        names = [x for x, _ in w]
        wts = [y for _, y in w]
        start = sum(len(s.w) for s in self.cur)
        while len(self.cur) < n:
            t = self.r.choices(names, wts)[0]
            getattr(self, "m_" + t)()

    def m_divburn(self):
        # back-to-back 36-cycle divides on whatever the registers hold: spends cycles so that
        # MAME's vblank interrupt arrives within a few tens of thousands of instructions
        for _ in range(self.r.randrange(4, 12)):
            self.t_alu2(self.r.choice(["divu", "divu", "divu", "divs"]), bare=True)

    def m_mode(self): self.t_mode()
    def m_jump(self): self.t_jump()
    def m_alu2(self): self.t_alu2()
    def m_imm(self): self.t_imm()
    def m_shift(self): self.t_shift()
    def m_set(self): self.t_set()
    def m_muldiv(self): self.t_muldiv()
    def m_ext2(self): self.t_ext2()
    def m_ldst(self): self.t_ldst()
    def m_ldwr(self): self.t_ldwr()
    def m_branch(self): self.t_branch()
    def m_dbranch(self): self.t_dbranch()
    def m_dbranch2(self): self.t_dbranch2()
    def m_call(self): self.t_call(ub_err=self.chance(0.08))
    def m_trap(self): self.t_trap()
    def m_fp(self): self.t_fp()
    def m_extend(self): self.t_extend()
    def m_sr(self): self.t_sr()
    def m_hseq(self): self.t_hseq()
    def m_chk(self): self.t_chk_range()
    def m_frame(self): self.t_frame_main()
    def m_movd(self): self.t_movd_src()


class Layout:
    def __init__(self):
        self.pos = {}
        self.labels = {}

    def addr(self, it):
        return self.pos[id(it)]


def build(seed, irq, n, dsp=False, loop=0):
    g = Gen(seed, irq, dsp)
    g.prologue()
    g.cond_matrix()
    g.opcode_pass()
    g.mem_matrix()
    g.special_src_matrix()
    g.imm_matrix()
    g.shift_matrix()
    if loop > 1:
        # the random part repeats `loop` times (the only backward branch): enough cycles for several
        # vblank interrupts without a large image
        g.loop_g = 13
        g.movi("G", 13, loop, form="w")
        head = len(g.cur)
        g.random_mix(head + n)
        body = g.cur[head:]
        sub = Item([(0x18 << 8) | (13 << 4) | 13] + ext_const14(-1, 0), tag="sum")
        g.cur.append(sub)
        off = -(g.nbytes(body) + 2 * len(sub.w) + 4)
        g.emit(pcrel_words(0xf3, off, True), tag="b")                       # BNE: Z clear after the decrement
    else:
        g.random_mix(n)
    main = g.cur
    lay = Layout()
    endloop = [Item([0xfc7f], tag="end"), Item([0xfc7f], tag="end")]
    order = [(None, main + endloop)] + g.subs          # the self-loop follows the main stream
    a = ROM_BASE
    for label, items in order:
        if label is not None:
            lay.labels[label] = a
        for it in items:
            lay.pos[id(it)] = a
            a += 2 * len(it.w)
    assert a < EMU_BASE, "program too large: %#x" % a
    img = bytearray(ROM_SIZE)
    for _, items in order:
        for it in items:
            if it.fix:
                it.fix(it, lay)
    for _, items in order:
        for it in items:
            off = lay.pos[id(it)] - ROM_BASE
            for i, w in enumerate(it.w):
                struct.pack_into(">H", img, off + 2 * i, w & 0xffff)
    # emulated-code handlers: RET PC, L3
    for k in range(16):
        struct.pack_into(">H", img, EMU_BASE - ROM_BASE + 16 * k, 0x0503)
    # trap table: RET PC, L0 in every entry; the reset entry branches to the start of the image
    for t in range(64):
        struct.pack_into(">H", img, TRAP_BASE - ROM_BASE + 4 * t, 0x0500)
    # Trace exception (trap 57): MAME takes it after every instruction while T and P are both set, and
    # the saved SR has P set, so a bare RET would trap again at once. The handler clears P in the
    # saved SR (L1) first: ANDNI L1, $20000; RET PC, L0. It does not fit in the 4-byte entry.
    th = 0xfffffee0
    for i, w in enumerate([0x7711, 0x0002, 0x0000, 0x0500]):
        struct.pack_into(">H", img, th - ROM_BASE + 2 * i, w)
    struct.pack_into(">HH", img, TRAP_BASE - ROM_BASE + 4 * 57,
                     *pcrel_words(0xfc, th - (TRAP_BASE + 4 * 57 + 4), True))
    off = (ROM_BASE - (TRAP_BASE + 4 * 62 + 4)) & 0xffffff
    struct.pack_into(">HH", img, TRAP_BASE - ROM_BASE + 4 * 62,
                     0xfc80 | ((off >> 16) & 0x7f), (off & 0xfffe) | ((off >> 23) & 1))
    count = sum(len(i) for i in [main] + [s for _, s in g.subs]) + 2
    tags = {}
    for items in [main] + [s for _, s in g.subs]:
        for it in items:
            tags[it.tag] = tags.get(it.tag, 0) + 1
    return img, dict(static=count, end=lay.pos[id(endloop[0])], subs=len(g.subs), tags=tags)


def find_zip():
    import os
    sys.path.insert(0, str(REPO / "scripts"))
    from mame_capture import mame_paths, rompath
    mame_dir, _ = mame_paths()
    for d in rompath(mame_dir).split(";"):
        p = Path(d) / "misncrft.zip"
        if p.exists():
            return p
    sys.exit("misncrft.zip not found on the ROM path")


def write_zip(img, out):
    src = zipfile.ZipFile(find_zip())
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        for i in src.infolist():
            z.writestr(i.filename, bytes(img) if i.filename == "prg-rom2.bin" else src.read(i.filename))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--irq", action="store_true", help="clear L and the FCR inhibits at start: the vblank interrupt (INT2, trap 52) is taken when MAME raises it")
    ap.add_argument("--n", type=int, default=4000, help="approximate static instruction count of the random part")
    ap.add_argument("--out", required=True)
    ap.add_argument("--dsp", action="store_true", help="also generate the EH* DSP extend functions and invalid ones")
    ap.add_argument("--loop", type=int, default=0, help="repeat the random part this many times (counter in g13)")
    ap.add_argument("--no-zip", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    img, info = build(a.seed, a.irq, a.n, a.dsp, a.loop)
    (out / "prg-rom2.bin").write_bytes(bytes(img))
    if not a.no_zip:
        write_zip(img, out / "misncrft.zip")
    (out / "info.txt").write_text(
        "seed %d irq %d static %d end %08x subs %d loop %d\n%s\n" % (a.seed, a.irq, info["static"], info["end"], info["subs"], a.loop,
        " ".join("%s=%d" % kv for kv in sorted(info["tags"].items()))), encoding="utf-8")
    print("seed %d irq %d: %d static instructions, end loop at %08x, %d subroutines" %
          (a.seed, a.irq, info["static"], info["end"], info["subs"]))


if __name__ == "__main__":
    main()
