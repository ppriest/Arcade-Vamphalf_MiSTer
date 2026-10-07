# Dump probe instance X (the architectural trace, rtl/debug/vh_trace.sv) in one JTAG session.
#   python scripts/read_trace.py [start]
# Sets the start (instructions from reset), resets the core through instance D's hold bit so the
# buffer refills, waits, and prints "TR <47 hex digits>" per record, as sim/sys_tb +trace writes.

set start 0
if {[llength $argv] > 0 && [lindex $argv 0] ne "noreset"} { set start [lindex $argv 0] }
set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSE*" $d] || $dev eq ""} { set dev $d } }
set idx -1; set didx -1
foreach i [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
    if {[lindex $i 3] eq "X"} { set idx [lindex $i 0] }
    if {[lindex $i 3] eq "D"} { set didx [lindex $i 0] }
}
if {$idx < 0} { puts "NO INSTANCE X -- is this the Vamphalf_stp build?"; exit 1 }
start_insystem_source_probe -device_name $dev -hardware_name $hw
# "noreset": read what the buffer holds (from the launch: the start powers up 0)
if {[lsearch -exact $argv "noreset"] < 0} {
    write_source_data -instance_index $idx -value [format %06X000 $start] -value_in_hex
    write_source_data -instance_index $didx -value 04 -value_in_hex
    after 200
    write_source_data -instance_index $didx -value 00 -value_in_hex
    after 3000
}
# 201 bits: [200:188] records, [187:0] the record
for {set k 0} {$k < 4096} {incr k} {
    write_source_data -instance_index $idx -value [format %06X%03X $start $k] -value_in_hex
    read_probe_data -instance_index $idx -value_in_hex
    set v [read_probe_data -instance_index $idx -value_in_hex]
    set v [string range [string repeat 0 51]$v end-50 end]
    scan [string range $v 0 3] %x n
    set n [expr {$n & 0x1fff}]
    if {$k >= $n} { break }
    puts "TR [string range $v 4 50]"
}
end_insystem_source_probe
