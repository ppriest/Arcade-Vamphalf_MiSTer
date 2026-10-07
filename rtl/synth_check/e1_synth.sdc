create_clock -name clk -period 17.857 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [get_ports {reset pause tick irq_in* bus_ack bus_rdata*}]
set_false_path -to [get_ports {irq_ack* bus_* retire*}]
