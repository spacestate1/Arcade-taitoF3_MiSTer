# Moving the pivot RAM out of block RAM

Scope for fixing `spacestate1/Arcade-taitoF3_MiSTer` issue #5. Written
2026-09-09, before any of it is built.

## The defect, in one line

`rtl/rf_main.sv` instantiates the pivot RAM as `rf_bram_tdp #(.AW(12))` —
4096 words, 8 KB — where the F3 has 64 KB (`map(0x630000, 0x63ffff)`, backed
in MAME by `memory_share_creator<u16> m_pivot_ram(0x10000)`). CPU writes past
8 KB alias back over the start and destroy what is there.

The pivot pixel layer is 512 px wide, so an 8x shortfall makes it repeat every
**64 px**. Measured on hardware: story text every 8 characters (8 px cells),
level background every 4 tiles (16 px cells). Both symptoms in issue #5.

## Why it cannot simply be resized

Full size is 32768 x 16 = 512 Kbit ~ 64 M10K blocks against 8 today: **+56**.
The 2026-09-09 build (stamp 09131852) sits at **551 / 553 M10K**. Complete
inventory of what could be freed:

| candidate | blocks |
|---|---|
| HQ2x scandoubler (`Hq2x` + `hq2x_in`) | 14 |
| debug write ring (`u_ring`) | 3 |
| currently unused | 2 |
| **reachable total** | **19** |

Everything else is functional and matches MAME's declared sizes EXACTLY --
checked one by one: `spriteram` 0x10000, `line_ram` 0x10000, `pf_ram` 0xc000
(as `u_pf` + `u_pfx`), `textram` 0x2000, `charram` 0x2000, sound RAM 0x10000.
There is no over-allocation anywhere. The pivot RAM is the single deliberate
compromise in the design, and its comment says so: *"Ray Force is unaffected
either way: it only ever clears this RAM."*

19 < 56. The layer has to leave block RAM.

## What actually has to be stored where

The saving grace is in `rf_video_pivot.sv`'s own header: the layer builds
**one screen line at a time into a double-banked line buffer**, at a cost of
**64 + 320 + 4 clocks per line, on RAM ports nothing else uses**.

So the VIDEO side does not need random access to 64 KB. Per line it needs one
pixel row out of each of 40 visible cells. The pixel layer is stored as 64x32
cells of 8x8 4bpp, scanned in COLUMNS (`cell = col*32 + row`), and one row of
one cell is 8 pixels = 32 bits = **2 words**. That is **80 words per line**,
in 40 pairs, with a 32-word (64-byte) stride between pairs.

80 words/line x ~262 lines x 60 Hz = ~1.3 M words/s. Trivial bandwidth; the
cost is in the strided access pattern, not the volume.

The CPU side needs ordinary read/write of the whole 32768 words with byte
enables (the read mux already has `SRC_PIVOT`, so reads happen too).

## Route A -- SDRAM (preferred)

`rtl/rf_sdram.sv` already has seven channels and **ch3 is read/write**
(`ch3_din`, `ch3_be`, `ch3_rnw`), today shared between the ROM download and
the CPU program bus (`ch3_*_pb`). Pivot access is the same shape as the CPU's,
so it belongs there.

Work items:

1. Reserve 64 KB in the SDRAM map above the 18.5 MB game stream. The map is
   already profile-driven (`gen_f3_mra.py` SLOT/SLOT1); this is core-private
   space, not part of the MRA stream, so no MRA changes and no re-issue.
2. Route `sel_pivot` CPU reads and writes to ch3 with byte enables, and stall
   the 68020 on the existing `clkena` handshake until `ch3_ready`.
3. Give `rf_video_pivot` a small fetch engine: 40 x 2-word bursts into the
   line buffer it already owns, started at `line_start`, within the existing
   320-clock budget.
4. Delete `u_pivot` (frees 8 blocks) and widen the read path -- note
   `v_pivot_addr` is ALREADY `[14:0]`, so the rest of the design assumes full
   size; only the RAM instance and its `[11:0]` read port truncate.

## Route B -- DDR3

`DDRAM_DIN` / `DDRAM_RD` are wired at the top level and the framebuffer
already uses DDR3. More bandwidth, higher and more variable latency, and it
shares a port with the scaler. Only worth it if SDRAM contention proves fatal.

## Risks, in the order they are likely to bite

1. **SDRAM contention.** The gfx fetch has documented deadline sensitivity
   (`MAXFETCH`, `SPRFETCH:ROWMAX`, the fetch-overrun work). Adding 40 bursts
   per line to a bus already streaming sprites and tiles is the main hazard.
   Mitigation: the pivot fetch is the lowest-priority channel and has a whole
   line of slack; measure `MAXFETCH` before and after.
2. **CPU stalls on pivot access.** Games that write pivot RAM heavily could
   slow the 68020. Ray Force only clears it, so the regression risk is on the
   games this is meant to fix.
3. **Fit.** Deleting `u_pivot` frees 8 blocks and the fetch engine costs a few
   back; ALMs were 39,867/41,910 (95%) at seed 8. Should be neutral to
   positive, but 95% leaves little room.

## How it gets verified

The renderer is already proven correct given correct contents -- three Bubble
scenes at 71680/71680 against the model, and the model at 0/71680 against
MAME. So simulation CANNOT see this bug and cannot confirm the fix; it can
only prove no regression.

* before/after: `make pipe`, `make ear-pipe-all`, `make bubble-all` must stay
  identical. That is the regression gate.
* the fix itself is confirmed on hardware only: `dump/bb2_story` is the
  reproducer -- Bubble Bobble II attract, the "LITTLE BUBBY,LITTLE BOBBY,
  KULULUN, AND CORORON" screen, which the board currently renders as
  "ALLDREN"/"BOOK." repeating every 8 characters.
* `MAXFETCH:BUILD` and `SPRFETCH:ROWMAX` on the self-test page before and
  after, to catch item 1.
