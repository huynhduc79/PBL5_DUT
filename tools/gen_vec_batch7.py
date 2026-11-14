"""gen_vec_batch7.py - vector golden cho dot 7: audio_crypt_top (APB3 + I2S + loi + FIFO) chay tu dau den cuoi.
Chay tu thu muc goc PBL5:

    python tools/gen_vec_batch7.py                 # ghi vao tb/vectors
    python tools/gen_vec_batch7.py --out <thu_muc>

Golden: refmodel.cipher.CipherCore (N = 16, RESEED_INTERVAL = 64) + refmodel.audio (sample_fmt, RAMP, SINE).
Tu OUT_DATA: [31:24] ctr[7:0]  [23] GAP  [22] VALID = 1  [21:16] idx  [15:0] C   (docs/HOP_DONG_FPGA_RTOS.md)

File:
  top_cfg.hex   32 tu 32 bit, xem CFG duoi (thu tu co dinh, testbench doc theo chi so).
  top_key.hex   8 tu KMASTER[0..7] (KMASTER[0] = K[255:224]).
  top_reg.hex   che do REG, moi dong 36 bit: [35:32] loai (0 ENC / 1 SKIP / 2 DEC) [31:16] vao [15:0] ra mong doi.
  top_ramp.hex  tu OUT_DATA mong doi, nguon RAMP.        top_sine.hex   nguon SINE.
  top_mic.hex   nguon MIC (mo hinh INMP441 doc i2s_frames.hex): s24 = L[STARTUP_SKIP + i] -> sample_fmt(SHIFT) -> ENC.
  top_clip.hex  so mau bi bao hoa tich luy sau i mau MIC (de kiem CLIP_CNT).
  top_nokey.hex luong RAMP bat khi CHUA co khoa: 65 mau 0..64 (1 mau loi dang giu + 64 trong in_fifo) duoc ma hoa sau
                khi tat ENABLE va nap khoa, roi bat lai: RAMP bat dau lai tu 0, keystream noi tiep, GAP = 0.
  top_ovf_a11.hex / top_ovf_a7.hex  nguon RAMP khi out_fifo (2048 / 128 tu) day va in_fifo (64) day: bo DROP mau,
                tu dau tien sau lo co GAP = 1, keystream lien mach.
"""
import argparse
import hashlib
import os
import sys
from dataclasses import replace

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from refmodel import audio as A                          # noqa: E402
from refmodel.cipher import CipherCore                    # noqa: E402
from refmodel.params import DEFAULT_PARAMS                # noqa: E402

P16 = replace(DEFAULT_PARAMS, N=16)
KEY = hashlib.sha256(b"PBL5 dot 7 - khoa thu, KHONG dung that").digest()
IN_DEPTH = 64

CFG = {                       # chi so -> (ten, gia tri)
    0: ("CTR_REG", 0x000000F0),
    1: ("CTR_RAMP", 0x00012340),
    2: ("CTR_SINE", 0x00012400),
    3: ("CTR_MIC", 0x7FFFFFF0),
    4: ("CTR_OVF", 0xFFFFFFFE),   # sat bien 2^32: ctr quay vong 0xFFFFFFFF -> 0 trong luc chay
    5: ("DROP", 3),
    6: ("N_RAMP", 200),
    7: ("N_SINE", 150),
    8: ("N_MIC", 120),
    9: ("MIC_SHIFT", 4),
    10: ("MIC_SKIP", 5),
    11: ("SCK_DIV", 3),
    12: ("N_REG", 0),             # dien sau
    13: ("CTR_REG_END", 0),       # ctr phien hien tai sau che do REG (doc lai CTR)
    14: ("N_OVF_EXTRA", 40),      # so tu doc them sau lo
    15: ("IRQ_THRESH", 48),
    16: ("GOLD_EXTRA", 0),        # dien sau
    17: ("ZKEY_WORD", 0),         # tu OUT_DATA dau tien sau KEY_CLEAR + RESEED khong ghi khoa: K = 0, ctr 1000, RAMP 0
    18: ("CTR_NOKEY", 0x00005000),
    19: ("NOKEY_WORD", 0),        # tu dau tien cua ban ghi moi sau mot lan bo mau luc chua co khoa: GAP phai = 0
}
GOLD_EXTRA = 100              # golden dai hon so tu testbench cho truoc: doc theo dot IRQ_THRESH (48) + mau dang bay


