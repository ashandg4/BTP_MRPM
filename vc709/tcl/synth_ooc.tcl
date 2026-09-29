# Out-of-context synth (+ optional place/route) of one thesis module on the
# VC709 part, with utilization/timing reports and a one-line CSV summary.
#
#   vivado -mode batch -source vc709/tcl/synth_ooc.tcl -tclargs <top> <period_ns> [impl|synth] [adder]
#
#   top    : fir8_fold | fir8_fold_pipelined | mrpm_radix4 | mrpm_radix4_wide
#   period : clock period in ns (5.0 = 200 MHz). For the combinational
#            multipliers it is a virtual clock; DATAPATH_DELAY is what matters.
#   impl   : run opt/place/route too (default) - use this for Fmax numbers
#   adder  : FIR tree adder for fir8_fold (han_carlson_adder | kogge_stone_adder |
#            brent_kung_adder | sklansky_adder), default han_carlson_adder
#
# Reports land in vc709/reports/<top>_<adder>_p<period>/ and a summary line is
# appended to vc709/reports/summary.csv. Never quote a number not in a report.

set top    [lindex $argv 0]
set period [lindex $argv 1]
set stage  [expr {[llength $argv] > 2 ? [lindex $argv 2] : "impl"}]
set adder  [expr {[llength $argv] > 3 ? [lindex $argv 3] : "han_carlson_adder"}]
if {$top eq "" || $period eq ""} { error "usage: -tclargs <top> <period_ns> \[impl|synth\] \[adder\]" }

set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set PART xc7vx690tffg1761-2
set COMB_TOPS {mrpm_radix4 mrpm_radix4_wide}

set tag ${top}_${adder}_p${period}
set rpt $ROOT/vc709/reports/$tag
file mkdir $rpt

foreach f {han_carlson_adder.v adder_variants.v mrpm_radix4.v mrpm_radix4_wide.v
           mrpm_radix4_wide_pipe.v fir8_fold.v fir8_fold_pipelined.v} {
    read_verilog $ROOT/rtl/$f
}

# constraints written per run so the period is part of the artifact
set xdc $rpt/ooc.xdc
set fh [open $xdc w]
if {[lsearch $COMB_TOPS $top] >= 0} {
    puts $fh "create_clock -name vclk -period $period"
    puts $fh "set_input_delay  -clock vclk 0 \[all_inputs\]"
    puts $fh "set_output_delay -clock vclk 0 \[all_outputs\]"
} else {
    puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
}
close $fh
read_xdc $xdc

synth_design -top $top -part $PART -mode out_of_context -verilog_define FIR_ADDER=$adder
report_utilization    -file $rpt/util_synth.rpt
report_timing_summary -file $rpt/timing_synth.rpt

if {$stage eq "impl"} {
    opt_design
    place_design
    route_design
    report_utilization    -file $rpt/util_impl.rpt
    report_timing_summary -file $rpt/timing_impl.rpt
    report_timing -max_paths 3 -file $rpt/worst_paths.rpt
}

set path [get_timing_paths -max_paths 1 -setup]
set wns  [get_property SLACK $path]
set dpd  [get_property DATAPATH_DELAY $path]
set luts [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == LUT}]]
set ffs  [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set dsps [llength [get_cells -hier -quiet -filter {PRIMITIVE_TYPE =~ *DSP*}]]
set fmax [expr {$wns eq "" ? 0 : 1000.0 / ($period - $wns)}]

set csv $ROOT/vc709/reports/summary.csv
if {![file exists $csv]} {
    set fh [open $csv w]
    puts $fh "top,adder,period_ns,stage,wns_ns,fmax_mhz,datapath_ns,luts,ffs,dsp48"
    close $fh
}
set fh [open $csv a]
puts $fh [format "%s,%s,%s,%s,%.3f,%.1f,%.3f,%d,%d,%d" $top $adder $period $stage $wns $fmax $dpd $luts $ffs $dsps]
close $fh

puts "=================================================================="
puts [format "RESULT %s  period=%s ns  stage=%s" $tag $period $stage]
puts [format "  WNS=%.3f ns  Fmax=%.1f MHz  datapath=%.3f ns" $wns $fmax $dpd]
puts [format "  LUT=%d  FF=%d  DSP48=%d   (reports: %s)" $luts $ffs $dsps $rpt]
puts "=================================================================="
