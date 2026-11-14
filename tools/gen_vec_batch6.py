"""gen_vec_batch6.py - vector golden cho dot 6 (sample_fmt, test_src), lay tu refmodel/audio.py. Chay tu goc PBL5:

    python tools/gen_vec_batch6.py                       # ghi vao tb/vectors
    python tools/gen_vec_batch6.py --out <thu_muc>

Sinh ra (tat dinh):
  fmt_vec.hex   sample_fmt, moi dong = 1 mau dua vao (vld = 1)                                  84 bit:
                [83] hop_le [82] 0 [81] clr (W xoa CLIP_CNT cung chu ky) [80] clip [79:76] shift [75:52] s24
                [51:36] s16 mong doi [35:4] CLIP_CNT 32 bit sau mau nay [3:0] CLIP_CNT cua ban CW = 4 (bao hoa o 15)
  tsrc_cfg.hex  cac ca test_src                                                                  64 bit:
                [63] hop_le [62:60] 0 [59:58] mode [57:56] 0 [55:44] sck_div [43:32] div_hieu_dung [31:16] 0 [15:0] so mau
  tsrc_exp.hex  mau mong doi, noi tiep cac ca                                                    32 bit:
                [31:16] mau cua DUT mac dinh (RAMP_INIT = 0, SINE_INC 1 kHz)
                [15:0]  mau cua DUT thu hai: RAMP_INIT = 0xFFF8 (kiem quay vong) va SINE_INC = 2^24 (moi mau
                        sang 1 o bang -> quet ca 256 o; buoc 1 kHz chi di qua 125 o)
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from refmodel import audio as A  # noqa: E402

RAMP_INIT_B = 0xFFF8
SINE_INC_B = 1 << 24


def gen_fmt(seed=66):
    rng = random.Random(seed)
    rows = []                                       # (clr, shift, s24)
    for shift in range(16):
        s = min(shift, 8)
        vals = [0, 1, -1, 0x7FFFFF, -0x800000, 255, 256, -256, -257]
        if s >= 1:
            b = 32768 << (8 - s)
            vals += [b - 1, b, b + 1, -b, -b - 1, -b + 1]
        vals += [rng.randrange(-(1 << 23), 1 << 23) for _ in range(30)]
        vals += [rng.randrange(-(1 << 15) << (8 - s), (1 << 15) << (8 - s)) for _ in range(10)]   # quanh nguong
        for v in vals:
            rows.append((0, shift, v))
    # chen lenh xoa: o mau bi bao hoa va o mau khong bao hoa
    for i in (40, 333, 334, 500, len(rows) - 5):
        c, sh, v = rows[i]
        rows[i] = (1, sh, v)
    rows.append((1, 8, 0x7FFFFF))                  # xoa + bao hoa cung chu ky: dem = 1
    rows.append((0, 0, 0))

    out, cnt, cnt4 = [], 0, 0
    for clr, shift, s24 in rows:
        y, clip = A.sample_fmt(s24, shift)
        cnt = (0 if clr else cnt) + int(clip)
        cnt = min(cnt, 0xFFFFFFFF)
        cnt4 = min((0 if clr else cnt4) + int(clip), 15)
        v = (1 << 83) | (clr << 81) | (int(clip) << 80) | (shift << 76) | ((s24 & 0xFFFFFF) << 52) \
            | (A.u16(y) << 36) | (cnt << 4) | cnt4
        out.append(f"{v:021x}")
    return out


# (mode, sck_div, so mau)   mode: 1 RAMP, 2 SINE; 0 / 3 = khong phai nguon thu -> phai im lang
TSRC_CASES = [
    (1, 24, 40),
    (2, 24, 40),
    (2, 3, 2000),          # nhieu chu ky sin, pha 32 bit quay vong nhieu lan
    (1, 0, 300),           # SCK_DIV = 0 kep len 3
    (3, 3, 0),             # REG: test_src im lang
    (0, 3, 0),             # MIC: test_src im lang
    (2, 7, 100),           # bat lai: pha ve 0
    (1, 5, 30),            # bat lai: RAMP ve RAMP_INIT
]


def gen_tsrc():
    cfg, exp = [], []
    for mode, div, n in TSRC_CASES:
        eff = A.sck_div_eff(div)
        cfg.append(f"{(1 << 63) | (mode << 58) | (div << 44) | (eff << 32) | n:016x}")
        if mode == 1:
            a, b = A.ramp(n), A.ramp(n, RAMP_INIT_B)
        elif mode == 2:
            a = [A.u16(x) for x in A.sine(n)]
            b = [A.u16(x) for x in A.sine(n, inc=SINE_INC_B)]
        else:
            a = b = []
        exp += [f"{(x << 16) | y:08x}" for x, y in zip(a, b)]
    return cfg, exp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tb/vectors")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    def wr(name, rows):
        with open(os.path.join(a.out, name), "w", newline="\n") as f:
            f.write("\n".join(rows) + "\n")
        print(f"  {name:14s} {len(rows):6d} dong")

    print("dot 6 -> " + a.out)
    wr("fmt_vec.hex", gen_fmt())
    cfg, exp = gen_tsrc()
    wr("tsrc_cfg.hex", cfg)
    wr("tsrc_exp.hex", exp)


if __name__ == "__main__":
    main()
