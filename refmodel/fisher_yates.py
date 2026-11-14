"""fisher_yates.py - bit pool, rut so khong thien vi, Fisher-Yates tu chaos, hoan vi bit
(muc 4.3.4 - 4.3.5, 4.3.6 - 4.3.7).

Quy uoc bit (D1, da sua: lay tu bit THAP):
  * Bit 0 la LSB cua mau. Hoan vi gather: P'[i] = P[pi[i]] (bit i cua dau ra lay tu bit pi[i]).
  * BitPool la FIFO: bit cu nhat ra truoc; moi trang thai X nap vao theo thu tu tu LSB len MSB,
    nen b bit dau tien lay ra chinh la x & (2**b - 1). Ly do: cac bit cao cua X lech manh
    (mat do bat bien cua LTS khong deu), cac bit thap thi deu (do bang thuc nghiem).
  * Pool bat dau rong moi lan goi fisher_yates_from_chaos; bit du cua lan refill truoc
    van dung tiep trong cung lan goi, het lan goi thi bo.
  * So bit can cho pham vi rng la b = ceil(log2(rng)) = (rng - 1).bit_length() (khong float).

Trace (neu truyen list): moi su kien la tuple (ten_trang_thai_FSM, du_lieu),
ten theo muc 5.3.4: FY_INIT, FY_REFILL, FY_DRAW, FY_SWAP.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import NamedTuple

from .params import CipherParams

Step = Callable[[int], int]   # step(X) -> X_next, thuong la make_lts_step(r_int, X0, p)


class BitPool:
    """FIFO bit, lay tu LSB cua tung tu duoc nap."""

    def __init__(self) -> None:
        self._bits = 0
        self._n = 0

    @property
    def size(self) -> int:
        return self._n

    def refill(self, x: int, w: int) -> None:
        """Nap w bit cua x vao cuoi hang doi; bit 0 cua x ra truoc."""
        if not (0 <= x < (1 << w)):
            raise ValueError("x khong vua w bit")
        self._bits |= x << self._n
        self._n += w

    def take(self, b: int) -> int:
        """Lay b bit cu nhat; bit lay ra dau tien la bit 0 cua ket qua."""
        if b < 0 or b > self._n:
            raise ValueError("khong du bit trong pool")
        val = self._bits & ((1 << b) - 1)
        self._bits >>= b
        self._n -= b
        return val


class FYResult(NamedTuple):
    pi: tuple[int, ...]   # hoan vi cua {0..N-1}
    x: int                # trang thai LTS sau khi chay xong
    refills: int          # so lan lap LTS de nap bit (xem 4.3.5, 4.3.8)
    rejects: int          # so lan loai bo (rejection)


def _emit(trace, name: str, *data) -> None:
    if trace is not None:
        trace.append((name, data))


def rand_range(pool: BitPool, x: int, step: Step, rng: int, p: CipherParams,
               trace=None) -> tuple[int, int, int, int]:
    """RandRange (4.3.5): so deu trong [0, rng-1] bang rejection sampling.

    Tra (gia_tri, x_moi, so_refill, so_reject). Khong gioi han so lan loai bo
    (D5, dung dac ta); chi co watchdog (RuntimeError) de bat nguon bit hong.
    """
    if rng < 2:
        raise ValueError("rng phai >= 2")
    b = (rng - 1).bit_length()
    refills = rejects = 0
    while True:
        while pool.size < b:
            x_old = x
            x = step(x)
            pool.refill(x, p.W)
            refills += 1
            _emit(trace, "FY_REFILL", x_old, x)
            if refills > p.FY_REFILL_WATCHDOG:      # chi de bat loi (D5), khong doi hanh vi
                raise RuntimeError(f"vuot watchdog {p.FY_REFILL_WATCHDOG} lan refill trong mot lan rut so")
        cand = pool.take(b)
        accepted = cand < rng
        _emit(trace, "FY_DRAW", rng, b, cand, accepted)
        if accepted:
            return cand, x, refills, rejects
        rejects += 1


def fisher_yates_from_chaos(x: int, step: Step, p: CipherParams, trace=None) -> FYResult:
    """FisherYatesFromChaos (4.3.5): hoan vi {0..N-1} theo Durstenfeld (4.11)."""
    n = p.N
    pi = list(range(n))
    pool = BitPool()
    refills = rejects = 0
    _emit(trace, "FY_INIT", n)
    for i in range(n - 1, 0, -1):
        j, x, r1, r2 = rand_range(pool, x, step, i + 1, p, trace)
        refills += r1
        rejects += r2
        if refills > p.FY_REFILL_WATCHDOG:
            raise RuntimeError(f"vuot watchdog {p.FY_REFILL_WATCHDOG} lan refill trong mot lan Fisher-Yates")
        pi[i], pi[j] = pi[j], pi[i]
        _emit(trace, "FY_SWAP", i, j)
    return FYResult(tuple(pi), x, refills, rejects)


def gather_bits(value: int, pi: tuple[int, ...]) -> int:
    """Ma hoa: out[i] = value[pi[i]]  (bit 0 = LSB)."""
    out = 0
    for i, src in enumerate(pi):
        out |= ((value >> src) & 1) << i
    return out


def scatter_bits(value: int, pi: tuple[int, ...]) -> int:
    """Giai ma (nghich dao cua gather_bits): out[pi[i]] = value[i]."""
    out = 0
    for i, dst in enumerate(pi):
        out |= ((value >> i) & 1) << dst
    return out