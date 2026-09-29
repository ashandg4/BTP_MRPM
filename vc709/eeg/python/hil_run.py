"""
Run the EEG hardware-in-the-loop test on a programmed VC709.

    python vc709/eeg/python/hil_run.py --port COM5 --mat vc709/eeg/synth.mat

  --baud must match DIP SW0 (0 -> 115200, 1 -> 921600; default 921600).

For every record (clean + AWGN at 30 ... -5 dB):
  1. quantise to int8, append 8 zeros (flush), upload, verify the on-chip checksum
  2. for every gap in --gaps: run on silicon, read back all three DUTs,
     verify the on-chip output sum, compare EVERY sample with the bit-exact model
  3. signal metrics computed from the HARDWARE output

Outputs in --out (default vc709/eeg/results/<timestamp>/):
  raw/<record>_gap<g>_<dut>.npy   every word read from the board (evidence)
  hw_verification.csv             per record x gap x DUT
  hw_timing.csv                   clocks / latency / throughput per DUT
  tables.tex                      two LaTeX tables for the paper
  run.log                         everything printed, with board + host info
  fig_eeg_hw.png                  clean vs noisy vs hardware output
Exit code 0 only if every sample of every run is bit-exact.
"""
import argparse, csv, datetime, os, platform, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import eeg_model as M
import hil_protocol as P


class Tee:
    def __init__(self, path):
        self.f = open(path, "w", encoding="utf-8")
    def __call__(self, *a):
        s = " ".join(str(x) for x in a)
        print(s); self.f.write(s + "\n"); self.f.flush()


