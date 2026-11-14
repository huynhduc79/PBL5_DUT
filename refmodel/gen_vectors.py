"""gen_vectors.py - sinh bo vector kiem thu (golden) cho RTL, co dinh theo SPEC_VERSION (muc 6.2.4, 6.3.7).

Dung:
    python -m refmodel.gen_vectors OUT_DIR            # sinh bo vector vao OUT_DIR
    python -m refmodel.gen_vectors --check OUT_DIR    # sinh lai trong bo nho va doi chieu voi OUT_DIR
                                                      # (phat hien golden model bi doi hoac file bi sua)

Moi ket qua la tat dinh (seed co dinh, khong co thoi gian). Bo vector gom:
    kat_sha256, kat_hmac, kat_crc16         KAT cho loi SHA-256 / HMAC / CRC
    kdf                                     (K_master, ctr) -> K_session, X0, r_int
    kdf_words                               K_session -> (X0, r_int)  (kiem tra khoi Parameter Derivation, co ca bien)
    lts_step                                (X, r_int, X0) -> X_next, nhanh re, co bay-guard
    enc_*                                   ma hoa tung mau: (ctr, idx, P, C, k, pi, refills, rejects) + trace_*.txt
    frames                                  khung UART / payload Ethernet cho firmware
    manifest.json                           phien ban, hash cau hinh, SHA-256 tung file, bo cuc cot, do phu
Moi bang co <ten>.csv (doc duoc) va, neu toan cot so, <ten>.hex: mot dong = mot tu rong, noi cac cot
so theo thu tu bo cuc (cot dau la bit cao nhat), hex chu thuong, du so 0 dau; doc bang $readmemh.
"""

from __future__ import annotations

import argparse
import binascii
import dataclasses
import hashlib
import json
import random
import sys
from pathlib import Path

from .cipher import CipherCore
from .compare import format_event, parse_trace
from .framing import crc16_ccitt, pack_frame, pack_payload
from .kdf import derive_lts_params, hmac_sha256, params_from_session_key, session_message
from .lts import lts_step_ex
from .params import DEFAULT_PARAMS, SPEC_VERSION, CipherParams

SEED = 0x1A05          # seed goc; moi bang dung SEED + chi so rieng

README = """\
BO VECTOR KIEM THU GOLDEN CHO RTL (xem manifest.json de biet phien ban, hash cau hinh, bo cuc)

CSV: dong dau la ten cot. Cot so in dang hex chu thuong du so 0 dau (do rong = ceil(bit / 4));
     cot chu (case, key_hex, frame...) in nguyen van. Khong co dau phay trong o.
HEX: moi dong = mot tu rong gom cac cot SO cua dong CSV tuong ung, cot dau tien o bit cao nhat.
     Bo cuc (ten cot, so bit) nam trong manifest.json -> tables.<ten>.layout.
Quy uoc: bit 0 = LSB; hoan vi pi dong thanh so: nibble i = pi[i] (pi[0] o nibble thap nhat);
     ma hoa: C = gather(P, pi) XOR k  (gather: bit i cua ket qua = bit pi[i] cua P);
     giai ma: dua C vao, ky vong P (cung bang, doc nguoc cot c -> p).
Trace (trace_<bo>.txt): moi dong '<so_mau>,<TEN_SU_KIEN>,<truong>...' (xem refmodel/compare.py);
     so sanh log RTL voi golden bang:  python -m refmodel.compare trace trace_<bo>.txt log_rtl.txt
Kiem tra bo vector con nguyen ven / golden chua doi:  python -m refmodel.gen_vectors --check <thu_muc>
"""

# (ten, kieu, bit): kieu 'x' = so (in hex), 's' = chuoi
Col = tuple[str, str, int]


