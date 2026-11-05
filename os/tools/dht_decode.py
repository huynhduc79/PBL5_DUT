#!/usr/bin/env python3
"""dht_decode.py - chay tren LAPTOP: giai ma file .chau cua bai thu DHT22 ra CSV.

  python dht_decode.py rec_*.chau --key key.hex [--refmodel <thu_muc_chua_refmodel>] [-o out.csv]

Giai ma bang golden model refmodel (Python) - doc lap voi ban C chay tren RTOS, nen
neu ket qua dung thi ca hai ban cai dat deu dung. Moi lan doc DHT22 = 2 mau N=16 lien tiep
(RH roi T), luon bat dau o idx chan.

Ban giai ma tong quat cho audio (tools/decode_chau.py) thuoc phan cua thanh vien ma hoa.
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import struct
import sys

FILE_HDR = struct.Struct(">4sB3BBBBBIQII")
BLOCK_HDR = struct.Struct(">HIBBBB")


def import_refmodel(path: str | None):
    """Tim refmodel: --refmodel, bien moi truong REFMODEL_PATH, hoac thu muc goc repo."""
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (path, os.environ.get("REFMODEL_PATH"), os.path.join(here, "..", "..")):
        if cand and os.path.isdir(os.path.join(cand, "refmodel")):
            sys.path.insert(0, os.path.abspath(cand))
            break
    try:
        from dataclasses import replace

        from refmodel.cipher import CipherCore
        from refmodel.framing import crc16_ccitt
        from refmodel.params import DEFAULT_PARAMS
    except ImportError:
        sys.exit("khong tim thay refmodel: dung --refmodel <thu muc chua refmodel/> hoac REFMODEL_PATH")
    return CipherCore, crc16_ccitt, replace(DEFAULT_PARAMS, N=16)


def read_header(data: bytes) -> dict:
    (magic, ver, s0, s1, s2, n, ch, shift, src, fs, start, key_id, first_ctr) = FILE_HDR.unpack_from(data)
    if magic != b"CHAU":
        raise ValueError("khong phai file .chau")
    return {"format_version": ver, "spec": f"{s0}.{s1}.{s2}", "N": n, "channels": ch, "shift": shift,
            "source": src, "fs_milli_hz": fs, "start_unix": start, "key_id": key_id, "first_ctr": first_ctr}


def decode_file(path: str, k_master: bytes, rm) -> tuple[dict, list[dict], int]:
    CipherCore, crc16_ccitt, p16 = rm
    data = open(path, "rb").read()
    hdr = read_header(data)
    if hdr["N"] != 16:
        raise ValueError(f"{path}: N={hdr['N']} (can 16)")
    pos, core, expect, rows, bad = FILE_HDR.size, None, None, [], 0
    pending = None                                      # mau RH dang cho mau T
    while pos + BLOCK_HDR.size <= len(data):
        sync, ctr, idx0, cnt, flags, _ = BLOCK_HDR.unpack_from(data, pos)
        end = pos + BLOCK_HDR.size + 2 * cnt
        if sync != 0xA55A or not 1 <= cnt <= 64 or end + 2 > len(data) \
                or crc16_ccitt(data[pos + 2:end]) != struct.unpack_from(">H", data, end)[0]:
            bad += 1
            pos += 1
            continue
        if expect != (ctr, idx0):                      # dau file hoac co mau bi mat
            core = CipherCore(k_master, p16, ctr0=ctr)
            core.advance(idx0)
            pending = None
        for k, c in enumerate(struct.unpack_from(f">{cnt}H", data, pos + BLOCK_HDR.size)):
            idx = idx0 + k
            p = core.decrypt(c)
            if idx % 2 == 0:
                pending = (ctr, idx, p, flags if k == 0 else 0)
            elif pending is not None:
                t_raw = p
                t10 = -(t_raw & 0x7FFF) if t_raw & 0x8000 else t_raw
                rows.append({"file": os.path.basename(path), "ctr": pending[0], "idx": pending[1],
                             "gap_before": pending[3] & 1, "rh_raw": pending[2], "t_raw": t_raw,
                             "rh_pct": pending[2] / 10, "temp_c": t10 / 10})
                pending = None
        expect = core.position
        pos = end + 2
    return hdr, rows, bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help="file .chau (co the dung glob)")
    ap.add_argument("--key", required=True, help="file chua K_master 64 ky tu hex")
    ap.add_argument("--refmodel", help="thu muc chua package refmodel/")
    ap.add_argument("-o", "--output", help="ghi CSV ra file (mac dinh: stdout)")
    args = ap.parse_args(argv)

    rm = import_refmodel(args.refmodel)
    k_master = bytes.fromhex(open(args.key, encoding="ascii").read().strip())
    if len(k_master) != 32:
        sys.exit("K_master phai dai 32 byte (64 ky tu hex)")

    paths = sorted(p for pat in args.files for p in (glob.glob(pat) or [pat]))
    out = open(args.output, "w", newline="", encoding="utf-8") if args.output else sys.stdout
    w = csv.DictWriter(out, fieldnames=["file", "ctr", "idx", "gap_before", "rh_raw", "t_raw", "rh_pct", "temp_c"])
    w.writeheader()
    for path in paths:
        hdr, rows, bad = decode_file(path, k_master, rm)
        w.writerows(rows)
        print(f"{os.path.basename(path)}: {len(rows)} lan doc, ctr dau={hdr['first_ctr']}, "
              f"source={hdr['source']}, byte hong={bad}", file=sys.stderr)
    if out is not sys.stdout:
        out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
