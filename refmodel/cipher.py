"""cipher.py - quan ly phien va ma hoa/giai ma tung mau (muc 4.2.6, 4.3.6, 4.3.7).

    SessionManager  : ctr, sample_count, (X0, r), trang thai X, tai tao phien (4.2.6)
    CipherCore      : encrypt / decrypt mot mau N bit, dung chung _gen_ks_perm()

Ma hoa:   x <- LTS(x); k <- x & (2**N - 1); pi <- FisherYates(x); C <- gather(P, pi) XOR k
Giai ma:  cung k, pi;   P <- scatter(C XOR k, pi)

Trace (neu truyen list): moi su kien la tuple (ten_trang_thai_FSM, du_lieu) theo muc 5.3.4:
    RESEED_HMAC (luc bat dau phien), LTS_KEYSTREAM, FY_INIT, FY_REFILL, FY_DRAW,
    FY_SWAP, PERMUTE_XOR, CHECK_RESEED, [RESEED_HMAC], DONE
"""

from __future__ import annotations

from typing import NamedTuple

from .fisher_yates import fisher_yates_from_chaos, gather_bits, scatter_bits
from .kdf import derive_lts_params
from .lts import make_lts_step
from .params import DEFAULT_PARAMS, CipherParams


def _emit(trace, name: str, *data) -> None:
    if trace is not None:
        trace.append((name, data))


class SessionManager:
    """Quan ly phien (4.2.6). ctr la so 32 bit khong dau, quay vong modulo 2**32."""

    def __init__(self, k_master: bytes, p: CipherParams = DEFAULT_PARAMS, ctr0: int = 0, trace=None):
        self.p = p
        self.k_master = bytes(k_master)
        self.ctr = ctr0
        self.sample_count = 0
        self.trace = trace
        self._start_session()

    def _start_session(self) -> None:
        sp = derive_lts_params(self.k_master, self.ctr, self.p)   # HMAC + (4.4)-(4.6)
        self.x0 = sp.x0
        self.r_int = sp.r_int
        self.x = sp.x0                                            # X <- X0   (4.7)
        self.step = make_lts_step(sp.r_int, sp.x0, self.p)
        _emit(self.trace, "RESEED_HMAC", self.ctr, sp.k_session, sp.x0, sp.r_int)

    def update(self) -> bool:
        """UpdateSession (4.2.6). Tra True neu vua tai tao phien."""
        self.sample_count += 1
        _emit(self.trace, "CHECK_RESEED", self.sample_count)
        if self.sample_count >= self.p.RESEED_INTERVAL:
            self.ctr = (self.ctr + 1) & self.p.CTR_MASK
            self.sample_count = 0
            self._start_session()
            return True
        return False


class EncResult(NamedTuple):
    c: int      # ban ma N bit
    ctr: int    # ctr dung de ma hoa mau nay (truoc UpdateSession), D4
    idx: int    # chi so mau trong phien, 0 .. RESEED_INTERVAL-1


class CipherCore:
    """Ma hoa dong dong bo cho tung mau N bit."""

    def __init__(self, k_master: bytes, p: CipherParams = DEFAULT_PARAMS, ctr0: int = 0, trace=None):
        self.p = p
        self.trace = trace
        self.session = SessionManager(k_master, p, ctr0, trace)
        # thong ke mau gan nhat, cho analysis (so vong LTS moi mau = 1 + refills)
        self.last_refills = 0
        self.last_rejects = 0

    @property
    def position(self) -> tuple[int, int]:
        """(ctr, idx) cua mau KE TIEP se duoc xu ly."""
        return self.session.ctr, self.session.sample_count

    @property
    def last_lts_steps(self) -> int:
        return 1 + self.last_refills

    def _check_sample(self, v: int) -> None:
        if not isinstance(v, int) or isinstance(v, bool) or not (0 <= v <= self.p.N_MASK):
            raise ValueError(f"mau phai la so nguyen {self.p.N} bit")

    def _gen_ks_perm(self) -> tuple[int, tuple[int, ...]]:
        """Sinh (keystream k, hoan vi pi) cho mau hien tai; cap nhat trang thai X cua phien."""
        s, p = self.session, self.p
        x_in = s.x
        x = s.step(x_in)                                          # LTS_KEYSTREAM
        k = x & p.N_MASK                                          # (4.10) sua: N bit THAP
        _emit(self.trace, "LTS_KEYSTREAM", x_in, x, k)
        fy = fisher_yates_from_chaos(x, s.step, p, self.trace)    # FY_*
        s.x = fy.x
        self.last_refills, self.last_rejects = fy.refills, fy.rejects
        return k, fy.pi

    def _finish(self, out: int) -> None:
        self.session.update()                                     # CHECK_RESEED [+ RESEED_HMAC]
        _emit(self.trace, "DONE", out)

    def encrypt(self, plain: int) -> EncResult:
        self._check_sample(plain)
        ctr, idx = self.position
        k, pi = self._gen_ks_perm()
        shuffled = gather_bits(plain, pi)
        c = shuffled ^ k
        _emit(self.trace, "PERMUTE_XOR", pi, plain, shuffled, c)
        self._finish(c)
        return EncResult(c, ctr, idx)

    def decrypt(self, cipher: int) -> int:
        self._check_sample(cipher)
        k, pi = self._gen_ks_perm()
        shuffled = cipher ^ k
        plain = scatter_bits(shuffled, pi)
        _emit(self.trace, "PERMUTE_XOR", pi, plain, shuffled, cipher)
        self._finish(plain)
        return plain

    def advance(self, n: int = 1) -> None:
        """Chay bu n mau (bo qua du lieu) de dong bo lai sau khi mat goi (muc 5.4.2, idx)."""
        for _ in range(n):
            self._gen_ks_perm()
            self._finish(0)