class Table:
    def __init__(self, name: str, cols: list[Col], rows: list[tuple], emit_hex: bool = True):
        self.name, self.cols, self.rows, self.emit_hex = name, cols, rows, emit_hex

    @staticmethod
    def _fmt(v, col: Col) -> str:
        name, kind, bits = col
        if kind == "s":
            s = str(v)
            if "," in s or "\n" in s:
                raise ValueError(f"{name}: chuoi chua dau phay/xuong dong")
            return s
        v = int(v)
        if not (0 <= v < (1 << bits)):
            raise ValueError(f"{name}: gia tri {v} khong vua {bits} bit")
        return f"{v:0{(bits + 3) // 4}x}"

    def csv_bytes(self) -> bytes:
        lines = [",".join(c[0] for c in self.cols)]
        lines += [",".join(self._fmt(v, c) for v, c in zip(row, self.cols)) for row in self.rows]
        return ("\n".join(lines) + "\n").encode()

    @property
    def num_cols(self) -> list[tuple[int, Col]]:
        return [(i, c) for i, c in enumerate(self.cols) if c[1] == "x"]

    @property
    def word_bits(self) -> int:
        return sum(c[2] for _, c in self.num_cols)

    def hex_bytes(self) -> bytes | None:
        if not self.emit_hex or not self.num_cols:
            return None
        digits = (self.word_bits + 3) // 4
        lines = []
        for row in self.rows:
            word = 0
            for i, c in self.num_cols:
                self._fmt(row[i], c)                                 # kiem tra do rong
                word = (word << c[2]) | int(row[i])
            lines.append(f"{word:0{digits}x}")
        return ("\n".join(lines) + "\n").encode()

    def layout(self) -> list[dict]:
        return [{"name": c[0], "bits": c[2]} for _, c in self.num_cols]


def _int(b: bytes) -> int:
    return int.from_bytes(b, "big")


# ============================================================ cac bang KAT / KDF / LTS
def table_kat_sha256() -> Table:
    msgs = [b"", b"abc", b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"]
    msgs += [bytes(i & 0xFF for i in range(n)) for n in (1, 3, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 1000)]
    rows = [(m.hex(), hashlib.sha256(m).hexdigest()) for m in msgs]
    return Table("kat_sha256", [("msg_hex", "s", 0), ("digest_hex", "s", 0)], rows, emit_hex=False)


def table_kat_hmac(p: CipherParams) -> Table:
    rfc4231 = [(b"\x0b" * 20, b"Hi There"), (b"Jefe", b"what do ya want for nothing?"),
               (b"\xaa" * 20, b"\xdd" * 50), (bytes(range(1, 26)), b"\xcd" * 50)]
    pairs = list(rfc4231)
    for key in (bytes(range(32)), bytes(32), b"\xff" * 32):
        pairs += [(key, session_message(ctr, p)) for ctr in (0, 1, 0xFFFFFFFF)]
    rows = [(k.hex(), m.hex(), hmac_sha256(k, m).hex()) for k, m in pairs]
    return Table("kat_hmac", [("key_hex", "s", 0), ("msg_hex", "s", 0), ("mac_hex", "s", 0)], rows, emit_hex=False)


def table_kat_crc16(rnd: random.Random) -> Table:
    datas = [b"", b"123456789", b"\x00", b"\xff" * 4, bytes(range(16))]
    datas += [bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 17))) for _ in range(20)]
    rows = [(d.hex(), crc16_ccitt(d)) for d in datas]
    return Table("kat_crc16", [("data_hex", "s", 0), ("crc", "x", 16)], rows, emit_hex=False)


def table_kdf(p: CipherParams, rnd: random.Random) -> Table:
    keys = [bytes(range(32)), bytes(32), b"\xff" * 32, bytes(rnd.randrange(256) for _ in range(32))]
    ctrs = [0, 1, 2, 3, 63, 64, 255, 256, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF]
    rows = []
    for key in keys:
        for ctr in ctrs:
            sp = derive_lts_params(key, ctr, p)
            rows.append((_int(key), ctr, _int(sp.k_session), sp.x0, sp.r_int))
    cols = [("k_master", "x", 256), ("ctr", "x", 32), ("k_session", "x", 256), ("x0", "x", 32), ("r_int", "x", p.R_BITS)]
    return Table("kdf", cols, rows)


