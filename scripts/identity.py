#!/usr/bin/env python3
"""Who a probe reading belongs to: core, build and set, from the device itself.

Several sessions share one MiSTer and one USB-Blaster, so the core that answers a
JTAG read is whatever is loaded, not necessarily the repository that asked. Every
probe line is therefore prefixed

    <core>|<build>|<set>|

core   the loaded core file's stem, from the device (/tmp/RBFNAME), numbering removed
build  that file's name plus the commit it was built from, from the deploy log
set    the running set, from the device (/tmp/CORENAME)

A field that cannot be established is "?", never a guess. When the loaded core is
not this repository's, a warning goes to stderr: the reading is someone else's.

The deploy log is machine-wide, like the JTAG marker, because any repository's
probe may be reading any repository's bitstream:
    %LOCALAPPDATA%/mister_deployed.tsv   rbf-name <TAB> project <TAB> commit <TAB> time
"""
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coretools import core_root, load_env, project   # noqa: E402

DELIM = "|"
LOG = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "mister_deployed.tsv"


def built_commit(root=None):
    """The commit a deploy is shipping: build/BUILT_COMMIT, else HEAD."""
    root = root or core_root()
    f = root / "build" / "BUILT_COMMIT"
    if f.exists():
        return f.read_text(encoding="utf-8").split()[0][:12]
    r = subprocess.run(["git", "rev-parse", "--short=12", "HEAD"], cwd=root,
                       capture_output=True, text=True)
    return r.stdout.strip() or "?"


def record_deploy(rbf_name, root=None):
    """Append one line to the machine-wide deploy log (called by deploy.py)."""
    root = root or core_root()
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write("%s\t%s\t%s\t%s\n" % (rbf_name, project(root), built_commit(root),
                                      time.strftime("%Y-%m-%d %H:%M:%S")))


def lookup(rbf_stem):
    """(project, commit) for the most recent deploy of this core file, or None."""
    if not LOG.exists():
        return None
    hit = None
    for ln in LOG.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = ln.split("\t")
        if len(parts) >= 3 and Path(parts[0]).stem == rbf_stem:
            hit = (parts[1], parts[2])
    return hit


def device_state(root=None):
    """(rbf stem, set name) as the MiSTer reports them, or (None, None)."""
    try:
        import hw                                      # needs mister.env settings
        env = load_env(root, require=("MISTER_HOST", "MISTER_USER", "MISTER_PASSWORD"))
        out = hw.Mister(env).sh("cat /tmp/RBFNAME; echo; cat /tmp/CORENAME",
                                check=False, timeout=20)
        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        return (lines[0] if lines else None, lines[1] if len(lines) > 1 else None)
    except (Exception, SystemExit):
        return None, None


def prefix(root=None, warn=True):
    """The '<core>|<build>|<set>|' prefix for this moment's probe reading."""
    root = root or core_root()
    rbf, setname = device_state(root)
    core = re.sub(r"_\d{8}$", "", rbf) if rbf else "?"
    core = re.sub(r"^Arcade-", "", core)
    build = "?"
    if rbf:
        rec = lookup(rbf)
        build = "%s@%s" % (rbf, rec[1]) if rec else rbf
    mine = project(root)
    if warn and core not in ("?", mine):
        print("WARNING: the MiSTer is running %s, not %s: this reading is not from this "
              "repository's core" % (core, mine), file=sys.stderr)
    return DELIM.join([core, build, setname or "?"]) + DELIM


if __name__ == "__main__":
    print(prefix())
