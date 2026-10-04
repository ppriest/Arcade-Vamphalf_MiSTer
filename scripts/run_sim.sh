#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compile and run one testbench. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_sim.sh maincpu_tb
#     scripts/run_sim.sh video_tb +FRAME=1200      # extra args go to vsim
#
# $readmemh paths resolve against the simulator's CWD, not the testbench file,
# so every bench in this project is written to be run from the repo root and
# this script enforces it. A wrong CWD leaves ROMs all zeroes and fails every
# check at once, which reads exactly like an RTL regression -- grep the log for
# `readmem` first (LESSONS_LEARNED, "Testbench discipline").
#
# VHDL goes through vcom from sim/vhdl.files; all SystemVerilog/Verilog under
# rtl/ goes through vlog.
#
# A FRESH library every run. A run that dies mid-compile leaves work/_lock
# behind, on which every later vlog/vcom waits silently and forever -- which
# looked exactly like a bench that printed nothing. Corollary: ONE RUN AT A
# TIME. Two concurrent invocations delete and rebuild the same library
# underneath each other, and the loser prints nothing at all.
set -euo pipefail

TB="${1:?usage: scripts/run_sim.sh <testbench-dir-name> [vsim args...]}"
shift

# TOOL PATH RESOLUTION.
#
# Probed rather than asserted, because "bash" on this machine is ambiguous:
# PATH also contains WSL's bash, which is a different OS with /mnt/c instead of
# /c and cannot run Windows .exe tools at all. A Python wrapper that spawns
# plain `bash` gets THAT one, so a script passes when you run it by hand and
# fails from the wrapper, reporting "No such file or directory" for a path that
# plainly exists.
MS=""
for _c in "${MODELSIM_BIN:-}" \
          /c/intelFPGA_lite/17.0/modelsim_ase/win32aloem \
          C:/intelFPGA_lite/17.0/modelsim_ase/win32aloem; do
  [ -n "$_c" ] && [ -x "$_c/vlib.exe" ] && MS="$_c" && break
done
[ -n "$MS" ] || { echo "ModelSim not found. Set MODELSIM_BIN."; exit 1; }
[ -d sys ] || { echo "run me from the repository root"; exit 1; }
[ -d "sim/$TB" ] || { echo "no such testbench: sim/$TB"; exit 1; }

# JTAG concurrent with ModelSim has bugchecked this PC three times (0x139).
# hwlock.py enforces it rather than leaving it to memory. See docs/WORKFLOW.md
# section 2.
python scripts/hwlock.py --require-no-jtag "simulation $TB"

# Orphaned kernels from killed runs spin at 100% CPU indefinitely and make
# every later simulation look pathologically slow. Sweep before launching.
if command -v powershell.exe >/dev/null 2>&1; then
  n=$(powershell.exe -NoProfile -Command \
      "(Get-Process vsim,vsimk -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r' || echo 0)
  [ "${n:-0}" != "0" ] && echo "WARNING: $n vsim/vsimk process(es) already running."
fi

rm -rf work
"$MS/vlib.exe" work >/dev/null

# Vendored VHDL (a CPU core, say) is listed in sim/vhdl.files, one path per
# line, packages FIRST: ModelSim resolves them at compile time, not elaboration.
# List only what the core instantiates; an unused wrapper can fail to compile.
if [ -f sim/vhdl.files ]; then
  echo "--- vcom: sim/vhdl.files ---"
  # shellcheck disable=SC2046
  "$MS/vcom.exe" -quiet -2008 -work work $(grep -vE '^\s*(#|$)' sim/vhdl.files)
fi

# Compile the whole core RTL every time rather than a per-bench file list. It
# costs seconds and removes an entire class of "the bench passed against a
# stale module" failure.
#
# Deliberate exclusions:
#   rtl/synth_check/        Quartus-only harnesses with their own top levels
#   screen_rotate*.sv       vendored MiSTer-devel code that uses its variables
#                           before declaring them. Quartus and Verilator accept
#                           it, ModelSim's vlog does not (vlog-2730), and it
#                           must stay UNTOUCHED -- so it is left out of
#                           simulation rather than patched. Still synthesized.
#   *_upstream_reference.*  pristine upstream copies kept beside the vendored
#                           modules purely so local changes can be diffed.
#   cos.sv, lfsr.v, mycore.v  Template_MiSTer's demo core. Excluded now, and to
#                           be DELETED once <Name>.sv becomes the real top
#                           level; the exclusions stay so a stray copy cannot
#                           creep back in.
RTL=$(find rtl -name '*.sv' \
        -not -path 'rtl/synth_check/*' \
        -not -name 'screen_rotate*.sv' \
        -not -name '*_upstream_reference.sv' \
        -not -name 'cos.sv' | sort)
VLOG=$(find rtl -name '*.v' \
        -not -path 'rtl/synth_check/*' \
        -not -name 'pll*.v' \
        -not -name 'lfsr.v' -not -name 'mycore.v' \
        -not -name '*_upstream_reference.v' | sort)

echo "--- vlog: RTL + testbench ---"
# +initreg/+initmem =r+0 give every un-reset variable and array the power-up
# zero that hardware has and a four-state simulator does not. The vendored
# jotego modules need it: their un-reset pipelines are X in ModelSim and zero
# on the board.
#
# It has its own trap, and the trap is recorded: "+initreg=r+0 turns an
# un-evaluated `always @*` into a confident zero". Set INITREG=" " to run
# four-state (X) instead when a block is suspected of never evaluating.
#
# VDEFS carries extra +define+ switches for an A/B.
#
# -suppress 7061: some vendored cores (fx68k) drive parts of an array from more than one
# always_ff. Quartus accepts it; ModelSim refuses by default.
# shellcheck disable=SC2086
"$MS/vlog.exe" -quiet -sv -work work -suppress 7061 \
    +define+SIMULATION ${INITREG-+initreg=r+0 +initmem=r+0} ${VDEFS:-} \
    $VLOG $RTL $(ls sim/common/*.sv 2>/dev/null) "sim/$TB"/*.sv

# The bench's top module is found rather than derived from the directory name,
# so a bench directory can hold more than one file without the runner caring.
TOP=$(grep -l -E '^\s*module\s+tb_' "sim/$TB"/*.sv | head -1 \
      | xargs grep -oE '^\s*module\s+tb_[a-z0-9_]+' | awk '{print $2}')
[ -n "$TOP" ] || { echo "no 'module tb_*' found in sim/$TB"; exit 1; }

echo "--- vsim $TOP $* ---"
"$MS/vsim.exe" -c -quiet -work work "$TOP" "$@" -do "run -all; quit -f" 2>&1 \
  | grep -v '^# *$' | grep -v 'pref.tcl\|^# 10.5b\|Start time\|^# vsim -c'
