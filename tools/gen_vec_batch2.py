#!/usr/bin/env python3
"""gen_vec_batch2.py - sinh vector .hex cho lts_iter va fy_shuffle (dot 2) tu golden model.

Chay tu thu muc goc du an (noi co refmodel/ va vectors/):
    python tools/gen_vec_batch2.py              # ghi vao tb/vectors/

Nguon:
  * trace_enc_*.txt  (vector da dong bang SPEC 1.0.0)  -> chuoi buoc LTS that va cac su kien FY_*
  * refmodel.fisher_yates.fisher_yates_from_chaos voi chuoi x kich thich tu chon (0, 1, 0xFFFFFFFF, ... + ngau nhien)
    de phu cac ca bien cua rejection sampling ma LTS that it khi sinh ra.
Dinh dang (moi dong mot tu hex rong co dinh, cot dau o bit cao):
  lts_iter.hex : 130 bit  [129:128] loai (0 nap, 1 buoc, 3 het)  [127:96] a  [95:64] b  [63:32] c  [31:0] d
                 nap  : a = x0, b = xr (= r_int & 0xFFFFFFFF)
                 buoc : a = x_vao (trang thai truoc buoc), d = x_ra
  fy_ev.hex    : 40 bit   [39:38] loai (0 REFILL, 1 DRAW, 2 SWAP, 3 het)
                 REFILL: [31:0] = x moi ; DRAW: [12] acc [11:8] cand [7:5] b [4:0] rng ; SWAP: [7:4] j [3:0] i
  fy_sum.hex   : 82 bit   [81] hop le  [80] n_sel (0: N=8, 1: N=16)  [79:72] refills  [71:64] rejects  [63:0] pi
                 (pi: nibble i = pi[i]; N = 8 -> nibble 8..15 = 0)
"""
import os, random, sys

ROOT = os.getcwd()
sys.path.insert(0, ROOT)
from refmodel.fisher_yates import fisher_yates_from_chaos      # noqa: E402
from refmodel.params import DEFAULT_PARAMS                       # noqa: E402
import dataclasses                                               # noqa: E402

VEC = os.path.join(ROOT, "vectors", "out")
OUT = os.path.join(ROOT, "tb", "vectors")
TRACES = ["enc_n8_default", "enc_n16_default", "enc_keyrnd", "enc_key00", "enc_keyff", "enc_ctrwrap", "enc_reseed1"]
M32 = 0xFFFFFFFF


