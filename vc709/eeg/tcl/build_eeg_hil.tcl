# Build the VC709 EEG hardware-in-the-loop bitstream (non-project batch flow).
#
#   vivado -mode batch -source vc709/eeg/tcl/build_eeg_hil.tcl -tclargs [clk_mhz]
#
#   clk_mhz : 200 (default, SYSCLK direct, no MMCM)
#             100 125 150 250 300 333 350 400 (MMCM from the 200 MHz SYSCLK)
#
# Output: vc709/eeg/build/clk<MHz>/eeg_hil_top.bit
#         vc709/eeg/reports/clk<MHz>/   util / timing / power / drc reports
#         vc709/eeg/reports/build_summary.csv   one line per build
# Quote numbers from the .rpt files, never from the console.

set clk_mhz [expr {[llength $argv] > 0 ? [lindex $argv 0] : 200}]
# MHz -> {CLK_HZ USE_MMCM M O}; VCO = 200*M MHz must lie in 600..1440 (-2 grade)
array set CFG {
    100 {100000000 1 5 10}
    125 {125000000 1 5 8}
    150 {150000000 1 6 8}
    200 {200000000 0 6 4}
    250 {250000000 1 5 4}
    300 {300000000 1 6 4}
    333 {333333333 1 5 3}
    350 {350000000 1 7 4}
    400 {400000000 1 6 3}
}
if {![info exists CFG($clk_mhz)]} { error "unsupported clk_mhz $clk_mhz; use one of [lsort -integer [array names CFG]]" }
lassign $CFG($clk_mhz) CLK_HZ USE_MMCM MM MO

set ROOT  [file normalize [file join [file dirname [info script]] .. .. ..]]
set PART  xc7vx690tffg1761-2
set build $ROOT/vc709/eeg/build/clk$clk_mhz
set rpt   $ROOT/vc709/eeg/reports/clk$clk_mhz
file mkdir $build $rpt

foreach f {han_carlson_adder.v mrpm_radix4.v mrpm_radix4_wide.v mrpm_radix4_wide_pipe.v
           fir8_symmetric.v fir8_fold.v fir8_fold_pipelined.v} {
    read_verilog $ROOT/rtl/$f
}
foreach f {uart_rx.v uart_tx.v eeg_hil_top.v} { read_verilog $ROOT/vc709/eeg/rtl/$f }
read_xdc $ROOT/vc709/eeg/xdc/eeg_hil_top.xdc

synth_design -top eeg_hil_top -part $PART \
    -generic CLK_HZ=$CLK_HZ -generic USE_MMCM=$USE_MMCM -generic MMCM_M=$MM -generic MMCM_O=$MO
report_utilization -hierarchical -file $rpt/util_synth_hier.rpt
opt_design
place_design
phys_opt_design
route_design

# ---------------- reports ----------------
report_utilization                 -file $rpt/util_impl.rpt
report_utilization -hierarchical   -file $rpt/util_impl_hier.rpt
foreach d {u_dut0 u_dut1 u_dut2} {
    report_utilization -cells [get_cells $d] -file $rpt/util_$d.rpt
}
report_timing_summary -max_paths 10 -file $rpt/timing_impl.rpt
foreach d {u_dut0 u_dut1 u_dut2} {
    # worst register-to-register path that ends inside each DUT
    report_timing -to [get_cells -hier -filter "NAME =~ $d/* && IS_SEQUENTIAL"] \
        -max_paths 1 -file $rpt/timing_$d.rpt
}
report_clock_utilization -file $rpt/clock_util.rpt
report_drc               -file $rpt/drc.rpt
# vectorless power (default 12.5% toggle) - an ESTIMATE, see power_saif.tcl for the
# activity-annotated estimate; neither is a board measurement
report_power -hierarchical_depth 2 -file $rpt/power_vectorless.rpt

write_checkpoint -force $build/eeg_hil_top_routed.dcp
write_bitstream  -force $build/eeg_hil_top.bit

# ---------------- one-line summary ----------------
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
set dsp_all  [llength [get_cells -quiet -hier -filter {REF_NAME =~ DSP48*}]]
set bram_all [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]
set line "clk_mhz=$clk_mhz,clk_hz=$CLK_HZ,wns_ns=$wns,whs_ns=$whs,dsp_total=$dsp_all,bram_prims=$bram_all"
foreach d {u_dut0 u_dut1 u_dut2} {
    set c [get_cells -quiet -hier -filter "NAME =~ $d/*"]
    set lut [llength [filter -quiet $c {REF_NAME =~ LUT*}]]
    set ff  [llength [filter -quiet $c {REF_NAME =~ FD*}]]
    set srl [llength [filter -quiet $c {REF_NAME =~ SRL*}]]
    set cy  [llength [filter -quiet $c {REF_NAME =~ CARRY*}]]
    set dsp [llength [filter -quiet $c {REF_NAME =~ DSP48*}]]
    append line ",${d}_lut=$lut,${d}_ff=$ff,${d}_srl=$srl,${d}_carry4=$cy,${d}_dsp=$dsp"
}
set csv $ROOT/vc709/eeg/reports/build_summary.csv
set fh [open $csv a]; puts $fh "[clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S],$line"; close $fh

puts "=================================================================="
puts "EEG HIL BUILD DONE  clk=$clk_mhz MHz  WNS=$wns ns  WHS=$whs ns  DSP48 (whole chip)=$dsp_all"
puts "  $line"
if {$wns < 0} { puts "  *** TIMING NOT MET at $clk_mhz MHz - results at this clock are NOT sign-off valid ***" }
puts "  bit: $build/eeg_hil_top.bit"
puts "  reports: $rpt"
puts "=================================================================="
