#!/usr/bin/env python3
"""Generate rtl/rf_selftest_page.sv -- the static text of the core self-test page.

The page is 40x28 characters over the 320x224 raster. This script emits the
label ROM plus the layout constants, so rf_selftest.sv and rf_uart_log.sv
cannot drift from each other or from the page: both read this ROM and overlay
the same value and status fields at the same columns.

Character codes are ascii-0x20, matching rf_font8x8.sv.

    python3 tools/make_selftest_page.py
"""
from pathlib import Path

COLS, ROWS = 40, 28
VAL_C0, VAL_W = 16, 8       # eight hex digits
ST_C0, ST_W = 26, 4         # PASS / FAIL / WAIT / BUSY

# (text, has_value, has_status). The check index of a value row is its position
# in the value-row list; rf_selftest.sv selects on the row number directly, so
# the two only have to agree on the row numbers below.
PAGE = [
    ("TAITO F3 CORE", 0, 0),          # row 0 is REPLACED at render time by the
                                     # game name below, chosen by the MRA's
                                     # game-config byte; this is the fallback
    ("SELF TEST",                           0, 0),
    ("-- LOAD AND FETCH -------------------", 0, 0),
    ("ROM BYTES",                           1, 1),
    ("ROM CHECKSUM",                        1, 1),
    ("SDRAM BIST",                          1, 1),
    ("-- CPU AND MEMORY MAP ---------------", 0, 0),
    ("PIVOT WR:SND PC",                     1, 1),   # {pivot RAM writes (must stay 0), sound CPU PC}
    ("WRITE HASH",                          1, 1),
    ("HS:TRAP:MAIN PC",                    1, 1),   # {injected, sh_ok, out-of-range fetch flag, main 68020 PC}
    ("SPR REC : DROP",                      1, 1),   # {records built last prepass, rows dropped at the cap}
    ("-- INTERRUPTS -----------------------", 0, 0),
    ("SND ES WR : RUN",                     1, 1),   # {sound CPU ES5505 writes, running}
    ("IRQ2 ACK/64FRM",                      1, 1),
    # DIAGNOSTIC BUILD: borrowed from SMP BIST:OVR:DR (sample-region BIST,
    # sampler overruns, queue drops) -- restore that label and rf_selftest's
    # row 14 once the Darius Gaiden sprite-colour bug is closed.
    ("STALELN:AGE:CNT",                     1, 1),   # {last STALE sprite line, frames old, stale lines since reset} -- rf_spr_fb
    ("-- DRAW VS MIXER, LAST 4 FRAMES -----", 0, 0),
    # DIAGNOSTIC BUILD: this row's value had 16'd0 in its upper half; it now
    # carries rf_main's palette-write split at entry 0x1000 (pal_wr_hi is at
    # and above it, pal_wr_lo below). That is the "did the CPU ever ISSUE the
    # upper-half burst" half of the Darius Gaiden tower-colour question, and
    # without it the counters are built and then thrown away by synthesis.
    # The row's PASS test is unchanged (still pal_wr_cnt != 0). Restore the
    # "PALETTE" label, and rf_selftest's row 16, once that bug is closed.
    ("PAL HI : LO",                         1, 1),
    # BORROWED 2026-09-10 from FOLDSEQ N:N-1 (sprite corruption: closed).
    # {lowest raster line, highest raster line, count} of the CPU's writes to
    # the video control registers (0x660000-1F) last frame -- rf_main. A
    # tear that moves with scrolling is a scroll write under the beam; this
    # says whether there is one and on which line.
    ("VCTRL MIN:MAX:N",                     1, 1),
    # BORROWED 2026-09-10 from FOLDSEQ N-2:N-3 (sprite corruption: closed).
    # {rf_out_flip display lines fetched late, source lines written late} --
    # the analog flip's DDR3 timing, judged on the board. Both must be 0.
    ("FLIP LATE:WLATE",                     1, 1),
    # BORROWED 2026-09-09 from USEDSEQ N:N-1 only, exactly as
    # SPRFETCH:ROWMAX borrowed MIX:BUILD -- the page is 28 rows, so a new row
    # costs an old one. Those two were measurement rows for the sprite
    # corruption, whose root cause (rec store aliasing) is closed. Restore
    # them here and in rf_selftest.sv if the sprite work reopens.
    #
    # WHY THESE: the Bubble games' playfield corrupts on hardware while the
    # SAME frames render 71680/71680 in simulation, so the fault is in the
    # VRAM the CPU writes, not in the renderer. Simulation replays MAME's
    # VRAM and therefore cannot see it. These two rows split the CPU's writes
    # by destination, which is the measurement nothing on the board makes.
    ("PF WR  : SPR WR",                     1, 1),
    # BORROWED 2026-09-11 from USEDSEQ N-2:N-3 (sprite corruption: closed).
    ("FLUSH:SHORT",                         1, 1),
    ("-- VIDEO PIPELINE / FRAME -----------", 0, 0),
    ("SPRFETCH:ROWMAX",                     1, 1),   # {longest single sprite gfx fetch in clocks, most rows drawn on one line}
    ("FETCH : PIX NZ",                      1, 1),
    ("MAXFETCH:BUILD",                      1, 1),
    # DIAGNOSTIC BUILD: borrowed from TILE NZ:PF:PAL (a bring-up liveness
    # check that a working pipe already implies). {rotation preemptions of the
    # sprite framebuffer on the shared DDRAM port, sprite line reads that came
    # back short}. Every other instrument on this page sits on the sprite side
    # of that port -- the side that wins arbitration -- which is why they all
    # read clean while the screen is visibly wrong under load. Restore the
    # "TILE NZ:PF:PAL" label and rf_selftest's row 25 once that is closed.
    ("BK:PAR:OVR:END",                     1, 1),
    ("BUILD",                               1, 0),
    ("SPRLINE : LATE",                      1, 1),   # {longest sprite line draw, lines the mixer started before the draw finished them}
]

