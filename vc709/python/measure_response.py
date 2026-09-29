#!/usr/bin/env python3
"""Measured FIR frequency response from a set of ILA captures (one per DIP value).

    python vc709/python/measure_response.py captures/*.csv [--out response.csv] [--plot]

Tone B sits at f/fs = dip/512, i.e. exactly on bin `dip` of a 512-point DFT, so
a rectangular 512-sample window has no leakage. |H| = |Y[dip]| / |X[dip]| is
compared with the analytic response of h = [0,3,20,42,42,20,3,0].
"""
import argparse
import cmath
import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import demo_model as m            # noqa: E402
from check_ila_csv import parse_ila_csv  # noqa: E402

N = 512


def dft_bin(seq, k):
    w = -2j * math.pi * k / N
    return sum(v * cmath.exp(w * i) for i, v in enumerate(seq))


def contiguous_block(xs, ys):
    """First run of N consecutive indices present in both dicts, skipping the transient."""
    common = sorted(set(xs) & set(ys))
    for start in range(len(common) - N + 1):
        n0 = common[start]
        if n0 < 8:
            continue
        if common[start + N - 1] == n0 + N - 1:
            idx = range(n0, n0 + N)
            return [xs[i] for i in idx], [ys[i] for i in idx]
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+")
    ap.add_argument("--out", default="response.csv")
    ap.add_argument("--plot", action="store_true")
    a = ap.parse_args()

    rows = []
    for path in a.csvs:
        xs, ys, dips = parse_ila_csv(path)
        if len(dips) != 1:
            print(f"{path}: DIP not constant, skipped"); continue
        dip = dips.pop()
        if dip == 0:
            print(f"{path}: dip=0 has no tone B, skipped"); continue
        xb, yb = contiguous_block(xs, ys)
        if xb is None:
            print(f"{path}: need >= {N}+8 contiguous samples (ILA depth 8192, no storage qualifier)"); continue
        gain = abs(dft_bin(yb, dip)) / abs(dft_bin(xb, dip))
        theory = m.fir_response(dip / N)
        rows.append((dip, dip / N, gain, theory))
        print(f"{os.path.basename(path)}: dip={dip:3d} f/fs={dip/N:.4f} measured={gain:8.3f} theory={theory:8.3f}")

    rows.sort()
    with open(a.out, "w") as f:
        f.write("dip,f_over_fs,measured_gain,theory_gain,measured_dB,theory_dB\n")
        for dip, fn, g, t in rows:
            f.write(f"{dip},{fn:.6f},{g:.4f},{t:.4f},{20*math.log10(max(g,1e-9)):.3f},{20*math.log10(max(t,1e-9)):.3f}\n")
    print(f"wrote {a.out} ({len(rows)} points)")

    if a.plot and rows:
        import matplotlib.pyplot as plt
        fs = [r[1] for r in rows]
        plt.plot([k / 1024 for k in range(513)], [20*math.log10(max(m.fir_response(k/1024),1e-9)) for k in range(513)], label="analytic")
        plt.plot(fs, [20*math.log10(max(r[2],1e-9)) for r in rows], "o", label="VC709 measured")
        plt.xlabel("f / fs"); plt.ylabel("|H| (dB)"); plt.grid(True); plt.legend()
        plt.title("8-tap folded MRPM FIR: measured vs analytic response")
        plt.savefig(os.path.splitext(a.out)[0] + ".png", dpi=150)
        print("wrote", os.path.splitext(a.out)[0] + ".png")


if __name__ == "__main__":
    main()
