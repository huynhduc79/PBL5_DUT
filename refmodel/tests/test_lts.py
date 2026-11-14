"""Test cho lts.py.

Ba lop kiem chung:
  1. Oracle doc lap: viet lai cung cac phep cat bot bang Fraction + floor (khong dung
     >> hay mat na), de bat loi dich bit/mat na.
  2. Doi chieu voi cong thuc thuc (3.1) tinh chinh xac bang Fraction: sai lech vong
     (circular) so voi floor(f(x) * 2^W) phai <= 7 LSB (xem _MAX_LSB).
  3. Cac bien va zero-guard, tinh nhat quan giua lts_core / lts_step / make_lts_step.
"""

import dataclasses
import random
from fractions import Fraction
from math import floor

import pytest

from refmodel.lts import (
    BRANCH_HIGH,
    BRANCH_LOW,
    lts_core,
    lts_step,
    lts_step_ex,
    make_lts_step,
)
from refmodel.params import DEFAULT_PARAMS

P = DEFAULT_PARAMS

# Gioi han sai so cat bot moi buoc (LSB cua Q0.W):
#   prod cat < 1 LSB, nhan voi r < 4 -> < 4; cong cat term1 < 1  => term1 sai < 5
#   half_4r cat <= 0.5, nhan voi X < 1 -> < 0.5; cong cat term2 < 1 => term2 sai < 1.5
#   tong < 6.5  ->  lam tron len 7.
_MAX_LSB = 7

R_MID = P.R_MIN_INT + P.R_SPAN_INT // 2   # r = 1.5


# ---------------------------------------------------------------- oracle
def oracle_core(x: int, r: int, p) -> int:
    """Cung cac diem cat bot voi lts_core nhung bang Fraction/floor/%, khong >>, khong mat na."""
    one = p.ONE
    omx = one - x
    prod = floor(Fraction(x * omx, one))
    term1 = floor(Fraction(r * prod, one))
    half = floor(Fraction(4 * one - r, 2))
    base = x if Fraction(x, one) < Fraction(1, 2) else omx
    term2 = floor(Fraction(half * base, one))
    return (term1 + term2) % one


def exact_scaled(x: int, r: int, p) -> int:
    """floor(2^W * f(x)) voi f la cong thuc (3.1) tinh chinh xac (khong cat bot)."""
    one = p.ONE
    xr = Fraction(x, one)
    rr = Fraction(r, one)
    tent = xr if xr < Fraction(1, 2) else 1 - xr
    f = (rr * xr * (1 - xr) + (4 - rr) / 2 * tent) % 1
    return floor(f * one)


def circ_dist(a: int, b: int, one: int) -> int:
    d = (a - b) % one
    return min(d, one - d)


def _samples(p, n, seed):
    rng = random.Random(seed)
    edges = [0, 1, 2, 3, p.HALF - 2, p.HALF - 1, p.HALF, p.HALF + 1, p.MASK - 2, p.MASK - 1, p.MASK]
    return edges + [rng.randrange(p.ONE) for _ in range(n)]


def _r_values(p):
    # bien duoi, bien tren, giua, du 4 so du mod 4, va r = 4 (bien tren cua r_int hop le)
    base = p.R_MIN_INT + p.R_SPAN_INT // 2
    base -= base % 4
    return [p.R_MIN_INT, p.R_MAX_INT, base, base + 1, base + 2, base + 3, 4 << p.W]


# ---------------------------------------------------------------- 1. oracle
@pytest.mark.parametrize("p", [P, dataclasses.replace(P, W=24), dataclasses.replace(P, W=16)])
def test_core_matches_fraction_oracle(p):
    for r in _r_values(p):
        for x in _samples(p, 400, seed=r):
            assert lts_core(x, r, p)[0] == oracle_core(x, r, p), (x, r)


# ---------------------------------------------------------------- 2. cong thuc thuc
@pytest.mark.parametrize("p", [P, dataclasses.replace(P, W=24)])
def test_core_close_to_exact_real_formula(p):
    for r in _r_values(p):
        for x in _samples(p, 400, seed=r + 7):
            got = lts_core(x, r, p)[0]
            want = exact_scaled(x, r, p)
            assert circ_dist(got, want, p.ONE) <= _MAX_LSB, (x, r, got, want)


# ---------------------------------------------------------------- 3a. chuoi pinned (tu oracle)
def test_pinned_sequence_from_oracle():
    # X0 = 0x12345678, r = 1.5 (R_MIN_INT + R_SPAN_INT//2). Gia tri sinh bang oracle_core
    # (doc lap), dong bang de bao ve khoi thay doi ngam.
    expected = [0x301ED37E, 0x76C36911, 0xF3F449E7, 0x20468E5A, 0x52A774E9, 0xBB44F2D8, 0xA15488AF, 0xCFD3FA69]
    assert R_MID == 6_442_450_944
    x0 = 0x12345678
    x = x0
    step = make_lts_step(R_MID, x0, P)
    for want in expected:
        assert oracle_core(x, R_MID, P) == want
        x = lts_step(x, R_MID, x0, P)
        assert x == want
    x = x0
    for want in expected:
        x = step(x)
        assert x == want


# ---------------------------------------------------------------- 3b. bien & nhanh re
def test_branch_split_at_half():
    assert lts_core(P.HALF - 1, R_MID, P)[1] == BRANCH_LOW
    assert lts_core(P.HALF, R_MID, P)[1] == BRANCH_HIGH
    assert lts_core(0, R_MID, P)[1] == BRANCH_LOW
    assert lts_core(P.MASK, R_MID, P)[1] == BRANCH_HIGH


