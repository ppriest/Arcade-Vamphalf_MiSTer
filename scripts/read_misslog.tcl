# Dump probe instance T (the last 256 cache misses since reset, Vamphalf.sv) in one JTAG session.
#   python scripts/read_misslog.py
# Output, oldest first: "<n> <I|D> <line, cached space> <instructions retired before it>", the format
# sim/sys_tb +misslog writes, so the board's lines can be found in the bench's list.

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSE*" $d] || $dev eq ""} { set dev $d }
}
set idx -1
foreach i [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
    if {[lindex $i 3] eq "T"} { set idx [lindex $i 0] }
}
if {$idx < 0} { puts "NO INSTANCE T -- is this the Vamphalf_stp build?"; exit 1 }

# 80 bits as 20 hex digits: [79:64] misses so far, [63] I, [49:32] line [21:4], [31:0] instructions
proc slot {idx s} {
    write_source_data -instance_index $idx -value [format %02X $s] -value_in_hex
    read_probe_data -instance_index $idx -value_in_hex
    set v [read_probe_data -instance_index $idx -value_in_hex]
    set v [string range [string repeat 0 20]$v end-19 end]
    scan [string range $v 0 3] %x n
    scan [string range $v 4 11] %x hi
    scan [string range $v 12 19] %x ni
    return [list $n $hi $ni]
}

start_insystem_source_probe -device_name $dev -hardware_name $hw
set total [lindex [slot $idx 0] 0]
set first [expr {$total > 256 ? $total - 256 : 0}]
for {set k $first} {$k < $total} {incr k} {
    lassign [slot $idx [expr {$k & 255}]] n hi ni
    set ic [expr {($hi >> 31) & 1}]
    set line [expr {($hi & 0x3ffff) << 4}]
    puts [format "%d %s %06x %u" $k [expr {$ic ? "I" : "D"}] $line $ni]
}
puts "logged $total"
end_insystem_source_probe
