"""framing.py - CRC-16-CCITT va dong/mo khung du lieu (muc 5.4.2, 5.4.3, cong thuc 5.1, 5.2).

Khung UART (5.1, da them idx - P5):

    SYNC(1) | ctr(4) | idx(2) | N(1) | C(N/8) | CRC16(2)
     0xAA      big-endian        8|16   big-endian   big-endian

  * CRC tinh tren ctr || idx || N || C (khong gom SYNC).
  * N = 8  -> 11 byte;  N = 16 -> 12 byte.
  * Payload Ethernet (5.4.3) = ctr || idx || N || C, khong SYNC, khong CRC phan mem
    (da co FCS cua Ethernet).

CRC-16/CCITT-FALSE: da thuc 0x1021 (x^16 + x^12 + x^5 + 1), gia tri dau 0xFFFF,
khong dao bit, khong XOR cuoi. Check value cua b"123456789" la 0x29B1.
(Tai lieu chi ghi "CRC-16-CCITT"; cac bien the init/reflect khac nhau cho ket qua khac nhau,
nen o day chot ro bien the nay.) CRC duoc tinh tung bit, giong mach LFSR trong RTL.

FrameDecoder tach khung tu luong byte UART: tim SYNC, doc N de biet do dai, kiem tra CRC;
sai thi bo dung 1 byte (SYNC gia) roi tim tiep.
"""

from __future__ import annotations

from typing import NamedTuple

SYNC = 0xAA
CTR_BYTES = 4
IDX_BYTES = 2
HEADER_LEN = CTR_BYTES + IDX_BYTES + 1          # ctr, idx, N
CRC_BYTES = 2
VALID_N = (8, 16)

CRC_POLY = 0x1021
CRC_INIT = 0xFFFF


class FrameError(ValueError):
    """Khung sai. reason: 'sync' | 'length' | 'n' | 'crc'."""

    def __init__(self, reason: str, msg: str):
        super().__init__(f"{reason}: {msg}")
        self.reason = reason


class Frame(NamedTuple):
    ctr: int
    idx: int
    n: int
    c: int


# ------------------------------------------------------------------ CRC-16-CCITT
def crc16_update(crc: int, byte: int) -> int:
    """Cap nhat CRC voi mot byte (MSB truoc), tuong ung 8 chu ky LFSR."""
    crc ^= byte << 8
    for _ in range(8):
        if crc & 0x8000:
            crc = ((crc << 1) ^ CRC_POLY) & 0xFFFF
        else:
            crc = (crc << 1) & 0xFFFF
    return crc


def crc16_ccitt(data: bytes, init: int = CRC_INIT) -> int:
    crc = init
    for b in data:
        crc = crc16_update(crc, b)
    return crc


# ------------------------------------------------------------------ dong / mo payload va khung
def frame_length(n: int) -> int:
    if n not in VALID_N:
        raise ValueError("N phai la 8 hoac 16")
    return 1 + HEADER_LEN + n // 8 + CRC_BYTES


def _check_int(v, name: str, lo: int, hi: int) -> None:
    if not isinstance(v, int) or isinstance(v, bool) or not (lo <= v <= hi):
        raise ValueError(f"{name} phai la so nguyen trong [{lo}, {hi}]")


