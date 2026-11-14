"""Test cho refmodel/analysis: ideal_lts (6.1), period (6.2.3), stats."""

import dataclasses
import math
import random

import numpy as np
import pytest

from refmodel.analysis import ideal_lts, period, stats
from refmodel.lts import lts_core, make_lts_step
from refmodel.params import DEFAULT_PARAMS

P = DEFAULT_PARAMS
KM = bytes(range(32))


# =========================================================== ideal_lts
def test_float_step_matches_fixed_point_within_truncation_bound():
    rnd = random.Random(1)
    one = P.ONE
    for _ in range(3000):
        x = rnd.randrange(one)
        r_int = P.R_MIN_INT + rnd.randrange(P.R_SPAN_INT)
        want = lts_core(x, r_int, P)[0] / one
        got = float(ideal_lts.lts_float(x / one, r_int / one))
        d = abs(got - want)
        assert min(d, 1 - d) < 8 / one + 1e-12            # < 7 LSB cat bot (xem test_lts) + sai so float


def test_float_known_values():
    assert ideal_lts.lts_float(0.5, 3.0) == 0.0            # f(0.5) = 1 mod 1 = 0 (so thuc)
    assert ideal_lts.lts_float(0.25, 4.0) == pytest.approx(0.75)      # logistic r=4: 4*.25*.75
    assert ideal_lts.lts_float(0.0, 2.0) == 0.0


def test_derivative_matches_finite_difference_away_from_jumps():
    rnd = np.random.default_rng(2)
    h = 1e-7
    checked = 0
    for _ in range(400):
        x = float(rnd.uniform(0.01, 0.99))
        r = float(rnd.uniform(0.2, 3.9))
        if abs(x - 0.5) < 1e-3:
            continue
        inner = lambda v: r * v * (1 - v) + 0.5 * (4 - r) * (v if v < 0.5 else 1 - v)
        if math.floor(inner(x - h)) != math.floor(inner(x + h)):
            continue                                          # cat ngang bien mod 1
        fd = (inner(x + h) - inner(x - h)) / (2 * h)
        assert float(ideal_lts.lts_derivative(x, r)) == pytest.approx(fd, abs=1e-5)
        checked += 1
    assert checked > 200


def test_lyapunov_logistic_limit_is_ln2():
    # r = 4: thanh phan Tent bien mat, LTS = Logistic r = 4, lambda = ln 2
    lam = ideal_lts.lyapunov([3.9999], n_transient=500, n_avg=100000)[0]
    assert lam == pytest.approx(math.log(2), abs=0.01)


def test_lyapunov_positive_on_whole_range():
    # Ket qua muc 6.1: lambda ~ ln 2 tren toan bo (0, 4) (khong chi [3.6, 4))
    r = np.linspace(0.05, 3.99, 150)
    lam = ideal_lts.lyapunov(r, n_avg=5000)
    assert np.all(lam > 0.6) and np.all(lam < 0.72)
    sm = ideal_lts.lyapunov_summary(r, lam, 3.6, 4.0)
    assert sm["frac_positive"] == 1.0 and sm["r_nonpositive"] == []


def test_zero_trap_creates_fake_lyapunov_without_guard():
    # x0 = 0.5, r = 3: f(0.5) = 0 -> ket o diem hap thu, lambda gia = ln(2 + r/2) = ln 3.5
    lam_noguard = ideal_lts.lyapunov([3.0], n_transient=10, n_avg=1000, x0=0.5, guard=False)[0]
    assert lam_noguard == pytest.approx(math.log(3.5), abs=1e-6)


def test_guard_restores_x0_when_orbit_hits_zero():
    # x0 = 0.5, r = 3: x1 = 0 -> guard dat lai 0.5; quy dao dung o 0.5, f'(0.5) = -(4-r)/2 = -0.5
    lam = ideal_lts.lyapunov([3.0], n_transient=10, n_avg=1000, x0=0.5, guard=True)[0]
    assert lam == pytest.approx(math.log(0.5), abs=1e-9)


def test_bifurcation_shapes_and_range():
    r = np.linspace(0.5, 3.9, 50)
    rp, xp = ideal_lts.bifurcation(r, n_transient=100, n_plot=30)
    assert rp.shape == xp.shape == (50 * 30,)
    assert np.all((xp >= 0) & (xp < 1))
    assert set(np.unique(rp)) == set(r)


def test_plot_writes_png(tmp_path):
    out = tmp_path / "bif.png"
    ideal_lts.plot_bifurcation_lyapunov(str(out), n_r=60)
    assert out.stat().st_size > 5000


