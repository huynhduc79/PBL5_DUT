"""stats.py - thong ke cho cipher: so vong LTS moi mau, do deu, entropy, tuong quan, nhay khoa,
va hai bai kiem tra bit don gian (monobit, runs) theo NIST SP 800-22 (muc 2.1, 2.3).

Day la bo thong ke nhanh de phat hien loi som; danh gia ngau nhien day du bang bo NIST nam o muc 7.
"""

from __future__ import annotations

import dataclasses
import math
import random
from collections import Counter
from collections.abc import Callable, Iterable

from ..cipher import CipherCore
from ..lts import make_lts_step
from ..params import DEFAULT_PARAMS, X0_MIN, CipherParams


# ------------------------------------------------------------------ so vong LTS moi mau (4.3.5, 4.3.8)
def lts_steps_stats(key: bytes, p: CipherParams = DEFAULT_PARAMS, n_samples: int = 20000) -> dict:
    core = CipherCore(key, p)
    steps = Counter()
    rejects = 0
    for i in range(n_samples):
        core.encrypt(i & p.N_MASK)
        steps[core.last_lts_steps] += 1
        rejects += core.last_rejects
    total = sum(k * v for k, v in steps.items())
    return {
        "n": n_samples,
        "mean_lts_steps": total / n_samples,
        "max_lts_steps": max(steps),
        "hist": dict(sorted(steps.items())),
        "mean_rejects": rejects / n_samples,
    }


# ------------------------------------------------------------------ chat luong bit cua trang thai X theo r
def lts_bit_quality(p: CipherParams = DEFAULT_PARAMS, r_lo: float = 1.0, r_hi: float = 2.0,
                    n_sessions: int = 1500, steps: int = 200, seed: int = 0) -> dict:
    """Do phan bo 8 bit CAO va 8 bit THAP cua X tren nhieu phien ngan (r ngau nhien trong [r_lo, r_hi)).

    Phai dung nhieu phien ngan (< rho), khong dung mot quy dao dai: quy dao dai da lap chu ky
    nen chi-square bi thoi phong. chi2 (df = 255): nguong p = 0.001 la 330.
    """
    rnd = random.Random(seed)
    top, low, pairs = [], [], []
    top1 = total = 0
    for _ in range(n_sessions):
        r_int = int((r_lo + (r_hi - r_lo) * rnd.random()) * p.ONE)
        x0 = rnd.randrange(X0_MIN, p.ONE)
        step = make_lts_step(r_int, x0, p)
        x, prev = x0, None
        for _ in range(steps):
            x = step(x)
            top.append(x >> (p.W - 8))
            low.append(x & 255)
            top1 += x >> (p.W - 1)
            total += 1
            if prev is not None:
                pairs.append(((prev & 15) << 4) | (x & 15))
            prev = x
    return {
        "n": total,
        "chi2_top8": chi2_uniform(top, 256),
        "chi2_low8": chi2_uniform(low, 256),
        "chi2_pairs_low4": chi2_uniform(pairs, 256),
        "p_top_bit": top1 / total,
    }


# ------------------------------------------------------------------ thong ke gia tri
def chi2_uniform(values: Iterable[int], nbins: int) -> float:
    c = Counter(values)
    n = sum(c.values())
    e = n / nbins
    return sum((c.get(i, 0) - e) ** 2 / e for i in range(nbins))


def shannon_entropy_bits(values: Iterable[int]) -> float:
    c = Counter(values)
    n = sum(c.values())
    return -sum((v / n) * math.log2(v / n) for v in c.values())


def serial_correlation(values: list[int], lag: int = 1) -> float:
    n = len(values) - lag
    xs, ys = values[:n], values[lag:lag + n]
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
    sxx = sum((a - mx) ** 2 for a in xs)
    syy = sum((b - my) ** 2 for b in ys)
    return sxy / math.sqrt(sxx * syy)


# ------------------------------------------------------------------ bit va hai bai NIST don gian
def to_bits(values: Iterable[int], nbits: int) -> list[int]:
    out: list[int] = []
    for v in values:
        out.extend((v >> k) & 1 for k in range(nbits))
    return out


def monobit_pvalue(bits: list[int]) -> float:
    """NIST SP 800-22 muc 2.1: kiem tra tan suat bit."""
    n = len(bits)
    s = sum(1 if b else -1 for b in bits)
    return math.erfc(abs(s) / math.sqrt(n) / math.sqrt(2))


def runs_pvalue(bits: list[int]) -> float:
    """NIST SP 800-22 muc 2.3: kiem tra so chuoi (runs). Tra 0 neu tien quyet monobit khong dat."""
    n = len(bits)
    pi = sum(bits) / n
    if abs(pi - 0.5) >= 2 / math.sqrt(n):
        return 0.0
    v = 1 + sum(1 for k in range(n - 1) if bits[k] != bits[k + 1])
    return math.erfc(abs(v - 2 * n * pi * (1 - pi)) / (2 * math.sqrt(2 * n) * pi * (1 - pi)))


# ------------------------------------------------------------------ luong ban ma
def ciphertext_stream(key: bytes, p: CipherParams, n: int,
                      plain: Callable[[int], int] = lambda i: 0xA5) -> list[int]:
    core = CipherCore(key, p)
    return [core.encrypt(plain(i) & p.N_MASK).c for i in range(n)]


def key_sensitivity(key: bytes, p: CipherParams = DEFAULT_PARAMS, n_samples: int = 256,
                    flips: Iterable[int] | None = None) -> dict:
    """Dao 1 bit cua K_master, ma hoa cung ban ro; do ti le bit ban ma khac nhau (ky vong ~0.5)."""
    base = ciphertext_stream(key, p, n_samples)
    ratios = []
    for bit in (range(len(key) * 8) if flips is None else flips):
        k2 = bytearray(key)
        k2[bit // 8] ^= 1 << (bit % 8)
        other = ciphertext_stream(bytes(k2), p, n_samples)
        diff = sum(bin(a ^ b).count("1") for a, b in zip(base, other))
        ratios.append(diff / (n_samples * p.N))
    return {"n_flips": len(ratios), "mean": sum(ratios) / len(ratios), "min": min(ratios), "max": max(ratios)}


def write_bitstream(path: str, values: Iterable[int], nbits: int) -> int:
    """Ghi luong bit (moi mau nbits bit, bit 0 truoc) ra file nhi phan cho bo NIST STS; tra so byte."""
    bits = to_bits(values, nbits)
    bits += [0] * (-len(bits) % 8)
    data = bytes(sum(bits[i + k] << (7 - k) for k in range(8)) for i in range(0, len(bits), 8))
    with open(path, "wb") as f:
        f.write(data)
    return len(data)
