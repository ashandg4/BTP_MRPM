"""
Byte-level protocol of vc709/eeg/rtl/eeg_hil_top.v.
Used by BOTH the live board script (hil_run.py) and the Icarus simulation
check (sim_check.py), so the simulation exercises the exact bytes the PC sends.
"""
import struct
import numpy as np

NDUT = 3


def cmd_ping():
    return b"P"


def cmd_load(xq):
    xq = np.asarray(xq, dtype=np.int64)
    n = len(xq)
    assert 0 < n < (1 << 24)
    return b"L" + n.to_bytes(3, "big") + bytes((xq & 0xFF).astype(np.uint8))


def load_checksum(xq):
    return int(np.sum(np.asarray(xq, dtype=np.int64) & 0xFF)) & 0xFFFFFFFF


def cmd_run(gap=0):
    return b"R" + bytes([gap & 0xFF])


def cmd_dump_y(dut):
    return b"Y" + bytes([dut])


def cmd_dump_x():
    return b"X"


# ---------------- reply parsers (take a bytes-like, return (obj, consumed)) ----
PING_LEN = 10
LOAD_LEN = 8
RUN_LEN = 44


def parse_ping(b):
    assert b[:4] == b"HIL1", f"bad ping reply {bytes(b[:10])!r}"
    clk_hz = struct.unpack(">I", b[4:8])[0]
    return dict(clk_hz=clk_hz, aw=b[8], ndut=b[9]), PING_LEN


def parse_load(b):
    assert b[0:1] == b"K", f"bad load reply {bytes(b[:8])!r}"
    n = int.from_bytes(b[1:4], "big")
    s = struct.unpack(">I", b[4:8])[0]
    return dict(n=n, sum=s), LOAD_LEN


def parse_run(b):
    assert b[0:1] == b"D", f"bad run reply {bytes(b[:4])!r}"
    flags = b[1]
    duts = []
    p = 2
    for _ in range(NDUT):
        cnt, lat, last, ysum = struct.unpack(">IHIi", b[p:p + 14])
        duts.append(dict(cnt=cnt, lat=lat, last=last, ysum=ysum))
        p += 14
    return dict(timeout=bool(flags & 1), duts=duts), RUN_LEN


def y_dump_len(cnt):
    return 1 + 3 * cnt


def parse_y(b, cnt):
    assert b[0:1] == b"Y", f"bad Y header {bytes(b[:1])!r}"
    raw = np.frombuffer(bytes(b[1:1 + 3 * cnt]), dtype=np.uint8).reshape(-1, 3).astype(np.int64)
    w = (raw[:, 0] << 16) | (raw[:, 1] << 8) | raw[:, 2]
    w = np.where(w & 0x800000, w - (1 << 24), w)
    return w, y_dump_len(cnt)


def ysum32(words):
    s = int(np.sum(np.asarray(words, dtype=np.int64))) & 0xFFFFFFFF
    return s - (1 << 32) if s & 0x80000000 else s
