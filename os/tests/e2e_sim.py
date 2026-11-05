#!/usr/bin/env python3
"""e2e_sim.py - kiem thu dau-cuoi tren PC: sim_rtos -> chaosd -> .chau -> dht_decode (refmodel).

  python tests/e2e_sim.py --refmodel <thu muc chua refmodel/> [--sim build/sim_rtos.exe]

Kiem tra:
  1. Moi lan doc thanh cong ma RTOS ma hoa deu giai ma ra dung RH/T goc (doi chieu truth.csv).
  2. Lan doc hong / bi chan lease -> co co GAP_BEFORE o block ke tiep, khong lech dong bo.
  3. Chay lai lan 2 (gia lap khoi dong lai): moi ctr deu moi -> khong lap keystream.
  4. File tren "Linux" (outbox) khong chua K_master.
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OS_DIR = os.path.dirname(HERE)
KEY_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"   # khoa vector cong khai

sys.path.insert(0, os.path.join(OS_DIR, "tools"))
import dht_decode  # noqa: E402


def run_once(sim: str, work: str, tag: str, seed: int, count: int) -> str:
    truth = os.path.join(work, f"truth_{tag}.csv")
    key = os.path.join(work, "test.key")
    sim_cmd = f'"{sim}" --key "{key}" --period-ms 4 --count {count} --fail-pct 10 --seed {seed} --truth "{truth}"'
    if os.name != "nt":
        sim_cmd = sim_cmd.replace('"', "")
    cmd = [sys.executable, os.path.join(OS_DIR, "linux", "chaosd", "chaosd.py"), "--sim-cmd", sim_cmd,
           "--data-dir", os.path.join(work, "data"), "--rotate-s", "0.25", "--lease", "2",
           "--status-every", "0.3"]
    log = os.path.join(work, f"chaosd_{tag}.log")
    with open(log, "w", encoding="utf-8") as f:
        rc = subprocess.run(cmd, stderr=f, stdout=f, timeout=120).returncode
    assert rc == 0, f"chaosd tra {rc}, xem {log}"
    return truth


def block_ctrs(path: str) -> list[int]:
    data = open(path, "rb").read()
    pos, out = 32, []
    while pos + 10 <= len(data):
        _, ctr, _, cnt, _, _ = struct.unpack_from(">HIBBBB", data, pos)
        out.append(ctr)
        pos += 10 + 2 * cnt + 2
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refmodel", required=True)
    ap.add_argument("--sim", default=os.path.join(OS_DIR, "build", "sim_rtos.exe" if os.name == "nt" else "sim_rtos"))
    ap.add_argument("--count", type=int, default=240)
    args = ap.parse_args()
    args.sim = os.path.abspath(args.sim)

    rm = dht_decode.import_refmodel(args.refmodel)
    work = os.path.join(OS_DIR, "build", "e2e")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "test.key"), "w", encoding="ascii") as f:
        f.write(KEY_HEX + "\n")
    outbox = os.path.join(work, "data", "outbox")
    key = bytes.fromhex(KEY_HEX)
    fails = 0
    ctr_sets = []

    for run, seed in ((1, 11), (2, 22)):
        before = set(os.listdir(outbox)) if os.path.isdir(outbox) else set()
        truth_path = run_once(args.sim, work, f"run{run}", seed, args.count)
        files = sorted(os.path.join(outbox, n) for n in set(os.listdir(outbox)) - before)
        with open(truth_path, encoding="utf-8") as f:
            truth = list(csv.DictReader(f))
        ok_truth = [(int(r["rh_raw"]), int(r["t_raw"])) for r in truth if r["status"] == "0"]

        decoded, gaps = [], 0
        for p in files:
            _, rows, bad = dht_decode.decode_file(p, key, rm)
            fails += bad != 0
            decoded += [(r["rh_raw"], r["t_raw"]) for r in rows]
            gaps += sum(r["gap_before"] for r in rows)

        # decoded phai la day con (dung thu tu) cua cac lan doc thanh cong; phan thieu = bi chan lease
        it = iter(ok_truth)
        subseq = all(any(d == t for t in it) for d in decoded)
        n_fail = len(truth) - len(ok_truth)
        ctrs = sorted({c for p in files for c in block_ctrs(p)})
        ctr_sets.append(ctrs)
        ok = subseq and len(decoded) >= 0.8 * len(ok_truth) and (n_fail == 0 or gaps > 0)
        fails += not ok
        print(f"lan {run}: {len(files)} file, doc {len(truth)} lan ({n_fail} hong), "
              f"ma hoa+giai ma dung {len(decoded)}/{len(ok_truth)}, co GAP={gaps}, "
              f"ctr {ctrs[0]}..{ctrs[-1]} -> {'DAT' if ok else 'SAI'}")

    no_reuse = max(ctr_sets[0]) < min(ctr_sets[1])
    fails += not no_reuse
    print(f"khong lap ctr giua hai lan chay: {'DAT' if no_reuse else 'SAI'} "
          f"(lan 1 toi {max(ctr_sets[0])}, lan 2 tu {min(ctr_sets[1])})")

    leaked = any(key in open(os.path.join(outbox, n), "rb").read() for n in os.listdir(outbox))
    fails += leaked
    print(f"K_master khong xuat hien trong file outbox: {'DAT' if not leaked else 'SAI'}")
    print("KET QUA:", "TAT CA DAT" if fails == 0 else f"{fails} muc SAI")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
