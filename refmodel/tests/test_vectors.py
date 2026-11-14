"""Test cho gen_vectors.py: tinh tat dinh, dung dan (doi chieu oracle doc lap), do phu, bo cuc hex, che do --check."""

import binascii
import hashlib
import json

import pytest

from oracle import OracleCipher, hmac_fips198, oracle_lts, oracle_params
from refmodel import gen_vectors as gv
from refmodel.cipher import CipherCore
from refmodel.compare import parse_trace
from refmodel.fisher_yates import gather_bits
from refmodel.framing import parse_frame, parse_payload
from refmodel.lts import lts_core
from refmodel.params import DEFAULT_PARAMS, SPEC_VERSION
import dataclasses

P = DEFAULT_PARAMS


@pytest.fixture(scope="module")
def built():
    return gv.build_all()


def table(files, name):
    lines = files[f"{name}.csv"].decode().splitlines()
    head = lines[0].split(",")
    return head, [dict(zip(head, ln.split(","))) for ln in lines[1:]]


def hx(s):
    return int(s, 16)


# ------------------------------------------------------------------ chung
def test_deterministic():
    f1, m1 = gv.build_all()
    f2, m2 = gv.build_all()
    assert f1 == f2 and m1 == m2


def test_manifest_basics(built):
    files, m = built
    assert m["spec_version"] == SPEC_VERSION == "1.0.0"
    assert m["config_hash"] == P.config_hash()
    assert set(m["files"]) == set(files)
    for name, info in m["files"].items():
        assert info["sha256"] == hashlib.sha256(files[name]).hexdigest() and info["bytes"] == len(files[name])
    assert m["params"]["RESEED_INTERVAL"] == 64 and m["params"]["R_MIN"] == [1, 1]


def test_csv_has_no_stray_commas_and_headers_match_layout(built):
    files, m = built
    for name, info in m["tables"].items():
        head, rows = table(files, name)
        assert len(rows) == info["rows"]
        nums = [c for c in head if c in {l["name"] for l in info["layout"]}]
        assert [l["name"] for l in info["layout"]] == nums
        for r in rows:
            assert len(r) == len(head)


# ------------------------------------------------------------------ KAT
def test_kat_sha256(built):
    files, _ = built
    _, rows = table(files, "kat_sha256")
    got = {r["msg_hex"]: r["digest_hex"] for r in rows}
    assert got[""] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert got[b"abc".hex()] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    m56 = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    assert got[m56.hex()] == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    lens = {len(bytes.fromhex(k)) for k in got}
    assert {0, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128} <= lens          # bien dem (padding)
    for k, v in got.items():
        assert hashlib.sha256(bytes.fromhex(k)).hexdigest() == v


def test_kat_hmac(built):
    files, _ = built
    _, rows = table(files, "kat_hmac")
    rfc = [
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
        "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
    ]
    assert [r["mac_hex"] for r in rows[:4]] == rfc
    for r in rows:
        assert hmac_fips198(bytes.fromhex(r["key_hex"]), bytes.fromhex(r["msg_hex"])).hex() == r["mac_hex"]
    assert sum(1 for r in rows if len(r["key_hex"]) == 64) == 9              # 3 khoa 32 byte x 3 ctr


def test_kat_crc16(built):
    files, _ = built
    _, rows = table(files, "kat_crc16")
    for r in rows:
        assert binascii.crc_hqx(bytes.fromhex(r["data_hex"]), 0xFFFF) == hx(r["crc"])
    assert any(r["data_hex"] == b"123456789".hex() and hx(r["crc"]) == 0x29B1 for r in rows)


# ------------------------------------------------------------------ KDF
def test_kdf_matches_independent_oracle(built):
    files, _ = built
    _, rows = table(files, "kdf")
    assert len(rows) == 48
    for r in rows:
        key = hx(r["k_master"]).to_bytes(32, "big")
        ks, x0, rr = oracle_params(key, hx(r["ctr"]))
        assert (hx(r["k_session"]), hx(r["x0"]), hx(r["r_int"])) == (int.from_bytes(ks, "big"), x0, rr)


def test_kdf_words_directed_cases(built):
    files, _ = built
    _, rows = table(files, "kdf_words")
    by = {r["case"]: r for r in rows}
    for name in ("x0_xor_0_nonzero_words", "x0_xor_1", "x0_xor_2"):
        assert hx(by[name]["x0"]) == 2                                       # < 2 -> 2
    assert hx(by["x0_xor_3"]["x0"]) == 3 and hx(by["x0_max"]["x0"]) == 0xFFFFFFFF
    assert hx(by["x_zero"]["r_int"]) == 2**32 and hx(by["x_one"]["r_int"]) == 2**32 + 1
    assert hx(by["x_half"]["r_int"]) == 2**32 + 2**31 and hx(by["x_max"]["r_int"]) == P.R_MAX_INT
    assert hx(by["x_xor_mix_max"]["r_int"]) == P.R_MAX_INT
    for r in rows:                                                           # cong thuc doc lap
        ks = hx(r["k_session"]).to_bytes(32, "big")
        w = [int.from_bytes(ks[4 * i:4 * i + 4], "big") for i in range(8)]
        assert hx(r["x0"]) == max(2, w[0] ^ w[1] ^ w[2] ^ w[3])
        assert hx(r["r_int"]) == 2**32 + (w[4] ^ w[5] ^ w[6] ^ w[7])


