# VC709 (xc7vx690tffg1761-2) constraints for demo_top
# Clock + LED pins are the ones already proven by the blinky build.
# Push-button / DIP pins are from the VC709 master XDC (UG887) - if Vivado
# reports an unplaced port, cross-check those against UG887 Table 1-x.

# ---------------- 200 MHz system clock ----------------
set_property PACKAGE_PIN H19 [get_ports SYSCLK_P]
set_property PACKAGE_PIN G18 [get_ports SYSCLK_N]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {SYSCLK_P SYSCLK_N}]
create_clock -period 5.000 -name sys_clk [get_ports SYSCLK_P]
# The MMCM output (when USE_MMCM=1) is derived automatically from sys_clk.

# ---------------- CPU_RESET push button (active high) ----------------
set_property PACKAGE_PIN AV40 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS18 [get_ports CPU_RESET]

# ---------------- GPIO DIP switches SW0..SW7 ----------------
set_property PACKAGE_PIN AV30 [get_ports {GPIO_DIP_SW[0]}]
set_property PACKAGE_PIN AY33 [get_ports {GPIO_DIP_SW[1]}]
set_property PACKAGE_PIN BA31 [get_ports {GPIO_DIP_SW[2]}]
set_property PACKAGE_PIN BA32 [get_ports {GPIO_DIP_SW[3]}]
set_property PACKAGE_PIN AW30 [get_ports {GPIO_DIP_SW[4]}]
set_property PACKAGE_PIN AY30 [get_ports {GPIO_DIP_SW[5]}]
set_property PACKAGE_PIN BA30 [get_ports {GPIO_DIP_SW[6]}]
set_property PACKAGE_PIN BB31 [get_ports {GPIO_DIP_SW[7]}]
set_property IOSTANDARD LVCMOS18 [get_ports {GPIO_DIP_SW[*]}]

# ---------------- User LEDs 0..7 ----------------
set_property PACKAGE_PIN AM39 [get_ports {LED[0]}]
set_property PACKAGE_PIN AN39 [get_ports {LED[1]}]
set_property PACKAGE_PIN AR37 [get_ports {LED[2]}]
set_property PACKAGE_PIN AT37 [get_ports {LED[3]}]
set_property PACKAGE_PIN AR35 [get_ports {LED[4]}]
set_property PACKAGE_PIN AP41 [get_ports {LED[5]}]
set_property PACKAGE_PIN AP42 [get_ports {LED[6]}]
set_property PACKAGE_PIN AU39 [get_ports {LED[7]}]
set_property IOSTANDARD LVCMOS18 [get_ports {LED[*]}]

# ---------------- timing exceptions ----------------
# Buttons/switches are synchronised in RTL; LEDs are human-speed.
set_false_path -from [get_ports {CPU_RESET GPIO_DIP_SW[*]}]
set_false_path -to   [get_ports {LED[*]}]

# ---------------- configuration ----------------
set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
