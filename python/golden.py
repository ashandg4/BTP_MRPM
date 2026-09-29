import numpy as np

# ---------- signed radix-4 RPM (modified Booth recoding) ----------
# For SIGNED operands the clean radix-4 form IS modified Booth: it processes
# 2 bits/step, digits in {-2,-1,0,1,2}, 4 steps for 8-bit. This avoids the
# unsigned "3B" precompute and handles sign natively -> right choice for signed.
def rpm_radix4_signed(a, b, width=8):
    # sign-extend a to width+1 for Booth, accumulate shifted +-b, +-2b
    A = a & ((1<<width)-1)
    if a < 0: A = a & ((1<<width)-1)  # two's comp pattern
    # Use Python ints but emulate fixed width via masking at the end.
    acc = 0
    # Booth: examine (b_{2i+1}, b_{2i}, b_{2i-1})
    bb = a  # multiplicand
    mult = b
    # build bits of multiplier (two's complement, width bits) + implicit b[-1]=0
    def getbit(x, i):
        if i < 0: return 0
        return (x >> i) & 1
    for i in range(0, width, 2):
        code = getbit(mult,i-1) + getbit(mult,i)*(1 if i>=0 else 0)  # placeholder
    # --- simpler & provably-correct: do exact radix-4 Booth ---
    acc = 0
    prev = 0
    for i in range(0, width, 2):
        b0 = getbit(mult, i)
        b1 = getbit(mult, i+1)
        # Booth radix-4 digit from (b1,b0,prev)
        digit = b0 + prev - 2*b1
        acc += bb * digit * (1 << i)
        prev = b1
    return acc

# verify signed multiply exhaustively for 8-bit
bad=0
for a in range(-128,128):
    for b in range(-128,128):
        if rpm_radix4_signed(a,b)!=a*b:
            bad+=1
            if bad<5: print("MISMATCH",a,b,rpm_radix4_signed(a,b),a*b)
print("radix4 signed exhaustive mismatches:", bad, "(0 = perfect)")

# ---------- fixed-point FIR golden ----------
taps = np.load("taps_q.npy").astype(int)  # signed int8
N = len(taps)
SCALE_BITS = 7

def fir_fixed(x):
    # x: list of signed 8-bit ints. Full-precision integer accumulate.
    y=[]
    buf=[0]*N
    for s in x:
        buf = [s]+buf[:-1]
        acc = sum(rpm_radix4_signed(buf[k], int(taps[k])) for k in range(N))
        y.append(acc)   # full precision (scaled by 2^7)
    return y

# quick self-check vs numpy convolve (integer)
rng=np.random.default_rng(0)
x=rng.integers(-128,128,size=64).tolist()
y=fir_fixed(x)
# reference: direct integer conv, same orientation
ref=[]
buf=[0]*N
for s in x:
    buf=[s]+buf[:-1]
    ref.append(int(sum(buf[k]*int(taps[k]) for k in range(N))))
print("FIR golden matches integer reference:", y==ref)
print("sample outputs (scaled by 2^7):", y[:6])

# dump vectors for the Verilog testbench
with open("mult_vectors.txt","w") as f:
    for a in range(-128,128,7):
        for b in range(-128,128,11):
            f.write(f"{a & 0xFF:02x} {b & 0xFF:02x} {(a*b) & 0xFFFFFFFF:08x}\n")
with open("fir_vectors.txt","w") as f:
    for s,o in zip(x,y):
        f.write(f"{s & 0xFF:02x} {o & 0xFFFFF:05x}\n")
print("wrote mult_vectors.txt and fir_vectors.txt")
