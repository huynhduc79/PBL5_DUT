"""Test cho compare.py: dinh dang trace, so sanh trace/CSV, bao cao sai lech, CLI."""

import pytest

from refmodel import gen_vectors as gv
from refmodel.compare import (
    EVENT_BLOCK,
    Event,
    compare_csv,
    compare_traces,
    format_event,
    format_report,
    main,
    normalize_token,
    parse_trace,
)


@pytest.fixture(scope="module")
def golden_text():
    files, _ = gv.build_all()
    return files["trace_enc_reseed1.txt"].decode()


# ------------------------------------------------------------------ dinh dang
def test_format_and_parse_roundtrip():
    line = format_event(7, "PERMUTE_XOR", ((3, 1, 0, 2), 0xAB, 255, True))
    assert line == "7,PERMUTE_XOR,3.1.0.2,ab,ff,1"
    (e,) = parse_trace(line + "\n")
    assert e == Event(7, "PERMUTE_XOR", ("3.1.0.2", "ab", "ff", "1"))
    assert e.text() == line
    assert format_event(0, "RESEED_HMAC", (1, b"\x00\xff", False)) == "0,RESEED_HMAC,1,00ff,0"


def test_parse_ignores_blank_and_comments_and_rejects_garbage():
    assert parse_trace("\n# ghi chu\n1,DONE,5\n") == [Event(1, "DONE", ("5",))]
    with pytest.raises(ValueError):
        parse_trace("khong phai trace\n")


def test_normalize_token():
    assert normalize_token("00AB") == "ab"
    assert normalize_token("0") == "0" and normalize_token("000") == "0"
    assert normalize_token("03.0A.00") == "3.a.0"
    assert normalize_token("") == ""
    assert normalize_token(" Ff ") == "ff"


# ------------------------------------------------------------------ trace
def test_identical_traces_match(golden_text):
    g = parse_trace(golden_text)
    res = compare_traces(g, g)
    assert res.ok and res.n_compared == len(g) and "KHOP" in format_report(res)


def test_subset_of_events_and_padding_tolerated(golden_text):
    g = parse_trace(golden_text)
    rtl_text = "\n".join(
        e.text().replace(",DONE,", ",DONE,0000").upper().replace("DONE", "DONE")        # chu hoa + so 0 dem
        for e in g if e.name in ("DONE", "LTS_KEYSTREAM")
    )
    res = compare_traces(g, parse_trace(rtl_text))
    assert res.ok and set(res.names) == {"DONE", "LTS_KEYSTREAM"}


def test_value_mismatch_reports_first_diverging_event(golden_text):
    g = parse_trace(golden_text)
    rtl = list(g)
    idx = next(i for i, e in enumerate(rtl) if e.name == "PERMUTE_XOR" and e.sample == 5)
    f = list(rtl[idx].fields); f[3] = "ff" if f[3] != "ff" else "fe"
    rtl[idx] = Event(rtl[idx].sample, rtl[idx].name, tuple(f))
    res = compare_traces(g, rtl)
    assert not res.ok
    m = res.mismatch
    assert m.golden.sample == 5 and m.golden.name == "PERMUTE_XOR" and m.reason == "gia tri truong khac"
    assert len(m.context) == 3
    rep = format_report(res)
    assert "SAI" in rep and EVENT_BLOCK["PERMUTE_XOR"] in rep and "golden" in rep and "rtl" in rep


def test_missing_extra_and_misordered_events(golden_text):
    g = parse_trace(golden_text)
    short = compare_traces(g, g[:-3], names=[e.name for e in g])
    assert not short.ok and short.mismatch.reason == "RTL thieu su kien"
    extra = compare_traces(g, g + [Event(99, "DONE", ("0",))], names=[e.name for e in g])
    assert not extra.ok and extra.mismatch.reason == "RTL thua su kien"
    swapped = list(g)
    swapped[3], swapped[4] = swapped[4], swapped[3]
    assert not compare_traces(g, swapped).ok


def test_partial_fields_lenient_vs_strict(golden_text):
    g = parse_trace(golden_text)
    rtl = [Event(e.sample, e.name, e.fields[:1]) for e in g if e.name == "LTS_KEYSTREAM"]
    assert compare_traces(g, rtl).ok                                  # chi so sanh truong dau
    assert not compare_traces(g, rtl, strict=True).ok
    rtl_more = [Event(e.sample, e.name, e.fields + ("1",)) for e in g if e.name == "DONE"]
    assert not compare_traces(g, rtl_more).ok                         # RTL nhieu truong hon -> sai


def test_events_argument_restricts_comparison(golden_text):
    g = parse_trace(golden_text)
    rtl = [Event(e.sample, e.name, ("0",)) if e.name == "FY_DRAW" else e for e in g]
    assert not compare_traces(g, rtl).ok
    assert compare_traces(g, rtl, names=["DONE", "PERMUTE_XOR"]).ok


# ------------------------------------------------------------------ CSV
CSV_G = "case,x,y\na,00ff,1\nb,0A,2\n"


def test_csv_match_and_padding():
    assert compare_csv(CSV_G, "case,x,y\na,FF,1\nb,a,2\n").ok


def test_csv_mismatch_locations():
    r = compare_csv(CSV_G, "case,x,y\na,ff,1\nb,0b,2\n")
    assert not r.ok and "dong 1" in r.message and "'x'" in r.message
    assert not compare_csv(CSV_G, "case,x,y\na,ff,1\n").ok
    assert "so dong khac nhau" in compare_csv(CSV_G, "case,x,y\na,ff,1\n").message
    assert not compare_csv(CSV_G, "case,z\na,1\nb,2\n", cols=["x"]).ok
    assert compare_csv(CSV_G, "case,x,y\na,ff,9\nb,a,9\n", cols=["x"]).ok


# ------------------------------------------------------------------ CLI
def test_cli_trace_and_csv(tmp_path, golden_text, capsys):
    gf = tmp_path / "g.txt"; gf.write_text(golden_text)
    ok = tmp_path / "ok.txt"; ok.write_text(golden_text)
    assert main(["trace", str(gf), str(ok)]) == 0
    lines = golden_text.splitlines()
    i = next(i for i, ln in enumerate(lines) if ",DONE," in ln and ln.startswith("4,"))
    lines[i] = lines[i].rsplit(",", 1)[0] + ",ee"
    bad = tmp_path / "bad.txt"; bad.write_text("\n".join(lines) + "\n")
    assert main(["trace", str(gf), str(bad)]) == 1
    assert "mau 4" in capsys.readouterr().out
    assert main(["trace", str(gf), str(bad), "--events", "LTS_KEYSTREAM"]) == 0
    assert main(["trace", str(gf), str(tmp_path / "khong_co.txt")]) == 2
    gc = tmp_path / "g.csv"; gc.write_text(CSV_G)
    rc = tmp_path / "r.csv"; rc.write_text("case,x,y\na,ff,1\nb,a,2\n")
    assert main(["csv", str(gc), str(rc)]) == 0
    assert main(["csv", str(gc), str(rc), "--cols", "x,y"]) == 0
