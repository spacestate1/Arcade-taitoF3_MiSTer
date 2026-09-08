# The sprite corruption: everything tried, and what it ruled out

> **ROOT CAUSE FOUND 2026-09-08 — in the Quartus map report.** `rec_rtl_0:
> WIDTH 18, WIDTHAD 14, NUMWORDS 16384`. The record store `rec[0:1][0:NREC-1]`
> with `NREC = 12288` is 24,576 words and needs 15 address bits; Quartus built
> a 16,384-word RAM with `wb*NREC + f_rd` truncated to 14 bits. **Bank 1's
> records from 4,096 up alias onto bank 0's records 0..8191.** Every frame
> with more than 4,096 records has its tail clobber the other bank's head, so
> one frame parity draws a stale/mixed list and the other is live -- the
> "two layers, offset, flickering" reported from day one. Verilator models all
> 24,576 words, which is why every bench passed. Fix: `NREC = 8192`, so the
> store is exactly the RAM Quartus builds. See "Open" -> item 1 for the full
> account, and the memory note. **VERIFIED 2026-09-08 -- player: "that fixed almost all of it."**


The core's most visible defect, and the one that has consumed the most build
time. This file is the **single register** for it: the symptom as the player
describes it, every fix and instrument attempted with its verdict, what is
ruled out and by what evidence, and what is still open.

HANDOFF.md tells the story in date order and is the place for narrative.
**This file is the scoreboard.** Add a row here before starting anything, and
record the verdict when it lands -- several ideas below were tried twice
because nothing collected them in one place.

Last updated: 2026-09-08 (FIXED: NREC=8192, build 07213908, instruments + player confirm. Residue: boss row drops).

---

## The symptom, in the player's words

> "Corrupted sprite explosions or enemy sprites." Vertical lines of corruption
> at each side of the screen when the display is oriented vertically. Worse
> when the screen is busy with lots of objects and explosions. The screen on
> the board is much worse than a screenshot of the same moment.

## What the symptom actually is, measured (2026-09-07)

Six screenshots of one static screen fell into **exactly two states**, differing
by an identical 10,967 pixels each time:

- `screenshots/paused_cmp/frameA.png` -- correct.
- `screenshots/paused_cmp/frameB.png` -- the left rock column replaced by
  horizontal streaks of sprite-coloured pixels smeared along the scanlines
  across the lower two thirds.
- `screenshots/paused_cmp/diffmask.png` -- the difference, which is plainly
  **scanline-structured**: runs of whole lines, not blobs.

Four facts follow, and each one kills a family of theories:

1. **It alternates between two fixed states.** Something double-buffered is
   serving good content from one bank and garbage from the other.
2. **The garbage is DETERMINISTIC.** The four "B" captures were byte-identical
   to each other. That rules out metastability and any random timing glitch --
   it is a systematic difference, not a race.
3. **It happens at almost no load.** Frame A reads "PUSH 2P TO CONTINUE,
   CREDIT 02" -- the continue screen after a death, a near-static scene.
   **Heavy load is not required.** Busy scenes make it more visible, not more
   likely.
4. **Native scanlines become vertical lines when rotated**, which is exactly
   the player's description. The screenshot is the native 320x224 output; the
   display is rotated 90 degrees.

Point 3 contradicts README.md's "Known problems" item 1, which still concludes
the fix is a wider draw datapath. **That conclusion is not supported.**

---

## How the sprite path currently works

You need this to read the table below. The stages, and **every point where
state is double buffered** -- because the corruption alternates between two
fixed states, so a bank is implicated somewhere in here.

```
  sprite RAM  ──►  WALK  ──►  stored list  ──►  EXPAND  ──►  record store
   64 KB           (once/frame)  sl_y / sl_d     (prepass)     rec[bank]
   NOT buffered                                                  2 banks
                                                                    │
                                                                    ▼
  mixer  ◄──  DDR3 framebuffer  ◄──  line-buffer ring  ◄──────  DRAW
              2 banks (par)          NB = 2                  1 px/clock
```

**1. Sprite RAM** — `rf_bram_tdp #(.AW(15))`, 32,768 x 16 = 64 KB. The CPU
writes port A; the walker reads port B. **No snapshot, no interlock, not
double buffered.** This is open suspect #1 below.

**2. The walk** (`rf_video_spr_list`) — starts at `frame_start`
(`rf_video_spr.sv:751`) and streams sprite RAM into a compact list. It is a
small program: 8 words per entry, a bank bit, a jump command that can branch
and switch halves of the 64 KB, "multi" blocks reusing the previous block's
position and zoom, and per-axis scroll modes folding in two levels of global
offset. **Entirely sequential** — each entry's jump/bank/globals depend on the
last — so it cannot be parallelised or restarted cheaply.

