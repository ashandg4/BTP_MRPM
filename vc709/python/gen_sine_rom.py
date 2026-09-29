#!/usr/bin/env python3
"""Generate sine_rom.mem / sine_rom.coe and the golden vector file for tb_demo_top.

    python vc709/python/gen_sine_rom.py [--dip 32] [--n 2048]

Writes (paths relative to repo root):
    vc709/rtl/sine_rom.mem      ($readmemh table used by sine_rom.v)
    vc709/rtl/sine_rom.coe      (same table, for Block Memory Generator if ever needed)
    vc709/sim/demo_golden.txt   ("idx x_hex2 y_hex5" per line, from reset, given DIP)
"""
import argparse
import os
import demo_model as m

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dip", type=int, default=32, help="GPIO_DIP_SW value (tone B = dip*fs/512)")
    ap.add_argument("--n", type=int, default=2048, help="samples to write to the golden file")
    a = ap.parse_args()

    rom = m.rom_table()
    assert all(-127 <= v <= 127 for v in rom)

    mem = os.path.join(ROOT, "vc709", "rtl", "sine_rom.mem")
    with open(mem, "w") as f:
        for v in rom:
            f.write(f"{v & 0xFF:02x}\n")

    coe = os.path.join(ROOT, "vc709", "rtl", "sine_rom.coe")
    with open(coe, "w") as f:
        f.write("memory_initialization_radix=16;\nmemory_initialization_vector=\n")
        f.write(",\n".join(f"{v & 0xFF:02x}" for v in rom) + ";\n")

    xs, ys = m.sequence_from_reset(a.n, a.dip)
    assert all(-128 <= x <= 127 for x in xs)
    # steady-state model must agree with the from-reset model once history is full
    assert all(m.y_sample(n, a.dip) == ys[n] for n in range(8, a.n))

    gold = os.path.join(ROOT, "vc709", "sim", "demo_golden.txt")
    os.makedirs(os.path.dirname(gold), exist_ok=True)
    with open(gold, "w") as f:
        for n, (x, y) in enumerate(zip(xs, ys)):
            f.write(f"{n} {x & 0xFF:02x} {y & 0xFFFFF:05x}\n")

    print(f"wrote {mem}\nwrote {coe}\nwrote {gold}  (dip={a.dip}, {a.n} samples)")
    print(f"tone A = fs/64, tone B = fs*{a.dip}/512, |H| at tone B = {m.fir_response(a.dip/512):.2f} (DC gain {sum(m.H)})")


if __name__ == "__main__":
    main()
