#!/usr/bin/env python3
"""verify_chau.py - cong cu kiem tra phia OS: doc .chau, giai ma bang refmodel, kiem tinh lien mach.

Khong thay the tools/decode_chau.py cua thanh vien ma hoa (giai ma + phan tich pho...);
file nay chi de phia OS tu kiem driver/RTOS/chaosd truoc khi giao.

  python tools/verify_chau.py "build/e2e/data/outbox/*.chau" --key build/e2e/test.key \
         --refmodel D:/PBL5/chaos_refmodel_v1.0.0/chaos_project [--wav out.wav]

Kiem tra:
  - header CHAU, CRC tung block, (ctr, idx) lien tiep giua cac block
  - nguon RAMP: ban ro phai la 0, 1, 2, ... ; sau block GAP_BEFORE nhay dung 1 + drop_before
"""

from __future__ import annotations

import argparse
import glob
import struct
import sys
import wave
from dataclasses import dataclass, field

FILE_HDR = struct.Struct(">4sB3BBBBBIQII")
BLOCK_HDR = struct.Struct(">HIBBBB")
FLAG_GAP, FLAG_TEST = 0x01, 0x02


@dataclass
class Report:
    files: int = 0
    blocks: int = 0
    samples: int = 0
    crc_errors: int = 0
    gaps: int = 0
    dropped: int = 0
    ramp_errors: int = 0
    seq_breaks: int = 0
    ctrs: list = field(default_factory=list)
    pcm: list = field(default_factory=list)


def load_key(path: str) -> bytes:
    return bytes.fromhex(open(path, encoding="ascii").read().strip()[:64])


def verify(paths: list[str], key: bytes, rep: Report, CipherCore, P16, crc16) -> None:
    core, expect, prev_plain = None, None, None
    for path in paths:
        data = open(path, "rb").read()
        magic, fmt, s0, s1, s2, n, ch, shift, src, fs_mhz, t0, key_id, first_ctr = FILE_HDR.unpack_from(data)
        if magic != b"CHAU" or n != 16:
            raise SystemExit(f"{path}: header sai")
        rep.files += 1
        pos = FILE_HDR.size
        while pos + BLOCK_HDR.size <= len(data):
            sync, ctr, idx0, cnt, flags, drop = BLOCK_HDR.unpack_from(data, pos)
            end = pos + BLOCK_HDR.size + 2 * cnt
            if sync != 0xA55A or end + 2 > len(data) or \
               crc16(data[pos + 2:end]) != struct.unpack_from(">H", data, end)[0]:
                rep.crc_errors += 1
                pos += 1
                continue
            if expect != (ctr, idx0):
                if expect is not None:
                    rep.seq_breaks += 1          # khong duoc xay ra trong mot lan ghi
                core = CipherCore(key, P16, ctr0=ctr)
                core.advance(idx0)
                prev_plain = None
            if flags & FLAG_GAP:
                rep.gaps += 1
                rep.dropped += drop
            for i, c in enumerate(struct.unpack_from(f">{cnt}H", data, pos + BLOCK_HDR.size)):
                p = core.decrypt(c)
                if src == 1:                     # RAMP
                    if prev_plain is not None:
                        step = 1 + (drop if (i == 0 and flags & FLAG_GAP) else 0)
                        ok = p == (prev_plain + step) & 0xFFFF
                        if not ok and drop == 255 and i == 0 and flags & FLAG_GAP:
                            ok = ((p - prev_plain) & 0xFFFF) > 255     # drop_before bao hoa
                        rep.ramp_errors += not ok
                    elif p != 0 and rep.samples == 0:
                        rep.ramp_errors += 1
                prev_plain = p
                rep.pcm.append(p - 0x10000 if p & 0x8000 else p)
            rep.blocks += 1
            rep.samples += cnt
            rep.ctrs.append(ctr)
            expect = core.position
            pos = end + 2
        rep.fs = fs_mhz / 1000


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pattern", help="file hoac glob, vd 'outbox/*.chau' (sap theo ten = theo thoi gian)")
    ap.add_argument("--key", required=True)
    ap.add_argument("--refmodel", required=True, help="thu muc chua package refmodel/")
    ap.add_argument("--wav", help="ghi ban giai ma ra WAV int16")
    a = ap.parse_args()

    sys.path.insert(0, a.refmodel)
    from dataclasses import replace
    from refmodel.cipher import CipherCore
    from refmodel.framing import crc16_ccitt
    from refmodel.params import DEFAULT_PARAMS

    paths = sorted(glob.glob(a.pattern))
    if not paths:
        raise SystemExit("khong co file")
    rep = Report()
    verify(paths, load_key(a.key), rep, CipherCore, replace(DEFAULT_PARAMS, N=16), crc16_ccitt)
    if a.wav:
        with wave.open(a.wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(round(rep.fs))
            w.writeframes(struct.pack(f"<{len(rep.pcm)}h", *rep.pcm))
    print(f"{rep.files} file, {rep.blocks} block, {rep.samples} mau, ctr {min(rep.ctrs)}..{max(rep.ctrs)}, "
          f"GAP {rep.gaps} (bo {rep.dropped} mau), loi CRC {rep.crc_errors}, dut (ctr,idx) {rep.seq_breaks}, "
          f"loi RAMP {rep.ramp_errors}")
    return 0 if rep.crc_errors == rep.seq_breaks == rep.ramp_errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
