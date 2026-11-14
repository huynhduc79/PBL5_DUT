"""oracle.py - cai dat doc lap thu hai cua toan bo thuat toan, dung trong test.

Co y KHAC golden o cach tinh:
  * HMAC viet lai tu FIPS 198-1 (ipad/opad) tren hashlib.sha256, khong dung module hmac.
  * LTS tinh bang Fraction + floor + %, khong dung >> va mat na.
  * Fisher-Yates dung chuoi bit dang '0'/'1' (str); bit dau chuoi = bit 0 cua X (LSB truoc).
  * Phep chia // thay cho >>.
Chi dung cho W = 32. Dai r = [1.0, 2.0); bay: X_next <= 1 -> X0; X0 >= 2.
"""

import hashlib
from fractions import Fraction
from math import floor

W = 32
ONE = 2 ** W
R_MIN = (1 * ONE) // 1            # r_min  = 1.0
R_SPAN = (1 * ONE) // 1           # r_span = 1.0  -> r thuoc [1.0, 2.0)


def hmac_fips198(key: bytes, msg: bytes) -> bytes:
    block = 64
    if len(key) > block:
        key = hashlib.sha256(key).digest()
    key = key + b"\x00" * (block - len(key))
    ipad = bytes(b ^ 0x36 for b in key)
    opad = bytes(b ^ 0x5C for b in key)
    return hashlib.sha256(opad + hashlib.sha256(ipad + msg).digest()).digest()


def oracle_params(k_master: bytes, ctr: int):
    ks = hmac_fips198(k_master, b"session" + ctr.to_bytes(4, "big"))
    w = [int.from_bytes(ks[4 * i:4 * i + 4], "big") for i in range(8)]
    x0 = w[0] ^ w[1] ^ w[2] ^ w[3]
    if x0 < 2:
        x0 = 2
    x = w[4] ^ w[5] ^ w[6] ^ w[7]
    return ks, x0, R_MIN + (R_SPAN * x) // 2 ** 32


def oracle_lts(x: int, r: int, x0: int) -> int:
    omx = ONE - x
    prod = floor(Fraction(x * omx, ONE))
    t1 = floor(Fraction(r * prod, ONE))
    half = floor(Fraction(4 * ONE - r, 2))
    base = x if Fraction(x, ONE) < Fraction(1, 2) else omx
    t2 = floor(Fraction(half * base, ONE))
    nxt = (t1 + t2) % ONE
    return nxt if nxt > 1 else x0


class OracleCipher:
    def __init__(self, k_master: bytes, n: int = 8, reseed: int = 64, ctr0: int = 0):
        self.k, self.n, self.reseed = k_master, n, reseed
        self.ctr, self.cnt = ctr0, 0
        self._start()

    def _start(self):
        self.ks, self.x0, self.r = oracle_params(self.k, self.ctr)
        self.x = self.x0

    def _next(self) -> int:
        self.x = oracle_lts(self.x, self.r, self.x0)
        return self.x

    def _perm(self):
        n = self.n
        perm = list(range(n))
        bits = ""
        self.refills = 0
        for i in range(n - 1, 0, -1):
            rng = i + 1
            b = len(bin(rng - 1)) - 2          # ceil(log2(rng))
            while True:
                if len(bits) < b:
                    bits += format(self._next(), "032b")[::-1]   # bit 0 truoc
                    self.refills += 1
                cand = int(bits[:b][::-1], 2)                    # bit dau tien = LSB cua cand
                bits = bits[b:]
                if cand < rng:
                    break
            perm[i], perm[cand] = perm[cand], perm[i]
        return perm

    def _ks_perm(self):
        k = self._next() % 2 ** self.n
        return k, self._perm()

    def _advance_session(self):
        self.cnt += 1
        if self.cnt >= self.reseed:
            self.ctr = (self.ctr + 1) % 2 ** 32
            self.cnt = 0
            self._start()

    def encrypt(self, plain: int):
        ctr, idx = self.ctr, self.cnt
        k, perm = self._ks_perm()
        shuffled = sum(((plain >> perm[i]) & 1) << i for i in range(self.n))
        self._advance_session()
        return shuffled ^ k, ctr, idx

    def decrypt(self, cipher: int) -> int:
        k, perm = self._ks_perm()
        shuffled = cipher ^ k
        plain = 0
        for i in range(self.n):
            plain |= ((shuffled >> i) & 1) << perm[i]
        self._advance_session()
        return plain
