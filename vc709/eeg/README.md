# VC709 EEG hardware-in-the-loop test (synth.mat)

Runs the three thesis FIRs **on the Virtex-7 silicon** over the full synthetic
EEG record (`synth.mat`, 140,007 samples, 7 epochs, amplitude about ±10) and reads every
output back to the PC. The thesis RTL in `rtl/` is instantiated **unchanged**.

```
PC (python) --USB-UART--> x RAM (BRAM, int8) --200 MHz, 1 sample/clk--> A fir8_symmetric  -> y RAM A
                                                                     -> B fir8_fold       -> y RAM B
                                                                     -> C fir8_fold_pipelined -> y RAM C
PC (python) <--USB-UART-- y RAMs + on-chip counters (count, latency, clocks, checksum)
```

What is a **hardware measurement** here:
* bit-exactness of every output sample of every FIR, for every record (vs `eeg_model.fir_int`);
* clocks / latency / throughput counted by on-chip counters at the real clock;
* die temperature and VCCINT / VCCAUX / VCCBRAM read from the XADC over JTAG;
* LUT / FF / BRAM / DSP48 / WNS from the routed design (Vivado reports of the build that ran).

What is **not** a hardware measurement: power (Vivado estimate, vectorless or
SAIF-annotated), and the SNR/COR/MSE values themselves. Those are computed from the
hardware output, but a bit-exact output gives the same numbers as the model. The
hardware run proves that the silicon produces those numbers.

## Files

| Path | Purpose |
|---|---|
| `rtl/eeg_hil_top.v` | top: clocking, UART command FSM, x/y BRAMs, 3 DUTs, counters, LEDs |
| `rtl/uart_rx.v`, `rtl/uart_tx.v` | 8N1 UART, baud from DIP SW0 (115200 / 921600) |
| `xdc/eeg_hil_top.xdc` | VC709 pins (SYSCLK, CPU_RESET, SW0, USB-UART AU36/AU33, LEDs), 5 ns clock |
| `tcl/build_eeg_hil.tcl` | synth → impl → reports → bitstream (optionally 100–400 MHz via MMCM) |
| `tcl/program_eeg_hil.tcl` | JTAG program + XADC temperature / voltage log |
| `tcl/power_saif.tcl` | optional: EEG-activity (SAIF) power estimate per FIR |
| `python/eeg_model.py` | data prep, AWGN, int8 quantisation, bit-exact model, metrics |
| `python/hil_protocol.py` | byte protocol, shared by board script and simulation |
| `python/hil_run.py` | **the board run** → CSVs, `tables.tex`, figure, `run.log`, raw `.npy` |
| `python/sim_check.py` | Icarus simulation of the whole path (must print `SIM PASS`) |
| `python/gen_power_stim.py` | EEG stimulus files for `power_saif.tcl` |
| `sim/tb_eeg_hil.v`, `sim/tb_power.v` | testbenches |

## 0. Before the lab (laptop, no board)

```bash
pip install numpy scipy pyserial matplotlib
python vc709/eeg/python/sim_check.py --mat vc709/eeg/synth.mat          # ~1 min, must print SIM PASS
python vc709/eeg/python/sim_check.py --mat vc709/eeg/synth.mat --full   # whole record, ~30-60 min
```

## 1. Build (lab PC with Vivado; ~15-25 min)

```bash
vivado -mode batch -source vc709/eeg/tcl/build_eeg_hil.tcl -tclargs 200
```
Console must end with `EEG HIL BUILD DONE clk=200 MHz WNS=<positive>`. Reports go to
`vc709/eeg/reports/clk200/`; the per-DUT LUT/FF/SRL/CARRY4/DSP48 counts are in `build_summary.csv`.

## 2. Board setup

1. Connect the micro-USB **USB-UART** port (CP2103, see UG887 board photo) and the JTAG USB. Power on.
2. Windows: Device Manager → *Ports* → note `Silicon Labs CP210x ... (COMx)`
   (install the CP210x VCP driver if it does not appear).
3. **DIP SW0 ON = 921600 baud** (default of the script), OFF = 115200.
4. Program + log XADC:
   ```bash
   vivado -mode batch -source vc709/eeg/tcl/program_eeg_hil.tcl -tclargs 200
   ```
5. Press **CPU_RESET** once. LEDs: 0 blinks (heartbeat), 6 on (clock locked), 5 = SW0.

## 3. Run (~5 min at 921600, ~35 min at 115200)

```bash
python vc709/eeg/python/hil_run.py --port COM5 --mat vc709/eeg/synth.mat
vivado -mode batch -source vc709/eeg/tcl/program_eeg_hil.tcl -tclargs 200 read   # XADC right after
```
It must end with `HARDWARE BIT-EXACT`. LED 4 = last run OK, LED 7 = error.
Results: `vc709/eeg/results/<timestamp>/` → `tables.tex` (two paper tables),
`hw_verification.csv`, `hw_timing.csv`, `fig_eeg_hw.png`, `run.log`, `raw/*.npy`.
**Keep the whole folder**: it is the evidence behind the tables.

Optional extras:
* `--repeat 10`: runs every record 10× (about 75 M outputs compared, ~45 min) to show there are no intermittent errors.
* At-speed margin: rebuild with `-tclargs 250` / `300` and rerun. Only quote a clock as
  *verified* if the build reported WNS ≥ 0 **and** the run is bit-exact. A bit-exact run
  at a clock with negative WNS is only a margin observation, not a sign-off result.
* Power: `python vc709/eeg/python/gen_power_stim.py --mat vc709/eeg/synth.mat`, then
  `vivado -mode batch -source vc709/eeg/tcl/power_saif.tcl -tclargs clean`
  (and `awgn_-5dB`). Label the result "Vivado estimate, SAIF from EEG stimulus".

## Troubleshooting
* `expected N reply bytes, got 0`: wrong COM port, board not programmed, or SW0 does not match
  `--baud`. Press CPU_RESET and retry. `--baud 115200` with SW0 OFF is the safe fallback.
* LED 7 on: an unknown command byte arrived (usually a baud mismatch). Press CPU_RESET.
* Vivado says a port is unplaced: compare the pin with the VC709 master XDC (UG887 appendix).

## Data conventions (write these in the paper)
* `synth.mat`: `y1`, 140,007 = 7 × 20,001 samples. Epoch 1 starts at exactly 6.0 =
  0.5+1.5+4, i.e. Agarwal et al. epoch 1 at T = 0. The sample step is T = 0.5 ms (fs = 2 kHz
  if T is in seconds). **Confirm fs with your supervisor.** All metrics are per-sample and do not depend on it.
* Noise: white Gaussian, SNR 30/25/20/15/10/5/1/−5 dB w.r.t. the measured signal power, seed 2017.
* Quantisation: each record is peak-normalised to [−1, 1] and rounded to int8 (Q0.7), with 8 zeros
  appended to flush the filter.
* SNR_out / COR / MSE: hardware output ÷ (scale·128) against the clean record delayed by the
  3.5-sample group delay, excluding the first 8 samples.
* Fidelity SNR (the AutoFIR-style metric): hardware output against the floating-point FIR on the
  same float input. It is capped near 36 dB by the int8 taps (Σh = 130, not 128 → DC gain 1.0156).
