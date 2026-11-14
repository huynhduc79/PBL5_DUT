"""Test cho fisher_yates.py: bit pool, rut so khong thien vi, Fisher-Yates, gather/scatter."""

import dataclasses
import random

import pytest

from refmodel.fisher_yates import (
    BitPool,
    fisher_yates_from_chaos,
    gather_bits,
    rand_range,
    scatter_bits,
)
from refmodel.lts import make_lts_step
from refmodel.params import DEFAULT_PARAMS

P = DEFAULT_PARAMS
P16 = dataclasses.replace(P, N=16)


def scripted(values):
    """step gia: tra lan luot cac gia tri cho truoc (khong phai LTS), de kiem tra logic thuan."""
    it = iter(values)
    return lambda x: next(it)


def ref_fisher_yates(values, n):
    """Cai dat doc lap bang chuoi bit '0'/'1'. bit dau chuoi = bit 0 cua X (LSB truoc)."""
    it = iter(values)
    perm = list(range(n))
    bits = ""
    refills = rejects = 0
    for i in range(n - 1, 0, -1):
        rng = i + 1
        b = len(bin(rng - 1)) - 2
        while True:
            if len(bits) < b:
                bits += format(next(it), "032b")[::-1]
                refills += 1
            cand = int(bits[:b][::-1], 2)
            bits = bits[b:]
            if cand < rng:
                break
            rejects += 1
        perm[i], perm[cand] = perm[cand], perm[i]
    return tuple(perm), refills, rejects


# ------------------------------------------------------------------ BitPool
def test_bitpool_lsb_first_order():
    pool = BitPool()
    pool.refill(0b1011_0110, 8)              # bit 0 = 0, bit 1 = 1, bit 2 = 1, bit 3 = 0, ...
    assert pool.size == 8
    assert pool.take(1) == 0                  # bit 0
    assert pool.take(2) == 0b11               # bit 1, bit 2 -> bit1 la LSB cua ket qua
    assert pool.take(3) == 0b110              # bit 3,4,5 = 0,1,1 -> 0b110
    assert pool.size == 2


def test_bitpool_take_equals_low_bits():
    pool = BitPool()
    x = 0xDEADBEEF
    pool.refill(x, 32)
    assert pool.take(3) == x & 0b111


def test_bitpool_fifo_across_refills():
    pool = BitPool()
    pool.refill(0b101, 3)                     # bit: 1,0,1
    pool.refill(0b11, 2)                      # them: 1,1
    assert pool.size == 5
    assert pool.take(4) == 0b1101             # 1,0,1,1 -> bit0=1, bit1=0, bit2=1, bit3=1
    assert pool.take(1) == 1


def test_bitpool_errors():
    pool = BitPool()
    pool.refill(1, 1)
    with pytest.raises(ValueError):
        pool.take(2)
    with pytest.raises(ValueError):
        pool.refill(4, 2)                     # 4 khong vua 2 bit


# ------------------------------------------------------------------ rand_range / FY: logic thuan
def test_bits_needed_table():
    # b = (rng-1).bit_length() = ceil(log2 rng), muc 4.3.5
    expect = {2: 1, 3: 2, 4: 2, 5: 3, 6: 3, 7: 3, 8: 3, 9: 4, 15: 4, 16: 4}
    for rng, b in expect.items():
        assert (rng - 1).bit_length() == b


def test_rand_range_known_script():
    # X = 0b...0111: low 3 bit = 7. rng=7 (b=3): 7 >= 7 -> reject; roi lay 3 bit ke: 0b000 = 0 -> nhan.
    pool = BitPool()
    val, x, refills, rejects = rand_range(pool, 0, scripted([0b000_111]), 7, P)
    assert (val, refills, rejects) == (0, 1, 1)
    # rng = 8 khong bao gio reject
    pool = BitPool()
    val, _, refills, rejects = rand_range(pool, 0, scripted([0b101]), 8, P)
    assert (val, refills, rejects) == (5, 1, 0)


def test_fisher_yates_matches_independent_reference_many_scripts():
    rng = random.Random(777)
    for p, n in ((P, 8), (P16, 16)):
        for _ in range(300):
            values = [rng.randrange(2**32) for _ in range(400)]
            got = fisher_yates_from_chaos(0, scripted(values), p)
            want_pi, want_ref, want_rej = ref_fisher_yates(values, n)
            assert got.pi == want_pi
            assert (got.refills, got.rejects) == (want_ref, want_rej)


def test_fisher_yates_returns_last_state():
    values = [0x11111111, 0x22222222, 0x33333333, 0x44444444, 0x55555555, 0x66666666]
    got = fisher_yates_from_chaos(0, scripted(values), P)
    assert got.x == values[got.refills - 1]


