import numpy as np

# --- SPEC ---
# ECG sampling rate: 250 Hz (standard for many ECG DBs, e.g. wearable).
# Low-pass cutoff: 40 Hz. ECG diagnostic band is ~0.05-40 Hz; a 40 Hz LPF
# removes EMG/high-freq noise while preserving QRS morphology.
# 8 taps, linear phase (symmetric), Hamming window.
fs   = 250.0
fc   = 40.0
N    = 8            # taps
nyq  = fs/2.0

# Windowed-sinc, type-II linear phase (even N -> symmetric, half-sample delay)
n = np.arange(N)
m = n - (N-1)/2.0
# ideal LPF impulse response (sinc), fc normalized
h_ideal = np.sinc(2*fc/fs * m) * (2*fc/fs)
# Hamming window
win = 0.54 - 0.46*np.cos(2*np.pi*n/(N-1))
h = h_ideal*win
h = h/np.sum(h)          # DC gain = 1

print("float taps (symmetric):")
print(np.array2string(h, precision=6))
print("symmetry check h[i]==h[N-1-i]:", np.allclose(h, h[::-1]))

# --- QUANTIZE to signed 8-bit ---
# Signed 8-bit range: -128..127. Coeffs are fractional & small; scale so the
# largest |coeff| maps near full scale, keep a power-of-two scale for easy
# hardware de-scaling (shift). Choose scale = 2^7 = 128 (Q1.7-ish) then check.
SCALE_BITS = 7
scale = 2**SCALE_BITS
q = np.round(h*scale).astype(int)
q = np.clip(q, -128, 127)
print("\nquantized int8 taps (scale=2^%d):" % SCALE_BITS)
print(q.tolist())
print("symmetry after quant:", (q==q[::-1]).all())
print("sum(q) =", q.sum(), " -> DC gain =", q.sum()/scale)

# --- accuracy of quantization ---
err = np.abs(h - q/scale)
print("max coeff quant error:", err.max())

# --- output bit-growth analysis ---
# input signed 8-bit: -128..127. coeff signed 8-bit: -128..127.
# product: up to 16 bits signed. Sum of 8 products: +log2(8)=3 guard bits.
# worst-case |acc| <= 8 * 127 * 128 = 130048 -> needs 18 bits signed.
worst = N * 127 * 128
import math
bits = math.ceil(math.log2(worst)) + 1
print("\nworst-case |accumulator| =", worst, "-> signed acc width =", bits, "bits")
print("full-precision output width chosen: 20 bits (safe)")

np.save("taps_q.npy", q)
np.save("taps_f.npy", h)
