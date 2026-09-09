# Bubble Bobble II and Bubble Memories: preparation

Prep for bringing the two Taito F3 Bubble Bobble games up on this core: the
MRAs, all ten self-test expectations, reference dumps for both games, and one
finding that decides the order of work -- **the Python reference model does
not yet reproduce these games exactly, and it must before any RTL comparison
means anything.**

*Written before any of it was built. Bubble Bobble II has since run on
hardware and `extend=0` has been implemented and verified; see "Order of
work" for what that changed and what it did not. The measurements and the
reasoning below still stand.*

    bublbob2   Bubble Bobble II (Ver 2.6O 1994/12/16)   D90
    bubblem    Bubble Memories (Ver 2.4O 1996/02/15)    E21

ROM sets: `/storage02/roms/mame/{bublbob2,bubblem}.zip`, merged sets holding
every part these MRAs name, all CRCs verified against MAME 0.288.

## These two are closer to Ray Force than Elevator Action is

Elevator Action Returns cost a visarea parameter because its raster is the
base f3 one (232 lines from 24) where Ray Force uses f3_224a (224 from 31).
**Both Bubble games use f3_224a -- Ray Force's exact crop.** MAME's machine
config says so and the dumped frames come out 320x224. The per-game field
EAR forced into existence is, for these two, Ray Force's own value: `0`.

| | Ray Force | Elev. Action R. | Bubble Bobble II | Bubble Memories |
|---|---|---|---|---|
| MAME machine | `f3_224a` | `f3` | `f3_224a` | `f3_224a` |
| visarea | 224 from 31 | 232 from 24 | **224 from 31** | **224 from 31** |
| `extend` | 1 | 1 | 1 | 1 |
| rotation | ROT90 vert | ROT0 horiz | ROT0 horiz | ROT0 horiz |
| 12-bit palette | no | no | no | no |
| `sprites_hi` ROM | yes | yes | yes | **none (4bpp)** |
| 18.5 MB map | pads half | exact | pads half | maincpu+sprites exact |

## All ten expectations are measured

`Rayforce.sv` holds five expectations per game so the self-test page can
judge rather than merely report. All five, for both games, are done:

|  | Bubble Bobble II | Bubble Memories |
|---|---|---|
| `exp_bytes` | `0x01280000` | `0x01280000` |
| `exp_sum`   | `0xA364D1A1` | `0xA5923CBE` |
| `exp_bist`  | `0xBE0F04C3` | `0xC4BD753B` |
| `exp_hash`  | `0xA7C4A522` | `0xA81F4977` |
| `exp_smp`   | `0x5597A419` | `0x9C2DE26F` |

Every one was produced by a method validated on a known answer first:
`rf_stream_sum.py` over the MRA (and that both streams assemble to exactly
`0x1280000` is itself proof the MRAs lay the regions out right); the rotl1+add
fold of the first 64 KB of the first ensoniq ROM, which reproduces Ray
Force's known `0xB86C4865` from `gunlock.zip`; and `oracle_f3writes.lua` +
`rf_write_compare.py`, which reproduced Ray Force's known `0x10620931` in the
same run that produced the two new hashes.

## Two things that look like problems and are not

**Sprite lag.** ~~MAME's `f3_config_table` declares lag 1 for both games,
against Ray Force's 2, but depth 2 beats depth 1 decisively, so the table
does not describe this dump pipeline. Do not add a lag parameter.~~

**WRONG, corrected 2026-09-09. The table was right and this WAS the bug --
see "The real gap" below.** The measurement that produced this paragraph was
broken: `--depth` only chose how many warm-up frames to walk, while the render
always used the sprite list from frame-2. `--depth 1` therefore drew NO
SPRITES AT ALL rather than lag-1 sprites, which is why lag 1 looked
catastrophic (6.7-83.8%) and why depths 3-6 came out byte-identical to depth
2. `f3_render.py` now takes `--lag N` / `F3_LAG=N`, default 2; **the Bubble
games need `--lag 1`.**

**Bubble Memories has no `sprites_hi` ROM.** MAME declares the region
`EMPTY_SPRITE_HIDATA(0x200000)` -- 2 MB of zeros -- so its sprites are
effectively 4bpp where every other set is 6bpp. This was the obvious
structural risk, and it is disproved: bmem frames 900, 1200 and 1800 render
**pixel-identical** to MAME with that region all zeros. The 4bpp path is
correct.

## The real gap: SOLVED 2026-09-09 -- it was sprite lag, not block/multi

**Both games are now 0 / 71680 on all ten frames, at `--lag 1`.** Ray Force
stays 0 at the default `--lag 2`, and Elevator Action Returns and all five
Darius Gaiden dumps are unchanged at 0.

