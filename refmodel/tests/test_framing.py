"""Test cho framing.py: CRC-16-CCITT, khung, payload, FrameDecoder, va chay thu qua kenh co loi."""

import binascii
import dataclasses
import random

import pytest

from refmodel.cipher import CipherCore
from refmodel.framing import (
    CRC_BYTES,
    CTR_BYTES,
    HEADER_LEN,
    IDX_BYTES,
    SYNC,
    Frame,
    FrameDecoder,
    FrameError,
    crc16_ccitt,
    crc16_update,
    frame_length,
    pack_frame,
    pack_payload,
    parse_frame,
    parse_payload,
)
from refmodel.params import DEFAULT_PARAMS

KM = bytes(range(32))


# ------------------------------------------------------------------ CRC
def test_crc_check_value_ccitt_false():
    assert crc16_ccitt(b"123456789") == 0x29B1          # CRC-16/CCITT-FALSE
    assert crc16_ccitt(b"") == 0xFFFF                   # = gia tri dau


def test_crc_matches_stdlib_crc_hqx():
    rnd = random.Random(1)
    for _ in range(300):
        data = bytes(rnd.randrange(256) for _ in range(rnd.randrange(0, 40)))
        assert crc16_ccitt(data) == binascii.crc_hqx(data, 0xFFFF)


def test_crc_residue_zero_when_crc_appended():
    rnd = random.Random(2)
    for _ in range(100):
        data = bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 30)))
        assert crc16_ccitt(data + crc16_ccitt(data).to_bytes(2, "big")) == 0


def test_crc_update_is_incremental():
    data = b"\x01\x02\xfe\xff"
    crc = 0xFFFF
    for b in data:
        crc = crc16_update(crc, b)
    assert crc == crc16_ccitt(data)


# ------------------------------------------------------------------ bo cuc khung
def test_constants_match_params():
    p = DEFAULT_PARAMS
    assert CTR_BYTES == p.CTR_BITS // 8 and IDX_BYTES == p.IDX_BITS // 8
    assert HEADER_LEN == 7 and CRC_BYTES == 2 and SYNC == 0xAA


def test_frame_layout_n8():
    f = pack_frame(0x01020304, 0x0506, 8, 0x07)
    body = bytes.fromhex("01020304" "0506" "08" "07")
    assert f[:-2] == bytes([0xAA]) + body
    assert f[-2:] == binascii.crc_hqx(body, 0xFFFF).to_bytes(2, "big")
    assert f.hex() == "aa0102030405060807a643"          # co dinh (CRC tinh doc lap bang crc_hqx)
    assert len(f) == frame_length(8) == 11


def test_frame_layout_n16():
    f = pack_frame(1, 2, 16, 0xABCD)
    assert f.hex() == "aa00000001000210abcd3abc"
    assert len(f) == frame_length(16) == 12


def test_payload_layout_for_ethernet():
    pl = pack_payload(0x01020304, 0x0506, 8, 0x07)
    assert pl.hex() == "01020304050608" "07"
    assert len(pl) == 8 and len(pack_payload(1, 2, 16, 3)) == 9
    assert parse_payload(pl) == Frame(0x01020304, 0x0506, 8, 7)


def test_pack_parse_roundtrip_random():
    rnd = random.Random(3)
    for _ in range(2000):
        n = rnd.choice((8, 16))
        fr = Frame(rnd.randrange(2**32), rnd.randrange(2**16), n, rnd.randrange(1 << n))
        assert parse_frame(pack_frame(*fr)) == fr
        assert parse_payload(pack_payload(*fr)) == fr


def test_pack_validation():
    with pytest.raises(ValueError):
        pack_frame(2**32, 0, 8, 0)
    with pytest.raises(ValueError):
        pack_frame(-1, 0, 8, 0)
    with pytest.raises(ValueError):
        pack_frame(0, 2**16, 8, 0)
    with pytest.raises(ValueError):
        pack_frame(0, 0, 12, 0)
    with pytest.raises(ValueError):
        pack_frame(0, 0, 8, 256)
    with pytest.raises(ValueError):
        pack_frame(0, 0, 8, True)
    with pytest.raises(ValueError):
        pack_frame(1.0, 0, 8, 0)
    with pytest.raises(ValueError):
        frame_length(9)