assert len(PAGE) == ROWS, f"{len(PAGE)} rows, expected {ROWS}"

# One title per game id (Rayforce.sv "GAME CONFIG", {bit 5, bits 7:6}). The core runs a
# Taito F3 BOARD, so the page should say which game is in it rather than
# whichever game the core was first written for. Appended after the visible
# rows; rf_selftest reads row 0 from here instead of from the page itself.
NAMES = [
    "RAY FORCE (US)        TAITO F3 CORE",
    "ELEVATOR ACTION RETURNS  TAITO F3",
    "BUBBLE BOBBLE II      TAITO F3 CORE",
    "BUBBLE MEMORIES       TAITO F3 CORE",
    "DARIUS GAIDEN         TAITO F3 CORE",
    "PUZZLE BOBBLE 2       TAITO F3 CORE",
    "GUNLOCK               TAITO F3 CORE",
    "RAY FORCE (JAPAN)     TAITO F3 CORE",
    # LAST ENTRY IS THE FALLBACK. rf_selftest clamps any game id without a
    # title of its own to this row, so the id field covers all 35 F3 parent
    # sets while the page ROM only carries the titles actually written.
    "TAITO F3 CORE",
]
assert len(NAMES) >= 2
for n in NAMES:
    assert len(n) <= COLS, f"title too long: {n!r}"


