"""
Shared model for the VC709 EEG hardware-in-the-loop test.

  * load_synth()        : synth.mat -> float EEG (140,007 samples, 7 epochs)
  * make_datasets()     : clean + AWGN at the SNR levels of Agarwal et al. [BSPC 2017]
  * quantize()          : float -> int8, peak-normalised per record
  * fir_int()           : bit-exact integer model of the thesis FIR (all 3 DUTs)
  * expected_hw()       : what each DUT must emit, in the order it emits it
  * metrics()           : SNR / SNRI / MSE / COR / fidelity SNR

Nothing here is tuned to make hardware "look good": the hardware stream is
compared sample-for-sample against fir_int(), and the signal metrics are
computed from the HARDWARE samples, not from the model.
"""
import numpy as np

# thesis coefficients (python/gencoef.py): fs=250 Hz, fc=40 Hz, Hamming, x128
TAPS_Q = np.array([0, 3, 20, 42, 42, 20, 3, 0], dtype=np.int64)
COEF_SCALE = 128
N_TAPS = len(TAPS_Q)
GROUP_DELAY = (N_TAPS - 1) / 2.0          # 3.5 samples (type-II linear phase)

# the float design the int8 taps were rounded from (gencoef.py, re-derived)
def taps_float():
    fs, fc, N = 250.0, 40.0, N_TAPS
    n = np.arange(N); m = n - (N - 1) / 2.0
    h = np.sinc(2 * fc / fs * m) * (2 * fc / fs)
    h *= 0.54 - 0.46 * np.cos(2 * np.pi * n / (N - 1))
    return h / h.sum()

SNR_LEVELS_DB = [30, 25, 20, 15, 10, 5, 1, -5]   # Agarwal et al., Tables 2-3
NOISE_SEED = 2017
FLUSH = N_TAPS                                     # zeros appended so the tail is observed

# per-DUT output offset: hardware word k of DUT d equals model y[k - OFFSET[d]]
# (fir8_symmetric / fir8_fold register y from the delay line BEFORE it shifts,
#  so they emit y[n-1] alongside x[n]; the pipelined FIR emits y[n]).
# Established by sim/tb_eeg_hil.v and re-checked on every hardware run.
DUT_NAMES = ["A_direct (fir8_symmetric)", "B_fold (fir8_fold)", "C_pipe (fir8_fold_pipelined)"]
DUT_SHORT = ["A_direct", "B_fold", "C_pipe"]
OFFSET = [1, 1, 0]


def load_synth(path):
    from scipy.io import loadmat
    m = loadmat(path)
    keys = [k for k in m if not k.startswith("__")]
    x = np.asarray(m[keys[0]], dtype=np.float64).ravel()
    return x


def make_datasets(clean, levels=SNR_LEVELS_DB, seed=NOISE_SEED):
    """clean + white Gaussian noise at each input SNR (measured signal power,
    same convention as MATLAB awgn(x, snr, 'measured'))."""
    rng = np.random.default_rng(seed)
    p_sig = np.mean(clean ** 2)
    out = [("clean", None, clean.copy())]
    for snr in levels:
        sigma = np.sqrt(p_sig / 10 ** (snr / 10))
        out.append((f"awgn_{snr:+d}dB", snr, clean + rng.normal(0.0, sigma, clean.shape)))
    return out


def quantize(x):
    """Peak-normalise to [-1, 1] then int8 (Q0.7). Returns (x_q, scale):
    x ~= x_q / scale.  Symmetric normalisation keeps 0 V at code 0."""
    peak = np.max(np.abs(x))
    scale = 127.0 / peak
    xq = np.clip(np.round(x * scale), -128, 127).astype(np.int64)
    return xq, scale


def fir_int(xq):
    """y[n] = sum_k h[k] x[n-k], full precision (20-bit in hardware)."""
    return np.convolve(xq, TAPS_Q)[: len(xq)]


def stream_for_hw(xq):
    """samples actually sent to the board: record + FLUSH zeros"""
    return np.concatenate([xq, np.zeros(FLUSH, dtype=np.int64)])


def expected_hw(stream):
    """expected word sequence from each DUT for a given input stream"""
    y = fir_int(stream)
    exp = []
    for off in OFFSET:
        e = np.concatenate([np.zeros(off, dtype=np.int64), y])[: len(stream)]
        exp.append(e)
    return exp


def hw_to_y(words, dut, n_rec):
    """hardware word stream -> y[0..n_rec-1] aligned with the input record"""
    off = OFFSET[dut]
    return np.asarray(words[off: off + n_rec], dtype=np.int64)


def to_physical(y_int, scale):
    """integer output -> input units (undo input scale and x128 coefficients)"""
    return y_int / (scale * COEF_SCALE)


def delayed_ref(clean):
    """clean signal delayed by the FIR group delay (3.5 samples):
    r[n] = (c[n-3] + c[n-4]) / 2. For this record (<= 4 cycles per 2000
    samples) the half-sample interpolation error is < -90 dB."""
    c = np.concatenate([np.zeros(4), clean])
    return 0.5 * (c[1:-3] + c[0:-4])


def snr_db(ref, est):
    err = np.sum((ref - est) ** 2)
    return float("inf") if err == 0 else 10 * np.log10(np.sum(ref ** 2) / err)


def metrics(clean, noisy, y_phys, y_float_noisy, skip=8):
    """Agarwal-style metrics against the clean reference + AutoFIR-style
    fidelity SNR against the floating-point FIR. First `skip` samples
    (filter warm-up) are excluded from every metric."""
    ref = delayed_ref(clean)
    s = slice(skip, len(clean))
    snr_in = snr_db(clean[s], noisy[s])
    snr_out = snr_db(ref[s], y_phys[s])
    mse = np.mean((ref[s] - y_phys[s]) ** 2)
    cor = np.corrcoef(ref[s], y_phys[s])[0, 1]
    fid = snr_db(y_float_noisy[s], y_phys[s])
    return dict(snr_in=snr_in, snr_out=snr_out, snri=snr_out - snr_in,
                mse=mse, cor=cor, fidelity_snr=fid)


def fir_float(x):
    return np.convolve(x, taps_float())[: len(x)]


def analytic_snri_db():
    """white-noise gain of the quantised FIR at DC: (sum h)^2 / sum h^2"""
    h = TAPS_Q.astype(float)
    return 10 * np.log10(h.sum() ** 2 / np.sum(h ** 2))
