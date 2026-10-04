# Dump the worst setup-timing paths for the clk_sys domain from the
# already-compiled database, without a recompile. Run from the directory that
# holds the database (the repo root for build.sh, build/ for build_staged.py):
#   quartus_sta -t scripts/report_worst_paths.tcl <revision>
# The revision is the trailing argument; it defaults to the one below.
set rev ""
if {[llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }
if {$rev eq ""} {
    set qsfs [glob -nocomplain *.qsf]
    if {[llength $qsfs] != 1} { puts "give the revision: quartus_sta -t report_worst_paths.tcl <rev>"; exit 1 }
    set rev [file rootname [lindex $qsfs 0]]
}
project_open $rev
create_timing_netlist
read_sdc
update_timing_netlist

# --- core-specific: edit for this core -------------------------------------
# The main core clock, as the STA names it. This is the MiSTer framework's
# emu PLL output 0 and is the same on every core built from the template.
set clk "emu|pll|pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"
# ---------------------------------------------------------------------------

report_timing -setup -npaths 15 -detail full_path -from_clock $clk -to_clock $clk \
    -panel_name "Worst 15 setup paths (clk_sys)" -file "output_files/worst_paths_$rev.rpt"

delete_timing_netlist
# -dont_export_assignments: project_close otherwise RE-SAVES the .qsf,
# reordering it and reverting hand edits (a VERILOG_MACRO has been lost that way).
project_close -dont_export_assignments