**3. The stored list** — `NSPR = 1024` entries, split by consumer:
`sl_y` {ty, sy, fy} for the expand, in **M10K with a registered read**;
`sl_d` {tx, sx, code, color, fx} for the draw, in **MLAB, 2 banks, async read**.

**4. EXPAND** (prepass) — each sprite is spread over the screen lines it
covers. A `dy8` accumulator maps its 16 source rows (walked 15 -> 0) to screen
lines, and every in-range row becomes a record appended to that line's bucket
(a linked list: head/tail per line, next pointer per record). No vertical
dedup: when zoom crushes rows onto one line they overlay.
Store: `rec[0:1][0:NREC-1]`, `NREC = 12288` per bank, 18 bits,
**MLAB, 2 banks (`dbank`), async read**.

**5. DRAW** — from `frame_start`, draws lines 0..255 in order as fast as the
fetches allow, into a ring of `NB = 2` line buffers, running ahead of the
mixer. **Beware a stale claim elsewhere in the docs:** README "Known problems"
item 1 still describes a "ring of 8", and HANDOFF records deepening it 4 -> 8
and later 16. That was true when the ring's whole job was banking slack against
the raster. Once a whole frame was buffered in DDR3 that job disappeared and
the ring went back to **2** (`rf_video_spr.sv:633`), returning 14 M10K on a
device at 551/553. The "ring of 8" reasoning — 27,648 clocks of banked slack —
no longer describes this core. Emits **one pixel per clock**, 16 per row, drawn or not. Graphics come
from SDRAM through `rf_spr_gfx_bus` — two fetch buses (A/B) x two planes
(lo/hi) — behind a tile-row cache. That fetch path's data capture crosses
`clk_sys`/`clk_ram`, which `Rayforce.sdc:13` declares asynchronous, so **it is
cut from timing analysis entirely** and the module's own header admits the
arrival "passed or failed by fitter seed".

**6. DDR3 framebuffer** (`rf_spr_fb`) — each finished line is streamed out as
80 words and read back as 80 (`NRB = 8` line read window, `BL = 8` beat
chunks). **2 banks by frame parity (`par`)**: the draw writes one while the
mixer reads the other. Each line carries a CRC whose low 8 bits are a frame
tag, so a line proves both its content and its frame.

**7. Mixer** (`rf_video_mix`) — composites sprites with the playfields and the
pivot layer by priority. The per-line priority-group flags are **also double
banked** ("written for the frame being drawn, read for the frame being shown").

**Sprite lag is 2 frames**, which matches what MAME specifies for this game,
and it composes from two stages: the record store is double banked so the draw
reads last frame's bank, and the mixer then reads last frame's framebuffer.

### The double-buffered points, collected

Because the fault alternates between two fixed states, one of these is
serving different content on alternate frames:

| State | Where | Memory | Read |
|---|---|---|---|
| `rec` record store | `rf_video_spr.sv:323` | MLAB, 2 x 12288 x 18 | **async** |
| `sl_d` stored list | `rf_video_spr.sv:228` | MLAB, 2 x 1024 x 51 | **async** |
| per-line priority flags | `rf_video_spr.sv` | 2 x 256 x 4 | — |
| DDR3 framebuffer | `rf_spr_fb.sv`, `par` | DDR3 | verified by CRC |

The framebuffer row is **ruled out** (the fold says `wr == rd`). The other
three are not.

---

## Ruled out, with the evidence that did it

| Suspect | Verdict | Evidence |
|---|---|---|
| Sprite record store overflow | **ruled out** | `SPR REC : DROP` 0 dropped, every reading since NREC 12,288 |
| Lines composed before the draw finished ("late") | **ruled out** | `SPRLINE : LATE` 0 late across every capture |
| Lines displayed from the wrong frame (stale) | **ruled out** | `STALELN:AGE:CNT` 0 always, incl. during visible corruption |
| Sprite graphics fetch returning wrong data | **ruled out** | `fetch_bad` 00 always |
| DDR3 sprite framebuffer round trip | **ruled out** | `SPRFOLD WR:RD`: `wr == rd` on every sample, including in a busy scene (values `944A`, `BCE7`, `EEDD`) |
| Shared DDRAM port / rotation starving the framebuffer | **ruled out** | `ROTSTL:PK:LOST` 0 stalls across 210 samples of real gameplay |
| Sprite list built short (prepass overrun / walk / expand / fill) | **ruled out** | `RECSEQ`/`NSPRSEQ` constant across four frames on a paused glitch; `PREPASS OVR` 0, finishes at 5 % of the frame (build `07194816`) |
| Sprite RAM torn by CPU writes during the walk | **ruled out** | `SPRTEAR WR:FRM` = `01C20001`, constant over 126 samples: 450 writes in **one** frame (CPU initialising at core load), never again. Same boot-artifact shape as the `STALELN` count-of-1. |
| Abandoned-line residue in the line buffer | **ruled out** | Real gap found: `frame_start` mid-draw discards `cur_lo`/`cur_hi`, so the bank's stale pixels are never cleared (`rf_video_spr.sv:956`, and identical on `origin/master`). But `Rayforce.sv:402` records the board measured `draw_unfinished = 0` — the draw always finishes its 256 lines, so the state never occurs. Speculative fix written, tested (bench unchanged), and **reverted**. |
| Multi-write RAM inference on `cnt` / `rec` | **ruled out** | The mechanism that caused the original sprite splits. All four `cnt` writes (`793`, `825`, `845`, `880`) are in distinct branches of one `case (pst)`, so only one fires per cycle; `rec` has a single write site. |
| Draw throughput / pixels per clock | **contradicted** | corruption is present on the near-static continue screen |
| Palette content (Darius) | **ruled out** | 1023/1024 entries identical to MAME's `dg5070` dump |