class Board:
    def __init__(self, port, baud):
        import serial
        self.baud = baud
        self.retries = 0
        self.s = serial.Serial(port, baud, timeout=1.0, rtscts=False, dsrdtr=False)
        time.sleep(0.2)
        self.s.reset_input_buffer()

    def drain(self, quiet=1.5):
        """read and discard until the line has been silent for `quiet` s"""
        last = time.time()
        while time.time() - last < quiet:
            if self.s.read(4096):
                last = time.time()

    def xfer(self, tx, nrx, retries=3):
        # every command is idempotent (load/run/dump can be repeated), so a
        # short read (USB hiccup) is recovered by draining the line and retrying;
        # the on-chip checksums still verify whatever is finally accepted
        for attempt in range(retries + 1):
            self.s.reset_input_buffer()
            self.s.write(tx)
            self.s.flush()
            budget = 3.0 + 1.5 * 10.0 * (len(tx) + nrx) / self.baud
            t0 = time.time(); buf = bytearray()
            while len(buf) < nrx and time.time() - t0 < budget:
                buf += self.s.read(nrx - len(buf))
            if len(buf) == nrx:
                if attempt:
                    print(f"  (recovered after {attempt} retry/retries)")
                    self.retries += attempt
                return bytes(buf)
            print(f"  ! short reply: {len(buf)} of {nrx} bytes for command {tx[:1]!r}; "
                  + (f"draining and retrying ({attempt + 1}/{retries})" if attempt < retries else "giving up"))
            if attempt < retries:
                self.drain()
        raise IOError(f"expected {nrx} reply bytes, got {len(buf)} "
                      f"(check port, baud vs DIP SW0, and that the board is programmed)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--mat", required=True)
    ap.add_argument("--gaps", default="0 7", help="idle clocks between samples, e.g. '0 7'")
    ap.add_argument("--repeat", type=int, default=1, help="repeat every run N times")
    ap.add_argument("--levels", default=" ".join(str(v) for v in M.SNR_LEVELS_DB))
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out = a.out or os.path.join(HERE, "..", "results", stamp)
    os.makedirs(os.path.join(out, "raw"), exist_ok=True)
    log = Tee(os.path.join(out, "run.log"))
    gaps = [int(g) for g in a.gaps.split()]
    levels = [int(v) for v in a.levels.split()]

    b = Board(a.port, a.baud)
    info, _ = P.parse_ping(b.xfer(P.cmd_ping(), P.PING_LEN))
    fclk = info["clk_hz"]
    log(f"# VC709 EEG HIL run {stamp}")
    log(f"board: HIL1 clk={fclk/1e6:.3f} MHz AW={info['aw']} NDUT={info['ndut']}  port={a.port} baud={a.baud}")
    log(f"host : {platform.platform()} python {platform.python_version()} numpy {np.__version__}")
    log(f"data : {os.path.abspath(a.mat)}  noise seed {M.NOISE_SEED}  gaps {gaps}  repeat {a.repeat}")
    log(f"taps : {M.TAPS_Q.tolist()} / {M.COEF_SCALE}; analytic white-noise SNRI = {M.analytic_snri_db():.2f} dB")

    clean = M.load_synth(a.mat)
    sets = [s for s in M.make_datasets(clean, levels)]
    log(f"record: {len(clean)} samples, peak {np.max(np.abs(clean)):.3f}")

    ver_rows, tim_rows = [], []
    total_samples = 0; total_mism = 0; problems = 0
    keep_for_plot = {}

    for name, snr, x in sets:
        xq, scale = M.quantize(x)
        stream = M.stream_for_hw(xq)
        exp = M.expected_hw(stream)
        yfl = M.fir_float(x)                       # floating-point FIR on the float input
        n = len(stream)
        t0 = time.time()
        ld, _ = P.parse_load(b.xfer(P.cmd_load(stream), P.LOAD_LEN))
        t_up = time.time() - t0
        if ld["n"] != n or ld["sum"] != P.load_checksum(stream):
            log(f"{name}: UPLOAD CHECKSUM FAILED {ld} - aborting this record"); problems += 1; continue
        log(f"\n== {name}: {len(xq)} samples + {M.FLUSH} flush, scale {scale:.4f} LSB/unit, "
            f"upload {t_up:.1f}s checksum ok")
        ref_words = None
        for gap in gaps:
            for rep in range(a.repeat):
                run, _ = P.parse_run(b.xfer(P.cmd_run(gap), P.RUN_LEN))
                if run["timeout"]:
                    log(f"  gap {gap} rep {rep}: TIMEOUT flag set"); problems += 1
                words = []
                for d in range(P.NDUT):
                    r = run["duts"][d]
                    w, _ = P.parse_y(b.xfer(P.cmd_dump_y(d), P.y_dump_len(r["cnt"])), r["cnt"])
                    words.append(w)
                    if rep == 0:
                        np.save(os.path.join(out, "raw", f"{name}_gap{gap}_{M.DUT_SHORT[d]}.npy"), w)
                    sum_ok = P.ysum32(w) == r["ysum"]
                    mism = int(np.sum(w != exp[d])) if len(w) == n else n
                    total_samples += n; total_mism += mism
                    problems += (not sum_ok) + (mism != 0) + (r["cnt"] != n)
                    y_hw = M.hw_to_y(w, d, len(xq))
                    met = M.metrics(clean, x, M.to_physical(y_hw, scale), yfl)
                    clocks = r["last"] + 1
                    ver_rows.append(dict(record=name, snr_in_nominal=snr, gap=gap, rep=rep,
                                         dut=M.DUT_SHORT[d], samples=n, mismatches=mism,
                                         checksum_ok=sum_ok, **{k: round(v, 6) for k, v in met.items()}))
                    tim_rows.append(dict(record=name, gap=gap, rep=rep, dut=M.DUT_SHORT[d],
                                         fclk_mhz=fclk / 1e6, samples=n, clocks=clocks,
                                         first_out_clk=r["lat"],
                                         sample_latency_clk=r["lat"] + M.OFFSET[d],
                                         sample_latency_ns=(r["lat"] + M.OFFSET[d]) * 1e9 / fclk,
                                         exec_time_us=clocks * 1e6 / fclk,
                                         throughput_msps=n / clocks * fclk / 1e6))
                    log(f"  gap {gap} rep {rep} {M.DUT_SHORT[d]:8s} cnt {r['cnt']} mism {mism} "
                        f"sum {'ok' if sum_ok else 'BAD'} clocks {clocks} lat {r['lat']}+{M.OFFSET[d]} | "
                        f"SNRin {met['snr_in']:.2f} SNRout {met['snr_out']:.2f} SNRI {met['snri']:.2f} "
                        f"COR {met['cor']:.5f} MSE {met['mse']:.5f} fid {met['fidelity_snr']:.2f} dB")
                # all DUTs, gaps and repeats must give the same aligned output
                al = [M.hw_to_y(words[d], d, len(xq)) for d in range(P.NDUT)]
                if ref_words is None: ref_words = al[0]
                same = all(np.array_equal(ref_words, v) for v in al)
                problems += not same
                log(f"  gap {gap} rep {rep}: A/B/C identical to each other and to first run: {same}")
        keep_for_plot[name] = (x, M.to_physical(ref_words, scale) if ref_words is not None else None)

    # ---------------- files ----------------
    def wcsv(path, rows):
        if not rows: return
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
    wcsv(os.path.join(out, "hw_verification.csv"), ver_rows)
    wcsv(os.path.join(out, "hw_timing.csv"), tim_rows)
    write_tex(os.path.join(out, "tables.tex"), ver_rows, tim_rows, fclk, len(clean))
    try:
        plot(os.path.join(out, "fig_eeg_hw.png"), clean, keep_for_plot)
    except Exception as e:
        log(f"(plot skipped: {e})")

    log(f"\nTOTAL: {total_samples} hardware output samples compared, {total_mism} mismatches, "
        f"{problems} problems, {getattr(b, 'retries', 0)} UART retries")
    log("HARDWARE BIT-EXACT" if problems == 0 and total_mism == 0 else "HARDWARE CHECK FAILED")
    log(f"results in {os.path.abspath(out)}")
    sys.exit(0 if problems == 0 else 1)


