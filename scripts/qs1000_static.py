#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Recursive-descent scan of the QS1000 firmware (u7) for 8052-only resources.

    python scripts/qs1000_static.py debug/qs1000/rom/misncrft_u7.bin [--limit 0x10000]

Roots: reset (0x0000) and the interrupt vectors 0x03, 0x0B, 0x13, 0x1B, 0x23. 0x2B (Timer 2)
is not a root: it lies inside the init code, so it only matters if it executes. Follows
AJMP/LJMP/SJMP/conditional branches, ACALL/LCALL (and their fall-through) and, for
JMP @A+DPTR, the table of AJMP/LJMP entries at the last MOV DPTR,#imm that preceded it.
MOVC and MOVX targets are data and not followed.

Reports (with addresses), among reachable instructions:
  - direct accesses to the 8052 SFRs T2CON C8, T2MOD C9, RCAP2L CA, RCAP2H CB, TL2 CC, TH2 CD
  - bit accesses to T2CON bits C8-CF, IE.5 (ET2, 0xAD) and IP.5 (PT2, 0xBD)
  - byte writes/ORL to IE (A8) or IP (B8) whose immediate has bit 5 set
  - code at vector 0x2B
  - MOV SP,#imm and indirect (@R0/@R1) instruction counts (upper RAM needs dynamic evidence)
