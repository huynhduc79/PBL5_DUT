"""compare.py - so sanh log / CSV cua RTL voi golden model va chi ra cho sai dau tien.

Dinh dang trace (moi su kien mot dong, ten theo trang thai FSM muc 5.3.4):

    <so_mau>,<TEN_SU_KIEN>,<truong1>,<truong2>,...

  * so nguyen / co: hex thuong, khong tien to (co: 0 hoac 1);  bytes: hex;
  * day so (vd hoan vi pi): cac so hex noi bang dau '.'  (vd 3.1.0.2.7.6.5.4).
  * Khi so sanh, chu hoa/thuong va so 0 dung dau bi bo qua (RTL co the in do rong co dinh).
  * Su kien truoc mau dau tien (RESEED_HMAC luc khoi tao) mang so_mau = 0 cung voi mau 0.

Ten su kien (golden): RESEED_HMAC, LTS_KEYSTREAM, FY_INIT, FY_REFILL, FY_DRAW, FY_SWAP,
PERMUTE_XOR, CHECK_RESEED, DONE. RTL chi can in tap con; so sanh chi xet cac ten co trong log RTL
(hoac --events). Neu RTL in it truong hon golden thi chi so sanh cac truong dau (che do mac dinh).

Dung:
    python -m refmodel.compare trace  golden_trace.txt  rtl_trace.txt  [--events A,B] [--strict]
    python -m refmodel.compare csv    golden.csv        rtl.csv        [--cols c,k]
Ma thoat: 0 khop, 1 co sai lech, 2 loi dau vao.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass

# Khoi RTL (muc 5.3.1) phu trach tung su kien, de goi y noi can sua khi sai.
EVENT_BLOCK = {
    "RESEED_HMAC": "HMAC-SHA256 Core / Parameter Derivation Unit",
    "LTS_KEYSTREAM": "LTS Iterator (lap LTS + lay keystream)",
    "FY_INIT": "Fisher-Yates (khoi tao)",
    "FY_REFILL": "Fisher-Yates / bit pool (nap bit, lap LTS)",
    "FY_DRAW": "Fisher-Yates (rut so, rejection sampling)",
    "FY_SWAP": "Fisher-Yates (hoan doi)",
    "PERMUTE_XOR": "Hoan vi bit + XOR",
    "CHECK_RESEED": "FSM / Session (dem mau, tai tao phien)",
    "DONE": "FSM / giao dien bus (dau ra)",
}


@dataclass(frozen=True)
class Event:
    sample: int
    name: str
    fields: tuple[str, ...]

    def text(self) -> str:
        return ",".join([str(self.sample), self.name, *self.fields])


# ------------------------------------------------------------------ dinh dang
def _tok(v) -> str:
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return f"{v:x}"
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).hex()
    if isinstance(v, (tuple, list)):
        return ".".join(_tok(x) for x in v)
    return str(v)


def format_event(sample: int, name: str, data) -> str:
    return ",".join([str(sample), name, *(_tok(v) for v in data)])


def parse_trace(text: str) -> list[Event]:
    out = []
    for ln, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(",")
        if len(parts) < 2 or not parts[0].strip().lstrip("-").isdigit():
            raise ValueError(f"dong {ln}: khong phai '<so_mau>,<TEN>,...': {line[:60]!r}")
        out.append(Event(int(parts[0]), parts[1].strip(), tuple(p.strip() for p in parts[2:])))
    return out


def normalize_token(tok: str) -> str:
    """Chu thuong, bo so 0 dung dau o tung phan cach boi '.'; giu lai it nhat mot ky tu."""
    parts = []
    for p in tok.strip().lower().split("."):
        q = p.lstrip("0")
        parts.append(q if q else ("0" if p else ""))
    return ".".join(parts)


# ------------------------------------------------------------------ so sanh trace
@dataclass(frozen=True)
class Mismatch:
    index: int                    # vi tri trong day su kien da loc
    golden: Event
    rtl: Event | None
    context: tuple[Event, ...]    # cac su kien khop ngay truoc do
    reason: str


@dataclass(frozen=True)
class TraceResult:
    ok: bool
    n_compared: int
    names: tuple[str, ...]
    mismatch: Mismatch | None
    n_golden: int
    n_rtl: int


def _fields_match(g: Event, r: Event, strict: bool) -> bool:
    gf = [normalize_token(x) for x in g.fields]
    rf = [normalize_token(x) for x in r.fields]
    if strict or len(rf) >= len(gf):
        return gf == rf
    return gf[:len(rf)] == rf


def compare_traces(golden: list[Event], rtl: list[Event], names=None, strict: bool = False,
                   context: int = 3) -> TraceResult:
    names = tuple(sorted(names if names is not None else {e.name for e in rtl}))
    g = [e for e in golden if e.name in names]
    r = [e for e in rtl if e.name in names]
    for i in range(min(len(g), len(r))):
        if (g[i].sample, g[i].name) != (r[i].sample, r[i].name):
            return TraceResult(False, i, names, Mismatch(i, g[i], r[i], tuple(g[max(0, i - context):i]),
                               "sai thu tu/so mau hoac ten su kien"), len(g), len(r))
        if not _fields_match(g[i], r[i], strict):
            return TraceResult(False, i, names, Mismatch(i, g[i], r[i], tuple(g[max(0, i - context):i]),
                               "gia tri truong khac"), len(g), len(r))
    if len(g) != len(r):
        i = min(len(g), len(r))
        gi = g[i] if i < len(g) else g[-1]
        ri = r[i] if i < len(r) else None
        reason = "RTL thieu su kien" if len(r) < len(g) else "RTL thua su kien"
        return TraceResult(False, i, names, Mismatch(i, gi, ri, tuple(g[max(0, i - context):i]), reason), len(g), len(r))
    return TraceResult(True, len(g), names, None, len(g), len(r))


def format_report(res: TraceResult) -> str:
    if res.ok:
        return f"KHOP: {res.n_compared} su kien ({', '.join(res.names)})"
    m = res.mismatch
    lines = [f"SAI tai su kien #{m.index} (mau {m.golden.sample}): {m.reason}",
             f"  khoi nghi ngo : {EVENT_BLOCK.get(m.golden.name, '?')}",
             f"  golden        : {m.golden.text()}",
             f"  rtl           : {m.rtl.text() if m.rtl else '(het log)'}"]
    if m.context:
        lines.append("  ngay truoc do (da khop):")
        lines += [f"    {e.text()}" for e in m.context]
    lines.append(f"  (golden {res.n_golden} su kien, rtl {res.n_rtl} su kien sau khi loc)")
    return "\n".join(lines)


# ------------------------------------------------------------------ so sanh CSV
def parse_csv(text: str) -> tuple[list[str], list[list[str]]]:
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        raise ValueError("CSV rong")
    header = [h.strip() for h in lines[0].split(",")]
    return header, [[c.strip() for c in ln.split(",")] for ln in lines[1:]]


@dataclass(frozen=True)
class CsvResult:
    ok: bool
    n_rows: int
    cols: tuple[str, ...]
    message: str


def compare_csv(golden_text: str, rtl_text: str, cols=None) -> CsvResult:
    gh, grows = parse_csv(golden_text)
    rh, rrows = parse_csv(rtl_text)
    cols = tuple(cols) if cols else tuple(c for c in gh if c in rh)
    missing = [c for c in cols if c not in gh or c not in rh]
    if missing or not cols:
        return CsvResult(False, 0, cols, f"thieu cot trong mot trong hai file: {missing or 'khong co cot chung'}")
    gi = {c: gh.index(c) for c in cols}
    ri = {c: rh.index(c) for c in cols}
    for n in range(min(len(grows), len(rrows))):
        for c in cols:
            a, b = normalize_token(grows[n][gi[c]]), normalize_token(rrows[n][ri[c]])
            if a != b:
                return CsvResult(False, n, cols, f"dong {n}, cot {c!r}: golden={grows[n][gi[c]]} rtl={rrows[n][ri[c]]}")
    if len(grows) != len(rrows):
        return CsvResult(False, min(len(grows), len(rrows)), cols,
                         f"so dong khac nhau: golden {len(grows)}, rtl {len(rrows)}")
    return CsvResult(True, len(grows), cols, f"KHOP: {len(grows)} dong, cot {', '.join(cols)}")


# ------------------------------------------------------------------ CLI
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="mode", required=True)
    t = sub.add_parser("trace")
    t.add_argument("golden"); t.add_argument("rtl")
    t.add_argument("--events", default=None, help="danh sach ten su kien, cach nhau boi dau phay")
    t.add_argument("--strict", action="store_true", help="bat buoc so truong bang nhau")
    c = sub.add_parser("csv")
    c.add_argument("golden"); c.add_argument("rtl")
    c.add_argument("--cols", default=None)
    a = ap.parse_args(argv)
    try:
        gtext = open(a.golden, encoding="utf-8").read()
        rtext = open(a.rtl, encoding="utf-8").read()
        if a.mode == "trace":
            names = a.events.split(",") if a.events else None
            res = compare_traces(parse_trace(gtext), parse_trace(rtext), names, a.strict)
            print(format_report(res))
            return 0 if res.ok else 1
        res = compare_csv(gtext, rtext, a.cols.split(",") if a.cols else None)
        print(res.message)
        return 0 if res.ok else 1
    except (OSError, ValueError) as e:
        print(f"loi: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
