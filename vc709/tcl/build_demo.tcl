# Build the VC709 demo (project mode, with ILA) through to bitstream.
#
#   vivado -mode batch -source vc709/tcl/build_demo.tcl -tclargs [pipe|fold] [mmcm_div]
#
#   pipe|fold : which thesis FIR to wrap (default pipe)
#   mmcm_div  : omit or 0 = run straight at 200 MHz; 10 = 100 MHz via MMCM
#               (use this if fir8_fold fails timing at 5 ns in the OOC runs)
#
# Output: vc709/build/demo_<variant>/demo_vc709.runs/impl_1/demo_top.bit + .ltx
# Open the project in the GUI afterwards for the hardware manager / ILA.

set variant  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "pipe"}]
set mmcm_div [expr {[llength $argv] > 1 ? [lindex $argv 1] : 0}]
set use_pipe [expr {$variant eq "fold" ? 0 : 1}]
set use_mmcm [expr {$mmcm_div > 0 ? 1 : 0}]

set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set PART xc7vx690tffg1761-2
set build $ROOT/vc709/build/demo_${variant}

create_project -force demo_vc709 $build -part $PART

add_files [list \
    $ROOT/rtl/han_carlson_adder.v $ROOT/rtl/adder_variants.v \
    $ROOT/rtl/mrpm_radix4_wide.v  $ROOT/rtl/mrpm_radix4_wide_pipe.v \
    $ROOT/rtl/fir8_fold.v         $ROOT/rtl/fir8_fold_pipelined.v \
    $ROOT/vc709/rtl/sine_rom.v    $ROOT/vc709/rtl/demo_top.v \
    $ROOT/vc709/rtl/sine_rom.mem]
add_files -fileset constrs_1 $ROOT/vc709/xdc/demo_top.xdc
set_property top demo_top [current_fileset]
set_property verilog_define {USE_ILA=1} [current_fileset]
set_property generic [list USE_PIPE=$use_pipe USE_MMCM=$use_mmcm \
    MMCM_DIV=[expr {$mmcm_div > 0 ? $mmcm_div : 10}]] [current_fileset]

# ILA: 7 probes matching the u_ila instance in demo_top.v, 8192 deep
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {7} \
    CONFIG.C_DATA_DEPTH {8192} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.C_PROBE0_WIDTH {8}  \
    CONFIG.C_PROBE1_WIDTH {1}  \
    CONFIG.C_PROBE2_WIDTH {20} \
    CONFIG.C_PROBE3_WIDTH {1}  \
    CONFIG.C_PROBE4_WIDTH {16} \
    CONFIG.C_PROBE5_WIDTH {16} \
    CONFIG.C_PROBE6_WIDTH {8}] [get_ips ila_0]
generate_target all [get_ips ila_0]

update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }

open_run impl_1
set rpt $ROOT/vc709/reports/demo_${variant}
file mkdir $rpt
report_utilization    -file $rpt/util_impl.rpt -hierarchical
report_timing_summary -file $rpt/timing_impl.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "=================================================================="
puts "DEMO BUILD OK  variant=$variant  mmcm_div=$mmcm_div  WNS=$wns ns"
puts "  bit: $build/demo_vc709.runs/impl_1/demo_top.bit"
puts "  ltx: $build/demo_vc709.runs/impl_1/demo_top.ltx"
puts "=================================================================="