def word(r, gap):
    return ((r.ctr & 0xFF) << 24) | (gap << 23) | (1 << 22) | ((r.idx & 0x3F) << 16) | r.c


def stream(ctr0, pts, gaps=None):
    core = CipherCore(KEY, P16, ctr0=ctr0)
    out = []
    for i, p in enumerate(pts):
        out.append(word(core.encrypt(p & 0xFFFF), 1 if gaps and i in gaps else 0))
    return out


def gen_reg():
    core = CipherCore(KEY, P16, ctr0=CFG[0][1])
    rows = []
    for i in range(70):                                   # qua ranh phien 64 -> ctr tang
        p = (i * 0x3B5D + 0x1234) & 0xFFFF
        rows.append((0, p, core.encrypt(p).c))
    for _ in range(3):                                    # OP = SKIP, START
        core.advance(1)
        rows.append((1, 0, 0))
    for i in range(10):                                   # OP = DEC
        c = (i * 0x7E31 + 0xBEEF) & 0xFFFF
        rows.append((2, c, core.decrypt(c)))
    for i in range(5):                                    # lai ENC
        p = (0xA000 + i) & 0xFFFF
        rows.append((0, p, core.encrypt(p).c))
    return rows, core.position[0]


def gen_ovf(out_depth, n_extra):
    d = CFG[5][1]
    first_gap = out_depth + IN_DEPTH
    n = first_gap + n_extra + GOLD_EXTRA
    pts = [j if j < first_gap else j + d for j in range(n)]
    return stream(CFG[4][1], pts, gaps={first_gap})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tb/vectors")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    def wr(name, rows, width):
        with open(os.path.join(a.out, name), "w", newline="\n") as f:
            f.write("\n".join(f"{v:0{width}x}" for v in rows) + "\n")
        print(f"  {name:16s} {len(rows):6d} dong")

    reg_rows, ctr_end = gen_reg()
    CFG[12] = ("N_REG", len(reg_rows))
    CFG[13] = ("CTR_REG_END", ctr_end)

    n_ramp, n_sine, n_mic = CFG[6][1], CFG[7][1], CFG[8][1]
    ramp = stream(CFG[1][1], A.ramp(n_ramp + GOLD_EXTRA))
    sine = stream(CFG[2][1], A.sine(n_sine + GOLD_EXTRA))

    frames = [int(l, 16) for l in open(os.path.join(a.out, "i2s_frames.hex")) if l.strip()]
    skip, sh = CFG[10][1], CFG[9][1]
    mic_pts, clip_cum, c = [], [0], 0
    for i in range(n_mic + GOLD_EXTRA + 70):
        s24 = A.s24_from_u(frames[(skip + i) % len(frames)] >> 24)
        y, clip = A.sample_fmt(s24, sh)
        mic_pts.append(y)
        c += int(clip)
        clip_cum.append(c)
    mic = stream(CFG[3][1], mic_pts[: n_mic + GOLD_EXTRA])

    print("dot 7 -> " + a.out)
    CFG[16] = ("GOLD_EXTRA", GOLD_EXTRA)
    CFG[17] = ("ZKEY_WORD", word(CipherCore(bytes(32), P16, ctr0=1000).encrypt(0), 0))
    CFG[19] = ("NOKEY_WORD", word(CipherCore(KEY, P16, ctr0=CFG[18][1]).encrypt(0), 0))
    wr("top_cfg.hex", [CFG[i][1] for i in range(20)] + [0] * 12, 8)
    wr("top_key.hex", [int.from_bytes(KEY[4 * i: 4 * i + 4], "big") for i in range(8)], 8)
    wr("top_reg.hex", [(k << 32) | (x << 16) | y for k, x, y in reg_rows], 9)
    wr("top_ramp.hex", ramp, 8)
    wr("top_sine.hex", sine, 8)
    wr("top_mic.hex", mic, 8)
    wr("top_clip.hex", clip_cum, 4)
    wr("top_nokey.hex", stream(CFG[18][1], list(range(65)) + list(range(40))), 8)
    wr("top_ovf_a11.hex", gen_ovf(2048, CFG[14][1]), 8)
    wr("top_ovf_a7.hex", gen_ovf(128, CFG[14][1]), 8)
    for i in range(20):
        print(f"    cfg[{i:2d}] {CFG[i][0]:12s} = 0x{CFG[i][1]:08x}")


if __name__ == "__main__":
    main()
