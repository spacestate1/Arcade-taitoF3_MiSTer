#!/usr/bin/env python3
"""Capture one flip state: write the CFG, bounce cores so it is READ, grab shots.

    RF_HOST=MiSTer.lan .venv/bin/python rf_flip_ab.py <tag> <byte0> <byte2> [n]

The bounce matters: MiSTer only reads config/Rayforce.CFG when the core is
loaded fresh, so writing it and reloading the SAME core changes nothing --
load the menu first. Both states use Rotate: None (byte0 0x80) so the only
difference between the two captures is the 180 degrees.
"""
import sys, os, time
sys.path.insert(0, 'tools')
import rf_deploy as d

tag, b0, b2 = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
n = int(sys.argv[4]) if len(sys.argv) > 4 else 6
out = f"screenshots/{tag}"; os.makedirs(out, exist_ok=True)
R = "/media/fat/screenshots/rayforce"
MRA = "/media/fat/_Arcade/Ray Force.mra"

c = d.connect(); s = c.open_sftp()
path = "/media/fat/config/Rayforce.CFG"
try:    cur = bytearray(s.open(path, "rb").read())
except IOError: cur = bytearray(16)
if len(cur) < 16: cur = bytearray(cur) + bytearray(16 - len(cur))
cur[0], cur[1], cur[2] = b0, 0x00, b2
s.open(path, "wb").write(bytes(cur))
print(f"CFG = {b0:02x} 00 {b2:02x}   (Rotate:None, Flip Analog Out {'ON' if b2 & 0x20 else 'off'})")

d.run(c, 'echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd'); time.sleep(8)
d.run(c, f'echo "load_core {MRA}" > /dev/MiSTer_cmd'); time.sleep(34)
print("core reloaded")

d.run(c, f"mkdir -p {R}; rm -f {R}/*.png")
got = 0
for i in range(n):
    before = set(d.run(c, f"ls {R} 2>/dev/null").split())
    d.run(c, 'echo "screenshot" > /dev/MiSTer_cmd')
    new = set()
    for _ in range(8):
        time.sleep(0.7)
        new = set(d.run(c, f"ls {R} 2>/dev/null").split()) - before
        if new: break
    for f in sorted(new):
        if f.endswith(".png"):
            s.get(f"{R}/{f}", f"{out}/{f}"); d.run(c, f"rm -f '{R}/{f}'"); got += 1
    time.sleep(1.2)
s.close(); c.close()
print(f"{got} shots -> {out}")
