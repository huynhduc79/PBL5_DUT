"""Test cho audio.py (sample_fmt, test_src, nhip fs) - doi chieu voi docs/HOP_DONG_FPGA_RTOS.md."""

import math

import pytest

from refmodel import audio as A


def test_sine_lut_matches_formula():
    assert len(A.SINE_LUT) == 256
    for k, v in enumerate(A.SINE_LUT):
        assert v == math.floor(A.SINE_AMPL * math.sin(2 * math.pi * k / 256) + 0.5)
    assert max(A.SINE_LUT) == 0x4000 and min(A.SINE_LUT) == -0x4000


def test_sine_inc_is_1khz_at_default_fs():
    assert A.SINE_INC == round(2**32 * 1000 / 15625)
    f = A.fs_milli_hz(24) / 1000 * A.SINE_INC / 2**32
    assert abs(f - 1000.0) < 1e-3


def test_fs_contract_values():
    assert A.sample_period_clk(24) == 3200
    assert A.fs_milli_hz(24) == 15_625_000                # dung gia tri ghi trong header .chau
    assert A.sample_period_clk(0) == A.sample_period_clk(3) == 512


@pytest.mark.parametrize("shift", range(0, 16))
def test_sample_fmt_definition(shift):
    s = min(shift, 8)
    for s24 in (0, 1, -1, 0x7FFFFF, -0x800000, 255, 256, -256, -257, 0x12345, -0x12345):
        y, c = A.sample_fmt(s24, shift)
        x = math.floor(s24 / 2 ** (8 - s))
        assert y == max(-32768, min(32767, x))
        assert c == (x != y)


def test_sample_fmt_shift0_is_top16_never_clips():
    for s24 in range(-(1 << 23), 1 << 23, 4099):
        y, c = A.sample_fmt(s24, 0)
        assert not c and y == (A.s24_from_u(s24 & 0xFFFFFF) >> 8)


def test_sample_fmt_clip_boundaries():
    for s in range(1, 9):
        b = 32768 << (8 - s)                             # s24 nho nhat bi bao hoa duong
        assert A.sample_fmt(b - 1, s) == (32767, False)
        assert A.sample_fmt(b, s) == (32767, True)
        assert A.sample_fmt(-b, s) == (-32768, False)
        assert A.sample_fmt(-b - 1, s) == (-32768, True)


def test_sample_fmt_rejects_out_of_range():
    with pytest.raises(ValueError):
        A.sample_fmt(1 << 23, 0)


def test_ramp_and_wrap():
    assert A.ramp(4) == [0, 1, 2, 3]
    assert A.ramp(4, 0xFFFE) == [0xFFFE, 0xFFFF, 0, 1]


def test_sine_start_and_period():
    s = A.sine(32)
    assert s[0] == 0
    # 15,625 mau / chu ky: sau 16 mau pha vuot qua 2^32 mot chut
    assert s[1] == A.SINE_LUT[A.SINE_INC >> 24]
    assert A.sine(5, phase0=0x40000000)[0] == 0x4000


def test_sine_default_inc_visits_only_125_entries():
    # Ly do testbench can them mot DUT voi SINE_INC = 2^24: buoc 1 kHz chi di qua 125 / 256 o bang.
    ph, seen = 0, set()
    for _ in range(5000):
        seen.add(ph >> 24)
        ph = (ph + A.SINE_INC) & 0xFFFFFFFF
    assert len(seen) == 125
    assert A.sine(256, inc=1 << 24) == list(A.SINE_LUT)


def test_s24_from_u():
    assert A.s24_from_u(0x800000) == -(1 << 23)
    assert A.s24_from_u(0x7FFFFF) == (1 << 23) - 1
    assert A.s24_from_u(0xFFFFFF) == -1
