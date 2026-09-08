# Ray Force / Gunlock (Taito F3) — Handoff

**Date**: 2026-08-29
**Status**: Phase 2 (video) complete on hardware, sprites included. Phase 3
(sound) stages 0-3 built and on the board: the sound 68000 runs the real
driver (its chip writes match MAME's), the ES5505 is sample-exact against
the model, the volume chip and the mix drive AUDIO_L/R. **Deployed: build 28113056 (B15)**, timing met on every clock
(the first clean one since B7), every self-test row PASS.
**Sound was scrambled on every build up to B12, and the cause is found and
fixed in B13 (2026-08-28 morning, session b2): the driver READS the ES5505
and the RTL answered every read with a constant** -- see "The sound bug:
ES5505 reads" below. B12 (`28084316`) is on the board with every page row
PASS. **B13 (`28094310`, the read port + the analog stick as d-pad) is on
the board: every page row PASS, and its Audio Ring capture correlates
1.000 with MAME's own mix at ratio 1.0 (28.850 s on MAME's timeline) --
the board's sound is MAME's, sample for sample, for the first time.** The story of the night is under "Morning summary" and
"Overnight plan" below; the video work of 2026-08-27 follows after that.

> **THE SCOREBOARD FOR THIS BUG IS NOW [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md).**
> Every fix and instrument attempted, its verdict, what is ruled out and by
> what evidence, and the dead ends. Add a row there before starting anything --
> several ideas were tried twice because nothing collected them in one place.
> This file remains the story in date order.
>
> **ROOT CAUSE FOUND 2026-09-08 — read SPRITE-CORRUPTION.md item 0.** The
> sprite record store `rec[0:1][0:NREC-1]` (`NREC = 12288`, 24,576 words) was
> built by Quartus as a **16,384-word RAM** (`rec_rtl_0: WIDTHAD 14, NUMWORDS
> 16384`, silently). Bank 1's records from 4,096 up alias onto bank 0's
> 0..8191, so any frame with more than 4,096 records clobbers the other bank:
> one parity draws a stale/mixed list, the other is live -- the "two layers,
> offset, flickering" reported from day one. The threshold is a record COUNT:
> attract ~3-4k clean, continue screen 4,587 slightly wrong, boss 10,836
> severe. At the committed `NREC = 10240` the threshold was 6,144 (why GitHub
> "had fewer streaks"); raising it to 12,288 lowered the threshold (why it
> "got worse when the core expanded"). Verilator models all 24,576 words, so
> every bench passed. **Fix: `NREC = 8192`** -- 2 x 8192 = 16,384 = exactly
> the RAM Quartus builds. 24,576 real words would cost +256 MLABs (= LABs) on
> a device at 4,185/4,191: the truncation was why it fit. **Deployed as
> `07213908` and VERIFIED: FOLDSEQ constant on both parities, rf_flicker one
> state, player: "that fixed almost all of it."** Residue: ~2,600 dropped
> rows a frame at the boss (`SPR REC : DROP` saturates there). **Lesson, for the second time:** after
> any memory change read the RAM inference lines (`NUMWORDS`, `WIDTHAD`) in
> the map log before trusting a passing bench.
>
> Older callout follows:
> **READ THIS FIRST (2026-09-07). THREE THEORIES TESTED AND KILLED, AND THE
> SEARCH SPACE IS MUCH SMALLER.** Everything about the sprite corruption now
> lives in **[SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md)** -- the measured
> symptom, every attempt with its verdict, the dead ends, and what is open.
> Read that first; this file is the story in date order.
>
> The day's outcome in short:
>
> 1. **The corruption was captured**, not just described: two states alternating
>    on a STATIC screen, byte-identical run to run, differing by 10,967 pixels,
>    scanline-structured (`screenshots/paused_cmp/`). It appears on the CONTINUE
>    screen at near-zero load, which **contradicts the throughput theory** that
>    README item 1 still concludes with.
> 2. **Rotation's Avalon violation** -- `screen_rotate` pulses its DDR3 write for
>    one cycle and never reads `DDRAM_BUSY` (= `waitrequest`), so it drops a
>    pixel whenever the port is busy. Real, provable, fixed with a write FIFO in
>    `rf_ddr_arb`, and **NOT this bug**: 0 stalls across 210 gameplay samples.
>    I wrote it up here as "ROOT CAUSE FOUND" before the board had a say. It
>    was not.
> 3. **Sprite RAM tearing** -- the walk reads sprite RAM with no snapshot while
>    the CPU can write it, and neither MAME nor the bench can reproduce that by
>    construction. **Ruled out**: `SPRTEAR WR:FRM` = one boot frame, never again.
> 4. **Abandoned-line residue** and **multi-write RAM inference** -- both real
>    shapes, both checked, both ruled out. See the register.
>
> **Where it stands:** every instrument on the sprite side reads clean while the
> picture is visibly wrong. The player reports the **committed** build has fewer
> streaks but not none, so there is a base bug in committed code plus amplifiers
> among the three uncommitted functional changes (lookahead skip, pen mask
> widening, tile-row cache). Build `07154217` is on the board with the lookahead
> skip switched off (`LK_SKIP`), awaiting the player's comparison.
>
> **Note the dates.** The last commit is 2026-08-31; everything since is
> uncommitted, including every document written this week.
>
> **Read this first (2026-09-04, 08:45).** `04074618` is on the board under
> `releases/experimental/Ray Force (zone 2).mra`, timing met (+0.266 ns), and it
> carries three new things: the **zone injector** (coin+start opens at zone 2),
> the **stale-line detector** and the **fetch self-check**. Read off the board at
> the title screen, both new instruments are zero, `SPR REC` shows 0 dropped, and
> `SPRLINE` reads **0 late with a longest line of 11,306 clocks**. Read that row
> carefully: the zero means the LATE COUNTER IS NOW HONEST, not that the draw
> fits its budget. 11,306 clocks is still far over the 3,456-clock budget.
>
> **UPDATE 09:05: the injector is CONFIRMED ON HARDWARE, and remote input
> works.** A virtual GAMEPAD coined up and started a game, and the board drew
> `AREA 2`. Both firsts. What is still needed from a human is PLAY: something
> has to survive zone 2 to reach the boss, which is where the corruption is.
> See "Remote input solved" below.
>
> Everything operational -- the exact commands, the page field layouts, the
> unexplained measurements and the dead ends -- is under "2026-09-04 morning"
> below.
>
> Older callout follows:
> **Read this first (2026-09-03). THE PALETTE IS PROVED CORRECT, RAY FORCE'S
> HEAVY LINES ARE PIXEL-BOUND, AND THE BOARD'S OSD IS UNREACHABLE.** Four
> builds overnight; **`02230245` is deployed** (cache + quad-skip + MRA-driven
> UART mode, timing met +0.064 ns). Three things matter for whoever picks
> this up:
>
> 1. **Darius Gaiden's palette content is CORRECT** -- 1023/1024 entries
>    identical to MAME's `dg5070` dump, captured off the board through the
>    write ring. The CPU, the palette write path and the index composition
>    are all exonerated. What is left is the PEN, i.e. the sprite graphics
>    fetch.
> 2. **Ray Force's heavy lines are PIXEL-throughput-bound, not fetch-bound.**
>    784 rows x 16 px = 12,544 pixels in 14,236 clocks = 1.135 clocks/pixel
>    against a 3,456-clock budget. No fetch improvement can fix that; it
>    needs ~4 px/clock. The cache bought 3 %, the quad-skip another 3 %.
> 3. **`config/Rayforce.CFG` does NOT reach the status word** and pad input
>    is dead, so **no OSD option is reachable on this board**. The MRA config
>    byte does work and now drives `uart_mode` (index 2 bits [7:6]). That is
>    the only way in -- use `releases/experimental/Darius Gaiden (write
>    ring).mra`.
>
> **NOT established:** that the tile-row cache fixes the Darius tower
> colours. One Zone A frame with the cache renders steel towers and two
> without it render red, but those two are from a build differing by more
> than the cache, and 164 samples on the proper control build never reached
> the Zone A demo. Treat it as suggestive only. See the section below.
>
> Older callout follows:
> **Read this first (2026-08-31). THE SPRITE SPLITS ARE FIXED.** Build
> `31083249` (commit 17c5bfa) renders solid sprites in-game -- verified by
> the HPS fill-probe (inject solid data into the DDR3 framebuffer, photograph
> a solid rectangle; the broken builds photographed stripes at x%4==3) and by
> live battleships matching MAME's reference. Root cause: the readout line
> buffer wrote FOUR pixels a cycle into an inferred single-write-port RAM;
> Quartus silently kept one lane, Verilator performed all four. Fixed with a
> 64-bit rf_bram, one write per DDR beat. Outstanding: HDMI timing closure
> (-0.385 ns; seed sweep running), a ~2/frame cosmetic over-count in
> SPRLINE's miss half (sample at end-of-line, next build), the user's level-2
> playthrough confirmation, and rf_hiscore wiring (staged in scratchpad).
>
> Older callout follows:
> **Read this first (2026-08-30).** Build `29224005` is on the board. Two of
> its three changes are confirmed working there (sticky self-test verdicts,
> run-length sprite records); the third, `ch7`, **did not work** and the
> reason is understood -- the two sprite channels were at fixed priority and
> must alternate. The fix for that, and a correction to the `SPRLINE` row's
> pass criterion, are in the tree and **not yet built**. See "The board's
> verdict on ch7" immediately below.

**The board is on DHCP and answers to `MiSTer.lan`.** The 172.17.1.164 hardcoded in `tools/rf_deploy.py` and `tools/rf_screenshot.py` is stale; `RF_HOST=MiSTer.lan` overrides it and every tool call below assumes that.

---

## 2026-09-04 morning — Session handoff, and the board's own verdict on `04074618`

Work moved from session `b5` to session `2e` at 08:45. `b5` released the build
slot and the board; nothing was armed (no builds, watches, cron or loops). The
operational knowledge below lived only in that session and in a tmpfs
scratchpad that will not survive a reboot, so it is written down here.

### First readings from both new instruments -- and why they prove little yet

A 200-second UART capture across a scripted play session on `04074618`:

```
STALELN:AGE:CNT  4A020001   line 74, 2 frames behind, count 1
SPRFETCH:ROWMAX  ...0310    fetch_bad 00 on EVERY page
SPRLINE : LATE   26C60000   longest line 9,926, 0 late
SPR REC : DROP   19750000   peak 6,517 records, 0 dropped
```

**The single stale line is a BOOT ARTIFACT, not a gameplay event.** It reads
`4A020001` on the FIRST page of the capture and never changes again through 200
seconds. At core load the framebuffer holds no previous frame, so the first
verified line's tag has nothing consistent to compare against and scores one
hit. Line 0 is exempt from the check; line 74 is not. **Count 1 that never
increments is the signature of a startup hit** -- the same shape as the benign
`PIVOT WR FAIL` on Elevator Action Returns. Treat any future reading as "count
above 1", and consider exempting the first frame after reset in the next build.

**The run never reached the failing regime, so nothing here is evidence about
the bug.** Peak records 6,517 and longest line 9,926 are ATTRACT-level numbers;
the boss reaches 10,836 records and 15,014 clocks. A screenshot at t+120 s shows
a starfield with one explosion on it. The scripted pad input fires and jiggles
the stick, which does not keep a ship alive or fill a screen. **A script that
presses buttons is not a player.**

So: the fetch self-check reads clean, but only under light load, which is weak.
The stale detector has still never been read during a genuinely busy scene.
Both remain unproven in the regime that matters.

### Finding the end of zone 2: partial

Zone 2 in MAME with the injector runs from the start to the zone-3 transition,
but **an unattended ship dies early**: `0x402317`/`0x402319` (the gameplay zone
copies, which read 3 while zone 2 is being played) drop to 0 by frame +2100, so
only ~1,800 frames of that run were real gameplay and everything after is game
over and attract. The zone advancing to 3 at +5,400 was the ATTRACT DEMO, not a
completed stage.

Consequence: the RAM dumps from that run are contaminated and **no clean
stage-progress counter was found in them** -- no 16-bit word rises at every
sample. Redo it holding a lives byte so the run is real gameplay throughout,
then diff. Candidate lives bytes from the decreasing-counter scan include
`0x4016A0` (9 -> 0 by frame +1,200). Nothing is confirmed.

### THE REFRAME: it is LOAD, not the boss (user, 2026-09-04)

**The player reports the corruption appears whenever the screen gets busy --
big explosions and the like -- and that the zone 2 boss simply has a LOT of
it.** This is the most important statement about the bug so far and it
reorganises everything above.

What it means:

1. **The defect is a DEADLINE problem, not boss-specific content.** Every
   attempt so far to reproduce it has hunted for the boss's particular sprites.
   Wrong target: the boss is just the heaviest scene, not a special one. Any
   scene dense enough will do, which is why level 1 "cleared up" after the
   video fixes -- lighter load, not a different code path.
2. **It fits the stale-line theory exactly, and explains the mechanism.** Under
   heavy load the sprite draw does not finish the frame; lines it never reached
   keep the PREVIOUS frame's pixels and their matching CRC, so they verify and
   are displayed one frame behind their neighbours. That is precisely "two
   layers, offset, flickering", and it should scale smoothly with busyness --
   which is what the player describes.
3. **It explains why no bench reproduces it.** The benches render SINGLE frames
   and check them pixel by pixel. A deadline overrun is a property of sustained
   load across consecutive frames. A single frame, however heavy, cannot show
   it, and the heaviest bench frame is 344 rows against the board's 784.
4. **It re-points the fix at throughput, which was already measured.**
   `rf_video_spr` advances ONE pixel per clock whether or not that pixel draws.
   The worst line needs ~4 pixels per clock to fit. Fetch bandwidth, the cache
   and the quad/lookahead skips were all aimed slightly off-target; they reduce
   work but do not raise the pixel rate.
5. **It makes the bug reproducible on demand**, now that remote input works: a
   busy scene is enough, so no one has to play to a boss to test a build.

**Corollary that needs checking:** if lines are being missed on a deadline,
`SPRLINE : LATE` ought to fire too, and it currently reads 0. Either the draw
window is longer than one frame (so "late" is not the right predicate), or the
miss fix that removed the phantom count now under-reports. Do not treat that
zero as proof of health until it has been read during a genuinely busy scene.

### Remote input solved: a virtual GAMEPAD, not a virtual keyboard

**"Board input is dead" was wrong, and the fix is small.** `tools/rf_pad_run.py`
creates a uinput device that mirrors the attached pad exactly -- name
`Microsoft X-Box One pad`, bustype 3, vendor `0x045e`, product `0x02d1`,
version `0x0101`, the same eleven `BTN_*` codes and eight `ABS` axes. MiSTer
applies its built-in gamepad defaults to it. `BTN_SELECT` inserted a coin and
`BTN_START` started a game, **both on the first attempt**, verified by
screenshots reading `CREDIT 01` and then `AREA 2`.

Why the old tool failed: there are **no `.map` files in `/media/fat/config`**,
so nothing maps keyboard keys for this core -- the real pad works purely on
MiSTer's defaults for a *recognised gamepad*. `tools/rf_input.py` presents a
plain keyboard with an invented vendor `0x1234`, so MiSTer has no mapping to
apply and silently drops every key. That is the entire "input is dead" story,
and it cost this project a documented dead end plus a wrong generalisation
(see the callout of 2026-09-03).

`rf_input.py`'s ordering rule was right and still applies: MiSTer enumerates
input devices when a core loads, so **create the device, THEN `load_core`, then
press**. The device also disappears when the creating process exits, so hold it
open for the whole session.

**This unlocks headless in-game testing** -- coin, start, menus, a named scene,
a screenshot at a chosen instant -- which every capture campaign in this project
so far has had to work around.

### The zone injector: CONFIRMED on hardware

Coin + start on `04074618` under `Ray Force (zone 2).mra` drew **`AREA 2 -- THE
GRAVITY OF...`**. The bus-level substitution fires on real hardware exactly as it
did in MAME. Screenshots in `screenshots/pad/`.

Counters sampled during that Area 2 run, still clean:

```
SPR REC : DROP  0BE80000    3,048 records, 0 dropped
SPRLINE : LATE  23190000    longest line 8,985, 0 late
SPRFETCH:ROWMAX 005802D0    fetch_bad 00, longest fetch 88, rows 720
STALELN:AGE:CNT 00000000
```

**That is the start of zone 2, NOT the boss**, and the ship was not being
flown, so this says nothing yet about the corruption. Reaching the boss still
needs someone to play -- or an input script good enough to survive, which is
now at least possible.

### `04074618` is on the board and both new instruments read clean at the title

Read off the board over UART at 08:44, not taken on trust:

```
BUILD           04074618
ROM CHECKSUM    77E1C279  PASS
SPR REC : DROP  19750000  PASS   6,517 records, 0 dropped
SPRLINE : LATE  2C2A0000  PASS   longest line 11,306 clocks, 0 late
SPRFETCH:ROWMAX 005B0310  PASS   fetch_bad 00, longest fetch 91, rows 784
STALELN:AGE:CNT 00000000  PASS
```

**Do not read `SPRLINE : LATE`'s zero as a throughput win.** It is two separate
facts, and conflating them is an easy mistake to make:

1. **The zero is a counter fix, not a fit.** The late count climbed exactly 28
   per page pass on every build A-E regardless of line time (63, 83 and 94
   consecutive samples). `rf_spr_fb` cleared `hit_seen` at `frame_start` while
   the mixer was mid-line, scoring **one phantom miss per frame**, and a page
   pass is 28 frames. Build F removed that clear and the rate went to 0 across
   104 samples with the RTL otherwise unchanged. The row is now honest. The draw
   still does NOT fit: 11,306 clocks in attract and 9,497-10,876 at the boss,
   against a 3,456-clock budget.
2. **The longest-line improvement is the lookahead skip**, 14,676 down to
   ~9,500-11,300. The transparent-quad skip was a strict subset of it and has
   been REMOVED from the RTL -- do not credit it. The tile-row cache measured
   3 % on that line, though it is worth much more on fetch-bound lines.

`SPRLINE`'s peak-hold also starts at frame 16, so a fresh board reads clean
regardless.

**Both new instruments read zero, which is the expected null result**: the
corruption is at the zone 2 boss and the board is at the title screen. Their
positive behaviour is still untested. THE NEXT STEP IS UNCHANGED AND IT NEEDS A
HUMAN: coin up on the pad, start a game, confirm it opens at zone 2 (expect blue
fighter formations, no asteroid field), play to the boss, then read the page.

### The board commands, verbatim

`RF_HOST=MiSTer.lan` is required: `rf_deploy.py` and `rf_screenshot.py` hardcode
a dead `172.17.1.164`. Use `.venv/bin/python` -- paramiko is only in the venv,
while numpy and PIL are only in the system `python3`.

```bash
# self-test page (rf_uart.py already defaults to MiSTer.lan)
.venv/bin/python tools/rf_uart.py -t 12 -o page.txt
grep -oE '^(BUILD|STALELN:AGE:CNT|SPRFETCH:ROWMAX|SPR REC : DROP|SPRLINE : LATE) +[0-9A-F]{8}' page.txt

# screenshot burst -> screenshots/<tag>/
RF_HOST=MiSTer.lan .venv/bin/python tools/rf_grab.py <tag> [n]
```

Page field layouts, which are not otherwise written down:

| row | packing |
|---|---|
| `STALELN:AGE:CNT` | {last stale line[7:0], frames behind[7:0], count[15:0]} |
| `SPRFETCH:ROWMAX` | {fetch_bad sat8, longest fetch sat8, rows on line[15:0]} |
| `SPR REC : DROP` | {records built[15:0], rows dropped[15:0]} |
| `SPRLINE : LATE` | {longest line clocks[15:0], late lines[15:0]} |
| `BUILD` | build stamp, ddhhmmss |

Deploying takes a snippet rather than a script, and the `rm -f` matters --
**MiSTer loads the highest-sorting `Rayforce_*.rbf`, and a stale name has beaten
a fresh upload twice**:

