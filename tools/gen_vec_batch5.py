"""gen_vec_batch5.py - vector golden cho dot 5 (sync_fifo, i2s_rx). Chay tu thu muc goc PBL5:

    python tools/gen_vec_batch5.py                       # ghi vao tb/vectors
    python tools/gen_vec_batch5.py --out <thu_muc>

Sinh ra (tat dinh, seed co dinh):
  fifo_a6.hex     sync_fifo AW=6  (64 x 16)    - chu ky-chinh xac
  fifo_a11.hex    sync_fifo AW=11 (2048 x 32)  - chu ky-chinh xac
  i2s_frames.hex  cac khung I2S {L[23:0], R[23:0]} ma mo hinh INMP441 trong testbench phat ra
  i2s_cfg.hex     cac ca thu i2s_rx
  i2s_exp.hex     dau ra mong doi cua i2s_rx, noi tiep theo tung ca

Bo cuc (cot dau o bit cao nhat):
  fifo_*.hex   84 bit: [83] hop_le [82] 0 [81] clr [80] wr [79] rd [78:47] wd [46:35] level [34] full [33] empty
                       [32] rd_vld [31:0] rd_data           (level / rd_data / wd lay so bit thap theo DW, AW)
  i2s_frames   48 bit: [47:24] L  [23:0] R
  i2s_cfg      80 bit: [79] hop_le [78:76] 0 [75:64] sck_div [63:61] 0 [60] channel [59:48] div_hieu_dung
                       [47:16] startup_skip [15:0] so mau kiem
  i2s_exp      24 bit: s24 cua tung mau, noi tiep cac ca theo thu tu trong i2s_cfg
"""
import argparse
import os
import random
from collections import deque

# ------------------------------------------------------------------ sync_fifo
class FifoModel:
    """Mo hinh chu ky-chinh xac cua sync_fifo.v.

    Moi chu ky (canh len clk), voi trang thai TRUOC canh:
      clr = 1          -> xoa het (con tro, muc, rd_vld = 0); rd_data giu nguyen; bo qua wr / rd cung chu ky
      do_rd = rd & !empty   -> rd_data <= dau hang doi, rd_vld <= 1 (nguoc lai rd_vld <= 0)
      do_wr = wr & !full    -> day vao cuoi
    full / empty / level la ham cua so phan tu sau canh. Ghi khi day bi bo; doc khi rong bi bo.
    """

    def __init__(self, aw):
        self.depth = 1 << aw
        self.q = deque()
        self.rd_data = 0
        self.rd_vld = 0

    def step(self, clr, wr, rd, wd):
        if clr:
            self.q.clear()
            self.rd_vld = 0
        else:
            do_rd = rd and len(self.q) > 0
            do_wr = wr and len(self.q) < self.depth
            if do_rd:
                self.rd_data = self.q.popleft()
                self.rd_vld = 1
            else:
                self.rd_vld = 0
            if do_wr:
                self.q.append(wd)
        lvl = len(self.q)
        return lvl, int(lvl == self.depth), int(lvl == 0), self.rd_vld, self.rd_data