def write_tex(path, ver, tim, fclk, nrec):
    # Table 1: one row per record (gap 0, rep 0, DUT C; A/B/C identical is checked above)
    rows = [r for r in ver if r["gap"] == 0 and r["rep"] == 0 and r["dut"] == "C_pipe"]
    mism, comp = {}, {}
    for r in ver:
        mism[r["record"]] = mism.get(r["record"], 0) + r["mismatches"]
        comp[r["record"]] = comp.get(r["record"], 0) + r["samples"]
    L = []
    L.append(r"% generated by vc709/eeg/python/hil_run.py - numbers read back from the VC709")
    L.append(r"\begin{table}[t]\centering")
    L.append(r"\caption{Hardware-in-the-loop results on the VC709 (XC7VX690T) for the synthetic EEG record "
             rf"({nrec:,} samples) with white Gaussian noise. Every output of all three FIRs was read back "
             r"and compared with the bit-exact model; metrics are computed from the hardware output.}")
    L.append(r"\label{tab:hw_eeg}\small")
    L.append(r"\begin{tabular}{lrrrrrr}\hline")
    L.append(r"Input & SNR$_\mathrm{in}$ & SNR$_\mathrm{out}$ & SNRI & COR & MSE & Mismatches / \\")
    L.append(r" & (dB) & (dB) & (dB) & & & outputs compared \\ \hline")
    for r in rows:
        lab = "clean" if r["snr_in_nominal"] in (None, "") else f"{r['snr_in_nominal']} dB AWGN"
        snr_in = "--" if lab == "clean" else f"{r['snr_in']:.2f}"
        L.append(f"{lab} & {snr_in} & {r['snr_out']:.2f} & "
                 f"{'--' if lab == 'clean' else format(r['snri'], '.2f')} & {r['cor']:.4f} & "
                 f"{r['mse']:.4f} & {mism[r['record']]} / {comp[r['record']]:,} \\\\")
    L.append(r"\hline\end{tabular}\end{table}")
    L.append("")
    # Table 2: timing measured by on-chip counters (clean record, per gap)
    L.append(r"\begin{table}[t]\centering")
    L.append(rf"\caption{{Timing measured on silicon by on-chip counters at {fclk/1e6:.0f}~MHz "
             r"(clean record + 8 flush samples).}")
    L.append(r"\label{tab:hw_timing}\small")
    L.append(r"\begin{tabular}{llrrrr}\hline")
    L.append(r"FIR & Gap & Clocks & Latency $x[n]\!\to\!y[n]$ & Exec. time & Throughput \\")
    L.append(r" & (clk) & & (clk / ns) & ($\mu$s) & (MS/s) \\ \hline")
    for r in tim:
        if r["record"] == "clean" and r["rep"] == 0:
            L.append(f"{r['dut'].replace('_', ' ')} & {r['gap']} & {r['clocks']:,} & "
                     f"{r['sample_latency_clk']} / {r['sample_latency_ns']:.1f} & "
                     f"{r['exec_time_us']:.1f} & {r['throughput_msps']:.2f} \\\\")
    L.append(r"\hline\end{tabular}\end{table}")
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")


def plot(path, clean, keep):
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    names = [k for k in ("clean", "awgn_+10dB", "awgn_-5dB") if k in keep and keep[k][1] is not None]
    fig, ax = plt.subplots(len(names), 1, figsize=(9, 2.4 * len(names)), sharex=True)
    ax = np.atleast_1d(ax)
    s = slice(0, 4000); ref = M.delayed_ref(clean)
    for i, k in enumerate(names):
        x, y = keep[k]
        ax[i].plot(x[s], lw=0.5, color="0.7", label="FIR input")
        ax[i].plot(y[s], lw=0.9, color="C3", label="VC709 output")
        ax[i].plot(ref[s], lw=0.7, ls="--", color="k", label="clean (delayed 3.5)")
        ax[i].set_title(k, fontsize=9); ax[i].legend(fontsize=7, loc="upper right")
    ax[-1].set_xlabel("sample")
    fig.tight_layout(); fig.savefig(path, dpi=200)


if __name__ == "__main__":
    main()