def pack_payload(ctr: int, idx: int, n: int, c: int) -> bytes:
    """ctr || idx || N || C  (payload Ethernet, 5.4.3)."""
    if n not in VALID_N:
        raise ValueError("N phai la 8 hoac 16")
    _check_int(ctr, "ctr", 0, (1 << (8 * CTR_BYTES)) - 1)
    _check_int(idx, "idx", 0, (1 << (8 * IDX_BYTES)) - 1)
    _check_int(c, "c", 0, (1 << n) - 1)
    return (ctr.to_bytes(CTR_BYTES, "big") + idx.to_bytes(IDX_BYTES, "big")
            + bytes([n]) + c.to_bytes(n // 8, "big"))


def parse_payload(payload: bytes) -> Frame:
    if len(payload) < HEADER_LEN + 1:
        raise FrameError("length", "payload qua ngan")
    n = payload[HEADER_LEN - 1]
    if n not in VALID_N:
        raise FrameError("n", f"N={n} khong hop le")
    if len(payload) != HEADER_LEN + n // 8:
        raise FrameError("length", "do dai payload khong khop N")
    ctr = int.from_bytes(payload[0:CTR_BYTES], "big")
    idx = int.from_bytes(payload[CTR_BYTES:CTR_BYTES + IDX_BYTES], "big")
    c = int.from_bytes(payload[HEADER_LEN:], "big")
    return Frame(ctr, idx, n, c)


def pack_frame(ctr: int, idx: int, n: int, c: int) -> bytes:
    """Khung UART day du (5.1)."""
    payload = pack_payload(ctr, idx, n, c)
    return bytes([SYNC]) + payload + crc16_ccitt(payload).to_bytes(CRC_BYTES, "big")


def parse_frame(data: bytes) -> Frame:
    """Mo mot khung dung do dai; nem FrameError neu sai SYNC, do dai, N hoac CRC."""
    if len(data) < 1 + HEADER_LEN + CRC_BYTES + 1:
        raise FrameError("length", "khung qua ngan")
    if data[0] != SYNC:
        raise FrameError("sync", f"byte dau {data[0]:#04x} khac {SYNC:#04x}")
    n = data[HEADER_LEN]                         # offset cua N trong khung = 1 + (HEADER_LEN - 1)
    if n not in VALID_N:
        raise FrameError("n", f"N={n} khong hop le")
    if len(data) != frame_length(n):
        raise FrameError("length", f"can {frame_length(n)} byte, nhan {len(data)}")
    payload = bytes(data[1:-CRC_BYTES])
    if crc16_ccitt(payload) != int.from_bytes(data[-CRC_BYTES:], "big"):
        raise FrameError("crc", "CRC khong khop")
    return parse_payload(payload)


# ------------------------------------------------------------------ tach khung tu luong byte
class FrameDecoder:
    """Tach khung tu luong byte UART (cho phep chunk tuy y, nhieu rac, khung hong).

    Khung hong chi lam mat chinh no: sai CRC thi bo dung 1 byte SYNC roi tim SYNC tiep theo.
    Xac suat chap nhan nham mot ung vien sai la khoang 2**-16. Neu byte N bi hong thanh 8/16
    sai, bo giai ma co the cho them vai byte; khung hop le ke tiep van duoc tim lai.
    Dem: frames_ok, crc_errors, bad_n, dropped_bytes.
    """

    def __init__(self) -> None:
        self._buf = bytearray()
        self.frames_ok = 0
        self.crc_errors = 0
        self.bad_n = 0
        self.dropped_bytes = 0

    def feed(self, data: bytes) -> list[Frame]:
        buf = self._buf
        buf += data
        out: list[Frame] = []
        i = 0
        while True:
            j = buf.find(SYNC, i)
            if j < 0:                                   # khong con SYNC: bo het
                self.dropped_bytes += len(buf) - i
                i = len(buf)
                break
            self.dropped_bytes += j - i
            i = j
            if len(buf) - i < 1 + HEADER_LEN:           # chua doc duoc N, cho them
                break
            n = buf[i + HEADER_LEN]
            if n not in VALID_N:
                self.bad_n += 1
                self.dropped_bytes += 1
                i += 1
                continue
            flen = frame_length(n)
            if len(buf) - i < flen:                     # chua du khung, cho them
                break
            try:
                frame = parse_frame(bytes(buf[i:i + flen]))
            except FrameError:
                self.crc_errors += 1
                self.dropped_bytes += 1
                i += 1
                continue
            out.append(frame)
            self.frames_ok += 1
            i += flen
        del buf[:i]
        return out