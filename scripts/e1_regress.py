#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""E1 ISA conformance regression: generate, trace in MAME, replay in the Verilator bench, summarise.

    python scripts/e1_regress.py --seeds 1 2 3 [--irq-seeds 101 102] [--n 4000] [--waits 0 3]
                                 [--out debug/e1] [-v]
    python scripts/e1_regress.py --replay [--pipe] [--jobs 8] [--waits 0 3]

--replay runs the bench again on every trace already under <out> (no generation, no MAME), in parallel;
--pipe builds the bench with rtl/e1/e1_pipe.sv instead of e1_cpu.sv (bench output bench_pipe_wait<k>.txt).

Per seed: scripts/e1_gen_test.py writes <out>/<name>/ (prg-rom2.bin, misncrft.zip), MAME
(-nodrc, scripts/mame_e1_trace.py --rompath) writes <out>/<name>/ref/, then
scripts/run_verilator.sh e1_tb (+cont=1) replays it for each wait-state setting up to the first
self-loop of the program; the bench output goes to <out>/<name>/bench_wait<k>.txt. Output: one
line per run, the primary opcode coverage of all traces, and the failures grouped by mnemonic.
Traces stay under <out> (debug/ is gitignored). Exit status 1 if any run failed.
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from e1_coverage import opcodes  # noqa: E402

ALLFAIL = []


def bash():
    """Git bash (scripts/run_verilator.sh re-executes itself under MSYS2); not WSL's bash.exe."""
    for c in ("C:/Program Files/Git/bin/bash.exe", "C:/Program Files (x86)/Git/bin/bash.exe"):
        if Path(c).exists():
            return c
    return shutil.which("bash") or "bash"


def sh(cmd, **kw):
    if cmd[0].endswith(".sh"):
        cmd = [bash()] + cmd
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, **kw)


