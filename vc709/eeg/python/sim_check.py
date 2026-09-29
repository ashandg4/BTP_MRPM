"""
Pre-silicon check of the whole HIL path (RTL + protocol + host parser).

    python vc709/eeg/python/sim_check.py --mat synth.mat      (from repo root)

Builds a command stream with the same encoder as hil_run.py, simulates
eeg_hil_top in Icarus (AW=12, UART at 8 clocks/bit), then parses the
reply bytes with the same parser and compares every DUT output with the
bit-exact model. Must print "SIM PASS".
"""
import argparse, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
import eeg_model as M
import hil_protocol as P

RTL = ["rtl/han_carlson_adder.v", "rtl/mrpm_radix4.v", "rtl/mrpm_radix4_wide.v",
       "rtl/mrpm_radix4_wide_pipe.v", "rtl/fir8_symmetric.v", "rtl/fir8_fold.v",
       "rtl/fir8_fold_pipelined.v", "vc709/eeg/rtl/uart_rx.v", "vc709/eeg/rtl/uart_tx.v",
       "vc709/eeg/rtl/eeg_hil_top.v", "vc709/eeg/sim/tb_eeg_hil.v"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mat", required=True)
    ap.add_argument("--n", type=int, default=1500, help="samples per test record")
    ap.add_argument("--full", action="store_true",
                    help="one run over the WHOLE clean record at AW=18 (slow: ~15-30 min)")
    a = ap.parse_args()

    clean = M.load_synth(a.mat)
    sets = M.make_datasets(clean)
    rng = np.random.default_rng(1)
    tests = []
    if a.full:
        xq, _ = M.quantize(sets[0][2])
        tests.append(("FULL clean record gap0", xq, 0))
    # 1) clean EEG, one sample per clock        2) -5 dB EEG, gap 3
    # 3) EEG crossing an epoch boundary, gap 0  4) full-scale random int8 (corner codes)
    if not a.full:
      xq, _ = M.quantize(sets[0][2]);  tests.append(("clean[0:n] gap0", xq[:a.n], 0))
      xq, _ = M.quantize(sets[-1][2]); tests.append(("awgn-5dB[0:n] gap3", xq[:a.n], 3))
      xq, _ = M.quantize(sets[0][2]);  tests.append(("clean[epoch 1|2 boundary] gap0",
                                                     xq[20001 - a.n // 2: 20001 + a.n // 2], 0))
      rnd = rng.integers(-128, 128, a.n); rnd[:16] = [-128, 127] * 8
      tests.append(("random int8 extremes gap1", rnd, 1))

    cmd = bytearray(); meta = []
    def tr(b, nreply):
        cmd.extend(b); meta.append((len(b), nreply))
    tr(P.cmd_ping(), P.PING_LEN)
    plan = []
    for name, x, gap in tests:
        s = M.stream_for_hw(x)
        tr(P.cmd_load(s), P.LOAD_LEN)
        tr(P.cmd_run(gap), P.RUN_LEN)
        for d in range(P.NDUT):
            tr(P.cmd_dump_y(d), P.y_dump_len(len(s)))
        plan.append((name, x, s, gap))
    tr(P.cmd_dump_x(), 1 + len(plan[-1][2]))

    os.chdir(ROOT)
    os.makedirs("build", exist_ok=True)
    with open("tb_cmd.hex", "w") as f:
        f.writelines(f"{b:02x}\n" for b in cmd)
    with open("tb_meta.txt", "w") as f:
        f.writelines(f"{t} {r}\n" for t, r in meta)
    params = ["-P", "tb_eeg_hil.AW=18", "-P", "tb_eeg_hil.DIV=4"] if a.full else []
    subprocess.run(["iverilog", "-g2005", "-DSIM_NO_PRIMS"] + params + ["-o", "build/eeg_hil.vvp"] + RTL, check=True)
    out = subprocess.run(["vvp", "build/eeg_hil.vvp"], capture_output=True, text=True).stdout
    print(out.strip())
    rx = bytes(int(l, 16) for l in open("tb_rx.hex") if l.strip())
    for f in ("tb_cmd.hex", "tb_meta.txt", "tb_rx.hex"):
        os.remove(f)

    p = 0; fails = 0
    info, c = P.parse_ping(rx[p:]); p += c
    print(f"ping: {info}")
    for name, x, s, gap in plan:
        ld, c = P.parse_load(rx[p:]); p += c
        ok_ld = ld["n"] == len(s) and ld["sum"] == P.load_checksum(s)
        run, c = P.parse_run(rx[p:]); p += c
        exp = M.expected_hw(s)
        line = [f"{name:34s} load {'ok' if ok_ld else 'BAD'} timeout={run['timeout']}"]
        fails += (not ok_ld) + run["timeout"]
        for d in range(P.NDUT):
            r = run["duts"][d]
            w, c = P.parse_y(rx[p:], r["cnt"]); p += c
            mism = int(np.sum(w != exp[d])) if len(w) == len(exp[d]) else -1
            sum_ok = P.ysum32(w) == r["ysum"]
            if mism != 0:
                # diagnose: which offset would have matched?
                y = M.fir_int(s)
                for off in range(-2, 7):
                    e = np.concatenate([np.zeros(max(off, 0), dtype=np.int64), y[max(-off, 0):]])[:len(w)]
                    if len(e) == len(w) and np.all(e == w):
                        line.append(f"   {M.DUT_SHORT[d]} matches with offset {off}")
            fails += (mism != 0) + (not sum_ok) + (r["cnt"] != len(s))
            line.append(f"   {M.DUT_SHORT[d]:9s} cnt={r['cnt']} lat={r['lat']} last={r['last']} "
                        f"mismatches={mism} ysum {'ok' if sum_ok else 'BAD'}")
        print("\n".join(line))
    assert rx[p:p + 1] == b"X"
    xb = np.frombuffer(rx[p + 1:p + 1 + len(plan[-1][2])], dtype=np.int8).astype(np.int64)
    xr_ok = np.array_equal(xb, plan[-1][2]); fails += not xr_ok
    print(f"x read-back: {'ok' if xr_ok else 'BAD'}; {len(rx) - p - 1 - len(xb)} trailing bytes")
    print("SIM PASS" if fails == 0 else f"SIM FAIL ({fails} problems)")
    sys.exit(0 if fails == 0 else 1)


if __name__ == "__main__":
    main()
