# Activity-annotated power ESTIMATE for the three FIRs on the VC709 part,
# driven by the real EEG stream (UG907 flow: post-route functional netlist
# -> xsim -> SAIF -> report_power). This is still an estimate, not a board
# measurement, but the switching activity comes from the EEG data instead
# of the 12.5% vectorless default.
#
#   python vc709/eeg/python/gen_power_stim.py --mat vc709/eeg/synth.mat
#   vivado -mode batch -source vc709/eeg/tcl/power_saif.tcl -tclargs [record]
#
#   record : clean (default) | awgn_-5dB | any name written by gen_power_stim.py
#
# Output: vc709/eeg/reports/power/<dut>_<record>/power_saif.rpt (+ vectorless
# report of the same netlist for comparison) and power_summary.csv.
# Check "Design Nets Matched" in each report: it should be close to 100%.
# NOTE: written without access to Vivado on the author's laptop - if a
# command fails, the Tcl console message names the step.

set rec  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "clean"}]
set ROOT [file normalize [file join [file dirname [info script]] .. .. ..]]
set PART xc7vx690tffg1761-2
set stim $ROOT/vc709/eeg/build/power/x_$rec.hex
if {![file exists $stim]} { error "missing $stim - run gen_power_stim.py first" }
set fh [open $stim r]; set nsamp [llength [split [string trim [read $fh]] "\n"]]; close $fh
set XV $::env(XILINX_VIVADO)
set bin $XV/bin
set ext [expr {$tcl_platform(platform) eq "windows" ? ".bat" : ""}]

proc run {args} {
    global tcl_platform
    if {$tcl_platform(platform) eq "windows"} { set args [linsert $args 0 cmd /c] }
    puts ">> $args"
    exec {*}$args >@ stdout 2>@ stderr
}

set summ $ROOT/vc709/eeg/reports/power/power_summary.csv
file mkdir [file dirname $summ]

foreach top {fir8_symmetric fir8_fold fir8_fold_pipelined} {
    set dir $ROOT/vc709/eeg/reports/power/${top}_$rec
    file mkdir $dir
    catch {close_design}
    # ---- OOC implementation at 200 MHz (same RTL as the board) ----
    foreach f {han_carlson_adder.v mrpm_radix4.v mrpm_radix4_wide.v mrpm_radix4_wide_pipe.v
               fir8_symmetric.v fir8_fold.v fir8_fold_pipelined.v} { read_verilog $ROOT/rtl/$f }
    set xdc $dir/ooc.xdc
    set f [open $xdc w]; puts $f "create_clock -name clk -period 5.000 \[get_ports clk\]"; close $f
    read_xdc $xdc
    synth_design -top $top -part $PART -mode out_of_context
    opt_design; place_design; route_design
    report_utilization    -file $dir/util.rpt
    report_timing_summary -file $dir/timing.rpt
    report_power          -file $dir/power_vectorless.rpt
    write_verilog -force -mode funcsim $dir/${top}_funcsim.v

    # ---- xsim: post-route functional netlist + EEG stimulus -> SAIF ----
    set cwd [pwd]; cd $dir
    file copy -force $stim $dir/stim.hex
    run $bin/xvlog$ext $dir/${top}_funcsim.v $XV/data/verilog/src/glbl.v
    run $bin/xvlog$ext -d DUT=$top -d NSAMP=$nsamp $ROOT/vc709/eeg/sim/tb_power.v
    run $bin/xelab$ext -debug typical -L unisims_ver -L secureip tb_power glbl -s snap
    set f [open $dir/saif.tcl w]
    puts $f "run 200ns"
    puts $f "open_saif $dir/activity.saif"
    puts $f "log_saif \[get_objects -r /tb_power/dut/*\]"
    puts $f "run all"
    puts $f "close_saif"
    puts $f "quit"
    close $f
    run $bin/xsim$ext snap -tclbatch $dir/saif.tcl
    cd $cwd

    # ---- power with the EEG activity ----
    read_saif -strip_path tb_power/dut $dir/activity.saif
    report_power -file $dir/power_saif.rpt
    set f [open $dir/power_saif.rpt r]; set txt [read $f]; close $f
    set tot NA; set dyn NA; set sta NA; set conf NA
    regexp {Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)} $txt -> tot
    regexp {Dynamic \(W\)\s*\|\s*([0-9.]+)} $txt -> dyn
    regexp {Device Static \(W\)\s*\|\s*([0-9.]+)} $txt -> sta
    regexp {Confidence Level\s*\|\s*(\w+)} $txt -> conf
    set fh [open $summ a]
    puts $fh "$top,$rec,$nsamp,total_W=$tot,dynamic_W=$dyn,static_W=$sta,confidence=$conf"
    close $fh
    puts "POWER $top $rec  total=$tot W  dynamic=$dyn W  static=$sta W  (see $dir/power_saif.rpt)"
}
