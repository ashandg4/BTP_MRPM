"""
UART link check for the VC709 EEG harness: sends 'P' (ping) at both baud
rates and prints the raw reply bytes.

    python vc709/eeg/python/uart_probe.py COM8

Good reply (at the baud matching DIP SW0):
    b'HIL1' + 4-byte clock + b'\\x12\\x03'
    e.g. 150 MHz build -> b'HIL1\\x08\\xf0\\xd1\\x80\\x12\\x03'
         200 MHz build -> b'HIL1\\x0b\\xeb\\xc2\\x00\\x12\\x03'
"""
import sys, time, struct
import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM8"
for baud in (921600, 115200):
    s = serial.Serial(port, baud, timeout=1.0)
    time.sleep(0.3)
    s.reset_input_buffer()
    s.write(b"P")
    time.sleep(0.5)
    r = s.read(64)
    s.close()
    verdict = ""
    if r[:4] == b"HIL1" and len(r) >= 10:
        verdict = f"  <-- OK: board clock {struct.unpack('>I', r[4:8])[0] / 1e6:.3f} MHz, use --baud {baud}"
    print(f"{baud:7d} baud: {len(r):2d} bytes {r!r}{verdict}")
