# GUI flow: run in Hardware Manager AFTER the board is programmed
# (Open Target -> Auto Connect already done).
#   Vivado GUI -> Tools -> Run Tcl Script... -> pick this file.
# Reads the on-die XADC 5 times (1 s apart): die temperature, VCCINT,
# VCCAUX, VCCBRAM. Appends to vc709/eeg/reports/xadc_log.csv.

set ROOT [file normalize [file join [file dirname [info script]] .. .. ..]]
set dev [lindex [get_hw_devices xc7vx690t*] 0]
refresh_hw_device -quiet $dev
set sm [lindex [get_hw_sysmons -of_objects $dev] 0]
set csv $ROOT/vc709/eeg/reports/xadc_log.csv
file mkdir [file dirname $csv]
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
    puts $fh "$ts,gui,$t,$vi,$va,$vb"
    puts "XADC $ts  T=$t C  VCCINT=$vi V  VCCAUX=$va V  VCCBRAM=$vb V"
    after 1000
}
close $fh
puts "saved to $csv"