# =========================================================== period
def _brute_rho(f, x0):
    seen = {}
    x, i = x0, 0
    while x not in seen:
        seen[x] = i
        x = f(x)
        i += 1
    mu = seen[x]
    return i - mu, mu                                       # lam, mu


def test_brent_known_sequences():
    assert period.brent(lambda x: (x + 1) % 7, 3) == (7, 0)
    tail = {0: 1, 1: 2, 2: 3, 3: 4, 4: 2}
    assert period.brent(tail.__getitem__, 0) == (3, 2)
    assert period.brent(lambda x: x, 5) == (1, 0)
    assert period.rho_of(tail.__getitem__, 0) == 5


def test_brent_matches_bruteforce_on_random_maps():
    rnd = random.Random(3)
    for _ in range(400):
        m = rnd.randrange(2, 400)
        table = [rnd.randrange(m) for _ in range(m)]
        x0 = rnd.randrange(m)
        assert period.brent(table.__getitem__, x0) == _brute_rho(table.__getitem__, x0)


def test_brent_matches_bruteforce_on_real_lts_small_w():
    p = dataclasses.replace(P, W=12)
    rnd = random.Random(4)
    for _ in range(200):
        x0, r = period.sample_session(p, rnd)
        step = make_lts_step(r, x0, p)
        assert period.brent(step, x0) == _brute_rho(step, x0)


def test_repeats_within_equals_rho_le_s():
    p = dataclasses.replace(P, W=14)
    rnd = random.Random(5)
    for _ in range(300):
        x0, r = period.sample_session(p, rnd)
        step = make_lts_step(r, x0, p)
        rho = period.rho_of(step, x0)
        for s in (1, 5, 50, 300):
            assert period.repeats_within(step, x0, s) == (rho <= s)


def test_sample_session_ranges():
    for w in (8, 16, 32):                                     # W = 8: x0 = 0 se xuat hien neu khong loai tru
        p = dataclasses.replace(P, W=w)
        rnd = random.Random(w)
        for _ in range(6000):
            x0, r = period.sample_session(p, rnd)
            assert 2 <= x0 <= p.MASK and p.R_MIN_INT <= r <= p.R_MAX_INT


def test_repeats_within_exact_boundary():
    p = dataclasses.replace(P, W=14)
    rnd = random.Random(15)
    for _ in range(200):
        x0, r = period.sample_session(p, rnd)
        step = make_lts_step(r, x0, p)
        rho = period.rho_of(step, x0)
        assert period.repeats_within(step, x0, rho) is True
        assert period.repeats_within(step, x0, rho - 1) is False


def test_formulas():
    assert period.predicted_p_repeat(32, 0) == 0.0
    s = int(math.sqrt(2 ** 33))                                # s^2 ~ 2^(W+1)
    assert period.predicted_p_repeat(32, s) == pytest.approx(1 - math.exp(-1), abs=1e-4)
    mean = math.sqrt(math.pi * 2 ** 20 / 2)
    assert period.n_eff_from_mean_rho(mean) == pytest.approx(2 ** 20)
    assert period.predicted_p_repeat(32, 516) == pytest.approx(3.1e-5, rel=0.02)


def test_summarize_fields():
    sm = period.summarize(list(range(1, 1001)), 16)
    assert sm["min"] == 1 and sm["max"] == 1000 and sm["median"] in (500, 501)
    assert sm["mean"] == pytest.approx(500.5)


def test_scaled_w_effective_state_space():
    # Ket qua muc 6.2.3 (thu nho W): dai r cu [3.6, 4.0) chi con ~0.36 * 2^W trang thai hieu dung;
    # dai r mac dinh [1.0, 2.0) gan nhu anh xa ngau nhien (~1.0 * 2^W).
    w = 16
    p_old = dataclasses.replace(P, W=w, R_MIN=(36, 10), R_SPAN=(4, 10))
    p_new = dataclasses.replace(P, W=w)
    ratio = lambda p: period.summarize([r for r, _, _ in period.scan_rho(p, 3000, seed=7)], w)["N_eff_over_2W"]
    assert 0.30 < ratio(p_old) < 0.45
    assert 0.90 < ratio(p_new) < 1.15


def test_rho_by_r_buckets():
    p = dataclasses.replace(P, W=12)
    res = period.rho_by_r(p, [0.5, 1.0, 2.0, 3.6, 4.0], 300, seed=3)
    assert [(s["r_lo"], s["r_hi"]) for s in res] == [(0.5, 1.0), (1.0, 2.0), (2.0, 3.6), (3.6, 4.0)]
    assert all(s["n"] == 300 and s["min"] >= 1 for s in res)
    assert res[1]["N_eff_over_2W"] > res[3]["N_eff_over_2W"]      # r cao -> it trang thai hieu dung hon


