#!/usr/bin/env python3
"""gen_vec_batch3.py - sinh vector .hex cho chaos_core (dot 3) tu golden model.

Chay tu thu muc goc du an (noi co refmodel/ va vectors/):
    python tools/gen_vec_batch3.py              # ghi vao tb/vectors/ (core_*.hex) va tb/vectors/trace/ (trace_ops_*.txt)

9 bo (chi so +SET trong tb_chaos_core.v):
  0 enc_n8_default  1 enc_n16_default  2 enc_reseed1  3 enc_ctrwrap  4 enc_key00  5 enc_keyff  6 enc_keyrnd   (lay tu vectors/out, chi ENC)
  7 ops_n8_ri4      N = 8,  RESEED_INTERVAL = 4,  ctr0 = 0xFFFFFFFD, ENC / DEC / SKIP xen ke, khoa ngau nhien
  8 ops_n16_ri64    N = 16, RESEED_INTERVAL = 64, ENC / DEC / SKIP xen ke, khoa 00..1f
Dinh dang:
  core_<bo>_cfg.hex : 1 tu 321 bit  [320] n_sel  [319:288] RESEED_INTERVAL  [287:256] ctr0  [255:0] khoa (byte dau o bit cao)
  core_<bo>.hex     : moi dong mot tu 179 bit  [178] hop le  [177:176] op (0 ENC, 1 DEC, 2 SKIP)  [175:160] du lieu vao
                      [159:144] du lieu ra mong doi (ENC: C, DEC: P, SKIP: 0)  [143:112] ctr  [111:96] idx  [95:80] k
                      [79:16] pi (nibble i = pi[i])  [15:8] refills  [7:0] rejects
                      ctr / idx = vi tri cua mau nay TRUOC khi xu ly (D4).
"""
import csv, dataclasses, os, random, sys

ROOT = os.getcwd()
sys.path.insert(0, ROOT)
from refmodel.cipher import CipherCore                     # noqa: E402
from refmodel.compare import format_event                  # noqa: E402
from refmodel.gen_vectors import cipher_set_specs          # noqa: E402
from refmodel.params import DEFAULT_PARAMS                 # noqa: E402

VEC = os.path.join(ROOT, "vectors", "out")
OUT = os.path.join(ROOT, "tb", "vectors")
TRV = os.path.join(ROOT, "tb", "vectors", "trace")
ENC = ["enc_n8_default", "enc_n16_default", "enc_reseed1", "enc_ctrwrap", "enc_key00", "enc_keyff", "enc_keyrnd"]
ENC_OP, DEC_OP, SKIP_OP = 0, 1, 2


def hexw(v, bits):
    return format(v, "0%dx" % ((bits + 3) // 4))


def row_word(op, din, dout, ctr, idx, k, pi, refills, rejects):
    w = 1
    for v, b in ((op, 2), (din, 16), (dout, 16), (ctr, 32), (idx, 16), (k, 16), (pi, 64), (refills, 8), (rejects, 8)):
        assert 0 <= v < (1 << b)
        w = (w << b) | v
    return hexw(w, 179)


def cfg_word(key, ctr0, ri, n):
    w = 1 if n == 16 else 0
    for v, b in ((ri, 32), (ctr0, 32), (int.from_bytes(key, "big"), 256)):
        w = (w << b) | v
    return hexw(w, 321)


def write(name, rows, cfg):
    with open(os.path.join(OUT, "core_%s.hex" % name), "w") as f:
        f.write("\n".join(rows) + "\n")
    with open(os.path.join(OUT, "core_%s_cfg.hex" % name), "w") as f:
        f.write(cfg + "\n")


def from_enc_sets():
    for spec in cipher_set_specs(DEFAULT_PARAMS):
        rows = []
        with open(os.path.join(VEC, spec.name + ".csv")) as f:
            for r in csv.DictReader(f):
                v = {k: int(x, 16) for k, x in r.items()}
                rows.append(row_word(ENC_OP, v["p"], v["c"], v["ctr"], v["idx"], v["k"], v["pi"], v["refills"], v["rejects"]))
        write(spec.name, rows, cfg_word(spec.key, spec.ctr0, spec.reseed, spec.n))
        print(spec.name, len(rows), "mau")


def build_ops(name, key, ctr0, n, ri, count, seed):
    p = dataclasses.replace(DEFAULT_PARAMS, N=n, RESEED_INTERVAL=ri)
    rnd = random.Random(seed)
    trace = []
    core = CipherCore(key, p, ctr0=ctr0, trace=trace)
    lines = [format_event(0, nm, d) for nm, d in trace]            # RESEED_HMAC luc khoi tao
    words, cnt = [], [0, 0, 0]
    for i in range(count):
        ctr, idx = core.position
        start = len(trace)
        u = rnd.random()
        v = rnd.randrange(1 << n)
        if u < 0.5:
            op, out = ENC_OP, core.encrypt(v).c
        elif u < 0.8:
            op, out = DEC_OP, core.decrypt(v)
        else:
            op, out = SKIP_OP, 0
            k_s, pi_s = core._gen_ks_perm()                          # = CipherCore.advance(1), giu lai k, pi de kiem tra
            core._finish(0)
        cnt[op] += 1
        ev = trace[start:]
        k = next(d for nm, d in ev if nm == "LTS_KEYSTREAM")[2]
        pi_t = pi_s if op == SKIP_OP else next(d for nm, d in ev if nm == "PERMUTE_XOR")[0]
        if op == SKIP_OP:
            assert k == k_s
        pi_packed = sum(pv << (4 * j) for j, pv in enumerate(pi_t))
        words.append(row_word(op, v, out, ctr, idx, k, pi_packed, core.last_refills, core.last_rejects))
        lines += [format_event(i, nm, d) for nm, d in ev]
    write(name, words, cfg_word(key, ctr0, ri, n))
    os.makedirs(TRV, exist_ok=True)
    with open(os.path.join(TRV, "trace_%s.txt" % name), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(name, count, "mau  ENC/DEC/SKIP =", tuple(cnt))


def main():
    os.makedirs(OUT, exist_ok=True)
    from_enc_sets()
    kr = random.Random(20260702)
    build_ops("ops_n8_ri4", bytes(kr.randrange(256) for _ in range(32)), 0xFFFFFFFD, 8, 4, 90, 31)
    build_ops("ops_n16_ri64", bytes(range(32)), 0, 16, 64, 150, 32)


if __name__ == "__main__":
    main()