# ------------------------------------------------------------------ LTS
def test_lts_step_vectors(built):
    files, _ = built
    _, rows = table(files, "lts_step")
    assert len(rows) == 66 + 1500 + 600
    for r in rows:
        x, rr, x0 = hx(r["x_in"]), hx(r["r_int"]), hx(r["x0"])
        assert oracle_lts(x, rr, x0) == hx(r["x_out"])
        assert hx(r["branch"]) == (1 if x >= P.HALF else 0)
        assert hx(r["guarded"]) == (1 if lts_core(x, rr, P)[0] <= 1 else 0)
        assert P.R_MIN_INT <= rr <= P.R_MAX_INT and x0 >= 2


def test_lts_edge_rows_cover_trap_behaviour(built):
    files, _ = built
    _, rows = table(files, "lts_step")
    edge = [r for r in rows if r["case"] == "edge"]
    r_mid = P.R_MIN_INT + P.R_SPAN_INT // 2
    half_rows = {hx(r["r_int"]): r for r in edge if hx(r["x_in"]) == P.HALF}
    assert hx(half_rows[r_mid]["guarded"]) == 1                              # r % 4 == 0: f(0.5) = 0
    assert hx(half_rows[r_mid + 1]["guarded"]) == 0 and hx(half_rows[r_mid + 1]["x_out"]) == P.MASK
    for x in (0, 1, P.MASK):
        assert all(hx(r["guarded"]) == 1 for r in edge if hx(r["x_in"]) == x)


# ------------------------------------------------------------------ ma hoa
def test_cipher_sets_match_independent_oracle_and_decrypt(built):
    files, m = built
    for name, cs in m["cipher_sets"].items():
        _, rows = table(files, name)
        assert len(rows) == cs["samples"]
        n, key = cs["N"], bytes.fromhex(cs["k_master"])
        orc = OracleCipher(key, n=n, reseed=cs["RESEED_INTERVAL"], ctr0=cs["ctr0"])
        q = dataclasses.replace(P, N=n, RESEED_INTERVAL=cs["RESEED_INTERVAL"])
        dec = CipherCore(key, q, ctr0=cs["ctr0"])
        for r in rows:
            c, ctr, idx = orc.encrypt(hx(r["p"]))
            assert (hx(r["c"]), hx(r["ctr"]), hx(r["idx"])) == (c, ctr, idx), name
            assert dec.decrypt(hx(r["c"])) == hx(r["p"]), name


def test_cipher_rows_internally_consistent(built):
    files, m = built
    for name, cs in m["cipher_sets"].items():
        n = cs["N"]
        _, rows = table(files, name)
        for r in rows:
            pi = tuple((hx(r["pi"]) >> (4 * i)) & 0xF for i in range(n))
            assert sorted(pi) == list(range(n))
            assert hx(r["c"]) == gather_bits(hx(r["p"]), pi) ^ hx(r["k"])
            assert hx(r["refills"]) >= 1 and hx(r["idx"]) < cs["RESEED_INTERVAL"]


def test_hex_files_match_csv_columns(built):
    files, m = built
    for name, info in m["tables"].items():
        if info["hex"] is None:
            continue
        head, rows = table(files, name)
        lines = files[info["hex"]].decode().splitlines()
        assert len(lines) == len(rows)
        digits = (info["word_bits"] + 3) // 4
        for line, row in zip(lines, rows):
            assert len(line) == digits and line == line.lower()
            word, shift = int(line, 16), info["word_bits"]
            for col in info["layout"]:
                shift -= col["bits"]
                assert (word >> shift) & ((1 << col["bits"]) - 1) == hx(row[col["name"]]), (name, col["name"])
            assert shift == 0


def test_traces_agree_with_tables(built):
    files, m = built
    for name in m["cipher_sets"]:
        ev = parse_trace(files[f"trace_{name}.txt"].decode())
        _, rows = table(files, name)
        assert ev[0].name == "RESEED_HMAC" and ev[0].sample == 0
        done = [e for e in ev if e.name == "DONE"]
        assert [int(e.fields[0], 16) for e in done] == [hx(r["c"]) for r in rows]
        finished = 0                                                         # so mau da xong truoc su kien nay
        for e in ev:
            assert e.sample == finished, (name, e.text())
            finished += e.name == "DONE"
        assert [e.sample for e in done] == list(range(len(rows)))
        ks = [e for e in ev if e.name == "LTS_KEYSTREAM"]
        assert [int(e.fields[2], 16) for e in ks] == [hx(r["k"]) for r in rows]
        px = [e for e in ev if e.name == "PERMUTE_XOR"]
        n = m["cipher_sets"][name]["N"]
        for e, r in zip(px, rows):
            assert [int(t, 16) for t in e.fields[0].split(".")] == [(hx(r["pi"]) >> (4 * i)) & 0xF for i in range(n)]