def test_fisher_yates_trace_events():
    tr = []
    values = [random.Random(1).randrange(2**32) for _ in range(100)]
    fisher_yates_from_chaos(0, scripted(values), P, tr)
    names = [e[0] for e in tr]
    assert names[0] == "FY_INIT"
    assert names.count("FY_SWAP") == 7                       # N-1 lan
    assert set(names) <= {"FY_INIT", "FY_REFILL", "FY_DRAW", "FY_SWAP"}
    assert names.count("FY_DRAW") >= 7


def test_watchdog_triggers_on_endless_rejection():
    # X = 2^32-1 luon: 3 bit thap = 7 -> rng=7 bi reject mai -> vuot watchdog
    with pytest.raises(RuntimeError):
        fisher_yates_from_chaos(0, lambda x: 0xFFFFFFFF, P)


# ------------------------------------------------------------------ tinh dung dan
def _chi2(counts, expected):
    return sum((c - expected) ** 2 / expected for c in counts)


# nguong chi-square p = 0.001 theo bac tu do
CHI2_999 = {2: 13.82, 4: 18.47, 5: 20.52, 6: 22.46, 7: 24.32}


@pytest.mark.parametrize("rng_size", [3, 5, 6, 7])
def test_rand_range_is_uniform(rng_size):
    # nguon bit deu (Python random) -> rejection sampling phai cho phan bo deu (khong bias modulo)
    r = random.Random(1000 + rng_size)
    step = lambda x: r.randrange(2**32)
    pool = BitPool()
    draws = 30000
    counts = [0] * rng_size
    x = 0
    for _ in range(draws):
        v, x, _, _ = rand_range(pool, x, step, rng_size, P)
        counts[v] += 1
    assert _chi2(counts, draws / rng_size) < CHI2_999[rng_size - 1]


def test_fisher_yates_position_marginals_uniform():
    r = random.Random(4242)
    step = lambda x: r.randrange(2**32)
    n_samples = 40000
    marg = {0: [0] * 8, 3: [0] * 8, 7: [0] * 8}
    for _ in range(n_samples):
        pi = fisher_yates_from_chaos(0, step, P).pi
        for j in marg:
            marg[j][pi[j]] += 1
    for j, counts in marg.items():
        assert _chi2(counts, n_samples / 8) < CHI2_999[7], j


def test_real_lts_refill_and_reject_statistics():
    # Phien that: x moi mau = 1 lan LTS (keystream) roi Fisher-Yates, nhu cipher.py
    r_int = P.R_MIN_INT + P.R_SPAN_INT // 2
    x0 = 0x12345678
    step = make_lts_step(r_int, x0, P)
    x = x0
    refills, rejects, maxref = [], [], 0
    for _ in range(20000):
        x = step(x)
        fy = fisher_yates_from_chaos(x, step, P)
        x = fy.x
        refills.append(fy.refills)
        rejects.append(fy.rejects)
        maxref = max(maxref, fy.refills)
    mean_ref = sum(refills) / len(refills)
    mean_rej = sum(rejects) / len(rejects)
    # Ly thuyet (bit deu): ~1.01 refill, 1/7 + 1/3 + 3/5 + 1/3 = 1.41 reject moi mau
    assert 1.0 <= mean_ref <= 1.05
    assert 1.3 <= mean_rej <= 1.5
    assert maxref <= 4


def test_fisher_yates_valid_permutation_with_real_lts():
    for p in (P, P16):
        r_int = p.R_MIN_INT + p.R_SPAN_INT // 3
        step = make_lts_step(r_int, 987654321, p)
        x = 987654321
        for _ in range(2000):
            x = step(x)
            fy = fisher_yates_from_chaos(x, step, p)
            x = fy.x
            assert sorted(fy.pi) == list(range(p.N))


# ------------------------------------------------------------------ gather / scatter
def test_gather_known_values():
    pi = (1, 0, 2, 3, 4, 5, 6, 7)
    assert gather_bits(0b01, pi) == 0b10      # out[0] = in[1] = 0, out[1] = in[0] = 1
    assert gather_bits(0b10, pi) == 0b01
    ident = tuple(range(8))
    assert gather_bits(0xA5, ident) == 0xA5
    rev = tuple(range(7, -1, -1))
    assert gather_bits(0b0000_0001, rev) == 0b1000_0000


def test_scatter_inverts_gather():
    r = random.Random(5)
    for n in (8, 16):
        for _ in range(500):
            pi = list(range(n))
            r.shuffle(pi)
            pi = tuple(pi)
            v = r.randrange(2**n)
            g = gather_bits(v, pi)
            assert scatter_bits(g, pi) == v
            assert gather_bits(scatter_bits(v, pi), pi) == v
            assert bin(g).count("1") == bin(v).count("1")     # chi hoan vi bit, khong doi so bit 1