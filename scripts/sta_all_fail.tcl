# Every failing setup endpoint on the main core clock, summary form, from the
# existing post-fit netlist. Run from the directory holding the database:
#   quartus_sta -t scripts/sta_all_fail.tcl <revision>
set rev ""
if {[llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }
if {$rev eq ""} {
    set qsfs [glob -nocomplain *.qsf]
    if {[llength $qsfs] != 1} { puts "give the revision: quartus_sta -t sta_all_fail.tcl <rev>"; exit 1 }
    set rev [file rootname [lindex $qsfs 0]]
}
project_open $rev
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c
read_sdc
update_timing_netlist
# --- core-specific: edit for this core -------------------------------------
# The main core clock (the framework's emu PLL output 0; same on every core).
set ck {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
# ---------------------------------------------------------------------------
report_timing -setup -npaths 600 -detail summary -from_clock $ck -to_clock $ck -file sta_all_fail.rpt
project_close -dont_export_assignments
