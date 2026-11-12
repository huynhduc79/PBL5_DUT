#!/usr/bin/env python3
"""e2e_audio.py - kiem thu dau-cuoi tren PC: sim_audio (RTOS + mo hinh FPGA) -> chaosd -> .chau -> refmodel.

  python tests/e2e_audio.py --refmodel D:/PBL5/chaos_refmodel_v1.0.0/chaos_project

Kiem tra:
  1. Nguon RAMP giai ma ra dung 0, 1, 2, ... ; RTOS bi tre -> co GAP, nhay dung drop_before,
     keystream khong lech (khong co dut (ctr, idx)).
  2. Mat dien giua luc ghi (kill RTOS): lan sau ctr bat dau LON HON moi ctr da thay.
  3. Chay lai binh thuong: ctr lan 2 > lan 1 (khong lap keystream).
  4. Nguon MIC chay qua STARTUP_SKIP, giai ma duoc, ra WAV.
  5. File tren "Linux" (outbox) khong chua K_master.
"""

from __future__ import annotations

import argparse
import glob
import os
import shutil
import struct
import subprocess
import sys
import time
from dataclasses import replace

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KEY_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"   # khoa vector cong khai
EXE = ".exe" if os.name == "nt" else ""

sys.path.insert(0, os.path.join(ROOT, "tools"))
import verify_chau  # noqa: E402


def chaosd(work: str, tag: str, sim_args: str, source: str) -> str:
    sim = os.path.join(ROOT, "build", "sim_audio" + EXE)
    key, nvm = os.path.join(work, "test.key"), os.path.join(work, "nvm.bin")
    sim_cmd = f'"{sim}" --key "{key}" --nvm "{nvm}" {sim_args}'
    if os.name != "nt":
        sim_cmd = sim_cmd.replace('"', "")
    data = os.path.join(work, tag)
    cmd = [sys.executable, os.path.join(ROOT, "linux", "chaosd", "chaosd.py"), "--sim-cmd", sim_cmd,
           "--data-dir", data, "--source", source, "--rotate-s", "0.2", "--status-every", "1000"]
    log = os.path.join(work, f"chaosd_{tag}.log")
    with open(log, "w", encoding="utf-8") as f:
        rc = subprocess.run(cmd, stderr=f, stdout=f, timeout=300).returncode
    assert rc == 0, f"chaosd tra {rc}, xem {log}"
    return os.path.join(data, "outbox", "*.chau")


def check(pattern: str, key: bytes, cc, p16, crc, wav: str | None = None) -> verify_chau.Report:
    rep = verify_chau.Report()
    verify_chau.verify(sorted(glob.glob(pattern)), key, rep, cc, p16, crc)
    if wav:
        import wave
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(round(rep.fs))
            w.writeframes(struct.pack(f"<{len(rep.pcm)}h", *rep.pcm))
    print(f"   {rep.files} file, {rep.blocks} block, {rep.samples} mau, ctr {min(rep.ctrs)}..{max(rep.ctrs)}, "
          f"GAP {rep.gaps} (bo {rep.dropped}), CRC sai {rep.crc_errors}, dut {rep.seq_breaks}, RAMP sai {rep.ramp_errors}")
    return rep


def killed_run(work: str) -> int:
    """Chay RTOS khong qua chaosd, START roi kill giua chung; tra ctr lon nhat thay o dau ra."""
    sim = os.path.join(ROOT, "build", "sim_audio" + EXE)
    p = subprocess.Popen([sim, "--key", os.path.join(work, "test.key"), "--nvm", os.path.join(work, "nvm.bin"),
                          "--speed", "20"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    p.stdin.write(b"START ramp 0\n")
    p.stdin.flush()
    time.sleep(1.0)
    p.kill()                                   # "mat dien": khong STOP, khong ghi gi them
    out = p.stdout.read()
    p.wait()
    best, pos = -1, 0
    while True:
        pos = out.find(b"\xa5\x5a", pos)
        if pos < 0 or pos + 10 > len(out):
            break
        best = max(best, struct.unpack_from(">I", out, pos + 2)[0])
        pos += 2
    return best


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refmodel", required=True)
    a = ap.parse_args()
    sys.path.insert(0, a.refmodel)
    from refmodel.cipher import CipherCore
    from refmodel.framing import crc16_ccitt
    from refmodel.params import DEFAULT_PARAMS
    p16 = replace(DEFAULT_PARAMS, N=16)

    work = os.path.join(ROOT, "build", "e2e")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "test.key"), "w", encoding="ascii") as f:
        f.write(KEY_HEX + "\n")
    key = bytes.fromhex(KEY_HEX)
    ok = True

    def expect(cond: bool, msg: str) -> None:
        nonlocal ok
        print(("   DAT  " if cond else "   SAI  ") + msg)
        ok &= cond

    print("1. RAMP, RTOS bi tre 150 ms moi 2 s (6 s am thanh)")
    r1 = check(chaosd(work, "run1", "--run-s 6 --speed 50 --stall-ms 150 --stall-every-s 2", "ramp"),
               key, CipherCore, p16, crc16_ccitt)
    expect(r1.ramp_errors == 0 and r1.crc_errors == 0 and r1.seq_breaks == 0, "giai ma dung RAMP, khong lech keystream")
    expect(r1.gaps >= 2 and r1.dropped > 0, "co GAP khi RTOS tre, drop_before khop buoc nhay RAMP")
    expect(r1.samples + r1.dropped >= int(6 * 15625 * 0.97), "so mau + mau bo ~ 6 s x 15 625 Hz")

    print("2. Mat dien giua luc ghi")
    dead_max = killed_run(work)
    r2 = check(chaosd(work, "run2", "--run-s 2 --speed 50", "ramp"), key, CipherCore, p16, crc16_ccitt)
    expect(dead_max >= 0, f"lan bi kill co ma hoa (ctr toi {dead_max})")
    expect(min(r2.ctrs) > max(max(r1.ctrs), dead_max), "ctr sau khi mat dien lon hon moi ctr da dung")
    expect(r2.ramp_errors == 0 and r2.seq_breaks == 0, "lan 2 giai ma dung")

    print("3. Nguon MIC (gia), co STARTUP_SKIP")
    wav = os.path.join(work, "mic_dec.wav")
    r3 = check(chaosd(work, "run3", "--run-s 3 --speed 50", "mic"), key, CipherCore, p16, crc16_ccitt, wav)
    expect(r3.crc_errors == 0 and r3.seq_breaks == 0, "giai ma MIC khong loi")
    expect(r3.samples <= 3 * 15625 - 4096 + 64, "da bo 4096 mau khoi dong")
    expect(min(r3.ctrs) > max(r2.ctrs), "ctr lan 3 > lan 2")

    print("4. Bi mat")
    blob = b"".join(open(p, "rb").read() for p in glob.glob(os.path.join(work, "run*", "outbox", "*.chau")))
    expect(key not in blob and key[:16] not in blob, "K_master khong co trong file outbox")

    print("TAT CA DAT" if ok else "CO MUC SAI")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