def test_trap_states_of_core():
    # X = 0 luon ve 0. X = 1 va X = 2^W-1 phu thuoc r: neu r <= 2 (half = (4-r)/2 >= 1) thi ve 1,
    # neu r > 2 thi ve 0. Ca hai deu la bay (<= TRAP_MAX) nen guard xu ly.
    two = 2 << P.W
    for r in _r_values(P):
        assert lts_core(0, r, P)[0] == 0
        want = 1 if r <= two else 0
        assert lts_core(1, r, P)[0] == want, r
        assert lts_core(P.MASK, r, P)[0] == want, r
    assert lts_core(1, two, P)[0] == 1 and lts_core(1, two + 1, P)[0] == 0


def test_x_equal_1_is_fixed_point_in_default_range():
    for r in (P.R_MIN_INT, R_MID, P.R_MAX_INT):
        assert lts_core(1, r, P)[0] == 1


@pytest.mark.parametrize("k", [0, 1, 2, 3])
def test_x_half_depends_on_r_mod_4(k):
    # Trong so thuc f(0.5) = 1 mod 1 = 0 voi moi r. O so nguyen cat bot:
    #   term1 = r >> 2,  term2 = (4*ONE - r) >> 2
    #   r%4 == 0 -> tong = ONE        -> mat na -> 0
    #   r%4 != 0 -> tong = ONE - 1    -> 2^W - 1   (va 2^W - 1 lai ve 0 o buoc ke)
    r = R_MID - (R_MID % 4) + k
    got = lts_core(P.HALF, r, P)[0]
    assert got == (0 if k == 0 else P.MASK)


def test_zero_guard_returns_x0_and_flags():
    x0 = 0xDEADBEEF
    r = R_MID - (R_MID % 4)          # r % 4 == 0 -> f(HALF) = 0 ngay
    out = lts_step_ex(P.HALF, r, x0, P)
    assert out == (x0, BRANCH_HIGH, True)
    assert lts_step(0, R_MID, x0, P) == x0
    assert lts_step(1, R_MID, x0, P) == x0               # f(1) = 1 (diem bat dong) -> guard
    assert lts_step(P.MASK, R_MID, x0, P) == x0          # f(2^W - 1) = 1 -> guard
    assert lts_step(1, 3 * P.ONE, x0, P) == x0           # r = 3: f(1) = 0 -> guard

    out2 = lts_step_ex(0x12345678, R_MID, x0, P)
    assert out2.guarded is False and out2.x_next != 0


def test_x_half_with_r_not_div4_takes_two_steps_to_guard():
    x0 = 0x1357_9BDF
    r = R_MID - (R_MID % 4) + 1
    s1 = lts_step(P.HALF, r, x0, P)
    assert s1 == P.MASK                      # chua guard o buoc dau
    assert lts_step(s1, r, x0, P) == x0      # buoc ke: 2^W - 1 -> 0 -> guard


def test_guarded_step_never_outputs_trap():
    rng = random.Random(99)
    x0 = 12345
    for _ in range(3000):
        x = rng.randrange(P.ONE)
        r = P.R_MIN_INT + rng.randrange(P.R_SPAN_INT)
        assert 2 <= lts_step(x, r, x0, P) <= P.MASK
    for x in (0, 1, 2, P.MASK, P.MASK - 1, P.HALF):
        assert lts_step(x, R_MID, x0, P) >= 2


# ---------------------------------------------------------------- 3c. nhat quan 3 cach goi
@pytest.mark.parametrize("p", [P, dataclasses.replace(P, W=24)])
def test_closure_equals_step_and_core(p):
    rng = random.Random(2024)
    for r in _r_values(p):
        x0 = rng.randrange(2, p.ONE)
        step = make_lts_step(r, x0, p)
        for x in _samples(p, 500, seed=r + 1):
            raw, br = lts_core(x, r, p)
            exp = x0 if raw <= 1 else raw
            assert step(x) == exp
            assert lts_step(x, r, x0, p) == exp
            out = lts_step_ex(x, r, x0, p)
            assert (out.x_next, out.branch, out.guarded) == (exp, br, raw <= 1)


def test_long_orbit_closure_vs_reference():
    x0, x_a, x_b = 0x0F0F0F0F, 0x0F0F0F0F, 0x0F0F0F0F
    step = make_lts_step(R_MID, x0, P)
    for _ in range(5000):
        x_a = lts_step(x_a, R_MID, x0, P)
        x_b = step(x_b)
        assert x_a == x_b


# ---------------------------------------------------------------- 3d. kiem tra tham so
def test_input_validation():
    with pytest.raises(ValueError):
        lts_core(-1, R_MID, P)
    with pytest.raises(ValueError):
        lts_core(P.ONE, R_MID, P)
    with pytest.raises(ValueError):
        lts_core(5, 0, P)
    with pytest.raises(ValueError):
        lts_core(5, (4 << P.W) + 1, P)
    with pytest.raises(ValueError):
        lts_step(5, R_MID, 0, P)             # X0 = 0 khong hop le
    with pytest.raises(ValueError):
        lts_step(5, R_MID, 1, P)             # X0 = 1 cung la bay -> khong hop le (X0 >= 2)
    with pytest.raises(ValueError):
        make_lts_step(R_MID, 0, P)
    with pytest.raises(ValueError):
        make_lts_step(R_MID, 1, P)
    with pytest.raises(ValueError):
        make_lts_step(0, 5, P)