def test_parse_frame_error_reasons():
    good = pack_frame(5, 6, 8, 0x42)

    def reason(data):
        with pytest.raises(FrameError) as e:
            parse_frame(data)
        return e.value.reason

    assert reason(b"\x00" + good[1:]) == "sync"
    assert reason(good[:5]) == "length"
    assert reason(good + b"\x00") == "length"
    bad_n = bytearray(good); bad_n[HEADER_LEN] = 9
    assert reason(bytes(bad_n)) == "n"
    bad_crc = bytearray(good); bad_crc[-1] ^= 1
    assert reason(bytes(bad_crc)) == "crc"
    # N doi tu 8 sang 16 (do dai khop khung 12 byte) van bi CRC bat
    n_flip = bytearray(pack_frame(5, 6, 16, 0x4242)); n_flip[HEADER_LEN] = 8
    assert reason(bytes(n_flip[:-1])) in ("crc", "length")


def test_every_single_and_double_bit_error_detected_n8_and_n16():
    for n, c in ((8, 0x5A), (16, 0xC3A5)):
        good = pack_frame(0x12345678, 0x00FF, n, c)
        nbits = len(good) * 8
        for a in range(nbits):
            bad = bytearray(good); bad[a // 8] ^= 1 << (a % 8)
            with pytest.raises(FrameError):
                parse_frame(bytes(bad))
        for a in range(nbits):
            for b in range(a + 1, nbits):
                bad = bytearray(good)
                bad[a // 8] ^= 1 << (a % 8)
                bad[b // 8] ^= 1 << (b % 8)
                with pytest.raises(FrameError):
                    parse_frame(bytes(bad))


# ------------------------------------------------------------------ FrameDecoder
def _frames(count, seed=0):
    rnd = random.Random(seed)
    out = []
    for _ in range(count):
        n = rnd.choice((8, 16))
        out.append(Frame(rnd.randrange(2**32), rnd.randrange(2**16), n, rnd.randrange(1 << n)))
    return out


def test_decoder_back_to_back_and_chunking_invariant():
    frs = _frames(300, seed=4)
    stream = b"".join(pack_frame(*f) for f in frs)
    d = FrameDecoder()
    assert d.feed(stream) == frs and d.dropped_bytes == 0
    for chunk in (1, 2, 3, 7, 11, 50):
        d = FrameDecoder()
        got = []
        for i in range(0, len(stream), chunk):
            got += d.feed(stream[i:i + chunk])
        assert got == frs, chunk
        assert d.frames_ok == len(frs) and d.dropped_bytes == 0


def test_decoder_handles_sync_byte_inside_payload():
    frs = [Frame(0xAAAAAAAA, 0xAAAA, 8, 0xAA), Frame(0x00AA00AA, 0xAA00, 16, 0xAAAA)]
    stream = b"".join(pack_frame(*f) for f in frs) * 3
    assert FrameDecoder().feed(stream) == frs * 3


def test_decoder_skips_garbage_prefix_and_between_frames():
    frs = _frames(50, seed=5)
    rnd = random.Random(6)
    stream = b""
    garbage = 0
    for f in frs:
        junk = bytes(rnd.randrange(256) for _ in range(rnd.randrange(0, 9)))
        stream += junk + pack_frame(*f)
        garbage += len(junk)
    d = FrameDecoder()
    got = d.feed(stream)
    assert got[-1] == frs[-1]
    assert set(frs) <= set(got)                          # khong mat khung hop le (rac co the them khung gia, xac suat ~2^-16)
    assert d.frames_ok == len(got)


def test_decoder_recovers_after_corrupted_frame():
    f1, f2, f3 = _frames(3, seed=7)
    bad = bytearray(pack_frame(*f2)); bad[5] ^= 0x40
    d = FrameDecoder()
    got = d.feed(pack_frame(*f1) + bytes(bad) + pack_frame(*f3))
    assert got == [f1, f3]
    assert d.crc_errors >= 1 and d.frames_ok == 2


def test_decoder_waits_for_partial_frame():
    f = Frame(9, 9, 16, 0x1234)
    raw = pack_frame(*f)
    d = FrameDecoder()
    assert d.feed(raw[:5]) == []                         # chua doc duoc N
    assert d.feed(raw[5:9]) == []                        # co N, chua du khung
    assert d.feed(raw[9:]) == [f]
    assert d.dropped_bytes == 0


def test_decoder_corrupted_n_does_not_eat_following_frames():
    a, b, c = Frame(1, 1, 8, 0x11), Frame(2, 2, 16, 0x2222), Frame(3, 3, 8, 0x33)
    bad = bytearray(pack_frame(*a))
    bad[HEADER_LEN] = 16                                 # N 8 -> 16: khung gia dai 12 thay vi 11
    d = FrameDecoder()
    assert d.feed(bytes(bad) + pack_frame(*b) + pack_frame(*c)) == [b, c]
    assert d.crc_errors >= 1


def test_decoder_false_sync_prefix_does_not_hide_real_frames():
    frs = _frames(60, seed=11)
    rnd = random.Random(12)
    stream = b"".join(
        bytes([SYNC]) + bytes(rnd.randrange(256) for _ in range(rnd.randrange(0, 12))) + pack_frame(*f)
        for f in frs
    )
    d = FrameDecoder()
    got = d.feed(stream)
    assert set(frs) <= set(got)
    assert d.crc_errors > 0                              # co thu ung vien sai that su


def test_decoder_bad_n_counter():
    d = FrameDecoder()
    d.feed(bytes([SYNC]) + bytes(HEADER_LEN))            # N = 0 khong hop le
    assert d.bad_n == 1


# ------------------------------------------------------------------ chay thu: ma hoa -> khung -> kenh loi -> giai ma
def _run_link(n, reseed, seed):
    p = dataclasses.replace(DEFAULT_PARAMS, N=n, RESEED_INTERVAL=reseed)
    rnd = random.Random(seed)
    plain = [rnd.randrange(1 << n) for _ in range(600)]
    tx = CipherCore(KM, p)
    sent = {}
    wire = bytearray()
    for v in plain:
        r = tx.encrypt(v)
        sent[(r.ctr, r.idx)] = v
        raw = bytearray(pack_frame(r.ctr, r.idx, n, r.c))
        roll = rnd.random()
        if roll < 0.10:
            continue                                      # mat ca khung
        if roll < 0.20:
            raw[rnd.randrange(len(raw))] ^= 1 << rnd.randrange(8)   # hong 1 bit
        if roll < 0.25:
            wire += bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 6)))  # rac chen vao
        wire += raw

    dec = FrameDecoder()
    rx = None
    ok = 0
    for i in range(0, len(wire), 13):                    # chunk le
        for fr in dec.feed(bytes(wire[i:i + 13])):
            assert fr.n == n
            if rx is None or (fr.ctr, fr.idx) != rx.position:
                rx = CipherCore(KM, p, ctr0=fr.ctr)      # dong bo lai bang (ctr, idx)
                rx.advance(fr.idx)
            got = rx.decrypt(fr.c)
            assert got == sent[(fr.ctr, fr.idx)], (fr.ctr, fr.idx)
            ok += 1
    return ok, dec


@pytest.mark.parametrize("n,reseed", [(8, 256), (8, 40), (16, 64)])
def test_link_decrypts_every_delivered_frame_despite_loss_and_noise(n, reseed):
    ok, dec = _run_link(n, reseed, seed=n * 100 + reseed)
    assert ok > 400                                       # ~ 90% - hong 1 bit (~10%) -> ~ 480 khung toi noi
    assert dec.frames_ok == ok
    assert dec.crc_errors > 20                            # kenh that su gay loi va CRC bat duoc