#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build and run one testbench with Verilator. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_verilator.sh video_tb [-GNAME=value ...] [--threads=N] [+plusargs ...]
#
# The fast second simulator (WORKFLOW section 10): two-state and no VHDL, and a
# disagreement with ModelSim is a finding. VHDL modules come in as GHDL Verilog
# conversions made by scripts/verilator_prep.sh, if the core has one.
#
# The bench's sources are listed in sim/<tb>/verilator.files: unlike
# scripts/run_sim.sh this does not compile all of rtl/, because Verilator
# parses every file it is given and not all vendored code is clean for it.
# -G arguments are top-level parameter overrides and go to the build; the
# rest go to the run. Output is in obj_verilator/<tb>/ (git-ignored), not
# build/, which is scripts/build_staged.py's Quartus worktree.
#
# TOOLS: the MSYS2 MinGW64 install (verilator, g++, make, perl). The script
# re-executes itself under that environment when started from Git bash,
# whose PATH has none of them. hwlock does not apply: Verilator never
# touches JTAG and is not a Quartus/ModelSim process.
set -euo pipefail

TB="${1:?usage: scripts/run_verilator.sh <testbench-dir-name> [-Gparam=v] [plusargs...]}"
shift

# MSYS2 holds verilator/g++/make/perl on Windows. Probed, not assumed: set
# MSYS2_ROOT if it lives somewhere else.
if ! command -v verilator >/dev/null 2>&1; then
	MSYS=""
	for _c in "${MSYS2_ROOT:-}" /c/msys64 /d/msys64 /e/msys64 C:/msys64; do
		[ -n "$_c" ] && [ -x "$_c/usr/bin/bash.exe" ] && MSYS="$_c" && break
	done
	[ -n "$MSYS" ] || { echo "MSYS2 not found (verilator, g++, make, perl). Set MSYS2_ROOT."; exit 1; }
	exec env MSYSTEM=MINGW64 CHERE_INVOKING=1 "$MSYS/usr/bin/bash.exe" -lc \
		'cd "$1" && shift && exec scripts/run_verilator.sh "$@"' _ "$(pwd -W 2>/dev/null || pwd)" "$TB" "$@"
fi

[ -d sys ] || { echo "run me from the repository root"; exit 1; }
[ -f "sim/$TB/verilator.files" ] || { echo "no sim/$TB/verilator.files"; exit 1; }

GEN=(); RUN=(); THREADS=1
for a in "$@"; do
	case "$a" in
		-G*)         GEN+=("$a") ;;
		--threads=*) THREADS="${a#--threads=}" ;;
		*)           RUN+=("$a") ;;
	esac
done

# Per-core preparation, e.g. GHDL conversion of a VHDL CPU into obj_verilator/.
# It is passed the bench name and must be cheap when nothing changed.
[ -x scripts/verilator_prep.sh ] && scripts/verilator_prep.sh "$TB"

# A parameter override or a thread count changes the model, so it gets its
# own build directory
OUT="obj_verilator/$TB$(printf '%s' "${GEN[@]+"${GEN[@]}"}" | tr -c 'A-Za-z0-9_' '_')"
[ "$THREADS" = 1 ] || OUT="${OUT}_t$THREADS"
mkdir -p "$OUT"

# A bench with its own sim/<tb>/main.cpp drives its clock from C++ and can
# be saved and restored (main.cpp says how). Verilator cannot save a
# --timing model, so that build is --cc --exe --savable, not --binary.
if [ -f "sim/$TB/main.cpp" ]; then
	MODE=(--cc --exe --build --savable -DCPP_CLOCK "$(pwd)/sim/$TB/main.cpp")
else
	MODE=(--binary --timing)
fi
# OPT_FAST, OPT_GLOBAL: verilated.mk compiles the model, the runtime and a
# bench's main.cpp at -Os (Verilator's own -O3 is not the C++ build), and
# MSYS2's GCC 16.2.0 cannot link -Os code that moves a std::string
# (undefined basic_string(&&)). -O2 links, and is the speed setting.
verilator "${MODE[@]}" --threads "$THREADS" -j 0 -O3 -DSIMULATION \
	-MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_GLOBAL=-O2 \
	-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	"${GEN[@]+"${GEN[@]}"}" \
	--top-module "tb_${TB%_tb}" --Mdir "$OUT" -f "sim/$TB/verilator.files" \
	> "$OUT/build.log" 2>&1 || { grep -E "%Error|error:" "$OUT/build.log" | head -30; exit 1; }

"$OUT/Vtb_${TB%_tb}" "${RUN[@]+"${RUN[@]}"}"