def main():
    val_mask = 0
    st_mask = 0
    cells = []
    for r, (text, has_val, has_st) in enumerate(PAGE):
        if has_val:
            val_mask |= 1 << r
        if has_st:
            st_mask |= 1 << r
        if has_val and len(text) > VAL_C0:
            raise SystemExit(f"row {r} label runs into the value field: {text!r}")
        if len(text) > COLS:
            raise SystemExit(f"row {r} is {len(text)} chars, max {COLS}: {text!r}")
        padded = text.ljust(COLS)
        for c, ch in enumerate(padded):
            code = ord(ch) - 0x20
            if not 0 <= code < 64:
                raise SystemExit(f"row {r} col {c}: {ch!r} is outside the font")
            cells.append(code)

    # the per-game titles live after the visible rows
    for n in NAMES:
        for ch in n.ljust(COLS):
            code = ord(ch) - 0x20
            if not 0 <= code < 64:
                raise SystemExit(f"title char {ch!r} outside the font")
            cells.append(code)

    out = []
    out.append("//" + "=" * 74)
    out.append("//  Taito F3 - static text of the core self-test page")
    out.append("//")
    out.append("//  GENERATED FILE -- do not edit by hand.")
    out.append("//  Produced by tools/make_selftest_page.py")
    out.append("//")
    out.append(f"//  {COLS}x{ROWS} characters over the 320x224 raster. Two read ports: the")
    out.append("//  pixel renderer (rf_selftest) uses one, the UART logger (rf_uart_log)")
    out.append("//  uses the other, so what goes out the serial port is character-for-")
    out.append("//  character what is on the screen.")
    out.append("//" + "=" * 74)
    out.append("")
    out.append("package rf_selftest_pkg;")
    out.append(f"    localparam int ST_COLS  = {COLS};")
    out.append(f"    localparam int ST_ROWS  = {ROWS};")
    out.append(f"    localparam int ST_TITLES = {len(NAMES)};")
    out.append(f"    localparam int ST_VAL_C0 = {VAL_C0};")
    out.append(f"    localparam int ST_VAL_W  = {VAL_W};")
    out.append(f"    localparam int ST_ST_C0  = {ST_C0};")
    out.append(f"    localparam int ST_ST_W   = {ST_W};")
    out.append("    // bit r set = row r prints a value / a status word")
    out.append(f"    localparam logic [{ROWS-1}:0] ST_VAL_ROWS = {ROWS}'h{val_mask:07X};")
    out.append(f"    localparam logic [{ROWS-1}:0] ST_ST_ROWS  = {ROWS}'h{st_mask:07X};")
    out.append("endpackage")
    out.append("")
    out.append("module rf_selftest_page (")
    out.append("    input  logic        clk,")
    out.append("    input  logic [10:0] a_addr,   // row * ST_COLS + col")
    out.append("    output logic  [5:0] a_char,")
    out.append("    input  logic [10:0] b_addr,")
    out.append("    output logic  [5:0] b_char")
    out.append(");")
    out.append("")
    # M10K, explicitly. 1480 x 6 bits is 8,880 bits, and an MLAB holds 640 --
    # so left to itself Quartus spent ~47 MLABs, i.e. ~47 LABs, on a page of
    # constant debug text at 70 % width waste (6 bits used of 20). One M10K
    # holds the whole thing with room over. Both reads are already registered
    # and it is a true dual-port ROM, which is exactly what an M10K is for.
    # Audited 2026-09-11, when the design failed to fit by 16 LABs.
    out.append('    (* ramstyle = "M10K" *)')
    out.append(f"    logic [5:0] rom [0:{len(cells)-1}];")
    out.append("")
    out.append("    initial begin")
    labels = [t for t, _, _ in PAGE] + [f"title, game id {i}: {n}"
                                       for i, n in enumerate(NAMES)]
    for r, text in enumerate(labels):
        out.append(f"        // row {r:2d}: {text!r}")
        base = r * COLS
        for c in range(COLS):
            out.append(f"        rom[{base + c:4d}] = 6'd{cells[base + c]:2d};")
    out.append("    end")
    out.append("")
    out.append("    always_ff @(posedge clk) begin")
    out.append("        a_char <= rom[a_addr];")
    out.append("        b_char <= rom[b_addr];")
    out.append("    end")
    out.append("")
    out.append("endmodule")
    out.append("")

    p = Path("rtl/rf_selftest_page.sv")
    p.write_text("\n".join(out))
    print(f"wrote {p} ({ROWS}x{COLS} = {len(cells)} cells)")
    print(f"  value rows 0x{val_mask:07X}, status rows 0x{st_mask:07X}")


if __name__ == "__main__":
    main()
