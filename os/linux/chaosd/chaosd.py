#!/usr/bin/env python3
"""chaosd - daemon phia Linux: nhan ban ma tu RTOS, ghi file .chau, cap "lease" ctr.

Linux KHONG co K_master va KHONG thay ban ro; daemon chi:
  1. Mo kenh toi RTOS (RPMsg tty tren board, hoac chay sim_rtos qua pipe khi thu tren PC).
  2. Cap lease ctr: luu limit xuong dia (fsync) TRUOC khi gui "START <ctr> <limit>" / "LEASE <limit>".
     Lan chay sau bat dau tu limit da luu -> khong bao gio lap (K_master, ctr) du mat dien.
  3. Tach luong byte thanh dong trang thai '#...' va block .chau (kiem CRC), ghi vao file
     trong spool/, het rotate_s giay thi dong file va chuyen sang outbox/ (atomic rename).
  4. Dich vu khac (chaos-upload, rclone) day outbox/ len Google Drive.

Vi du:
  board : chaosd.py --device /dev/ttyRPMSG0 --data-dir /var/lib/chaos
  PC    : chaosd.py --sim-cmd "build/sim_rtos.exe --key build/test.key --period-ms 20" --data-dir build/chaos
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import queue
import shlex
import signal
import struct
import subprocess
import sys
import threading
import time

LOG = logging.getLogger("chaosd")

SYNC = b"\xa5\x5a"
BLOCK_HDR = struct.Struct(">HIBBBB")          # sync, ctr, idx0, count, flags, reserved
FILE_HDR = struct.Struct(">4sB3BBBBBIQII")    # 32 byte, muc 8.1
MAX_SAMPLES = 64
CTR_MAX = 0xFFFFFFFF

SOURCE_CODES = {"mic": 0, "ramp": 1, "sine": 2, "dht22": 3}   # dht22 = 3: de xuat, chua chot o muc 8


def crc16_ccitt(data: bytes) -> int:
    """CRC-16/CCITT-FALSE, giong refmodel.framing.crc16_ccitt."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


# ---------------------------------------------------------------------------- tach luong
class StreamParser:
    """Tach luong byte RTOS -> Linux thanh ('line', str) va ('block', ctr, idx0, count, flags, raw)."""

    def __init__(self) -> None:
        self.buf = bytearray()
        self.crc_errors = 0
        self.skipped = 0

    def feed(self, data: bytes):
        self.buf += data
        out = []
        while self.buf:
            b0 = self.buf[0]
            if b0 == 0x23:                                    # '#': dong trang thai
                nl = self.buf.find(b"\n")
                if nl < 0:
                    if len(self.buf) > 512:                   # dong qua dai -> rac
                        del self.buf[0]
                        self.skipped += 1
                        continue
                    break
                out.append(("line", self.buf[:nl].decode("ascii", "replace")))
                del self.buf[:nl + 1]
            elif b0 == 0xA5:
                if len(self.buf) < BLOCK_HDR.size:
                    break
                sync, ctr, idx0, count, flags, _ = BLOCK_HDR.unpack_from(self.buf)
                if sync != 0xA55A or not 1 <= count <= MAX_SAMPLES:
                    del self.buf[0]
                    self.skipped += 1
                    continue
                total = BLOCK_HDR.size + 2 * count + 2
                if len(self.buf) < total:
                    break
                raw = bytes(self.buf[:total])
                if crc16_ccitt(raw[2:-2]) != struct.unpack(">H", raw[-2:])[0]:
                    self.crc_errors += 1
                    del self.buf[0]                           # do lai sync tu byte ke tiep
                    continue
                out.append(("block", ctr, idx0, count, flags, raw))
                del self.buf[:total]
            else:
                del self.buf[0]
                self.skipped += 1
        return out


