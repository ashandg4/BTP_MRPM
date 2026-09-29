# Program the VC709 over JTAG with the demo bitstream + ILA probe file.
#
#   vivado -mode batch -source vc709/tcl/program.tcl -tclargs [pipe|fold]
#
# Then open Vivado GUI -> Open Hardware Manager -> Open Target -> Auto Connect
# to use the ILA (the .ltx is already associated by this script).

set variant [expr {[llength $argv] > 0 ? [lindex $argv 0] : "pipe"}]
set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set run  $ROOT/vc709/build/demo_${variant}/demo_vc709.runs/impl_1

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7vx690t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $run/demo_top.bit $dev
set_property PROBES.FILE  $run/demo_top.ltx $dev
set_property FULL_PROBES.FILE $run/demo_top.ltx $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "programmed $dev with $run/demo_top.bit"
