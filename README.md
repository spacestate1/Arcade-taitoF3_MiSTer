# Taito F3 System for MiSTer

**The arcade board, not a port of one game.** An FPGA recreation of the Taito
F3 System (1992-1998) for MiSTer. One bitstream runs the whole library; adding
a game is an MRA and a config byte, not a new core.

Verified against MAME, which stands in for the datasheets Taito never
published: 15 consecutive frames pixel-identical, 1.15 million ES5505 samples
with zero differences.

**Plays now:** Ray Force (*Gunlock*, *Layer Section*) in all three regions,
Elevator Action Returns, Bubble Bobble II. Bubble Memories and Puzzle Bobble 2
in progress.

Goes one step past the reference on sound: MAME stops at the MB87078 volume
chip, the real cabinet then drives an LM324 and a power amp, and this core
puts that missing 25 to 30 dB back.

## Status

| Game | State | Where it stands |
|---|---|---|
| **Ray Force** (US) | **~90 %** | Plays with sound. Every self-test row passes on hardware; video pixel-identical to MAME, audio sample-exact. Held back from "done" by the sprite overrun in busy scenes (Known problems #1), the ES5510 stub, and the fact that nobody has played it start to finish. |
| **Gunlock** (World) | **~85 %** | Same board and the same ROMs bar one program chip, so everything above should apply — but the MRA has never been loaded on a board. Untested, not unlikely. |
| **Ray Force** (Japan) | **~85 %** | As Gunlock. |
| *Elevator Action Returns* | **~80 %** | **Runs** — boots, plays, sprites and playfields draw, sound CPU streaming, one vblank ack per frame. All ten sampled frames match MAME pixel for pixel across the full 232-line visarea, five of them dumped after the fixes as an out-of-sample check. Still in `releases/experimental/`: the pivot layer is a mirror, ten frames of attract and character select are not a playthrough, and its sound has never been correlated. |
| *Bubble Bobble II* | **~65 %** | **Runs on hardware** (2026-08-31) with no RTL change at all — an MRA and a config byte, which is what the universal F3 map was built for. Title, character select, cutscenes and play all draw correctly. Not frame-verified: the reference model itself is only exact on 3 of 10 dumped frames for this game, so there is nothing trustworthy to check the RTL against yet. |
| *Bubble Memories* | **~40 %** | **MRA written and assembles** to the same 18.5 MB stream, all ten self-test expectations measured — but it has never been loaded on a board. Its sprites carry no `sprites_hi` ROM (4bpp where every other set is 6bpp), and the reference model renders three of its frames pixel-identical, so that path at least looks right. |
| *Puzzle Bobble 2* | **~60 %** | **Renders correctly on hardware** (2026-09-01). The truncated playfield is gone: `extend=0` went live once compiling the framework's Y/C encoder and ascal's adaptive filter out paid for the LABs, and the before/after on the same attract screen is in `screenshots/pb2/`. Not frame-verified, and never played. |
| *Darius Gaiden* | **~45 %** | **Boots and renders** (2026-09-01) — title, intro and attract-demo gameplay all correct, on an MRA and a config byte with no RTL change. The ROM path is proven: the byte count, checksum and SDRAM BIST the board reports are exactly the three numbers `rf_stream_sum.py` predicts from the MRA. **But it uses the pixel layer** — 98,304 non-zero writes across all eight 8 KB pages, where Ray Force only ever clears it — and this core mirrors 8 KB of that 64 KB window, so that layer cannot be right yet. Sound uncorrelated, never played, not frame-verified. |

Percentages are judgement, not arithmetic; the rows either side of them are
the evidence.


**The game boots, plays at full speed, and has sound.** On a DE10-Nano every
row of the core's built-in self test passes, and the picture and the audio
have both been checked against MAME rather than by eye:

- **Video: 15 consecutive frames pixel-identical to MAME**, end to end
  (playfields, line-RAM raster effects, the text/pivot layer, sprites with
  zoom, and the priority mixer), plus 30 frames / 4.0 M pixels on the
  playfield builder and 7,680 lines through the line-RAM decoder.
- **Sound: the ES5505 sampler is sample-exact against a bit-accurate model of
  MAME over 1,150,000 samples**, and the sound 68000 runs the real driver —
  its first 1,387 chip writes from reset are identical to MAME's.
- **On hardware**: the core's own audio capture (see *Audio Ring* below)
  **correlates 1.000 with MAME's mix** at the same instant of the same track.

The released build (`releases/Rayforce_20260831.rbf`, build stamp
**31153138**, tagged `v1.2`) runs on a DE10-Nano with timing met on every
clock. Every self-test row passes except `SPRLINE : LATE`, which is a counter
question rather than a picture one (Known problems). Verify what you
downloaded with `python3 tools/check_files.py`.

**The bitstream and the MRAs must come from the same release.** The SDRAM
region layout changed when the core became a general F3 core, so an older
bitstream with these MRAs (or the reverse) fails the `ROM BYTES` self-test
row and shows wrong graphics.

## What the core covers

| Part of the arcade board | State |
|---|---|
| 68020 main CPU (TG68K.C in 020 mode) | Working — the full `f3_map` memory map |
| Video: 4 playfields + line-RAM effects | Working, pixel-identical to MAME |
| Video: sprites (list walker, zoom, priority) | Working, pixel-identical to MAME |
| Video: text layer | Working |
| Video: pivot / pixel layer | **Stubbed** — Ray Force only ever clears it (checked every run by a self-test row) |
| Sound: 68000 + MB8421 dual-port RAM | Working — runs the real driver |
| Sound: ES5505 "OTIS" sampler, 32 voices | Working, sample-exact vs the model |
| Sound: ES5510 "ESP" DSP | **Host port only** — the presence check passes, the DSP itself is a dry pass-through |
| Sound: MB87078 volume chip | Working — the game's own fades and level |
| 93C46 settings EEPROM + NVRAM save | Working (see *Saving settings*) |
| SDRAM, ROM loading | Working — 12 MB, verified by an on-core checksum every load |

> **If you are running v1.1:** it boots into the diagnostic page instead of
> the game. MiSTer's status word powers up at 0 and the OSD's `Self Test`
> option had `On` as its first entry, so a fresh load got the self test.
> Turn **Self Test** to `Off` in the OSD, or use a build after this note --
> the default is fixed and a released core now boots to the game.
>
> **And a saved config can no longer do it either.** Fixing the OSD default
> was necessary and not sufficient: MiSTer replays the saved status word from
> `config/Rayforce.CFG` over the top of those defaults, so a card that had
> ever switched `Self Test` on handed the bit straight back to every
> bitstream loaded after it -- a brand-new build booting to the diagnostic
> page with nothing whatever wrong with it. `Self Test` and `Service Mode`
> are now *armed* rather than merely selected: whatever the bits say at the
> moment the game starts is treated as inherited and ignored, and only a
> change you make from the OSD afterwards turns either on. If the OSD reads
> `On` while you are looking at the game, that is this -- toggle it `Off`,
> then `On`.

## Resources

The FPGA is full — 95–98 % ALMs on every recent build, and four fits have
failed outright. **[RESOURCES.md](RESOURCES.md)** documents the budget: which
stores consume MLABs and why, what each lever is worth in measured numbers,
the two different "can't fit" errors and what they mean, why the LAB
percentage reads 100 % even in builds that fit comfortably, and the build
memory caps. Read it before adding anything to the RTL.

## Known problems

0. **High scores save but do not restore.** The table is captured correctly
   into the upper half of `config/nvram/<mra>.nvm` on an OSD-triggered save,
   and the file round-trips; injecting it back into the game's RAM on boot
   does not work, so scores reset each power cycle. A `.nvm` with all four
   guard bytes correct and a planted top score is ignored, and since
   `save_ready` rises the RAM guard walk demonstrably completes, so the
   failure is downstream of it. Diagnosing it needs `sh_ok` and `injected`
   exposed on a self-test row; two builds have been spent on hypotheses
   instead, which is the wrong way round.

1. **Sprites can be missing or partial in busy scenes — boss transitions,
   heavy attract moments.** This is the most visible defect in the core and
   it is measured, not suspected.

   > **See [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md)** for the full register
   > of what has been tried, what is ruled out and by what evidence, and what
   > is still open. That file is the scoreboard; this section is the summary,
   > and parts of it are now known to be wrong — see the correction at the end.
 The sprite engine draws each screen line
   into a ring of line buffers running ahead of the mixer; when a line's draw
   misses its deadline the mixer composes that line anyway, with whatever
   sprites had arrived. The core counts both, and leaving it in attract for a
   couple of minutes shows:

   ```
   before (ring of 4)  SPRLINE : LATE  3EFA182E   6190 late lines
   after  (ring of 8)  SPRLINE : LATE  3D7703CE    974 late lines
                       (longest line ~15700 clocks; the budget is 3456)
   ```

   **Mostly fixed, not entirely.** Deepening the run-ahead ring from 4 line
   buffers to 8 removed 86 % of it, measured on the same attract sequence
   second by second: the burst that used to add 4,770 late lines at t=56 s is
   now zero, and the total falls from 6,190 to 974.

   What is left is not a buffering problem and no ring depth will fix it. A
   ring of 8 banks 7 spare lines plus the line's own budget -- 27,648 clocks,
   comfortably more than the 15,722 the worst single line needs -- so any one
   heavy line is now covered.

   **The residual was caught in the act on 2026-08-29, and it is a latency
   defect, not the fetch-bandwidth ceiling this section used to guess at.** A
   screenshot from the board and MAME's own frame 2930 are the same instant of
   attract, and they differ in **1,124 pixels, every one of them on rows
   210-223** -- the last 14 lines of the frame. Rows 0-209 are pixel-identical.
   A rendering bug does not stop at row 210, and the same frame renders
   71,680/71,680 exact in the bench: the sprite draw ran out of time partway
   down the frame and the run-ahead never recovered before the frame ended.

   The cause is serialisation. The sprite engine runs two fetch buses taking
   alternate records, each record needs two graphics planes, and all four went
   through one `rf_spr_ch_share` onto SDRAM `ch4` -- where a sharer holds
   exactly **one** burst outstanding. So four bursts were served strictly one
   after another with nothing overlapped, and a line's draw time was
   (bursts x round trip).

   **A fix was attempted and the board rejected it.** One SDRAM channel per
   fetch bus -- bus A on `ch4`, bus B on a new `ch7` -- so the two records in
   flight could overlap instead of queueing. In the bench it doubled the
   headroom (frame 2930 stays exact to a 135-clock sprite round trip instead
   of 70). On hardware (build `29224005`, 2026-08-30) it moved the longest
   sprite line only 8 %, 16,063 -> 14,809 clocks, and late lines kept
   climbing.

   **Why, and it is worth remembering:** `ch7` was placed *below* `ch4` in
   the controller's fixed-priority scan, but the sprite draw consumes the two
   buses in strict alternation, so the slower bus gates the pair. One
   fairly-shared channel (a sharer round-robins its four ports) had become an
   unfair pair. The bench missed it because it modelled both channels with
   the *same* latency -- an assumption written into the bench, not measured
   from the board. With the asymmetry modelled (`F3_SPS_LAT_B`), 90/180 --
   the same 135 mean that renders exact when symmetric -- breaks the frame.

   The arbiter now alternates between the two sprite channels. That is in the
   tree and **has not been on a board**; until it has, the reading above
   stands and this problem is open. The full trail is in HANDOFF.md.

   Note what is NOT wrong: `SPR REC : DROP` stays at zero, so the sprite list
   and the record store are keeping up — every sprite row the frame asked for
   was built. It is the per-line **fetch and draw** that misses its deadline,
   which points at SDRAM contention rather than at capacity.

   You will see this as sprites flickering or vanishing for a frame where a
   lot is on screen at once. It has been present in every build so far
   (including the first release), and it went unnoticed because those
   counters only arrived recently and every earlier reading was taken
   seconds after a core load, when they are still zero.

   The bench used to miss it too, for two reasons now fixed. Its `lat`
   argument slows *every* SDRAM channel, so it broke the frame everywhere
   instead of at the bottom where the board breaks it; `F3_SPS_LAT` slows the
   sprite channel alone, which is the asymmetry the real controller has.
   And the `SPRLINE : LATE` counter is peak-held from the 16th frame on, so a
   3-frame bench run reads zero no matter what is happening -- `F3_FRAMES=20`
   or more is required before that number means anything.

   **Measured to its cause, 2026-09-03: the heavy lines are PIXEL-bound.**
   On hardware, Ray Force's worst sprite line carries **784 sprite rows** --
   784 x 16 = 12,544 pixels -- and takes **14,236 clocks**, i.e. **1.135
   clocks per pixel**. The draw emits exactly one pixel per clock
   (`rf_video_spr.sv`, `dr_xx`), sixteen a row, whether or not the pixel
   draws anything. Fitting the 3,456-clock budget needs 0.276 clocks/pixel,
   about **four pixels per clock**. No fetch improvement can reach that, and
   two were tried:

   ```
                             worst line   late lines/pass
   baseline                     14,676         28
   + sprite tile-row cache      14,236         28
   + transparent-quad skip      13,781         28
   ```

   6 % off the worst line and **the late-line rate did not move at all** --
   28 per page pass on both, across 63 and 83 consecutive samples. The cache
   is still worth having (in simulation it halves a *fetch-bound* line at
   board-like latency) but it is not what breaks a boss line, and neither is
   ring depth. **The fix is a wider draw datapath**, which is real work: the
   line buffer is a 16-bit single-write-port RAM, the DDR3 packer reads it a
   pixel a clock too, a 2-pixel word only aligns at 1:1 zoom, and a
   multi-write line buffer is exactly the inference trap that caused the
   sprite splits. Until then this defect stands.

   Why no bench caught it: the heaviest sprite line in any dumped frame in
   this tree is 114 rows and is fetch-dominated, while the board's failing
   line is 784 rows and is pixel-dominated. **No bench here reproduces the
   regime that fails.**

   **ROOT CAUSE (2026-09-08).** The sprite record store `rec[0:1][0:NREC-1]`
   with `NREC = 12288` is 24,576 words, but Quartus silently built it as a
   **16,384-word RAM** (`rec_rtl_0: WIDTHAD 14`). Bank 1's records from 4,096
   up alias onto bank 0, so any frame with more than 4,096 sprite records
   clobbers the other bank's head -- one frame parity draws a stale list, the
   other is live, and you see two copies of every moving sprite, offset,
   flickering at 30 Hz. The threshold is a record count, which is why it only
   showed in busy scenes, and why raising `NREC` for the boss made it worse.
   Verilator models the full declaration, so every bench passed. The fix is
   `NREC = 8192`: 2 x 8192 is exactly the RAM Quartus builds. **Deployed as
   build `07213908` on 2026-09-08 and verified -- the draw's per-frame fold
   is constant on both parities, the flicker capture finds one state, and the
   player's verdict was "that fixed almost all of it."** What remains is
   dropped sprite rows on the single heaviest scene (the zone 2 boss, ~10,800
   records against 8,192), which `SPR REC : DROP` counts -- a graceful loss,
   not corruption. See [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md).

   **CORRECTION (2026-09-07): the conclusion above is not supported.** The
   corruption was captured on the board and it appears on the CONTINUE screen
   after a death — a near-static scene at almost no load — alternating between
   two fixed states that are byte-identical run to run. A throughput ceiling
   cannot do that. Heavy load makes it more visible, not more likely, so a
   wider draw datapath is not the fix and the pixel-rate measurement, while
   correct, is measuring the wrong thing. Everything ruled in and out since is
   in [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md).

2. **The ES5510 DSP is not emulated**, only its host port. Measured impact:
   the dry sampler mix correlates **0.95–0.99** with MAME's full output across
   the whole soundtrack, so what the DSP adds is at most a faint residual. If
   something sounds thin against MAME, this is why.
3. ~~**Sprites lag the playfields by one frame; MAME uses two.**~~ **Fixed**,
   as a side effect of moving the sprite framebuffer to DDR3. The two stages
   compose: the bucket store is double banked, so the draw reads last frame's
   bank (`rf_video_spr.sv:47`), and the mixer then reads last frame's
   framebuffer (`rf_spr_fb.sv:27`). One plus one is the two MAME uses for
   this game.
4. **NVRAM only saves when you open the OSD.** That is MiSTer's design, not
   the core's — see *Saving settings*.
5. **Untested on hardware**: the *Gunlock* and *Ray Force (Japan)* MRAs, the
   60 Hz refresh option, and the analog stick. All three are built and
   believed correct; none has been exercised on a board.
6. The pivot/pixel layer stub is the one thing that ties this core to Ray
   Force — see [Other F3 games](#other-f3-games).

## What is verified, and what is not

The core is checked against MAME, so it is worth being precise about which
parts of MAME that covers. Measured over **7,680 line-configurations across
30 dumped frames** of Ray Force:

| F3 feature | Ray Force uses it | State here |
|---|---|---|
| Line zoom (per-line X/Y scale) | **Heavily** — 7,485 of 30,720 playfield-lines at a scale other than 1:1 | Verified: the 15 pixel-identical frames include it |
| Blending modes 1 and 2 | **Rarely** — 120 of 30,720 playfield-lines (0.4 %) | Exercised but thinly. The likeliest place for an unnoticed difference |
| Column scroll, per-line priority, palette offset | Constantly | Verified |
| Mosaic | **Never** (`x_sample_enable` false on every line) | Implemented, follows the model, but has no dump coverage |
| Clip planes | **Never** (no plane ever set) | Implemented; MAME's several-inverted-planes case is deliberately not reproduced |
| Pivot / pixel layer | Only cleared, never drawn | Stubbed, and a self-test row counts non-zero writes every run |
| Sprite trails | Never | Not implemented |

### Two Ray Force-specific gaps, from MAME's own notes

Searching MAME's source and issue history for this game rather than for the
board turns up two things that matter here, both confirmed against our dumps:

**1. The palette-add effect is implemented but never verified.** MAME's PR
#10943 ("line ram palette add effect") names **"rayforce stage 5 intro"** as
a place it is used. This core implements it (`pf_pal_add`, the line-RAM
0x9000 section), but **every one of the 30,720 playfield-lines in the dumped
frames has `pal_add = 0`** — the dumps are boot, title and attract, and
stage 5 is deep in a play session. So the code is there, follows the model,
and has never been compared against MAME on a frame that actually uses it.
Dumping a stage 5 intro frame and running `make -C sim mix-all` against it is
the single most valuable verification left for this game.

**2. An unknown palette bit that MAME names Gunlock for.** In the 0x6400
effect field, MAME comments `x8xx = ??? seems to affect the palette of a
single layer(??) (gunlock)` and notes `gunlock:78` — and its code logs
"unknown effect bits set" for anything that is not 0x70, i.e. **for Gunlock's
0x78**. MAME does not emulate it (`palette interpretation [unimplemented]`).
Our dumps only ever show `0x00` (7,650 lines) and the benign `0x70` (30
lines), so the scene that sets 0x78 is not covered here either. This core
latches the field and, like MAME, acts on none of it — so we match MAME, and
both may differ from the real board in whatever scene sets that bit.

Neither is a defect against MAME. Both are places where "pixel-identical to
MAME" is a narrower claim than it sounds.

### What MAME's own tracker says about this game

Checked 2026-08-30. The rows still open are inherited by this core, because
this core is written against MAME:

| MAMETesters | State | What it means here |
|---|---|---|
| [08230](https://mametesters.org/view.php?id=8230) missing transparent shadows in **Area 4** | **open** | The `x8xx` bit above, in play rather than in a corner case. The reporter's analysis: it offsets a palette on playfield 4 only, by +0x10 on 4bpp tiles and +0x40 on 6bpp, and is masked by the layer beneath. **Area 4 will look like MAME and both will differ from a real board.** |
| [07861](https://mametesters.org/view.php?id=7861) sound glitches after the first game over | **open** | Named in MAME's own `es5510.cpp` header. The ES5510 is a stub here, so this is likely reproduced or replaced by silence rather than fixed. |
| [01920](https://mametesters.org/view.php?id=1920) enemy laser too short, stage 3 | fixed in 0.203 | Fixed by a **68020 `CMP2` opcode** correction. This core runs TG68K, not MAME's 68020 — TG68K implements `CMP2`/`CHK2` and carries its own bugfixes for them through 2020, but **stage 3 is the test of that**, and it has never been played here. |
| [02527](https://mametesters.org/view.php?id=2527) square glitches on the title screen | fixed in 0.266 | Fixed by PR #11811, the video rewrite this core is written against, so it should not appear. |
| [06794](https://mametesters.org/view.php?id=6794) screen flickering | not a bug | A 58.97 Hz game on a 60 Hz display. If you see flicker, try the OSD's **Refresh Rate** and your display's, before suspecting the core. |

### What this core does NOT emulate that MAME also does not

Everything in this list is unemulated in MAME too, so matching MAME says
nothing about it. From MAME's own source:

- **Video**: `0x0800` (VRAM layer opaque) and `0x2000` (enables "garbage
  pixels") are both marked *unemulated*; the `0xf000` palette-RAM format,
  the `0x6600` bg-palette field and the `0x7000` field are *unimplemented*;
  the pixel layer's palette mirroring is an admitted **hack** keyed off the
  scroll offset; there is a `TODO: determine when we can stop drawing`; and
  sprite lag is a guess — *"presumably sprite lag is timing of sprite
  ram/framebuffer access."*
- **Sound**: *"ES5510 ESP emulation is not perfect"*, `TODO: ES5505 Volume
  control is correct?`, and the ES5510's DRAM size is unverified.
- **Board**: the `TC0650FDA` "Digital to Analog" chip — the part that does
  the blending and RGB output — is not modelled as a device at all, and
  `TC0640FIO` has a TODO to use the shared implementation.

### What this core has that MAME does not

Short list, and worth being accurate about: **this core is a subset of MAME's
behaviour, not a superset.** Every graphics feature here was ported from MAME
and checked against it. Two exceptions:

- **The analog output stage.** MAME emulates the sound path to the MB87078
  and stops. The real cabinet then runs that through an LM324 op-amp and a
  power amplifier with a volume control — `taito_f3.cpp` says so explicitly,
  and adds that *"in test mode, digital regulation hasn't effect"*. That
  analog stage is the entire missing 25–30 dB, and **Audio Boost stands in
  for it**. MAME leaves it to the host's volume control; a core has to put
  it somewhere.
- **Real fetch timing.** MAME renders a frame in one pass with no memory
  model. This core has a raster, line buffers and a finite SDRAM budget, so
  it can *miss a deadline* in a way MAME cannot — which is Known problem #1.
  That is not extra fidelity, it is a real constraint the arcade board met
  and this implementation does not yet.

And one deliberate divergence: MAME's several-inverted-clip-planes case is
not reproduced (`rf_video_mix.sv`). Ray Force never enables a clip plane, so
it costs this game nothing.

The MAME source this was written against is **current**: `taito_f3_v.cpp` and
`taito_f3.h` are byte-identical to MAME master as of this release, including
the April 2024 video rewrite, and `taito_f3.cpp` differs only in API
tidy-ups and manufacturer strings — nothing behavioural, and nothing that
touches Gunlock/Ray Force.

Uncertainties inherited from MAME, which no amount of diffing against it can
resolve, all flagged in its own source: `0x0800` marking the VRAM layer
opaque and `0x2000` enabling "garbage pixels" are both marked *unemulated*;
the priority-conflict behaviour where "the second layer can reset part of the
state" is described as a hardware feature-or-bug; and the timer register at
`0x4C0000` that configures a pseudo-hblank interrupt is a TODO. Ray Force
writes 0 to that last one, so it costs nothing here.

## How to use it

One bitstream runs every game below. The MRA picks the game; you never swap
cores.

1. Copy `releases/Rayforce_20260831.rbf` to `/media/fat/_Arcade/cores/` on
   the MiSTer SD card.
2. Copy the `.mra` files you want to `/media/fat/_Arcade/`.
3. Put the matching MAME ROM zips in `/media/fat/games/mame/`. Parts are
   matched **by CRC**, so the layout inside a zip does not matter and a
   merged set is fine.
4. Pick the game from the MiSTer arcade menu.

### Games, and what each needs

Every one of these runs on the same `.rbf`. "Verified" means measured against
MAME frame by frame, not just "it looked right".

| Game | MRA | ROM zip | Screen | State |
|---|---|---|---|---|
| Ray Force (US) | `Ray Force.mra` | `rayforce.zip` or `gunlock.zip` | vertical | **Verified.** Pixel-identical to MAME, sample-exact audio |
| Gunlock (World) | `Gunlock.mra` | `rayforce.zip` or `gunlock.zip` | vertical | **Verified**, same set as above |
| Ray Force (Japan) | `Ray Force (Japan).mra` | `rayforce.zip` or `gunlock.zip` | vertical | **Verified**, same set as above |
| Elevator Action Returns | `experimental/Elevator Action Returns.mra` | `elvactr.zip` | horizontal | **Plays.** Video verified against MAME; sound runs but has never been correlated |
| Bubble Bobble II | `experimental/Bubble Bobble II.mra` | `bublbob2.zip` | horizontal | **Plays.** Confirmed on hardware 2026-08-31; not yet frame-verified |
| Bubble Memories | `experimental/Bubble Memories.mra` | `bubblem.zip` | horizontal | **Untested.** MRA is written and assembles; never loaded on hardware |
| Puzzle Bobble 2 | `experimental/Puzzle Bobble 2.mra` | `pbobble2.zip` | horizontal | **Boots, renders wrong.** Sprites and text are correct; the playfield is truncated because `extend=0` is not enabled — see below |

The three Ray Force MRAs share every ROM and differ only in one program chip,
so a single `gunlock.zip` covers all three regions.

Horizontal games need **Rotate: None** in the OSD; the vertical ones want the
core's default. Anything under `experimental/` is exactly that — it runs, but
it has not earned the same evidence the Ray Force set has.

### Known limitations

- **High scores save but do not restore.** Scores are captured into the upper
  half of `config/nvram/<mra>.nvm` correctly; injecting them back on boot does
  not work yet, so the table resets each power cycle.
- **Puzzle Bobble 2's playfield is wrong.** The `extend=0` playfield geometry
  it needs is implemented and verified but compiled out, because it costs
  ~116 LABs the device does not currently have.
- **`SPRLINE : LATE` reports FAIL** on the self-test page. The picture is
  visually clean in heavy scenes; the counter itself is the open question.

### The three Ray Force regions

They are one ROM set with one program chip swapped, which is why a single zip
serves all three:

| MRA | Region | Differs by |
|---|---|---|
| `Ray Force.mra` | US | `d66-25.ic35` |
| `Gunlock.mra` | World / Europe | `d66-24.ic35` |
| `Ray Force (Japan).mra` | Japan | `d66-20.ic35` |

All three share every other ROM; the region changes the title and the notice
screen.

## Controls

| Gamepad | Action |
|---|---|
| D-pad **or left analog stick** | Move |
| A | Shot |
| B | Bomb (lock-on laser) |
| R | Start |
| L | Insert coin |
| Select | Service |
| Start | Pause |

The left analog stick works alongside the d-pad — it sets a direction past
about 38 % of full deflection. If it does nothing, check MiSTer's own input
mapping first: the stick has to be assigned under *Define analog joystick*, or
MiSTer never sends the axes to any core.

Input latency in the core is zero-added: the joystick word reaches the CPU's
port read through combinational logic only, with no pipeline stage and no
per-frame sampling. The one frame of latency that does exist is MiSTer's
rotation framebuffer — see below.

## Video options

**Rotate** — the cabinet monitor is vertical. **CW (TATE)** is the default and
is the right way up; CCW is upside down for this game, because Ray Force runs
with the F3 flipscreen bit permanently set and the raster the core produces is
already inverted. **None** leaves the picture in raster order.

Rotation goes through MiSTer's DDR3 framebuffer, which costs **one frame of
latency**. `Rotate = None`, and the analog VGA output (which stays in raster
order deliberately, for a physically rotated CRT), avoid it.

**Flip Screen** — 180° on the rotated output. Unlike some cores this is *not*
done in the core's raster: Ray Force's own flipscreen bit is already set and
the sprite engine takes its flip from the sprite command word, so flipping the
renderer would turn the playfields over and leave the sprites upright. It
therefore applies when rotation is on, and does nothing with `Rotate = None`.

**Aspect ratio**, **Scandoubler Fx** (None / HQ2x / CRT 25 % / 50 % / 75 %) and
**Stereo Mix** (None / 25 % / 50 % / 100 %) are the usual MiSTer options. The
ES5505 pans its voices, so Stereo Mix is a real choice on headphones.

**Audio Boost** — **the arcade board's own output is very quiet**, and this
core reproduces its gain structure exactly, so without a boost both games sit
about 25–30 dB below where a MiSTer core normally does. Measured from the
core's own Audio Ring capture: peak **−33.5 dBFS**, rms −43 dBFS.

That is not a defect. `rf_mb87078`'s 0 dB coefficient is 576 against a `>>> 15`
— precisely taito_en's ×3.125 at 0 dB, times MAME's 0.18 route gain, times the
ES5506 pump's 0.5, times the 20-bit → 16-bit ÷16 — and Ray Force then runs the
chip at −7.5 dB rather than 0 dB, for about 1/135 in total.

So the level is a choice, and the OSD makes it one: **8x by default** (+18 dB),
with 16x for quiet amplifiers and **1x for MAME's own level** if you are
comparing the two. It is a saturating shift on the finished sample, so a loud
passage clips rather than wraps. The Audio Ring is tapped *before* the boost,
so `tools/rf_audio_match.py` still reports a real amplitude ratio against
MAME rather than the boost setting.

**Refresh Rate** — native is 262 lines at **58.94 Hz**, which nearly every
15 kHz display holds. The **60Hz** option trims the frame to 257 lines; the
game paces itself off the vblank interrupt, so it then runs ~1.8 % fast. Leave
it on native unless your display needs it. *(Verified in simulation; never
watched on a real display.)*

**Pause When OSD Open** — freezes both CPUs while the menu is up, so the music
stops with the game.

## The arcade board's own service menu

**The F3 board has no DIP switches.** There is no DIP bank on the PCB and none
in MAME's driver: difficulty, lives, coinage, free play and screen flip all
live in the game's own service menu and are stored in the 93C46 EEPROM.

Turn on **Service Mode** in the OSD (it is the cabinet TEST switch) and reset
to reach it.

## Saving settings

The MRAs declare `<nvram index="254" size="128"/>`, so MiSTer loads
`/media/fat/config/nvram/<mra name>.nvm` into the EEPROM after the ROMs and
writes it back out again when asked.

MiSTer only performs that write-back **when you open the OSD** (or pick *Save
settings*). So the sequence is: change what you want in Service Mode, leave it,
**open the OSD once**, and the file appears. The game itself only writes the
EEPROM when a setting actually changes — during a normal boot and attract it
only reads it — so a `.nvm` will not appear until you have changed something.

## Built-in self test

The core carries a 28-row self-test page covering the ROM load and checksum,
the SDRAM, the CPU write stream, every video RAM, the interrupt rates, the
video pipeline's per-frame counters, the sprite engine's record and timing
margins, and the sound board. It is **on by default** (`Self Test` in the OSD)
and the same page is streamed over the DE10-Nano's UART, which is how the core
is tested without anyone watching a monitor. Rows that prove the video
pipeline *can* do something (fetch tiles, make non-black pixels) latch PASS
once it has and read BUSY until then, so a blank frame never shows a false
FAIL; the sprite engine's rows are peak-held and need the core left running a
couple of minutes before they mean anything:

```sh
python3 tools/rf_uart.py -t 12          # the page, over the serial port
```

`UART Debug` switches that port between the page, the CPU write ring, the
sound-chip write ring, and the **Audio Ring** — a capture of the core's own
audio output, which `tools/rf_audio_match.py` correlates against MAME's mix.
That is how "the sound is right" was established without an ear in the room.

## Building it yourself

Quartus Prime Lite **17.0.2** (the version the MiSTer framework targets).

```sh
./build.sh          # ~32 minutes; writes output_files/Rayforce.rbf
```

`build.sh` runs the compile under a systemd scope with a memory cap so a
runaway fitter cannot take the machine down, prints a phase/progress line, and
gates on both a produced bitstream and the timing report.

The Verilator benches are the core's real regression suite and need no FPGA:

```sh
make -C sim line-all pf-all mix-all      # video, against MAME's own frames
make -C sim spr-all spr-line-all spr-ghost
make -C sim pipe pipe-60 pipe-lat        # the raster pipeline under load
make -C sim spr-lat                      # the sprite fetch path's headroom
make -C sim spr-rec                      # the sprite record store vs the model
make -C sim es5505 es5505-rw             # the sampler, incl. host reads
```

They compare against reference data produced from MAME by the Lua oracles in
`tools/`; regenerate that data with `tools/oracle_f3dump.lua` (video) and
`tools/oracle_en_dump.lua` (sound). The dumps are not in the repository — they
are hundreds of megabytes — and neither are the MAME source files the core was
written against.

## Other F3 games

The F3 library is **35 distinct games across 100 ROM sets**, and they differ
from each other by remarkably little. From MAME's driver:

- **Four machine configurations** (`f3`, `f3_224a`, `f3_224b`, `f3_224c`) that
  differ *only* in where the visible raster starts and how tall it is — 232
  lines from line 24, or 224 from 31, 32 or 24.
- **Two per-game video quirks**: `extend` (0/1, the playfield RAM layout) and
  `sprite_lag` (0, 1 or 2 frames).
- **Orientation**: ROT0, ROT90 or ROT270.
- **ROM footprint from 9.8 MB (Arkanoid Returns) to 49 MB (Kirameki Star
  Road)**, which is what decides how many games a given SDRAM module can hold.
  Ray Force is 11.5 MB as this core loads it.

**Elevator Action Returns runs** — it boots, plays, and draws sprites and
playfields, with the sound CPU streaming and one vblank acknowledge per
frame. All ten sampled frames match MAME pixel for pixel across the
full 232-line visarea (`make -C sim ear-pipe-all`, 74,240 pixels each). It
stays in `releases/experimental/` because ten frames of attract and
character select are not a playthrough, the pivot layer is still a mirror
rather than real RAM, and its sound has never been correlated the way Ray
Force's was.

Getting there turned up a pattern worth naming: **every one of its rendering
defects was a Ray Force dimension frozen into the RTL as a constant.** The
board is one chipset running 35 games, so anything sized from a ROM region or
a visarea has to be a parameter.

- **Graphics codes were 14 bits.** That is exactly right for Ray Force, whose
  sprite and tile regions hold 16,384 elements each — and wrong for Elevator
  Action, whose regions are 4 MB and hold 32,768. MAME builds a 17-bit sprite
  code and uses all 16 bits of the tile word. The visible symptom was oddly
  specific: on the character-select screen every panel, bar and glyph was
  perfect while the three portraits drew as scattered fragments of in-game
  sprites, because 60 of the 72 over-limit sprites in that frame *were* the
  portraits.
- **The sprite cull window was hardcoded twice**, in the list walker and
  again in the row expander, to Ray Force's 224 lines from line 31. Elevator
  Action shows 232 from line 24, so every sprite row on the 8 lines outside
  that window was silently dropped. Both now follow the `vis_mode` the game
  config byte already carried.
- **The bench never looked.** `sim/pipe_tb.cpp` compared Ray Force's window
  whatever game it was handed, so those 8 lines went unchecked — widening it
  is what exposed the cull bug at all. A bench with one game's dimensions
  baked in cannot fail on the lines it never reads.

Two things also had to be built for it, and both are instructive about why Ray
Force never needed them:

- **Real pivot (pixel-layer) RAM.** Ray Force only ever *clears* that RAM, so
  a read-as-zero stub survived — and its 64 KB of block RAM was spent on the
  sound board instead. Elevator Action's power-on self test writes
  `FF/AA/55/00` to every RAM and reads each location straight back; a stub
  cannot pass that. It now has 8 KB mirrored across the 64 KB window, because
  64 KB is 51 M10Ks and about 20 were free. The mirror passes because the test
  verifies each location immediately after writing it.
- **The watchdog.** Elevator Action's boot deliberately parks at a `BRA.S *`
  with interrupts masked and waits for the TC0640FIO watchdog to reboot the
  board — traced in MAME, it sits there about two seconds, resets, re-runs its
  self test and carries on. This core ignored writes to `0x4A0000` entirely,
  so it hung there forever. Ray Force never depends on that path.

Both failures were silent hangs rather than error messages, and the game's own
error handler is generic enough to point at the wrong RAM, which is why this
took a while. The full trail is in `HANDOFF.md`.

So most of what a *compatible* second game needs is four small parameters,
which belong in the MRA rather than in the RTL. That is now true: the config
byte carries them, and `vis_mode` reaches both the raster crop and the sprite
cull.

**"Compatible" is doing real work in that sentence, though.** Counting
MAME's own `f3_config_table` (33 games):

| Still hardwired here | How many games it blocks |
|---|---|
| ~~`extend` is tied to 1~~ **live** (`cfg_extend`) | was 15 of 33; now none. Puzzle Bobble 2 and Darius Gaiden both render on it |
| ~~sprite lag is tied to 1~~ **now 2** | matches MAME for both shipped games; 3 games want 0 and remain unserved |
| pivot layer is an 8 KB mirror | every game that actually draws on it |
| 18.5 MB SDRAM map | Kaiser Knuckle and Kirameki Star Road are 48-49 MB |

Config bits [2] and [4:3] are reserved for the first two and are not read
yet. `extend` is the awkward one: it is hardcoded in the Python model
(`EXTEND = True`) as well as in the RTL, so there is no verified oracle for
the non-extend path — that work starts before any RTL does. And the sprite
lag row is not hypothetical future work: MAME says lag 2 for both Gunlock and
Elevator Action, the engine does 1, and the benches hide it because they hand
the sprite RAM over from frame-2 themselves.

So the architecture generalises; the coverage does not yet. The largest item
left is the pivot layer — though not for either game this core runs:

**The pivot (pixel) layer still has to come back for whichever F3 game draws
on it.** Ray Force never does — it only clears it, which this core proves on
every run with a self-test row — so the layer's 64 KB of block RAM was spent
on the sound board's RAM instead, and what stands in for it is an 8 KB mirror.

Elevator Action Returns looked like the counter-example and is not. A first
probe counted 131,072 writes to the pivot RAM over 2,319 frames, 98,304 of
them carrying non-zero data, touching all 256 pages — but sampling the RAM's
live *contents* rather than the write stream tells a different story. Those
writes all happen once, in a burst between frames 120 and 180, and **the most
non-zero data ever live in the layer is one longword out of 16,384**,
transient inside that burst; from frame 180 to frame 2,653 it is uniformly
empty, exactly like Ray Force. MAME's frame dumps agree: `pivot_ram` is all
zero in all nine of them. It is a boot-time fill-and-clear — a memory test —
not a layer in use, and the game runs on the mirror.

So the cost is deferred rather than paid: for a game that really draws the
layer, holding both it and the sound RAM needs 128 KB of block RAM against a
device at 95 % of its M10K blocks, so one of them — or the 128 KB main RAM,
the largest single block — has to move to SDRAM behind a cache.
`rtl/rf_video_pivot.sv` itself is already written and verified, and the
`PIVOT WR:SND PC` self-test row is the watchdog that would say on hardware if
either shipped game started using it.

Encouragingly, the same measurement says **no F3 game examined uses sprite
"trails"**, so the one sprite feature this core omits costs nothing.

## Credits and licence

- **MAME** — the reference for every part of this core. The video, sound and
  protection behaviour was ported from and checked against MAME's `taito_f3`
  and `taito_en` drivers and its ES5505/ES5510 devices.
- **TG68K.C** by Tobias Gubener — the 68000/68020 CPU core.
- The **MiSTer** framework and its `sys/` files.

Licensed under the **GNU General Public License v3** — see [LICENSE](LICENSE).
