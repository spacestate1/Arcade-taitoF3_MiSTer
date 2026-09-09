#!/usr/bin/env python3
"""Reference for sim/spr_line_tb.cpp: the model's sprite framebuffer.

Stage (c) of the sprite engine -- the per-line builder -- draws the walked
list into a line buffer with zoom, flips, the pen mask and the priority
"later list entry wins" rule. The oracle is the model's own framebuffer
(SpriteEngine.fb) after get_sprite_info + draw_sprites on frame F-LAG's
sprite RAM (F3_LAG, 2 for Ray Force and 1 for the Bubble games), which is
what render_frame samples and what matched
MAME 15/15 through the mixer.

Emits, per screen line, the visible span (raster x 46..365 = 320 values) of
the framebuffer as decimal 16-bit sprite-colour values (0 = no sprite), plus
that line's 4-bit row-usage.

    sim/gen_spr_fb_ref.py [dump_dir] [frame] > sim/spr_fb_ref.txt
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import f3_render as R

d = sys.argv[1] if len(sys.argv) > 1 else "dump"
frame = int(sys.argv[2]) if len(sys.argv) > 2 else 1800
# Sprite lag is per game: 2 for Ray Force / Gunlock / EAR, 1 for the Bubble
# games. Keep this in step with the bench, which reads the same F3_LAG.
LAG = int(os.environ.get("F3_LAG", "2"))
src = frame - LAG
if not os.path.exists(os.path.join(d, "f3_%05d_spriteram.bin" % src)):
    sys.exit("need the frame-%d dump (sprite_lag %d)" % (LAG, LAG))

gfxs = R.load_gfx(d)
eng = R.SpriteEngine(gfxs["spr"])
dump = R.Dump(d, src)
eng.get_sprite_info(dump.spriteram)
eng.draw_sprites()

print("# frame %d src %d flip %d penmask %x" % (frame, src, int(eng.flipscreen), eng.pen_mask))
for sy in range(256):
    row = eng.fb[sy][R.VIS_X0:R.VIS_X0 + 320]
    used = int(eng.row_usage[sy]) & 0xF
    print("L %d %d %s" % (sy, used, " ".join(str(int(v)) for v in row)))
