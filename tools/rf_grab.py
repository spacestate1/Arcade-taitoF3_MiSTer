#!/usr/bin/env python3
"""Grab N screenshots plus the self-test page from the board, right now.

Written for the boss A/B: when the player says "I'm there", one command has
to take everything before the moment passes. Screenshots first (they are what
the comparison needs), page second.

    RF_HOST=MiSTer.lan .venv/bin/python tools/rf_grab.py <tag> [n]
"""
import sys, os, time
sys.path.insert(0, 'tools')
import rf_deploy as d

tag = sys.argv[1] if len(sys.argv) > 1 else "grab"
n   = int(sys.argv[2]) if len(sys.argv) > 2 else 6
out = f"screenshots/{tag}"
os.makedirs(out, exist_ok=True)
R = "/media/fat/screenshots/rayforce"

c = d.connect(); s = c.open_sftp()
d.run(c, f"mkdir -p {R}")
got = 0
for i in range(n):
    before = set(d.run(c, f"ls {R} 2>/dev/null").split())
    d.run(c, 'echo "screenshot" > /dev/MiSTer_cmd')
    new = set()
    for _ in range(8):
        time.sleep(0.6)
        new = set(d.run(c, f"ls {R} 2>/dev/null").split()) - before
        if new: break
    for f in sorted(new):
        if f.endswith(".png"):
            s.get(f"{R}/{f}", f"{out}/{f}"); d.run(c, f"rm -f '{R}/{f}'")
            got += 1; print("captured", f, flush=True)
s.close(); c.close()
print(f"{got} shots -> {out}")
