# Program the VC709 with the EEG HIL bitstream over JTAG, then read the
# on-die XADC (SYSMON) through JTAG: die temperature and supply voltages.
# These are MEASURED operating conditions of the silicon during the test.
#
#   vivado -mode batch -source vc709/eeg/tcl/program_eeg_hil.tcl -tclargs [clk_mhz] [read_only]
#
#   read_only : pass "read" to skip programming and only log XADC again
#               (run it right after hil_run.py finishes).
# Appends to vc709/eeg/reports/xadc_log.csv

set clk_mhz [expr {[llength $argv] > 0 ? [lindex $argv 0] : 200}]
set mode    [expr {[llength $argv] > 1 ? [lindex $argv 1] : "program"}]
set ROOT [file normalize [file join [file dirname [info script]] .. .. ..]]
set bit  $ROOT/vc709/eeg/build/clk$clk_mhz/eeg_hil_top.bit

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7vx690t*] 0]
current_hw_device $dev
if {$mode ne "read"} {
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
    puts "programmed $dev with $bit"
}
refresh_hw_device $dev

set sm [lindex [get_hw_sysmons -of_objects $dev] 0]
set csv $ROOT/vc709/eeg/reports/xadc_log.csv
file mkdir [file dirname $csv]
set new [expr {![file exists $csv]}]
set fh [open $csv a]
if {$new} { puts $fh "timestamp,clk_mhz,phase,temp_c,vccint_v,vccaux_v,vccbram_v" }
# 5 readings, 1 s apart
for {set i 0} {$i < 5} {incr i} {
    refresh_hw_sysmon $sm
    set t  [get_property TEMPERATURE $sm]
    set vi [get_property VCCINT  $sm]
    set va [get_property VCCAUX  $sm]
    set vb [get_property VCCBRAM $sm]
    set ts [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S]
    puts $fh "$ts,$clk_mhz,$mode,$t,$vi,$va,$vb"
    puts "XADC $ts  T=$t C  VCCINT=$vi V  VCCAUX=$va V  VCCBRAM=$vb V"
    after 1000
}
close $fh
close_hw_target
disconnect_hw_server
