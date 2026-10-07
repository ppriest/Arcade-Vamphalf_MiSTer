# Dump probe instance P (npc and sr after 256 instructions from a start) in one JTAG session.
#   python scripts/read_pctrace.py <start, a multiple of 8>
# The core must be reset (or relaunched) after the start is set: the window fills once after reset.
# Output: "PCT <instruction> <npc> <sr>", the format sim/sys_tb +pcfrom prints.

set start [lindex $argv 0]
set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSE*" $d] || $dev eq ""} { set dev $d } }
set idx -1; set didx -1
foreach i [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
    if {[lindex $i 3] eq "P"} { set idx [lindex $i 0] }
    if {[lindex $i 3] eq "D"} { set didx [lindex $i 0] }
}
if {$idx < 0} { puts "NO INSTANCE P"; exit 1 }
start_insystem_source_probe -device_name $dev -hardware_name $hw
set s8 [expr {$start / 8}]
# set the start, then hold and release the core through instance D's source bit 2 so the window refills
write_source_data -instance_index $idx -value [format %06X $s8] -value_in_hex
write_source_data -instance_index $didx -value 04 -value_in_hex
after 100
write_source_data -instance_index $didx -value 00 -value_in_hex
after 2000
for {set k 0} {$k < 256} {incr k} {
    write_source_data -instance_index $idx -value [format %02X%04X $k $s8] -value_in_hex
    read_probe_data -instance_index $idx -value_in_hex
    set v [read_probe_data -instance_index $idx -value_in_hex]
    set v [string range [string repeat 0 19]$v end-18 end]
    scan [string range $v 0 2] %x n
    scan [string range $v 3 10] %x npc
    scan [string range $v 11 18] %x sr
    if {$k >= $n} { break }
    puts [format "PCT %d %08x %08x" [expr {$start + $k}] $npc $sr]
}
end_insystem_source_probe
