# VC709 (xc7vx690tffg1761-2) constraints for eeg_hil_top
# SYSCLK + LED pins: proven by the blinky build.
# CPU_RESET, DIP SW0, USB-UART: VC709 master XDC (UG887); UART direction as
# in fpgasystems/fpga-network-stack vc709.xdc: AU36 = FPGA TX, AU33 = FPGA RX.

# ---------------- 200 MHz system clock ----------------
set_property PACKAGE_PIN H19 [get_ports SYSCLK_P]
set_property PACKAGE_PIN G18 [get_ports SYSCLK_N]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {SYSCLK_P SYSCLK_N}]
create_clock -period 5.000 -name sys_clk [get_ports SYSCLK_P]
# With USE_MMCM=1 Vivado derives the MMCM output clock from sys_clk automatically.

# ---------------- CPU_RESET push button (active high) ----------------
set_property PACKAGE_PIN AV40 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS18 [get_ports CPU_RESET]

# ---------------- GPIO DIP SW0: baud select (0 = 115200, 1 = 921600) ----------------
set_property PACKAGE_PIN AV30 [get_ports GPIO_DIP_SW0]
set_property IOSTANDARD LVCMOS18 [get_ports GPIO_DIP_SW0]

# ---------------- USB-UART (Silicon Labs CP2103, micro-USB J17) ----------------
set_property PACKAGE_PIN AU36 [get_ports UART_TXD]
set_property PACKAGE_PIN AU33 [get_ports UART_RXD]
set_property IOSTANDARD LVCMOS18 [get_ports {UART_TXD UART_RXD}]

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
# All of these are asynchronous, human-speed or UART-speed (>= 217 clocks/bit)
# and are synchronised in RTL. The FIR datapaths remain fully constrained.
set_false_path -from [get_ports {CPU_RESET GPIO_DIP_SW0 UART_RXD}]
set_false_path -to   [get_ports {LED[*] UART_TXD}]

# ---------------- configuration ----------------
set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