| lag | bb2, ten frames | bmem, ten frames |
|---|---|---|
| 2 (old default) | 878 602 404 67 292 280 341 0 0 0 | 817 0 0 0 1340 298 301 10526 142 446 |
| **1 (correct)** | **0 0 0 0 0 0 0 0 0 0** | **0 0 0 0 0 0 0 0 0 0** |

The block/multi reasoning below is preserved because the elimination work in
it is still sound -- but its conclusion was wrong. The correlation it rests on
is real and misleading: these games DO set block control on 97% of sprites
where Ray Force sets it on 2%, and they also happen to be the games with a
different sprite lag. The differences were confined to sprite pixels because
a wrong lag moves only sprites. **A per-game constant, not a rendering path.**
That makes this the same lesson as [[f3-per-game-constants]] again.

Fixing the lag also fixed something unrelated in the old harness: because it
never called `get_sprite_info` when the lagged dump was missing, `eng.flipscreen`
kept its default and every playfield rendered unflipped. Ray Force frames 298,
598, 898, 1198, 1790, 2100 and 2398 went from 1746-30001 wrong pixels to 0
(or far fewer). The model now latches command state even when it cannot draw.

### The original block/multi analysis (kept for the elimination it did)

Model versus MAME's own frames, depth 2, ten dumped frames each:

| frame | 600 | 900 | 1200 | 1800 | 2400 | 3000 | 3600 | 4200 | 4800 | 5400 |
|---|---|---|---|---|---|---|---|---|---|---|
| **bb2** | 1.23% | 0.84% | 0.56% | 0.09% | 0.41% | 0.39% | 0.48% | **0** | **0** | **0** |
| **bmem** | 1.14% | **0** | **0** | **0** | 1.87% | 0.42% | 0.42% | 14.69% | 0.20% | 0.62% |

The control matters: on Ray Force's own dumps the same command gives
`0 / 71680` on every frame. So this is a real gap, not a harness artifact.

What is ruled out, by measurement rather than argument:

- **not sprite lag or history depth** -- depths 2 through 6 are identical to
  the byte, including on the 14.69% outlier, for which frames 4194-4199 were
  dumped specifically to test it
- **not zoom** -- bmem frame 4200 uses zero zoom on all 324 sprites, while
  Ray Force uses zoom on 326 of its 503 and is exact
- **not the missing `sprites_hi`** -- see above

What it points at. The differences are confined to sprite pixels, and these
games hammer the sprite multi/block/lock path an order of magnitude harder
than Ray Force ever does:

| dump | sprites | multi | lock | blockX != 0 |
|---|---|---|---|---|
| rayforce 3000 | 503 | 48 | 40 | **10** |
| bb2 600 | 754 | 730 | 730 | **742** |
| bmem 1800 | 1148 | 1026 | 1038 | **1084** |
| bmem 4200 | 324 | 306 | 306 | **314** |

Ray Force sets block control on 2% of its sprites; the Bubble games set it on
97%. That is the path Ray Force cannot have proven, and the residual error
lives in it. Note that it is not simply broken -- bb2 4200 (222 multi) and
bmem 1800 (1026 multi) are pixel-exact -- so the bug is a specific case
inside block/multi handling, not the feature as a whole.

`dump/bmem/f3_04200_diff.png` is the loudest example, and
`dump/bmem/f3_04200_model.png` beside `f3_04200_frame.argb` shows it plainly:
two mid-screen dragons drawn with the wrong pixels while the tilemaps,
palette and everything above y=130 match exactly.

## Order of work

Updated 2026-08-31, after the session that did items 5 and 7 out of order.

**Done since this was written:**

- Bubble Bobble II **runs on hardware**, with no RTL change at all. That was
  meant to be step 7; it turned out step 1 was not a prerequisite for merely
  running the game, only for proving it correct.
- `extend=0` is implemented in both the model (`F3_EXTEND`) and the RTL, and
  verified: Puzzle Bobble 2 frame 1800 is pixel-identical MAME -> model, and
  74240/74240 model -> RTL. It was tied off for a build for want of LABs and
  is live again, paid for by compiling the framework's Y/C encoder and
  ascal's adaptive filter out.
- The self-test expectation arms were added, then commented out when the
  fitter ran 10 LABs short. The numbers are preserved in `Rayforce.sv` and
  above; restoring them is uncommenting a block.

**Still to do, in order:**

1. ~~**Close the model gap.**~~ **DONE 2026-09-09** -- it was sprite lag, not
   block/multi. Use `--lag 1` for both Bubble games; both are pixel-exact on
   all ten frames. The RTL now has a trustworthy reference for these games,
   so verifying Bubble Bobble II is unblocked.
2. **Move `rec` and `sl_d` out of MLABs**, the way `sl_y` went. Worth ~832
   LABs, which is what the rest of the roadmap is short of. The draw has the
   slack (5179 clocks on the worst line with 0 late), but M10K is now at
   543/553 so blocks have to be freed first -- the debug ring is ~12.
