"""Stream golem's quantized weight image to the board, then read the story back.

The board boots into a LOAD phase: its weight_loader receives the packed image
(4 bytes per word, little-endian, matching quant/pack.py) over UART and writes it
into SDRAM. After all 1,624,264 words arrive it flips to RUN, generates a story,
and streams each token id back as 2 bytes (hi, lo) — which this script decodes.

    pip install pyserial tokenizers
    python scripts/upload_weights.py /dev/tty.usbserial-XXXX

SDRAM is volatile, so the image is re-uploaded every power cycle. At 921600 baud
the ~6.5 MB image takes ~9-10 min to send (the UART is the bottleneck).
"""
import struct
import os
import sys
import time
from pathlib import Path

import serial
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[1]
BAUD = int(os.environ.get("GOLEM_BAUD", 921600))
EOT = 0
CHUNK = 8192


def load_image():
    words = (ROOT / "data" / "golem_mem.hex").read_text().split()
    blob = struct.pack(f"<{len(words)}I", *[int(w, 16) for w in words])
    return blob, len(words)


def upload(ser, blob):
    total = len(blob)
    t0 = time.time()
    for i in range(0, total, CHUNK):
        ser.write(blob[i:i + CHUNK])
        ser.flush()                      # block until on the wire, so progress is honest
        sent = min(i + CHUNK, total)
        el = time.time() - t0
        rate = sent / el if el > 0 else 0
        eta = (total - sent) / rate if rate > 0 else 0
        print(f"\r  {sent/1e6:5.2f}/{total/1e6:.2f} MB  {100*sent/total:5.1f}%  "
              f"{rate/1e3:4.1f} KB/s  eta {eta:4.0f}s", end="", flush=True)
    print(f"\n  done in {time.time()-t0:.0f}s")


def read_story(ser):
    tok = Tokenizer.from_file(str(ROOT / "data" / "tokenizer.json"))
    print("\ngolem is writing:\n")
    while True:
        hi = ser.read(1)
        lo = ser.read(1)
        if not hi or not lo:
            continue
        t = (hi[0] << 8) | lo[0]
        if t == EOT:
            print("\n\n[end of story]")
            return
        print(tok.decode([t]), end="", flush=True)


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/tty.usbserial-1"
    blob, nwords = load_image()
    ser = serial.Serial(port, BAUD, timeout=None)
    ser.reset_input_buffer()
    # the SDRAM needs ~200us of power-up before the loader can take a word, and the board holds
    # its UART receiver in reset until then. Bytes sent inside that window are simply not there.
    time.sleep(0.05)
    print(f"uploading {nwords} words ({len(blob)/1e6:.2f} MB) to {port} @ {BAUD}")
    upload(ser, blob)
    read_story(ser)


if __name__ == "__main__":
    main()
