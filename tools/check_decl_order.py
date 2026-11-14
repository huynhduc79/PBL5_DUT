"""check_decl_order.py - tim bien / wire dung truoc khi khai bao trong file Verilog.
ModelSim bao loi vlog-2730 "Undefined variable" cho truong hop nay; Icarus va Verilator thi bo qua, nen phai kiem rieng
truoc khi dua file sang Libero. Chay:  python tools/check_decl_order.py <file.v> ...

Xet tung module rieng (file co nhieu module, vd. testbench kem mo hinh). Cong khai bao kieu ANSI trong danh sach cong
(input / output / inout) tinh la khai bao o dau module. Bien cuc bo trong task / function bi bo qua.
Thoat voi ma 1 neu co loi.
"""
import re
import sys

DECL = re.compile(r"\s*(reg|integer|wire|localparam|parameter|input|output|inout|genvar|real|time)\b(.*)")
SKIP_WORDS = {"signed", "reg", "wire", "integer", "unsigned"}


def strip(line):
    line = re.sub(r'"[^"]*"', '""', re.sub(r"//.*", "", line))
    return re.sub(r"\d*'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_?]+", "0", line)     # hang co do rong: 32'd0 -> 0


def drop_groups(text):
    """Bo noi dung trong {} va () (de dau phay ben trong khong tach nham ten)."""
    prev = None
    while prev != text:
        prev = text
        text = re.sub(r"\{[^{}]*\}", "0", text)
        text = re.sub(r"\([^()]*\)", "0", text)
    return text


def check_module(lines, first_lineno, path):
    """lines: cac dong cua MOT module (da bo chu thich)."""
    decl, depth_tf = {}, 0
    for i, l in enumerate(lines):
        if re.search(r"\b(task|function)\b", l) and not re.search(r"\bend(task|function)\b", l):
            depth_tf += 1
        if re.search(r"\bend(task|function)\b", l):
            depth_tf = max(0, depth_tf - 1)
            continue
        if depth_tf:
            continue                                   # bien cuc bo cua task / function
        m = DECL.match(l)
        if not m:
            continue
        kind, body = m.group(1), m.group(2)
        body = drop_groups(re.sub(r"\[[^\]]*\]", "", body))
        if kind in ("wire", "localparam", "parameter", "reg", "integer"):
            body = re.sub(r"=[^,;]*", "", body)          # bo phan gan gia tri ban dau
        j = i + 1
        while body.rstrip().endswith(",") and j < len(lines) and not DECL.match(lines[j]):
            body += re.sub(r"\[[^\]]*\]", "", lines[j])
            j += 1
        for name in re.findall(r"\b([A-Za-z_]\w*)\b", body):
            if name not in SKIP_WORDS:
                decl.setdefault(name, i)
    bad = 0
    for name, dl in decl.items():
        for i, l in enumerate(lines[:dl]):
            if re.search(r"\b%s\b" % re.escape(name), l):
                print(f"{path}:{first_lineno + i}: '{name}' dung truoc khai bao (dong {first_lineno + dl})")
                bad += 1
                break
    return bad


def check_file(path):
    raw = open(path, encoding="utf-8", errors="replace").read().split("\n")
    clean = [strip(l) for l in raw]
    bad, start = 0, None
    for i, l in enumerate(clean):
        if re.match(r"\s*module\b", l):
            start = i
        elif re.match(r"\s*endmodule\b", l) and start is not None:
            bad += check_module(clean[start:i + 1], start + 1, path)
            start = None
    print(path, "OK" if bad == 0 else f"{bad} loi")
    return bad


if __name__ == "__main__":
    total = sum(check_file(p) for p in sys.argv[1:])
    sys.exit(1 if total else 0)