def test_coverage_requirements(built):
    _, m = built
    cov = m["coverage"]
    assert cov["lts_branch_low"] > 500 and cov["lts_branch_high"] > 500
    assert {"0", "1", "80000000", "ffffffff"} <= set(cov["lts_guarded_x_in"])
    c8, c16 = cov["cipher"]["enc_n8_default"], cov["cipher"]["enc_n16_default"]
    # moi pham vi KHONG phai luy thua cua 2 deu da bi loai it nhat 1 lan; luy thua cua 2 thi khong bao gio
    n8 = {}
    for name, c in cov["cipher"].items():
        if c["n"] == 8:
            for k, v in c["reject_by_range"].items():
                n8[int(k)] = n8.get(int(k), 0) + v
    assert {3, 5, 6, 7} <= set(n8) and not ({2, 4, 8} & set(n8))
    n16 = {int(k) for k in c16["reject_by_range"]}
    assert {3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15} <= n16 and not ({2, 4, 8, 16} & n16)
    refills8 = {}
    for c in cov["cipher"].values():
        if c["n"] == 8:
            for k, v in c["refills_hist"].items():
                refills8[int(k)] = refills8.get(int(k), 0) + v
    assert {1, 2} <= set(refills8)
    assert {2, 3} <= {int(k) for k in c16["refills_hist"]}
    # bien phien, tran ctr, reseed moi mau
    assert c8["max_idx"] == 63 and c8["reseeds"] >= 5 and c16["reseeds"] >= 2
    assert cov["cipher"]["enc_ctrwrap"]["ctr_wrapped"] is True
    assert cov["cipher"]["enc_reseed1"]["max_idx"] == 0
    assert any(c["n"] == 16 for c in cov["cipher"].values())


# ------------------------------------------------------------------ khung
def test_frames_table(built):
    files, _ = built
    _, rows = table(files, "frames")
    assert len(rows) == 5 + 40 + 20
    for r in rows:
        frame = bytes.fromhex(r["frame_hex"])
        fr = parse_frame(frame)
        assert (fr.ctr, fr.idx, fr.n, fr.c) == (hx(r["ctr"]), hx(r["idx"]), hx(r["n"]), hx(r["c"]))
        assert parse_payload(bytes.fromhex(r["payload_hex"])) == fr
        assert frame[-2:] == hx(r["crc"]).to_bytes(2, "big")
    assert rows[4]["frame_hex"] == "aa0102030405060807a643"
    assert len(bytes.fromhex(rows[0]["frame_hex"])) == 11 and len(bytes.fromhex(rows[2]["frame_hex"])) == 12


# ------------------------------------------------------------------ ghi / check
def test_generate_then_check_ok(tmp_path):
    m = gv.generate(tmp_path)
    assert (tmp_path / "manifest.json").exists() and (tmp_path / "README.txt").exists()
    assert json.loads((tmp_path / "manifest.json").read_text())["spec_version"] == m["spec_version"]
    assert gv.check(tmp_path) == []
    assert gv.main(["--check", str(tmp_path)]) == 0


def test_check_detects_tampering_missing_and_manifest_change(tmp_path):
    gv.generate(tmp_path)
    f = tmp_path / "enc_n8_default.hex"
    txt = f.read_text().splitlines()
    txt[10] = txt[10][:-1] + ("0" if txt[10][-1] != "0" else "1")
    f.write_text("\n".join(txt) + "\n")
    probs = gv.check(tmp_path)
    assert any("enc_n8_default.hex" in p for p in probs)
    assert gv.main(["--check", str(tmp_path)]) == 1

    gv.generate(tmp_path)
    (tmp_path / "lts_step.csv").unlink()
    assert any("thieu file lts_step.csv" in p for p in gv.check(tmp_path))

    gv.generate(tmp_path)
    mf = json.loads((tmp_path / "manifest.json").read_text())
    mf["spec_version"] = "9.9.9"
    (tmp_path / "manifest.json").write_text(json.dumps(mf, indent=2, sort_keys=True) + "\n")
    assert any("manifest.json" in p for p in gv.check(tmp_path))


def test_check_without_manifest(tmp_path):
    assert gv.check(tmp_path) == ["thieu manifest.json"]


def test_table_rejects_values_that_do_not_fit():
    t = gv.Table("x", [("a", "x", 4)], [(16,)])
    with pytest.raises(ValueError):
        t.csv_bytes()
    t2 = gv.Table("y", [("s", "s", 0)], [("a,b",)])
    with pytest.raises(ValueError):
        t2.csv_bytes()