"""
import argparse
import sys
from collections import defaultdict
from pathlib import Path

ALU = {0x00: "ADD", 0x10: "ADDC", 0x40: "ORL", 0x50: "ANL", 0x60: "XRL", 0x90: "SUBB"}
SFR_NAMES = {0x80: "P0", 0x81: "SP", 0x82: "DPL", 0x83: "DPH", 0x87: "PCON", 0x88: "TCON",
             0x89: "TMOD", 0x8A: "TL0", 0x8B: "TL1", 0x8C: "TH0", 0x8D: "TH1", 0x90: "P1",
             0x98: "SCON", 0x99: "SBUF", 0xA0: "P2", 0xA8: "IE", 0xB0: "P3", 0xB8: "IP",
             0xC8: "T2CON", 0xC9: "T2MOD", 0xCA: "RCAP2L", 0xCB: "RCAP2H", 0xCC: "TL2",
             0xCD: "TH2", 0xD0: "PSW", 0xE0: "ACC", 0xF0: "B"}
T2_SFR = {0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD}


def decode(rom, pc):
    """-> dict(len, text, flow, targets, dirs, bits, imm, ind)
    flow: 'seq', 'jmp' (no fall-through), 'cond', 'call', 'ret', 'ijmp'."""
    op = rom[pc]
    b1 = rom[pc + 1] if pc + 1 < len(rom) else 0
    b2 = rom[pc + 2] if pc + 2 < len(rom) else 0
    d = dict(len=1, text="", flow="seq", targets=[], dirs=[], bits=[], imm=None, ind=False,
             dirw=[], mnem="")
    lo, hi = op & 15, op & 0xF0
    rel = lambda n, r: (pc + n + (r - 256 if r & 0x80 else r)) & 0xFFFF
    if lo == 1:
        d["len"] = 2
        tgt = ((pc + 2) & 0xF800) | ((op >> 5) << 8) | b1
        if op & 0x10:
            d.update(flow="call", targets=[tgt], text=f"ACALL {tgt:04X}", mnem="ACALL")
        else:
            d.update(flow="jmp", targets=[tgt], text=f"AJMP {tgt:04X}", mnem="AJMP")
        return d
    if op == 0x02:
        t = b1 << 8 | b2
        d.update(len=3, flow="jmp", targets=[t], text=f"LJMP {t:04X}", mnem="LJMP")
    elif op == 0x12:
        t = b1 << 8 | b2
        d.update(len=3, flow="call", targets=[t], text=f"LCALL {t:04X}", mnem="LCALL")
    elif op == 0x22:
        d.update(flow="ret", text="RET", mnem="RET")
    elif op == 0x32:
        d.update(flow="ret", text="RETI", mnem="RETI")
    elif op == 0x80:
        t = rel(2, b1)
        d.update(len=2, flow="jmp", targets=[t], text=f"SJMP {t:04X}", mnem="SJMP")
    elif op in (0x40, 0x50, 0x60, 0x70):
        t = rel(2, b1)
        d.update(len=2, flow="cond", targets=[t], text=f"J{['C','NC','Z','NZ'][(op>>4)-4]} {t:04X}",
                 mnem="Jcc")
    elif op in (0x10, 0x20, 0x30):
        t = rel(3, b2)
        d.update(len=3, flow="cond", targets=[t], bits=[b1], mnem="JBC/JB/JNB",
                 text=f"{ {0x10:'JBC',0x20:'JB',0x30:'JNB'}[op]} bit{b1:02X},{t:04X}")
    elif op == 0x73:
        d.update(flow="ijmp", text="JMP @A+DPTR", mnem="JMP@")
    elif op == 0xD5:
        t = rel(3, b2)
        d.update(len=3, flow="cond", targets=[t], dirs=[b1], dirw=[b1], mnem="DJNZ",
                 text=f"DJNZ {b1:02X},{t:04X}")
    elif 0xD8 <= op <= 0xDF:
        t = rel(2, b1)
        d.update(len=2, flow="cond", targets=[t], mnem="DJNZ", text=f"DJNZ R{lo-8},{t:04X}")
    elif op == 0xB4:
        t = rel(3, b2)
        d.update(len=3, flow="cond", targets=[t], mnem="CJNE", text=f"CJNE A,#{b1:02X},{t:04X}")
    elif op == 0xB5:
        t = rel(3, b2)
        d.update(len=3, flow="cond", targets=[t], dirs=[b1], mnem="CJNE",
                 text=f"CJNE A,{b1:02X},{t:04X}")
    elif op in (0xB6, 0xB7):
        t = rel(3, b2)
        d.update(len=3, flow="cond", targets=[t], ind=True, mnem="CJNE",
                 text=f"CJNE @R{lo-6},#{b1:02X},{t:04X}")
    elif 0xB8 <= op <= 0xBF:
        t = rel(3, b2)
        d.update(len=3, flow="cond", targets=[t], mnem="CJNE", text=f"CJNE R{lo-8},#{b1:02X},{t:04X}")
    elif op == 0x90:
        d.update(len=3, text=f"MOV DPTR,#{b1<<8|b2:04X}", mnem="MOV DPTR", imm=b1 << 8 | b2)
    elif op == 0x75:
        d.update(len=3, dirs=[b1], dirw=[b1], imm=b2, mnem="MOV dir,#", text=f"MOV {b1:02X},#{b2:02X}")
    elif op == 0x85:
        d.update(len=3, dirs=[b1, b2], dirw=[b2], mnem="MOV dir,dir", text=f"MOV {b2:02X},{b1:02X}")
    elif op in (0x43, 0x53, 0x63):
        n = {0x43: "ORL", 0x53: "ANL", 0x63: "XRL"}[op]
        d.update(len=3, dirs=[b1], dirw=[b1], imm=b2, mnem=f"{n} dir,#", text=f"{n} {b1:02X},#{b2:02X}")
    elif op in (0x42, 0x52, 0x62):
        n = {0x42: "ORL", 0x52: "ANL", 0x62: "XRL"}[op]
        d.update(len=2, dirs=[b1], dirw=[b1], mnem=f"{n} dir,A", text=f"{n} {b1:02X},A")
    elif op in (0x72, 0x82, 0xA0, 0xB0):
        n = {0x72: "ORL C,bit", 0x82: "ANL C,bit", 0xA0: "ORL C,/bit", 0xB0: "ANL C,/bit"}[op]
        d.update(len=2, bits=[b1], mnem=n, text=f"{n} {b1:02X}")
    elif op in (0x92, 0xA2, 0xB2, 0xC2, 0xD2):
        n = {0x92: "MOV bit,C", 0xA2: "MOV C,bit", 0xB2: "CPL bit", 0xC2: "CLR bit",
             0xD2: "SETB bit"}[op]
        d.update(len=2, bits=[b1], mnem=n, text=f"{n} {b1:02X}")
    elif op in (0xC0, 0xD0):
        n = "PUSH" if op == 0xC0 else "POP"
        d.update(len=2, dirs=[b1], mnem=n, text=f"{n} {b1:02X}", dirw=[b1] if op == 0xD0 else [])
    elif op in (0x05, 0x15, 0xF5, 0xC5, 0x86, 0x87) or 0x88 <= op <= 0x8F:
        n = {0x05: "INC", 0x15: "DEC", 0xF5: "MOV dir,A", 0xC5: "XCH A,dir"}.get(op, "MOV dir,x")
        wr = op not in (0xC5,) or True
        d.update(len=2, dirs=[b1], dirw=[b1] if op != 0xC5 else [b1], mnem=n, text=f"{n} {b1:02X}",
                 ind=op in (0x86, 0x87))
    elif op in (0xA6, 0xA7) or 0xA8 <= op <= 0xAF:
        d.update(len=2, dirs=[b1], mnem="MOV x,dir", text=f"MOV x,{b1:02X}", ind=op in (0xA6, 0xA7))
    elif op == 0xE5:
        d.update(len=2, dirs=[b1], mnem="MOV A,dir", text=f"MOV A,{b1:02X}")
    elif hi in ALU and lo in (4, 5):
        n = ALU[hi]
        if lo == 4:
            d.update(len=2, imm=b1, mnem=f"{n} A,#", text=f"{n} A,#{b1:02X}")
        else:
            d.update(len=2, dirs=[b1], mnem=f"{n} A,dir", text=f"{n} A,{b1:02X}")
    elif hi in ALU and lo in (6, 7):
        d.update(ind=True, mnem=f"{ALU[hi]} A,@Ri", text=f"{ALU[hi]} A,@R{lo-6}")
    elif op in (0x74, 0x76, 0x77) or 0x78 <= op <= 0x7F:
        d.update(len=2, imm=b1, ind=op in (0x76, 0x77), mnem="MOV x,#", text=f"MOV x,#{b1:02X}")
    elif op in (0x06, 0x07, 0x16, 0x17, 0xC6, 0xC7, 0xD6, 0xD7, 0xE6, 0xE7, 0xF6, 0xF7, 0xE2, 0xE3,
                0xF2, 0xF3):
        d.update(ind=True, mnem="@Ri", text=f"op{op:02X} @R{lo&1}")
    elif op in (0x83, 0x93):
        d.update(mnem="MOVC", text="MOVC")
    elif op in (0xE0, 0xF0):
        d.update(mnem="MOVX", text="MOVX @DPTR")
    else:
        d.update(mnem="op", text=f"op{op:02X}")
    return d


def scan(rom, limit, extra=()):
    seen, order = {}, []
    work = [0x00, 0x03, 0x0B, 0x13, 0x1B, 0x23] + list(extra)
    roots = {a: None for a in work}
    pred = {}
    while work:
        pc = work.pop()
        last = None
        prev = roots.get(pc)
        while pc < limit and pc not in seen:
            pred[pc] = prev
            d = decode(rom, pc)
            if pc + d["len"] > limit:
                break
            seen[pc] = d
            order.append(pc)
            if d["mnem"] == "MOV DPTR":
                last = d["imm"]
            fl = d["flow"]
            for t in d["targets"]:
                if t not in seen:
                    work.append(t)
                    roots.setdefault(t, pc)
            if fl in ("jmp", "ret"):
                break
            if fl == "ijmp":
                if last is not None:
                    t = last
                    while t + 1 < limit and t not in seen:
                        o = rom[t]
                        if o & 15 == 1 and not o & 0x10:
                            tgt = ((t + 2) & 0xF800) | ((o >> 5) << 8) | rom[t + 1]
                            work.append(tgt)
                            roots.setdefault(tgt, pc)
                            t += 2
                        elif o == 0x02:
                            work.append(rom[t + 1] << 8 | rom[t + 2])
                            t += 3
                        else:
                            break
                break
            prev = pc
            pc += d["len"]
    return seen, pred


def chain(pred, pc, depth=40):
    out = [pc]
    while pred.get(pc) is not None and len(out) < depth:
        pc = pred[pc]
        out.append(pc)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("--limit", type=lambda x: int(x, 0), default=0x8000)
    ap.add_argument("--seed", help="a *_instr.trace: its executed PCs are added as roots (reaches code "
                    "behind computed jumps and RET dispatch that the scan cannot follow)")
    a = ap.parse_args()
    rom = Path(a.rom).read_bytes()[:a.limit]
    rom = rom + bytes(8)
    extra = set()
    if a.seed:
        for line in open(a.seed):
            if line[0] != "#":
                extra.add(int(line.split()[1], 16))
    seen, pred = scan(rom, a.limit, sorted(extra))
    if extra:
        print(f"seeded with {len(extra)} executed PCs")
    print(f"{a.rom}: {len(seen)} reachable instructions, "
          f"{sum(d['len'] for d in seen.values())} bytes, max address {max(seen):04X}")
    over = [p for p in seen if p >= 0x8000]
    print(f"reachable at >= 0x8000 (MAME maps program ROM only at 0000-7FFF): {len(over)}")
    print("vector code present:", {f"{v:04X}": (v in seen) for v in (0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B)})
    print(f"bytes at 0x2B: {rom[0x2b:0x2b+3].hex()} (inside the init code starting at 0x24)")
    hits = defaultdict(list)
    for pc in sorted(seen):
        d = seen[pc]
        for x in d["dirs"]:
            if x in T2_SFR:
                hits["T2 SFR direct"].append((pc, d["text"]))
        for x in d["bits"]:
            if 0xC8 <= x <= 0xCF:
                hits["T2CON bit"].append((pc, d["text"]))
            if x == 0xAD:
                hits["IE.5 (ET2)"].append((pc, d["text"]))
            if x == 0xBD:
                hits["IP.5 (PT2)"].append((pc, d["text"]))
        for x in d["dirw"]:
            if x in (0xA8, 0xB8) and d["imm"] is not None and d["imm"] & 0x20:
                hits["IE/IP immediate with bit 5"].append((pc, d["text"]))
        if d["mnem"] == "MOV dir,#" and d["dirs"][0] == 0x81:
            hits["MOV SP,#imm"].append((pc, d["text"]))
        if d["ind"]:
            hits["indirect @Ri (iram)"].append((pc, d["text"]))
    for k in ("T2 SFR direct", "T2CON bit", "IE.5 (ET2)", "IP.5 (PT2)", "IE/IP immediate with bit 5",
              "MOV SP,#imm"):
        print(f"\n{k}: {len(hits[k])}")
        for pc, t in hits[k][:40]:
            print(f"  {pc:04X}  {t}   via " + " <- ".join(f"{x:04X}" for x in chain(pred, pc, 8)))
    print(f"\nindirect @Ri instructions reachable: {len(hits['indirect @Ri (iram)'])}"
          " (whether Ri >= 0x80 needs the dynamic trace)")
    # writes of IE / IP with non-bit-5 immediates, for context
    print("\nIE/IP direct writes:")
    for pc in sorted(seen):
        d = seen[pc]
        for x in d["dirw"]:
            if x in (0xA8, 0xB8):
                print(f"  {pc:04X}  {d['text']}")


if __name__ == "__main__":
    sys.exit(main())
