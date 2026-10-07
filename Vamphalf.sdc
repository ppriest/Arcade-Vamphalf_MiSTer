derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# The QS1000's 8052 (jt8052) updates every register on its 24 MHz enable, which is never two
# clk_sys clocks in a row (rtl/qs1000/vh_qs1000.sv): a path from one of its registers to another
# has two clocks. Its divider (DIV AB) alone is longer than one.
set_multicycle_path -setup 2 -from [get_registers {*jt8052:u_mcu|*}] -to [get_registers {*jt8052:u_mcu|*}]
set_multicycle_path -hold 1 -from [get_registers {*jt8052:u_mcu|*}] -to [get_registers {*jt8052:u_mcu|*}]
# and into its internal RAM, which is written and read on the same enable
set_multicycle_path -setup 2 -from [get_registers {*jt8052:u_mcu|*}] -to [get_keepers {*vh_qs1000_mcu:u_mcu|vh_dpram:u_iram|*}]
set_multicycle_path -hold 1 -from [get_registers {*jt8052:u_mcu|*}] -to [get_keepers {*vh_qs1000_mcu:u_mcu|vh_dpram:u_iram|*}]
