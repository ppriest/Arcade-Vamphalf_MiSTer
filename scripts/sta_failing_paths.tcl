# Report the worst setup-failing paths on the main core clock domain, from the
# existing post-fit netlist (no re-fit, no placement change). Run from the
# directory holding the database:
#   quartus_sta -t scripts/sta_failing_paths.tcl <revision>
set rev ""
if {[llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }
if {$rev eq ""} {
    set qsfs [glob -nocomplain *.qsf]
    if {[llength $qsfs] != 1} { puts "give the revision: quartus_sta -t sta_failing_paths.tcl <rev>"; exit 1 }
    set rev [file rootname [lindex $qsfs 0]]
}
project_open $rev -revision $rev
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c
read_sdc
update_timing_netlist

# --- core-specific: edit for this core -------------------------------------
# The main core clock (the framework's emu PLL output 0; same on every core).
set ck {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
# ---------------------------------------------------------------------------

# 1) Summary of the 50 worst failing endpoints -- shows WHERE the failures cluster
report_timing -setup -npaths 50 -detail summary \
    -from_clock $ck -to_clock $ck \
    -file sta_top50_summary.rpt

# 2) Full detail on the 5 worst paths -- the actual cell-by-cell critical path
report_timing -setup -npaths 5 -detail full_path \
    -from_clock $ck -to_clock $ck \
    -file sta_worst5_full.rpt

project_close -dont_export_assignments
