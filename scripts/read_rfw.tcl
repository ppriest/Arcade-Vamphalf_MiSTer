# Dump probe instance W (the first 256 writes to one local register slot) in one JTAG session.
#   python scripts/read_rfw.py <slot>
# Sets the slot, resets the core through instance D's hold bit so the log refills, then prints
# "RFW <instructions> <data>", the format sim/sys_tb +rfslot prints.

set slot [lindex $argv 0]
set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSE*" $d] || $dev eq ""} { set dev $d } }
set idx -1; set didx -1
foreach i [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
    if {[lindex $i 3] eq "W"} { set idx [lindex $i 0] }
    if {[lindex $i 3] eq "D"} { set didx [lindex $i 0] }
}
if {$idx < 0} { puts "NO INSTANCE W"; exit 1 }
start_insystem_source_probe -device_name $dev -hardware_name $hw
write_source_data -instance_index $idx -value [format %04X $slot] -value_in_hex
write_source_data -instance_index $didx -value 04 -value_in_hex
after 100
write_source_data -instance_index $didx -value 00 -value_in_hex
after 2000
for {set k 0} {$k < 256} {incr k} {
    write_source_data -instance_index $idx -value [format %02X%02X $k $slot] -value_in_hex
    read_probe_data -instance_index $idx -value_in_hex
    set v [read_probe_data -instance_index $idx -value_in_hex]
    set v [string range [string repeat 0 19]$v end-18 end]
    scan [string range $v 0 2] %x n
    scan [string range $v 3 10] %x d
    scan [string range $v 11 18] %x ni
    if {$k >= $n} { break }
    puts [format "RFW %u %08x" $ni $d]
}
end_insystem_source_probe