def loop_index(trace, end):
    """Index of the first instruction executed at the end self-loop's address."""
    with open(trace, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line[0] == "#":
                continue
            p = line.split(None, 2)
            if int(p[1], 16) == end:
                return int(p[0])
    return None


def parse_failures(txt):
    """Bench output -> [(kind, idx, pc, disasm, detail)] of the primary (non-cascade) failures."""
    out = []
    for b in re.split(r"(?m)^(?=MISMATCH at instruction)", txt):
        head = b.split("\n")[0]
        m = re.match(r"MISMATCH at instruction (\d+) \(([^)]*)\)", head)
        if not m or "(cascade)" in head:
            continue
        d = re.search(r"instruction idx (\d+): (\w+) \w+\s+\w+: (.*)", b)
        if d:
            idx, pc, dis = int(d.group(1)), d.group(2), d.group(3).strip()
        else:
            d = re.search(r"pc=(\w+)\s+\w+: (.*)", b)
            idx, pc, dis = int(m.group(1)), (d.group(1) if d else "?"), (d.group(2).strip() if d else "?")
        out.append((m.group(2), idx, pc, dis, "\n".join(b.split("\n")[1:]).strip()))
    return out


def one(name, seed, irq, n, waits, out, mame_n, verbose, extra):
    d = out / name
    r = sh([sys.executable, "scripts/e1_gen_test.py", "--seed", str(seed), "--n", str(n), "--out", str(d)]
           + (["--irq"] if irq else []) + extra)
    if r.returncode:
        return [(name, "GEN-FAIL", r.stdout + r.stderr)], None
    info = (d / "info.txt").read_text().split("\n")[0]
    static = int(re.search(r"static (\d+)", info).group(1))
    end = int(re.search(r"end ([0-9a-f]+)", info).group(1), 16)
    nrun = mame_n or int(static * 1.5) + 2000
    instr, bus = d / "ref" / "misncrft_instr.trace", d / "ref" / "misncrft_bus.trace"
    for attempt in range(3):
        # a trap-heavy seed can take more than 1.5 x static instructions: trace again with twice as many
        r = sh([sys.executable, "scripts/mame_e1_trace.py", "misncrft", str(nrun), "--out", str(d / "ref"),
                "--rompath", str(d)])
        if r.returncode or not instr.exists():
            if attempt == 0:
                continue          # one retry: two MAME instances started together can clash
            return [(name, "MAME-FAIL", r.stdout[-800:] + r.stderr[-800:])], None
        li = loop_index(instr, end)
        if li is not None:
            break
        nrun *= 2
    if li is None:
        return [(name, "NO-LOOP", "trace of %d instructions never reached the end loop" % nrun)], str(instr)
    nbench = li + 2
    res = []
    retraced = []
    for w in waits:
        r = sh(["scripts/run_verilator.sh", "e1_tb", "+instr=" + str(instr), "+bus=" + str(bus),
                "+n=%d" % nbench, "+wait=%d" % w, "+cont=1"])
        txt = r.stdout + r.stderr
        if re.search(r"RTL made fewer bus accesses than MAME\)\s+expected \d+ rows, consumed 0;", txt) and not retraced:
            # MAME's debug trace now and then attributes sequential ROM reads (pc+6...) and later rows to an
            # instruction that makes no access; it differs from one MAME run to the next. Trace again once.
            retraced.append(name)
            r = sh([sys.executable, "scripts/mame_e1_trace.py", "misncrft", str(nrun), "--out", str(d / "ref"),
                    "--rompath", str(d)])
            li = loop_index(instr, end)
            nbench = (li or nbench) + 2
            r = sh(["scripts/run_verilator.sh", "e1_tb", "+instr=" + str(instr), "+bus=" + str(bus),
                    "+n=%d" % nbench, "+wait=%d" % w, "+cont=1"])
            txt = r.stdout + r.stderr
        (d / ("bench_wait%d.txt" % w)).write_text(txt, encoding="utf-8")
        m = re.search(r"(PASS|FAIL): (\d+) instructions", txt)
        ints = re.search(r"interrupts taken: (\d+)", txt)
        status = m.group(1) if m else "ERROR"
        fl = parse_failures(txt)
        ALLFAIL.extend((name, w) + f for f in fl)
        res.append((name + " wait=%d" % w, status,
                    "%s instr=%d irqs=%s failing=%d" % (info, nbench, ints.group(1) if ints else "?", len(fl))
                    + ("\n" + txt[-1500:] if status == "ERROR" else "")))
    return res, str(instr)


def replay(d, waits, exe, tag):
    """The bench on <d>'s stored trace, up to the program's end loop."""
    info = (d / "info.txt").read_text().split("\n")[0]
    end = int(re.search(r"end ([0-9a-f]+)", info).group(1), 16)
    instr, bus = d / "ref" / "misncrft_instr.trace", d / "ref" / "misncrft_bus.trace"
    li = loop_index(instr, end) if instr.exists() else None
    if li is None:
        return [(d.name, "NO-TRACE", "")]
    res = []
    for w in waits:
        r = subprocess.run([str(exe), "+instr=" + str(instr), "+bus=" + str(bus), "+n=%d" % (li + 2), "+wait=%d" % w,
                            "+cont=1"], cwd=REPO, capture_output=True, text=True)
        txt = r.stdout + r.stderr
        (d / ("bench_%swait%d.txt" % (tag, w))).write_text(txt, encoding="utf-8")
        m = re.search(r"(PASS|FAIL): (\d+) instructions, \d+ cycles \(([\d.]+) clk", txt)
        ints = re.search(r"interrupts taken: (\d+)", txt)
        fl = parse_failures(txt)
        ALLFAIL.extend((d.name, w) + f for f in fl)
        res.append((d.name + " wait=%d" % w, m.group(1) if m else "ERROR",
                    "%s clk/instr, irqs=%s failing=%d" % (m.group(3) if m else "?", ints.group(1) if ints else "?", len(fl))
                    + ("\n" + txt[-1500:] if not m else "")))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, nargs="*", default=[1])
    ap.add_argument("--irq-seeds", type=int, nargs="*", default=[])
    ap.add_argument("--n", type=int, default=4000)
    ap.add_argument("--irq-n", type=int, default=0, help="static count for --irq-seeds (default: --n)")
    ap.add_argument("--waits", type=int, nargs="*", default=[0, 3])
    ap.add_argument("--out", default="debug/e1")
    ap.add_argument("--mame-n", type=int, default=0, help="instructions to trace (default: 1.5 x static + 2000)")
    ap.add_argument("--gen-args", default="", help="extra arguments for e1_gen_test.py, e.g. '--dsp'")
    ap.add_argument("--detail", type=int, default=2, help="failures shown per mnemonic")
    ap.add_argument("-v", action="store_true")
    ap.add_argument("--replay", action="store_true", help="the bench on the traces already under --out")
    ap.add_argument("--pipe", action="store_true", help="bench e1_pipe instead of e1_cpu")
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    out = REPO / a.out
    out.mkdir(parents=True, exist_ok=True)
    fails = 0
    traces = []
    if a.replay:
        defs = ["+define+E1_PIPE"] if a.pipe else []
        r = sh(["scripts/run_verilator.sh", "e1_tb"] + defs + ["+n=0"])
        exe = REPO / "obj_verilator" / ("e1_tb_define_E1_PIPE_CFLAGS_DE1_PIPE" if a.pipe else "e1_tb") / "Vtb_e1"
        if not exe.exists() and not exe.with_suffix(".exe").exists():
            print(r.stdout + r.stderr)
            return 1
        dirs = sorted(d for d in out.iterdir() if (d / "info.txt").exists())
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(a.jobs) as ex:
            allres = list(ex.map(lambda d: replay(d, a.waits, exe, "pipe_" if a.pipe else ""), dirs))
        for res in allres:
            for nm, st, txt in res:
                print("%-16s %-9s %s" % (nm, st, txt))
                fails += st != "PASS"
        jobs = []
    extra = a.gen_args.split()
    if not a.replay:
        jobs = [("s%d" % s, s, False, a.n) for s in a.seeds] + [("i%d" % s, s, True, a.irq_n or a.n) for s in a.irq_seeds]
    else:
        traces = [str(d / "ref" / "misncrft_instr.trace") for d in dirs if (d / "ref" / "misncrft_instr.trace").exists()]
    for name, seed, irq, n in jobs:
        res, tr = one(name, seed, irq, n, a.waits, out, a.mame_n, a.v, extra)
        if tr:
            traces.append(tr)
        for nm, st, txt in res:
            print("%-16s %-9s %s" % (nm, st, txt))
            sys.stdout.flush()
            fails += st != "PASS"
    tot = {}
    for t in traces:
        for k, v in opcodes(t).items():
            tot[k] = tot.get(k, 0) + v
    miss = [o for o in range(256) if o not in tot and o != 0xcf]
    print("coverage: %d of 255 primary opcodes executed (0xcf excluded); missing: %s" %
          (255 - len(miss), " ".join("%02x" % o for o in miss) or "none"))
    seen = {}
    for nm, w, kind, idx, pc, dis, detail in ALLFAIL:
        seen.setdefault((nm, idx), (kind, pc, dis, detail, set()))[4].add(w)
    groups = {}
    for (nm, idx), (kind, pc, dis, detail, ws) in sorted(seen.items()):
        groups.setdefault(dis.split()[0] if dis != "?" else "?", []).append((nm, idx, kind, pc, dis, sorted(ws), detail))
    if groups:
        print("\nfailures by mnemonic (%d distinct per seed and index):" % len(seen))
        for mn, lst in sorted(groups.items()):
            print("  %-10s %d" % (mn, len(lst)))
            for nm, idx, kind, pc, dis, ws, detail in lst[:a.detail]:
                print("      %s idx %d pc %s  %s  [%s] waits %s" % (nm, idx, pc, dis, kind, ws))
                for line in detail.split("\n")[1:]:
                    print("        " + line.strip())
    print("%d failing run(s)" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
