import numpy as np

# --- SPEC (16-tap variant of gencoef.py, TASK 4) ---
# Same ECG low-pass spec as the 8-tap design, just more taps -> sharper
# transition. fs=250 Hz, fc=40 Hz, linear phase (symmetric), Hamming window.
# Writes SEPARATE artifacts (taps16_q.npy) so the verified 8-tap flow is
# left completely untouched.
fs   = 250.0
fc   = 40.0
N    = 16           # taps (was 8)
nyq  = fs/2.0

# Windowed-sinc, type-II linear phase (even N -> symmetric, half-sample delay)
n = np.arange(N)
m = n - (N-1)/2.0
h_ideal = np.sinc(2*fc/fs * m) * (2*fc/fs)
win = 0.54 - 0.46*np.cos(2*np.pi*n/(N-1))
h = h_ideal*win
h = h/np.sum(h)          # DC gain = 1

print("float taps (symmetric):")
print(np.array2string(h, precision=6))
print("symmetry check h[i]==h[N-1-i]:", np.allclose(h, h[::-1]))

# --- QUANTIZE to signed 8-bit, power-of-two scale (same as 8-tap) ---
SCALE_BITS = 7
scale = 2**SCALE_BITS
q = np.round(h*scale).astype(int)
q = np.clip(q, -128, 127)
print("\nquantized int8 taps (scale=2^%d):" % SCALE_BITS)
print(q.tolist())
print("symmetry after quant:", (q==q[::-1]).all())
print("sum(q) =", q.sum(), " -> DC gain =", q.sum()/scale)

err = np.abs(h - q/scale)
print("max coeff quant error:", err.max())

# --- output bit-growth analysis for 16 taps ---
# worst-case |acc| <= 16 * 127 * 128
worst = N * 127 * 128
import math
bits = math.ceil(math.log2(worst)) + 1
print("\nworst-case |accumulator| =", worst, "-> signed acc width =", bits, "bits")
print("full-precision output width chosen: 20 bits (safe:", worst < 2**19, ")")

np.save("taps16_q.npy", q)
np.save("taps16_f.npy", h)
