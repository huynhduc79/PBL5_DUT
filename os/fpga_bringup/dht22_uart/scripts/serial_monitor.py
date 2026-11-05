#!/usr/bin/env python3
"""serial_monitor.py - doc dong chu tu board (115200 8N1) va tu tim dung cong COM.

  python scripts/serial_monitor.py            # tu do: thu moi cong cua FT4232H
  python scripts/serial_monitor.py COM7       # chi dinh cong
  python scripts/serial_monitor.py --list     # liet ke cong COM

FT4232H tren board tao 4 cong: kenh A la JTAG (FlashPro5, khong mo duoc),
B/C noi vao MSS (UART cua RISC-V), D noi vao fabric -> dong chu cua bai nay.
Che do tu do nghe moi cong vai giay, cong nao co dong bat dau bang "PBL5" hoac "#0" la dung.
"""

from __future__ import annotations

import argparse
import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("can pyserial: pip install pyserial")

BAUD = 115200


def candidates():
    ports = list(serial.tools.list_ports.comports())
    ftdi = [p for p in ports if (p.vid == 0x0403) or "FTDI" in (p.manufacturer or "")]
    return ftdi or ports


def looks_right(line: str) -> bool:
    return line.startswith("PBL5") or line.startswith("#0")


def probe(dev: str, seconds: float) -> bool:
    try:
        with serial.Serial(dev, BAUD, timeout=0.5) as s:
            end = time.time() + seconds
            buf = b""
            while time.time() < end:
                buf += s.read(256)
                for raw in buf.split(b"\n")[:-1]:
                    if looks_right(raw.decode("ascii", "replace").strip()):
                        return True
    except serial.SerialException:
        pass
    return False


def monitor(dev: str) -> None:
    print(f"== {dev} @ {BAUD} 8N1 (Ctrl+C de thoat) ==")
    with serial.Serial(dev, BAUD, timeout=1) as s:
        while True:
            raw = s.readline()
            if raw:
                print(time.strftime("%H:%M:%S"), raw.decode("ascii", "replace").rstrip())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", nargs="?")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--probe-s", type=float, default=5.0, help="so giay nghe moi cong khi tu do")
    args = ap.parse_args()

    if args.list:
        for p in serial.tools.list_ports.comports():
            print(f"{p.device:8} {p.description}  vid={p.vid} pid={p.pid} sn={p.serial_number}")
        return 0
    try:
        if args.port:
            monitor(args.port)
            return 0
        ports = candidates()
        if not ports:
            sys.exit("khong thay cong COM nao: cam cap USB-C vao J4, cai driver FT4232H")
        for p in ports:
            print(f"thu {p.device} ({p.description}) ...", flush=True)
            if probe(p.device, args.probe_s):
                monitor(p.device)
                return 0
        sys.exit("khong cong nao in ra dong 'PBL5...'/'#0...'. Xem README muc 'Khong thay gi tren serial'.")
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
