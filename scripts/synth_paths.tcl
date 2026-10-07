# worst setup paths of the E1 standalone fit; run from debug/synth/synth_e1_<time>/rtl/synth_check
project_open $::env(SYNTH_PROJ) -revision $::env(SYNTH_PROJ)
create_timing_netlist
read_sdc $::env(SYNTH_PROJ).sdc
update_timing_netlist
report_timing -setup -npaths 5 -detail path_only -panel_name "wp" -file wp.txt
project_close
