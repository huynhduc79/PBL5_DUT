"""params.py - tham so va hang so cua reference model (nguon su that duy nhat).

Moi module khac (lts, kdf, fisher_yates, cipher, framing, ...) chi doc tham so
tu day. Khong module nao tu dinh nghia lai W, N, RESEED_INTERVAL hay dai r.
Toan bo gia tri o day la so nguyen (khong float) de golden model bit-exact.

Tham chieu Design_Proposal:
    W, Q0.W / Q2.W ........ muc 4.3.1, cong thuc (4.8), (4.9)
    r_int (D2) ............ muc 4.2.3, cong thuc (4.6); dai r = [1.0, 2.0) sau phan tich muc 6.1/6.2.3
    RESEED_INTERVAL ....... muc 4.2.4, (4.7); = 64 sau phan tich muc 6.2.3
    TRAP_MAX / X0_MIN ..... trang thai X <= 1 la bay (X = 0 va X = 1 la diem bat dong, xem lts.py)
    nhan "session", ctr ... muc 4.2.2, (4.3); ctr 4 byte big-endian (D4)
    idx 2 byte ............ muc 5.4.2 (P5)
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field

# Doi phien ban nay moi khi doi bat ky quy uoc nao anh huong den vector.
SPEC_VERSION = "1.0.0"

# KDF (muc 4.2.3): K_session 256 bit -> 8 tu w_i, moi tu 32 bit, big-endian.
KDF_WORD_BITS = 32
KDF_NUM_WORDS = 8

# Bay cua LTS so nguyen: X = 0 luon ve 0; voi r < 2 thi X = 1 luon ve 1 (term2 = floor((4-r)/2) = 1),
# va X = 2^W - 1 roi thang vao 1. Moi trang thai X_next <= TRAP_MAX bi thay bang X0 cua phien,
# nen X0 phai >= X0_MIN.
TRAP_MAX = 1
X0_MIN = TRAP_MAX + 1


def _floor_scaled(frac: tuple[int, int], bits: int) -> int:
    """floor(num/den * 2**bits) bang so nguyen thuan tuy."""
    num, den = frac
    return (num << bits) // den


@dataclass(frozen=True)
class CipherParams:
    """Bo tham so cua mot cau hinh mat ma.

    Cac truong dau la tham so goc (nhap vao). Cac truong init=False la hang so
    dan xuat, tinh mot lan trong __post_init__ de truy cap nhanh (p.ONE, p.MASK).
    Doi cau hinh bang dataclasses.replace(p, W=24), khong sua tai cho.
    """

    # --- Tham so goc ---
    W: int = 32                        # do rong trang thai X (bit), Q0.W
    N: int = 8                         # do rong mau cam bien (bit): 8 hoac 16
    RESEED_INTERVAL: int = 64          # so mau moi phien (muc 6.2.3: rui ro lap ~ s^2 / 2^(W+1))
    R_MIN: tuple[int, int] = (1, 1)    # r_min  = 1/1 = 1.0  (phan so, khong float)
    R_SPAN: tuple[int, int] = (1, 1)   # r_span = 1/1 = 1.0  -> r thuoc [1.0, 2.0)  (xem 4.2.3)
    LABEL: bytes = b"session"          # nhan trong thong diep HMAC (4.3)
    CTR_BITS: int = 32                 # ctr: 4 byte big-endian (D4)
    IDX_BITS: int = 16                 # idx trong khung: 2 byte (P5)
    K_MASTER_BYTES: int = 32           # K_master 256 bit
    FY_REFILL_WATCHDOG: int = 64       # chi de bat loi: vuot qua thi raise, khong doi hanh vi (D5)

    # --- Hang so dan xuat ---
    ONE: int = field(init=False, repr=False, compare=False)          # 2**W
    MASK: int = field(init=False, repr=False, compare=False)         # 2**W - 1
    HALF: int = field(init=False, repr=False, compare=False)         # 2**(W-1), tuong duong X = 0.5
    R_BITS: int = field(init=False, repr=False, compare=False)       # W + 2 (Q2.W)
    R_MIN_INT: int = field(init=False, repr=False, compare=False)    # floor(r_min * 2**W)
    R_SPAN_INT: int = field(init=False, repr=False, compare=False)   # floor(r_span * 2**W)
    R_MAX_INT: int = field(init=False, repr=False, compare=False)    # r_int lon nhat co the sinh ra
    CTR_MASK: int = field(init=False, repr=False, compare=False)
    IDX_MAX: int = field(init=False, repr=False, compare=False)      # so mau toi da moi phien theo idx
    N_MASK: int = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        self._validate_primary()

        w = self.W
        r_min_int = _floor_scaled(self.R_MIN, w)
        r_span_int = _floor_scaled(self.R_SPAN, w)
        # (4.6): r_int = R_MIN_INT + ((R_SPAN_INT * x) >> 32), x < 2**32
        r_max_int = r_min_int + ((r_span_int * ((1 << KDF_WORD_BITS) - 1)) >> KDF_WORD_BITS)

        derived = {
            "ONE": 1 << w,
            "MASK": (1 << w) - 1,
            "HALF": 1 << (w - 1),
            "R_BITS": w + 2,
            "R_MIN_INT": r_min_int,
            "R_SPAN_INT": r_span_int,
            "R_MAX_INT": r_max_int,
            "CTR_MASK": (1 << self.CTR_BITS) - 1,
            "IDX_MAX": 1 << self.IDX_BITS,
            "N_MASK": (1 << self.N) - 1,
        }
        for name, value in derived.items():
            object.__setattr__(self, name, value)

        self._validate_derived()

    # ------------------------------------------------------------------ kiem tra
    def _validate_primary(self) -> None:
        def need(cond: bool, msg: str) -> None:
            if not cond:
                raise ValueError(msg)

        need(isinstance(self.W, int) and 8 <= self.W <= 64, "W phai la so nguyen trong [8, 64]")
        need(self.N in (8, 16), "N phai la 8 hoac 16")
        need(self.N <= self.W, "N phai <= W (keystream lay N bit MSB cua X, muc 4.3.3)")
        need(
            isinstance(self.RESEED_INTERVAL, int) and 1 <= self.RESEED_INTERVAL <= (1 << self.IDX_BITS),
            "RESEED_INTERVAL phai trong [1, 2**IDX_BITS] de idx khong tran",
        )
        for name in ("R_MIN", "R_SPAN"):
            frac = getattr(self, name)
            need(
                isinstance(frac, tuple) and len(frac) == 2
                and all(isinstance(v, int) and not isinstance(v, bool) for v in frac)
                and frac[0] > 0 and frac[1] > 0,
                f"{name} phai la tuple (tu, mau) so nguyen duong (khong dung float)",
            )
        need(isinstance(self.LABEL, bytes) and len(self.LABEL) > 0, "LABEL phai la bytes khong rong")
        need(self.CTR_BITS == 32, "CTR_BITS = 32 (khung 5.4.2 danh 4 byte cho ctr)")
        need(self.IDX_BITS == 16, "IDX_BITS = 16 (khung 5.4.2 danh 2 byte cho idx)")
        need(self.K_MASTER_BYTES == 32, "K_MASTER_BYTES = 32 (K_master 256 bit)")
        need(self.FY_REFILL_WATCHDOG >= 1, "FY_REFILL_WATCHDOG phai >= 1")

    def _validate_derived(self) -> None:
        four = 4 << self.W
        if not (0 < self.R_MIN_INT < self.R_MAX_INT):
            raise ValueError("dai r rong: can 0 < r_min < r_max")
        if self.R_MAX_INT >= four:
            raise ValueError("r_max phai nho hon 4 (r_int < 4 * 2**W)")
        if self.R_MAX_INT >= (1 << self.R_BITS):
            raise ValueError("r_int khong vua thanh ghi Q2.W")

    # --------------------------------------------------------------- tien ich
    @property
    def kdf_supported(self) -> bool:
        """KDF 4.2.3 (w_i 32 bit) chi dung duoc voi W = 32.

        Voi W khac (thi nghiem thu nho W o muc 6.2.3) dung lts_step truc tiep
        voi (X0, r) tu chon, khong qua KDF.
        """
        return self.W == KDF_WORD_BITS

    def to_dict(self) -> dict:
        """Dang canonical, chi gom so nguyen/chuoi, dung cho manifest va hash."""
        return {
            "SPEC_VERSION": SPEC_VERSION,
            "TRAP_MAX": TRAP_MAX,
            "W": self.W,
            "N": self.N,
            "RESEED_INTERVAL": self.RESEED_INTERVAL,
            "R_MIN": list(self.R_MIN),
            "R_SPAN": list(self.R_SPAN),
            "LABEL_HEX": self.LABEL.hex(),
            "CTR_BITS": self.CTR_BITS,
            "IDX_BITS": self.IDX_BITS,
            "K_MASTER_BYTES": self.K_MASTER_BYTES,
            "R_MIN_INT": self.R_MIN_INT,
            "R_SPAN_INT": self.R_SPAN_INT,
            "R_MAX_INT": self.R_MAX_INT,
        }

    def config_hash(self) -> str:
        """SHA-256 cua cau hinh canonical; ghi vao manifest.json cua vector."""
        blob = json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(blob).hexdigest()


DEFAULT_PARAMS = CipherParams()
