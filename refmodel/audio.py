"""audio.py - golden model cho lop vo am thanh phia truoc loi ma hoa (sample_fmt, test_src, nhip fs).

Nguon: docs/HOP_DONG_FPGA_RTOS.md (muc "24 -> 16 bit", SRC_SEL, I2S).  Moi gia tri la so nguyen.

  sample_fmt:  s16 = bao_hoa_16(s24 >>> (8 - SHIFT)),  SHIFT = 0..8 (SHIFT > 8 duoc kep ve 8).
               ">>>" la dich phai so hoc (lam tron ve -vo cung). clip = 1 khi phai bao hoa.
  test_src:    RAMP: 0, 1, 2, ... (16 bit, quay vong 0xFFFF -> 0).  Khong qua sample_fmt, de ban giai ma
               phai ra dung 0, 1, 2, ...
               SINE: bo tich luy pha 32 bit, pha += SINE_INC moi mau; mau = SINE_LUT[pha >> 24].
               SINE_INC = round(2^32 * 1000 / 15625) -> 1000,000 Hz o fs = 15 625 Hz (SCK_DIV = 24).
               Bien do 0x4000 (= 16384), tuc -6 dBFS: duong di du lieu khong bao gio cham bao hoa.
               Ca hai bat dau lai (RAMP = 0, pha = 0) moi lan ENABLE.
  nhip fs:     mot mau moi 128 * (SCK_DIV_eff + 1) chu ky clk, SCK_DIV_eff = max(SCK_DIV, MIN_SCK_DIV).
               test_src dung CUNG nhip voi i2s_rx, nen luong du lieu phia sau giong het che do micro.
"""

from __future__ import annotations

MIN_SCK_DIV = 3
SHIFT_MAX = 8
S16_MAX = 0x7FFF
S16_MIN = -0x8000

SINE_AMPL = 0x4000
SINE_INC = 274_877_907                        # round(2^32 * 1000 / 15625)
PHASE_BITS = 32
LUT_BITS = 8

# SINE_LUT[k] = floor(16384 * sin(2*pi*k/256) + 0.5). Viet san thanh hang so de khong phu thuoc float luc chay;
# tests/test_audio.py kiem lai bang cong thuc.
SINE_LUT = (
         0,    402,    804,   1205,   1606,   2006,   2404,   2801,   3196,   3590,   3981,   4370,   4756,   5139,   5520,   5897,
      6270,   6639,   7005,   7366,   7723,   8076,   8423,   8765,   9102,   9434,   9760,  10080,  10394,  10702,  11003,  11297,
     11585,  11866,  12140,  12406,  12665,  12916,  13160,  13395,  13623,  13842,  14053,  14256,  14449,  14635,  14811,  14978,
     15137,  15286,  15426,  15557,  15679,  15791,  15893,  15986,  16069,  16143,  16207,  16261,  16305,  16340,  16364,  16379,
     16384,  16379,  16364,  16340,  16305,  16261,  16207,  16143,  16069,  15986,  15893,  15791,  15679,  15557,  15426,  15286,
     15137,  14978,  14811,  14635,  14449,  14256,  14053,  13842,  13623,  13395,  13160,  12916,  12665,  12406,  12140,  11866,
     11585,  11297,  11003,  10702,  10394,  10080,   9760,   9434,   9102,   8765,   8423,   8076,   7723,   7366,   7005,   6639,
      6270,   5897,   5520,   5139,   4756,   4370,   3981,   3590,   3196,   2801,   2404,   2006,   1606,   1205,    804,    402,
         0,   -402,   -804,  -1205,  -1606,  -2006,  -2404,  -2801,  -3196,  -3590,  -3981,  -4370,  -4756,  -5139,  -5520,  -5897,
     -6270,  -6639,  -7005,  -7366,  -7723,  -8076,  -8423,  -8765,  -9102,  -9434,  -9760, -10080, -10394, -10702, -11003, -11297,
    -11585, -11866, -12140, -12406, -12665, -12916, -13160, -13395, -13623, -13842, -14053, -14256, -14449, -14635, -14811, -14978,
    -15137, -15286, -15426, -15557, -15679, -15791, -15893, -15986, -16069, -16143, -16207, -16261, -16305, -16340, -16364, -16379,
    -16384, -16379, -16364, -16340, -16305, -16261, -16207, -16143, -16069, -15986, -15893, -15791, -15679, -15557, -15426, -15286,
    -15137, -14978, -14811, -14635, -14449, -14256, -14053, -13842, -13623, -13395, -13160, -12916, -12665, -12406, -12140, -11866,
    -11585, -11297, -11003, -10702, -10394, -10080,  -9760,  -9434,  -9102,  -8765,  -8423,  -8076,  -7723,  -7366,  -7005,  -6639,
     -6270,  -5897,  -5520,  -5139,  -4756,  -4370,  -3981,  -3590,  -3196,  -2801,  -2404,  -2006,  -1606,  -1205,   -804,   -402,
)


def s24_from_u(u: int) -> int:
    """24 bit khong dau (nhu tren day I2S) -> so co dau."""
    u &= 0xFFFFFF
    return u - (1 << 24) if u & 0x800000 else u


def u16(x: int) -> int:
    return x & 0xFFFF


def sample_fmt(s24: int, shift: int) -> tuple[int, bool]:
    """(s16 co dau, clip). s24 co dau trong [-2^23, 2^23); shift 0..15 (> 8 kep ve 8)."""
    if not -(1 << 23) <= s24 < (1 << 23):
        raise ValueError("s24 ngoai mien 24 bit")
    s = min(shift, SHIFT_MAX)
    x = s24 >> (SHIFT_MAX - s)                 # Python >> tren so am = dich so hoc
    if x > S16_MAX:
        return S16_MAX, True
    if x < S16_MIN:
        return S16_MIN, True
    return x, False


def ramp(n: int, start: int = 0) -> list[int]:
    """n mau RAMP (u16), bat dau tu start."""
    return [(start + i) & 0xFFFF for i in range(n)]


def sine(n: int, phase0: int = 0, inc: int = SINE_INC) -> list[int]:
    """n mau SINE (co dau), pha ban dau phase0, buoc pha inc (mac dinh 1 kHz; inc = 2^24 quet tung o cua bang)."""
    out, ph = [], phase0 & 0xFFFFFFFF
    for _ in range(n):
        out.append(SINE_LUT[ph >> (PHASE_BITS - LUT_BITS)])
        ph = (ph + inc) & 0xFFFFFFFF
    return out


def sck_div_eff(sck_div: int) -> int:
    return max(sck_div & 0xFFF, MIN_SCK_DIV)


def sample_period_clk(sck_div: int) -> int:
    """So chu ky clk giua hai mau (cho ca i2s_rx va test_src)."""
    return 128 * (sck_div_eff(sck_div) + 1)


def fs_milli_hz(sck_div: int, clk_hz: int = 50_000_000) -> int:
    """fs x 1000 (truong fs_milli_hz trong header .chau), lam tron xuong."""
    return clk_hz * 1000 // sample_period_clk(sck_div)
