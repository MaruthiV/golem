"""Read golem's story off the board's serial port.

golem streams each generated token id as 2 bytes (hi, lo). This maps them back to
text with the trained tokenizer and prints the story as it arrives.

    pip install pyserial
    python scripts/read_story.py /dev/tty.usbserial-XXXX
(find the port with: ls /dev/tty.usbserial* , or `ls /dev/tty.*` after plugging in)
"""
import sys
from pathlib import Path

import serial
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[1]
BAUD = 115200
EOT = 0


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/tty.usbserial-1"
    tok = Tokenizer.from_file(str(ROOT / "data" / "tokenizer.json"))
    ser = serial.Serial(port, BAUD, timeout=None)
    print(f"listening on {port} @ {BAUD} — golem is writing:\n")
    while True:
        hi = ser.read(1)
        lo = ser.read(1)
        if not hi or not lo:
            continue
        t = (hi[0] << 8) | lo[0]
        if t == EOT:
            print("\n\n[end of story]")
            break
        print(tok.decode([t]), end="", flush=True)


if __name__ == "__main__":
    main()