def table_kdf_words(p: CipherParams, rnd: random.Random) -> Table:
    def ks(*w: int) -> bytes:
        return b"".join(v.to_bytes(4, "big") for v in w)

    cases = [
        ("zeros", ks(*[0] * 8)), ("ones", ks(*[0xFFFFFFFF] * 8)), ("range", bytes(range(32))),
        ("x0_xor_0_nonzero_words", ks(0xAAAAAAAA, 0xAAAAAAAA, 0x12345678, 0x12345678, 1, 2, 3, 4)),
        ("x0_xor_1", ks(1, 0, 0, 0, 0, 0, 0, 0)), ("x0_xor_2", ks(2, 0, 0, 0, 0, 0, 0, 0)),
        ("x0_xor_3", ks(3, 0, 0, 0, 0, 0, 0, 0)), ("x0_max", ks(0xFFFFFFFF, 0, 0, 0, 0, 0, 0, 0)),
        ("x_zero", ks(5, 0, 0, 0, 0, 0, 0, 0)), ("x_one", ks(5, 0, 0, 0, 1, 0, 0, 0)),
        ("x_half", ks(5, 0, 0, 0, 0x80000000, 0, 0, 0)), ("x_max", ks(5, 0, 0, 0, 0xFFFFFFFF, 0, 0, 0)),
        ("x_xor_mix_max", ks(5, 0, 0, 0, 0xF0F0F0F0, 0x0F0F0F0F, 0, 0)),
    ]
    cases += [(f"rand{i}", bytes(rnd.randrange(256) for _ in range(32))) for i in range(20)]
    rows = []
    for name, k in cases:
        x0, r = params_from_session_key(k, p)
        rows.append((name, _int(k), x0, r))
    cols = [("case", "s", 0), ("k_session", "x", 256), ("x0", "x", 32), ("r_int", "x", p.R_BITS)]
    return Table("kdf_words", cols, rows)


def table_lts_step(p: CipherParams, rnd: random.Random) -> Table:
    rows: list[tuple] = []

    def add(case: str, x: int, r: int, x0: int):
        out = lts_step_ex(x, r, x0, p)
        rows.append((case, x, r, x0, out.x_next, out.branch, int(out.guarded)))
        return out

    r_mid = p.R_MIN_INT + p.R_SPAN_INT // 2                 # r_mid chia het cho 4
    r_set = [p.R_MIN_INT, r_mid, r_mid + 1, r_mid + 2, r_mid + 3, p.R_MAX_INT]
    x_set = [0, 1, 2, 3, p.HALF - 2, p.HALF - 1, p.HALF, p.HALF + 1, p.MASK - 2, p.MASK - 1, p.MASK]
    for r in r_set:
        for x in x_set:
            add("edge", x, r, 0xDEADBEEF)
    for _ in range(1500):
        add("rand", rnd.randrange(p.ONE), p.R_MIN_INT + rnd.randrange(p.R_SPAN_INT), rnd.randrange(2, p.ONE))
    key = bytes(range(32))
    for ctr in range(3):                                      # quy dao that cua 3 phien dau
        sp = derive_lts_params(key, ctr, p)
        x = sp.x0
        for _ in range(200):
            x = add(f"orbit{ctr}", x, sp.r_int, sp.x0).x_next
    cols = [("case", "s", 0), ("x_in", "x", p.W), ("r_int", "x", p.R_BITS), ("x0", "x", p.W),
            ("x_out", "x", p.W), ("branch", "x", 1), ("guarded", "x", 1)]
    return Table("lts_step", cols, rows)


# ============================================================ ma hoa tung mau + trace
class CipherSetSpec:
    def __init__(self, name: str, key: bytes, ctr0: int, n: int, reseed: int, plain: list[int]):
        self.name, self.key, self.ctr0, self.n, self.reseed, self.plain = name, key, ctr0, n, reseed, plain


def cipher_set_specs(p: CipherParams) -> list[CipherSetSpec]:
    km = bytes(range(32))

    def rnd_list(idx: int, n_bits: int, count: int) -> list[int]:
        r = random.Random(SEED + 100 + idx)
        return [r.randrange(1 << n_bits) for _ in range(count)]

    kr = random.Random(SEED + 99)
    key_rnd = bytes(kr.randrange(256) for _ in range(32))
    return [
        CipherSetSpec("enc_n8_default", km, 0, 8, p.RESEED_INTERVAL, list(range(256)) + rnd_list(1, 8, 144)),
        CipherSetSpec("enc_n16_default", km, 0, 16, p.RESEED_INTERVAL,
                      [0, 0xFFFF, 0xA5A5, 0x5A5A, 1, 0x8000, 0x00FF, 0xFF00] + rnd_list(2, 16, 192)),
        CipherSetSpec("enc_reseed1", km, 0, 8, 1, rnd_list(3, 8, 40)),
        CipherSetSpec("enc_ctrwrap", km, 2**32 - 2, 8, 4, rnd_list(4, 8, 24)),
        CipherSetSpec("enc_key00", bytes(32), 0, 8, p.RESEED_INTERVAL, rnd_list(5, 8, 140)),
        CipherSetSpec("enc_keyff", b"\xff" * 32, 0, 8, p.RESEED_INTERVAL, rnd_list(6, 8, 140)),
        CipherSetSpec("enc_keyrnd", key_rnd, 0, 8, p.RESEED_INTERVAL, rnd_list(7, 8, 140)),
    ]


