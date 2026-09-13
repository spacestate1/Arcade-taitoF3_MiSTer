#!/usr/bin/env python3
"""Decide whether Flip Analog Out actually flipped the raster, without eyes.

    python3 rf_flip_check.py screenshots/flip_off screenshots/flip_on

Both sets must be captured with Rotate: None, so the ONLY difference between
them is the 180 degrees -- otherwise the rotation change swamps the test.

Attract mode animates, so two captures are never the same instant. Two
independent scores, and they have to agree:

  1. row profile   mean luminance per scanline. A 180 degree flip reverses
                   that profile, so corr(on, reversed(off)) must beat
                   corr(on, off) decisively. Survives frame-to-frame motion.
  2. exact pixels  best pairwise fraction of identical pixels, on[::-1,::-1]
                   against off. Near 1.0 only if two captures caught the same
                   attract moment -- strong when it fires, absent otherwise.
"""
import sys, os, itertools
import numpy as np
from PIL import Image

def load(d):
    out = []
    for f in sorted(os.listdir(d)):
        if f.lower().endswith(".png"):
            a = np.asarray(Image.open(os.path.join(d, f)).convert("RGB"), dtype=np.int16)
            out.append((f, a))
    return out

def prof(a):
    p = a.mean(axis=(1, 2))
    return (p - p.mean()) / (p.std() + 1e-9)

def corr(x, y):
    n = min(len(x), len(y))
    return float((x[:n] * y[:n]).mean())

off, on = load(sys.argv[1]), load(sys.argv[2])
if not off or not on:
    sys.exit(f"need PNGs in both dirs (off={len(off)}, on={len(on)})")
shapes = {a.shape for _, a in off} | {a.shape for _, a in on}
print(f"{len(off)} off, {len(on)} on; shapes {shapes}")
if len(shapes) > 1:
    print("WARNING: shapes differ -- were both sets captured with Rotate: None?")

same = flipped = -2.0
px_same = px_flip = 0.0
for (fn, a), (gn, b) in itertools.product(off, on):
    if a.shape != b.shape:
        continue
    same    = max(same,    corr(prof(a), prof(b)))
    flipped = max(flipped, corr(prof(a), prof(b[::-1])))
    px_same = max(px_same, float((a == b).all(axis=2).mean()))
    px_flip = max(px_flip, float((a == b[::-1, ::-1]).all(axis=2).mean()))

print(f"row profile  upright {same:+.3f}   flipped {flipped:+.3f}")
print(f"exact pixels upright {px_same:.1%}   flipped {px_flip:.1%}")

verdict = "FLIP IS WORKING" if (flipped > same + 0.25 or px_flip > 0.90) else \
          "NO FLIP DETECTED" if (same > flipped + 0.25 or px_same > 0.90) else \
          "INCONCLUSIVE -- capture a less busy scene, or more frames"
print("VERDICT:", verdict)
sys.exit(0 if verdict.startswith("FLIP IS") else 1)