```bash
RF_HOST=MiSTer.lan .venv/bin/python - <<'PY'
import sys,time; sys.path.insert(0,'tools'); import rf_deploy as d
c=d.connect(); s=c.open_sftp()
d.run(c,"rm -f /media/fat/_Arcade/cores/Rayforce_*.rbf")
s.put("builds/<file>.rbf","/media/fat/_Arcade/cores/Rayforce_20260904_0007.rbf"); s.close()
d.run(c,'echo "load_core /media/fat/_Arcade/Ray Force (zone 2).mra" > /dev/MiSTer_cmd')
time.sleep(55); print(d.run(c,"cat /tmp/CORENAME")); c.close()
PY
```

Then confirm with the UART `BUILD` row. **Copy `output_files/Rayforce.rbf` into
`builds/` before the next `./build.sh`** -- it wipes `output_files/`. Use
`./build.sh`, never `build_seeds.sh` (11 G caps). `tools/shot.py` is broken for
anything but Ray Force: hardcoded directory, and it deletes first.

### Measurements that are real but unexplained

- **`rows on line` reads 784 within seconds of boot in attract**, yet MAME's
  heaviest attract line is 344 rows and the boss-2 dumps are 91. The RTL counter
  does not measure what the model calls rows on a line, and nobody found out
  what it does count. **Do not compare that field against dumps.**
- **The stale detector's calibration is unexplained.** Expecting the tag to
  equal `fnum` flagged ~781 lines a run; expecting `fnum-1` flagged ~256. The
  relation partitions lines rather than separating right from wrong, which is
  why the shipped detector compares each line's tag against the previous
  verified line's instead. Why the split is ~256/~781 is not understood.
- **The zone injector intercepts two writes, not one.** `PC 004810` is the
  new-game init, but `PC 01388C` also stores 1 to the same word two frames
  later. The bus swap filters on data == 1, so it substitutes both. Harmless in
  MAME. Zone clears write 2, 3, 4 and pass through untouched. Neighbouring
  words: `0x402311` goes 0 -> 1 at game start (lives, unverified);
  `0x402317`/`0x402319` are gameplay-only zone copies, 0 in attract.
- **One UART grab came back completely empty**, once, just before a redeploy. It
  was never explained. If the page reads empty, retry before concluding
  anything from it.
- Pre-existing and not caused by any of this work: `sim/` `ear-spr-line-all`
  frame 4200 shows 8 used-flag differences with or without every change above.

### Dead ends: do not spend a second cycle on these

- Poking the zone word once a frame cannot change the stage. The stage loader
  consumes it in the same frame. Proved: 0.0 % pixel difference.
- "Sprite fetches starve the playfield builder" was a misreading of `pipetb`
  `argv[5]`, which is the PLAYFIELD latency. Sprite latency is `F3_SPS_LAT`.
- `NREC 13312` does not fit: `Error 11802`, memory placement. ALM headroom is
  irrelevant to it -- the 12,288 build that followed had 2,567 ALMs spare.
- "The tile-row cache fixes the Darius tower colours" has no control. 164
  samples across three capture runs never reached the Zone A demo.
- HDMI PLL misses of -0.1 to -0.5 ns are fitter variance, not a real path. Seed
  8 has closed that clock twice; seed 11 did not.

### The rule this project keeps relearning

**The player's description is the primary instrument.** Two layers, offset,
flickering, stray vertical lines on the LEFT, green specks outside the main
lines. The board is rotated with the HUD down the left, so landscape-left is the
TOP of the native frame. Session `b5` twice overrode the user's direct
observation with a metric and was wrong both times: once removing the tile-row
cache the player had said improved level 1, once declaring board input dead when
the player was using a pad the whole time.

---

## 2026-09-03/04 — The boss: a real overflow fixed, the visible bug still open, and the instrument that can finally see it

**Deployed: `03213829` (H)** -- cache + `NREC 12288` + trimmed debug, timing
met on every clock (HDMI +0.232, core +1.59/+1.77), 2,191 ALMs spare.
**Building: `03224907`** -- the same plus a stale-line detector (below).

### What the player found that no bench ever had

The player reached the **Zone 2 boss on the board** and the page read:

```
SPR REC : DROP    2A540286    10,836 records built, 646 DROPPED
SPRLINE : LATE    3AA68679    longest line 15,014, 34,425 late
```

`NREC` was 10,240. **The store overflowed and threw away 646 sprite rows.**
`1d49395` had cut it from 12,288 on attract-mode peaks of 6,517/8,645 -- no
dump, capture or bench in this project had ever contained a boss. Even the
344-row MAME frame added the night before reaches only 2,190 records.

Raised to 12,288 (13,312 does not fit: `Error 11802`, memory placement, NOT
ALMs -- see RESOURCES.md). Confirmed on hardware: **8,957 records, 0
dropped.** That fix is real and stays.

**But the picture did not change.** Dropped rows were never the visible
defect. The player's description, which I should have weighted over my own
metrics from the start: *two layers, offset, flickering, stray vertical lines
on the left, green specks outside the main lines.* The board is rotated with
the HUD down the left, so landscape-left is the TOP of the native frame.

### Two mistakes worth recording

1. **I removed the tile-row cache** on the grounds that its benefit was
   unverified (it bought 3 % on the worst-line metric). The player had said
   the earlier video fixes cleared up level 1. The picture got worse with
   the cache out and I put it back. A player's direct observation beat my
   metric; I should have treated it as data.
2. **I tied off the scandoubler FX assuming the OSD was unreachable.** It
   was reachable -- the player was using a pad the whole time. My "board
   input is dead" came from `rf_input.py`'s virtual keyboard being ignored,
   and I generalised it to all input without checking. The FX stay off for
   now because they pay for the record store; restoring them is the next
   cheap build (~1,700 ALMs, no M10K, 2,191 spare).

### What the bench cannot see, and the instrument that can

Every path has now been exercised on the ACTUAL boss content (dumps from the
player's own savestates, model 100.00 % identical to MAME once the rotation
is undone): the RTL renders it **71680/71680 at the board's 87-clock sprite
latency and stays perfect to 120**, and cannot be made to fail even with the
DDR3 framebuffer slowed to 600 clocks at 50 % busy. The corruption is in
something simulation does not model.

The framebuffer's per-line CRC proves a line's CONTENT round-tripped -- but a
line the draw never rewrote this frame still carries last frame's pixels AND
last frame's matching CRC, so it verifies and is shown one frame behind its
neighbours. **Present, valid, wrong frame.** `miss` fires only when a line is
absent; nothing could see this. It is exactly "two layers, offset".

So the CRC word gives its low 8 bits to a **frame tag** stamped at write, and
the reader flags a line whose tag differs from the previous verified line's
(a frame drawn in one pass has one tag on every line; line 0 is exempt). A
fixed expectation against the frame counter does NOT work -- both `fnum` and
`fnum-1` flag a whole population of correct lines, because the draw and the
readout straddle `frame_start` differently per line. The row is
`STALELN:AGE:CNT` = {last stale line, frames behind its neighbour, count}.
It reads `00000000` on three pixel-perfect frames in the bench; its positive
behaviour is untested until the board reads it at the boss.

### Zone injector: reaching the zone 2 boss on demand (built and DEPLOYED as `04074618`)

