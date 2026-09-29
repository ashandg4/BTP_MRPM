#!/usr/bin/env python3
"""Diff a Vivado ILA CSV export of demo_top against the bit-exact model.

    python vc709/python/check_ila_csv.py capture.csv [--aligned out.csv]

Works for both FIR variants: y_idx is computed in hardware from USE_PIPE.

Rows with in_valid_s=1 give (sample_idx, x_smp); rows with out_valid=1 give
(y_idx, y_out). Each is checked against demo_model. DIP is read from the
capture itself. Outputs whose history straddles the reset (y_idx < 8 or
>= 65528) are skipped because the model cannot know if history was zero.
"""
import argparse
import csv
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
import demo_model as m  # noqa: E402

COLS = {
    "x": "x_smp", "iv": "in_valid_s", "y": "y_out", "ov": "out_valid",
    "idx": "sample_idx", "yidx": "y_idx", "dip": "dip",
}


def parse_ila_csv(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    header = rows[0]
    radix_row = rows[1] if rows[1] and rows[1][0].lower().startswith("radix") else None
    data = rows[2:] if radix_row else rows[1:]

    col = {}
    for key, name in COLS.items():
        hits = [i for i, h in enumerate(header) if h.lower().startswith(name.lower())]
        if not hits:
            sys.exit(f"column '{name}' not found in header: {header}")
        col[key] = hits[0]

    def radix(i):
        if radix_row is None:
            return "HEX"
        return radix_row[i].split("-")[-1].strip().upper()

    def val(row, key, bits):
        i = col[key]
        r = radix(i)
        s = row[i].strip()
        if r == "HEX":
            v = int(s, 16)
        elif r == "BINARY":
            v = int(s, 2)
        else:
            v = int(s)
        return m.to_signed(v, bits) if key in ("x", "y") else v & ((1 << bits) - 1)

    xs, ys, dips = {}, {}, set()
    for row in data:
        if len(row) <= max(col.values()) or not row[col["iv"]].strip():
            continue
        dips.add(val(row, "dip", 8))
        if val(row, "iv", 1):
            xs[val(row, "idx", 16)] = val(row, "x", 8)
        if val(row, "ov", 1):
            ys[val(row, "yidx", 16)] = val(row, "y", 20)
    return xs, ys, dips


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--aligned", help="write 'n,x,y' CSV of the captured samples")
    a = ap.parse_args()

    xs, ys, dips = parse_ila_csv(a.csv)
    if len(dips) != 1:
        sys.exit(f"DIP changed during capture ({sorted(dips)}); set DIP, press CPU_RESET, re-capture")
    dip = dips.pop()

    x_bad = [(n, x, m.x_sample(n, dip)) for n, x in xs.items() if x != m.x_sample(n, dip)]
    y_bad, skipped = [], 0
    for n, y in ys.items():
        if n < 8 or n >= m.IDX_MOD - 8:
            skipped += 1
            continue
        exp = m.y_sample(n, dip)
        if y != exp:
            y_bad.append((n, y, exp))

    for n, got, exp in (x_bad + y_bad)[:10]:
        print(f"MISMATCH idx={n} got={got} exp={exp}")
    print(f"dip={dip}  x samples={len(xs)} ({len(x_bad)} bad)  "
          f"y samples={len(ys) - skipped} ({len(y_bad)} bad, {skipped} skipped at reset boundary)")
    print("HARDWARE BIT-EXACT" if not x_bad and not y_bad else "HARDWARE MISMATCH")

    if a.aligned:
        with open(a.aligned, "w") as f:
            f.write("n,x,y\n")
            for n in sorted(set(xs) & set(ys)):
                f.write(f"{n},{xs[n]},{ys[n]}\n")
        print(f"wrote {a.aligned}")
    sys.exit(1 if (x_bad or y_bad) else 0)


if __name__ == "__main__":
    main()