def hexw(v, bits):
    return format(v, "0%dx" % ((bits + 3) // 4))


def parse_trace(name):
    """-> danh sach su kien (mau, TEN, [truong int/list])"""
    ev = []
    for line in open(os.path.join(VEC, "trace_%s.txt" % name)):
        line = line.strip()
        if not line:
            continue
        p = line.split(",")
        ev.append((int(p[0]), p[1], p[2:]))
    return ev


def main():
    os.makedirs(OUT, exist_ok=True)
    lts_rows, fy_ev, fy_sum = [], [], []
    n_lts = 0

    def add_sample(n16, evs, pi, refills, rejects):
        for kind, d in evs:
            if kind == "FY_REFILL":
                fy_ev.append((0 << 38) | d[1])
            elif kind == "FY_DRAW":
                rng, b, cand, acc = d
                fy_ev.append((1 << 38) | (int(acc) << 12) | (cand << 8) | (b << 5) | rng)
            elif kind == "FY_SWAP":
                i, j = d
                fy_ev.append((2 << 38) | (j << 4) | i)
        pic = 0
        for i, v in enumerate(pi):
            pic |= v << (4 * i)
        fy_sum.append((1 << 81) | (int(n16) << 80) | (refills << 72) | (rejects << 64) | pic)

    # ---- 1) vector LTS that tu cac trace
    nsamp_real = 0
    for name in TRACES:
        cur, evs, refills, rejects, n16 = None, [], 0, 0, False
        for smp, kind, f in parse_trace(name):
            if kind == "RESEED_HMAC":
                x0 = int(f[2], 16); xr = int(f[3], 16) & M32
                lts_rows.append((0 << 128) | (x0 << 96) | (xr << 64))
            elif kind == "LTS_KEYSTREAM":
                xi, xo = int(f[0], 16), int(f[1], 16)
                lts_rows.append((1 << 128) | (xi << 96) | xo); n_lts += 1
            elif kind == "FY_INIT":
                evs, refills, rejects = [], 0, 0
                n16 = int(f[0], 16) == 16
            elif kind == "FY_REFILL":
                xi, xo = int(f[0], 16), int(f[1], 16)
                lts_rows.append((1 << 128) | (xi << 96) | xo); n_lts += 1
                evs.append(("FY_REFILL", (xi, xo))); refills += 1
            elif kind == "FY_DRAW":
                rng, b, cand, acc = (int(t, 16) for t in f)
                evs.append(("FY_DRAW", (rng, b, cand, acc)))
                if not acc: rejects += 1
            elif kind == "FY_SWAP":
                evs.append(("FY_SWAP", (int(f[0], 16), int(f[1], 16))))
            elif kind == "PERMUTE_XOR":
                pi = tuple(int(t, 16) for t in f[0].split("."))
                add_sample(n16, evs, pi, refills, rejects); nsamp_real += 1

    # ---- 1b) bay-guard: x0 = 0xFFFFFFFF  =>  buoc dau cho x' = 1 (bay) nen x' = x0 = 0xFFFFFFFF (golden lts_step_ex)
    #      LTS that hau nhu khong cham bay-guard, nen dung ca dac biet nay de kiem day noi x0_q cua lts_iter.
    from refmodel.lts import lts_step_ex
    n_guard = 0
    for xr in (0, 1, 0x12345678, 0x80000000, 0xFFFFFFFF, 0x9ABCDEF0):
        r_int = (1 << 32) + xr
        out = lts_step_ex(M32, r_int, M32, DEFAULT_PARAMS)
        assert out.guarded and out.x_next == M32, "gia thiet ca bay-guard khong con dung"
        lts_rows.append((0 << 128) | (M32 << 96) | (xr << 64))
        lts_rows.append((1 << 128) | (M32 << 96) | out.x_next); n_lts += 1; n_guard += 1
        lts_rows.append((1 << 128) | (M32 << 96) | out.x_next); n_lts += 1     # buoc nua tu chinh trang thai do

    # ---- 2) chuoi x kich thich (golden chay voi step gia)
    rnd = random.Random(20260429)
    specials = [0, 1, 2, M32, M32 - 1, 0x80000000, 0x7FFFFFFF, 0xAAAAAAAA, 0x55555555, 0xF0F0F0F0, 0x0F0F0F0F, 0x00000007, 0x77777777]
    nsamp_syn = 0
    for n in (8, 16):
        p = dataclasses.replace(DEFAULT_PARAMS, N=n)
        for s in range(400):
            seq = []
            def step(x, seq=seq):
                v = rnd.choice(specials) if rnd.random() < 0.35 else rnd.getrandbits(32)
                seq.append(v)
                return v
            trace = []
            try:
                r = fisher_yates_from_chaos(rnd.getrandbits(32), step, p, trace)
            except RuntimeError:
                continue
            evs = [(k, d) for k, d in trace if k in ("FY_REFILL", "FY_DRAW", "FY_SWAP")]
            add_sample(n == 16, evs, r.pi, r.refills, r.rejects); nsamp_syn += 1

    for fname, rows, bits, sentinel in (("lts_iter.hex", lts_rows, 130, 3 << 128),
                                        ("fy_ev.hex", fy_ev, 40, (3 << 38)),
                                        ("fy_sum.hex", fy_sum, 82, 0)):
        with open(os.path.join(OUT, fname), "w") as f:
            for v in rows:
                f.write(hexw(v, bits) + "\n")
            if fname != "fy_sum.hex":
                f.write(hexw(sentinel | ((1 << 38) - 1 if bits == 40 else 0), bits) + "\n")   # dong ket thuc: loai = 3
    print("lts_iter: %d dong (%d buoc LTS) | fy_shuffle: %d mau that + %d mau kich thich, %d su kien"
          % (len(lts_rows), n_lts, nsamp_real, nsamp_syn, len(fy_ev)))


if __name__ == "__main__":
    main()
