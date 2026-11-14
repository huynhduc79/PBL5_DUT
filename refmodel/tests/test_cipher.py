"""Test cho cipher.py: round-trip, doi chieu oracle doc lap, dong bo/mat goi, trace, thong ke."""

import dataclasses
import random
from collections import Counter

import pytest

from oracle import OracleCipher
from refmodel.cipher import CipherCore, SessionManager
from refmodel.kdf import derive_lts_params
from refmodel.params import DEFAULT_PARAMS

P = DEFAULT_PARAMS
KM = bytes(range(32))


def params(**kw):
    return dataclasses.replace(P, **kw)


# ------------------------------------------------------------------ doi chieu oracle
def test_pinned_ciphertext_from_oracle():
    # Gia tri sinh bang OracleCipher (tests/oracle.py): HMAC tu FIPS 198-1, LTS bang Fraction,
    # Fisher-Yates bang chuoi bit. Dong bang de chong thay doi ngam.
    plain = list(range(16)) + [255, 0, 128, 1]
    expected = [208, 119, 11, 77, 140, 172, 8, 29, 52, 111,
                195, 74, 12, 194, 107, 84, 93, 208, 164, 104]
    core = CipherCore(KM)
    assert [core.encrypt(x).c for x in plain] == expected


@pytest.mark.parametrize("n,reseed", [(8, 64), (8, 37), (8, 1), (16, 64), (16, 29)])
def test_matches_oracle_across_reseeds(n, reseed):
    rnd = random.Random(n * 1000 + reseed)
    p = params(N=n, RESEED_INTERVAL=reseed)
    core = CipherCore(KM, p)
    orc = OracleCipher(KM, n=n, reseed=reseed)
    count = 700 if reseed != 1 else 120
    for _ in range(count):
        v = rnd.randrange(1 << n)
        assert tuple(core.encrypt(v)) == orc.encrypt(v)


def test_matches_oracle_decrypt_and_other_keys():
    rnd = random.Random(31)
    for km in (b"\x00" * 32, b"\xff" * 32, bytes(rnd.randrange(256) for _ in range(32))):
        p = params(RESEED_INTERVAL=50)
        enc, dec = CipherCore(km, p), CipherCore(km, p)
        orc = OracleCipher(km, reseed=50)
        for _ in range(160):
            v = rnd.randrange(256)
            c = enc.encrypt(v).c
            assert c == orc.encrypt(v)[0]
            assert dec.decrypt(c) == v


# ------------------------------------------------------------------ round-trip
@pytest.mark.parametrize("n", [8, 16])
@pytest.mark.parametrize("reseed", [64, 16, 3])
def test_roundtrip(n, reseed):
    rnd = random.Random(n + reseed)
    p = params(N=n, RESEED_INTERVAL=reseed)
    a, b = CipherCore(KM, p), CipherCore(KM, p)
    plain = [rnd.randrange(1 << n) for _ in range(1500)]
    cipher = [a.encrypt(v).c for v in plain]
    assert [b.decrypt(c) for c in cipher] == plain
    assert a.position == b.position


def test_ciphertext_differs_from_plaintext_mostly():
    core = CipherCore(KM)
    same = sum(core.encrypt(0x5A).c == 0x5A for _ in range(2000))
    assert same < 40                      # ky vong ~ 2000/256 ~ 8


def test_equal_plaintexts_give_varying_ciphertext():
    core = CipherCore(KM)
    cs = {core.encrypt(0x00).c for _ in range(400)}
    assert len(cs) > 150


# ------------------------------------------------------------------ vi tri (ctr, idx)
def test_position_progression_and_reseed():
    p = params(RESEED_INTERVAL=4)
    core = CipherCore(KM, p, ctr0=10)
    seen = []
    for _ in range(10):
        r = core.encrypt(1)
        seen.append((r.ctr, r.idx))
    assert seen == [(10, 0), (10, 1), (10, 2), (10, 3), (11, 0), (11, 1), (11, 2), (11, 3), (12, 0), (12, 1)]
    assert core.position == (12, 2)


def test_default_reseed_interval_is_64():
    core = CipherCore(KM)
    for _ in range(64):
        core.encrypt(0)
    assert core.position == (1, 0)


def test_ctr_wraps_modulo_2_32():
    p = params(RESEED_INTERVAL=2)
    core = CipherCore(KM, p, ctr0=2**32 - 1)
    core.encrypt(0); core.encrypt(0)
    assert core.position == (0, 0)
    sp = derive_lts_params(KM, 0, p)
    assert core.session.x0 == sp.x0 and core.session.r_int == sp.r_int
    assert core.session.x == sp.x0


def test_session_resets_x_to_x0_on_reseed():
    p = params(RESEED_INTERVAL=3)
    s = SessionManager(KM, p)
    s.x = 12345
    assert s.update() is False and s.update() is False
    assert s.update() is True
    assert s.ctr == 1 and s.sample_count == 0
    assert s.x == s.x0                                  # X <- X0 cua phien moi (4.7)
    assert s.x0 == derive_lts_params(KM, 1, p).x0


