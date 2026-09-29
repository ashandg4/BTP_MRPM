import numpy as np
import os

# ---------- 16-tap golden model (TASK 4) ----------
# Reuses the exact signed radix-4 Booth reference from golden.py, applied to
# the 16-tap coefficient set. Writes sim/fir16_vectors.txt for tb_fir16_fold.v.
# Leaves the 8-tap fir_vectors.txt / mult_vectors.txt untouched.

def rpm_radix4_signed(a, b, width=8):
    def getbit(x, i):
        if i < 0: return 0
        return (x >> i) & 1
    bb = a          # multiplicand
    mult = b        # multiplier
    acc = 0
    prev = 0
    for i in range(0, width, 2):
        b0 = getbit(mult, i)
        b1 = getbit(mult, i+1)
        digit = b0 + prev - 2*b1     # radix-4 Booth digit {-2..2}
        acc += bb * digit * (1 << i)
        prev = b1
    return acc

HERE = os.path.dirname(os.path.abspath(__file__))
taps = np.load(os.path.join(HERE, "taps16_q.npy")).astype(int)   # signed int8
N = len(taps)
assert N == 16, "expected 16 taps"
SCALE_BITS = 7

def fir_fixed(x):
    y = []
    buf = [0]*N
    for s in x:
        buf = [s]+buf[:-1]
        acc = sum(rpm_radix4_signed(buf[k], int(taps[k])) for k in range(N))
        y.append(acc)   # full precision (scaled by 2^7)
    return y

# self-check vs direct integer convolution
rng = np.random.default_rng(0)
x = rng.integers(-128, 128, size=64).tolist()
y = fir_fixed(x)
ref = []
buf = [0]*N
for s in x:
    buf = [s]+buf[:-1]
    ref.append(int(sum(buf[k]*int(taps[k]) for k in range(N))))
print("16-tap FIR golden matches integer reference:", y == ref)
print("sample outputs (scaled by 2^7):", y[:6])

# worst-case fits in 20-bit signed?
assert max(abs(v) for v in y) < 2**19, "output exceeds 20-bit signed range"

out = os.path.join(HERE, "..", "sim", "fir16_vectors.txt")
with open(out, "w") as f:
    for s, o in zip(x, y):
        f.write(f"{s & 0xFF:02x} {o & 0xFFFFF:05x}\n")
print("wrote", os.path.normpath(out))