# ---------------------------------------------------------------------------- lease ctr
class LeaseState:
    """Bat bien: moi ctr RTOS da/se dung < limit da gui <= next_ctr da luu tren dia."""

    def __init__(self, path: str, lease: int) -> None:
        self.path = path
        self.lease = lease
        self.next_ctr = 0
        self.limit = 0
        self.max_seen = -1
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                self.next_ctr = int(json.load(f)["next_ctr"])

    def _persist(self, value: int) -> None:
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"next_ctr": value, "updated": int(time.time())}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)
        self.next_ctr = value

    def start(self) -> tuple[int, int]:
        ctr0 = self.next_ctr
        if ctr0 >= CTR_MAX:
            raise SystemExit("ctr da het 2^32 voi khoa nay: phai doi K_master va xoa file state")
        limit = min(ctr0 + self.lease, CTR_MAX)
        self._persist(limit)                 # luu TRUOC khi gui
        self.limit = limit
        return ctr0, limit

    def on_block(self, ctr: int) -> None:
        if ctr >= self.limit:
            LOG.error("RTOS dung ctr=%d >= limit=%d (vi pham lease)", ctr, self.limit)
        self.max_seen = max(self.max_seen, ctr)

    def want_extend(self) -> int | None:
        if self.limit >= CTR_MAX or self.max_seen < self.limit - max(1, self.lease // 2):
            return None
        new_limit = min(self.max_seen + self.lease, CTR_MAX)
        if new_limit <= self.limit:
            return None
        self._persist(new_limit)
        self.limit = new_limit
        return new_limit


# ---------------------------------------------------------------------------- ghi file
class ChauWriter:
    def __init__(self, spool: str, outbox: str, rotate_s: float, header_args: dict) -> None:
        self.spool, self.outbox, self.rotate_s = spool, outbox, rotate_s
        self.h = header_args
        self.f = None
        self.path = None
        self.opened = 0.0
        self.blocks = 0
        os.makedirs(spool, exist_ok=True)
        os.makedirs(outbox, exist_ok=True)

    def write_block(self, ctr: int, raw: bytes) -> None:
        now = time.time()
        if self.f is not None and now - self.opened >= self.rotate_s:
            self.close()
        if self.f is None:
            self._open(ctr, now)
        self.f.write(raw)
        self.f.flush()
        self.blocks += 1

    def _open(self, first_ctr: int, now: float) -> None:
        name = time.strftime("rec_%Y%m%d_%H%M%S", time.localtime(now)) + f"_{first_ctr:08x}.chau"
        self.path = os.path.join(self.spool, name)
        self.f = open(self.path, "wb")
        self.f.write(FILE_HDR.pack(b"CHAU", 1, 1, 0, 0, 16, self.h["channels"], self.h["shift"],
                                   self.h["source"], self.h["fs_milli_hz"], int(now),
                                   self.h["key_id"], first_ctr))
        self.opened = now
        self.blocks = 0
        LOG.info("mo file %s", name)

    def close(self) -> None:
        if self.f is None:
            return
        self.f.flush()
        os.fsync(self.f.fileno())
        self.f.close()
        dst = os.path.join(self.outbox, os.path.basename(self.path))
        os.replace(self.path, dst)
        LOG.info("dong file %s (%d block) -> outbox", os.path.basename(dst), self.blocks)
        self.f = None


# ---------------------------------------------------------------------------- kenh toi RTOS
class Transport:
    """Luong doc nen day bytes vao hang doi; None nghia la kenh da dong."""

    def __init__(self) -> None:
        self.rx: queue.Queue = queue.Queue()

    def _reader(self, read_fn) -> None:
        try:
            while True:
                data = read_fn()
                if not data:
                    break
                self.rx.put(data)
        except OSError as e:
            LOG.error("loi doc kenh: %s", e)
        self.rx.put(None)

    def send_line(self, line: str) -> None:
        LOG.info("-> %s", line)
        self._write((line + "\n").encode("ascii"))


class TtyTransport(Transport):
    def __init__(self, path: str) -> None:
        super().__init__()
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        try:
            import tty
            tty.setraw(self.fd)          # khong echo, khong doi '\n'
        except Exception as e:  # noqa: BLE001 - rpmsg tty co the khong ho tro termios day du
            LOG.warning("khong dat duoc che do raw cho %s: %s", path, e)
        threading.Thread(target=self._reader, args=(lambda: os.read(self.fd, 4096),), daemon=True).start()

    def _write(self, data: bytes) -> None:
        os.write(self.fd, data)

    def close(self) -> None:
        os.close(self.fd)


class SimTransport(Transport):
    def __init__(self, cmd: str) -> None:
        super().__init__()
        args = cmd if os.name == "nt" else shlex.split(cmd)
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        fd = self.p.stdout.fileno()
        threading.Thread(target=self._reader, args=(lambda: os.read(fd, 4096),), daemon=True).start()

    def _write(self, data: bytes) -> None:
        try:
            self.p.stdin.write(data)
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def close(self) -> None:
        try:
            self.p.stdin.close()
        except OSError:
            pass
        self.p.wait(timeout=10)


# ---------------------------------------------------------------------------- main
def load_config(path: str | None) -> dict:
    """File cau hinh dang key = value (bo dong trong va dong '#')."""
    cfg: dict = {}
    if path:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip().replace("-", "_")] = v.strip()
    return cfg