**Read that table carefully.** Every instrument in it sits on the *sprite* side
of the pipeline, and they all read clean while the picture is visibly wrong.
That is itself the strongest clue in the file: whatever is wrong is either
upstream of them all, or in something none of them watches.

---

## Everything tried, in order

**The `PLAYER` column is the one that decides.** Every instrument in this core
sits on the sprite side of the pipeline and reads clean while the picture is
visibly wrong, so a measured improvement means nothing until someone looks at
the screen. This project has already had one case where the player's direct
observation beat a metric: the tile-row cache measured 3 % and was removed as
unproven, the picture got worse, and it went back in.

Values: **better** / **worse** / **no change** / **fixed** / **not assessed**.
"Not assessed" is not a pass -- it means nobody has looked, and several rows
below have carried that quietly for weeks.

### Fixes that were real and stayed

| # | Change | Measured result | PLAYER |
|---|---|---|---|
| 1 | **Sprite framebuffer moved to DDR3** (`783c6c7`) | The draw stops racing the raster. Also corrected sprite lag 1 -> 2 frames, matching MAME for this game. | **better** — the player reported level 1 "cleared up" after the video fixes |
| 2 | **Line-buffer ring 4 -> 8** | Late lines 6,190 -> 974 on the same attract sequence. 86 % of them gone. | not assessed — a counter improvement, never judged on screen. The ring is now back to **2** anyway (see above). |
| 3 | **Four writes a cycle into a single-write-port RAM** (`17c5bfa`) | **THE root cause of the sprite splits.** Quartus silently kept one write lane; Verilator performed all four. Fixed with a 64-bit `rf_bram`, one write per DDR beat. Verified by an HPS fill-probe. | **fixed** — the splits are gone; confirmed by fill-probe and by live battleships matching MAME |
| 4 | **`NREC` 10,240 -> 12,288** | Fixed 646 sprite rows dropped at the zone 2 boss. Real, but **changed nothing visible**. | **no change** — stated explicitly at the time |
| 5 | **Pen mask was one bit too narrow** | Latent bug, fixed. | **no change** either way — bisected 2026-09-07 (build `07190811`), innocent |
| 6 | **Tile-row cache** (`rf_spr_gfx_bus`) | 3 % on the worst line, no change to the late-line rate. Kept because the player reported the picture worse without it -- a direct observation beating a metric. | **worse without it** (earlier), **no change** to the target glitch (bisected 2026-09-07) — innocent |
| 7 | **Lookahead skip** | Longest sprite line 14,676 -> ~9,500-11,300 clocks. | **worse without it** (tears return) and **no change** to the target glitch — bisected 2026-09-07, innocent and necessary |
| 8 | **Rotation write FIFO** (`rf_ddr_arb`, 2026-09-07) | Fixes a genuine Avalon `waitrequest` violation in `screen_rotate` (see below). **Latent, not this bug** -- but correct, cheap (~106 ALMs, 2 M10K) and kept. | **no change** expected and none seen — the violation never fires here |
| 31 | **`NREC` 12,288 -> 8,192** (`rf_video_spr.sv`, 2026-09-08, build `07213908`) | **THE FIX.** Quartus built the record store as 16,384 words for a 24,576-word declaration; 2 x 8,192 matches the RAM exactly so no record can alias (map log: `rec_rtl_0 NUMWORDS 16384, WIDTHAD 14`). `FOLDSEQ` constant on both parities, `rf_flicker` one state. Cost: row drops above 8,192 records (the boss, ~2,600/frame). | **"fixed almost all of it"** -- the first build to change the picture |

### Attempts the board rejected

