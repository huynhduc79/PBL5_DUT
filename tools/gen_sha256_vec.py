"""gen_sha256_vec.py - sinh vector thu cho sha256_core (tb/tb_sha256_core.v).

Moi dong = MOT lan nen (mot khoi 512 bit), 770 bit, cot dau o bit cao nhat:
    [769] valid=1   [768] first   [767:256] blk (big-endian, W0 o bit cao)   [255:0] H sau khoi do
Thong diep duoc padding o day (0x80, 0..., do dai bit 64 bit); H trung gian lay tu ham nen viet bang Python
thuan; ham nen nay duoc doi chieu voi hashlib o gia tri cuoi cua moi thong diep (assert) nen khong the sai am tham.

Chay (tu thu muc goc du an):   python tools/gen_sha256_vec.py
"""
import hashlib
import random
from math import isqrt
from pathlib import Path


def _primes(n):
    p, c = [], 2
    while len(p) < n:
        if all(c % q for q in p):
            p.append(c)
        c += 1
    return p


def _icbrt(n):
    lo, hi = 0, 1 << ((n.bit_length() + 2) // 3 + 1)
    while lo < hi:
        m = (lo + hi + 1) // 2
        if m ** 3 <= n:
            lo = m
        else:
            hi = m - 1
    return lo


_P = _primes(64)
K = [_icbrt(p << 96) & 0xFFFFFFFF for p in _P]
IV = [isqrt(p << 64) & 0xFFFFFFFF for p in _P[:8]]
M = 0xFFFFFFFF


def rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & M


def compress(h, blk):
    w = [int.from_bytes(blk[4 * i:4 * i + 4], "big") for i in range(16)]
    for t in range(16, 64):
        s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
        s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
        w.append((w[t - 16] + s0 + w[t - 7] + s1) & M)
    a, b, c, d, e, f, g, hh = h
    for t in range(64):
        t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & M & g)) + K[t] + w[t]) & M
        t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & M
        hh, g, f, e, d, c, b, a = g, f, e, (d + t1) & M, c, b, a, (t1 + t2) & M
    return [(x + y) & M for x, y in zip(h, [a, b, c, d, e, f, g, hh])]


def pad(msg: bytes) -> bytes:
    n = len(msg)
    z = (55 - n) % 64
    return msg + b"\x80" + b"\x00" * z + (8 * n).to_bytes(8, "big")


def rows_for(msg: bytes):
    data = pad(msg)
    h, out = list(IV), []
    for i in range(0, len(data), 64):
        h = compress(h, data[i:i + 64])
        out.append((1 if i == 0 else 0, data[i:i + 64], list(h)))
    digest = b"".join(x.to_bytes(4, "big") for x in h)
    assert digest == hashlib.sha256(msg).digest(), f"ham nen Python lech hashlib (len={len(msg)})"
    return out


def main():
    rng = random.Random(20261029)
    msgs = [b"abc",                                                           # FIPS 180-4 vi du 1 (1 khoi)
            b"",                                                              # thong diep rong (1 khoi)
            b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"]      # FIPS 180-4 vi du 2 (448 bit -> 2 khoi)
    msgs += [bytes(n) for n in (1, 55, 56, 63, 64, 65, 119, 120, 128)]       # bien cua padding, toan 0
    msgs += [b"\xff" * n for n in (32, 55, 64, 100)]                          # toan 1: nhieu bit nho khi cong
    msgs += [b"a" * 1000]
    msgs += [rng.randbytes(rng.randrange(0, 300)) for _ in range(120)]
    msgs += [rng.randbytes(32 + 4) for _ in range(40)]                        # dang thong diep ngan nhu KDF ("session"||ctr)
    lines = []
    for m in msgs:
        for first, blk, h in rows_for(m):
            v = (1 << 769) | (first << 768) | (int.from_bytes(blk, "big") << 256)
            v |= int.from_bytes(b"".join(x.to_bytes(4, "big") for x in h), "big")
            lines.append(f"{v:0193x}")
    out = Path(__file__).resolve().parent.parent / "tb" / "vectors" / "sha256_blocks.hex"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    print(f"{len(msgs)} thong diep, {len(lines)} khoi -> {out}")


if __name__ == "__main__":
    main()