3. ~~Widen `cfg_game` past 2 bits~~ (DONE -- it is `wire [5:0] cfg_game` now,
   which is how 26+ games ship), and move the expectations into an M10K ROM
   at the same time. The field is full at four games, and every game in the
   tables below needs an id. Note `ST_ROWS + game_id` is a 5-bit index with
   `ST_ROWS = 28`, so the self-test title rows need extending together with
   it.
4. ~~Add `bb2-*`/`bmem-*` targets to `sim/Makefile`~~ **DONE 2026-09-09**:
   `bb2-pipe-all`, `bmem-pipe-all`, `bb2-spr-line-all`, `bmem-spr-line-all`
   and `bubble-all`, at `F3_LAG=1` (no visarea override -- both are f3_224a,
   Ray Force's own crop). `F3_LAG` had to be plumbed through BOTH sides:
   `gen_pipe_ref.py`, `gen_spr_fb_ref.py`, `pipe_tb.cpp` and `spr_line_tb.cpp`
   all hardcoded `frame - 2`.

   **Result: 44/44 frames 71680/71680 pixels identical, RTL vs model.** With
   the model itself now 0/71680 against MAME, both games are verified end to
   end. The only divergence is the known, benign row-usage over-report
   (bb2 1799/1800: 46/45 flags; bmem 2999/3000: 21) -- the RTL sets the flag
   on any visible pen without a read-before-write, so overlapping priority
   groups over-claim. Ray Force frame 4200 has had 1 of these all along; these
   games mix priority groups far more (bb2 600 is 67 pri-1 and 280 pri-2
   sprites against Ray Force's 90% single group), hence the larger counts.
   Explained in HANDOFF.md; SPRITE-CORRUPTION.md still calls it unexplained.
5. Bubble Memories on hardware: it has an MRA and measured expectations but
   has never been loaded.

## What else the ROM shelf holds

`/storage02/roms/mame` has **35 of the driver's 100 F3 parent sets**. Scoring
each against what this core can actually do -- does it fit the 18.5 MB
universal map (by real ROM bytes, not MAME's declared region sizes), is it
`extend=1`, is it off the 12-bit palette list -- gives a roadmap. The method
validates: `gunlock` and `elvactr`, the two already running, score clean.

**Blocked by nothing at all** (beyond the `cfg_game` width below):

| set | visarea | rot | lag | |
|---|---|---|---|---|
| `gunlock` | f3_224a | ROT90 | 2 | running |
| `elvactr` | f3 | ROT0 | 2 | running |
| `bublbob2` | f3_224a | ROT0 | 1 | prepped here |
| `bubblem` | f3_224a | ROT0 | 1 | prepped here |
| `arkretrn` | f3 | ROT0 | 1 | Arkanoid Returns |
| `popnpop` | f3 | ROT0 | 1 | Pop'n Pop |
| `qtheater` | f3_224c | ROT0 | 1 | Quiz Theater (first f3_224c user) |
| `recalh` | f3 | ROT0 | 1 | Recalhorn (prototype) |
| `twinqix` | f3_224a | ROT0 | 1 | Twin Qix (prototype) |

So five more games are, on paper, MRA-and-a-config-byte work.

**The biggest single unlock is `extend=0`.** The renderer is hardwired to
`extend=1`. Seven available sets are blocked by that and nothing else:
`cleopatr`, `dariusg`, `dariusgx`, `gekiridn`, `gseeker`, `spcinv95`,
`pbobble2`. Darius Gaiden alone probably justifies the work.

**Second unlock: widen the universal map.** Six sets need only more room --
`sprites` past 4 MB (`commandw`, `lightbr`, `trstar`, `quizhuhu`,
`puchicar`) or `ensoniq` past 4 MB (`landmakr`, `puchicar`, `quizhuhu`).

**Third: the 12-bit palette path** (`ridingf`, and with extend=0 also
`arabianm`, `ringrage`). MAME itself flags this one as guesswork.

Out of reach without a much bigger map: `kaiserkn`, `dankuga`, `kirameki`,
`pwrgoal`, `tcobra2`, at 12-13 MB of sprites each.

**This is what makes the `cfg_game` width urgent.** A 2-bit field caps the
core at four games total, and Bubble Bobble II and Bubble Memories take the
last two ids. Every game in the tables above is unreachable until that field
grows, whatever else gets implemented. Widening it is a one-line RTL change
plus a config byte in four MRAs today; later it is a re-issue of every MRA
ever shipped.

## Artifacts produced

- `releases/experimental/Bubble Bobble II.mra`, `.../Bubble Memories.mra`
  (both marked UNTESTED)
- `dump/bb2/`, `dump/bmem/` -- 10 frames each plus predecessors, regions
  included; `dump/bmem/` also has 4194-4199 from the depth experiment
- `dump/wr/{rayforce,bublbob2,bubblem}.tr` -- write-stream traces
