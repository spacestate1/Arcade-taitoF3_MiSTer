#!/usr/bin/env python3
"""Find which MAME frame a board screenshot is showing.

The board cannot be told what frame it is on, and a self-test row that
reports a per-frame quantity is only comparable against the model if you know
WHICH frame. This aligns the two by brute force: score the screenshot against
every frame of a dense capture and take the peak.

    tools/rf_match_frame.py <shot.png> <dense_dir> [--top N]

`dense_dir` holds `*_frame.argb` files written by a recon/oracle run (any
step; step 1 or 2 gives the sharpest peak). Scoring is the fraction of
EXACTLY equal pixels, not a mean difference: the parts of the picture the
core gets right are bit-exact against MAME, so the true frame stands out as
a sharp peak while a mean-difference score is dominated by whatever is wrong.

A peak that is not clearly above its neighbours means the scene is not
aligned -- act on that rather than on the number it prints.
"""
import os
import sys

import numpy as np
from PIL import Image


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    shot, dense = sys.argv[1], sys.argv[2]
    top = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 5

    a = np.array(Image.open(shot).convert("RGB"), dtype=np.uint8)
    h, w, _ = a.shape

    scores = []
    for f in sorted(os.listdir(dense)):
        if not f.endswith("_frame.argb"):
            continue
        raw = np.frombuffer(open(os.path.join(dense, f), "rb").read(), dtype=np.uint8)
        if raw.size != h * w * 4:
            continue
        b = raw.reshape(h, w, 4)[:, :, [2, 1, 0]]
        scores.append(((b == a).all(axis=2).mean(), f.split("_")[1]))

    if not scores:
        print("no frames of %dx%d in %s" % (w, h, dense))
        return 1
    scores.sort(reverse=True)
    print("%-8s %s" % ("frame", "exact-match"))
    for s, n in scores[:top]:
        print("  %-6s %5.1f%%" % (n, 100 * s))
    best, peak = scores[0][1], scores[0][0]
    second = scores[1][0] if len(scores) > 1 else 0.0
    print()
    print("best frame %s at %.1f%%" % (best, 100 * peak))
    if peak < 0.30:
        print("  WEAK: nothing in the capture is close. Widen or densify it "
              "before trusting this.")
    elif peak - second < 0.02:
        print("  FLAT: neighbouring frames score the same, so the alignment is "
              "ambiguous to within a frame or two.")
    else:
        print("  sharp peak -- alignment is trustworthy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
