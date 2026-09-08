#!/usr/bin/env python3
"""The model's answer for the core's SPRPIX WR:RD self-test row.

The row is two 16-bit sums of the SAME quantity taken either side of the
DDR3 round trip the sprite pixels make on hardware:

    wr  the palette index of every sprite pixel the draw hands to the
        framebuffer writer (rf_spr_fb, tapped at lb_q)
    rd  the palette index of every sprite pixel the mixer reads back

Both are plain sums mod 2^16 over the whole sprite framebuffer, so they do
not depend on draw order -- which matters, because the RTL draws a line in
bucket order with overwrite while this model draws it in reverse list order
with write-if-empty. The finished buffers are identical; the write sequences
are not, so only an order-independent statistic can be compared.

This prints what BOTH halves must read for a given dumped frame:

    tools/f3_sprfold.py dump/dg972 972
    F3_EXTEND=0 F3_VIS=f3 tools/f3_sprfold.py dump/dg972 972

Reading the result:

    board wr != board rd            the DDR3 round trip corrupts the pixels
    board wr == rd, != this number  the sprite draw itself is wrong
    board wr == rd == this number   both are sound; the fault is downstream,
                                    in the mixer or the palette read

Comparing the board's two halves to EACH OTHER needs nothing from this
tool and works on a moving picture: the RTL delays the write side by a frame
so both halves describe the same drawn frame. This number is only needed for
the second question -- whether the (agreeing) halves are RIGHT -- and that
does need a matched frame: align a board screenshot to a MAME frame first,
the same way the Darius Gaiden comparison was, then dump that frame and run
this on it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import f3_gfx
import f3_render as R


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    d, frame = sys.argv[1], int(sys.argv[2])

    gfxs = {"spr": f3_gfx.load_sprite_gfx(os.path.join(d, "rgn_sprites.bin"),
                                          os.path.join(d, "rgn_sprites_hi.bin"))}
    eng = R.SpriteEngine(gfxs["spr"])

    # Same priming as f3_render's --seq: sprite_lag 2, so the buffer shown on
    # `frame` was drawn from the sprite RAM of frame-2. Walk the same order
    # (draw, then read the next frame's list) and stop with the engine
    # holding exactly the buffer that frame displays.
    frames = []
    for back in (2, 1):
        f = frame - back
        if os.path.exists(os.path.join(d, "f3_%05d_spriteram.bin" % f)):
            frames.append(f)
    frames.append(frame)
    if len(frames) < 3:
        print("note: dumps for frame-1/frame-2 are missing; the fold will be "
              "up to two frames ahead of MAME", file=sys.stderr)

    for i, f in enumerate(frames):
        dump = R.Dump(d, f)
        if i == len(frames) - 1:
            break                    # eng.fb is now the buffer THIS frame shows
        eng.draw_sprites()
        eng.get_sprite_info(dump.spriteram)

    fb = eng.fb
    total = int(fb.astype("int64").sum()) & 0xFFFF
    nz = int((fb != 0).sum())
    print("frame %d   sprite pixels %d   fold 0x%04X" % (frame, nz, total))
    print("  self-test row should read   SPRPIX WR:RD   %04X%04X" % (total, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
