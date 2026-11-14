"""Kiem tra bo giai ma .chau: dung golden model tao file, co GAP va mat block, roi giai ma lai."""
import os
import struct
import sys
from dataclasses import replace

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from refmodel.params import DEFAULT_PARAMS  # noqa: E402
from refmodel.cipher import CipherCore
from refmodel.framing import crc16_ccitt

P16 = replace(DEFAULT_PARAMS, N=16)
KEY = bytes(range(32))
FS_MILLI = 15625000


# ----------------------------------------------------------------- bo giai ma (ban dua vao tai lieu)
def decode_chau(path_or_bytes, k_master):
    data = path_or_bytes if isinstance(path_or_bytes, bytes) else open(path_or_bytes, "rb").read()
    assert data[:4] == b"CHAU", "khong phai file .chau"
    fs = struct.unpack(">I", data[12:16])[0] / 1000
    pos, samples, core, expect = 32, [], None, None
    while pos + 12 <= len(data):
        sync, ctr, idx0, cnt, flags, _, drop = struct.unpack(">HIBBBBH", data[pos:pos + 12])
        end = pos + 12 + 2 * cnt
        if sync != 0xA55A or cnt == 0 or cnt > 64 or end + 2 > len(data) \
           or crc16_ccitt(data[pos + 2:end]) != struct.unpack(">H", data[end:end + 2])[0]:
            pos += 1                      # tim sync ke tiep
            continue

        # (1) mat block sau ma hoa: keystream DA tieu thu -> phai chay khong tai cho bat lai pha
        if expect != (ctr, idx0):
            lost = 0
            if expect is not None:
                lost = (ctr - expect[0]) * P16.RESEED_INTERVAL + (idx0 - expect[1])
            if core is None or not (0 < lost <= 64 * 4096):
                core = CipherCore(k_master, P16, ctr0=ctr)    # file moi / nhay xa: dung lai tu dau phien
                core.advance(idx0)
            else:
                core.advance(lost)                            # mat block: giu nguyen mach keystream
                samples.extend([0] * lost)                    # lo thoi gian do mat block

        # (2) GAP: bo TRUOC khi ma hoa -> keystream LIEN MACH, chi chen lang, KHONG advance
        if flags & 1:
            samples.extend([0] * drop)

        for c in struct.unpack(f">{cnt}H", data[pos + 12:end]):
            p = core.decrypt(c)
            samples.append(p - 0x10000 if p & 0x8000 else p)
        expect = core.position
        pos = end + 2
    return fs, samples


# ----------------------------------------------------------------- bo tao file de thu
def make_block(ctr, idx0, pcm, gap=False, drop=0, test_src=False):
    flags = (1 if gap else 0) | (2 if test_src else 0)
    body = struct.pack(">IBBBBH", ctr, idx0, len(pcm), flags, 0, drop)
    body += b"".join(struct.pack(">H", c & 0xFFFF) for c in pcm)
    return b"\xa5\x5a" + body + struct.pack(">H", crc16_ccitt(body))


def build(ctr0, plain, drop_at=None, drop_n=0, lose_blocks=()):
    """plain: danh sach mau 16 bit co dau. drop_at: chi so mau bi bo TRUOC ma hoa."""
    core = CipherCore(KEY, P16, ctr0=ctr0)
    hdr = b"CHAU" + bytes([1, 1, 0, 0, 16, 1, 0, 0]) + struct.pack(">I", FS_MILLI) \
        + struct.pack(">Q", 0) + struct.pack(">II", 0, ctr0)

    kept = [s for i, s in enumerate(plain) if drop_at is None or not (drop_at <= i < drop_at + drop_n)]
    # RTOS DONG block ngay khi thay GAP, roi mo block moi voi GAP_BEFORE -> mo phong dung the
    gap_at = drop_at if drop_at is not None else -1
    blocks, cur, cur_ctr, cur_idx, cur_gap = [], [], None, None, False
    for n, s in enumerate(kept):
        ctr, idx = core.position
        if cur and (ctr != cur_ctr or len(cur) == 64 or n == gap_at):
            blocks.append(make_block(cur_ctr, cur_idx, cur, cur_gap, drop_n if cur_gap else 0))
            cur, cur_gap = [], False
        if not cur:
            cur_ctr, cur_idx, cur_gap = ctr, idx, (n == gap_at)
        cur.append(core.encrypt(s & 0xFFFF).c)
    if cur:
        blocks.append(make_block(cur_ctr, cur_idx, cur, cur_gap, drop_n if cur_gap else 0))

    # ky vong: chen 0 cho cho bi bo truoc ma hoa, va cho cac mau nam trong block bi mat
    expect = kept[:gap_at] + [0] * drop_n + kept[gap_at:] if drop_at is not None else list(kept)
    lost_idx = set()
    off, seen = 0, 0
    for b, blk in enumerate(blocks):
        cnt = blk[7]
        if drop_at is not None and seen == gap_at:
            off += drop_n
        if b in lose_blocks:
            lost_idx.update(range(seen + off, seen + off + cnt))
        seen += cnt
    for b in sorted(lose_blocks, reverse=True):
        del blocks[b]
    return hdr + b"".join(blocks), expect, lost_idx


def run(name, ctr0, plain, **kw):
    data, expect, lost_idx = build(ctr0, plain, **kw)
    fs, got = decode_chau(data, KEY)
    ok_fs = abs(fs - FS_MILLI / 1000) < 1e-9
    ok_len = len(got) == len(expect)
    # moi mau KHONG nam trong block bi mat phai khop tuyet doi; mau bi mat phai la 0
    bad = [i for i in range(min(len(got), len(expect)))
           if (got[i] != 0 if i in lost_idx else got[i] != expect[i])]
    ok = ok_fs and ok_len and not bad
    note = "" if ok else f"  <-- {len(bad)} sai, len {len(got)}/{len(expect)}"
    print(f"{name:34s} {len(got):4d} mau, {len(lost_idx):3d} mau trong block mat  "
          f"{'PASS' if ok else 'FAIL'}{note}")
    return ok


if __name__ == "__main__":
    ramp = [((i * 1103515245 + 12345) >> 8) & 0xFFFF for i in range(400)]
    ramp = [v - 0x10000 if v & 0x8000 else v for v in ramp]
    seq = list(range(300))

    r = []
    r.append(run("RAMP 300 mau, ctr0=0", 0, seq))
    r.append(run("Ngau nhien 400 mau, ctr0=0", 0, ramp))
    r.append(run("ctr0 lech (=1000)", 1000, seq))
    r.append(run("ctr0 sat bien (2^32-3)", 2**32 - 3, seq[:200]))
    r.append(run("GAP: bo 7 mau tu vi tri 100", 0, seq, drop_at=100, drop_n=7))
    r.append(run("GAP: bo 200 mau tu vi tri 50", 0, seq, drop_at=50, drop_n=200))
    r.append(run("Mat 1 block giua file", 0, seq, lose_blocks=(2,)))
    r.append(run("Mat 2 block khong lien nhau", 0, seq, lose_blocks=(1, 3)))

    print()
    print("TAT CA PASS" if all(r) else "CO LOI")
