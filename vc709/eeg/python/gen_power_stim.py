"""
Write the int8 EEG streams used by tcl/power_saif.tcl (same quantisation and
flush as the board run), plus the measured bit toggle rate of each stream.

    python vc709/eeg/python/gen_power_stim.py --mat vc709/eeg/synth.mat
"""
import argparse, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import eeg_model as M

ap = argparse.ArgumentParser()
ap.add_argument("--mat", required=True)
a = ap.parse_args()
out = os.path.join(HERE, "..", "build", "power")
os.makedirs(out, exist_ok=True)
clean = M.load_synth(a.mat)
for name, snr, x in M.make_datasets(clean):
    if name not in ("clean", "awgn_+10dB", "awgn_-5dB"):
        continue
    s = M.stream_for_hw(M.quantize(x)[0]) & 0xFF
    with open(os.path.join(out, f"x_{name}.hex"), "w") as f:
        f.writelines(f"{v:02x}\n" for v in s)
    bits = (s[:, None] >> np.arange(8)) & 1
    tog = np.mean(bits[1:] != bits[:-1], axis=0)
    print(f"{name:12s} {len(s)} samples; per-bit toggle rate LSB..MSB: "
          + " ".join(f"{t:.3f}" for t in tog) + f"  (mean {tog.mean():.3f})")
