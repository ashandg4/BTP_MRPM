"""Bit-exact Python model of vc709/rtl/demo_top.v (NCO + sine ROM + 8-tap FIR).

Sample n after reset:
    ph_a = n*INC_A  mod 2^16,   ph_b = n*(dip<<7) mod 2^16
    x[n] = (ROM[ph_a>>8] >> 1) + (ROM[ph_b>>8] >> 1)      (arithmetic shifts)
    y[n] = sum_k H[k] * x[n-k]                              (x[<0] = 0)
"""
import math

H = [0, 3, 20, 42, 42, 20, 3, 0]
ROM_N = 256
INC_A = 1024                 # fs/64
IDX_MOD = 1 << 16            # sample_idx / phase accumulators are 16-bit


def rom_table():
    return [int(round(127 * math.sin(2 * math.pi * i / ROM_N))) for i in range(ROM_N)]


_ROM = rom_table()


def inc_b(dip):
    return (dip << 7) & 0xFFFF


def x_sample(n, dip):
    pa = (n * INC_A) & 0xFFFF
    pb = (n * inc_b(dip)) & 0xFFFF
    return (_ROM[pa >> 8] >> 1) + (_ROM[pb >> 8] >> 1)


def y_sample(n, dip):
    """Steady-state output (history taken from the periodic x sequence)."""
    return sum(H[k] * x_sample((n - k) % IDX_MOD, dip) for k in range(8))


def sequence_from_reset(n_samples, dip):
    """(x, y) lists for n = 0..n_samples-1 with zero FIR history at reset."""
    xs = [x_sample(n, dip) for n in range(n_samples)]
    ys, buf = [], [0] * 8
    for x in xs:
        buf = [x] + buf[:-1]
        ys.append(sum(h * b for h, b in zip(H, buf)))
    return xs, ys


def fir_response(f_norm):
    """|H(e^jw)| at normalised frequency f_norm = f/fs."""
    w = 2 * math.pi * f_norm
    re = sum(h * math.cos(w * k) for k, h in enumerate(H))
    im = sum(h * math.sin(w * k) for k, h in enumerate(H))
    return math.hypot(re, im)


def to_signed(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v