Save states MAME-style are a large project (no `ss_*` bus in this `sys/`, two
VHDL 68k's with no state export, ~22 RAMs). Instead: **start the game at
zone 2.** Found in MAME with `tools/mame/`: the zone word is `0x402312/13`,
written at new-game init by **ROM 0x004810 as the constant 1** and consumed
by the stage loader in the same frame -- so holding the byte once a frame did
nothing (proved: 0.0 % pixel difference), while substituting the value AT the
write loaded zone 2 (44 % differs). The core does the same at bus level in
`rf_main`: a 16-bit CPU store of `0x0001` to RAM word `0x1189` (0x402312 and
its mirror) is rewritten to `{8'h00, zone}` while `zone_inj != 0`. Zone clears
write 2,3,4 and pass; game over -> new game -> 1 -> substituted again.
Armed by MRA index 1 bits **[4:3]** (spare): 1..3 = zone 2..4.
`releases/experimental/Ray Force (zone 2).mra` carries `08`.

### The fetch self-check: BUILT, not queued

If STALELN reads zero at the boss, the two-layers theory dies and the specks
point at the FETCH. Every 16th cache hit is re-fetched from SDRAM and compared
against the cached copy -- ROM is immutable, so any difference is fetch
corruption, counted on the page. **This shipped**: it is in `rf_spr_gfx_bus`,
wired through `rf_video_spr` (`fetch_bad`, summed over both buses) and
`rf_video_pipe` (sat8 into the top byte of `SPRFETCH:ROWMAX`), benched
pixel-identical, and is live in builds `03232713` and `04074618`. It reads
`00` in simulation because the SDRAM model is exact, so **the board is its
only judge** -- as it is for the stale detector. Neither instrument has a
positive control.

### Debug removed to make room

Write ring 2048 -> 512 entries (~8 M10Ks, still a full trigger window); the
per-line fold instrument and its M10K (job done); `SPIN:TWRA:TWRB` row given
to `STALELN:AGE:CNT`. `RESOURCES.md` now documents the whole budget.

---

## 2026-09-02/03 — Four builds overnight: the palette exonerated, the Ray Force bottleneck identified, and the OSD found unreachable

**Deployed: `02230245` (build D).** Timing met, worst slack +0.064 ns, ALMs
97 %, LABs 4,183/4,191, M10K 549/553.

### The builds

| | stamp | contents | result |
|---|---|---|---|
| A | `02205428` | penmask 5->6 bit fix, triggered write ring | timing met +0.013 |
| B | `02214052` | + sprite tile-row cache | HDMI PLL -0.514 (seed 5) |
| C | `02222040` | + MRA-driven `uart_mode`, ring arms late, **seed 8** | timing met +0.124 |
| D | `02230245` | + transparent-quad skip | timing met +0.064 |

All four are in `builds/`. Seed 8 is the one that closes the framework HDMI
clock: the same design missed by -0.514 on seed 5 and makes +0.124 on seed 8,
which is the third time that clock has proved to be fitter variance rather
than a real path. **Both core clocks were healthy throughout** (clk_sys
+1.15 to +1.24, clk_ram +1.13 to +1.16); only the framework clock ever moved.

### The palette is correct, and this is reference-based rather than inferred

The write ring captured a contiguous 1024-entry palette burst off the board,
reconstructed to RGB (`word0[7:0]`=R, `word1[15:8]`=G, `word1[7:0]`=B, the
order `rf_video_mix` reads) and diffed against MAME's `paletteram.bin`:

```
vs dump/dg5070   1023/1024 identical
vs dump/dg864     1012/1024      <- a DIFFERENT SCENE, not an error
```

The single differing entry, `0x129E`, is animated and differs between every
pair of MAME frames too. **So the CPU writes the right palette data.** With
the index composition already matching the model (`base|pen`,
f3_render.py:781 against rf_video_spr.sv:929/978), the palette path,
the CPU and the mixer are all cleared. **What remains is the PEN** -- the
sprite graphics data itself, i.e. the fetch path.

Note this also kills the palette-copy-queue theory properly. An earlier
14-second capture showed `twr_a_cnt`/`twr_b_cnt` parked at 160/216 and that
was read as "frozen, so the copy ran once". They actually **saturate at
0xFF**: the writes are continuous and the window was simply too short. A
counter that has not moved in 14 seconds has not been shown to be frozen.

### Ray Force's heavy lines are pixel-bound, and that is the whole story

Measured on hardware, Ray Force attract:

```
worst sprite line   14,676 clocks     budget 3,456
rows on that line      784
longest single fetch      87 clocks   (22 in the bench)
late lines          climbing ~56/s, never settling
records dropped            0
```

784 rows x 16 pixels = 12,544 pixels in 14,236 clocks = **1.135 clocks per
pixel**. `rf_video_spr.sv`'s `dr_xx` advances one pixel per clock, sixteen a
row, whether or not the pixel draws anything. To fit the budget needs 0.276
clocks/pixel, i.e. **~4 pixels per clock**. Fetch bandwidth cannot touch it.

Two fixes went in and both were aimed at the wrong bottleneck for these
lines:

```
                          worst line   note
baseline                     14,676
+ tile-row cache             14,236    3 %
+ transparent-quad skip      13,781    3 %   (6 % cumulative)
```

**The cache is still worth having** -- in simulation it cuts a *fetch-bound*
line by 49 % at board-like latency (6,493 -> 3,325 clocks at LAT=90) and
drops latency sensitivity 3.4x, matching the offline prediction exactly. It
just is not what breaks a boss line. The benches never showed this because
their heaviest dumped line is 114 rows (fetch-dominated) while the board's is
784 (pixel-dominated): **no bench in this tree reproduces the failing
regime.**

### The tile-row cache (rf_spr_gfx_bus)

256 sets, direct mapped, one per fetch bus. Direct mapped because it reaches
the fully-associative bound on every frame measured, and 256 deep because an
M10K is width-limited -- a 96-bit memory costs three blocks whatever its
depth, so a shallower cache wastes them. Costs 8 M10Ks total.

It is the safest cache that can be built here: **sprite graphics live in ROM
and never change**, so there is no invalidation, no coherency and no frame
boundary to get wrong -- the failure mode this project keeps hitting. The
only state needing a clear is the valid bits, once, at reset (256 cycles,
`busy` held).

Verified transparent across the whole suite: `pipe`, `spr`, `mix`,
`spr-line`, `spr-ghost`, `spr-all`, `ear-mix`, `line`, `pf`, `pipe-lat`, and
`mix-all` at **20/20 frames / 1,433,600 pixels identical to MAME**.

### The OSD is unreachable, and the MRA config byte is the way in

`config/Rayforce.CFG` does **not** reach the core's status word. Tested end
to end on `02205428`: wrote byte 0 = `0x20` (UART Debug = Write Ring) and
byte 1 bit 6 (Flip Screen), reloaded with `load_core`, read the file back and
confirmed it held `2050`. The UART kept emitting the self-test page and the
screenshot came back the right way up. **No status bit arrived.** With pad
input also dead (`tools/rf_input.py` is enumerated and ignored), no OSD
option is reachable on this board at all.

MRA config bytes *do* arrive -- the board picks its game id, visarea and
extend from them. So `uart_mode` now takes **index 2 bits [7:6]** when
non-zero and falls back to `status[5:4]` otherwise. No MRA written before
tonight carries an index-2 region, so none change meaning.
`releases/experimental/Darius Gaiden (write ring).mra` selects Write Ring;
that is how the 17,994-write palette capture happened.

### A latent bug fixed: the pen mask was one bit too narrow

`rf_video_spr_list.sv:92` assigned a 6-bit expression into a 5-bit port:

```
output logic [4:0] o_penmask;              // too narrow
assign o_penmask = {extra, 4'h0} | 5'h0F;  // {2 bits, 4 bits} = 6 bits
```

MAME's mask is `(extra_planes << 4) | 0x0F` with `extra_planes` 0..3, so it
reaches `0x3F`, and F3 sprite graphics are 6bpp. The top bit was dropped:
`extra=2` produced `0x0F` instead of `0x2F` and `extra=3` produced `0x1F`
instead of `0x3F`, masking away the two upper colour planes. Widened to 6
bits through `o_penmask`, `wk_penmask`, `penmask_r`, `dr_pen` and both
comparisons.

**Latent, not the tower bug.** Every one of the 150+ dumps in this tree uses
`extra` 0 or 1, which fit in five bits, so no bench covers it and no shipped
game shows it. It will bite the first F3 game that uses the upper planes.

### What is NOT established: that the cache fixes the Darius colours

One confirmed Zone A frame **with** the cache renders blue-grey steel towers;
two confirmed Zone A frames on `02193638` **without** it render red. But
`02193638` differs from the cache build by more than the cache, so the
control needed was build A (penmask fix, no cache) -- and **164 samples
across three capture runs never reached the Zone A demo**, so there is no
matched control. With board input dead it cannot be forced either.

The screenshots are real; the causal claim is not. Note also that the
aggregate metric used at first ("0.3 % red-ramp with the cache against 22 %
without") was comparing capture sets that mostly did not contain Zone A at
all -- the same class of error as the two instruments that measured their own
artifacts. **A scene-blind aggregate over an attract loop is not evidence.**

### Process rule, learned the hard way

**Do not edit RTL while a Quartus build is running.** Sources are read during
Analysis & Synthesis (~6 minutes) and an edit landing inside that window
leaves it unknowable what the bitstream contains: build C's
`rf_video_spr.sv` was written at 22:25:24 with synthesis finishing at
22:27:20, and the reports cannot settle it -- internal wire names
(`cfg_uart`, `dr_skip4`) do not appear in `map.rpt` or `fit.rpt` at all, so
grepping for them proves nothing either way. Wait for `Analysis & Synthesis
was successful` in `/tmp/rayforce_build_progress.log`, or stage the change in
a scratch copy.

Also: **`build_seeds.sh` is stale and hazardous.** It still uses
`MemoryHigh=11G MemoryMax=11G`, the settings that got builds killed. Set
`SEED` in `Rayforce.qsf` and go through `build.sh`, which carries the correct
8G/9G caps. Builds actually peak **7.6-7.8 GB** (from the systemd scope
accounting in the journal), not the ~4.5 GB previously recorded, and take
**38-43 minutes**. The machine has 15 GB and 512 MB of swap; a browser at a
7.3 GB peak alongside a build is what locked it up on 2026-09-02 at 18:24 and
cost a build at 29 minutes in.

### Open, in the order worth attacking

1. **Ray Force: multi-pixel-per-clock draw.** The only thing that fixes a
   784-row line. Touches the write path (`u_lbuf`, 16-bit single-write-port),
   the DDR3 packer's read side (`w_acc <= {lb_q, ...}`, also one pixel a
   clock) and the fold diagnostics. **Beware:** a multi-write line buffer is
   exactly the inference trap that produced the sprite splits, and a 2-pixel
   word only aligns at 1:1 zoom. Develop it against the benches and build
   only once simulation is clean.
2. **The Darius pen, i.e. the sprite gfx fetch.** Everything else in that
   path is now cleared by measurement. Suspects: `rf_spr_ch_share`'s own
   header warns that re-granting a plane double-toggles its completion and
   "permanently desyncs the edge detector"; and every clk_sys<->clk_ram path
   is `set_clock_groups -asynchronous`, i.e. wholly unconstrained, with
   `rf_spr_gfx_bus` admitting its data capture "passed or failed by fitter
   seed" at two sync stages.
3. **A controlled Darius A/B**, which needs a way to reach Zone A on demand.
   Board input is dead; either fix that or find an MRA/config route.
4. `ear-spr-line-all` frame 4200 reports 8 used-flag diffs. **Pre-existing**
   -- identical with the cache reverted, same cycle count -- but unexplained.

---

## 2026-09-01/02 — Darius Gaiden's sprite colours: measured to the sprite framebuffer's read side, cause still open

**The symptom.** Zone A on the board draws the two big foreground tower
sprites solid red and gold where MAME has blue-grey steel. Everything else on
the screen is right.

**Matching the frame.** The board cannot be told what frame it is on, and
`tools/rf_input.py` no longer drives it (the uinput keyboard is enumerated and
ignored — coin and start do nothing on Ray Force either), so the scene came
from the user pausing in Zone A. A dense MAME capture of Zone A and a
brute-force exact-pixel search (`tools/rf_match_frame.py`, new) put the paused
frame at **MAME frame 972**, a sharp peak at 35 %.

**What the diff said.** 64.9 % of pixels differ and **100 % of the differing
pixels are inside sprite layers**. pf2, pf3 and the pivot/text HUD are
pixel-identical. Sprite silhouettes overlap MAME's 97.7 %, so the list walk,
positions, zoom and tile codes are right and only the colours are wrong. Some
board colours (`#830303`, `#C30303`, `#BB5323`) are not palette entries at all.

**Why no bench could find it.** Every off-board check is clean, on the exact
frame the board gets wrong:

- the Python model is 0/74240 against MAME on three Zone A frames
- the RTL sprite list walker is 320/320 (with `vis_mode=3` — `sim/spr_tb.cpp`
  never drives that port, so `make spr` silently judges every game against Ray
  Force's 31..254 window and scored this frame 50/320)
- `pipetb` is **74240/74240 identical to the model**, at `F3_DDR_LAT` 40..400,
  `F3_DDR_BUSY` 7..2 and `F3_SPS_LAT` 24/34
- the MRA's four graphics regions are byte-identical to MAME's own

**So the build had to make the board talk.** `SPRPIX WR:RD` sums the same
pixels either side of the DDR3 round trip — `lb_q` as the writer streams a
finished line out, `rd_color` as the mixer reads it back — with the write side
delayed one frame so both halves describe the same DRAWN frame, which is what
makes the row readable on a moving picture instead of only on a paused one.
`tools/f3_sprfold.py` predicts what it must read; the RTL matched it exactly in
simulation on three frames (Ray Force 1800 `7667`, dg972 `4325`, dg5070
`fdda`) BEFORE the build shipped, so a deviation on the board could only be real.

**The reading that settled it.** On a still picture the write side repeated
`0x76E0` eleven times while the read side never once matched it, alternating
between `0x1B75` and `0x88CD`. A still picture makes any frame offset
irrelevant, and a read fold ABOVE the write fold cannot come from dropped
lines — only from reading content that was never written. Two other stable
scenes round-tripped 3/3 exactly.

**Where it is NOT.** Two theories died to the boards' own numbers rather
than to argument:

- *The sprite draw overruns its line budget and the banks swap under it.*
  `draw_unfinished` reads **0**: the draw always finishes all 256 lines, so
  the overrun (`SPRLINE : LATE`, 38485) is not the mechanism. The OSD sprite
  row cap built to test it is tied off rather than deleted.
- *The prefetcher wraps NRB lines round onto the line being displayed and the
  mixer composes a mix of two lines.* `defer_cnt` reads **0**, and the window
  condition proves why: refilling slot L%NRB happens at `nf = L+NRB`, which
  `nf < rd_line + NRB` only allows once `rd_line > L`. The `buf_ok` clear that
  came out of this is kept as the invariant the module should have had, but it
  is not the fix.

**AND THEN THE INSTRUMENT MEASURED ITSELF.** This is the part worth keeping.
`SPRPIX WR:RD` reset its read accumulator at `frame_start` (raster 260), but
the mixer composes line L during raster L-1, so line 255 is composed at raster
254 while the `rd_line` 255->0 wrap is at raster 261. The reset fell between
them and cut line 255 out of the read side alone. The f3_224a sprite cull
stops at line 254 and f3's runs to 255, so ONLY visarea-f3 games have content
there -- and the artifact produced a perfect, causal-looking split:

```
Ray Force         f3_224a   296/296  100 %
Bubble Bobble II  f3_224a   291/291  100 %
Darius Gaiden     f3        146/192   76 %
Elevator Action   f3         94/176   53 %
Darius Gaiden     vis 3->0  167/167  100 %   <- one MRA config bit
```

Every one of those numbers is real and every conclusion drawn from them was
wrong. What caught it: the per-line version flagged exactly ONE line, 255,
while the same bench run rendered **74240/74240 identical to the model,
including line 255**. Correct pixels and a raised flag cannot both be right.
Re-keying the boundary to the `rd_line` wrap makes the bench read 0 bad lines
for Darius on f3, EAR on f3 and Ray Force alike.

**The lesson, since two builds went into it:** a diagnostic that straddles a
frame boundary has to use the boundary the measured quantity actually has --
for anything the mixer produces that is the `rd_line` wrap, not `frame_start`
-- and a new counter must be cross-checked against something already known
good. The pixel count was sitting right there saying the flag was false.

**Where that leaves the bug — measured, build 02005337.** The corrected
per-line row on hardware, Darius Gaiden, 295 samples over 140 s:

```
frames with NO bad line   249 / 295   (84 %)
18190002  n=22   lines 24-25    count 2
FFFF0001  n=12   line  255      count 1
18FF0002  n=6    lines 24..255  count 2
18FF0003  n=4    lines 24..255  count 3
18180001  n=2    line  24       count 1
```

Every flagged line is 24, 25 or 255 — the first and last lines that carry
sprites at all under visarea f3 (the cull runs 24..255), and they may yet be
an edge effect in the comparison rather than a fault. What matters is what is
NOT there: the body of the screen, which is where the red tower sprites are,
is never flagged in 295 samples.

**So the DDR3 round trip is exonerated for the region that is wrong.** The
mixer receives exactly what the draw wrote there, which means the pixels were
already wrong when the draw wrote them. The instrument was calibrated for this
verdict: with `F3_DDR_CORRUPT=1` it reports 232 lines (24..255) and the
picture collapses to 29053/74240, while at 1-in-200 the CRC-and-refetch
machinery repairs everything and it correctly reports zero.

**Next, and it needs a Zone A frame.** `wl_acc` is the DRAW's own per-line
fold. `tools/f3_sprfold.py` can produce the model's per-line folds for a
dumped frame, so comparing the two names exactly which lines the draw got
wrong — and from there the suspects are the sprite gfx fetch under real
SDRAM contention (board fetches take 84 clocks against 22 in the bench, and
`rf_spr_ch_share` warns in its own header about desyncing a plane's
completion) and the pen/colour composition. Reaching Zone A needs the user to
play and pause; the attract loop only ever reaches Zone E.

---

## 2026-08-30 — What MAME does not emulate, and what this core does not inherit

Research note, so the next session does not repeat the search. Sources are
`reference/mame/` on disk (not in git) and MAMETesters, checked 2026-08-30.

### The one that reaches ordinary play: MAMETesters 08230, OPEN

**"gunlock, rayforcej, rayforce: Missing transparent shadows in Area 4."**
Still open. The reporter's analysis names the same field this core already
flags as unread: bit `x8xx` of the 0x6400 section of line RAM. Their findings,
worth keeping because they are more than MAME's source says:

- it offsets a palette, and only on playfield 4
- the offset respects the tile's depth: +0x10 for 4bpp, +0x40 for 6bpp
- it is masked by the layer beneath (possibly only by playfield 1), so on real
  hardware it renders only where an upper layer exists, while in MAME it would
  affect every pixel

So **Area 4 of a normal playthrough is a place where "pixel-identical to MAME"
and "identical to the arcade board" are known to differ**, and the difference
is missing shadows. This belongs in the README's user-facing list, not only in
the inherited-uncertainty paragraph, and it now is.

### The rest of this game's tracker history

| MAMETesters | State | Here |
|---|---|---|
| 07861 sound glitches after the first game over | **open** | Named in MAME's own `es5510.cpp` header. The ESP is a stub here. |
| 01920 enemy laser too short in stage 3 | fixed 0.203 | Fixed by a **68020 CMP2 opcode** correction. We run TG68K, not MAME's core. TG68K does implement CMP2/CHK2 (`TG68KdotC_Kernel.vhd`, with dated bugfixes through 2020) -- but stage 3 has never been played on this core, and it is the direct test. |
| 02527 square glitches on the title screen | fixed 0.266 | PR #11811, the video rewrite this core is written against. Should not appear; the title screen is in the dumped frames and is exact. |
| 06794 screen flickering | closed, not a bug | 58.97 Hz game on a 60 Hz display. Relevant to the OSD Refresh Rate option before anyone blames the core. |
| GitHub #10033 EAR: shooting ceiling lamps should darken the floor | closed | The reporter traced it to brightness values written to line RAM 0x6200, nibble-per-layer, "lights off" = 0xCBFB. Unemulated in MAME; would matter if Elevator Action Returns is ever finished. |

### Unemulated in MAME, therefore unverifiable by diffing against it

From `taito_f3_v.cpp` unless noted:

- `0x0800` sets the VRAM layer opaque -- *[unemulated]*
- `0x2000` enables "garbage pixels" for the line -- *[unemulated]*
- `0xf000` palette RAM format -- *[unemulated]*
- `0x6600` bg palette, `0x7000` "pivot enable" -- *[unimplemented]*, both logged
- 12-bit palette games are a hardcoded per-game list with a
  `TODO: seems to be selected on a line basis by 6400?`
- the pixel layer's palette mirroring is an explicit **HACK** keyed off the
  scroll offset, with a comment admitting it should dirty the layer and does not
- `TODO: determine when we can stop drawing?` in the sprite walk
- `TODO: presumably "sprite lag" is timing of sprite ram/framebuffer access` --
  i.e. the lag values this core copies are themselves a guess in MAME
- `taito_en.cpp`: *"ES5510 ESP emulation is not perfect"*, `TODO: ES5505
  Volume control is correct?`, and "where does the MB8421 go?"
- `es5510.cpp`: DRAM size unverified
- `taito_f3.cpp`: `TC0650FDA` "Digital to Analog -- Blending and RGB output"
  is listed as a board chip and modelled as no device at all; `TC0640FIO` has
  a TODO to use the shared implementation

### What this core has that MAME does not

Being accurate matters here: **this core is a subset of MAME's behaviour, not
a superset.** Every graphics feature was ported from MAME and checked against
it, and the things above are unemulated in both. Two real exceptions:

1. **The analog output stage.** `taito_f3.cpp` line 2355: *"Sound volume
   regulation output is gained via common analog operational and power ic
   amplification (LM324 and 1241). In test mode, digital regulation hasn't
   effect, due to obvious reason."* MAME emulates to the MB87078 and stops,
   leaving the rest to the host volume control. The board's own digital
   output measures **-33.5 dBFS peak**, which is why both games sound almost
   silent. Audio Boost is the stand-in for that missing amplifier -- not an
   arbitrary loudness preference, a named component.
2. **Real fetch timing.** MAME renders a frame in one pass with no memory
   model at all. This core has a raster, a line-buffer ring and a finite
   SDRAM budget, so it can miss a per-line deadline in a way MAME cannot.
   That is not extra fidelity: it is a constraint the arcade board met and
   this implementation does not yet, and it is Known problem #1.

One deliberate divergence: MAME's several-inverted-clip-planes case is not
reproduced (`rf_video_mix.sv`). Ray Force never enables a clip plane.

### What this changes about the release

"Video pixel-identical to MAME" stays true and stays the strongest claim
available, but it is now bounded in writing by a *named, open* MAME bug in a
scene players reach. The README says so.

---

## 2026-08-30 — The board's verdict on ch7: two of three fixes land, one is wrong

Build `29224005` (timing met on every clock; worst +0.011 ns on the HDMI
framework clock, clk_ram +1.056, clk_sys +1.648; ALM 91 %, M10K 541/553,
LAB 99 %). `rec` stayed in MLAB after the widening -- checked in the Fitter
RAM Summary, which was the one real risk in the run-length change.

### What worked

**Sticky self-test verdicts.** 63 page passes: 28 samples of
`MAXFETCH:BUILD 00000111` and 27 of `TILE NZ:PF:PAL 00009FFF` -- the
blank-frame values -- and **not one reported FAIL**. Those same values were
FAILs before. Confirmed on hardware.

**Run-length records.** `SPR REC : DROP 19750000`: **peak 6,517 records, 0
dropped**, 53 % of the 12,288 store, on a scene busier than any dump. Before:
10,714 rows, 87 %. Confirmed on hardware.

### What did not: ch7

    before (one channel)   SPRLINE : LATE  3EBF03D5   16,063 clk,   981 late (static)
    after  (ch4 + ch7)     SPRLINE : LATE  39D9074E   14,809 clk, 1,870 late (climbing)

Late lines went 935 -> 1,870 *within one 30 s capture*, and the longest line
improved 8 % where the bench had predicted about 2x.

**The cause is a mistake in the change itself.** `ch7` was placed immediately
below `ch4` in the fixed-priority scan, on the reasoning that this left the
sprite path's standing against the CPU and playfields unchanged. It does --
but it does not leave the two sprite buses equal, and they must be. The draw
consumes their records in **strict alternation** (`q_cs` in `rf_video_spr`),
so a record from the fast bus cannot be drawn out of turn and the **slower
bus gates the pair**. Bus B, served only when bus A is not asking, runs
systematically behind. The single `rf_spr_ch_share` these replaced
round-robins its four ports, so it was already fair: the change swapped a
fair channel for an unfair pair.

**The bench could not have caught it, because the bench asserted the thing
that was false.** `pipe_tb` drove both sprite channels from one `lat_sps`.
That symmetry was an assumption written into the bench, never measured from
the controller. `F3_SPS_LAT_B` now models the two separately, and the
asymmetry costs far more than the mean latency predicts (frame 2930):

    A=90  B=90    exact          mean  90
    A=90  B=135   exact          mean 112
    A=90  B=180   67276/71680    mean 135  <- symmetric 135 is EXACT
    A=60  B=240   62549/71680    mean 150  <- worse than 90/90, faster bus A

The lesson generalises past this bug: a bench knob that collapses two
distinct hardware quantities into one variable cannot fail on their
difference. It is the same shape as the visarea that was hardcoded in
`pipe_tb` and hid the sprite cull bug.

### Fixed in the tree, not yet built

1. **`rf_sdram.sv`: `ch4` and `ch7` alternate.** Whichever was served last
   yields to the other; `spr_tog` carries it. Priority against every other
   client is unchanged.
2. **`rf_selftest.sv`: `SPRLINE : LATE` is judged on late lines.** The old
   criterion also demanded the longest line be under one line's 3,456-clock
   budget, so the board read `39D90000` -- 14,809 clocks with **zero late
   lines** -- as FAIL. That is wrong by design: the ring of 8 exists so a
   line can run over budget and still be drawn in full. The ceiling is now
   the ring's own 27,648, which is the point past which no amount of banked
   slack covers a line.

### Does any of this apply to Elevator Action Returns?

Measured, not assumed (`F3_VIS=f3 tools/f3_rec_count.py dump/ear`):

| Change | Applies to EAR? |
|---|---|
| `ch7` + the fair arbiter | **Yes, fully.** The controller and the sprite fetch path are game-independent, and EAR's sprite load is comparable (264 sprites / 4,088 rows at peak in its dumps, against Ray Force's 305 / 4,808). |
| Sticky self-test verdicts | **Yes.** EAR has blank frames of its own (598-600, 1798-1800, 2998-2999 carry no sprites at all), which is exactly what used to false-FAIL. |
| `SPRLINE` ceiling of 27,648 | **Yes.** Both games run a 262-line raster, so the per-line budget and the ring are the same. |
| Run-length records | **Correct for EAR, but worth nothing to it.** |

That last row is the interesting one. **EAR's rows/run is 1.00 on every
dumped frame but one** (3598, at 1.05): it does not y-shrink its sprites,
where Ray Force shrinks heavily and reaches 3.25. So the compression that
took Ray Force from 87 % to 53 % of the record store does nothing for
Elevator Action.

**Which makes EAR, not Ray Force, the game that now sits closest to
overflowing the store.** Its dumps peak at 4,088 records with no compression
available. If its real play is ~2x its dumps -- the ratio Ray Force showed
between dump (4,808 rows) and board (10,714) -- EAR would land near 9,000 of
12,288. Nothing has dropped a record yet in either game, and `SPR REC : DROP`
is the watchdog, but if `NREC` is ever raised it will be Elevator Action that
forces it, not Ray Force.

One tooling note: `tools/f3_rec_count.py` follows `f3_render`'s `F3_VIS`, and
its default is Ray Force's window. Counting an EAR dump without `F3_VIS=f3`
silently drops the 8 lines outside it -- the same trap as the hardcoded
sprite cull bounds.

---

## 2026-08-29 — The sprite fetch path: one SDRAM channel per bus (uncommitted)

**This is the "SPRITE FETCH note" the comments in `Rayforce.sv`,
`rtl/rf_sdram.sv`, `sim/pipe_top.sv` and `sim/Makefile` point at.**

Known problem #1 — sprites missing from busy scenes — was caught in the act,
and it is a **latency** defect in the sprite graphics fetch, not the
fetch-bandwidth ceiling the README used to guess at.

### What the board actually did

Attract was left running on the board and screenshotted every six seconds
(`screenshots/glitch_board/`); MAME was dumped over the same sequence
(`screenshots/mame/`, `dump/rf_glitch/`), and frames 2928-2930 were then
dumped in full so the bench could reproduce that instant. The board's
`t062.png` and MAME's frame 2930 are the same moment of attract. Diffed
pixel for pixel:

    1,124 differing pixels out of 71,680
    every one of them on rows 210-223 -- the last 14 lines of the visarea
    rows 0-209 pixel-identical

That shape *is* the diagnosis. A rendering bug does not stop at row 210. And
the bench renders the same frame **71,680/71,680 exact**, so nothing about the
picture is wrong: the sprite draw ran out of time partway down the frame and
the run-ahead ring never recovered before the frame ended.

Reproduce the diff:

```sh
python3 tools/rf_argb2png.py dump/f3_02930_frame.argb /tmp/mame_2930.png
python3 - <<'EOF'
from PIL import Image; import numpy as np
b=np.array(Image.open('screenshots/glitch_board/t062.png').convert('RGB')).astype(int)
m=np.array(Image.open('/tmp/mame_2930.png').convert('RGB')).astype(int)
d=(np.abs(b-m).sum(axis=2)>0); r=d.sum(axis=1)
print(d.sum(), 'px on rows', [i for i,v in enumerate(r) if v])
EOF
```

### Why the draw was slow: four bursts, strictly serial

The sprite engine runs two fetch buses (A and B) taking alternate records, and
each record needs two graphics planes — four plane requests outstanding at
once. All four shared SDRAM `ch4` through a single `rf_spr_ch_share`, and **a
sharer holds exactly one burst outstanding**. So the four bursts were served
one after another with nothing overlapped, and a line's draw time came to
(bursts × round trip): linear in the fetch latency with a slope of one full
round trip per burst, which is the signature of zero overlap.

Note what was *not* wrong, and still is not: `SPR REC : DROP` stays at zero.
The sprite list and the record store built every row the frame asked for. It
is only the per-line fetch and draw that missed the deadline.

### The bench had to be taught to model it — two separate fixes

**1. `F3_SPS_LAT`.** `pipe_tb`'s positional `lat` argument slows *every*
channel. On the board the playfield planes are `ch1`/`ch2`, the controller's
top two priorities, while the sprite planes sat on `ch4`, fifth of six — so
the sprite path waits several times longer than the playfields do. Slowing
everything breaks the frame *everywhere* instead of at the bottom, where the
board breaks it, so the old knob could not reproduce this at all.
`F3_SPS_LAT` is the sprite channel's round trip on its own.

**2. `F3_FRAMES`.** The pipe's own `SPRLINE : LATE` counter is peak-held and
only begins accumulating once `warm` reaches 15 (`rf_video_pipe.sv:280,405`),
i.e. from the 16th frame. **On the default 3-frame bench run it reads zero no
matter what is happening.** Every "the bench reports zero late lines" reading
before today was taken that way and meant nothing. `F3_FRAMES=20` or more is
required. With the VRAM static, every extra frame is the same frame again,
which is exactly what a steady-state timing reading wants.

### The fix

One SDRAM channel per fetch bus: bus A keeps `ch4`, bus B gets the new `ch7`.
Two `rf_spr_ch_share` instances, two planes behind each, so the two records
overlap instead of queueing. `ch7` sits immediately after `ch4` in the
arbiter — the scan is now ch2, ch1, ch3, ch5, ch4, ch7, ch6 — so the sprite
path's standing against the CPU (`ch3`) and the playfields (`ch1`/`ch2`) is
unchanged. The one client that did move down is `ch6`, the ES5505 sample
fetch, which now sits behind two sprite channels rather than one; it was
already last and its occupancy is ~10-15 %, but that is untested on hardware.

### Measured on frame 2930

Sprite-channel round trip (`F3_SPS_LAT`, ram clocks) swept against the longest
single sprite-line draw, the late-line count and the picture. `F3_FRAMES=20`
throughout, so the peak-held late counter is actually accumulating:

```
    lat   longest     late   pixels-exact
--- ONE shared channel (ch4 only, the committed wiring) ---
     14      1351        0    71680/71680
     40      3124        0    71680/71680
     60      4495        0    71680/71680
     70      5199        0    71680/71680
     75      5551       40    71151/71680
     90      6607      305    67325/71680
    130      8549      670    62499/71680
--- TWO channels (ch4 + ch7, the change under test) ---
     14      1314        0    71680/71680
     40      1973        0    71680/71680
     60      2655        0    71680/71680
     70      2996        0    71680/71680
     75      3151        0    71680/71680
     90      3678        0    71680/71680
    130      5065        0    71680/71680
    135      5227        0    71680/71680
    140      5417       30    71376/71680
```

Three things to read out of it.

**The draw time is linear in the fetch latency, and the slope halves.**
Between lat 14 and lat 130 the longest line grows by 62.1 clocks per clock of
round trip on one channel and 32.3 on two — a ratio of 1.92. A slope that is
*proportional to the number of bursts* is the signature of zero overlap; that
it halves is the change doing exactly and only what it was meant to do.

**The headroom roughly doubles.** How much round trip frame 2930 survives
before a single pixel goes wrong: **70 ram clocks with one channel, 135 with
two** (ratio 1.93, matching the slope). That is where `spr-lat`'s `SPS_LAT`
default of 130 comes from — comfortably inside what is verified, and not
claiming margin that is not there.

**The budget is not the deadline.** A line is allotted 3,456 clocks, but the
ring of 8 banks seven spare lines on top of it, so the longest line can run far
past 3,456 with nothing late and the picture still exact — one channel at lat
70 draws a 5,199-clock line and is still 71,680/71,680. Late lines start when
*runs* of heavy lines drain the ring, which is why the failure appears at the
bottom of a frame rather than wherever the single worst line happens to be.

### What this does NOT establish

- **It has never been on a board.** No bitstream contains it. `./build.sh` was
  launched at 16:05 on 2026-08-29 (stamp `29160539`) and was interrupted
  during synthesis — `db/` holds the half-finished `quartus_map` output, there
  is no `output_files/`, and the newest bitstream in `builds/`
  (`Rayforce_29074637.rbf`) predates the change. The build must simply be
  re-run; it starts with `rm -rf db incremental_db output_files`, so the stale
  half-build costs nothing.
- **The bench does not reproduce the board's failure geometry exactly.** The
  board loses rows 210-223 and nothing else. The one-channel bench at lat 75
  loses rows 169-174; at lat 80, rows 167-223. Same character — bottom-of-frame
  sprite loss that spreads upward as the fetch slows — but the bench models a
  constant round trip, where the real controller's is bursty and contended.
  Do not read the bench's `lat` as a calibrated measurement of the board.
- **`ch6` moved down a place** and the sound path has not been re-measured
  against MAME since. The Audio Ring correlation (1.000) predates this change.
- **Timing closure is unknown.** An extra channel widens the controller's
  arbiter and adds a 64-bit output register; the qsf seed was also changed from
  11 to 7 in the same edit, so a failed fit will need both untangled.

### Regression status of the change, in the tree

    make -C sim pipe-all     19/19 frames, 71,680/71,680 each   (unchanged)
    make -C sim spr-lat      frame 2930 exact at SPS_LAT=130

### The next step, precisely

Re-run `./build.sh`, deploy, leave the core in attract for two minutes or more,
and read `SPRLINE : LATE` off the self-test page. Before this change the same
reading was `3EFA182E` / `42C910A7` — around 6,000 late lines with the longest
line near 16,000 clocks. That row, not the bench, is what closes Known
problem #1.

---

## 2026-08-29 — Two more findings from the board, both in the tree for the next build

Read off build `29101900` running attract, 95 page passes over 45 s.

### Self-test rows that failed on blank frames (fixed: `rf_selftest.sv`)

`FETCH : PIX NZ`, `MAXFETCH:BUILD` and `TILE NZ:PF:PAL` are latched once per
frame by `rf_video_pipe`, and a frame with no playfield on it -- the notice
screen, a scene cut, the black frame between attract loops -- has zero tile
fetches, zero non-zero tiles and no longest fetch, legitimately. The bench
confirms it: frames 300 and 900 give `dbg_nz = 000000ff`. Judged frame by
frame the rows said FAIL on every such frame (3 of the 95 passes), which is a
diagnostic that teaches its reader to ignore red. HANDOFF had already called
this "the known text-only-frame artefact" on 2026-08-27 and left it.

Now the verdicts latch: PASS the first frame the condition holds, BUSY until
then (the same idiom as the VIDEO RAM WRITES rows), cleared whenever the CPU
is not running so a re-download starts the proof over. The *values* stay
per-frame, so a blank frame still reads as blank on the page. MAXFETCH:BUILD
also carries a real limit -- longest playfield build under the 3,456-clock
line budget -- and that latches the other way: one frame over budget is FAIL
from then on, peak-held like the sprite rows, because the page is read twice
a second and a one-frame overrun would otherwise never be seen.

Not benchable (no bench instantiates `rf_selftest`); Verilator lint clean.
The check on the board: leave attract running through a scene cut and the
three rows must stay PASS.

### The sprite record store: 87 % full, then run-length records (implemented)

`SPR REC : DROP` read `29DA0000` for the whole capture: **peak 10,714 rows in
a frame, 0 dropped**, in a store of 12,288. `rf_video_spr.sv` said 12,288
"leaves ~45 % over that peak" -- true of the 8,296 it was written against,
and 13 % now. Overflow drops rows from the *last lines* of the frame, which is
the same visible symptom as the sprite fetch running late, so this is worth
knowing before blaming the fetch path for a missing bottom edge.

**Growing the store was ruled out** -- it is 2 x 384 = 768 MLABs already
(32 x 20-bit MLABs), 16,384 would be 1,024, the fitter has died once at ~960
in this design, and M10K is no alternative (24 blocks a bank, ~26 free).

**What was done instead: a record is now a RUN, not a row.** A sprite is one
16 x 16 tile and the expand used to emit one record per source row landing in
range. A y-shrunk sprite lands several of its 16 rows on the same screen
line, and the draw lays those rows down back to back in the same order
either way -- so the run of consecutive rows on one line is one record:

    {sidx[9:0], srow_a[3:0], srow_b[3:0]}   18 bits, first and last source row

Direction is implied (`b > a` under flip-y), 18 bits still fits the 20-bit
MLAB word, so the store's cost is unchanged and every slot holds 1-16 rows.
The draw issues one fetch per row stepping `a -> b`, and advances `fc` only
on the last, so the two-bus alternation and the overwrite order are
untouched -- which is why the picture is identical by construction and not
by luck. One row-step macro (`RUN_STEP`) is shared by pass 1 and pass 2 so
they cannot disagree about where a run starts and ends.

How much it buys, measured with `tools/f3_rec_count.py` over every Ray
Force dump (rows are what the old RTL stored, runs what the new one does):

    ordinary play (2400, 2930, 3000, 5400)   1.0-1.3 rows a record
    ship shrink (1797-1800)                  1.4-1.7
    shrink-heavy (4198-4200, glitch/4242)    2.8-3.25   5680 rows -> 1750

The board's 10,714 peak is nearly double the busiest dump, and the
shrink-to-a-line effects are exactly the 3x regime, so the store should
land somewhere between 30 % and 60 % instead of 87 %. `SPR REC` on the page
now counts records; the first board reading after this build is the number
to write down.

Verified before it was built:

    make -C sim spr-rec          1800: 638, 2930: 3755, 4200: 854 records --
                                 each exactly the model's run count
                                 (4200 was 2672 records before)
    make -C sim spr-line-all     20/20 SPRITE LINES OK; frame 4200's one
                                 used-flag diff (0 pixel diffs) unchanged
    make -C sim spr-ghost        0 stale pixels, both frames
    make -C sim pipe-all         19/19, 71,680/71,680 each
    make -C sim spr-lat          frame 2930 exact at SPS_LAT=130
    make -C sim ear-pipe-all     10/10; ear-spr-line-all as before

`spr-rec` is new: it reads `rec_peak` out of the pipe bench's `dbg_rec` and
compares it with the model's count for the sprite RAM the bench actually
draws (frame f-2). A prepass that split or merged runs wrongly shows there
before it shows on the page.

This is in the same build as `ch7`. They are independent -- one is the store,
the other the fetch -- and each has its own page row (`SPR REC` and
`SPRLINE`), so they can still be told apart on the board.

---

## 2026-08-29 — Elevator Action Returns renders exactly (commit 603d965)

All ten sampled EAR frames match MAME pixel for pixel across the **full
232-line visarea** (74,240 px each), where before four matched partially over
224 lines and one sat at 77.5 %. Five of the ten (3000, 3600, 4200, 4800,
5400) were dumped from MAME *after* these fixes and never used to develop
them, so they are an out-of-sample check. Ray Force is unaffected: `pipe-all` 19/19,
`mix-all` 19/19, `spr-ghost` OK, and `spr-line-all`'s one frame-4200 used-flag
diff (0 pixel diffs) is byte-identical on the parent commit.

**All three defects were the same thing: a Ray Force dimension frozen into
the RTL as a constant.**

1. **Graphics code width, 14 bits.** Ray Force's sprite and tile regions hold
   16,384 elements, so 14 bits is exactly right for it. EAR's are 4 MB =
   32,768. MAME builds a 17-bit sprite code (`spr[0] | ((spr[5]&1)<<16)`) and
   uses all 16 bits of `tilep[1]`, wrapping `% nelem`. Widened to 15 bits
   through `sl_d`, both gfx buses and the playfield fetch.
   *How it presented*: on the character-select screen every panel, bar and
   glyph was perfect while the three portraits drew as scattered in-game
   sprite fragments — 60 of the 72 over-limit sprites in frame 2400 were the
   portraits. A layer-by-layer render (`F3_ONLY`) proved the whole screen is
   sprites, which is what pointed at the sprite code rather than the mixer.
2. **Sprite cull bounds, hardcoded TWICE** — `rf_video_spr_list`'s `Y0/Y1`
   and `rf_video_spr`'s `VY0/VY1`, both 31..254 (f3_224a). EAR is 24..255, so
   sprite rows on the 8 lines outside that window were dropped. Fixing only
   the first changes nothing; the second is the per-row clip matching the
   model's `_drawgfx`. Both now follow `vis_mode`.
3. **The bench never checked those 8 lines.** `sim/pipe_tb.cpp` used Ray
   Force's 224-line window for every game. `F3_V0`/`F3_V1` now set it and
   drive the RTL's `vis_mode`; widening the window is what exposed defect 2.
   New targets: `make -C sim ear-pipe-all ear-spr-line-all`.

**Two things checked and found NOT to be bugs**, recorded so they are not
re-investigated: EAR's ensoniq ROMs load at 0 and 0x400000 in MAME, which
looks like our MRA packs them wrongly — but Ray Force has the identical
layout and verified-exact sound, and `rf_smp_bus` maps ES5505 banks
contiguously across the 4 MB region, so the packing is right. And the tile
code never exceeds 14 bits in any dumped frame of either game, so the
tilemap half of the widening is insurance, not a fix.

**The sprite row-usage flags over-report, harmlessly, and here is why.**
`ear-spr-line-all` frame 4200 shows 0 pixel diffs and 8 used-flag diffs (Ray
Force has the same on its own frame 4200, and had it before any of this).
The model sets `row_usage[dy] |= bit` only inside `if c and not fbrow[dx]` --
the sprite that actually *claims* the pixel. The RTL sets it whenever it
writes a visible non-zero pen (`rf_video_spr.sv`, `dr_used <= dr_used | (1
<< dr_pri)`), because it relies on draw order rather than a read-before-write
to make the last writer win. So where sprites of different priority groups
overlap, the RTL claims a group is present that contributes no visible pixel.
The mixer then looks for that group's pixels, finds none, and produces the
same colour -- which is why the pixel counts are exact and `pipe-all` /
`ear-pipe-all` are 19/19 and 10/10. Making it exact needs a read-before-write
in the draw loop; not worth the regression risk for no visible defect.

Also fixed: the three Ray Force MRAs contained literal `\n` text where
newlines belonged, left by an earlier scripted edit. The part stream is
byte-identical after the fix, so the download checksums the self test
expects are unchanged (verified by comparing the parsed part list with
`git show HEAD:`).

---

## Morning summary (written 2026-08-28 ~00:40, B7 still compiling)

What changed overnight, shortest form. Every step's numbers are in the table
below and the sections after it.

- **Video**: sprites are on hardware and stay there. Two fetches in flight,
  the playfield fetch overlapped with its unpack, a run-ahead ring of four
  sprite line buffers, and the bucket store rebuilt as a counting sort
  holding 8192 rows per frame at the same MLAB cost. Attract mode on the
  board: 0 dropped records, 0 late lines. **The ship-vanishing lead**: the
  4095-row cap (dropping the END of the sprite list = the ship) is gone; the
  `SPR REC : DROP` row will say if boss transitions still exceed 8192.
- **Sound, from nothing to a sample-exact sampler**: the MAME oracle
  (`tools/oracle_en_dump.lua`), an exact Python model of the ES5505
  (`tools/es5505_model.py`, correlation 0.95-0.99 with MAME's own mix), the
  sound 68000 board (`rf_sound_main.sv` -- the real program runs: 1387 chip
  writes identical to MAME from reset, 1775 in a row in the steady state),
  the ES5510's host port (`rf_es5510_host.sv`), the ES5505 in RTL
  (`rf_es5505.sv`, **sample-exact against the model over 1.15 M samples**),
  the MB87078 volume chip, and the audio path to AUDIO_L/R. B6 built it but
  failed timing on a divider of mine; B7 (compiling) has the fixes.
- **BRAM**: the 64 KB sound RAM fits because pivot RAM (the pixel layer,
  which Ray Force only clears) is a stub; the page counts non-zero writes to
  it so the assumption is checked every run.
- **Pause** works (J1 button). **Gunlock / Ray Force (Japan)** MRAs written.
  NVRAM is a design note (needs one MiSTer-side fact, see "Missing parts").

**Board state when you read this**: B8 (`28005854`, also in `builds/`) --
video + sound CPU + sampler + volume chip, timing met on every clock, every
page row PASS; confirmed still running at 01:40 on 08-28. It should be
making sound; no one has listened. B9 (sound-CPU Pause) was stopped
mid-compile; its sources are in the tree, one `./build.sh` away.

**Is sound working? -- what is and is not known.** Known: the driver runs
(1387 chip writes identical to MAME from reset, 1775 in a row later, ~50k
voice writes counted on the page), the sampler is sample-exact against the
model, the mix reaches AUDIO_L/R, timing is met. Not known: the real SDRAM
sample path (ch6) has only the bench's memory model behind it, the output
level is a calculation, and nothing on the page shows audio activity. The
quick objective check is a page row for {sampler overruns, queue drops,
non-zero audio samples per frame} in place of the redundant `IRQ3 ACK` row
-- a 35-minute build -- or an ear at the HDMI output. If B7 failed, the last known-good sprite core is
`Rayforce_27223342.rbf` (B4) and the last sound-CPU core `27230527` (B5),
both in `builds/` (git-ignored); `tools/rf_deploy.py --rbf builds/<file>`.
Put `Rayforce.CFG[0]` back to `08` (page mode) with `.venv/bin/python3
tools/setcfg.py 08` if the UART shows the ring instead of the page. The
ring test is `tools/snd_test.sh <rbf>`.

**To hear it**: the sound is at AUDIO_L/R with the game's own volume
control; nothing on the page proves audio, only the sim does. If it is
silent or wrong, `SND ES WR : RUN` says whether the 68000 is streaming
voice writes, and the ring test (`snd_test.sh <rbf>`) says whether it is
saying what MAME says.

## Overnight plan (2026-08-27 -> 28) -- results are appended to each step as they land

Everything below is verified in Verilator before it is built, deployed to
172.17.1.164 and read back off the self-test page over the UART. Each
bitstream is kept aside as scratch `Rayforce_<stamp>.rbf`; nothing is
committed (no commit was asked for -- the tree is left ready to review).

| # | Step | Verification | Result |
|---|------|--------------|--------|
| B2 | Two sprite fetches in flight, playfield fetch/unpack overlap, 20-bit sprite line buffer | sims 15/15; on the board: SPRLINE, MAXFETCH:BUILD | **27220158, timing met, M10K 533.** Attract mode, 4 samples: SPRLINE max 2473 clocks, 0 missed (B1: 3582 / 2 missed); longest playfield build 1823-2295 (B1: 2467) |
| B3 | Run-ahead sprite ring (NB=4) + `SPR REC : DROP` row (replaces LAST PC) + `SPRLINE : LATE` | sims 15/15, frame 3000 at latency 34 clean; board: LATE = 0 in attract, REC:DROP read | merged into B4 |
| B4 | Ring + counting-sort bucket build (no `rnext`, NREC 8192 at the same MLAB cost) + the two rows + Pause | spr-line-all, pipe-all, pipe-60, pipe-lat; overflow path exercised at NREC=2048 | **27223342, timing met, M10K 536, memory LABs 784.** Attract, 3 samples: records/frame 1294-2272, **0 dropped**; sprite lines **0 late**, longest 2338. Boss transitions need play (see morning note) |
| S0 | Sound oracle: ES5505/bank/volume write stream + wav + sound-RAM footprint from MAME; `es5505_model.py` proven against the wav | model vs wav | **Done.** `tools/oracle_en_dump.lua` (writes with machine time, `dump/en3/`), `tools/es5505_model.py` (exact port of the 5505 paths), `tools/es5505_compare.py`: correlation 0.95-0.99 with MAME's mix in every audible window, lag < 1 ms. Sound RAM working set 16.6 KB scattered; pivot RAM is never written -> its 64 M10Ks become the sound RAM (ROADMAP Phase 3) |
| S1 | `rf_sound_main.sv`: TG68K in 68000 mode, the EN map, the MB8421's other port, the DUART's timer/vector/OPR, ROM via its own prog_bus on new SDRAM ch5, the full 64 KB sound RAM (pivot RAM stubbed with a write counter), chip writes to the shared UART ring (UART Debug = Sound Ring); rows `PIVOT WR:SND PC` and `SND ES WR : RUN` replace WRITE COUNT and FRAME COUNT | No Verilator bench possible (TG68K is VHDL); lint clean with a stub. Board: `tools/rf_snd_ring_check.py` against `dump/en3/en_writes.txt` | **27230527, timing met, M10K 538, ALMs 80 %, LABs 97 %.** The sound 68000 runs the real program: **the first 435 chip writes on the board are identical to MAME's stream from write 0** (the ES5505 init, the DUART setup, the volume chip). It then loops on the ES5510 presence check: the driver stores a value through the DSP's latches (host regs 0x80/0xA0) and reads it back, and the stub only decoded 32 registers, so the select commands overwrote latch 0. A faithful host-port model (`rf_es5510_host.sv`) goes into B6. Page in page mode: `SND ES WR : RUN 62340001` (25,140 ES5505 writes, running -- the driver times out of the DSP check and streams anyway), and `PIVOT WR:SND PC 8000106A` FAIL: **the game clears pivot RAM at boot** (exactly 0x8000 word writes), which the zero stub absorbs; the row counts only non-zero writes from the next build |
| S2 | `rf_es5505.sv`: the sampler, 32 voices time-multiplexed in MAME's 20.9 forms, per-voice 8-sample line caches over new SDRAM ch6 (`rf_smp_bus.sv`); register writes applied at sample boundaries | `make -C sim es5505`: sample-exact against `es5505_model.py` over the capture | **Sample-exact: 1,150,000 samples (38.6 s, 11 s of music), 0 differences, 0 overruns, 43,600 line fetches.** Three bugs the bench found: a 64-deep write queue lost the write that started the first voice (the driver sets a voice up with ~100 writes 0.3 us apart; now 256 deep + a drop counter); the registered voice-file write lost back-to-back writes to one voice (forwarding added); a signed x unsigned product in the interpolation went unsigned (all operands signed now). Plus one bench bug: the sample clock must use MAME's INTEGER rate (15238090 // 512 = 29761 Hz), or the write boundaries drift a sample every ~30 ms. Also exact with the bench's memory latency raised to 60 cycles (the ch6 path will be slower than the bench's 20). Integration into the core is B6 |
| S3 | `rf_mb87078.sv`: the volume chip (mb87077.cpp's latch/gain-index rules, taito_en's L/R mapping, a 66-entry coefficient table folding in MAME's route gains and the 20->16-bit scaling); the ESP stays a dry sum (pump's fake mode) | lint; by ear on the board | *(written; goes into B6 with the sampler)* |
| B6 | Sampler + sample bus on ch6 + sample clock (integer rate, fractional divider of clk_sys) + volume chip -> AUDIO_L/R + `rf_es5510_host.sv` (the DSP's host port done properly, so the driver's presence check passes) | sims (es5505 exact); board: ring check should now run past the DSP init; sound by ear | **27233928: compiled but timing FAILED (-32 ns on clk_sys), ALMs 92 %, LABs 100 %.** Two causes, both mine: a 32-bit divider for the sample rate in Rayforce.sv (the -32 ns path, `active -> es_acc`; now a 32-entry constant table), and the sampler instantiating a multiplier per expression (28 DSPs + ~5000 ALMs; rewritten around ONE shared 34x18 multiplier, 17 cycles per voice, re-verified exact). Its ring test still stood (the ring does not use that path): **1387 writes identical from write 0** (B5: 435 -- the DSP host port passes the presence check) and a **1775-write identical run in the steady state** (from MAME write 127,442); the differences are DUART command-register writes whose order against the 1 kHz timer interrupt is CPU-speed dependent. Rebuilt as B7 with the divider table, the one-multiplier sampler (re-verified exact) and the pivot counter counting non-zero writes only |
| B7 | B6's content with the fixes above | ring test; page; board sound | **28001753: clk_sys +1.1 ns, clk_ram +1.4 ns; ALMs 96 %, LABs 100 %, M10K 538; the framework's HDMI PLL clock misses by 0.26 ns (TNS -2) under that pressure.** Ring: 1387 identical from reset, 1775-long identical run in the steady state. **Every page row PASS**: `PIVOT WR:SND PC 0000xxxx` (no non-zero pivot writes), `SND ES WR : RUN C27A0001` (49,786 voice writes, running), `SPR REC : DROP 0E800000` (3712 records, 0 dropped), `SPRLINE : LATE 061C0000`. **This is the core on the board now, in page mode.** Audio reaches AUDIO_L/R; nobody has heard it yet |
| B9 | The sound CPU honours Pause too (B4's Pause froze the game with the music playing on) | lint | Build `28013233` was stopped from outside ~2 min in (01:34). The sources are promoted (`rtl/rf_sound_main.sv`, `Rayforce.sv` `.pause(paused)` on the sound board), so `./build.sh` produces it; nothing else changed since B8 |
| B10 | Morning report: **sound scrambled, HDMI upside down.** (1) Rotation default flipped to CW (the F3 flipscreen already inverts the raster). (2) A sample-region BIST through the real fetch path (`rf_smp_bus` on ch6: the first 64 KB of d66-01, fold rotl1+add per LE word, expected `B86C4865` from `gunlock.zip`) and the sampler's overrun/queue-drop counters, on the `IRQ3 ACK` row as `SMP BIST:OVR:DR` -- the two hardware-only things the sim could not cover. (3) The sound CPU honours Pause. | page: the new row says whether the sampler is fed the right bytes and keeps up | **28072603 deployed: `SMP BIST:OVR:DR 48650000 PASS`** -- the sample path returns the right bytes (sum B86C4865), 0 overruns, 0 queue drops. clk_sys +2.4, clk_ram +2.0; the HDMI PLL misses by 0.33 ns (fitter variance at 86 % ALMs). So the scrambling is NOT the fetch path or timing; next is recording the audio itself over the UART (B11) |
| B11 | **Audio Ring**: UART Debug's unused "Off" slot becomes "Audio Ring" -- the first 4096 AUDIO_L samples after the sound starts, into the write ring; `tools/rf_audio_ring.py` makes a wav of it and correlates it with the model's output for the same moment. The remote ear. `tools/setcfg.py 18`, load, `rf_uart.py -t 15`, then the tool. | correlation with `dump/en3/model45.wav` | **28080709, timing met everywhere.** First capture: the board's audio at its first non-silent sample is real sampled audio (smooth ~1 kHz oscillation, peak 930 = about -31 dB, i.e. at the game's fade level), but it correlates with NOTHING in the model's 45 s (max 0.15). Either the board plays something MAME never does, or its sound starts after 45 s (the capture window ran to ~80 s after load and a boot without saved EEPROM settings changes the timeline). The ring's index was relative to its own start, so it could not say which. B12 makes the index absolute (samples since the sound CPU's release) and `dump/en4/` extends the reference to 95 s |
| B12 | Audio Ring index absolute (samples since the sound CPU's release); sound CPU honours Pause | page | **28084316: every page row PASS, HDMI PLL -0.042 ns (fitter variance), core clocks +1.7/+1.8 ns.** Deployed 09:22 by session b2 after session 5a was stopped. The full bench suite (12 targets) passes on this tree |
| B13 | **The fix for the scrambled sound: ES5505 register READS** (`rf_es5505.sv` rd_* port, `rf_sound_main.sv` stalls the 68000 until the answer), plus the left analog stick as d-pad (`Rayforce.sv` stick_dirs) | `make -C sim es5505-rw`: 1.15 M samples exact AND all 8001 of the driver's reads answered as MAME does; `make es5505` (en3) still exact; lint | **28094310, GATE PASS (HDMI PLL -0.158 ns, the framework clock's fitter variance again; core clocks +1.35/+1.82 ns), ALMs 87 %. Every page row PASS. Audio Ring: index 803387 (26.99 s after the release), NCC +1.000 at ratio 1.000 against BOTH `model95.wav` and MAME's `en_mix.wav` at 28.850 s -- the board's audio is MAME's.** Capture kept as `dump/en5/audio_ring_b13.log`. The analog stick is untested (no pad on the bench) |
| B8 | Sampler shrunk for margin: the write queue read through one port (an `A_NXT` state instead of a second read port), the record update done field by field instead of rebuilding 313 bits per case arm | `make -C sim es5505` exact (1.15 M samples) | **28005854: TIMING MET on every clock** (HDMI +0.19, clk_ram +1.46, clk_sys +1.96 ns), ALMs 86 % (B7: 96 %), sampler 1805 ALMs (B7: 5381), M10K 539. On the board, every page row PASS (`SND ES WR : RUN C27A0001`, `SPR REC : DROP 0E800000`, `SPRLINE : LATE 06610000`). **This is the core on the board, in page mode, and in `builds/`** |
| B14 | The sprite ghost (per-line span clear + frame-parity tag), NVRAM load/save on ioctl 254, the two sprite rows peak-held | `make -C sim spr-ghost` (frame 3000 then 300: 1280 stale pixels before, 0 after), all 12 benches, `pipe-lat` 0 late lines, lint | **28105535, GATE PASS (HDMI PLL -0.110 ns, the same framework clock; ALMs 88 %). On the board: every row PASS, `SPRLINE : LATE 02B80000` (longest line 696 clocks, 0 late) and `SPR REC : DROP 05B00000` (peak 1456 rows, 0 dropped) -- both now peak-held, so those zeros cover the whole run** |
| B15 | Resource work: the 56-bit debug ring 4096 -> 2048 entries (24 -> 12 M10Ks, M10K being the binding resource at 539/553) and the sprite record store 8192 -> 12288 rows per bank in MLABs, which is what the board's measured 8296-row peak overran | benches; the fit report's M10K and memory-LAB counts | **28113056: `GATE PASS: timing met` -- the FIRST fully clean build since B7. Worst slack +0.048 ns; the HDMI PLL clock that had missed by 0.04-0.16 ns in every build from B10 on is met, which says that miss was fitter congestion, not a real path. M10K 527/553 (was 539), ALMs 88 %, block memory 73 %. On the board: every page row PASS; the audio ring (2048 samples now) correlates +0.992 with `model95.wav` at ratio 1.0** |
| P | Small missing parts: Pause (in B4), gunlock/rayforcej MRAs (written), NVRAM (design note only) | build + board | Pause + MRAs done; NVRAM see "Missing parts" |

### Ray Force overruns its sprite budget in attract -- in the SHIPPED release (2026-08-28)

Found by the peak-hold rows added in B14, and only because a core was left
running for a couple of minutes instead of being read straight after a load:

    v1.0 release (28124835, its own unpadded MRA, ROM BYTES 00B80000 PASS)
        SPRLINE : LATE  3EFA182E  FAIL     longest line 16122 clocks,
                                           6190 late lines and climbing

The budget is 3456 clocks a line. Sixteen thousand is nearly five times it,
and a "late" line is one the mixer started composing before the sprite draw
had finished it -- i.e. **missing or partial sprites on those lines**, in
ordinary attract mode, in the build that was tagged and released.

This is NOT a regression from the F3 generalisation: the same rows on the
current tree's build (`28165741`) read `42C910A7`, the same story. Both were
checked with the MRA each bitstream was built for -- the first attempt at
this comparison ran the release bitstream against the new padded MRA, which
it cannot read (ROM BYTES failed), and was thrown away.

Why it went unnoticed: every capture in this handoff before now was taken
within seconds of a core load, when the peak-hold counters are still at
zero. They climb once attract reaches its busier scenes. `SPR REC : DROP`
stays clean (0 dropped records), so the record store is fine -- it is the
per-line DRAW that misses its deadline, which points at the SDRAM fetch
path under contention rather than at the bucket build.

**This deserves priority over Elevator Action**: it is a visible defect in a
released, working game, it is measurable from the page without a debugger,
and `pipe-lat` (the bench that models a hardware-like fetch turnaround)
reports zero late lines -- so the bench's latency model is optimistic
compared with the real controller and should be recalibrated against these
numbers first.

> **Resolved 2026-08-29 — do not act on the paragraph above as written.** The
> bench reported zero late lines for a reason that had nothing to do with its
> latency model: the counter is peak-held from the 16th frame and the bench
> ran three. Recalibrated (`F3_SPS_LAT` + `F3_FRAMES`), it reproduces the
> failure, and the cause is serialisation on the shared sprite channel rather
> than a bandwidth ceiling. See "The sprite fetch path" at the top of this
> file.

### Elevator Action Returns: first boot on the core (2026-08-28, `28133520`)

The core is now a Taito F3 core that loads a second game. Build `28133520`
carries the universal 18.5 MB SDRAM map and the per-game config byte, timing
met (+0.219 ns), and **Ray Force still passes all 21 self-test rows on it** --
including `ROM BYTES 01280000` (the padded total) and the unchanged
`ROM CHECKSUM 77E1C279`, which is the regression that mattered.

`releases/Elevator Action Returns.mra` loads on it. What the board says:

| Row | Value | Meaning |
|---|---|---|
| ROM BYTES | `01280000` PASS | the download is exactly the universal map |
| ROM CHECKSUM | `D041363D` PASS | **byte-perfect** -- matches `tools/rf_stream_sum.py` computed offline from the MRA |
| SDRAM BIST | `399D4BCA` PASS | the 68020's program ROM reads back correctly through the SDRAM path |
| SMP BIST | `F5D3....` PASS | the sample ROM fetch path returns the right bytes (`52DDF5D3` low half) |
| PLAYFIELD / SPRITE / LINE RAM / TEXT | PASS | the CPU is executing and writing video RAM |
| **IRQ2 ACK/64FRM** | `00000000` **FAIL** | **no vblank interrupt is ever acknowledged** |
| FETCH : PIX NZ, TILE NZ | 0 FAIL | so nothing is being rendered |
| SND ES WR : RUN | WAIT | the sound CPU is never released, which follows |
| PIVOT WR | `0001....` FAIL | exactly **one** non-zero pivot write -- the same single transient longword MAME shows, so the stub is behaving as measured |

So the loading half is done and proven, and the game is stuck before it
starts drawing. Everything the ROMs can prove about themselves passes; what
fails is all downstream of the CPU never taking IRQ2.

**The CPU is not the problem -- that is now measured, not assumed.**
`tools/oracle_f3writes.lua` (new: the Phase 0/1 write-stream oracle, for any
F3 game, emitting the same `WR addr data szN` lines `rf_write_compare.py`
parses) was validated by reproducing Ray Force's known hash `0x10620931`
exactly, first lines matching the original `rf_acc.tr`. Run on `elvactr` it
gives **`0x93368F3C` -- precisely what the board reports**. So the 68020 in
this core executes Elevator Action Returns' first 4096 bus writes exactly as
MAME does, and that row is now a real expectation rather than report-only.

What is left is downstream of that: no IRQ2 acknowledge ever happens. Note
that MAME's `f3_timer_control_w` (0x4C0000, where this game writes 0x278B
and Ray Force writes 0) is an explicit TODO in MAME too -- "several games
configure timer-based pseudo-hblank int5 here at POST" -- and MAME runs the
game without it, so that register is not the cause either.

**Where it actually stops (measured 2026-08-28, build `28142635`).** The
game's POST is a byte-by-byte RAM test: for every byte address it writes
FF, AA, 55, 00 and kicks the watchdog (0x4A0000) between each, so eight bus
writes per byte. MAME walks it from 0x400000 straight through 0x401D49 and
beyond without pausing.

The board gets to byte **0x4001FD and stops writing altogether**. Two ring
captures six seconds apart hold the *identical* 1025 distinct operations --
not a loop cycling through them again, the ring simply stops advancing --
so the CPU is spinning somewhere that performs no writes, i.e. on a read.
That is about 4,100 bus writes in, which is why the WRITE HASH row (frozen
at 4,096) still matches MAME: the divergence happens just past the end of
what that row can see.

Nothing is special about that address in MAME's stream -- it writes
0x4001FE, 0x4001FF, 0x400200 and carries on -- so the boundary is ours, not
the game's. Note also that MAME has issued **no** sound-reset (0xC80000) and
**no** dual-port RAM writes by this point, so the sound board is not what it
is waiting for.

Two hypotheses were tested and eliminated: the timer-control register
0x4C0000 (MAME ignores it too and runs the game), and non-deterministic
mixed-port read-during-write on the BRAMs (changed to OLD_DATA in
`28142635` -- kept, since it is strictly safer, but the symptoms did not
move at all).

**Answered (build `28150713`, timing met +0.114): the game's own POST
rejected our RAM.** The new `TRAP : MAIN PC` row reads `0001032C`, trap
flag 0. Disassembling the reconstructed program ROM there:

```
0102A0:  MOVE.B D1,(A0) / MOVE.B (A0),D2 / CMP.B D1,D2 / BEQ ok    byte pass
0102D0:  MOVE.W D1,(A0) / MOVE.W (A0),D2 / CMP.W D1,D2 / BEQ ok    word pass
010300:  MOVE.L D1,(A0) / MOVE.L (A0),D2 / CMP.L D1,D2 / BEQ ok    long pass
   mismatch -> LEA (pc+8),A2 ; JMP <error printer>
010324:  JMP (A6)    010326: BRA.S *      <- hang
010328:  JMP (A2)    01032A: BRA.S *      <- hang
01032C:  JMP (A2)    01032E: BRA.S *      <- hang   <-- the board sits HERE
010332:  "WORK RAM ERROR" "OBJECT RAM ERROR" "SCR0 RAM ERROR" ...
         "MASK RAM ERROR" "LINE SET RAM ERROR" "LINE DATA RAM ER..."
```

So the core is not hanging on a missing device and is not lost: Elevator
Action Returns' power-on self test **compared a byte it had just written,
found the wrong value, and jumped to its error handler on purpose**. The
strings sitting immediately after the handler are that test's messages.

Every failing compare in all three phases is a READ IMMEDIATELY AFTER A
WRITE TO THE SAME ADDRESS -- which is exactly the path where `rf_main`
drives `waddr` and `raddr` from the same `a[16:1]`. Changing the BRAM's
mixed-port mode from DONT_CARE to OLD_DATA did not move it, so the fault is
in WHEN the CPU samples that read-back, not in the memory's
read-during-write mode.

**Experiment 1 (build `28154550`): qualifying every CPU write with
`!clkena` -- write once, on the address-setup cycle, the way
`rf_sound_main` does it. It BROKE RAY FORCE**, in exactly the way Elevator
Action fails: IRQ2 acknowledges 0, nothing rendered, sound CPU never
released, PC parked (0x002932). Reverted; Ray Force verified back to 21/21
on `28150713`.

That is a useful negative result, and it says something precise. Removing
the write that commits at the END of the clock-enable cycle is what broke
it, so THAT is the write carrying valid address and data -- the earlier one,
at the address-setup edge, is the spurious one. `rf_sound_main`'s idiom does
not transfer: it runs a different TG68K configuration (68000 mode, its own
SPEED_DIV) whose outputs settle a cycle earlier.

It also shows what a broken CPU write path looks like from the self-test
page -- IRQ2 0, no render, CPU parked -- which is precisely Elevator Action
Returns' signature.

**Experiment 2 (build `28165741`): qualify with `clkena` instead.
Ray Force survived, 21/21. Elevator Action did not change at all** -- same
PC, same rows. So the CPU write path is exonerated. The change is kept
anyway: one write per bus cycle instead of two, on the cycle that was
already the effective one.

**And a correction that matters more than either experiment.** The write
ring FREEZES at the 4096th write (`wr_frozen = wr_count[12]`), a Phase 0/1
feature for capturing the boot stream. So "the ring stopped advancing, three
captures identical, therefore the CPU stopped writing at byte 0x4001FD" was
WRONG: the ring had simply hit its freeze, and the CPU may have run far
past that point. What the ring did prove, rigorously, is worth keeping: an
exact subsequence match puts the board's 2048 recorded ops at MAME's ops
2048..4095, **identical, op for op, lanes included**. The divergence is
somewhere after write 4096, unseen.

The ring is circular from the next build, so a capture always shows the LAST
2048 writes -- which is what tells you what a parked CPU did just before it
parked. The WRITE HASH row already covers the first 4096, so nothing is lost.

**(superseded) Experiment 2, when it was still worth running:** qualify with `clkena`
instead, so each write happens once, on the cycle that is already the
effective one, and the spurious address-setup write disappears. That is
strictly today's behaviour minus the extra write, rather than a different
write. If Ray Force survives and Elevator Action clears POST, the spurious
write was the fault; if Ray Force survives and Elevator Action still stops
at 01032C, the RAM path is exonerated and the search moves elsewhere.

**And in simulation rather than in 32-minute builds:** the failing
sequence is "write X, read X back, compare" against `rf_main`, which a
Verilator bench can drive directly in minutes. Make it red first, then fix.
Ray Force never trips this because its boot does not run this test.

**(superseded) The diagnostic was the main CPU's program counter.** `rf_main` still
computes `last_pc`, but the page row that showed it was given to
`PIVOT WR:SND PC` in B5, so nothing reports it any more. One build that puts
the main CPU's PC back on the page says immediately whether it is in a
retry loop inside the RAM test, in an exception handler, or parked on a poll
-- which is the difference between a RAM readback bug and a missing device.

**The older next step, once that is known:**
capture the board's write ring (`UART Debug = Write Ring`) and diff it
against the oracle's stream past that point. One obstacle to clear first:
setting the UART mode for this game did not take. Both MRAs declare
`<rbf>Rayforce</rbf>`, so it is not obvious whether MiSTer keys the saved
settings on the core name (`Rayforce.CFG`, which `tools/setcfg.py` writes and
which works for Ray Force) or on the MRA name (`Elevator Action Returns.CFG`);
writing either one and reloading left the UART streaming the self-test page.
Worth settling from Main_MiSTer's `user_io_create_config_name` rather than by
trial.

Note for whoever runs it: MiSTer keeps arcade settings per MRA name, so
Elevator Action Returns gets its own `/media/fat/config/Elevator Action
Returns.CFG` and starts from defaults (self test ON, TATE rotation) rather
than inheriting Ray Force's.

### Polish, input lag and the analog stick (2026-08-28, B16 `28121351`)

Three OSD options added: **Stereo Mix** (None/25/50/100 % -- `AUDIO_MIX`,
which had been tied to 0; the ES5505 pans its voices so this is a real
choice), **Flip Screen**, and **Pause When OSD Open** (holds both CPUs
through the existing `pause_eff`, so the music stops with the game).

Flip Screen drives `screen_rotate`'s `flip`, i.e. the ROTATED output. It is
deliberately not the renderer's flip: `rf_video_pipe`'s `flip` is tied high
because Ray Force sets its flipscreen bit permanently, and the sprite engine
takes its own flip from the sprite command word -- toggling the pipe's bit
would flip the playfields and pivot layer but not the sprites. So the option
applies whenever rotation is on; with Rotate = None, and on the analog raster
(which stays in raster order on purpose, for a rotated CRT cab), there is
nothing to flip.

**Input lag: there is none to remove in this core.** The path is
combinational end to end -- `hps_io`'s joystick word, OR'ed with the analog
stick decode (`joy0_in`), into `rf_main`'s `j0`, into the `always_comb`
that builds `in0_lo`/`in1_lo`/`ctrl_q`, straight to the CPU's read. Not one
pipeline stage, no per-frame sampling: the game sees a button the moment it
polls the port, so the lag is the USB poll (~1 ms) plus the game's own
polling. The lag that DOES exist is in the video path and is a choice:
`screen_rotate` writes the picture through the DDR3 framebuffer and the
scaler reads it back, which costs a frame, so **Rotate = None (or the analog
output, which never goes through the framebuffer) is the low-latency
configuration**; MiSTer's own scaler and `vsync_adjust` add the rest.

**The analog stick** (B13, in every build since) is correct by
construction and the board is set up for it: the DE10 has a *Microsoft
X-Box One pad* attached (045e:02d1, `ABS=3003f`, so the axes exist) and a
`rayforce_input_045e_02d1_v3.map` already saved. MiSTer scales axes to
-127..127 and sends **negative Y for up** (Main_MiSTer `input.cpp`,
`joy_analog`), which is exactly what `stick_dirs` assumes -- so up/down
cannot come out inverted. It ORs into the d-pad bits past 48/127 of
deflection. What no one has done is hold the stick: if it does nothing on
the cabinet, the thing to check first is MiSTer's own input map (the
analog stick has to be assigned in "Define analog joystick"), not the core
-- with the stick unassigned MiSTer never sends the axes at all.

### Sprites that never went away, and NVRAM (2026-08-28, B14 `28105535`)

**The ghost.** Reported from the cabinet: player shots leave their pixels on
the screen along the whole path. The cause is in `rf_video_spr.sv`, and the
comment that hid it said "the line buffer needs no clearing: each entry tags
the line it was written for". It tagged the LINE but not the FRAME. Bank =
line mod 4, tag = line[7:1]; within a frame that tells the 64 lines sharing
a bank apart, but line L of the next frame has the same bank AND the same
tag, so a pixel written at (L, x) and not overwritten by anything since
still read as a live sprite pixel, frame after frame. Nothing ever cleared
it -- only another sprite pixel at the same address could.

The fix is what the real chip does (and the model: it clears its
framebuffer every frame -- "sprite trails" is the F3 feature for NOT
clearing, and Ray Force never sets it): **clear the line before drawing
it**. Two details earned by measurement:

- A frame-parity bit in the tag (free: `{par, line[7:NBW]}` is still 7
  bits) is NOT sufficient on its own -- one bit only tells adjacent frames
  apart, and a pixel untouched for two frames comes back. `sim/Makefile
  spr-ghost` -- frame 3000 (198 sprites) followed by frame 300 -- failed
  with 1280 stale pixels on exactly that. It is kept as a guard for the
  window where the draw has not reached a line the mixer asks for.
- A flat 320-pixel clear per line is too expensive: it took the longest
  line from 3288 to 3608 clocks and made 254 of 256 lines late in
  `pipe-lat`. The clear is therefore a **span**: each bank remembers the
  leftmost and rightmost pixel its last occupant wrote and only that range
  is cleared. Every written pixel is still cleared before the next occupant
  draws -- full correctness, not just adjacent frames -- and the empty and
  near-empty lines that most of a frame is made of cost nothing. Measured
  after: longest line 3472/4726 clocks, **0 late lines**, all 12 benches
  identical.

**The two sprite rows are now PEAK HOLD.** A five-minute attract capture
(632 page passes) showed record drops in ONE pass and late lines in two,
which a last-frame value misses by design. `SPR REC : DROP` now reads
{highest records built, total rows dropped} and `SPRLINE : LATE` {longest
line draw, total late lines}, held since reset -- so a boss transition
cannot slip past between two UART samples. Held only from the 16th frame:
the first frames after a reset have no buckets built yet, so the mixer
legitimately outruns the draw and the counter would latch a permanent FAIL
out of the boot.

**NVRAM -- what is proven and what still needs a person at the cabinet.**
The board's MiSTer supports the channel (other cores have 128-byte files in
`/media/fat/config/nvram/`) and the deployed MRA carries the `<nvram>`
element, but no `Ray Force.nvm` exists yet, and it cannot appear until a
save is triggered: MiSTer only calls `arcade_nvm_save()` when the OSD is
opened or "Save settings" is picked, and `/dev/MiSTer_cmd` has no command
that opens the OSD (menu / osd / show_menu were all tried and ignored).
A MAME tap on the EEPROM port (0x4A0010, the byte MAME's `case 0x04` and
our `a[4:1] == 4'h9` both decode) settles what to expect: over a 40 s boot
and attract the game issues **16 READ commands and no WRITE** -- so a save
is requested only once a setting actually changes, which is correct
behaviour and also means a plain boot will never produce a .nvm.
**The end-to-end test is therefore: Service Mode on, change a setting,
exit, open the OSD once, and check that `/media/fat/config/nvram/Ray
Force.nvm` appears; then reload the core and see the setting stick.**

**NVRAM.** The 93C46 settings EEPROM now loads and saves through MiSTer's
ioctl index 254. The MRAs declare `<nvram index="254" size="128"/>` (the
form Main_MiSTer's `mra_loader.cpp` parses: `nvram_idx` from index,
`nvram_size` from size); Main sends the 128 bytes after the ROM regions,
from `config/nvram/<mra>.nvm` if it exists and the MRA's default
otherwise, and reads them back when the core raises `ioctl_upload_req` and
the user opens the OSD or picks "Save settings" (`menu.cpp`:
`arcade_nvm_save` on `MENU_SAVE_CHECK`, and on the Save settings item).
`rf_eeprom_93c46` gained a load port, a readback port and a `wrote` pulse;
the top level holds the save request from the first game write until the
upload finishes, so a later write asks again. **The array is no longer
cleared on reset** -- it could not be: the load arrives while the core is
held in reset by the download, so a reset clear would wipe exactly the
data being loaded. It powers up erased instead.

**On "DIP switches in the OSD": the F3 board has none.** There is no DIP
bank on the PCB and none in `taito_f3.cpp`; every setting (difficulty,
lives, region notice, free play, the sound test) lives in the game's own
service menu, reached with the cabinet TEST switch -- which is the OSD's
**Service Mode** toggle -- and is stored in the 93C46. So the OSD entry
that makes those settings reachable is already there, and NVRAM is what
makes them stick between sessions; there is nothing further to add without
inventing switches the hardware does not have.

### The sound bug: ES5505 reads (2026-08-28, session b2)

The board's B11 audio-ring capture was compared with MAME properly:
`tools/rf_audio_match.py` correlates the 138 ms capture at EVERY lag over the
whole 95 s of `model95.wav` and `en_mix.wav`, with a +-1 octave playback-rate
scan (a planted slice of the model is found at NCC 1.000; noise tops out at
0.09). The board's audio matched nothing (0.26, a transient), and its
waveform is voice-like for 17 ms then broadband hash (roughness 1.3-1.7
against a maximum of 0.69 anywhere in the model). Latency was excluded (the
bench with 20-79 cycle random fetch latency stays exact), so was byte order
(the BIST sum is the natural LE fold).

The cause, from a MAME read tap on the sound 68000 (`tools/oracle_en_reads.lua`
-> `dump/en4/en_reads.txt`; `oracle_en_dump.lua` now logs reads as `ESR`
lines too): **the driver reads the ES5505**. At boot it parks voice 10 (CR
fc06 = stopped, FC 0x40, K1/K2 ffff), steps ACC one byte at a time, writes
7fff to O1(n-1) on the high page and reads O1 back (page 0x2a, offset 0x0c,
~77 reads a frame from 2.4 s to 4 s) -- and what comes back is the game's
**sound table**, read out of the first bytes of d66-01: a 2-byte pointer and
a 12-character name per entry ("COIN", "EXTEND", "POWER UP", "LASER VOC",
"LOCK LASER", "P-BOMB", ...). MAME implements this as a special case
(`reg_read_high` O1 on a stopped voice returns the raw sample word at the
accumulator and stores it as o1n1 -- "the Taito F3 games extract raw data
from the sound ROMs"). While music plays the driver also polls the control
register's STOP bits on voices 21-31 (~750 reads in 11 s) and LVOL/RVOL now
and then. `rf_sound_main.sv` answered every one of those reads with `F000`,
so the board built its sound table from 0xF0 bytes and everything it played
afterwards was wrong. The write-stream ring check could not see it: the
reader loop's writes do not depend on what it reads, so the stream stays
identical to MAME's until the table is used at the first sound (28.8 s
after MAME's reset), past every window that was compared.

The fix (B13): `rf_es5505.sv` gets a host read port (`rd_req/rd_reg ->
rd_data/rd_valid`) answered from the live record of the page's voice --
`reg_read_low/high/test` including ACT/IRQV/PAGE, and the stopped-voice O1
case fetched through the voice's line cache (a miss goes to the sample bus,
idle at that point) and stored as o1n1. Two supporting changes: the write
queue is now applied whenever the sequencer is idle, not only at the tick
(same ordering -- every sample up to now is done, the next is not -- but a
read that follows a write sees it, which the page-then-read and
accumulator-then-read sequences need), and the reset sweep of the voice
file is an explicit flag (`sweeping`) because the old "vf_we still high"
test would restart the sweep after any idle-time record write and copy it
into every higher voice. `rf_sound_main.sv` holds the 68000 (no clkena)
until `rd_valid`, drops the request for one cycle after every CPU step so
back-to-back reads are distinct, and acknowledges IRQV only after the
vector has been delivered. The model applies the same O1 side effect on
`ESR` events, so the bench stays exact: `make -C sim es5505-rw`
(`dump/en5/`, 45 s with reads) = 1,150,000 samples, 0 differences, 8001
host reads, 0 wrong; `make es5505` on en3 still exact.

Also in B13: the left analog stick works as the d-pad (48/127 threshold,
OR'ed with the digital bits; `stick_dirs` in `Rayforce.sv`).

**B13 on the board (10:16)**: `tools/setcfg.py 18`, deploy, `rf_uart.py -t 40
-o ring.log`, `python3 tools/rf_audio_match.py ring.log --ref
dump/en4/model95.wav --ref dump/en4/en_mix.wav --span 0.5`: **NCC +1.000 at
ratio 1.0000 at 28.850 s in both**, the runner-up 0.26. The board's audio
IS MAME's. Still to do by ear: the whole soundtrack, not 138 ms of it; the
ring can be re-captured at any point by resetting (the index is absolute).

**For the morning**: to check the ship-vanishing lead directly, play into a
boss transition with `.venv/bin/python3 tools/rf_uart.py -t 30 -o boss.log`
running; `SPR REC : DROP` (rows dropped at the store cap) and `SPRLINE :
LATE` (lines the mixer took before the draw finished) are the two rows that
name the cause. Sprite lag is 1 frame here against MAME's 2: if sprites
visibly lead the scroll, that is the other thing to look at.

---

## What was done (2026-08-27)

### The real main board — `rtl/rf_main.sv` (replaces `rf_cpu_spike.sv`)

The spike answered its question (TG68K.C in 020 mode executes this program
correctly, write hash `0x10620931`) with a deliberately fake memory map:
everything outside ROM/RAM/palette read back zero and no interrupt was ever
delivered, so the boot code ran to its vblank wait at ~0x4060 and stopped.
No video RAM ever held real data, so no part of the pixel pipeline could be
developed or diffed. That is why Phase 2 starts with the map, not with pixels.

`rf_main.sv` is the whole `f3_map` from taito_f3.cpp:

```
000000-0FFFFF  ROM 1 MB, SDRAM via rf_prog_bus (unchanged from Phase 1)
100000-1FFFFF  rest of the ROM window, unpopulated -> 0x0000
300000-30007F  sound bankswitch (ignored)
400000-41FFFF  main RAM 128 KB, mirrored at 420000
440000-447FFF  palette 32 KB = 8192 x 24-bit
4A0000-4A001F  control: inputs, coin counters, EEPROM, watchdog
4C0000-4C0003  timer control (ignored)
600000-60FFFF  sprite RAM 64 KB
610000-617FFF  playfield RAM, tilemap window (4 x 0x2000, extend mode)
618000-61BFFF  playfield RAM, upper half
61C000-61DFFF  text RAM 8 KB
61E000-61FFFF  char RAM 8 KB
620000-62FFFF  line RAM 64 KB
630000-63FFFF  pivot RAM 64 KB
660000-66001F  video control (playfield/pivot scroll, extend bit)
C00000-C007FF  sound dual-port RAM
C80000/C80100  sound reset (ignored)
```

Every video RAM is a true dual-port BRAM: the CPU owns port A, the renderer
gets port B, already brought out of the module so the pixel pipeline can be
dropped in without touching `rf_main.sv` again.

**Interrupts.** Level 2 on vblank, level 3 at 10000 68020 cycles (625 us,
33358 clk_sys ticks) after it — taito_f3.cpp comments that the vblank handler
waits for int3, so it has to be delivered or the game hangs in vblank. Both
are autovectored (68EC020 AVEC). TG68K.C exposes no IACK strobe, so the
handler-address fetch at VBR+0x68 / VBR+0x6C is used as the acknowledge: it
is the one bus cycle that can only mean "the exception is being taken".
`irq2_cnt` / `irq3_cnt` are on the diagnostic screen so a missed acknowledge
shows as a counter running away from the frame count, not as a mystery hang.

**Other pieces**
- `rtl/rf_eeprom_93c46.sv` — the settings EEPROM (93C46, 16-bit org). Written
  properly rather than stubbed: the boot code reads it before drawing
  anything, and a stub that answers wrong sends the program down its "bad
  settings" path, which looks exactly like a broken CPU or video chip.
  Contents are volatile — hooking it to hps_io nvram is a Phase 4 item.
- Inputs: 2 players, start/coin/service, plus a **Service Mode** OSD toggle
  (`O[2]`) wired to the cabinet TEST switch. The F3 test menu is a useful
  early video target.
- `rtl/rayforce_video.sv` — raster timing corrected. gunlock uses `f3_224a`:
  `set_visarea(46, 365, 31, 254)`, so the 224 visible lines start at line 31
  of a 262-line frame, and `vcnt` is itself the line-RAM index. The old build
  had lines 24..247. The diagnostic page now shows eleven readouts (the
  Phase 1 proofs plus frame count, IRQ acknowledges and per-region write
  counters) and a live dump of all 8192 palette entries.

**Build**: timing MET. Worst setup slack +0.660 ns, clk_sys +3.688 ns,
clk_ram +2.376 ns, all TNS 0.000. 31% ALMs, 39 DSPs.

**BRAM is now the binding constraint: 514 / 553 blocks (93%).** Main RAM is
128 of those and the sprite framebuffer will need ~160, so main RAM has to
move to SDRAM before sprites can be built.

### The video oracle and model (`tools/`)

The F3 makes all 256 scanlines independently configurable for scroll, zoom,
priority, clipping, blending and palette offset. That is too much state to
get right by writing Verilog and looking at a TV, so the chipset is modelled
in software first and checked against MAME's own output.

- `tools/oracle_f3dump.lua` — dumps all seven video RAMs, the playfield
  control registers (captured with a write tap, since 0x660000 is write-only),
  the four gfx ROM regions, and MAME's rendered frame as raw ARGB, all at one
  emulated instant. The snapshot is forced inside the same callback so the
  picture cannot drift a frame from the bytes it belongs to.
- `tools/f3_gfx.py` — decoding for all five gfx layouts.
- `tools/f3_render.py` — port of `read_line_ram`, `get_pf_scroll`,
  `calc_clip`, `mix_line`, `render_line`, `get_sprite_info`, `f3_drawgfx`.
- `tools/f3_regress.py` — renders every dumped frame, fails on any differing
  pixel.

**Result: 15/15 frames pixel-identical to MAME**, across boot, the Taito
logo, the title screen and attract-mode gameplay.

Two findings the RTL has to honour:

1. **Ray Force runs with flipscreen ON.** Its graphics are stored flipped in
   ROM and the program sets the flipscreen bit to display them correctly. Every
   tilemap is mirrored in both axes, the line-RAM index runs backwards
   (255 - screen_y), and `get_pf_scroll` takes its flipscreen branch — whose
   two x adjustments (320<<6 and (512+192)<<6) sum to exactly 65536 and so
   cancel in s16.
2. **Char RAM and pivot RAM are read byte-swapped.** They are big-endian u16
   shares, but `video_start()` hands them to the gfx decoder as
   `reinterpret_cast<u8 *>`, which swaps the two bytes of every word relative
   to the 68020's view. Against the memory image the CPU wrote, pixel 0 is the
   low nibble of byte 3 and pixel 7 the high nibble of byte 0. Getting this
   wrong scrambles pixel pairs inside every character while leaving the text
   correctly positioned on screen — it reads as a font problem, not a byte
   order problem. This is the one bug that cost real time today.

---

### Self-test page and UART debug (new)

A labelled 40x28 pass/fail page instead of a screen of bare hex, and the same
page character-for-character out of the UART. Same idea as the Raiden II core.

- `rtl/rf_selftest.sv` — value/status mux and the pixel renderer. Expected
  values (`00B80000`, `77E1C279`, `D53D7C04`, `00001000`, `10620931`, 64
  acks per 64 frames) are constants in the RTL, so the board says PASS or
  FAIL by itself instead of handing back a number to compare by eye.
- `rtl/rf_selftest_page.sv` — generated by `tools/make_selftest_page.py`;
  static text plus the layout constants both consumers read.
- `rtl/rf_font8x8.sv` — generated by `tools/make_font.py` from a stock
  cp850-8x8 console font, ASCII 0x20-0x5F.
- `rtl/rf_uart_log.sv` — walks rf_selftest's **second character port**, so
  the serial output is the page by construction rather than by two pieces of
  formatting code kept in step. One row per frame; the whole page repeats
  about twice a second, comfortably inside 115200 baud.

OSD options:

```
Aspect ratio   Original / Full Screen / [ARC1] / [ARC2]
Rotate         CCW (TATE) / CW / None         Ray Force is MAME ROT270 = CCW;
                                              rotation is through the DDR3
                                              framebuffer (scaler output only),
                                              exactly as the Raiden II core
Scandoubler Fx None / HQ2x / CRT 25% / 50% / 75%
Refresh Rate   58.9Hz Native / 60Hz           60Hz = 257-line frame (60.08 Hz)
Service Mode   Off / On                       cabinet TEST switch
Self Test      On / Off                       On = the page, Off = game video
UART Debug     Self Test / Off / Write Ring
```

F3 boards have no DIP switches: game settings are the service menu (Service
Mode + the EEPROM). Button remapping is MiSTer's own "Define buttons", driven
by the J1 list, which matches the MRA's `<buttons>`: Shot, Bomb, Start, Coin,
Service, Pause (Pause is named but not implemented yet).

UART Debug defaults to **Self Test**, i.e. on: the OSD cannot be driven
remotely, and a debug channel that has to be switched on by hand at the
cabinet is not much of a debug channel. `Write Ring` is the Phase 0/1 oracle.
The two producers are muxed onto UART_TXD and the unselected one is held in
reset so the line idles high.

Read it on the board with:

```sh
stty -F /dev/ttyS1 115200 raw -echo
cat /dev/ttyS1
```

Both were verified in Verilator before the build: the rendered page is
pixel-exact against a bitmap computed independently from the two ROMs, and
the decoded serial stream is the page verbatim.

---

## Outstanding

### Hardware result (2026-08-27, board at 172.17.1.164)

The main board runs the game and **every self-test check passes**, read both
off the screen and off the UART:

```
ROM BYTES       00B80000  PASS
ROM CHECKSUM    77E1C279  PASS
SDRAM BIST      D53D7C04  PASS
WRITE COUNT     00001000  PASS
WRITE HASH      10620931  PASS   <- unchanged by the much larger memory map,
                                    which is the point: the first 4096 writes
                                    are boot clear loops that finish long
                                    before the first vblank
FETCH IN RANGE  00000000  PASS
LAST PC         00000AAE          <- the main loop, no longer parked at the
                                     0x4060 vblank wait
FRAME COUNT     00000BA5
IRQ2 ACK/64FRM  00400A2A  PASS   <- 0x40 = 64 acknowledges per 64 frames
IRQ3 ACK/64FRM  00400A2A  PASS
PALETTE         0000FFFF  PASS
PLAYFIELD       0000FFFF  PASS
SPRITE          0000FFFF  PASS
LINE RAM        0000FFFF  PASS
TEXT AND CHAR   0000FFFF  PASS
BUILD           27093739
```

Measured separately from two screenshots 12 s apart: frame_cnt +708,
irq2_cnt +708, irq3_cnt +708 -- 59.0 Hz with the acknowledges exactly in
lockstep, and `frame_cnt - irq2_cnt` a **constant** 380 (380 frames of boot
before the game enables interrupts, then every vblank acknowledged 1:1). The
vector-fetch acknowledge scheme works.

The palette panel (Self Test = Off) fills with the game's real colours and
changes between frames.

**Fit**: timing met, worst setup slack +0.613 ns. 32% ALMs,
**518 / 553 RAM blocks (94%)**.

### Review notes (2026-08-27, end of session)

A pass over everything written today, looking for defects rather than style.
Six found, all fixed and re-verified in Verilator:

- **93C46 READ was missing the dummy bit.** The chip emits a 0 on the clock
  after the last address bit, THEN the 16 data bits. Without it the word
  arrived one bit early and read back rotated. Caught by review, not by
  hardware -- the game boots either way because it rewrites defaults over
  corrupt settings. `make -C sim eeprom` now checks EWEN/WRITE/READ/idle.
- **rf_selftest port B** evaluated the value mux on the unregistered row
  while the field masks used the registered one -- a one-cycle skew that
  rf_uart_log's wait states happened to hide.
- **rf_video_line** spent a 3-cycle read on every subsection whether or not
  anything was latched. Now skipped: mean 151 -> 112 clocks/line.
- **rf_gfx_bus** silently dropped a request arriving while busy. Now has a
  `busy` output and says so on the port; `pix` validity is documented.
- **Diagnostic page** panel frame was drawn from the look-ahead x, one
  pixel left of the panel. Cosmetic; page is superseded by the self-test.
- **IRQ acknowledge limitation named in the RTL**: any data read of
  VBR+0x68/0x6C while an IRQ is pending counts as an ack. That happens once,
  in the boot ROM checksum with interrupts masked, and is where the constant
  380-frame `frame_cnt - irq2_cnt` offset comes from. Not a gameplay issue
  (hardware shows exactly one ack per frame) but it is now written down.

Reviewed and left alone, deliberately: the control-port and EEPROM byte-lane
decode (checked against `f3_control_w` case by case), the read-mux timing
(identical to the validated spike), the BRAM read-during-write modes, and
`f3_render.py`'s s16 wraparound in the sprite axis (matches MAME).

### The bench RAM model was wrong -- and the RTL was tuned to it (2026-08-27)

The first hardware build of the video pipeline showed a black screen while
the self-test page reported the pipeline running flat out (256 lines mixed
and built per frame, ~10k tile fetches, 81920 line-buffer writes). Running
the pipe under real raster timing in Verilator was pixel-perfect. That
contradiction pointed at the one thing the benches modelled in C++ rather
than in RTL: the video RAMs.

The C++ model answered with `mem[current address]` in the same cycle -- a
zero-latency RAM. The real BRAM (and rf_bram's own Verilator model) registers
the address and answers the cycle AFTER. Two modules had been written for the
real timing, "failed" the bench, and were then changed to satisfy it: the
playfield builder's attribute/code latch and row scan, and the mixer's
palette sampling. With the bench model corrected the sim reproduced the
hardware (4001/71680 pixels), the RTL was put back to real timing, and every
bench is green again under the correct model.

Rules that come out of this:
- a bench memory model must implement the documented BRAM contract (address
  registered, data the cycle after) -- or better, instantiate rf_bram's
  Verilator model instead of writing a C++ one. Follow-up: move the video
  RAMs into the sim wrappers so the benches use the real model.
- when correct-looking RTL fails a bench, suspect the bench before changing
  the RTL. The attribute latch was right the first time.
- the self-test page's per-frame video counters (MIX:BUILD, FETCH:LBUF,
  MAXFETCH:BUILD) are what made this diagnosable in one round trip instead
  of several. Real SDRAM tile-fetch latency measured 23 clocks against the
  sim's 12; longest build 1663 of 3456.

### Second session, 2026-08-27 evening: deployed, still black, instrumented

The 12:52 build (stamp `27123634`, the one with the BRAM-latency fix) had
been compiled but **never uploaded** -- the board was still on the 12:30
bitstream. The MiSTer process was also hung: `/dev/MiSTer_cmd` had two
writers blocked on it (one a stray `load_core` of an unrelated core's MRA
from other tooling) and pid 527 sat at 100% CPU without draining the FIFO,
so neither the UART capture nor a screenshot returned anything.

**Restarting a hung MiSTer process** (there is no respawn; inittab starts it
once at sysinit):

```sh
kill -9 <stuck writer pids>; killall MiSTer; sleep 2
cd /media/fat && setsid nohup /media/fat/MiSTer >/dev/null 2>&1 </dev/null &
```

(paramiko's exec channel times out on the detached start; check with a fresh
connection -- `ps | grep '[/]media/fat/MiSTer'` and a new inode on
`/dev/MiSTer_cmd`.)

Deployed 27123634: **every check on the page passes**, including the video
counters -- `MIX : BUILD 01000100`, longest SDRAM tile fetch 0x17 = 23 clocks,
longest build 0x099A = 2458 of 3456. The game video is **still black**
(`/media/fat/config/Rayforce.CFG` = `08`, i.e. Self Test Off, so the black
screenshot is game video, not the page).

Two things follow from that:

1. The bench-latency fix was right but **could not have been the black
   screen's cause**: with the wrong latency the sim matched 4001/71680 pixels
   -- wrong colours, not black. The black screen has a different cause and
   it has been there since the first video build.
2. The self-test rows prove the decoder and builder are reading line RAM and
   playfield RAM correctly on hardware -- 10888 tile fetches per frame against
   the sim's 10892 for the same attract frame. What they do NOT prove is the
   content of those fetches, or anything downstream of the mixer.

Ruled out by reading, this session: `rf_bram_tdp` port B is 1-cycle
unregistered like the bench; `rayforce_video`'s counters are the bench's
verbatim; the MRA stream offsets match `rf_gfx_bus` BASE_LO/BASE_HI and the
loader writes the stream flat; the palette word order is the 68020's (the
oracle dumps shares with `read_u8` in CPU byte order); Quartus reports no
latch, stuck-at or removed-register warning in the video path. Never verified
on hardware: **the SDRAM contents above 0x480000** (the BIST reads back only
the 1 MB maincpu region) and the mixer -> line buffer -> output path with
real data.

So the page now says which it is. Two rows changed/added, values latched per
frame:

```
FETCH : PIX NZ    {tile fetches, output pixels that are not black}   PASS if pixels != 0
TILE NZ:PF:PAL    {fetches whose 16 pixels were not all zero,
                   OR of playfield samples[7:0], OR of palette reads[7:0]}
                                                                     PASS if all three != 0
```

*(Since 2026-08-29 those two verdicts, and MAXFETCH:BUILD's, are sticky:
PASS latches the first frame the condition holds and BUSY is shown until
then, so a blank frame no longer reads FAIL. The values stay per-frame. See
"Self-test rows that failed on blank frames" at the top of this file.)*

Reading them (sim reference for frame 1800: `2A8C58F7` and `2A8C9FFF`):

| TILE NZ | PF | PAL | PIX NZ | it is                                             |
|---------|----|-----|--------|---------------------------------------------------|
| 0       | -  | -   | -      | SDRAM tile data reads as zero: contents or channel |
| >0      | 0  | -   | -      | the 6bpp unpack into the playfield line buffers    |
| >0      | >0 | 0   | -      | the palette port                                   |
| >0      | >0 | >0  | 0      | the mixer                                         |
| >0      | >0 | >0  | >0     | line-buffer readout or the output mux -- the       |
|         |    |     |        | pixels were made and lost on the way out           |

Also in this build: the OSD video options above (aspect, rotate via
`screen_rotate`, scandoubler fx, 60 Hz), and `rate_60` threaded into
`rayforce_video` (V_TOTAL 257, vsync at lines 1-3) and `rf_video_pipe` (the
lookahead wrap uses V_TOTAL-2/-1 in both cases). `make -C sim pipe pipe-60`
runs the pipe at both frame lengths: 71680/71680 pixels identical either way.

### The text layer -- `rtl/rf_video_pivot.sv` (2026-08-27, evening)

Built while the diagnostic build was compiling, because it needs no SDRAM
and its RAM ports (text, char, pivot) were already brought out of rf_main.
Per line, after the decoder finishes (the same `pf_go` the playfield builder
starts on): a 64-word scan of the text-RAM row for MAME's row-usage skip,
then one pixel per clock -- source x (mosaic hold, scroll, flipscreen) ->
text-RAM tile word -> char-RAM (or pivot-RAM) word -> nibble -> line buffer.
Double-banked; the mixer reads it at `smp_x` from the bank it is composing
and takes `pv_used` from the same bank. ~390 clocks per line, concurrent with
the playfield build.

Verified: **15/15 dumped frames pixel-identical to the model through the
whole pipe** (`make -C sim pipe-all`, now with `F3_ONLY=pv,pf0..3`), at both
frame lengths. The one bug found on the way: the model's `x_index` takes the
RASTER x, so the scroll register carries a +46 -- without it the text sat 46
px off, which the bench caught on the first run.

Coverage caveat, stated rather than hidden: every dumped frame drives the
VRAM (tilemap) source with mosaic off. The pixel-layer source (with its
borrowed-palette row hack) and the mosaic hold follow the model line by line
but have no dump exercising them.

`Rayforce.sv` now feeds the pipe the three RAM ports; only sprite RAM is
still parked. Not yet through Quartus at the time of writing -- that is the
build after the diagnostic one.

### The picture is up (2026-08-27, build 27162801)

Deployed the playfields + text build to the board (172.17.1.164). Result, on
screen and over the UART:

- The **notice screen** renders -- the US "FOR USE IN THE UNITED STATES OF
  AMERICA, CANADA, AND MEXICO ONLY" warning, correct text, correctly
  oriented for the rotated cabinet.
- **Attract-mode gameplay** renders: the terrain playfields (rivers,
  mountains, clouds) scrolling frame to frame, full colour, with the text
  HUD over them -- INSERT COIN, 1UP, HI SCORE, the score digits, CREDIT,
  LASER. Two shots 5 s apart show the playfields scrolled, i.e. it is live,
  not a static frame.

Every self-test row passes, including the new diagnostics:

```
TEXT AND CHAR   0000EBAB  PASS
MIX : BUILD     01000100  PASS
FETCH : PIX NZ  3E1BFFFF  PASS    <- 15899 tile fetches, output non-black
                                     pixels saturated (was 00000000 = black)
MAXFETCH:BUILD  00170C23  PASS    <- longest fetch 23 clks, longest build
                                     3107 of 3456 -- 349 clocks of margin,
                                     the tightest number on the page now
TILE NZ:PF:PAL  3E1B9FFF  PASS
```

**What the black screen actually was.** Not the BRAM-latency bug (that gave
wrong colours, not black) and not anything downstream of the mixer. The only
build ever deployed before this was the playfields-only pipe, and the first
thing the program draws is the text-only notice screen -- so there was
genuinely nothing for the playfields to show. The diagnostic rows added this
session would have said so in one read (PIX NZ = 0 with TILE NZ > 0), but the
text layer answered it first by making the picture appear. Lesson: before
calling a black screen a pipeline fault, check what the program is actually
drawing on that frame.

`MAXFETCH:BUILD` is now the row to watch: longest build 3107/3456. The pivot
build runs concurrently but the number crept up (2458 -> 3107) because both
share the cpu clock; sprites will add more. If it reaches 3456 the pipeline
overruns the line and the design needs the lookahead widened to two lines or
the build sped up.

### The whole video pipeline is verified in sim, sprites included (2026-08-27)

**`make -C sim pipe-all` -- every dumped frame, 71680/71680 visible pixels
identical to the model (= MAME), through playfields + pivot/text + sprites**,
at both frame lengths, including the 198-sprite frame 3000. The complete F3
video chipset now exists in RTL and matches the oracle end to end. What is
left is hardware integration (Rayforce.sv wiring, the SDRAM channel share,
the BRAM-fit decision) and a build -- not new pixel logic.

The sprite engine (`rf_video_spr`) is wired into `rf_video_pipe`: prepass on
frame_start into one of two bucket banks while the draw reads the other
(1-frame lag; MAME's is 2, tune on hardware), drawing the same build line as
the playfields, sampled by the mixer at smp_x for the line it composes. The
draw is FETCH-PIPELINED -- the next record's tile row is prefetched while the
current record draws -- which was necessary: frame 3000 puts ~114 sprite-rows
on one line, and fetch-then-draw (~43 clk/record) overran the 3456-clk line
budget and dropped the line; pipelined (~24 clk/record) it fits. The roadmap's
"max 43/line, no framebuffer needed" measurement was from a lighter capture;
114/line is real, and the per-line design only holds for it with the prefetch.

### Sprites: all three RTL blocks done and verified (2026-08-27)

Building the sprite engine in the same verify-each-stage way as the
playfields. Two of the three RTL pieces are done and byte-exact against the
model:

- `rtl/rf_video_spr_list.sv` -- the list walker (get_sprite_info): the Axis
  position/zoom state machine, bank switch, jump command, multi-block sprites
  and the two-level scroll globals. Streams the drawable sprite list.
  **Every dumped frame's list is byte-identical to the model**
  (`make -C sim spr-all`), including the 198-sprite frame 3000. Two width
  bugs found and fixed by the bench: 10-bit list counters made the 1024-entry
  limit compare as >= 0 (walk stopped after entry 0), and the sprite RAM read
  needed the registered-address BRAM model in the bench (same trap as the
  pipe benches).
- `rtl/rf_spr_gfx_bus.sv` -- sprite tile-row fetch, cloned from rf_gfx_bus
  with the sprite regions and sprite_hi packing. **584/584 rows byte-exact**
  (`make -C sim spr-gfx`).

The third block, `rtl/rf_video_spr.sv`, is now written and verified too:
**every dumped frame's sprite line buffer and per-line row-usage is
pixel-identical to the model's framebuffer** (`make -C sim spr-line-all`),
through the 198-sprite frame 3000, with zoom. It walks the list into a
per-line bucket of row-records (a sprite spread over the lines it covers via
the dy8 accumulator), then per line fetches and lays down each record with
the dx8 accumulator; the line buffer tags each pixel with its line so it
never needs clearing. The subtle bug the bench caught: when zoom crushes
several source rows onto one screen line they OVERLAY (a later row fills the
earlier one's transparent gaps) -- a "first row per line wins" shortcut drops
those, so every row is emitted, in reverse-row order, and drawn with
overwrite to reproduce the model's forward-row/reverse-list write-if-empty.

What is left for sprites is INTEGRATION, and the two decisions still land
there:

**1. Zoom is required.** The measurement in "The sprite framebuffer question"
below said no framebuffer is needed, and that still holds -- but it did NOT
say sprites don't zoom. They do, heavily: frame 1799 has scale-16 sprites
(16 source rows crushed to one line), frame 3000 mixes 107/114/144/174 and
even anisotropic 64x256. So the builder cannot assume full-size 16x16; it has
to reproduce the model's dy8/dx8 accumulators (source row per screen line,
source pixel per screen pixel, with the zoom-out dedup rule that the LAST
source pixel mapping to a screen pixel wins in x and the FIRST source row
wins in y).

**2. BRAM is the wall.** The current build is 530/553 blocks (96%); only 23
are free. A zoom-correct line builder wants to expand each sprite into its
per-screen-line row-records and bucket them by line -- and a busy frame
(frame 3000, ~198 sprites, many full-size) produces ~2000-2500 such records.
At ~56 bits each that is 13-16 RAM blocks for the record store alone, plus
the next-pointer store and the line buffers -- right at or over the 23 free.

So the builder either:
  (a) fits economically into 23 blocks with a hard record cap, DROPPING
      sprites on the busiest frames (a visible quality loss, logged not
      silent); or
  (b) waits for the main-RAM-to-SDRAM migration (frees the 128 blocks main
      RAM occupies) that the roadmap always flagged as maybe-needed for
      sprites -- a bigger change, but then sprites have all the room they
      need and this stops being a corner to design around.

This is the point the roadmap predicted ("main RAM has to move to SDRAM
before sprites can be built" -- though the framebuffer-free design pushed
that back, the record store brings it back for busy frames). It is a real
architecture call, so it is the user's to make rather than something to
quietly commit to.

### Sprite hardware integration (2026-08-27, late evening)

The sprite engine met Quartus. All sims re-run green AFTER every change
below: `spr-line-all` 15/15, `pipe-all` 15/15 (frame 3000's 198 sprites
included), `pipe-60` -- all 71680/71680 pixels identical to the model.

- `Rayforce.sv` -- the sprite RAM B port is wired to the pipe (was parked at
  `15'd0`), and the vpipe instantiation caught up with the pipe's real port
  list (the tree was mid-integration: it still connected the retired
  `sp_color`/`sp_used` tie-offs and would not have compiled).
- `rtl/rf_spr_ch_share.sv` (new) -- the two sprite gfx planes share ch4, the
  only free SDRAM channel. Grant-and-hold mux with a served-mask: a plane's
  request LEVEL outlives its completion by the CDC crossing, and without the
  mask the arbiter re-grants an already-served plane, double-toggling the
  completion and desyncing rf_spr_gfx_bus's edge detector for good.
- `sim/pipe_top.sv` (new) wraps the pipe with rf_spr_ch_share and pipe_tb
  drives ONE shared sprite channel, so the arbiter and the serialised fetch
  latency are covered by the whole pipe regression instead of meeting
  hardware untested. The sprite draw now starts at the top of the raster
  line (spr_start at div 2, new in rf_video_pipe) instead of after the line
  decoder: it has no decode dependency, and the doubled fetch latency of the
  shared channel makes the extra margin worth having on hardware, where ch4
  is the lowest-priority channel. (Whether the old pf_go start would also
  have passed was not re-tested; the early start costs nothing.)
- `rf_video_spr.sv` hardware mapping -- slist/rec/rnext are MLABs,
  head/tail stay registers (frame_start clears a bank in one cycle). Three
  Quartus lessons, each learned from a failed map:
  1. N separately-sliced reads of one array (`rec[rb][fc][53:36]` etc.)
     defeat memory inference entirely ("can't infer memory", then synthesis
     dies under ~500k of flip-flops). One full-word read wire, sliced after,
     is the pattern it accepts.
  2. Inferred RAM needs defined read-during-write behaviour; the async-read
     MLAB has none, so `ramstyle = "MLAB, no_rw_check"` is required. Safe
     here: slist is written and read in different prepass states, and
     rec/rnext writes (bank wb) never share an address with reads (bank rb).
  3. An MLAB has ONE write port. The bucket append wrote rnext twice in a
     cycle (the new record's null link and the old tail's link); the link
     write moved to a new P_LINK state. The first version of that split
     dropped the explicit `pst <= P_EXP1` from the advance path, parked the
     FSM in P_LINK, and silently stopped appending records -- spr-line-all
     caught it immediately. When a "stay in state" idiom moves to a
     different state, "stay" has to be written out.
- The `.qsf` was also missing rf_video_pivot/rf_video_spr_list/
  rf_spr_gfx_bus/rf_video_spr (only rf_video_pipe had been added) -- the
  deployed text-layer build predates the pipe module, which is why that was
  not caught earlier.
- `build.sh` -- the build scope now runs under `choom -n 1000`, so if the
  machine is short of RAM the OOM killer picks the build and not whatever
  else is running (this systemd predates `-p OOMScoreAdjust`).

The BRAM wall the roadmap worried about did not materialise: the sprite
stores cost zero M10Ks (all MLAB), so main RAM can stay in BRAM for now.

### Sprite / SDRAM review: fit and latency (2026-08-27, night)

A review of how the sprite engine and the SDRAM path would meet the
hardware, before the first sprite build. Two findings, both measured rather
than argued, and both addressed.

**1. The sprite draw overran dense lines at real SDRAM latency -- silently.**
The pipe bench's channel model answers 14 ram clocks after a request, with
no contention. The board measured the tile fetch at 23 clk_sys busy against
the bench's 12. Frame 3000 (198 sprites, 3144 row-records, four lines with
114 records) at higher bench latencies:

| bench latency | one fetch in flight (as built) | two in flight (this session) |
|---|---|---|
| 14 | 71680/71680 | 71680/71680 |
| 20 | 164 px wrong, lines 114-117 | 71680/71680 |
| 34 | 253 px wrong, 2 lines lost | 203 px wrong, 2 lines lost |

and frame 2400 (a routine 147-sprite frame, 74 records/line) at 34: 2 lines
lost as built, identical with two in flight. The single-slot draw cost the
whole SDRAM round trip per record (two bursts on the lowest-priority
channel plus the CDC both ways, ~30 clk); 114 x 30 > 3456. Worse, the
overrun was invisible: `rf_video_spr` samples `line_start` only when idle,
so a late line simply eats the next line's start and that line gets no
sprites, and nothing counted it.

Done about it:
- **`SPRLINE : MISS`** row on the self-test page (it replaced the UART note
  row -- the page is exactly 28 rows): {longest sprite line draw in clocks,
  line starts missed because the draw was still busy}. PASS = none missed
  and the longest under 3456. This is the number that calibrates the bench.
  The bench had to step through one more `frame_end` before printing its
  diagnostics: it was printing frame 2's, whose bucket bank the prepass had
  not filled yet (the one-frame lag), so `sprmax` always read 1.
- **Two fetches in flight** (`rf_video_spr`, build 2 of the night): two
  `rf_spr_gfx_bus` instances take alternate records, a two-slot queue hands
  them to the draw in issue order (the overwrite semantics depend on that
  order), and `rf_spr_ch_share` arbitrates four planes with a rotating
  priority in the order A.lo, A.hi, B.lo, B.hi -- a record's two planes go
  back to back and the older record's planes before the younger's. With the
  channel kept busy the 17-clock draw is the bound: 114 x 17 = 1938.
- `make -C sim pipe-lat` -- frame 3000 at latency 24 as a gate, 34 printed
  for information. Note what the bench's latency IS: through `ch_share`
  only one burst is ever outstanding, so `lat` is the per-burst OCCUPANCY of
  the shared channel, i.e. it stands for the controller's turnaround, not
  the fetch's round trip. Traced through `rf_sdram`'s states that turnaround
  is ~14 ram clocks idle (sync 2, ACTIVE, WAIT, READ, CAS 3 + burst 4, and
  the IDLE_5..1 spacing overlaps the next request's sync), more with the
  playfield channels contending. So 34 is pessimistic and the 114-record
  line cannot fit 228 x 34 whatever the queue depth; the page row settles
  where the board really is.

**2. The BRAM wall had moved into the MLABs, at 97 %.** "Sprite stores cost
zero M10Ks" was true; here is where they went (an MLAB is 32 x 20 bits):
`rec` 2 x 3328 x 54 = 624 MLABs, `rnext` 208, `slist` 128 -- 960 of the 985
MLAB-capable LABs, which is why the fitter died at 4096 records and 3328 was
chosen (6 % over the measured peak of 3144). And `head`/`tail` were 12288
flip-flops behind three 512:1 muxes, purely so `frame_start` could clear
them in one cycle. Done about it, all in `rf_video_spr`:
- A record is now `{sprite index, source row}` = 14 bits; the per-sprite
  fields (x, x scale, code, colour, flipx) that every one of a sprite's 16
  rows used to carry are stored once and looked up at draw time. The list
  is split by consumer: `sl_y` (ty, y scale, flipy) is read only by the
  expand in the same prepass that wrote it -- single bank; `sl_d` is read by
  the draw a frame later -- double banked. Neither needs a second read port.
- `head`/`tail`: `hvalid` is one bit per line per bank in registers (the
  one-cycle clear is now 256 bits), `head` is an `rf_bram` read by the draw
  with the BRAM's one-cycle latency, `tail` an MLAB read only by the
  prepass. Neither needs clearing because `hvalid` gates every read.
- The draw's record lookup is two deep (`rec` -> `sidx_r` -> `sl_d`), so the
  prefetch waits until it settles (`fc_ok`); a `P_RD` state reads `tail`
  the cycle BEFORE `P_EXP1` writes it, because an async-read MLAB with
  `no_rw_check` has no defined same-cycle same-address read-during-write and
  the RTL must never do one.
- NREC back to 4096 (30 % over the measured peak instead of 6 %). MLABs:
  `rec` 256 + `rnext` 256 + `sl_y` 64 + `sl_d` 192 + `tail` 16 = ~780 (80 %)
  against 960 (97 %) before, and ~12k flip-flops and their muxes gone.
  Fallback if the fitter still objects: NREC 3328 gives ~690.

Also fixed from the review: `rf_spr_ch_share` sampled the cpu-domain
request levels raw in the ram domain and used them the same cycle -- the
one new crossing without the two-flop synchroniser every other one has
(the controller's own channel requests included); and `video_rotated` was
generated by `screen_rotate` but never connected to `hps_io`, so the OSD
would have drawn unrotated over the TATE picture.

Left alone, deliberately: the SDRAM controller. One outstanding op, ~8 ram
clocks per 8-byte burst with auto-precharge, no bank interleave -- half the
raw bandwidth, but the worst line's aggregate (120 playfield + 228 sprite +
CPU + ~13 refresh bursts) is ~70 % of what it can do. Latency, not
bandwidth, was the problem, and that is fixed on the client side.

**Quartus lesson (a map crash):** `logic [255:0] hvalid [0:1]` with
`hvalid[wb][ex_dyb] <= 1'b1` -- a bit write into an element of an UNPACKED
array -- makes Verific treat it as a partial RAM write and quartus_map dies
with `Internal Error: Sub-system: VRFX ... AssignRam`. Declared PACKED
(`logic [1:0][255:0]`) it is a bit-select of a register vector and maps
fine. Same rule as the MLAB one: an unpacked array is a memory to Quartus,
and only whole-element reads and writes are safe on it.

All sims green after every step: `spr-line-all` 15/15, `pipe-all` 15/15,
`pipe-60`, at both the one- and two-slot draw.

### Build 27212838 on hardware: sprites up, and the overrun measured

The first sprite build (slim records, hvalid/head/tail, ch_share sync,
video_rotated, SPRLINE row; ONE fetch in flight). Fit: timing met (clk_sys
+2.69 ns, clk_ram +1.69 ns), **M10K 534/553, memory LABs 784** (the 960
estimate for the old layout, and ~780 predicted for this one), total LABs
3918/4191 (93 %) -- the async-read MLAB muxes are ALMs too, and that 93 % is
the number to watch when the sound board arrives. 30-minute compile.

On the board (172.17.1.164), read over the UART during attract mode:

```
FETCH : PIX NZ  350471A6  PASS
MAXFETCH:BUILD  001709A3  PASS     <- 23-clock fetch, longest build 2467
TILE NZ:PF:PAL  34FE9FFF  PASS
SPRLINE : MISS  0DFE0002  FAIL     <- longest sprite line 3582 clocks,
                                      2 line starts missed
```

**Sprites render** -- the ship, asteroids, the enemy fleet, the ITEM marker,
the lock-on instruction panel (screenshots/s2_20260828_020409-screen.png) --
and the overrun predicted in sim happens in ordinary attract play. The
number calibrates the bench: 3582/2 matches frame 2400 at bench latency
32-34 (`0E85 0002`), i.e. the shared sprite channel's real per-burst
turnaround is ~30 ram clocks, not the ~14 an idle controller would give.
ch4 is the lowest-priority channel and the CPU's line-cache misses (ch3)
and the playfield bursts (ch1/ch2) go in front of it.

Two consequences:
- Build 2 (two fetches in flight + the playfield fetch/unpack overlap +
  the 20-bit sprite line buffer) will bring a dense line down to ~2 x
  turnaround per record, ~26-35 clocks, channel-bound: it should pass the
  attract frames but may still miss on frame-3000-class lines (114
  records). The row will say.
- The robust fix is to stop paying per line at all: let the sprite draw run
  AHEAD of the raster into a ring of line buffers (4-8 banks, ~5 M10Ks for
  8 x 320 x 20 bits) instead of one line per line_start. The buckets are
  ready for the whole frame, sprites cost ~10 % of the frame on average
  (3144 records x ~30 clocks = ~95k of 885k clocks), and only local density
  matters -- a ring of N absorbs N-1 consecutive dense lines. That is
  independent of any SDRAM tuning and does not touch the verified draw.
  Raising ch4 above ch3 in rf_sdram is the cheap alternative, at the cost
  of CPU stalls on dense lines.

The two "FAIL"s in the text-only samples (notice screen: MAXFETCH:BUILD
`00000111`, TILE NZ `0000`) are the known text-only-frame artefact, not
faults; the rows assume a frame with playfields. *(Fixed 2026-08-29: those
verdicts now latch, and a blank frame reads BUSY or the earlier PASS -- see
the top of this file.)*

### The run-ahead sprite ring (build 3), and Phase 3 queued

`rf_video_spr` no longer draws one line per raster line. From frame_start
it draws lines 0..255 in order, as fast as the fetches allow, into a ring
of NB=4 line buffers (4 x 512 x 20 bits = 4 M10Ks), held back only by the
mixer's line: the draw may be up to NB-1 lines ahead, in 8-bit modular
arithmetic so the frame wrap needs no special case. `lines_done` comes out
to `rf_video_pipe`, whose SPRLINE row now counts *lines the mixer started
before the draw had finished them* (the number that matters) alongside the
longest single line. The buckets are ready for the whole frame and sprites
cost ~10 % of it on average, so only local density matters; NB=4 absorbs
three consecutive dense lines and is a one-line change to widen.

Verified: `spr-line-all` 15/15, `pipe-all` 15/15, `pipe-60`; frame 3000 at
bench latency 34 -- which lost two lines with one fetch in flight and still
lost them with two -- passes with a 4542-clock line and 0 late; frame 2400
at 34 passes. Latency 50 (pessimistic beyond anything measured) still shows
7 late lines: that is the point at which the average, not the peak, no
longer fits, and nothing per-line fixes that.

The bench drives it as the mixer would: `rd_line` is the mixer's line and
the bench waits for `lines_done` to pass it before reading a line back.

Phase 3 (sound) is written up in ROADMAP.md as a staged plan with its two
walls (the 64 KB sound RAM vs ~18 free M10Ks; two more SDRAM streams with
all four channels taken) and an oracle-first order, the same shape that
worked for video.

### Missing parts, listed (2026-08-28, for after sound)

Things the core does not do yet, with what each needs. None is blocked on
a design decision except NVRAM's MiSTer-side detail.

- **Pause** -- done in B4: the J1 "Pause" button toggles a hold on the main
  CPU's clock enable (`rf_main` `pause`); video keeps running. The sound
  CPU is not paused (it does not exist in B4); when it does, pause should
  hold it too or the music keeps playing over a frozen game.
- **Region variants** -- `releases/Gunlock.mra` and `releases/Ray Force
  (Japan).mra` written (ic35 d66-24 / d66-20, CRCs from taito_f3.cpp).
  Untested on the board; the notice screen differs per region.
- **NVRAM (EEPROM save/load)** -- the 93C46 contents are in registers in
  `rf_eeprom_93c46` (64 x 16). The MRA already declares `<rom index="254"
  type="nvram">`, so MiSTer sends 128 bytes on ioctl index 254 at load
  (the .nv file if one exists, else the MRA's default `FF FF`): the LOAD
  side is a 64-word write port on the EEPROM taken from `ioctl_wr` with
  `ioctl_index == 254`. The SAVE side is `hps_io`'s `ioctl_upload` /
  `ioctl_rd` / `ioctl_din` path, which needs the core to answer reads of
  the same 128 bytes, and needs to be told how MiSTer main triggers the
  upload for arcade cores (OSD "Save settings" vs. `ioctl_upload_req` from
  the core on a write) -- check a core that saves NVRAM (Arcade-Raiden2's
  MRA uses index 254 for DIPs only, load-only). Not built until that is
  confirmed; a wrong guess costs a 35-minute build to learn nothing.
- **Sprite lag** -- the RTL draws sprites one frame after the CPU wrote
  them, MAME two (`sprite_lag` in the gunlock config). Visible only as
  sprites leading the scroll by a frame, if at all; a triple-banked bucket
  store would match MAME at ~+256 MLABs, or the prepass could be started a
  frame later from a snapshot. Decide from what the eye says on the board.
- **Sprite trails** (`trails` bit in the list, unread in the RTL): Ray Force
  never sets it (measured in Phase 2). Other F3 games do.
- **Pivot RAM / pixel layer** -- stubbed from B5 on (Ray Force never writes
  it; `PIVOT WR:SND PC` counts writes so the assumption is checked every
  run). Any other F3 game on this core needs it back, and then the sound
  RAM needs the SDRAM route.
- **60 Hz refresh option** -- verified in sim at 257 lines, never watched on
  the board.
- **Mosaic** and the pixel-layer source of the text layer -- follow the
  model line by line but no dump exercises them.
- **EEPROM defaults** -- volatile until NVRAM lands: the game rewrites its
  settings on every boot after the "bad settings" path.

### Known issues carried forward

- ~~UART compare needs manual pass alignment.~~ Fixed: `tools/rf_ring_check.py`
  anchors on a `===` pass header, so the workaround is a script rather than a
  snippet to copy out of this file.
- **prog_bus line cache across re-download.** The loader bypasses prog_bus, so
  its line cache is not invalidated by a download. Only matters if the ROM is
  re-downloaded without a core reset; the menu Reset pulses `bus_reset` and
  clears it.
- **MiSTer_cmd FIFO.** If `/dev/MiSTer_cmd` stops working (deleted inode),
  kill and restart the MiSTer process.

---

## How to run the video oracle

```sh
# dump three consecutive frames (sprite_lag is 2, so a frame can only be
# reproduced when its two predecessors were dumped too), plus the gfx regions
F3DUMP_REGIONS=1 F3DUMP_FRAMES=1798,1799,1800 F3DUMP_DIR=dump \
  mame rayforce -rompath . -video none -sound none -nothrottle -norotate \
       -autoboot_script tools/oracle_f3dump.lua -seconds_to_run 32

python3 tools/f3_render.py dump 1800 --compare   # one frame
python3 tools/f3_regress.py dump                 # every dumped frame

F3_ONLY=pv python3 tools/f3_render.py dump 1800  # render one layer only --
                                                 # how a partially built RTL
                                                 # renderer gets compared
```

Use the system `python3` (it has numpy and PIL); the `.venv` is only for
paramiko.

---

## How to build

```sh
cd /storage01/code/c_things/raiden-mister/Arcade-rayforce_MiSTer
./build.sh
```

## How to deploy

```sh
./build.sh                                  # writes output_files/Rayforce.rbf
.venv/bin/python3 tools/rf_deploy.py        # upload, load_core, screenshot
```

The board is **172.17.1.164**. Plain `ssh` key auth fails on it -- the tools
use paramiko with the password, which works. The MRA's `<rbf>Rayforce</rbf>`
matches any `cores/Rayforce*.rbf` and MiSTer takes the last by name, so the
upload is timestamped and sorts newest-last.

## How to validate

Everything the old hex page reported is now on the self-test page, labelled,
with the expected values checked in RTL. Read it either way:

```sh
.venv/bin/python3 tools/rf_deploy.py         # screenshot -> screenshots/
.venv/bin/python3 tools/rf_uart.py -t 10     # the same page over the UART
```

A good run looks like:

```
ROM BYTES       00B80000  PASS
ROM CHECKSUM    77E1C279  PASS
SDRAM BIST      D53D7C04  PASS
WRITE COUNT     00001000  PASS
WRITE HASH      10620931  PASS
FETCH IN RANGE  00000000  PASS
LAST PC         0000064C
FRAME COUNT     0000xxxx
IRQ2 ACK/64FRM  0040xxxx  PASS     <- the 0040 is the acknowledge RATE: 64
IRQ3 ACK/64FRM  0040xxxx  PASS        acks per 64 frames, i.e. exactly one
PALETTE         0000FFFF  PASS        per frame. A raw counter cannot tell
PLAYFIELD       0000xxxx  PASS        that apart from double-acknowledging
SPRITE          0000FFFF  PASS        half the frames.
LINE RAM        0000FFFF  PASS
TEXT AND CHAR   0000xxxx  PASS
BUILD           ddhhmmss           <- ddhhmmss of the compile. If this is not
                                      the build you just made, the board is
                                      running a stale core.
```

`WAIT` means a check has not started, `BUSY` means it is in progress (the ROM
download, or the CPU still working through the boot writes). Anything still
`BUSY` a few seconds after load is a real failure.

That block is the early page; it has since grown to 28 rows. The two that
matter for the sprite engine are **peak-held**, and reading them correctly is
the difference between "clean" and "not looked":

```
SPRLINE : LATE  aaaabbbb     aaaa = longest single sprite line, in clocks
                             bbbb = lines the mixer composed before the draw
                                    had finished them  (the budget is 3456)
SPR REC : DROP  aaaabbbb     aaaa = peak sprite RECORDS in a frame (a record
                                    is a run of rows since 2026-08-29; before
                                    that, a row -- do not compare across)
                             bbbb = records dropped because the store was full
```

**Both halves start at zero and only begin accumulating after the core has
been running a while**, so a reading taken seconds after a load says nothing.
Leave the core in attract for two minutes or more before believing it. Every
capture in this handoff before 2026-08-28 was taken too early, which is why
the sprite overrun went unnoticed through two releases.

### Write-stream oracle (Phase 0/1)

Set **UART Debug** to `Write Ring` in the OSD, capture, and compare against
MAME's `rf_acc.tr`. `rf_write_compare.py` compares from the first parsed op
and a capture almost always starts mid-pass, so anchor at a `===` header:

```sh
.venv/bin/python3 tools/rf_uart.py -t 12 -o rf_uart.log
.venv/bin/python3 tools/rf_ring_check.py rf_uart.log
```

## How to screenshot

```sh
# On the MiSTer: echo "screenshot" > /dev/MiSTer_cmd
# then pull /media/fat/screenshots/rayforce/*.png
```
