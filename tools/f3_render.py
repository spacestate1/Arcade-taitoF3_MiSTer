#!/usr/bin/env python3
"""Software model of the Taito F3 video chipset (TC0630FDP/TC0650FDA/TC0660FCM).

A line-by-line port of MAME 0.288 taito_f3_v.cpp: read_line_ram, get_pf_scroll,
calc_clip, mix_line, render_line, get_sprite_info, f3_drawgfx. It takes a VRAM
dump from tools/oracle_f3dump.lua and produces the frame those bytes describe.

Why this exists before any renderer RTL: the F3's line RAM makes every one of
256 scanlines independently configurable for scroll, zoom, priority, clipping,
blending and palette offset. That is far too much state to get right by writing
Verilog and looking at a TV. The model is checked against MAME's own frame
pixel-for-pixel first, so when the RTL disagrees with the model there is a
known-correct intermediate to bisect against instead of one 51 KB C++ file.

Usage:
    tools/f3_render.py dump 1800            # render, write dump/f3_01800_model.png
    tools/f3_render.py dump 1800 --compare  # and diff against MAME's frame
    tools/f3_render.py dump/bmem 4200 --compare --lag 1   # Bubble games are lag 1

Sprite timing: what is on screen came from sprite RAM N frames earlier, where
N is MAME's f3_config_table sprite_lag FOR THAT GAME -- 2 for Ray Force /
Gunlock, but 1 for Bubble Bobble II and Bubble Memories. Set it with --lag N
or F3_LAG=N; the default is 2.

    GETTING THIS WRONG LOOKS LIKE A RENDERING BUG, NOT A TIMING ONE. At lag 2
    the Bubble games differ from MAME on 7 of 10 frames (bmem 4200 by 14.7%),
    and the error is confined to sprite pixels -- which reads as a fault in
    the sprite block/multi path, because those games set block control on 97%
    of their sprites where Ray Force sets it on 2%. It is not. At lag 1 both
    games are 0/71680 on all ten frames. Measured 2026-09-09.

    The earlier --depth flag could not express this: it only chose how many
    warm-up frames to walk, while the render always used the list from
    frame-2, so "--depth 1" drew NO sprites at all rather than lag-1 sprites.
    That is what made lag 1 look decisively worse and produced the wrong
    conclusion recorded in PREP-BUBBLE.md.
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import f3_gfx

# ---- geometry, from taito_f3.h ------------------------------------------
H_TOTAL, H_VIS, H_START = 432, 320, 46
V_VIS, V_START = 232, 24
NUM_PF, NUM_SP, NUM_CLIP = 4, 4, 4

import os as _os

# gunlock: f3_config_table extend = 1, sprite_lag = 2, and f3_224a crops to
# set_visarea(46, 365, 31, 254).
# The playfield "extend" bit (f3_config_table). It is NOT cosmetic: it
# changes the tilemap geometry, the playfield RAM stride and how many
# tilemaps exist, so a game run with the wrong one renders a truncated or
# aliased playfield rather than a subtly wrong one.
#
#   extend=1  four  64x32 tilemaps (1024x512), pf stride 0x2000 bytes,
#             10-bit x wrap. Ray Force, Elevator Action Returns, both
#             Bubble Bobble games.
#   extend=0  eight 32x32 tilemaps (512x512),  pf stride 0x1000 bytes,
#             9-bit x wrap, and playfield N may draw from tilemap N+2
#             when line RAM's colscroll bit 0x200 is set (alt_tilemap).
#             Puzzle Bobble 2/3/4, Darius Gaiden, Cleopatra Fortune,
#             Grid Seeker, Space Invaders '95, Gekirindan.
#
#   F3_EXTEND=0 python3 ...
EXTEND = _os.environ.get("F3_EXTEND", "1") != "0"
WIDTH_MASK = 0x3FF if EXTEND else 0x1FF
# tilemaps that exist, and the playfield RAM stride in 16-bit words
NUM_TMAP = 4 if EXTEND else 8
PF_STRIDE = 0x1000 if EXTEND else 0x800
TMAP_COLS = 64 if EXTEND else 32
VIS_X0, VIS_X1 = 46, 365

# The vertical crop is the ONE thing that differs between the four Taito F3
# machine configurations, and the model has to follow the game being dumped
# or every comparison is off by a few lines and reads as a total mismatch:
#
#   f3_224a  31..254  224 lines   Ray Force / Gunlock   (the default)
#   f3_224b  32..255  224 lines
#   f3_224c  24..247  224 lines
#   f3       24..255  232 lines   Elevator Action Returns
#
#   F3_VIS=f3 python3 ... , or F3_VIS=24,255
import os as _os
_VIS = {"f3_224a": (31, 254), "f3_224b": (32, 255),
        "f3_224c": (24, 247), "f3": (24, 255)}
_v = _os.environ.get("F3_VIS", "f3_224a")
if _v in _VIS:
    VIS_Y0, VIS_Y1 = _VIS[_v]
else:
    VIS_Y0, VIS_Y1 = (int(x) for x in _v.split(","))

SPR_COLORBASE = 0x1000


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def sext(v, bits):
    m = 1 << (bits - 1)
    return (v & (m - 1)) - (v & m)


# =========================================================================
#  Dump loading
# =========================================================================

class Dump:
    def __init__(self, d, frame):
        p = os.path.join(d, "f3_%05d_" % frame)
        self.frame = frame

        def w(name):
            return np.frombuffer(open(p + name + ".bin", "rb").read(), ">u2")

        self.spriteram = w("spriteram")
        self.pf_ram = w("pf_ram")
        self.textram = w("textram")
        self.charram_raw = open(p + "charram.bin", "rb").read()
        self.line_ram = w("line_ram")
        self.pivot_raw = open(p + "pivot_ram.bin", "rb").read()

        pal = np.frombuffer(open(p + "paletteram.bin", "rb").read(),
                            np.uint8).reshape(-1, 4)
        # 0x00RRGGBB for almost every set. Four games (Space Invaders DX,
        # Riding Fight, Arabian Magic, Ring Rage) instead pack the colour into
        # the LOW 16 bits as RRRRGGGGBBBB0000 and MAME scales each nibble by
        # 16 (taito_f3_v.cpp palette_24bit_w). Bits 15:8 of the entry are
        # byte 2 and bits 7:0 are byte 3, so R and G come out of byte 2 and B
        # out of byte 3. F3_PAL12=1 selects it, matching the RTL's pal12.
        if os.environ.get("F3_PAL12") == "1":
            b2 = pal[:, 2].astype(np.int32)
            b3 = pal[:, 3].astype(np.int32)
            self.clut = np.stack([(b2 >> 4) * 16, (b2 & 0xF) * 16,
                                  (b3 >> 4) * 16], axis=1)
        else:
            self.clut = pal[:, 1:4].astype(np.int32)      # (8192, 3) as R,G,B

        ctrl = [0] * 16
        for ln in open(p + "ctrl.txt"):
            i, v = ln.split()
            ctrl[int(i)] = int(v, 16)
        self.control_0 = ctrl[0:8]
        self.control_1 = ctrl[8:16]

        self.frame_ref = None
        fp = p + "frame.argb"
        if os.path.exists(fp):
            fw, fh = (int(x) for x in open(p + "frame.txt").read().split())
            raw = np.frombuffer(open(fp, "rb").read(), np.uint8).reshape(fh, fw, 4)
            self.frame_ref = raw[:, :, [2, 1, 0]].astype(np.int32)   # B,G,R,A -> R,G,B


# =========================================================================
#  Tilemaps
# =========================================================================

def _flip(a, flip):
    """Global tilemap flip.

    MAME does set_flip_all(FLIPX|FLIPY), which places every tile at the
    mirrored position AND xors its own flip bits -- the net effect on the
    finished pixmap is a plain mirror in both axes. Ray Force needs this: its
    graphics are stored flipped in ROM and the program sets the flipscreen bit
    to display them the right way up (see the note at the top of
    taito_f3_v.cpp about "strange use of flipscreen").
    """
    return a[::-1, ::-1] if flip else a


def build_playfields(dump, pf_gfx, flip=False):
    """Four 1024x512 pixmaps + flagsmaps, MAME tilemap semantics.

    tilemap.cpp combines the palette code and the pen with '+', not '|', and
    the F3 tile attribute puts the 6bpp extra planes in bits that overlap the
    palette code -- hence pen_mask, straight out of get_tile_info().
    """
    nelem = len(pf_gfx)
    pix, flg = [], []
    # extend=0 has EIGHT tilemaps, not four: playfield N can draw from map
    # N+2 (alt_tilemap), so all eight have to be built even though only four
    # playfields exist.
    for i in range(NUM_TMAP):
        base = PF_STRIDE * i                    # word offset of tilemap i
        blk = dump.pf_ram[base:base + PF_STRIDE]
        attr = blk[0::2].reshape(32, TMAP_COLS).astype(np.int32)
        code = blk[1::2].reshape(32, TMAP_COLS).astype(np.int32)

        pal_code = attr & 0x1FF
        blend_sel = (attr >> 9) & 1
        extra = (attr >> 10) & 3
        flipx = ((attr >> 14) & 1).astype(bool)
        flipy = ((attr >> 15) & 1).astype(bool)

        t = pf_gfx[code % nelem]                                  # (32,64,16,16)
        t = np.where(flipx[..., None, None], t[:, :, :, ::-1], t)
        t = np.where(flipy[..., None, None], t[:, :, ::-1, :], t)

        pen_mask = (((extra & ~pal_code) << 4) | 0x0F).astype(np.int32)
        pen = t.astype(np.int32) & pen_mask[..., None, None]

        pm = (pal_code[..., None, None] * 16 + pen).astype(np.uint16)
        fm = np.where(pen != 0, (0x10 | blend_sel[..., None, None]), 0).astype(np.uint8)

        pix.append(_flip(pm.transpose(0, 2, 1, 3).reshape(32 * 16, TMAP_COLS * 16), flip))
        flg.append(_flip(fm.transpose(0, 2, 1, 3).reshape(32 * 16, TMAP_COLS * 16), flip))
    return pix, flg


def build_vram_layer(dump, char_gfx, flip=False):
    """64x64 8x8 tiles from text RAM + char RAM -> 512x512."""
    tx = dump.textram.reshape(64, 64).astype(np.int32)
    code = tx & 0xFF
    pal = (tx >> 9) & 0x3F
    flipx = ((tx >> 8) & 1).astype(bool)
    flipy = ((tx >> 15) & 1).astype(bool)

    t = char_gfx[code].astype(np.int32)
    t = np.where(flipx[..., None, None], t[:, :, :, ::-1], t)
    t = np.where(flipy[..., None, None], t[:, :, ::-1, :], t)

    pm = (pal[..., None, None] * 16 + t).astype(np.uint16)
    fm = np.where(t != 0, 0x10, 0).astype(np.uint8)
    return (_flip(pm.transpose(0, 2, 1, 3).reshape(512, 512), flip),
            _flip(fm.transpose(0, 2, 1, 3).reshape(512, 512), flip))


def build_pixel_layer(dump, pivot_gfx, flipscreen=False):
    """64x32 8x8 tiles scanned in COLUMNS -> 512x256.

    The pixel layer is a bitmap in pivot RAM but borrows its palette from the
    text layer, which is twice as tall. MAME reproduces the hardware's
    behaviour with a scroll-offset check (get_tile_info_pixel); the same hack
    is kept here so the model and MAME agree, including where both are wrong.
    """
    idx = np.arange(2048).reshape(64, 32).T                # [row, col] = col*32+row
    rows = np.arange(32)[:, None] * np.ones((1, 64), np.int32)
    cols = np.ones((32, 1), np.int32) * np.arange(64)[None, :]

    y_off = rows * 8 + dump.control_1[5]
    if flipscreen:
        y_off += 0x100
    yy = rows + np.where((y_off & 0x1FF) >= 256, 32, 0)

    tx = dump.textram.reshape(64, 64).astype(np.int32)
    vram_tile = tx[yy, cols]
    pal = (vram_tile >> 9) & 0x3F
    flipx = ((vram_tile >> 8) & 1).astype(bool)
    flipy = ((vram_tile >> 15) & 1).astype(bool)

    t = pivot_gfx[idx].astype(np.int32)
    t = np.where(flipx[..., None, None], t[:, :, :, ::-1], t)
    t = np.where(flipy[..., None, None], t[:, :, ::-1, :], t)

    pm = (pal[..., None, None] * 16 + t).astype(np.uint16)
    fm = np.where(t != 0, 0x10, 0).astype(np.uint8)
    return (_flip(pm.transpose(0, 2, 1, 3).reshape(256, 512), flipscreen),
            _flip(fm.transpose(0, 2, 1, 3).reshape(256, 512), flipscreen))


# =========================================================================
#  Layer descriptors -- mixable / sprite_inf / pivot_inf / playfield_inf
# =========================================================================

class Mixable:
    kind = "MX"

    def __init__(self, index=0):
        self.pix = None
        self.flg = None
        self.index = index
        self.x_sample_enable = False
        self.mix_value = 0
        self.prio = 0
        self.blend_mode = 0

    def set_mix(self, v):
        self.mix_value = v
        self.prio = v & 0xF
        self.blend_mode = (v >> 14) & 3

    def set_prio(self, p):
        self.mix_value = (self.mix_value & 0xFFF0) | p
        self.prio = p

    def set_blend(self, b):
        self.mix_value = (self.mix_value & 0x3FFF) | (b << 14)
        self.blend_mode = b

    def clip_inv(self):      return (self.mix_value >> 4) & 0xF
    def clip_enable(self):   return (self.mix_value >> 8) & 0xF
    def clip_inv_mode(self): return bool(self.mix_value & 0x1000)
    def layer_enable(self):  return bool(self.mix_value & 0x2000) and self.blend_mode != 3

    def palette_adjust(self, pal): return pal
    def y_index(self, y):  return y
    def x_index(self, xs): return xs
    def blend_select(self, flags_row, gx): return np.zeros(gx.shape, np.int32)
    def inactive_group(self, color):       return np.zeros(color.shape, bool)


class SpriteInf(Mixable):
    kind = "SP"

    def __init__(self, index):
        super().__init__(index)
        self.blend_select_v = False

    def layer_enable(self):
        return bool(self.mix_value & 0x2000) and self.blend_mode != 0

    def blend_select(self, flags_row, gx):
        return np.full(gx.shape, int(self.blend_select_v), np.int32)

    def inactive_group(self, color):
        return ((color >> 10) & 3) != self.index


class PivotInf(Mixable):
    kind = "PV"

    def __init__(self):
        super().__init__(0)
        self.pivot_control = 0
        self.blend_select_v = False
        self.pivot_enable = 0
        self.reg_sx = 0
        self.reg_sy = 0

    def use_pix(self): return bool(self.pivot_control & 0xA0)

    def blend_select(self, flags_row, gx):
        return np.full(gx.shape, int(self.blend_select_v), np.int32)

    def x_index(self, xs): return (xs + self.reg_sx) & 0x1FF
    def y_index(self, y):  return (self.reg_sy + y) & (0xFF if self.use_pix() else 0x1FF)


class PlayfieldInf(Mixable):
    kind = "PF"

    def __init__(self, index):
        super().__init__(index)
        self.colscroll = 0
        self.alt_tilemap = False
        self.x_scale = 0x80
        self.y_scale = 0
        self.pal_add = 0
        self.rowscroll = 0
        self.reg_sx = 0
        self.reg_sy = 0
        self.reg_fx_y = 0
        self.reg_fx_x = 0
        self.width_mask = WIDTH_MASK

    def palette_adjust(self, pal): return pal + self.pal_add
    def x_index(self, xs):
        return ((((self.reg_fx_x + (xs - H_START) * self.x_scale) >> 8)
                 + H_START) & self.width_mask)
    def y_index(self, y):
        return ((self.reg_fx_y >> 8) + self.colscroll) & 0x1FF

    def blend_select(self, flags_row, gx):
        return (flags_row[gx] & 1).astype(np.int32)


class LineInf:
    def __init__(self):
        self.y = 0
        self.clip = [[0, 0] for _ in range(NUM_CLIP)]
        self.blend = np.zeros(4, np.int32)
        self.x_sample = 16
        self.fx_6400 = 0
        self.bg_palette = 0
        self.pivot = PivotInf()
        self.sp = [SpriteInf(i) for i in range(NUM_SP)]
        self.pf = [PlayfieldInf(i) for i in range(NUM_PF)]


# =========================================================================
#  Line RAM
# =========================================================================

def read_line_ram(lr, line, y, control_1):
    def latched(section, subsection):
        latches = int(lr[section * 0x100 + y])
        base = 0x4000 + 0x1000 * section + 0x200 * subsection
        if latches & (1 << (subsection + 4)):
            return (base + 0x800) // 2 + y
        if latches & (1 << subsection):
            return base // 2 + y
        return 0

    # 4000: column scroll (pf 3/4) and the high bits of the clip planes
    for i in (2, 3):
        w = latched(0, i)
        if w:
            cs = int(lr[w])
            line.pf[i].colscroll = cs & 0x1FF
            line.pf[i].alt_tilemap = (not EXTEND) and bool(cs & 0x200)
            set_upper(line.clip[2 * (i - 2) + 0], (cs >> 12) & 1, (cs >> 13) & 1)
            set_upper(line.clip[2 * (i - 2) + 1], (cs >> 14) & 1, (cs >> 15) & 1)

    # 5000: clip plane low bits
    for i in range(4):
        w = latched(1, i)
        if w:
            v = int(lr[w])
            set_lower(line.clip[i], v & 0xFF, (v >> 8) & 0xFF)

    # 6000: sprite blend modes, pivot control
    w = latched(2, 0)
    if w:
        v = int(lr[w])
        line.pivot.blend_select_v = bool((v >> 9) & 1)
        line.pivot.pivot_control = (v >> 8) & 0xFF
        for g in range(NUM_SP):
            line.sp[g].set_blend((v >> (g * 2)) & 3)
    # 6200: blend contribution values
    w = latched(2, 1)
    if w:
        v = int(lr[w])
        for idx in range(4):
            line.blend[idx] = min(8, 0xF - ((v >> (4 * idx)) & 0xF))
    # 6400: mosaic / palette interpretation
    w = latched(2, 2)
    if w:
        v = int(lr[w])
        line.x_sample = 16 - ((v >> 4) & 0xF)
        for n in range(NUM_PF):
            line.pf[n].x_sample_enable = bool((v >> n) & 1)
        for sp in line.sp:
            sp.x_sample_enable = bool((v >> 8) & 1)
        line.pivot.x_sample_enable = bool((v >> 9) & 1)
        line.fx_6400 = (v & 0xFC00) >> 8
    # 6600: background palette
    w = latched(2, 3)
    if w:
        line.bg_palette = int(lr[w])

    # 7000: unknown pivot enable
    w = latched(3, 0)
    if w:
        line.pivot.pivot_enable = int(lr[w])
    # 7200: pivot mix
    w = latched(3, 1)
    if w:
        line.pivot.set_mix(int(lr[w]))
    # 7400: sprite clip info and blend select
    w = latched(3, 2)
    if w:
        v = int(lr[w])
        for g in range(NUM_SP):
            line.sp[g].set_mix((line.sp[g].mix_value & 0xC00F) | ((v & 0x3FF) << 4))
            line.sp[g].blend_select_v = bool((v >> (12 + g)) & 1)
    # 7600: sprite priority
    w = latched(3, 3)
    if w:
        v = int(lr[w])
        for g in range(NUM_SP):
            line.sp[g].set_prio((v >> (g * 4)) & 0xF)

    # 8000: playfield zoom -- the Y zooms are interleaved between pf 2 and 4
    FIX_Y = (0, 3, 2, 1)
    for i in range(4):
        w = latched(4, i)
        if w:
            v = int(lr[w])
            line.pf[i].x_scale = 256 - ((v >> 8) & 0xFF)
            line.pf[FIX_Y[i]].y_scale = (v & 0xFF) << 1

    # 9000: playfield palette addition
    for i in range(4):
        w = latched(5, i)
        if w:
            line.pf[i].pal_add = int(lr[w]) * 16

    # A000: rowscroll, 10.6 fixed point with a negative fractional part
    for i in range(4):
        w = latched(6, i)
        if w:
            rs = int(lr[w]) << 2
            line.pf[i].rowscroll = (rs & ~0xFF) - (rs & 0xFF)

    # B000: playfield mixing info
    for i in range(4):
        w = latched(7, i)
        if w:
            line.pf[i].set_mix(int(lr[w]))


def set_upper(c, left, right):
    c[0] = (c[0] & 0xFF) | (left << 8)
    c[1] = (c[1] & 0xFF) | (right << 8)


def set_lower(c, left, right):
    c[0] = (c[0] & 0x100) | left
    c[1] = (c[1] & 0x100) | right


def get_pf_scroll(control_0, pf_num, flip=False):
    """Port of get_pf_scroll, keeping the s16 wraparound the original relies on.

    The two flipscreen x adjustments are 320<<6 and (512+192)<<6, which sum to
    exactly 65536 -- in s16 they cancel. Written out rather than simplified,
    because it is the register maths the RTL has to reproduce.
    """
    sx_raw = s16(control_0[pf_num])
    sy_raw = s16(s16(control_0[pf_num + 4]) + (1 << 7))     # 9.7
    if flip:
        sx_raw = s16(sx_raw + (320 << 6))
        sx_raw = s16(sx_raw + ((512 + 192) << 6))
        sy_raw = s16(-sy_raw)
    sx_raw = s16(sx_raw + ((40 - 4 * pf_num) << 6))         # 10.6
    sx = (sx_raw << 2) ^ 0b11111100                         # 10.6 -> 24.8
    sy = sy_raw << 1                                        # 9.7 -> 24.8
    sx -= H_START << 8
    if flip:
        sy = -sy
    return sx, sy


# =========================================================================
#  Clipping and mixing
# =========================================================================

def calc_clip(clip, layer):
    """Port of calc_clip: turn four clip planes into a list of visible spans."""
    INF_L, INF_R = H_START, H_START + H_VIS
    normal = layer.clip_enable() & ~layer.clip_inv() & 0xF
    invert = layer.clip_enable() & layer.clip_inv() & 0xF
    if not layer.clip_inv_mode():
        normal, invert = invert, normal

    ranges = [[INF_L, INF_R]]
    for plane in range(NUM_CLIP):
        cl = clip[plane][0] - 1
        cr = clip[plane][1] - 2
        if normal & (1 << plane):
            out = []
            for rg in ranges:
                if cl > cr or rg[1] < cl or rg[0] > cr:
                    continue
                out.append([max(rg[0], cl), min(rg[1], cr)])
            ranges = out
        elif (invert & (1 << plane)) and cl <= cr:
            new = ([[INF_L, cl] for _ in ranges] + [[cr, INF_R] for _ in ranges])
            out = []
            for it in new:
                dead = False
                for rg in ranges:
                    it[0] = max(rg[0], it[0])
                    it[1] = max(rg[0], it[1])
                    if it[0] >= it[1]:
                        dead = True
                        break
                if not dead:
                    out.append(it)
            ranges = out
    return ranges


def mosaic(xs, sample):
    x_count = xs - 46 + 114
    x_count = np.where(x_count >= 432, x_count - 432, x_count)
    return xs - (x_count % sample)


def mix_line(gfx, z, pri, line, lo, hi):
    """Vectorised port of mix_line.

    Every x is independent in the original -- all state is indexed by x and
    never read across columns -- so the whole span is one set of numpy masks.
    """
    lo = max(lo, H_START)
    hi = min(hi, H_START + H_VIS)
    if lo >= hi:
        return

    xs = np.arange(lo, hi)
    xs = xs[pri['src_blendmode'][xs] != gfx.blend_mode]
    if xs.size == 0:
        return

    real_x = mosaic(xs, line.x_sample) if gfx.x_sample_enable else xs
    y = gfx.y_index(line.y)
    gx = gfx.x_index(real_x)

    color = gfx.pix[y][gx].astype(np.int32)
    keep = ~gfx.inactive_group(color)
    flags_row = None
    if gfx.flg is not None:
        flags_row = gfx.flg[y]
        keep &= (flags_row[gx] & 0xF0) != 0
    if not keep.any():
        return
    xs, gx, color = xs[keep], gx[keep], color[keep]

    nz = color != 0
    if not nz.any():
        return
    xs, gx, color = xs[nz], gx[nz], color[nz]

    pal = gfx.palette_adjust(color)
    sel = gfx.blend_select(flags_row, gx)
    blend = line.blend
    prio = gfx.prio
    bm = gfx.blend_mode

    src_case = prio > pri['src_prio'][xs]
    dst_case = (~src_case) & (prio >= pri['dst_prio'][xs])

    # ---- source pixels -------------------------------------------------
    if src_case.any():
        xi, pi, si = xs[src_case], pal[src_case], sel[src_case]
        if bm == 1:                                   # normal blend
            bv = blend[2 + si]
            ok = bv != 0
            z['src_blend'][xi[ok]] = bv[ok]
        elif bm == 2:                                 # reverse blend
            bv = blend[si]
            ok = bv != 0
            z['src_blend'][xi[ok]] = bv[ok]
        else:                                         # opaque (0 or 3)
            b0, b1 = blend[si], blend[2 + si]
            ok = (b0 + b1) != 0
            z['src_blend'][xi[ok]] = b1[ok]
            z['dst_blend'][xi[ok]] = b0[ok]
            pri['dst_prio'][xi[ok]] = prio
            z['dst_pal'][xi[ok]] = pi[ok]
        z['src_pal'][xi[ok]] = pi[ok]
        pri['src_blendmode'][xi[ok]] = bm
        pri['src_prio'][xi[ok]] = prio

    # ---- destination pixels --------------------------------------------
    if dst_case.any():
        xj, pj, sj = xs[dst_case], pal[dst_case], sel[dst_case]
        old_dp = pri['dst_prio'][xj]
        # a priority tie is a colour-line conflict on real hardware
        z['dst_pal'][xj] = np.where(prio != old_dp, pj, 0)
        pri['dst_prio'][xj] = prio
        sbm = pri['src_blendmode'][xj]
        z['dst_blend'][xj] = np.where(sbm == 1, blend[sj], blend[2 + sj])


def render_line(clut, z):
    s = clut[z['src_pal'] & 0x1FFF]
    d = clut[z['dst_pal'] & 0x1FFF]
    out = (s * z['src_blend'][:, None] + d * z['dst_blend'][:, None]) >> 3
    return np.clip(out, 0, 255)


# =========================================================================
#  Sprites
# =========================================================================

class Axis:
    """One axis of the sprite position/zoom state machine (get_sprite_info)."""

    def __init__(self):
        self.block_scale = 1 << 8
        self.pos = 0
        self.block_pos = 0
        self.glob = 0
        self.subglobal = 0

    def update(self, scroll, posw, multi, block_ctrl, new_zoom):
        new_pos = sext(posw, 12)
        if scroll & 1:
            self.subglobal = new_pos
        if scroll & 2:
            self.glob = new_pos
        if not (scroll & 8):
            new_pos = s16(new_pos + self.glob)
            if not (scroll & 4):
                new_pos = s16(new_pos + self.subglobal)

        if block_ctrl == 0:
            if not multi:
                self.block_pos = new_pos << 8
                self.block_scale = 0x100 - new_zoom
            self.pos = self.block_pos
        elif block_ctrl == 2:
            self.pos = self.block_pos
        elif block_ctrl == 3:
            self.pos += self.block_scale * 16


class Sprite:
    __slots__ = ("code", "color", "flip_x", "flip_y", "x", "y",
                 "scale_x", "scale_y", "pri")


class SpriteEngine:
    """The F3 sprite framebuffer and its list-walking front end.

    F3 sprites are drawn into a framebuffer, not per scanline -- the "sprite
    trails" feature (don't clear the buffer) only makes sense with real
    storage behind it, and that is a 432x262 16-bit buffer. That is 1.8 Mbit,
    which is why the RTL cannot simply copy this structure into BRAM.
    """

    def __init__(self, spr_gfx):
        self.gfx = spr_gfx
        self.nelem = len(spr_gfx)
        self.flipscreen = False
        self.bank = False
        self.trails = False
        self.extra_planes = 0
        self.pen_mask = 0x0F
        self.fb = np.zeros((262, H_TOTAL), np.uint16)
        self.row_usage = np.zeros(256, np.uint8)
        self.spritelist = []

    def get_sprite_info(self, spriteram):
        x, y = Axis(), Axis()
        color = 0
        multi = False
        out = []
        offs = 0
        total = 0
        while offs < 0x400 and total < 0x400:
            total += 1
            bank = 0x4000 if self.bank else 0
            spr = [int(v) for v in spriteram[bank + offs * 8: bank + offs * 8 + 8]]

            if spr[3] & 0x8000:                       # special command
                cntrl = spr[5]
                self.flipscreen = bool((cntrl >> 13) & 1)
                self.extra_planes = (cntrl >> 8) & 3
                self.pen_mask = (self.extra_planes << 4) | 0x0F
                self.trails = bool((cntrl >> 1) & 1)
                self.bank = bool(cntrl & 1)

            # The jump is taken AFTER the command but the rest of this entry
            # is still processed -- MAME sets offs = new_offs - 1 and lets the
            # loop increment run. recalh jumps backwards, so no "<= offs" break.
            next_offs = offs + 1
            if spr[6] & 0x8000:
                new_offs = spr[6] & 0x3FF
                if new_offs == offs:
                    break
                next_offs = new_offs

            spritecont = spr[4] >> 8
            if not ((spritecont >> 2) & 1):           # "lock" reuses the palette
                color = spr[4] & 0xFF
            scroll_mode = (spr[2] >> 12) & 0xF
            zooms = spr[1]
            x.update(scroll_mode, spr[2] & 0xFFF, multi, (spritecont >> 6) & 3, zooms & 0xFF)
            y.update(scroll_mode, spr[3] & 0xFFF, multi, (spritecont >> 4) & 3, zooms >> 8)
            multi = bool((spritecont >> 3) & 1)

            tile = spr[0] | ((spr[5] & 1) << 16)
            if not tile:
                offs = next_offs
                continue

            if self.flipscreen:
                tx = (512 << 8) - x.block_scale * 16 - x.pos
                ty = (256 << 8) - y.block_scale * 16 - y.pos
            else:
                tx, ty = x.pos, y.pos

            if (tx + x.block_scale * 16 <= VIS_X0 << 8 or tx > VIS_X1 << 8 or
                    ty + y.block_scale * 16 <= VIS_Y0 << 8 or ty > VIS_Y1 << 8):
                offs = next_offs
                continue

            s = Sprite()
            s.x, s.y = tx, ty
            fx, fy = bool(spritecont & 1), bool((spritecont >> 1) & 1)
            s.flip_x = (not fx) if self.flipscreen else fx
            s.flip_y = (not fy) if self.flipscreen else fy
            s.code = tile
            s.color = color
            s.scale_x = x.block_scale
            s.scale_y = y.block_scale
            s.pri = (color >> 6) & 3
            out.append(s)
            offs = next_offs

        self.spritelist = out

    def draw_sprites(self):
        if not self.trails:
            self.fb[:] = 0
            self.row_usage[:] = 0
        for s in reversed(self.spritelist):
            self._drawgfx(s)

    def _drawgfx(self, s):
        tile = self.gfx[s.code % self.nelem]
        fx = 0xF if s.flip_x else 0
        fy = 0xF if s.flip_y else 0
        dy8 = s.y + (0 if self.flipscreen else 255)     # rounds up when not flipped
        base = SPR_COLORBASE + (s.color << 4)
        bit = 1 << s.pri
        for yy in range(16):
            dy = dy8 >> 8
            dy8 += s.scale_y
            if dy < VIS_Y0 or dy > VIS_Y1:
                continue
            row = tile[yy ^ fy]
            fbrow = self.fb[dy]
            dx8 = s.x + 128                             # 128 is 1/2 in fixed.8
            for xx in range(16):
                dx = dx8 >> 8
                dx8 += s.scale_x
                if dx < VIS_X0 or dx > VIS_X1:
                    continue
                if dx == dx8 >> 8:      # zoomed out: next pixel lands here too
                    continue
                c = int(row[xx ^ fx]) & self.pen_mask
                if c and not fbrow[dx]:
                    fbrow[dx] = base | c
                    self.row_usage[dy] |= bit


# =========================================================================
#  Frame rendering
# =========================================================================

def row_usage_playfields(dump):
    used = []
    for i in range(NUM_TMAP):
        blk = dump.pf_ram[PF_STRIDE * i: PF_STRIDE * (i + 1)]
        code = blk[1::2].reshape(32, TMAP_COLS)
        used.append((code != 0).any(axis=1))
    return used


def row_usage_text(dump):
    return ((dump.textram.reshape(64, 64) & 0xFF) != 0).any(axis=1)


def render_frame(dump, gfxs, eng):
    flip = eng.flipscreen
    pf_pix, pf_flg = build_playfields(dump, gfxs["pf"], flip)
    vram_pix, vram_flg = build_vram_layer(dump, gfxs["char"], flip)
    pixel_pix, pixel_flg = build_pixel_layer(dump, gfxs["pivot"], flip)
    pf_used = row_usage_playfields(dump)
    text_used = row_usage_text(dump)

    line = LineInf()
    for i in range(NUM_PF):
        sx, sy = get_pf_scroll(dump.control_0, i, flip)
        line.pf[i].reg_sx, line.pf[i].reg_sy = sx, sy
        line.pf[i].reg_fx_y = sy
    if flip:
        line.pivot.reg_sx = (dump.control_1[4] - 12) & 0xFFFF
        line.pivot.reg_sy = dump.control_1[5] & 0xFFFF
    else:
        line.pivot.reg_sx = (-dump.control_1[4] - 5) & 0xFFFF
        line.pivot.reg_sy = (-dump.control_1[5]) & 0xFFFF

    out = np.zeros((256, H_TOTAL, 3), np.int32)

    for screen_y in range(256):
        # line RAM is walked backwards when flipped, but y_index still uses
        # the screen line
        read_line_ram(dump.line_ram, line,
                      (255 - screen_y) if flip else screen_y, dump.control_1)
        line.y = screen_y

        for i in range(NUM_PF):
            pf = line.pf[i]
            tmap = i if EXTEND else (i + 2 * int(pf.alt_tilemap))
            pf.pix, pf.flg = pf_pix[tmap], pf_flg[tmap]
            pf.reg_fx_x = pf.reg_sx + pf.rowscroll
            pf.reg_fx_x += 10 * (pf.x_scale - (1 << 8))
        if line.pivot.use_pix():
            line.pivot.pix, line.pivot.flg = pixel_pix, pixel_flg
        else:
            line.pivot.pix, line.pivot.flg = vram_pix, vram_flg
        for sp in line.sp:
            sp.pix, sp.flg = eng.fb, None

        z = {"src_pal": np.zeros(H_TOTAL, np.int32),
             "dst_pal": np.full(H_TOTAL, line.bg_palette, np.int32),
             "src_blend": np.zeros(H_TOTAL, np.int32),
             "dst_blend": np.full(H_TOTAL, 8, np.int32)}
        pri = {"src_prio": np.zeros(H_TOTAL, np.int32),
               "dst_prio": np.zeros(H_TOTAL, np.int32),
               "src_blendmode": np.full(H_TOTAL, 0xFF, np.int32),
               "dst_blendmode": np.full(H_TOTAL, 0xFF, np.int32)}

        # this order settles priority ties the way the hardware does
        layers = [line.pivot,
                  line.sp[0], line.pf[0],
                  line.sp[3], line.pf[3],
                  line.sp[2], line.pf[2],
                  line.sp[1], line.pf[1]]
        layers.sort(key=lambda L: -L.prio)      # stable, descending

        if VIS_Y0 <= screen_y <= VIS_Y1:
            # F3_ONLY=pv,pf0,sp1,... renders a subset of the layers. This is
            # how a partially-built RTL renderer gets compared: bring up one
            # layer, render the same subset here, diff.
            only = os.environ.get("F3_ONLY")
            for g in layers:
                if only:
                    nm = ("pv" if isinstance(g, PivotInf) else
                          ("sp%d" % g.index if isinstance(g, SpriteInf) else "pf%d" % g.index))
                    if nm not in only.split(","):
                        continue
                if not g.layer_enable():
                    continue
                if isinstance(g, PivotInf):
                    ya = g.y_index(screen_y)
                    ya = (0x1FF - ya) if flip else ya
                    ok = g.use_pix() or text_used[ya >> 3]
                elif isinstance(g, SpriteInf):
                    ok = bool(eng.row_usage[screen_y] & (1 << g.index))
                else:
                    ya = g.y_index(screen_y)
                    ya = (0x1FF - ya) if flip else ya
                    ok = pf_used[g.index + (0 if EXTEND else 2 * int(g.alt_tilemap))][
                        ya >> 4]
                if not ok:
                    continue
                for rg in calc_clip(line.clip, g):
                    mix_line(g, z, pri, line, rg[0], rg[1])
            out[screen_y] = render_line(dump.clut, z)

        if screen_y != 0:
            for pf in line.pf:
                pf.reg_fx_y += pf.y_scale

    return out[VIS_Y0:VIS_Y1 + 1, H_START:H_START + H_VIS, :].astype(np.uint8)


def load_gfx(d):
    return {
        "pf": f3_gfx.load_playfield_gfx(os.path.join(d, "rgn_tilemap.bin"),
                                        os.path.join(d, "rgn_tilemap_hi.bin")),
        "spr": f3_gfx.load_sprite_gfx(os.path.join(d, "rgn_sprites.bin"),
                                      os.path.join(d, "rgn_sprites_hi.bin")),
    }


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    d, frame = sys.argv[1], int(sys.argv[2])
    compare = "--compare" in sys.argv
    seq = "--no-seq" not in sys.argv

    gfxs = load_gfx(d)
    eng = SpriteEngine(gfxs["spr"])

    # Sprite lag: the list on screen was built from sprite RAM `lag` frames
    # back. Ray Force / Gunlock are 2, the Bubble games are 1 -- MAME's
    # f3_config_table per game. WARM is how many extra earlier frames to walk
    # so the engine's latched state (bank, flipscreen, extra planes, and the
    # trails framebuffer) is what it would be at that point.
    lag = int(os.environ.get("F3_LAG", "2"))
    if "--lag" in sys.argv:
        lag = int(sys.argv[sys.argv.index("--lag") + 1])
    WARM = 2

    if seq and lag:
        have = 0
        for f in range(frame - lag - WARM, frame - lag + 1):
            if not os.path.exists(os.path.join(d, "f3_%05d_spriteram.bin" % f)):
                continue
            eng.get_sprite_info(Dump(d, f).spriteram)
            eng.draw_sprites()
            have += 1
        if not have:
            # No lagged dump, so the framebuffer stays empty -- but the engine
            # still has to LATCH the command-word state, because render_frame
            # reads eng.flipscreen and a wrong flip moves every playfield.
            # Latch from this frame without drawing: sprites missing is honest,
            # a mirrored background is not.
            eng.get_sprite_info(Dump(d, frame).spriteram)
            print("note: sprite_lag is %d but no dump for frame-%d exists;"
                  " rendering without sprites (state latched from frame %d)"
                  % (lag, lag, frame))

    dump = Dump(d, frame)
    gfxs["char"] = f3_gfx.decode_char(dump.charram_raw)
    gfxs["pivot"] = f3_gfx.decode_char(dump.pivot_raw)
    if not seq or not lag:
        eng.get_sprite_info(dump.spriteram)
        eng.draw_sprites()
    img = render_frame(dump, gfxs, eng)

    from PIL import Image
    out = os.path.join(d, "f3_%05d_model.png" % frame)
    Image.fromarray(img).save(out)
    print("wrote", out, img.shape)

    if compare and dump.frame_ref is not None:
        ref = dump.frame_ref[:, :, :3]
        diff = (img.astype(np.int32) - ref)
        bad = (diff != 0).any(axis=2)
        n = int(bad.sum())
        total = bad.size
        print("pixels differing: %d / %d  (%.3f%%)" % (n, total, 100.0 * n / total))
        if n:
            ys, xs = np.nonzero(bad)
            print("  first diff at (x=%d, y=%d): model %s ref %s" %
                  (xs[0], ys[0], img[ys[0], xs[0]], ref[ys[0], xs[0]]))
            vis = np.zeros(img.shape, np.uint8)
            vis[..., 0] = bad * 255
            Image.fromarray(np.concatenate(
                [ref.astype(np.uint8), img, vis], axis=1)).save(
                    os.path.join(d, "f3_%05d_diff.png" % frame))
            print("  wrote", os.path.join(d, "f3_%05d_diff.png" % frame))
    return 0


if __name__ == "__main__":
    sys.exit(main())