def parse_args(argv=None):
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("--config")
    known, _ = pre.parse_known_args(argv)
    cfg = load_config(known.config)

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", help="file key = value (gia tri mac dinh cho cac tham so duoi)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--device", help="kenh RPMsg tty, vd /dev/ttyRPMSG0")
    g.add_argument("--sim-cmd", help="lenh chay sim_rtos (thu tren PC)")
    ap.add_argument("--data-dir", default="/var/lib/chaos", help="chua spool/, outbox/, ctr_state.json")
    ap.add_argument("--rotate-s", type=float, default=3600, help="do dai moi file (giay)")
    ap.add_argument("--lease", type=int, default=16, help="so phien cap moi lan lease")
    ap.add_argument("--key-id", type=int, default=1)
    ap.add_argument("--source", choices=sorted(SOURCE_CODES), default="dht22")
    ap.add_argument("--channels", type=int, default=2)
    ap.add_argument("--fs-milli-hz", type=int, default=500, help="DHT22: 1 lan doc / 2 s = 500 mHz")
    ap.add_argument("--status-every", type=float, default=60)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.set_defaults(**{k: v for k, v in cfg.items() if k != "config"})
    args = ap.parse_args(argv)
    for name in ("rotate_s", "status_every"):
        setattr(args, name, float(getattr(args, name)))
    for name in ("lease", "key_id", "channels", "fs_milli_hz"):
        setattr(args, name, int(getattr(args, name)))
    if not args.device and not args.sim_cmd:
        ap.error("can --device hoac --sim-cmd")
    return args


def run(args) -> int:
    spool = os.path.join(args.data_dir, "spool")
    outbox = os.path.join(args.data_dir, "outbox")
    os.makedirs(args.data_dir, exist_ok=True)
    lease = LeaseState(os.path.join(args.data_dir, "ctr_state.json"), args.lease)
    writer = ChauWriter(spool, outbox, args.rotate_s, {
        "channels": args.channels, "shift": 0, "source": SOURCE_CODES[args.source],
        "fs_milli_hz": args.fs_milli_hz, "key_id": args.key_id,
    })
    # File do lan chay truoc bo do (mat dien) van giai ma duoc: day sang outbox.
    for name in os.listdir(spool):
        if name.endswith(".chau"):
            os.replace(os.path.join(spool, name), os.path.join(outbox, name))
            LOG.warning("chuyen file con sot %s sang outbox", name)

    link = TtyTransport(args.device) if args.device else SimTransport(args.sim_cmd)
    parser = StreamParser()
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, lambda *_: stop.set())
        except (ValueError, OSError):
            pass

    link.send_line("STOP")                     # RTOS co the dang chay tu lan truoc
    ctr0, limit = lease.start()
    link.send_line(f"START {ctr0} {limit}")
    last_status = time.monotonic()
    blocks = 0

    while not stop.is_set():
        try:
            data = link.rx.get(timeout=0.5)
        except queue.Empty:
            data = b""
        if data is None:
            LOG.info("RTOS dong kenh")
            break
        for item in parser.feed(data):
            if item[0] == "line":
                line = item[1]
                LOG.info("<- %s", line)
                if line.startswith("#LEASE_WAIT"):
                    lease.max_seen = max(lease.max_seen, lease.limit - 1)
            else:
                _, ctr, idx0, count, flags, raw = item
                lease.on_block(ctr)
                writer.write_block(ctr, raw)
                blocks += 1
                LOG.debug("block ctr=%d idx0=%d n=%d flags=%#x", ctr, idx0, count, flags)
        new_limit = lease.want_extend()
        if new_limit is not None:
            link.send_line(f"LEASE {new_limit}")
        if time.monotonic() - last_status >= args.status_every:
            link.send_line("STATUS")
            last_status = time.monotonic()

    link.send_line("STOP")
    writer.close()
    link.close()
    LOG.info("ket thuc: %d block, %d loi CRC, %d byte rac", blocks, parser.crc_errors, parser.skipped)
    return 0


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
