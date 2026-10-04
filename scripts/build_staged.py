#!/usr/bin/env python3
"""Build Quartus from a staged snapshot of HEAD, leaving the tree free.

A Quartus compile takes minutes, and for all of it the tree has to be left
alone. The compile runs in a dedicated git worktree at <repo>/build
(gitignored), so the main tree is free the moment the build starts, and every
scrap of Quartus scratch -- db/, incremental_db/, output_files/, the log --
lands under build/ instead of the repo root.

The build is exactly HEAD:
  * a dirty tree is refused by default, so what is in the editor and what is
    compiled cannot silently diverge. --allow-dirty builds HEAD anyway,
    explicitly acknowledging the uncommitted edits are EXCLUDED.
  * the built commit is written to build/BUILT_COMMIT beside the log, so
    every .rbf maps to one commit.

    python scripts/build_staged.py                     # compile HEAD, default revision
    python scripts/build_staged.py --rev <project>     # another revision
    python scripts/build_staged.py --seed 12345        # try another placement
    python scripts/build_staged.py --allow-dirty       # HEAD, ignoring edits

The revision defaults to CORE_REV, else the one .qsf, else the last
PROJECT_REVISION in the .qpf (scripts/coretools.py). A core with an
instrumented <project>_stp.qsf (DEBUG_ISSP) and a release <project>.qsf
builds the instrumented one by default when it is listed last.

Outputs, all inside the stage, named after the revision:
    build/q_staged.log                     the build log (deploy.py's gate reads it)
    build/output_files/<rev>.rbf           the bitstream
    build/output_files/<rev>.sta.summary
    build/BUILT_COMMIT                     commit, time and SEED

Deploy it by pointing deploy.py at the stage (its defaults):
    python scripts/deploy.py --rbf-only

The worktree persists between builds -- Quartus's db/ with it -- and each run
hard-resets it to HEAD. A .build_running marker refuses two overlapping
staged builds.

scripts/build.sh still builds in-tree; use it when you want the compile to
see uncommitted work and are willing to leave the tree alone.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coretools import core_root, revision, quartus_bin   # noqa: E402

REV = None          # set in main() from --rev / coretools
QUARTUS_BIN = None

# --- core-specific: edit for this core -------------------------------------
# Every block that MUST survive to the fitted netlist, by the name Quartus
# writes into the fit report. A build that passes timing because part of the
# design was optimised away is the worst kind of green (an undriven clock
# takes a whole video chain out and the build reports TIMING MET). Slack alone
# cannot catch that; presence is asserted separately. Add each name in the
# commit that adds the module it names, so the gate grows with the design.
REQUIRED_INSTANCES = (
    "hps_io",        # the framework's HPS interface; present from the template on
    # "fx68k", "sdram", "arcade_video", "Hq2x", "screen_rotate_two", ...
)

# Macros the design needs defined in the .qsf, and what breaks without each.
# Presence is not connection: a module can stay in the netlist with its ports
# bound to implicitly declared wires because a VERILOG_MACRO went missing.
REQUIRED_MACROS = {
    # "MISTER_FB": "HDMI rotation and 180 flip need the FB_* ports",
}

# Files the compile expects in the project directory that the repo keeps
# elsewhere, copied inside the stage before Quartus runs: (source, destination),
# both relative to the repo root. fx68k's $readmemb looks for its microcode in
# the directory Quartus runs from, not beside the RTL.
STAGE_COPIES = (
    # ("rtl/cpu/fx68k/microrom.mem", "microrom.mem"),
    # ("rtl/cpu/fx68k/nanorom.mem", "nanorom.mem"),
)
# ---------------------------------------------------------------------------


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit("FAILED: %s\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout.strip()


def read_slacks(summary):
    """Print every clock's setup slack; return the ones that fail.

    All of them, not clk_sys alone: a violation on any clock is a violation,
    and scripts/build.sh gates on exactly the same rule.
    """
    out = []
    if not os.path.exists(summary):
        print("no timing summary at %s -- treating as unverified" % summary)
        return out
    lines = open(summary, errors="replace").read().splitlines()
    for i, ln in enumerate(lines):
        if not ln.startswith("Type  : Setup ") or i + 2 >= len(lines):
            continue
        clk = ln.split("Setup ", 1)[1].strip().strip("'")
        try:
            slack = float(lines[i + 1].split(":", 1)[1])
        except (IndexError, ValueError):
            continue
        tns = lines[i + 2].split(":", 1)[1].strip()
        if "emu|pll" in clk:
            print("worst clk_sys setup: Slack : %.3f / TNS   : %s" % (slack, tns))
        if slack < 0:
            out.append((clk[-58:], slack, tns))
    return out


def report_resources(stage):
    fit = os.path.join(stage, "output_files", "%s.fit.summary" % REV)
    if not os.path.exists(fit):
        return
    keep = ("Logic utilization", "Total registers", "Total block memory bits",
            "Total RAM Blocks", "Total DSP Blocks", "Total pins", "Total PLLs")
    for ln in open(fit, errors="replace"):
        if any(ln.strip().startswith(k) for k in keep):
            print("  " + ln.strip())


def check_macros(stage):
    """Fail if a required VERILOG_MACRO is missing or commented out."""
    qsf = os.path.join(stage, "%s.qsf" % REV)
    try:
        with open(qsf, encoding="utf8", errors="replace") as f:
            live = [ln for ln in f if not ln.lstrip().startswith("#")]
    except OSError as e:
        return ["cannot read %s: %s" % (qsf, e)]
    text = "".join(live)
    return ['%s is not defined in %s -- %s' % (m, os.path.basename(qsf), why)
            for m, why in REQUIRED_MACROS.items()
            if 'VERILOG_MACRO "%s=' % m not in text]


def check_present(stage):
    """Fail if a block that must exist is missing from the fitted netlist."""
    rpt = os.path.join(stage, "output_files", "%s.fit.rpt" % REV)
    try:
        text = open(rpt, errors="replace").read()
    except OSError:
        print("  (no fit report at %s -- cannot check)" % rpt)
        return []
    missing = [n for n in REQUIRED_INSTANCES if n not in text]
    for n in REQUIRED_INSTANCES:
        print("  %-18s %s" % (n, "present" if n in text else "MISSING"))
    return missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", help="Quartus revision (default: CORE_REV, else the one "
                                  ".qsf in the core root, else the .qpf's last)")
    ap.add_argument("--seed", type=int,
                    help="override the fitter SEED in the STAGED .qsf "
                         "(placement only; worth trying before restructuring "
                         "RTL for a sub-ns violation)")
    ap.add_argument("--allow-negative-slack", action="store_true",
                    help="do not fail on a build that misses timing; the "
                         "shortfall must then be stated wherever it is used")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="build HEAD even though the tree has uncommitted "
                         "changes (they are NOT included in the build)")
    args = ap.parse_args()

    global REV, QUARTUS_BIN
    here = str(core_root())
    REV = revision(Path(here), args.rev)
    QUARTUS_BIN = str(quartus_bin(Path(here)))
    stage = os.path.join(here, "build")

    # scripts/hwlock.py: a compile must not start while a JTAG tool is
    # reading the device. The marker is machine-wide, so this also refuses
    # while another core is probing.
    from hwlock import require_no_jtag
    require_no_jtag("this build")

    dirty = run(["git", "-C", here, "status", "--porcelain"])
    # Untracked files are not part of HEAD either, but they are usually
    # scratch; only tracked modifications are treated as a divergence worth
    # refusing over.
    tracked_dirty = "\n".join(ln for ln in dirty.splitlines()
                              if not ln.startswith("??"))
    if tracked_dirty and not args.allow_dirty:
        sys.exit("tree is dirty -- commit first (the build is exactly HEAD), "
                 "or pass --allow-dirty to build HEAD without these:\n"
                 + tracked_dirty)

    head = run(["git", "-C", here, "rev-parse", "HEAD"])
    head_short = run(["git", "-C", here, "rev-parse", "--short", "HEAD"])

    marker = os.path.join(stage, ".build_running")
    if os.path.exists(marker):
        sys.exit("a staged build already appears to be running (%s exists) -- "
                 "wait for it, or delete the marker if it is stale" % marker)

    # Create or update the stage worktree to exactly HEAD.
    if not os.path.isdir(os.path.join(stage, ".git")) and \
       not os.path.isfile(os.path.join(stage, ".git")):
        run(["git", "-C", here, "worktree", "add", "--detach", stage, head])
    else:
        # --force: a seed override patches the STAGED .qsf, and a leftover
        # patch must never wedge the next build. The stage is a disposable
        # copy of HEAD; local changes in it are always discardable.
        run(["git", "-C", stage, "checkout", "--force", "--detach", head])
        run(["git", "-C", stage, "reset", "--hard", head])

    # Fitter seed override, patched into the STAGE only, so a build stays
    # reproducible from its commit plus this flag.
    if args.seed is not None:
        qsf = os.path.join(stage, "%s.qsf" % REV)
        if not os.path.isfile(qsf):
            sys.exit("no %s to patch a SEED into" % qsf)
        text = open(qsf, encoding="utf-8", errors="replace").read()
        new, n = re.subn(r"(?m)^set_global_assignment -name SEED .*$",
                         "set_global_assignment -name SEED %d" % args.seed, text)
        if n == 0:
            new = text.rstrip("\n") + \
                "\nset_global_assignment -name SEED %d\n" % args.seed
        elif n > 1:
            sys.exit("expected at most one SEED assignment in %s, found %d" % (qsf, n))
        open(qsf, "w", encoding="utf-8", newline="\n").write(new)
        print("seed:   %d (stage only)" % args.seed)

    # THE SEED IS PART OF THE BUILD. Two .rbf files from the same commit at
    # different seeds are not interchangeable: one placement with every clock
    # positive has broken games on hardware where another (worse worst slack)
    # ran them all. Record it, or a good build cannot be rebuilt.
    stamp = "%s  %s  seed=%s\n" % (
        head, datetime.datetime.now().isoformat(),
        args.seed if args.seed is not None else "default")
    open(os.path.join(stage, "BUILT_COMMIT"), "w").write(stamp)
    print("stage:  %s" % stage)
    print("rev:    %s" % REV)
    print("commit: %s (%s)" % (head_short, head))
    if dirty and args.allow_dirty:
        print("NOTE:   the tree has uncommitted changes and they are NOT in "
              "this build")

    for src, dst in STAGE_COPIES:
        with open(os.path.join(stage, src), "rb") as f_in, \
                open(os.path.join(stage, dst), "wb") as f_out:
            f_out.write(f_in.read())
        print("copied: %s -> %s (stage only)" % (src, dst))

    quartus = os.path.join(QUARTUS_BIN, "quartus_sh.exe")
    log_path = os.path.join(stage, "q_staged.log")
    open(marker, "w").write(stamp)
    try:
        with open(log_path, "w") as log:
            subprocess.run([quartus, "--flow", "compile", REV, "-c", REV],
                           cwd=stage, stdout=log, stderr=subprocess.STDOUT)
    finally:
        os.remove(marker)

    tail = open(log_path, errors="replace").read().splitlines()[-25:]
    ok = any("Full Compilation was successful" in ln for ln in tail)
    for ln in tail:
        if any(k in ln for k in ("successful", "Error", "Elapsed")):
            print(ln.strip())

    print("")
    print("==== resource usage ====")
    report_resources(stage)
    print("")
    print("==== the design is still there ====")
    missing = check_present(stage)
    bad_macros = check_macros(stage)
    for m in REQUIRED_MACROS:
        print("  %-18s %s" % (m, "undefined" if any(m in b for b in bad_macros)
                                   else "defined"))

    print("")
    print("==== timing ====")
    violations = read_slacks(
        os.path.join(stage, "output_files", "%s.sta.summary" % REV))

    if bad_macros:
        sys.exit("\nBUILD MISCONFIGURED --\n  " + "\n  ".join(bad_macros))

    if missing:
        sys.exit(
            "\nDESIGN INCOMPLETE -- %s missing from the fitted netlist.\n"
            "Whatever this build's timing says, it is not a measurement of the\n"
            "design you think you built. Look for an undriven clock or reset:\n"
            "  grep 'Stuck at GND due to stuck port clock' %s\n"
            % (", ".join(missing),
               os.path.join(stage, "output_files", "%s.map.rpt" % REV)))

    if not ok:
        sys.exit("BUILD FAILED -- see %s" % log_path)

    if violations and not args.allow_negative_slack:
        print("")
        for clk, slack, tns in violations:
            print("  FAILING: %-58s %8.3f  TNS %s" % (clk, slack, tns))
        sys.exit(
            "\nTIMING NOT MET -- %d clock(s) fail. The .rbf at\n"
            "  %s\nis not trustworthy. Close timing, try --seed, or pass\n"
            "--allow-negative-slack deliberately."
            % (len(violations),
               os.path.join(stage, "output_files", "%s.rbf" % REV)))
    if violations:
        print("")
        print("WARNING: --allow-negative-slack given; this build misses timing "
              "on %d clock(s)." % len(violations))

    rbf = os.path.join(stage, "output_files", "%s.rbf" % REV)
    print("\nOK -- deploy with:\n"
          "  python scripts/deploy.py --rbf-only --rev %s --log \"%s\" \\\n"
          "      --rbf \"%s\" \\\n"
          "      --sta \"%s\""
          % (REV, log_path, rbf,
             os.path.join(stage, "output_files", "%s.sta.summary" % REV)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