def build_cipher_set(spec: CipherSetSpec, p: CipherParams) -> tuple[Table, str]:
    q = dataclasses.replace(p, N=spec.n, RESEED_INTERVAL=spec.reseed)
    trace: list = []
    core = CipherCore(spec.key, q, ctr0=spec.ctr0, trace=trace)
    lines = [format_event(0, name, data) for name, data in trace]          # RESEED_HMAC luc khoi tao
    rows = []
    for i, v in enumerate(spec.plain):
        start = len(trace)
        res = core.encrypt(v)
        events = trace[start:]
        k = next(d for n_, d in events if n_ == "LTS_KEYSTREAM")[2]
        pi = next(d for n_, d in events if n_ == "PERMUTE_XOR")[0]
        pi_packed = sum(pv << (4 * j) for j, pv in enumerate(pi))
        rows.append((res.ctr, res.idx, v, res.c, k, pi_packed, core.last_refills, core.last_rejects))
        lines += [format_event(i, name, data) for name, data in events]
    n = spec.n
    cols = [("ctr", "x", 32), ("idx", "x", 16), ("p", "x", n), ("c", "x", n), ("k", "x", n),
            ("pi", "x", 4 * n), ("refills", "x", 8), ("rejects", "x", 8)]
    return Table(spec.name, cols, rows), "\n".join(lines) + "\n"


# ============================================================ khung / payload
def table_frames(enc_tables: dict[str, Table]) -> Table:
    items = [(0, 0, 8, 0), (0xFFFFFFFF, 0xFFFF, 8, 0xFF), (0xAAAAAAAA, 0xAAAA, 16, 0xAAAA),
             (1, 2, 16, 0xABCD), (0x01020304, 0x0506, 8, 0x07)]
    for name, count in (("enc_n8_default", 40), ("enc_n16_default", 20)):
        t = enc_tables[name]
        n = 8 if "n8" in name else 16
        items += [(r[0], r[1], n, r[3]) for r in t.rows[:count]]
    rows = []
    for ctr, idx, n, c in items:
        payload = pack_payload(ctr, idx, n, c)
        frame = pack_frame(ctr, idx, n, c)
        rows.append((ctr, idx, n, c, payload.hex(), frame.hex(), int.from_bytes(frame[-2:], "big")))
    cols = [("ctr", "x", 32), ("idx", "x", 16), ("n", "x", 8), ("c", "x", 16),
            ("payload_hex", "s", 0), ("frame_hex", "s", 0), ("crc", "x", 16)]
    return Table("frames", cols, rows, emit_hex=False)


# ============================================================ do phu va manifest
def compute_coverage(tables: dict[str, Table], traces: dict[str, str], specs: list[CipherSetSpec]) -> dict:
    lts = tables["lts_step"]
    ci = {c[0]: i for i, c in enumerate(lts.cols)}
    guarded_x = sorted({r[ci["x_in"]] for r in lts.rows if r[ci["guarded"]] == 1})
    cov = {
        "lts_branch_low": sum(1 for r in lts.rows if r[ci["branch"]] == 0),
        "lts_branch_high": sum(1 for r in lts.rows if r[ci["branch"]] == 1),
        "lts_guarded_rows": sum(1 for r in lts.rows if r[ci["guarded"]] == 1),
        "lts_guarded_x_in": [f"{x:x}" for x in guarded_x],
        "cipher": {},
    }
    for spec in specs:
        t = tables[spec.name]
        cidx = {c[0]: i for i, c in enumerate(t.cols)}
        events = parse_trace(traces[spec.name])
        rejects: dict[int, int] = {}
        for e in events:
            if e.name == "FY_DRAW" and e.fields[3] == "0":
                rng = int(e.fields[0], 16)
                rejects[rng] = rejects.get(rng, 0) + 1
        refills: dict[int, int] = {}
        for r in t.rows:
            refills[r[cidx["refills"]]] = refills.get(r[cidx["refills"]], 0) + 1
        ctrs = [r[cidx["ctr"]] for r in t.rows]
        cov["cipher"][spec.name] = {
            "n": spec.n, "samples": len(t.rows), "reseed_interval": spec.reseed,
            "reseeds": sum(1 for e in events if e.name == "RESEED_HMAC") - 1,
            "max_idx": max(r[cidx["idx"]] for r in t.rows),
            "ctr_first": ctrs[0], "ctr_last": ctrs[-1],
            "ctr_wrapped": any(b < a for a, b in zip(ctrs, ctrs[1:])),
            "reject_by_range": {f"{k}": v for k, v in sorted(rejects.items())},
            "refills_hist": {f"{k}": v for k, v in sorted(refills.items())},
        }
    return cov


