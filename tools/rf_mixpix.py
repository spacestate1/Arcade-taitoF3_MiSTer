#!/usr/bin/env python3
"""Decode the MIX S:D:BLEND self-test row (coordinate packing).

The row latches the mixer's inputs for the last SPRITE-sourced pixel of a
frame:

    {x[8:0], y[7:0], src_pal[12:0], src_blend==8, dst_blend==0}

With a matched MAME dump it renders the verdict itself: give it the dump
directory and frame and it compares the board's index against the model's
framebuffer at the same pixel.

    tools/rf_mixpix.py <hex8>
    tools/rf_mixpix.py <hex8> dump/dg864 864

The two flag bits compress the blend weights to the only question that
matters: MAME renders these scenes 100 % opaque, so anything but 1,1 means
the mixer is blending where it must not.
"""
import os
import struct
import sys


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    v = int(sys.argv[1], 16)
    x = (v >> 23) & 0x1FF
    y = (v >> 15) & 0xFF
    src = (v >> 2) & 0x1FFF
    sb8 = (v >> 1) & 1
    db0 = v & 1
    print("raw %08X" % v)
    print("  pixel      x=%d y=%d" % (x, y))
    print("  src_pal    0x%04X  (%s)" % (src, "sprite" if src >= 0x1000 else "NOT a sprite bank"))
    print("  src_blend==8: %d   dst_blend==0: %d   -> %s" % (sb8, db0,
          "opaque, out = palette[src_pal]" if (sb8 and db0) else "BLENDED -- must not happen in this scene"))

    if len(sys.argv) > 3:
        d, frame = sys.argv[2], int(sys.argv[3])
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        os.environ.setdefault("F3_EXTEND", "0")
        os.environ.setdefault("F3_VIS", "f3")
        import f3_gfx
        import f3_render as R
        spr = f3_gfx.load_sprite_gfx(os.path.join(d, "rgn_sprites.bin"),
                                     os.path.join(d, "rgn_sprites_hi.bin"))
        eng = R.SpriteEngine(spr)
        frames = [f for f in (frame - 2, frame - 1) if
                  os.path.exists(os.path.join(d, "f3_%05d_spriteram.bin" % f))] + [frame]
        for i, f in enumerate(frames):
            dump = R.Dump(d, f)
            if i == len(frames) - 1:
                break
            eng.draw_sprites()
            eng.get_sprite_info(dump.spriteram)
        # the sprite framebuffer holds the palette index per pixel, indexed by
        # raster x (screen x + H_START = 46)
        model_idx = int(eng.fb[y, x + 46]) if x + 46 < eng.fb.shape[1] else 0
        pal = open(os.path.join(d, "f3_%05d_paletteram.bin" % frame), "rb").read()
        def rgb(i):
            e = struct.unpack_from(">I", pal, i * 4)[0]
            return (e >> 16) & 0xFF, (e >> 8) & 0xFF, e & 0xFF
        print()
        print("  model at (x=%d, y=%d): sprite fb index 0x%04X  colour #%02X%02X%02X"
              % (x, y, model_idx, *rgb(model_idx)))
        print("  board palette[src_pal 0x%04X]          colour #%02X%02X%02X"
              % (src, *rgb(src)))
        if model_idx == src:
            print("  VERDICT: the index MATCHES the model -- everything upstream of")
            print("           the palette lookup is right at this pixel; compare the")
            print("           screenshot colour there against palette[src_pal]")
        else:
            print("  VERDICT: the index DIFFERS from the model -- the wrong pen or")
            print("           record reached the mixer; the fault is upstream")
    return 0


if __name__ == "__main__":
    sys.exit(main())
