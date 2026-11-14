#!/usr/bin/env python3
"""decode_chau.py - giai ma file ghi am .chau (hop dong docs/HOP_DONG_FPGA_RTOS.md v1.0) ra WAV 16 bit mono.

Chay tu thu muc goc repo:
    python tools/decode_chau.py rec_20261114_120000_00001000.chau --key key.hex
    python tools/decode_chau.py a.chau --key key.hex -o a.wav

key.hex: 64 ky tu hex = K_master 256 bit (byte dau = K[255:248]). KHONG commit file nay (.gitignore da chan).
Giai ma bang golden model refmodel (cung thuat toan voi phan cung, da kiem bit-exact tren board).
Xu ly: block hong CRC -> tim sync ke tiep; mat block (sau ma hoa) -> advance keystream + chen lang;
GAP (bo truoc ma hoa) -> chen drop_before mau lang, KHONG advance.
"""
import argparse
import os
import struct
import sys
import wave
from dataclasses import replace

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from refmodel.cipher import CipherCore        # noqa: E402
from refmodel.framing import crc16_ccitt      # noqa: E402
from refmodel.params import DEFAULT_PARAMS    # noqa: E402

P16 = replace(DEFAULT_PARAMS, N=16)


def decode_chau(path_or_bytes, k_master):
    data = path_or_bytes if isinstance(path_or_bytes, bytes) else open(path_or_bytes, "rb").read()
    assert data[:4] == b"CHAU", "khong phai file .chau"
    fs = struct.unpack(">I", data[12:16])[0] / 1000
    pos, samples, core, expect = 32, [], None, None
    while pos + 12 <= len(data):
        sync, ctr, idx0, cnt, flags, _, drop = struct.unpack(">HIBBBBH", data[pos:pos + 12])
        end = pos + 12 + 2 * cnt
        if sync != 0xA55A or cnt == 0 or cnt > 64 or end + 2 > len(data) \
           or crc16_ccitt(data[pos + 2:end]) != struct.unpack(">H", data[end:end + 2])[0]:
            pos += 1                      # tim sync ke tiep
            continue

        # (1) mat block sau ma hoa: keystream DA tieu thu -> phai chay khong tai cho bat lai pha
        if expect != (ctr, idx0):
            lost = 0
            if expect is not None:
                lost = (ctr - expect[0]) * P16.RESEED_INTERVAL + (idx0 - expect[1])
            if core is None or not (0 < lost <= 64 * 4096):
                core = CipherCore(k_master, P16, ctr0=ctr)    # file moi / nhay xa: dung lai tu dau phien
                core.advance(idx0)
            else:
                core.advance(lost)                            # mat block: giu nguyen mach keystream
                samples.extend([0] * lost)                    # lo thoi gian do mat block

        # (2) GAP: bo TRUOC khi ma hoa -> keystream LIEN MACH, chi chen lang, KHONG advance
        if flags & 1:
            samples.extend([0] * drop)

        for c in struct.unpack(f">{cnt}H", data[pos + 12:end]):
            p = core.decrypt(c)
            samples.append(p - 0x10000 if p & 0x8000 else p)
        expect = core.position
        pos = end + 2
    return fs, samples


def read_key(path):
    txt = open(path).read().split()
    k = bytes.fromhex("".join(txt))
    if len(k) != 32:
        raise SystemExit(f"{path}: can 32 byte (64 ky tu hex), doc duoc {len(k)} byte")
    return k


def main():
    ap = argparse.ArgumentParser(description="Giai ma .chau -> .wav")
    ap.add_argument("chau")
    ap.add_argument("--key", required=True, help="file hex chua K_master 256 bit")
    ap.add_argument("-o", "--out", help="file .wav (mac dinh: cung ten)")
    a = ap.parse_args()
    fs, samples = decode_chau(a.chau, read_key(a.key))
    out = a.out or os.path.splitext(a.chau)[0] + ".wav"
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(round(fs)))
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))
    print(f"{len(samples)} mau, fs = {fs:g} Hz, {len(samples) / fs:.2f} s -> {out}")


if __name__ == "__main__":
    main()
