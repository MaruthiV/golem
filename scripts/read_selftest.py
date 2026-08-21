"""Read one report line from the SDRAM self-test. Prints e.g. "P e0000 c066 p06"."""
import os
import sys
import time

import serial

BAUD = int(os.environ.get("GOLEM_BAUD", 921600))


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/tty.usbserial-1"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
    ser = serial.Serial(port, BAUD, timeout=0.3)
    ser.reset_input_buffer()
    buf, t0 = b"", time.time()
    while time.time() - t0 < secs:
        buf += ser.read(64)
        if b"\n" in buf:
            for line in buf.split(b"\n"):
                s = line.decode("ascii", "replace").strip()
                if s.startswith("P ") or s.startswith("F "):
                    print(s)
                    return 0 if s[0] == "P" else 1
    print("NO-REPORT")
    return 2


if __name__ == "__main__":
    sys.exit(main())