def build_all(p: CipherParams = DEFAULT_PARAMS) -> tuple[dict[str, bytes], dict]:
    """Tra (files, manifest): files = {ten_file: noi_dung_bytes}; manifest chua ca SHA-256 cua cac file."""
    rnd = lambda k: random.Random(SEED + k)
    tables: dict[str, Table] = {
        "kat_sha256": table_kat_sha256(), "kat_hmac": table_kat_hmac(p), "kat_crc16": table_kat_crc16(rnd(1)),
        "kdf": table_kdf(p, rnd(2)), "kdf_words": table_kdf_words(p, rnd(3)), "lts_step": table_lts_step(p, rnd(4)),
    }
    specs = cipher_set_specs(p)
    traces: dict[str, str] = {}
    for spec in specs:
        tables[spec.name], traces[spec.name] = build_cipher_set(spec, p)
    tables["frames"] = table_frames(tables)

    files: dict[str, bytes] = {"README.txt": README.encode()}
    tinfo: dict[str, dict] = {}
    for name, t in tables.items():
        files[f"{name}.csv"] = t.csv_bytes()
        hb = t.hex_bytes()
        if hb is not None:
            files[f"{name}.hex"] = hb
        tinfo[name] = {"rows": len(t.rows), "csv": f"{name}.csv", "hex": f"{name}.hex" if hb else None,
                       "word_bits": t.word_bits if hb else None, "layout": t.layout()}
    for name, text in traces.items():
        files[f"trace_{name}.txt"] = text.encode()
        tinfo[name]["trace"] = f"trace_{name}.txt"
    csets = {s.name: {"k_master": s.key.hex(), "ctr0": s.ctr0, "N": s.n, "RESEED_INTERVAL": s.reseed,
                      "samples": len(s.plain)} for s in specs}
    manifest = {
        "spec_version": SPEC_VERSION,
        "config_hash": p.config_hash(),
        "params": p.to_dict(),
        "seed": SEED,
        "files": {n: {"sha256": hashlib.sha256(b).hexdigest(), "bytes": len(b)} for n, b in sorted(files.items())},
        "tables": tinfo,
        "cipher_sets": csets,
        "coverage": compute_coverage(tables, traces, specs),
    }
    return files, manifest


def _manifest_bytes(manifest: dict) -> bytes:
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()


def generate(out_dir, p: CipherParams = DEFAULT_PARAMS) -> dict:
    files, manifest = build_all(p)
    d = Path(out_dir)
    d.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (d / name).write_bytes(data)
    (d / "manifest.json").write_bytes(_manifest_bytes(manifest))
    return manifest


def check(out_dir, p: CipherParams = DEFAULT_PARAMS) -> list[str]:
    """Doi chieu thu muc voi golden hien tai; tra danh sach van de (rong = khop hoan toan)."""
    files, manifest = build_all(p)
    d = Path(out_dir)
    problems = []
    if not (d / "manifest.json").exists():
        return ["thieu manifest.json"]
    for name, data in files.items():
        f = d / name
        if not f.exists():
            problems.append(f"thieu file {name}")
        elif f.read_bytes() != data:
            problems.append(f"{name}: khac voi golden hien tai")
    if (d / "manifest.json").read_bytes() != _manifest_bytes(manifest):
        problems.append("manifest.json: khac voi golden hien tai")
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir")
    ap.add_argument("--check", action="store_true", help="chi doi chieu, khong ghi")
    a = ap.parse_args(argv)
    if a.check:
        problems = check(a.out_dir)
        for pr in problems:
            print("SAI:", pr)
        print("KHOP: bo vector dung voi golden hien tai" if not problems else f"{len(problems)} van de")
        return 0 if not problems else 1
    m = generate(a.out_dir)
    print(f"da ghi {len(m['files']) + 1} file vao {a.out_dir}  (spec {m['spec_version']}, cau hinh {m['config_hash'][:12]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
