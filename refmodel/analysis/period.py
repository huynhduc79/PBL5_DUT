"""period.py - tim chu ky quy dao bang thuat toan Brent va uoc luong rui ro lap (muc 6.2.3).

Dai luong (muc 6.2.3):  quy dao X0, X1, ... co mu (doan qua do), lam (chu ky), rho = mu + lam
= so trang thai doi mot khac nhau; lan lap lai dau tien xay ra sau rho buoc.

  brent(step, x0)                      -> (lam, mu)      thuat toan Brent (1980)
  rho_of(step, x0)                     -> rho
  repeats_within(step, x0, s)          -> True neu rho <= s (re hon Brent khi chi can biet co lap khong)
  sample_session(p, rnd)               -> (x0, r_int) phan bo giong KDF muc 4.2.3 (tong quat cho moi W)
  scan_rho(p, n_pairs, seed)           -> danh sach (rho, lam, mu)
  repeat_probability(p, s, n_pairs, seed) -> (so lan lap, n_pairs)
  rho_by_r(p, edges, n_pairs, seed)    -> tom tat rho theo tung khoang r (xem anh huong cua r)
  predicted_p_repeat(W, s)             -> 1 - exp(-s^2 / 2^(W+1)) (mo hinh anh xa ngau nhien, cong thuc 6.2)
  n_eff_from_mean_rho(mean_rho)        -> so trang thai hieu dung, tu E[rho] = sqrt(pi * N_eff / 2)

Chay:  python -m refmodel.analysis.period rho --W 24 --pairs 2000
       python -m refmodel.analysis.period rsweep --W 24 --pairs 500 --edges 0.25,1,2,3,3.6,4
       python -m refmodel.analysis.period repeat --W 32 --s 129 --pairs 1000000   # s ~ 2.02 * RESEED_INTERVAL
"""

from __future__ import annotations

import argparse
import dataclasses
import math
import random
from collections.abc import Callable
from fractions import Fraction

from ..lts import make_lts_step
from ..params import DEFAULT_PARAMS, X0_MIN, CipherParams

Step = Callable[[int], int]


def brent(step: Step, x0: int) -> tuple[int, int]:
    """Thuat toan Brent: tra (lam, mu). Dich tu pseudocode muc 6.2.3."""
    power = lam = 1
    tortoise = x0
    hare = step(x0)
    while tortoise != hare:
        if power == lam:
            tortoise = hare
            power *= 2
            lam = 0
        hare = step(hare)
        lam += 1
    tortoise = hare = x0
    for _ in range(lam):
        hare = step(hare)
    mu = 0
    while tortoise != hare:
        tortoise = step(tortoise)
        hare = step(hare)
        mu += 1
    return lam, mu


def rho_of(step: Step, x0: int) -> int:
    lam, mu = brent(step, x0)
    return lam + mu


def repeats_within(step: Step, x0: int, s: int) -> bool:
    """True neu trong s buoc dau co mot trang thai lap lai (tuong duong rho <= s)."""
    seen = {x0}
    x = x0
    for _ in range(s):
        x = step(x)
        if x in seen:
            return True
        seen.add(x)
    return False


def sample_session(p: CipherParams, rnd: random.Random) -> tuple[int, int]:
    """(X0, r_int) co phan bo cua KDF: X0 deu tren [2, 2^W-1], r_int = R_MIN + (R_SPAN * x) >> W."""
    x0 = rnd.randrange(X0_MIN, p.ONE)
    x = rnd.randrange(p.ONE)
    return x0, p.R_MIN_INT + ((p.R_SPAN_INT * x) >> p.W)


def scan_rho(p: CipherParams, n_pairs: int, seed: int = 0) -> list[tuple[int, int, int]]:
    rnd = random.Random(seed)
    out = []
    for _ in range(n_pairs):
        x0, r_int = sample_session(p, rnd)
        lam, mu = brent(make_lts_step(r_int, x0, p), x0)
        out.append((lam + mu, lam, mu))
    return out


def repeat_probability(p: CipherParams, s: int, n_pairs: int, seed: int = 0) -> tuple[int, int]:
    rnd = random.Random(seed)
    hits = 0
    for _ in range(n_pairs):
        x0, r_int = sample_session(p, rnd)
        hits += repeats_within(make_lts_step(r_int, x0, p), x0, s)
    return hits, n_pairs


def _frac(v: float) -> tuple[int, int]:
    fr = Fraction(v).limit_denominator(10000)
    return fr.numerator, fr.denominator


def rho_by_r(p: CipherParams, edges: list[float], n_pairs: int, seed: int = 0) -> list[dict]:
    """Tom tat rho (summarize) cho tung khoang r = [edges[i], edges[i+1]) o do rong W cua p."""
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        q = dataclasses.replace(p, R_MIN=_frac(lo), R_SPAN=_frac(hi - lo))
        sm = summarize([r for r, _, _ in scan_rho(q, n_pairs, seed)], p.W)
        sm["r_lo"], sm["r_hi"] = lo, hi
        out.append(sm)
    return out


def predicted_p_repeat(w: int, s: int) -> float:
    """Mo hinh anh xa ngau nhien tren 2^W trang thai: P(rho <= s) ~ 1 - exp(-s^2 / 2^(W+1))."""
    return 1.0 - math.exp(-(s * s) / float(1 << (w + 1)))


def n_eff_from_mean_rho(mean_rho: float) -> float:
    return 2.0 * mean_rho * mean_rho / math.pi


def quantile(sorted_vals: list[int], q: float) -> int:
    idx = min(len(sorted_vals) - 1, max(0, int(q * len(sorted_vals))))
    return sorted_vals[idx]


def summarize(rhos: list[int], w: int) -> dict:
    v = sorted(rhos)
    mean = sum(v) / len(v)
    n_eff = n_eff_from_mean_rho(mean)
    return {
        "W": w, "n": len(v), "min": v[0], "q0.1%": quantile(v, 0.001), "q1%": quantile(v, 0.01),
        "median": quantile(v, 0.5), "mean": mean, "max": v[-1],
        "mean_random_map": math.sqrt(math.pi * (1 << w) / 2.0),
        "N_eff": n_eff, "N_eff_over_2W": n_eff / (1 << w),
    }


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["rho", "repeat", "rsweep"])
    ap.add_argument("--edges", default="0.25,1,2,3,3.6,4", help="bien cac khoang r (mode rsweep)")
    ap.add_argument("--W", type=int, default=32)
    ap.add_argument("--pairs", type=int, default=1000)
    ap.add_argument("--s", type=int, default=129, help="so vong LTS cua mot phien (mode repeat), ~ 2.02 * RESEED_INTERVAL")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args(argv)
    p = dataclasses.replace(DEFAULT_PARAMS, W=a.W)
    if a.mode == "rho":
        res = scan_rho(p, a.pairs, a.seed)
        print(summarize([r for r, _, _ in res], a.W))
        print("lam_min =", min(l for _, l, _ in res))
    elif a.mode == "rsweep":
        edges = [float(v) for v in a.edges.split(",")]
        for sm in rho_by_r(p, edges, a.pairs, a.seed):
            print(f"r in [{sm['r_lo']}, {sm['r_hi']}): mean rho = {sm['mean']:.0f}  N_eff/2^W = {sm['N_eff_over_2W']:.2f}  min = {sm['min']}")
    else:
        hits, n = repeat_probability(p, a.s, a.pairs, a.seed)
        print(f"W={a.W} s={a.s}: {hits}/{n} = {hits / n:.3e}   du doan mo hinh = {predicted_p_repeat(a.W, a.s):.3e}")


if __name__ == "__main__":
    main()