| # | Change | Why it failed | PLAYER |
|---|---|---|---|
| 9 | **One SDRAM channel per fetch bus** (`ch4` + `ch7`, build `29224005`) | Bench doubled the headroom; the board moved the longest line only 8 % (16,063 -> 14,809) and late lines kept climbing. Cause: `ch7` sat *below* `ch4` in fixed priority while the draw consumes the two buses in strict alternation, so the slower bus gated the pair. The bench had modelled both channels with the *same* latency -- an assumption written into the bench, never measured. | not assessed — rejected on counters before it reached a screen |
| 10 | **Transparent-quad skip** | A strict subset of the lookahead skip. **Removed.** Do not credit it. | not assessed |
| 11 | **`NREC` 13,312** | Does not fit: `Error 11802`, memory placement. ALM headroom is irrelevant -- the 12,288 build that followed had 2,567 ALMs spare. | n/a — never built |
| 12 | **Rotation-drops-writes theory** (2026-09-07) | The Avalon violation is real and provable in `sys/arcade_video.v`, and simulation shows it losing 5-70 % of pixels when the port is busy. **But `waitrequest` never actually fires on this hardware** -- 0 stalls across 210 gameplay samples. Protocol-correct, never exercised. The load-scaling argument was also wrong: `rf_video_spr.sv:1082` issues `fb_req` for *every drawn line*, so framebuffer traffic is constant per frame regardless of sprite density. | **no change** — ruled out by counters, 0 stalls in 210 gameplay samples |

### Not yet tried — the obvious next move

| # | Change | Why |
|---|---|---|
| 25 | **Find the BASE bug** | Every uncommitted change is now cleared (rows 22-23). Whatever is wrong is in the committed code and has survived every instrument. The sequence rows (26-28) are the next measurement. |

### The bisect (2026-09-07, in progress)

The player's report that the committed build has **fewer streaks but not none**
splits the problem: a base bug in committed code, plus amplifiers in the
uncommitted work. `LK_SKIP` in `rf_video_spr.sv` degenerates the lookahead skip
to the committed behaviour so each amplifier can be tested without reverting
the others.

| # | Build | Change | Measured result | PLAYER |
|---|---|---|---|---|
| 22 | `07154217` | **Lookahead skip OFF** (`LK_SKIP = 1'b0`) | Worst sprite line 9,951 -> 15,615 clocks in play (+56 %), still 0 late. | **target glitches UNCHANGED; other screen tears CAME BACK.** The skip is innocent and earns its place. Back ON. |
| 23 | `07190811` | **Tile-row cache OFF + pen mask back to 5 bits** (`CACHE_EN = 0`, `PENMASK6 = 0`), skip on | Timing met, HDMI +0.198. `rf_flicker`: 2 states, bands y 25-69 and 155-198, 11,762 px — identical structure to every other build. | **target glitches UNCHANGED; tears gone** (the skip is back). Cache and pen mask are innocent. |

**Bisect verdict: all three uncommitted functional changes are cleared as the
cause.** The base bug is in the committed code alone. "Fewer streaks on GitHub"
is therefore either perception, or `NREC` 10,240 dropping records at the boss
(fewer sprites drawn = fewer sprites to corrupt), not a mechanism.

### Queued for the next build: the SEQUENCE instruments (2026-09-07)

Every sprite counter on the page is **peak-held**, and a peak-hold cannot see an
alternation -- 6,500 records one frame and 3,000 the next leave the same 6,500
behind. The board's corruption is exactly an alternation, so these report the
last FOUR frames as a sequence, newest first, and they work **while the game is
playing**: no pause, no static scene needed.

| # | Row | Value | What it answers |
|---|---|---|---|
| 26 | `RECSEQ N:N-1` / `RECSEQ N-2:N-3` | records built, last 4 frames | Healthy: four similar numbers drifting with the action. The bug: **X Y X Y**. |
| 27 | `NSPRSEQ N:N-1` / `NSPRSEQ N-2:N-3` | sprites the walk found, last 4 frames | Splits the prepass: NSPRSEQ steady + RECSEQ alternating = the walk is fine and the expand/fill falls short. |
| 28 | `PREPASS OVR:END` | {frames where the prepass was still busy at `frame_start`, clocks from `frame_start` to prepass idle / 16} | **The direct test of the leading theory.** OVR must be 0. END near `DD00` (a whole frame) is a near miss. |

**RESULT (build `07194816`, paused on a glitch, 64 samples):**

```
RECSEQ    11EB 11EB 11EB 11EB     4,587 records, identical, four frames running
NSPRSEQ   0150 0150 0150 0150       336 sprites, identical, four frames running
PREPASS   0000 0AA2                 0 overruns; finishes 5 % into the frame
```