def fifo_stimulus(aw, dw, rng):
    depth = 1 << aw
    mask = (1 << dw) - 1
    st = []

    def rnd():
        return rng.getrandbits(dw)

    def put(clr, wr, rd, wd=None):
        st.append((clr, wr, rd, rnd() if wd is None else wd & mask))

    # 1. vai chu ky rong; doc khi rong
    for _ in range(3):
        put(0, 0, 0)
    for _ in range(3):
        put(0, 0, 1)
    # 2. lap day voi mau de nhan dien thu tu, roi co ghi tran
    for i in range(depth):
        put(0, 1, 0, (0xA5000000 | (i * 0x01010101)) ^ (i << 3))
    for _ in range(5):
        put(0, 1, 0)                                  # ghi khi day: phai bi bo
    # 3. doc va ghi cung luc khi day: chi doc duoc nhan
    for _ in range(3):
        put(0, 1, 1)
    # 4. rut het, roi co doc khi rong
    for _ in range(depth + 5):
        put(0, 0, 1)
    # 5. doc + ghi cung luc khi rong: chi ghi duoc nhan
    for _ in range(3):
        put(0, 1, 1)
    # 6. dao dong quanh muc 1 (doc ngay sau ghi)
    for _ in range(40):
        put(0, 1, 1)
    # 7. xoa giua chung
    for _ in range(depth // 2):
        put(0, 1, 0)
    put(1, 0, 0)
    for _ in range(3):
        put(0, 0, 1)                                  # phai rong sau clr
    for _ in range(5):
        put(0, 1, 0)
    put(1, 1, 1)                                      # clr cung luc wr / rd: clr thang
    for _ in range(2):
        put(0, 0, 1)
    # 8. ngau nhien, nhieu che do xac suat de cham ca bien day lan rong
    n_rand = max(4000, 4 * depth)
    modes = [(0.5, 0.5), (0.8, 0.3), (0.3, 0.8), (0.95, 0.9), (0.9, 0.95), (0.6, 0.4)]
    for k in range(n_rand):
        pw, pr = modes[(k * len(modes)) // n_rand]
        clr = 1 if rng.random() < 0.002 else 0
        put(clr, int(rng.random() < pw), int(rng.random() < pr))
    # 9. lap day lan nua roi rut het (con tro da quay vong nhieu lan)
    for _ in range(depth + 2):
        put(0, 1, 0)
    for _ in range(depth + 2):
        put(0, 0, 1)
    return st


def gen_fifo(aw, dw, seed):
    rng = random.Random(seed)
    m = FifoModel(aw)
    rows = []
    for clr, wr, rd, wd in fifo_stimulus(aw, dw, rng):
        lvl, full, empty, rvld, rdata = m.step(clr, wr, rd, wd)
        v = (1 << 83) | (clr << 81) | (wr << 80) | (rd << 79) | (wd << 47) | (lvl << 35) \
            | (full << 34) | (empty << 33) | (rvld << 32) | rdata
        rows.append(f"{v:021x}")
    return rows


# ------------------------------------------------------------------ i2s_rx
MIN_DIV = 3        # i2s_rx.v: SCK_DIV < 3 duoc kep len 3 (bo dong bo SD 2 tang can nua chu ky SCK >= 4 clk)


def i2s_frames(n, rng):
    fixed = [
        (0x800000, 0x7FFFFF), (0x7FFFFF, 0x800000), (0x000000, 0xFFFFFF), (0xFFFFFF, 0x000000),
        (0xAAAAAA, 0x555555), (0x555555, 0xAAAAAA), (0x000001, 0x800001), (0x800001, 0x000001),
        (0xFFFFFE, 0x7FFFFE), (0x123456, 0xFEDCBA),
    ]
    fr = list(fixed)
    for b in range(24):                               # bit di bo: bat loi lech bit / dao thu tu bit
        fr.append((1 << b, (1 << (23 - b)) ^ 0xFFFFFF))
    while len(fr) < n:
        fr.append((rng.getrandbits(24), rng.getrandbits(24)))
    return fr[:n]


# (sck_div, channel, startup_skip, so mau kiem)
I2S_CASES = [
    (24, 0, 0, 40),      # cau hinh chot: SCK 1 MHz, fs 15 625 Hz, kenh trai
    (24, 1, 0, 40),      # kenh phai
    (3, 0, 5, 60),       # SCK_DIV nho nhat
    (1, 1, 2, 30),       # SCK_DIV < 3: kep len 3
    (7, 0, 17, 50),
    (100, 1, 1, 5),      # SCK cham
    (3, 1, 300, 20),     # STARTUP_SKIP lon (vuot qua cac mau bien o dau bang)
    (0, 0, 0, 40),       # SCK_DIV = 0: kep len 3
]


def gen_i2s(seed, nframes=400):
    rng = random.Random(seed)
    fr = i2s_frames(nframes, rng)
    cfg, exp = [], []
    for div, ch, skip, n in I2S_CASES:
        eff = max(div, MIN_DIV)
        assert skip + n <= nframes
        v = (1 << 79) | (div << 64) | (ch << 60) | (eff << 48) | (skip << 16) | n
        cfg.append(f"{v:020x}")
        for i in range(n):
            exp.append(f"{fr[skip + i][ch]:06x}")
    frames = [f"{(l << 24) | r:012x}" for l, r in fr]
    return frames, cfg, exp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tb/vectors")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    def wr(name, rows):
        with open(os.path.join(a.out, name), "w", newline="\n") as f:
            f.write("\n".join(rows) + "\n")
        print(f"  {name:16s} {len(rows):6d} dong")

    print("dot 5 -> " + a.out)
    wr("fifo_a6.hex", gen_fifo(6, 16, seed=56))
    wr("fifo_a11.hex", gen_fifo(11, 32, seed=511))
    frames, cfg, exp = gen_i2s(seed=441)
    wr("i2s_frames.hex", frames)
    wr("i2s_cfg.hex", cfg)
    wr("i2s_exp.hex", exp)


if __name__ == "__main__":
    main()
