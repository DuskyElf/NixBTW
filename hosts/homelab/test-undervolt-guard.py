#!/usr/bin/env python3
"""Exercise the boot guard and the P-state arithmetic in cpu.nix.

    python3 hosts/homelab/test-undervolt-guard.py

The MSR accessors are replaced with a JSON-backed fake (a real /dev/cpu/N/msr
addresses each register by its number, so adjacent numbers cannot be faked with
one byte array); everything else, the marker logic, the arithmetic, the floor
and the agreement checks, is the code that ships, run as a subprocess against
fake MSR state. Nothing here needs root, and nothing touches this machine's
MSRs: it exists so a change to the guard can be checked before a boot depends on
it.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = 0xC0010064
STEP = 8
# The stock table this box ships (read off the real machine).
STOCK = [0x8000016800006410, 0x800001630000880B, 0x8000013E0000AC07,
         0x800001330000BC04, 0x8000012C0000CC02, 0x800001260000D450,
         0x800001220040DC4C]
STOCK_VID = [50, 68, 86, 94, 102, 106, 110]


def build(root):
    src = open(f"{REPO}/hosts/homelab/cpu.nix").read()
    body = textwrap.dedent(src.split("text = ''\n", 1)[1].split("\n    '';", 1)[0])
    db = f"{root}/msr.json"
    fake = f'''import json

DB = "{db}"


def _load():
    with open(DB) as f:
        return json.load(f)


def _save(d):
    with open(DB, "w") as f:
        json.dump(d, f)


def rd(cpu, reg):
    return _load()["%d:%d" % (cpu, reg)]


def wr(cpu, reg, val):
    d = _load()
    d["%d:%d" % (cpu, reg)] = val
    _save(d)

'''
    body = re.sub(r"def cpus\(wait=10\.0\):.*?\ndef rd\(", "def cpus(wait=10.0):\n    return [0, 1, 2, 3]\n\n\ndef rd(", body, flags=re.S)
    body = re.sub(r"def rd\(cpu, reg\):.*?\ndef table\(", fake + "def table(", body, flags=re.S)
    body = body.replace('DIR = "/var/lib/homelab-undervolt"', f'DIR = "{root}/state"')
    path = f"{root}/undervolt.py"
    with open(path, "w") as f:
        f.write(body)
    reset(root)
    return path


def reset(root, table=None):
    table = STOCK if table is None else table
    d = {}
    for cpu in range(4):
        for i in range(7):
            d[f"{cpu}:{BASE + i}"] = table[i]
        d[f"{cpu}:{0xC0010071}"] = (2 << 16) | (86 << 9)
    with open(f"{root}/msr.json", "w") as f:
        json.dump(d, f)


def set_reg(root, cpu, i, value):
    with open(f"{root}/msr.json") as f:
        d = json.load(f)
    d[f"{cpu}:{BASE + i}"] = value
    with open(f"{root}/msr.json", "w") as f:
        json.dump(d, f)


def set_vid(root, i, vid):
    with open(f"{root}/msr.json") as f:
        d = json.load(f)
    for cpu in range(4):
        k = f"{cpu}:{BASE + i}"
        d[k] = (d[k] & ~(0xFF << 9)) | (vid << 9)
    with open(f"{root}/msr.json", "w") as f:
        json.dump(d, f)


def vids(root, cpu=0):
    with open(f"{root}/msr.json") as f:
        d = json.load(f)
    return [(d[f"{cpu}:{BASE + i}"] >> 9) & 0xFF for i in range(7)]


def run(path, *args):
    r = subprocess.run([sys.executable, path, *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def mark(root):
    try:
        return open(f"{root}/state/state").read().strip()
    except FileNotFoundError:
        return ""


def clear(root):
    for f in ("state", "stock"):
        try:
            os.remove(f"{root}/state/{f}")
        except FileNotFoundError:
            pass


fails = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + (("  " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(name)


root = f"{REPO}/.tmp/guard-test"
shutil.rmtree(root, ignore_errors=True)
os.makedirs(f"{root}/state")
try:
    path = build(root)

    rc, out = run(path, "apply")
    check("first boot applies", vids(root) == [v + STEP for v in STOCK_VID], str(vids(root)))
    check("all four cpus written", all(vids(root, c) == [v + STEP for v in STOCK_VID] for c in range(4)))
    check("first boot leaves pending", mark(root) == "pending", mark(root))
    check("apply exits 0", rc == 0, out)

    rc, _ = run(path, "confirm")
    check("confirm writes ok", mark(root) == "ok", mark(root))

    rc, _ = run(path, "apply")
    check("warm reboot is idempotent", vids(root) == [v + STEP for v in STOCK_VID], str(vids(root)))
    check("warm reboot re-arms the guard", mark(root) == "pending", mark(root))

    reset(root)  # the power cycle a hang ends in
    rc, out = run(path, "apply")
    check("a pending marker skips the offset", vids(root) == STOCK_VID, str(vids(root)))
    check("the skip is sticky", mark(root) == "failed", mark(root))
    check("the skip explains itself", "did not confirm" in out, out)
    rc, _ = run(path, "apply")
    check("failed stays skipped on the next boot", vids(root) == STOCK_VID, str(vids(root)))

    clear(root)
    rc, _ = run(path, "apply")
    check("clearing the marker re-applies", vids(root) == [v + STEP for v in STOCK_VID], str(vids(root)))

    # a corrupted baseline must not be mistaken for "firmware stock"
    clear(root)
    reset(root)
    with open(f"{root}/state/stock", "wb") as f:
        f.write(b"")
    rc, out = run(path, "apply")
    check("an unreadable baseline refuses", vids(root) == STOCK_VID and "unreadable" in out, out)

    # cores that disagree mean a half-applied write
    clear(root)
    reset(root)
    set_reg(root, 1, 2, (STOCK[2] & ~(0xFF << 9)) | (99 << 9))
    rc, out = run(path, "apply")
    check("disagreeing cores refuse", vids(root) == STOCK_VID and "disagree" in out, out)

    # a table that is neither stock nor shifted (a BIOS update)
    clear(root)
    reset(root)
    with open(f"{root}/state/stock", "wb") as f:
        import struct
        f.write(struct.pack("<7Q", *STOCK))
    set_vid(root, 3, 90)
    rc, out = run(path, "apply")
    check("an unknown live table refuses", "neither" in out, out)

    # the floor
    clear(root)
    reset(root)
    set_vid(root, 6, 125)
    rc, out = run(path, "apply")
    check("the 0.750 V floor refuses", "0.750" in out, out)
    check("a refusal writes nothing", vids(root)[6] == 125, str(vids(root)))

    rc, _ = run(path, "bogus")
    check("a bad verb exits non-zero", rc != 0)
finally:
    shutil.rmtree(root, ignore_errors=True)

print("\n%d failed: %s" % (len(fails), " ".join(fails)) if fails else "\nall guard checks passed")
sys.exit(1 if fails else 0)
