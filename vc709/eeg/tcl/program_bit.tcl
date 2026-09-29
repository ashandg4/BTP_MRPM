# Program the VC709 with a given bitstream over JTAG and log the XADC.
#   vivado -mode batch -source vc709/eeg/tcl/program_bit.tcl -tclargs <bitfile> [label]
# Appends to vc709/eeg/reports/xadc_log.csv

set bit   [lindex $argv 0]
set label [expr {[llength $argv] > 1 ? [lindex $argv 1] : "program"}]
if {![file exists $bit]} { error "bitstream not found: $bit" }
set ROOT [file normalize [file join [file dirname [info script]] .. .. ..]]

open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
puts "JTAG targets: $targets"
if {[llength $targets] == 0} { error "no JTAG target - is the cable in the board's JTAG port?" }
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices xc7vx690t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAMMED $dev with $bit ([clock format [file mtime $bit]])"

set sm [lindex [get_hw_sysmons -of_objects $dev] 0]
set csv $ROOT/vc709/eeg/reports/xadc_log.csv
set new [expr {![file exists $csv]}]
set fh [open $csv a]
if {$new} { puts $fh "timestamp,source,temp_c,vccint_v,vccaux_v,vccbram_v" }
for {set i 0} {$i < 5} {incr i} {
    refresh_hw_sysmon $sm
    set t  [get_property TEMPERATURE $sm]
    set vi [get_property VCCINT  $sm]
    set va [get_property VCCAUX  $sm]
    set vb [get_property VCCBRAM $sm]
    set ts [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S]
    puts $fh "$ts,$label,$t,$vi,$va,$vb"
    puts "XADC $ts  T=$t C  VCCINT=$vi V  VCCAUX=$va V  VCCBRAM=$vb V"
    after 1000
}
close $fh
close_hw_target
disconnect_hw_server
