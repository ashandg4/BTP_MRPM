# VC709 (xc7vx690tffg1761-2) hardware validation of the folded MRPM FIR

Everything here wraps the thesis RTL in `../rtl/` **unchanged**. Run all commands
from the repo root. `VIVADO` = path to `vivado.bat` (e.g. `/c/AMD/Vivado/2026.1/bin/vivado.bat`).

| Path | Purpose |
|---|---|
| `rtl/demo_top.v` | 200 MHz -> two-tone NCO -> `fir8_fold` / `fir8_fold_pipelined` -> ILA probes + LEDs |
| `rtl/sine_rom.v` + `.mem`/`.coe` | 256 x int8 sine table (generated) |
| `xdc/demo_top.xdc` | VC709 pins, 5 ns clock, false paths on buttons/LEDs |
| `python/demo_model.py` | bit-exact model of the harness (NCO + FIR) |
| `python/gen_sine_rom.py` | writes ROM files + `sim/demo_golden.txt` |
| `python/check_ila_csv.py` | ILA CSV export -> bit-exact diff vs model |
| `python/measure_response.py` | set of ILA exports -> measured vs analytic |H(f)| |
| `sim/tb_demo_top.v` | Icarus self-check of the whole harness (`make demo`) |
| `tcl/synth_ooc.tcl`, `tcl/fmax_sweep.sh` | Day 1 / Day 6: OOC synth+impl, utilization, Fmax sweep |
| `tcl/build_demo.tcl`, `tcl/program.tcl` | Day 4: project + ILA IP + bitstream, JTAG program |

## Day 1 - 7-series numbers for the paper (no board needed)

```bash
VIVADO=/c/AMD/Vivado/2026.1/bin/vivado.bat PERIODS="5.0" vc709/tcl/fmax_sweep.sh
```
Produces `vc709/reports/<top>_<adder>_p5.0/{util_impl.rpt,timing_impl.rpt}` for
`mrpm_radix4`, `mrpm_radix4_wide`, `fir8_fold`, `fir8_fold_pipelined`, and one
line each in `vc709/reports/summary.csv` (LUT, FF, DSP48, WNS, Fmax). DSP48 must be 0.
Quote the `.rpt` files, never the console.

## Day 2-3 - vectors and simulation

```bash
make demo_vectors          # DEMO_DIP=32 default; tone B = 32*fs/512
make demo                  # both variants must print "x 0 mismatches ... y 0 mismatches"
```

## Day 4 - build, program, ILA

```bash
$VIVADO -mode batch -source vc709/tcl/build_demo.tcl -tclargs pipe      # 200 MHz
$VIVADO -mode batch -source vc709/tcl/build_demo.tcl -tclargs fold 10   # fold at 100 MHz via MMCM if it misses 5 ns
$VIVADO -mode batch -source vc709/tcl/program.tcl   -tclargs pipe
```
LEDs: 0 heartbeat, 1 reset held, 2 = USE_PIPE, 3 = clock locked, 7:4 = DIP[3:0].

ILA (Vivado GUI -> Hardware Manager, probes file is pre-associated):
* Trigger: `sample_idx == 0` and `in_valid_s == 1` (or just run trigger immediately).
* Capture mode: leave storage qualifier **off** (8192 clocks = 1024 samples at SAMPLE_DIV=8).
* Procedure: set DIP switches -> press CPU_RESET -> arm/run trigger -> `Export ILA data` as CSV.

## Day 5 - hardware bit-exactness

```bash
python vc709/python/check_ila_csv.py capture_dip32.csv --aligned aligned_dip32.csv
```
Prints `HARDWARE BIT-EXACT` when every captured x and y equals the model.
DIP value is read from the capture; the FIR variant is handled by `y_idx` in hardware.

## Day 6 - measured response and Fmax

```bash
# one capture per DIP setting, e.g. 4, 8, 16, 32, 48, 64, 96, 128, 160, 192, 224, 255
python vc709/python/measure_response.py captures/*.csv --out response.csv --plot
# Fmax sweep (fresh Vivado per run, ~2-4 min each on a small design)
PERIODS="5.0 4.0 3.5 3.0 2.5 2.0" TOPS="fir8_fold fir8_fold_pipelined" vc709/tcl/fmax_sweep.sh
ADDER=kogge_stone_adder TOPS="fir8_fold" vc709/tcl/fmax_sweep.sh   # adder sweep on 7-series
```
Achieved Fmax per run = 1000 / (period - WNS); the tightest period with WNS >= 0 is
the honest headline. Tone B is on DFT bin `dip` of 512 samples, so the measured
gain has no leakage and should match the analytic curve to rounding.

## Notes
* Pin assignments for CPU_RESET / DIP switches come from the VC709 master XDC;
  clock + LED pins are proven by the blinky build. If Vivado flags a pin, check UG887.
* `demo_top` utilization includes NCO/ROM/ILA - it is **not** the paper number;
  the Day 1 OOC reports are.
* SAMPLE_DIV must stay >= 6 (pipelined FIR latency 4 + `y_idx` bookkeeping).