# ------------------------------------------------------------------ dong bo, mat goi
def test_resync_after_packet_loss_with_advance():
    p = params(RESEED_INTERVAL=64)
    rnd = random.Random(8)
    plain = [rnd.randrange(256) for _ in range(500)]
    tx = CipherCore(KM, p)
    frames = [tx.encrypt(v) for v in plain]            # (c, ctr, idx)
    lost = set(range(150, 190)) | {300, 301, 450}
    rx_core = None
    out = {}
    for i, fr in enumerate(frames):
        if i in lost:
            continue
        if rx_core is None or (fr.ctr, fr.idx) != rx_core.position:
            # dong bo lai tu (ctr, idx) cua khung: khoi tao phien ctr roi chay bu idx mau
            rx_core = CipherCore(KM, p, ctr0=fr.ctr)
            rx_core.advance(fr.idx)
        out[i] = rx_core.decrypt(fr.c)
    assert all(out[i] == plain[i] for i in out)
    assert len(out) == 500 - len(lost)


def test_wrong_key_does_not_decrypt():
    enc = CipherCore(KM)
    cs = [enc.encrypt(v).c for v in range(64)]
    bad = bytearray(KM); bad[0] ^= 1
    dec = CipherCore(bytes(bad))
    out = [dec.decrypt(c) for c in cs]
    assert sum(a == b for a, b in zip(out, range(64))) < 8


def test_one_bit_key_change_changes_whole_stream():
    bad = bytearray(KM); bad[31] ^= 0x80
    a, b = CipherCore(KM), CipherCore(bytes(bad))
    diff = sum(a.encrypt(0).c != b.encrypt(0).c for _ in range(256))
    assert diff > 200


def test_decrypt_at_wrong_position_fails():
    enc, dec = CipherCore(KM), CipherCore(KM)
    cs = [enc.encrypt(v).c for v in range(64)]
    dec.advance(1)                                      # lech 1 mau
    out = [dec.decrypt(c) for c in cs]
    assert sum(a == b for a, b in zip(out, range(64))) < 8
    assert dec.position == (1, 1)                       # 65 mau da qua, phien 64 mau -> (ctr 1, idx 1)


# ------------------------------------------------------------------ kiem tra tham so
def test_sample_validation():
    core = CipherCore(KM)
    for bad in (-1, 256, 1.5, True, "a"):
        with pytest.raises(ValueError):
            core.encrypt(bad)                           # type: ignore[arg-type]
    with pytest.raises(ValueError):
        core.decrypt(256)
    assert CipherCore(KM, params(N=16)).encrypt(0xFFFF).c <= 0xFFFF


# ------------------------------------------------------------------ trace theo ten trang thai FSM
def test_trace_sequence_one_sample():
    tr = []
    core = CipherCore(KM, trace=tr)
    assert tr[0][0] == "RESEED_HMAC"                    # phien dau tien
    tr.clear()
    core.encrypt(0x3C)
    names = [e[0] for e in tr]
    assert names[0] == "LTS_KEYSTREAM"
    assert names[1] == "FY_INIT"
    assert names[-3:] == ["PERMUTE_XOR", "CHECK_RESEED", "DONE"]
    assert names.count("FY_SWAP") == 7
    assert "RESEED_HMAC" not in names


def test_trace_reseed_event_order():
    p = params(RESEED_INTERVAL=2)
    tr = []
    core = CipherCore(KM, p, trace=tr)
    core.encrypt(1)
    tr.clear()
    core.encrypt(2)                                     # mau thu 2 -> tai tao phien
    names = [e[0] for e in tr]
    assert names[-4:] == ["PERMUTE_XOR", "CHECK_RESEED", "RESEED_HMAC", "DONE"]
    _, data = tr[-2]
    assert data[0] == 1                                 # ctr moi


def test_trace_values_consistent_with_result():
    tr = []
    core = CipherCore(KM, trace=tr)
    tr.clear()
    r = core.encrypt(0x77)
    ev = {e[0]: e[1] for e in tr if e[0] in ("LTS_KEYSTREAM", "PERMUTE_XOR", "DONE")}
    x_in, x_out, k = ev["LTS_KEYSTREAM"]
    assert k == x_out & 0xFF
    pi, plain, shuffled, c = ev["PERMUTE_XOR"]
    assert plain == 0x77 and c == shuffled ^ k == r.c
    assert ev["DONE"] == (r.c,)


# ------------------------------------------------------------------ thong ke
def test_lts_steps_per_sample_about_two():
    core = CipherCore(KM)
    steps = []
    for v in range(5000):
        core.encrypt(v & 0xFF)
        steps.append(core.last_lts_steps)
    assert 2.0 <= sum(steps) / len(steps) <= 2.06       # 4.3.8: ~2 vong LTS moi mau (N=8)
    assert max(steps) <= 5


def test_ciphertext_of_constant_plaintext_is_uniform():
    # Co dinh P, nhieu phien: neu keystream lech (vd lay bit CAO cua X) thi chi-square vuot xa nguong.
    # df = 255, nguong p = 0.001 la 330.
    p = params(RESEED_INTERVAL=64)
    n_sessions, per = 1600, 64
    counts = Counter()
    for s in range(n_sessions):
        core = CipherCore(KM, p, ctr0=s * 7919)
        for _ in range(per):
            counts[core.encrypt(0xA5).c] += 1
    n = n_sessions * per
    e = n / 256
    chi2 = sum((counts.get(i, 0) - e) ** 2 / e for i in range(256))
    assert chi2 < 330, chi2
