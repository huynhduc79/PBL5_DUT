"""ideal_lts.py - mo hinh ly tuong (float64) cua LTS: bifurcation va so mu Lyapunov (muc 6.1).

Day la noi duy nhat (cung voi analysis/) duoc dung float. Cong thuc (3.1):

    x_{n+1} = ( r x (1 - x) + (4 - r)/2 * (x      neu x <  0.5
                                           1 - x  neu x >= 0.5) ) mod 1

Dao ham tung nhanh (phep mod khong doi dao ham):
    x <  0.5:  f'(x) = r (1 - 2x) + (4 - r)/2
    x >= 0.5:  f'(x) = r (1 - 2x) - (4 - r)/2

So mu Lyapunov (3.2):  lambda(r) = lim (1/N) sum ln |f'(x_n)|.

Zero-guard (giong lts.py, P3): neu x ve 0 chinh xac thi dat lai x = x0. Neu khong, quy dao
ket o diem hap thu x = 0 va cho lambda = ln(2 + r/2) > 0 gia tao.

Cac ham nhan r la mang numpy va lap song song theo r.
"""

from __future__ import annotations

import numpy as np


def lts_float(x, r):
    x = np.asarray(x, dtype=np.float64)
    r = np.asarray(r, dtype=np.float64)
    tent = np.where(x < 0.5, x, 1.0 - x)
    return np.mod(r * x * (1.0 - x) + 0.5 * (4.0 - r) * tent, 1.0)


def lts_derivative(x, r):
    x = np.asarray(x, dtype=np.float64)
    r = np.asarray(r, dtype=np.float64)
    sign = np.where(x < 0.5, 1.0, -1.0)
    return r * (1.0 - 2.0 * x) + sign * 0.5 * (4.0 - r)


def _step(x, r, x0, guard):
    x = lts_float(x, r)
    if guard:
        x = np.where(x == 0.0, x0, x)
    return x


def bifurcation(r_values, n_transient: int = 500, n_plot: int = 120, x0: float = 0.3, guard: bool = True):
    """Tra (r_pts, x_pts): n_plot diem moi gia tri r sau khi bo n_transient buoc qua do."""
    r = np.asarray(r_values, dtype=np.float64)
    x = np.full_like(r, x0)
    for _ in range(n_transient):
        x = _step(x, r, x0, guard)
    xs = np.empty((n_plot, r.size))
    for i in range(n_plot):
        x = _step(x, r, x0, guard)
        xs[i] = x
    return np.tile(r, n_plot), xs.ravel()


def lyapunov(r_values, n_transient: int = 1000, n_avg: int = 20000, x0: float = 0.3, guard: bool = True):
    """Cong thuc (3.2): trung binh ln|f'(x_n)| doc quy dao, tinh song song theo r."""
    r = np.asarray(r_values, dtype=np.float64)
    x = np.full_like(r, x0)
    for _ in range(n_transient):
        x = _step(x, r, x0, guard)
    acc = np.zeros_like(r)
    for _ in range(n_avg):
        acc += np.log(np.maximum(np.abs(lts_derivative(x, r)), 1e-300))
        x = _step(x, r, x0, guard)
    return acc / n_avg


def lyapunov_summary(r_values, lam, lo: float = 1.0, hi: float = 2.0) -> dict:
    """Tom tat lambda tren [lo, hi): min, mean, ti le diem duong, cac r co lambda <= 0."""
    r = np.asarray(r_values)
    lam = np.asarray(lam)
    m = (r >= lo) & (r < hi)
    sel = lam[m]
    return {
        "n": int(m.sum()),
        "min": float(sel.min()),
        "mean": float(sel.mean()),
        "frac_positive": float((sel > 0).mean()),
        "r_nonpositive": [float(v) for v in r[m][sel <= 0]],
    }


def plot_bifurcation_lyapunov(path: str, r_lo: float = 0.0, r_hi: float = 4.0, n_r: int = 800,
                              mark: tuple[float, float] = (1.0, 2.0)) -> None:
    """Ve bieu do phan nhanh va lambda(r), danh dau dai r dang dung (muc 6.1.4)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    r = np.linspace(r_lo + 1e-6, r_hi, n_r)
    rp, xp = bifurcation(r)
    lam = lyapunov(r, n_avg=5000)
    fig, ax = plt.subplots(2, 1, figsize=(9, 7), sharex=True)
    ax[0].plot(rp, xp, ",k", alpha=0.5)
    ax[0].set_ylabel("x")
    ax[0].set_title("LTS: bieu do phan nhanh (float64)")
    ax[1].plot(r, lam, "-b", lw=0.8)
    ax[1].axhline(0, color="r", lw=0.8)
    ax[1].set_ylabel("Lyapunov")
    ax[1].set_xlabel("r")
    for a in ax:
        a.axvspan(mark[0], mark[1], color="orange", alpha=0.12)
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)