while `rf_flicker` on the same screen: 2 states, 8,138 px, bands y 16-51 and
161-210. **The prepass builds the identical list every frame and the picture
still alternates.** Walk, expand and fill are all cleared; the prepass-overrun
theory is dead by its direct test. (In attract `NSPRSEQ` alternated 501/386 --
that is the GAME's own sprite flicker, not the core.) PLAYER: glitch "slightly
better" on this build -- no functional change, so perception or scene.

So the fault is downstream of the record store: the **draw** or the **mixer**.
Rows 17-20 are re-borrowed for the pair that splits them:

| # | Row | Value | What it answers |
|---|---|---|---|
| 29 | `FOLDSEQ` (2 rows) | `rf_spr_fb.wr_fold` -- sum of every sprite pixel the draw handed to DDR3 -- last 4 frames | **X Y X Y = the draw's output alternates from identical input.** Constant = the draw is deterministic. |
| 30 | `USEDSEQ` (2 rows) | rotate-xor hash of every `used_line[par][*]` the draw published -- last 4 frames | **X Y X Y with FOLDSEQ constant = identical sprite pixels composed differently by the mixer.** The per-line priority flags are double banked by parity, and the bench already reports a used-flag diff on frame 4200. |

**RESULT (build `07203817`, paused on a glitch, 63 samples). Read with the
page's phase in mind: the 28-row page renders one row per frame, so row 17
always samples the same frame parity and row 18 the other.**

```
FOLDSEQ   parity X:  3DEB 3DEB 3DEB 3DEB ...     constant, every sample
          parity Y:  5DB8 / 6EEB / 3BE2 / 3898   VARIES -- four distinct values
USEDSEQ   parity X:  3CAC    parity Y:  D5B5     constant on each side
```

`rf_flicker` on the same screen: **three** states this time (A x6, B x3, C x1),
bands y 13-37 and y 128-220, A-vs-B 10,945 px.

**Verdict: THE DRAW.** On one frame parity its output is identical every frame;
on the other it is wrong AND DIFFERENT EACH TIME. The record store is proved
identical frame to frame (RECSEQ/NSPRSEQ), so varying output from constant
input means the draw is not reading its input reliably on that parity. USEDSEQ
alternating is a consequence (different sprites drawn -> different priority
groups present), not independent evidence for the mixer.

What is parity-dependent in the draw: `rb`, the bank of `rec[rb][fc]` and
`sl_d[rb][sidx_r]` it reads -- both MLAB, both async read, both
`no_rw_check`, and both written by the prepass in the OTHER bank during the
same frame. One bank reads back correctly; the other reads back varying
garbage. That is the shape of a hardware read hazard, not a logic bug -- and
it is exactly the class of fault (a memory behaving differently on silicon
than in Verilator) that produced the sprite splits.

**Refinement, same capture:** the two bad states B and C differ from each
other by only **31 pixels** (rows 24-25). The bad parity is therefore a
STABLE wrong rendering with a tiny jitter -- a deterministic read of the wrong
data, not metastability. And only 17 % of its wrong pixels look like terrain
showing through: the bad parity mostly draws DIFFERENT SPRITE CONTENT, from a
record store proven to hold the same count. Same count, different content =
the draw is reading a different list on that parity.

**Reinterpretation after viewing the states (`ABC_lower.png`):** the flicker
tool labels by count, and here the MAJORITY state A is the CORRUPTED one; B and
C are the clean renders. That flips which fold value belongs to which:

- **bad parity: fold `3DEB`, constant across 63 samples**
- **good parity: fold VARIES** (`5DB8`/`6EEB`/`3BE2`/`3898`) -- because the
  good render tracks the game's slight animation on the continue screen

**The bad parity draws the same thing every frame even as the game moves.** It
is not misreading a live list; it is reading a list that never changes. That is
a **stale bank**: `RECSEQ` is a counter in the prepass, not a read-back of the
store, so "4,587 records every frame" says the prepass RAN, not that its writes
LANDED. If writes to one bank of `rec[wb]` / `sl_d[wb]` do not take on silicon,
that bank holds whatever it held before, and every other frame is drawn from
it. Same class as the sprite-split root cause (`17c5bfa`): a memory write that
Quartus implements differently than Verilator, which is why every bench passes.

**Next build (31): bank vs parity.** Two one-line changes: (a) the PREPASS row's
top byte now carries {rb, par} at the sampled phase, so the bad half can be
named by bank; (b) the prepass reset parity is SWAPPED (wb=1, rb=0). If the
bad half moves to the other frame parity, it follows the record BANK
(`rec[rb]` / `sl_d[rb]`) and the fault is in one bank of those MLABs. If it
stays, it follows `par` (`used_line`, the framebuffer bank).

They take rows 17-20 (the PLAYFIELD / SPRITE / LINE RAM / TEXT AND CHAR write-count
liveness rows, bring-up checks the working pipe already implies) and row 25
(SPRTEAR, which did its job). The bisect switches are restored to the
working-tree configuration (`LK_SKIP=1`, `PENMASK6=1`, `CACHE_EN=1`) so the
instruments characterise the core as it normally runs. Bench: 71680/71680.

### Instruments built (measurement, not fixes)

| # | Instrument | What it said | PLAYER |
|---|---|---|---|
| 13 | Per-line CRC in the framebuffer | Lines verify their own content round trip. |
| 14 | `miss` / `hit_seen` phantom-count fix (build F) | Removed exactly one spurious miss per frame (28 per page pass). The row is now honest; the zero it reads is a **counter fix, not a fit**. |
| 15 | Stale-line detector (`STALELN:AGE:CNT`) | 0, always -- including with corruption frozen on screen. |
| 16 | Fetch self-check (`fetch_bad`) | 00, always. **Caveat:** it compares a re-fetch against the *cached* copy for the same key, so it validates data consistency, not that the key was right. |
| 17 | Fold pair (`SPRFOLD WR:RD`, 2026-09-07) | `wr == rd` always. Built weeks ago and **never routed to a page row**, which is why the question it answers stayed open. |
| 18 | Rotation stall/peak/lost (`ROTSTL:PK:LOST`, 2026-09-07) | 0 / 1 / 0. Ruled the shared port out. |
| 19 | Sprite-RAM tear counter (`SPRTEAR WR:FRM`, 2026-09-07) | `01C20001` constant: 450 writes during the walk in **one** frame (boot), never again. Theory dead. |
| 20 | Zone injector | Test tooling: coin + start opens at zone 2 on demand. Confirmed on hardware. |
| 21 | Frame-to-frame stability check in `pipe_tb` (2026-09-07) | The bench compared only the **last** of four rendered frames, so an alternation between a good and a garbage frame was invisible by construction. Now it compares consecutive frames. Found **no instability** across six dumps including boss content -- so the alternation is board-only. |

---

## Dead ends: do not spend a second cycle on these

- Poking the zone word once a frame cannot change the stage; the loader
  consumes it the same frame. Proved: 0.0 % pixel difference.
- "Sprite fetches starve the playfield builder" was a misreading of `pipetb`
  `argv[5]`, which is the PLAYFIELD latency. Sprite latency is `F3_SPS_LAT`.
- "The tile-row cache fixes the Darius tower colours" has no control: 164
  samples across three capture runs never reached the Zone A demo.
- HDMI PLL misses of -0.1 to -0.5 ns are fitter variance, not a real path.
  Seed 8 has closed that clock twice; seed 11 did not.
- Deeper line-buffer rings. A ring of 8 already banks 27,648 clocks against a
  worst line of ~15,000. Depth is not the constraint.

---

## Open

### 0. ROOT CAUSE: the record store is a third smaller on silicon than in RTL

**Found 2026-09-08 from the map report of the bank-vs-parity build**, while
the board was still compiling it:

```
rec_rtl_0:   WIDTH 18,  WIDTHAD 14,  NUMWORDS 16384
sl_d_rtl_0:  WIDTH 51,  WIDTHAD 11,  NUMWORDS  2048    <- correct (2 x 1024)
```

`rec` is `[0:1][0:NREC-1]`, `NREC = 12288`: 24,576 words, 15 address bits.
`RW = 14` is hardcoded and `f_rd`/`fc` are 14 bits, and Quartus built
`wb * NREC + f_rd` **truncated to 14 bits** -- silently, with no warning.
Bank 0 = words 0..12287. Bank 1 should be 12288..24575; the top third does not
exist, so bank 1's records 4096..12287 land on words 0..8191 = **bank 0's
records 0..8191**. Every prepass that builds more than 4,096 records clobbers
the other bank's head with its own tail.

**The threshold is a record COUNT, and it explains every observation:**

| scene | records | NREC 12288 (threshold 4,096) | NREC 10240 / GitHub (threshold 6,144) |
|---|---|---|---|
| attract | ~3,000-4,000 | clean | clean |
| continue screen | 4,587 | **slightly corrupt** (what was captured) | clean |
| zone 2 boss | 10,836 | **severe** | corrupt |

- "only when busy": more records, past the threshold
- "GitHub has fewer streaks but not none": threshold 6,144 there -- the continue
  screen is clean, the boss is not. **The player was right and I dismissed it.**
- "got worse when the core expanded": raising `NREC` to stop the boss drops
  LOWERED the threshold from 6,144 to 4,096
- one parity stale, one live: the clobbering is asymmetric by construction
- `RECSEQ` constant: it is a counter in the prepass, not a read-back
- every bench 71680/71680: Verilator models all 24,576 words; no bench frame
  exceeds 2,190 records anyway

**Why "make it bigger" is not the fix:** 24,576 real words is +256 MLABs, and an
MLAB is a LAB, on a device at 4,185/4,191. **The truncation is why it fit.**

**The fix: `NREC = 8192`.** 2 x 8192 = 16,384 = 2^RW = exactly the RAM Quartus
builds, so no address can alias. Cost: graceful row DROPS on the very heaviest
boss frames (`rec_drop` counts them) -- what this core had before `NREC` was
raised, and rows dropped is a far better failure than rows aliased.

**Verification:** on a paused screen `FOLDSEQ` must read constant on BOTH
parities, `rf_flicker` must find ONE state, and the player must see it gone.

**Build `07213908` (the fix) is DEPLOYED, 2026-09-08.** Synthesis confirmed
`rec_rtl_0: WIDTHAD 14, NUMWORDS 16384` -- the same physical RAM as every
earlier build, now matching the declaration exactly. Timing: core clocks met,
HDMI -0.023 ns (fitter-variance band). 40,809 ALMs (97 %), 4,179/4,191 LABs,
549/553 M10K. At attract: `BUILD 07213908`, zero FAIL rows, records 4,462,
longest line 10,015, 0 late, 0 dropped. **Paused-screen verification and the
player's verdict pending.**

**VERIFIED 2026-09-08.** Instruments, paused at the zone 2 boss (63 samples):

```
FOLDSEQ      E696 E696 E696 E696   constant on BOTH parities   (was 3DEB / varying)
rf_flicker   ONE state, 9 frames                                (was always 2 or 3)
SPR REC      2A1E FFFF             10,782 records, drops SATURATED
```

**PLAYER: "yes that fixed almost all of it."** The first build in this
investigation to change the picture. The "almost" is the predicted residue:
at the boss, ~2,600 rows a frame above NREC 8,192 are DROPPED -- sprite rows
missing on the single heaviest scene, counted by `SPR REC : DROP`. A graceful
loss, not the aliasing. Making records more compact is the follow-up.

(`USEDSEQ` read `00000000` on this build where it read `3CAC`/`D5B5` before --
a diagnostic anomaly worth a look, not a picture problem.)

**The lesson, for the second time in this project** (the first was the
four-writes-a-cycle line buffer): after any memory change, read the RAM
inference lines in the map log -- `NUMWORDS`, `WIDTHAD` -- before trusting a
passing bench. Verilator simulates the RTL you wrote; Quartus builds something
else and does not always say so.

### 1. UNCOMMITTED RTL: three functional changes that are NOT on GitHub  (cleared by bisect)

**`origin/master` is `b5c77eb`, the same commit as local HEAD — but the working
tree carries ~1,621 uncommitted lines of RTL on top of it.** Every build in this
investigation came from the working tree. The core on GitHub is therefore a
genuinely different machine, and the player reports it has "less errors but
other issues".

Confirmed absent from `origin/master` (`git show origin/master:rtl/... | grep`
returns 0 for the first two):

| Change | Type | Could it produce the streaks? |
|---|---|---|
| **Lookahead skip** (`la[0..4]`, `dxk`, `sx1..sx4`) in `rf_video_spr.sv` | functional | **Strongly.** It manipulates `dr_dx8`, the x-position accumulator. A mis-computed skip lands pixels at the wrong x **along the scanline** — which is exactly the horizontal smearing in frame B. |
| **Pen mask widened 5 -> 6 bits** (`penmask_r`, `o_penmask`, `wk_penmask`) | functional | **Yes.** It changes which pen values are opaque. Too wide and sprites draw pixels that should be transparent — and frame B has *added* content, not missing content. |
| **Tile-row cache** (`rf_spr_gfx_bus`) | functional | Possible. A wrong cache hit returns another tile's pixels. `fetch_bad` validates data consistency **for a given key — not that the key was right**, which is a real gap in that instrument. |
| `NREC` 10,240 -> 12,288 | sizing | Unlikely to corrupt; it only stopped drops. |
| fold / stale / tear / rotation instruments | measurement | No. |

**Why the lookahead skip was built** (`rf_video_spr.sv:425`, and this rationale
exists nowhere on GitHub):

> The fix is not a wider write port — which would need a multi-write line
> buffer, **the exact inference trap that produced the sprite splits**, and
> would only align at 1:1 zoom anyway. It is to **STOP VISITING pixels that
> cannot write**.

Each clock it looks four source positions ahead and jumps to the first that
writes. A position is skippable when the pen is transparent, the destination is
off-screen, or zoom already mapped a later source pixel onto the same
destination. Measured: longest sprite line **14,676 -> ~9,500-11,300 clocks**.

It was built to attack the throughput theory — the draw needing ~4 px/clock
against a 3,456-clock budget. **That theory is the one now contradicted**, so
the optimisation was careful, well-reasoned, and aimed at something that is not
the problem. It may still be innocent. But note the claim it rests on: *"still
exactly one write per clock and the same set of written pixels"*. If that is
ever untrue for some zoom or flip case, pixels land at the wrong x along a
scanline — which is exactly what the streaks are.

This fits the player's own account exactly: *"it was fixed when the entire
screen was put into a memory buffer, then when we expanded the core over more
ALMs it went back to worse."* The DDR3 framebuffer is **committed**. The
lookahead skip, pen mask widening and cache are precisely "expanding the core",
and they are precisely what is **uncommitted**.

It also explains why every bench passes: they compare against a model that was
itself used to justify these changes.

**Next step, and it is cheap:** build `origin/master` and A/B it against the
working tree on the board. If the streaks are absent on the committed build,
the search narrows from a whole pipeline to three named changes, bisectable in
two builds.

### 1b. Sprite RAM read while the CPU can write it — RULED OUT

Kept for the record because the reasoning was sound and the answer was still no.

`rf_video_spr.sv:751` starts the list walk at `frame_start` and streams sprite
RAM through the B port of the CPU's sprite BRAM with **no snapshot and no
interlock**, while the CPU writes port A. MAME reads sprite RAM atomically and
the bench feeds a static snapshot, so neither could ever produce a torn list —
a textbook "invisible to every bench, plain on the board" candidate.

**The board said no.** `SPRTEAR WR:FRM` = `01C20001`, unchanged across 126
samples: 450 writes during the walk in exactly **one** frame, then never. That
one frame is the CPU initialising sprite RAM at core load. In steady state the
two never overlap.

Worth keeping in mind anyway: the structure is genuinely unprotected, so if the
game's write phase ever shifts this becomes live. A full 64 KB snapshot is not
affordable — sprite RAM is `rf_bram_tdp #(.AW(15))`, 512 Kbit, ~52 M10K against
**4 spare** (549/553). The cheap routes, if it ever matters, are (a) change when
the walk starts, (b) re-walk on a detected tear, (c) snapshot into DDR3.

### 2. The used-flag divergences

`make spr-line-all` reports **frame 4200: 0 pixel diffs, 1 used-flag diff**.
`ear-spr-line-all` frame 4200 reports 8. Pre-existing, reproducible, and
unexplained. The per-line priority-group flags are double banked ("written for
the frame being drawn, read for the frame being shown") -- the same double
banking the A/B alternation implicates. Small, but the only *reproducible in
simulation* anomaly in the sprite path.

### 3. Why the two states, and why deterministic

Unresolved regardless of the above. The draw's state is double banked in
several places (`rec` via `dbank`, `sl_d`, the per-line priority-group flags,
the framebuffer via `par`). Something is systematically different between two
banks. Nothing yet explains *what*.

### 4. Darius Gaiden sprite colours

A separate bug with its own trail (HANDOFF.md, 2026-09-01/02). The palette is
exonerated; the sprite graphics fetch is the remaining suspect. **Do not
conflate it with this one.**

---

## The state of the documentation itself

**The last commit is `b5c77eb`, 2026-08-31.** Everything from 2026-09-01 to
09-07 — nine days of investigation — is uncommitted and exists only on this
machine:

| Document | On GitHub | Working tree |
|---|---|---|
| `SPRITE-CORRUPTION.md` (this file) | **absent** | new |
| `RESOURCES.md` | **absent** | new |
| `F3-LIBRARY.md` | **absent** | new |
| `README.md` | 629 lines | 701 lines |
| `HANDOFF.md` | 1,947 lines | 2,751 lines |

What GitHub *does* carry is README "Known problems" item 1 in its older form:
the ring-of-4 -> ring-of-8 story and the late-line counts. It stops before the
pixel-bound analysis, and long before the 2026-09-07 finding that the
corruption appears at near-zero load. **Anyone reading GitHub today gets a
description of the symptom attached to a theory that has since been
contradicted twice**, and no record at all of why the lookahead skip, the pen
mask widening or the tile-row cache exist.

That is worth fixing on its own terms: the repository currently misrepresents
the state of the core, and nine days of measurement live in one place.

## The rule this file exists to enforce

Every theory in the "rejected" table above was argued confidently from code
before the board disagreed with it -- twice on 2026-09-07 alone. The pattern is
always the same: a mechanism that is real in the source, reasoned into a cause,
and then contradicted by a measurement that took twenty minutes to take.

**Take the measurement first.** State what result would kill the theory, before
building anything.