def test_cli_smoke(capsys):
    period.main(["rho", "--W", "12", "--pairs", "30"])
    period.main(["repeat", "--W", "12", "--s", "40", "--pairs", "50"])
    period.main(["rsweep", "--W", "12", "--pairs", "30", "--edges", "0.5,2,4"])
    out = capsys.readouterr().out
    assert "N_eff" in out and "mo hinh" in out and "r in [0.5, 2.0)" in out


# =========================================================== stats
def test_chi2_and_entropy():
    rnd = random.Random(6)
    vals = [rnd.randrange(256) for _ in range(100000)]
    assert stats.chi2_uniform(vals, 256) < 330
    assert stats.shannon_entropy_bits(vals) > 7.99
    assert stats.shannon_entropy_bits([5] * 100) == 0.0
    assert stats.chi2_uniform([0] * 256, 256) > 1000


def test_serial_correlation():
    assert stats.serial_correlation(list(range(1000))) == pytest.approx(1.0, abs=1e-3)
    rnd = random.Random(7)
    vals = [rnd.randrange(256) for _ in range(50000)]
    assert abs(stats.serial_correlation(vals)) < 0.02


def test_nist_examples_monobit_and_runs():
    # NIST SP 800-22, vi du trong muc 2.1.8 va 2.3.8
    bits = [int(c) for c in "1011010101"]
    assert stats.monobit_pvalue(bits) == pytest.approx(0.527089, abs=1e-6)
    bits = [int(c) for c in "1001101011"]
    assert stats.runs_pvalue(bits) == pytest.approx(0.147232, abs=1e-6)


def test_bit_tests_detect_bias_and_pattern():
    assert stats.monobit_pvalue([1] * 1000) < 1e-10
    assert stats.monobit_pvalue([0, 1] * 500) == pytest.approx(1.0)
    assert stats.runs_pvalue([0, 1] * 500) < 1e-10          # qua nhieu chuoi
    rnd = random.Random(8)
    bits = [rnd.randrange(2) for _ in range(100000)]
    assert stats.monobit_pvalue(bits) > 0.001 and stats.runs_pvalue(bits) > 0.001


def test_to_bits_and_write_bitstream(tmp_path):
    assert stats.to_bits([0b101, 0b011], 3) == [1, 0, 1, 1, 1, 0]       # bit 0 truoc
    f = tmp_path / "s.bin"
    assert stats.write_bitstream(str(f), [0b101], 3) == 1
    assert f.read_bytes() == bytes([0b10100000])
    n = stats.write_bitstream(str(f), list(range(256)), 8)
    assert n == 256 and len(f.read_bytes()) == 256


def test_lts_steps_stats_about_two():
    st = stats.lts_steps_stats(KM, P, n_samples=4000)
    assert 2.0 <= st["mean_lts_steps"] <= 2.06
    assert 1.3 <= st["mean_rejects"] <= 1.5
    assert st["max_lts_steps"] <= 5 and sum(st["hist"].values()) == 4000


def test_key_sensitivity_close_to_half():
    # moi lan dao: 512 mau * 8 bit = 4096 bit so sanh, do lech chuan cua ti le ~ 0.0078;
    # can 0.46..0.54 ~ 5 sigma cho min/max cua 8 lan dao.
    ks = stats.key_sensitivity(KM, P, n_samples=512, flips=range(0, 256, 32))
    assert ks["n_flips"] == 8
    assert 0.46 < ks["min"] and ks["max"] < 0.54 and 0.49 < ks["mean"] < 0.51


def test_ciphertext_stream_passes_basic_bit_tests():
    c = stats.ciphertext_stream(KM, P, 20000, plain=lambda i: 0xA5)
    bits = stats.to_bits(c, 8)
    assert stats.monobit_pvalue(bits) > 0.001
    assert stats.runs_pvalue(bits) > 0.001
    assert abs(stats.serial_correlation(c)) < 0.03


def test_bit_quality_msb_biased_lsb_uniform_at_high_r():
    q = stats.lts_bit_quality(P, 3.75, 4.0, n_sessions=800, steps=200, seed=1)
    assert q["chi2_top8"] > 10000                       # bit cao lech manh (ly do chon bit THAP, D1)
    assert q["chi2_low8"] < 330 and q["chi2_pairs_low4"] < 330
    assert q["p_top_bit"] != pytest.approx(0.5, abs=0.001) or q["chi2_top8"] > 10000


def test_bit_quality_low_bits_uniform_in_mid_range():
    q = stats.lts_bit_quality(P, 1.0, 2.0, n_sessions=800, steps=200, seed=2)
    assert q["chi2_low8"] < 330 and q["chi2_pairs_low4"] < 330
