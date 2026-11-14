"""lts.py - mot buoc lap Logistic-Tent System o so nguyen co dinh (muc 4.3.2).

Dich tung dong pseudocode LTS_Step (4.3.2) sang so nguyen Python, ep ve W bit
bang mat na (mod 1 = lay W bit thap nhat). Khong dung float.

Quy uoc (muc 6.3):
  * X la Q0.W: X_real = X / 2**W, X trong [0, 2**W - 1].
  * r_int la Q2.W: r_real = r_int / 2**W, 0 < r_int <= 4 * 2**W.
  * Moi phep nhan duoc dua ve Q0.W bang dich phai W bit (cat bot, truncation).
  * Bay (trap-guard, mo rong cua P3): X_next <= TRAP_MAX (= 1) -> X_next = X0 cua phien.
    X = 0 la diem bat dong (f(0) = 0). Voi r < 2 thi X = 1 cung la diem bat dong
    (f(1) = floor((4-r)/2) = 1) va X = 2**W - 1 roi thang vao 1; voi r > 2 thi f(1) = 0.
    Nen coi ca hai la bay. X0 phai >= X0_MIN = 2.

Ba cach dung:
  lts_core(X, r_int, p)        -> (X_next_raw, branch)   khong co guard; dung de doi chieu/oracle
  lts_step(X, r_int, X0, p)    -> X_next                 co guard, co kiem tra tham so (ban tham chieu)
  make_lts_step(r_int, X0, p)  -> ham step(X)            co guard, hang so tinh san; dung cho vong lap nong

Ba ham cho ket qua giong het nhau (test_lts.py kiem tra).
"""

from __future__ import annotations

from collections.abc import Callable
from typing import NamedTuple

from .params import TRAP_MAX, X0_MIN, CipherParams

BRANCH_LOW = 0   # X <  0.5  (nhanh Tent thu nhat cua cong thuc 3.1)
BRANCH_HIGH = 1  # X >= 0.5  (nhanh Tent thu hai)


class LTSOut(NamedTuple):
    """Ket qua mot buoc, day du thong tin cho trace (muc 4.4, 5.3.4)."""

    x_next: int      # sau zero-guard
    branch: int      # BRANCH_LOW / BRANCH_HIGH
    guarded: bool    # True neu bay-guard kich hoat


def _check_x(x: int, p: CipherParams) -> None:
    if not (0 <= x <= p.MASK):
        raise ValueError(f"X={x} nam ngoai [0, 2**{p.W}-1]")


def _check_r(r_int: int, p: CipherParams) -> None:
    if not (0 < r_int <= (4 << p.W)):
        raise ValueError(f"r_int={r_int} nam ngoai (0, 4*2**{p.W}]")


def _check_x0(x0: int, p: CipherParams) -> None:
    if not (X0_MIN <= x0 <= p.MASK):
        raise ValueError(f"X0={x0} phai trong [{X0_MIN}, 2**{p.W}-1] (X <= {TRAP_MAX} la bay)")


def lts_core(x: int, r_int: int, p: CipherParams) -> tuple[int, int]:
    """Cong thuc (3.1) o so nguyen, KHONG co zero-guard. Tra (X_next_raw, branch)."""
    _check_x(x, p)
    _check_r(r_int, p)
    w = p.W
    one_minus_x = p.ONE - x                       # (1 - Xn), Q0.W

    prod = (x * one_minus_x) >> w                 # Xn(1-Xn),   Q0.W
    term1 = (r_int * prod) >> w                   # r*Xn(1-Xn), Q0.W

    half_4r = ((4 << w) - r_int) >> 1             # (4-r)/2

    if x < p.HALF:                                # Xn < 0.5
        term2 = (half_4r * x) >> w
        branch = BRANCH_LOW
    else:                                         # Xn >= 0.5
        term2 = (half_4r * one_minus_x) >> w
        branch = BRANCH_HIGH

    return (term1 + term2) & p.MASK, branch       # mod 1


def lts_step_ex(x: int, r_int: int, x0: int, p: CipherParams) -> LTSOut:
    """Mot buoc co bay-guard, tra them nhanh re va co guard (cho trace)."""
    _check_x0(x0, p)
    nxt, branch = lts_core(x, r_int, p)
    if nxt <= TRAP_MAX:
        return LTSOut(x0, branch, True)
    return LTSOut(nxt, branch, False)


def lts_step(x: int, r_int: int, x0: int, p: CipherParams) -> int:
    """LTS_Step (4.3.2) day du: cong thuc (3.1) + bay-guard. Ban tham chieu, co kiem tra tham so."""
    return lts_step_ex(x, r_int, x0, p).x_next


def make_lts_step(r_int: int, x0: int, p: CipherParams) -> Callable[[int], int]:
    """Tra ham step(X) voi (r_int, X0) co dinh cua mot phien.

    Kiem tra tham so mot lan luc tao, khong kiem tra X moi lan goi, hang so
    (4<<W) - r_int tinh san. Dung cho Brent/thong ke (hang trieu buoc).
    Giu dung ngu nghia lts_step: cung cong thuc, cung bay-guard.
    """
    _check_r(r_int, p)
    _check_x0(x0, p)
    w = p.W
    one = p.ONE
    half = p.HALF
    mask = p.MASK
    half_4r = ((4 << w) - r_int) >> 1
    trap = TRAP_MAX

    def step(x: int) -> int:
        omx = one - x
        t1 = (r_int * ((x * omx) >> w)) >> w
        t2 = (half_4r * (x if x < half else omx)) >> w
        nxt = (t1 + t2) & mask
        return nxt if nxt > trap else x0

    return step
