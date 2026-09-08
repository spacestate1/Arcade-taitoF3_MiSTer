#!/usr/bin/env python3
"""Isolate rendering glitches by diffing the board against ITSELF on a paused screen.

The idea, and why it works so well: on a paused or otherwise static screen the
game is not drawing anything new, so every frame the core emits MUST be
identical. Grab a burst of screenshots and group them by exact byte equality --
if more than one group comes back, the core is rendering the same scene two
different ways, and the pixels that differ between the groups are the defect
with all of the artwork subtracted out. No reference frame, no model, no RTL
instrument required.

This found the Ray Force sprite corruption on 2026-09-07 after seven RTL
instruments had all read clean: 8 shots, exactly 2 states, 9,059 pixels
differing, in two horizontal bands. See SPRITE-CORRUPTION.md.

    RF_HOST=MiSTer.lan .venv/bin/python tools/rf_flicker.py <tag> [n]

Writes to screenshots/<tag>/:
    NN_state<X>.png    one representative raw frame per distinct state
    diffmask.png       white = differs between the two most common states
    state<X>_3x.png    3x nearest-neighbour blowups, easier to eyeball
and prints the band structure, so a run of differing scanlines is obvious.

Caveat worth keeping in mind: this can only see corruption that CHANGES frame
to frame. Corruption that is stable across frames is invisible to it by
construction -- for that you need MAME as a reference (tools/f3_render.py).
"""
import os
import sys
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from PIL import Image


def group_states(paths):
    """Group frames by exact equality. Returns [(indices, array), ...] biggest first."""
    ims = [np.array(Image.open(p).convert("RGB")).astype(int) for p in paths]
    groups = []
    for i, im in enumerate(ims):
        for g in groups:
            if (im == ims[g[0]]).all():
                g.append(i)
                break
        else:
            groups.append([i])
    groups.sort(key=len, reverse=True)
    return [(g, ims[g[0]]) for g in groups], ims


def bands(mask):
    """Contiguous runs of rows that contain any difference."""
    rows = mask.sum(axis=1)
    out, start = [], None
    for y in range(mask.shape[0]):
        if rows[y] > 0 and start is None:
            start = y
        elif rows[y] == 0 and start is not None:
            out.append((start, y - 1))
            start = None
    if start is not None:
        out.append((start, mask.shape[0] - 1))
    return out


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else "flicker"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    out = os.path.join("screenshots", tag)

    if not glob.glob(os.path.join(out, "*.png")):
        import rf_grab  # noqa: F401  -- grabbing is its whole job
        print("no frames yet; run tools/rf_grab.py %s %d first" % (tag, n))
        return 1

    paths = sorted(p for p in glob.glob(os.path.join(out, "*.png"))
                   if os.path.basename(p)[0].isdigit())
    groups, _ = group_states(paths)

    print("%d frames -> %d distinct state(s)" % (len(paths), len(groups)))
    for i, (idx, im) in enumerate(groups):
        name = chr(ord("A") + i)
        print("   state %s: %2d frame(s)   e.g. %s"
              % (name, len(idx), os.path.basename(paths[idx[0]])))
        Image.fromarray(im.astype("uint8")).save(
            os.path.join(out, "%02d_state%s.png" % (i, name)))
        h, w = im.shape[:2]
        Image.fromarray(im.astype("uint8")).resize(
            (w * 3, h * 3), Image.NEAREST).save(
            os.path.join(out, "state%s_3x.png" % name))

    if len(groups) < 2:
        print("\nONE state only: the core is rendering this scene consistently.")
        print("That does not mean it is CORRECT -- stable corruption is invisible")
        print("to this method. Use MAME as a reference instead.")
        return 0

    A, B = groups[0][1], groups[1][1]
    d = (A != B).any(axis=2)
    total = int(d.sum())
    print("\nstate A vs state B: %d pixels differ (%.2f %% of the frame)"
          % (total, 100.0 * total / (d.shape[0] * d.shape[1])))

    print("bands of affected scanlines:")
    for a, b in bands(d):
        print("   y %3d-%3d  (%3d rows, %5d px)" % (a, b, b - a + 1, int(d[a:b + 1].sum())))

    # Is it geometry or colour? The distinction decides where to look next: a
    # sprite in the wrong PLACE and a sprite in the wrong COLOUR are different
    # bugs, and on 2026-09-07 this line is what showed it was colour.
    nzA = A.sum(axis=2) > 60
    nzB = B.sum(axis=2) > 60
    only_a = int((d & nzA & ~nzB).sum())
    only_b = int((d & nzB & ~nzA).sum())
    both = int((d & nzA & nzB).sum())
    print("\nnature of the difference:")
    print("   content in A, dark in B : %6d" % only_a)
    print("   content in B, dark in A : %6d" % only_b)
    print("   content in BOTH, wrong colour: %6d   <- %.0f %%"
          % (both, 100.0 * both / max(total, 1)))
    if both > (only_a + only_b) * 3:
        print("   => mostly a COLOUR fault: same pixels, different values.")
        print("      Look at palette index composition, the pen mask, or the")
        print("      graphics fetch -- not at position, zoom or the list walk.")
    elif (only_a + only_b) > both * 3:
        print("   => mostly a GEOMETRY fault: pixels appearing or vanishing.")
        print("      Look at position, zoom, the record list or the line buffer.")

    h, w = d.shape
    Image.fromarray((d * 255).astype("uint8")).resize(
        (w * 3, h * 3), Image.NEAREST).save(os.path.join(out, "diffmask.png"))
    print("\nwrote %s/diffmask.png (white = differs), state pngs alongside" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
