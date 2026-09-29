# GUI flow: run AFTER "Run Implementation" has finished.
#   Vivado GUI -> Tools -> Run Tcl Script... -> pick this file.
# Opens the implemented design (if not open) and saves every report the
# paper tables need into vc709/eeg/reports/gui_impl/ + a one-line summary
# in vc709/eeg/reports/build_summary.csv.

set ROOT [file normalize [file join [file dirname [info script]] .. .. ..]]
# clock of this build, from the project generics (default 200 MHz)
set mhz 200
regexp {CLK_HZ=([0-9]+)} [get_property generic [current_fileset]] -> hz
if {[info exists hz]} { set mhz [expr {round($hz / 1.0e6)}] }
set rpt  $ROOT/vc709/eeg/reports/gui_impl_${mhz}MHz
file mkdir $rpt

# make sure the IMPLEMENTED (routed) design is the one being reported
if {[catch {current_design} d] || $d ne "impl_1"} { open_run impl_1 }
if {[get_property NEEDS_REFRESH [get_runs impl_1]]} {
    puts "WARNING: impl_1 is out of date - re-run implementation first"
}

report_utilization                 -file $rpt/util_impl.rpt
report_utilization -hierarchical   -file $rpt/util_impl_hier.rpt
foreach d {u_dut0 u_dut1 u_dut2} {
    report_utilization -cells [get_cells $d] -file $rpt/util_$d.rpt
    report_timing -to [get_cells -hier -filter "NAME =~ $d/* && IS_SEQUENTIAL"] \
        -max_paths 1 -file $rpt/timing_$d.rpt
}
report_timing_summary -max_paths 10 -file $rpt/timing_impl.rpt
report_drc                          -file $rpt/drc.rpt
report_power -hierarchical_depth 2  -file $rpt/power_vectorless.rpt

# which block owns every failing setup endpoint (u_dut0 / u_dut1 / u_dut2 / harness)
set fails [dict create]
foreach p [get_timing_paths -quiet -setup -max_paths 5000 -nworst 1 -slack_lesser_than 0] {
    set ep [get_property NAME [get_property ENDPOINT_PIN $p]]
    set blk [lindex [split $ep /] 0]
    if {![string match u_dut* $blk]} { set blk harness }
    dict incr fails $blk
}
set fh [open $rpt/failing_endpoints_by_block.txt w]
puts $fh "failing setup endpoints by block: $fails"; close $fh
puts "failing setup endpoints by block: $fails"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
set dsp_all  [llength [get_cells -quiet -hier -filter {REF_NAME =~ DSP48*}]]
set bram_all [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]
set line "gui_build,clk_mhz=$mhz,wns_ns=$wns,whs_ns=$whs,dsp_total=$dsp_all,bram_prims=$bram_all"
foreach d {u_dut0 u_dut1 u_dut2} {
    set c [get_cells -quiet -hier -filter "NAME =~ $d/*"]
    append line ",${d}_lut=[llength [filter -quiet $c {REF_NAME =~ LUT*}]]"
    append line ",${d}_ff=[llength [filter -quiet $c {REF_NAME =~ FD*}]]"
    append line ",${d}_srl=[llength [filter -quiet $c {REF_NAME =~ SRL*}]]"
    append line ",${d}_carry4=[llength [filter -quiet $c {REF_NAME =~ CARRY*}]]"
    append line ",${d}_dsp=[llength [filter -quiet $c {REF_NAME =~ DSP48*}]]"
}
set fh [open $ROOT/vc709/eeg/reports/build_summary.csv a]
puts $fh "[clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S],$line"; close $fh

puts "=================================================================="
puts "REPORTS SAVED to $rpt"
puts "  WNS=$wns ns  WHS=$whs ns  DSP48 whole chip=$dsp_all"
puts "  $line"
if {$wns < 0} { puts "  *** TIMING NOT MET - do not use this bitstream for the paper ***" }
puts "=================================================================="
