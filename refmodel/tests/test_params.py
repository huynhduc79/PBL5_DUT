"""Test cho params.py: gia tri phai khop dung voi Design_Proposal (4.2.3 / P1)."""

import dataclasses

import pytest

from refmodel.params import (
    DEFAULT_PARAMS,
    KDF_WORD_BITS,
    SPEC_VERSION,
    CipherParams,
)

P = DEFAULT_PARAMS


def test_defaults():
    assert (P.W, P.N, P.RESEED_INTERVAL) == (32, 8, 64)
    assert P.LABEL == b"session"
    assert P.kdf_supported


def test_derived_constants_match_design_doc():
    # Dai r = [1.0, 2.0): R_MIN = 1.0 * 2^32, R_SPAN = 1.0 * 2^32  (4.2.3, da cap nhat sau muc 6.1/6.2.3)
    assert P.R_MIN_INT == 4_294_967_296
    assert P.R_SPAN_INT == 4_294_967_296
    assert P.ONE == 1 << 32
    assert P.MASK == 0xFFFFFFFF
    assert P.HALF == 0x80000000
    assert P.R_BITS == 34
    assert P.N_MASK == 0xFF


def test_r_max_fits_q2_w():
    # r_int lon nhat = 2^32 + (2^32 - 1) = 2^33 - 1 < 2 * 2^32 (r < 2) va < 2^34 (vua Q2.32)
    assert P.R_MAX_INT == 8_589_934_591 == (1 << 33) - 1
    assert P.R_MAX_INT < 2 * P.ONE
    assert P.R_MAX_INT < (1 << 34)
    assert P.R_MAX_INT < 4 * P.ONE


def test_r_range_from_kdf_formula_exhaustive_edges():
    # r_int = R_MIN_INT + ((R_SPAN_INT * x) >> 32), x thuoc [0, 2^32 - 1]
    for x in (0, 1, 2**31, 2**32 - 1):
        r = P.R_MIN_INT + ((P.R_SPAN_INT * x) >> KDF_WORD_BITS)
        assert P.R_MIN_INT <= r <= P.R_MAX_INT


def test_all_derived_are_exact_ints():
    for name in ("ONE", "MASK", "HALF", "R_BITS", "R_MIN_INT", "R_SPAN_INT",
                 "R_MAX_INT", "CTR_MASK", "IDX_MAX", "N_MASK"):
        v = getattr(P, name)
        assert type(v) is int, name


def test_frozen():
    with pytest.raises(dataclasses.FrozenInstanceError):
        P.W = 24  # type: ignore[misc]


def test_replace_recomputes_derived():
    q = dataclasses.replace(P, W=24, N=16)
    assert q.ONE == 1 << 24
    assert q.MASK == (1 << 24) - 1
    assert q.R_BITS == 26
    assert q.R_MIN_INT == 1 << 24
    assert not q.kdf_supported


def test_n16_ok():
    q = dataclasses.replace(P, N=16)
    assert q.N_MASK == 0xFFFF


@pytest.mark.parametrize(
    "kw",
    [
        {"W": 7},
        {"W": 65},
        {"N": 12},
        {"N": 16, "W": 8},                 # N > W khong hop le (W=8 <16)
        {"RESEED_INTERVAL": 0},
        {"RESEED_INTERVAL": 65537},
        {"R_MIN": (3.6, 1)},               # float khong duoc phep
        {"R_MIN": (36, 0)},
        {"R_SPAN": (0, 10)},
        {"R_MIN": (39, 10), "R_SPAN": (4, 10)},   # r_max >= 4
        {"LABEL": b""},
        {"CTR_BITS": 16},
        {"IDX_BITS": 8},
        {"K_MASTER_BYTES": 16},
        {"FY_REFILL_WATCHDOG": 0},
    ],
)
def test_invalid_configs_rejected(kw):
    with pytest.raises(ValueError):
        dataclasses.replace(P, **kw)


def test_config_hash_stable_and_sensitive():
    assert P.config_hash() == CipherParams().config_hash()
    assert len(P.config_hash()) == 64
    assert dataclasses.replace(P, RESEED_INTERVAL=128).config_hash() != P.config_hash()
    assert dataclasses.replace(P, N=16).config_hash() != P.config_hash()


def test_to_dict_has_no_float():
    d = P.to_dict()
    assert d["SPEC_VERSION"] == SPEC_VERSION

    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, (list, tuple)):
            for x in v:
                walk(x)
        else:
            assert not isinstance(v, float)

    walk(d)


def test_old_range_still_expressible():
    # Dai cu [3.6, 4.0) van tao duoc bang tham so, de so sanh trong phan tich (analysis)
    old = dataclasses.replace(P, R_MIN=(36, 10), R_SPAN=(4, 10))
    assert old.R_MIN_INT == 15_461_882_265 and old.R_SPAN_INT == 1_717_986_918
    assert old.R_MAX_INT == 17_179_869_182


def test_trap_constants_and_version():
    from refmodel.params import TRAP_MAX, X0_MIN
    assert (TRAP_MAX, X0_MIN) == (1, 2)
    assert SPEC_VERSION == "1.0.0"
    assert P.to_dict()["TRAP_MAX"] == 1
