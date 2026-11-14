"""Test cho kdf.py: KAT (FIPS 180-4, RFC 4231), HMAC doc lap tu FIPS 198-1, cong thuc (4.4)-(4.6)."""

import dataclasses
import hashlib
import random

import pytest

from oracle import hmac_fips198, oracle_params
from refmodel.kdf import (
    derive_lts_params,
    derive_session_key,
    hmac_sha256,
    params_from_session_key,
    session_message,
    split_words,
)
from refmodel.params import DEFAULT_PARAMS

P = DEFAULT_PARAMS
KM = bytes(range(32))

# RFC 4231, HMAC-SHA-256, test case 1-4
RFC4231 = [
    (b"\x0b" * 20, b"Hi There",
     "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
    (b"Jefe", b"what do ya want for nothing?",
     "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
    (b"\xaa" * 20, b"\xdd" * 50,
     "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"),
    (bytes(range(1, 26)), b"\xcd" * 50,
     "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"),
]


def test_sha256_abc_kat():
    # FIPS 180-4 / muc 3.2.4
    assert hashlib.sha256(b"abc").hexdigest() == (
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


@pytest.mark.parametrize("key,msg,expected", RFC4231)
def test_hmac_rfc4231(key, msg, expected):
    assert hmac_sha256(key, msg).hex() == expected
    assert hmac_fips198(key, msg).hex() == expected      # ban doc lap tu FIPS 198-1


def test_session_message_is_label_plus_ctr_big_endian():
    assert session_message(0, P) == b"session\x00\x00\x00\x00"
    assert session_message(1, P) == b"session\x00\x00\x00\x01"
    assert session_message(0x01020304, P) == b"session\x01\x02\x03\x04"
    assert session_message(2**32 - 1, P) == b"session\xff\xff\xff\xff"


def test_split_words_big_endian():
    ks = bytes(range(32))
    w = split_words(ks)
    assert len(w) == 8
    assert w[0] == 0x00010203 and w[7] == 0x1C1D1E1F
    with pytest.raises(ValueError):
        split_words(b"\x00" * 31)


def test_pinned_session_key_and_params():
    # Gia tri sinh bang oracle doc lap (tests/oracle.py), dong bang de chong thay doi ngam.
    sp = derive_lts_params(KM, 0, P)
    assert sp.k_session.hex() == "7297ddc0ec2f11429742b90b88b414de7230d5e4a96cf90606d421da6ca9e5ea"
    assert sp.x0 == 0x814E6157
    assert sp.r_int == 7_266_756_818
    sp1 = derive_lts_params(KM, 1, P)
    assert sp1.x0 == 0xE8ECE838 and sp1.r_int == 4_354_086_344


def test_matches_independent_oracle():
    for ctr in (0, 1, 2, 255, 256, 65535, 2**31, 2**32 - 1):
        for km in (KM, b"\x00" * 32, b"\xff" * 32):
            sp = derive_lts_params(km, ctr, P)
            ks, x0, r = oracle_params(km, ctr)
            assert (sp.k_session, sp.x0, sp.r_int) == (ks, x0, r)


def test_x0_and_r_ranges_over_many_ctr():
    for ctr in range(2000):
        sp = derive_lts_params(KM, ctr, P)
        assert 2 <= sp.x0 <= P.MASK                       # X0 >= 2 (bay <= 1)
        assert P.R_MIN_INT <= sp.r_int <= P.R_MAX_INT


def test_params_from_session_key_edges():
    # x0: w1^w2^w3^w4 < 2 -> x0 = 2 (4.5)
    w = (0xAAAAAAAA, 0xAAAAAAAA, 0x12345678, 0x12345678)   # xor = 0
    ks = b"".join(v.to_bytes(4, "big") for v in w + (0, 0, 0, 0))
    x0, r = params_from_session_key(ks, P)
    assert x0 == 2 and r == P.R_MIN_INT                     # x = 0 -> r_min
    ks = b"".join(v.to_bytes(4, "big") for v in (1, 0, 0, 0, 0, 0, 0, 0))   # xor = 1 -> cung < 2
    assert params_from_session_key(ks, P)[0] == 2
    ks = b"".join(v.to_bytes(4, "big") for v in (2, 0, 0, 0, 0, 0, 0, 0))   # xor = 2 giu nguyen
    assert params_from_session_key(ks, P)[0] == 2
    ks = b"".join(v.to_bytes(4, "big") for v in (3, 0, 0, 0, 0, 0, 0, 0))
    assert params_from_session_key(ks, P)[0] == 3
    # x lon nhat -> r_max
    ks = b"".join(v.to_bytes(4, "big") for v in (0, 0, 0, 5, 0xFFFFFFFF, 0, 0, 0))
    x0, r = params_from_session_key(ks, P)
    assert x0 == 5 and r == P.R_MAX_INT
    # x = 2^31 -> r nam giua
    ks = b"".join(v.to_bytes(4, "big") for v in (7, 0, 0, 0, 0x80000000, 0, 0, 0))
    _, r = params_from_session_key(ks, P)
    assert r == P.R_MIN_INT + (P.R_SPAN_INT >> 1)


def test_r_int_is_2_pow_32_plus_x_for_default_range():
    # Dai r = [1, 2) voi W = 32: R_MIN_INT = R_SPAN_INT = 2^32 nen r_int = 2^32 + x (khong can phep nhan)
    rnd = random.Random(1)
    for _ in range(200):
        ws = [rnd.randrange(2**32) for _ in range(8)]
        ks = b"".join(v.to_bytes(4, "big") for v in ws)
        _, r = params_from_session_key(ks, P)
        assert r == (1 << 32) + (ws[4] ^ ws[5] ^ ws[6] ^ ws[7])


def test_different_ctr_gives_different_keys():
    keys = {derive_session_key(KM, c, P) for c in range(500)}
    assert len(keys) == 500


def test_input_validation():
    with pytest.raises(ValueError):
        derive_lts_params(KM, -1, P)
    with pytest.raises(ValueError):
        derive_lts_params(KM, 2**32, P)
    with pytest.raises(ValueError):
        derive_lts_params(KM[:31], 0, P)
    with pytest.raises(TypeError):
        derive_lts_params("k" * 32, 0, P)          # type: ignore[arg-type]
    with pytest.raises(ValueError):
        derive_lts_params(KM, True, P)             # bool khong phai ctr
    with pytest.raises(ValueError):
        derive_lts_params(KM, 0, dataclasses.replace(P, W=24))   # KDF chi cho W = 32
