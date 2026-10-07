create_clock -name clk -period 17.857 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [get_ports {rst dl_* latch_* sd_*}]
set_false_path -to [get_ports {sd_* out_* dbg_*}]
set_multicycle_path -setup 2 -from [get_registers {*jt8052:u_mcu|*}] -to [get_registers {*jt8052:u_mcu|*}]
set_multicycle_path -hold 1 -from [get_registers {*jt8052:u_mcu|*}] -to [get_registers {*jt8052:u_mcu|*}]
set_multicycle_path -setup 2 -from [get_registers {*jt8052:u_mcu|*}] -to [get_keepers {*vh_qs1000_mcu:u_mcu|vh_dpram:u_iram|*}]
set_multicycle_path -hold 1 -from [get_registers {*jt8052:u_mcu|*}] -to [get_keepers {*vh_qs1000_mcu:u_mcu|vh_dpram:u_iram|*}]
