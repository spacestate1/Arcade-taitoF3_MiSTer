# Release notes

What changed in each release, and the rules every release has to meet.

## Rules for a release

These are not optional and they are not judgement calls. A release that
breaks any of them is not a release.

1. **List the changes in simple, concise terms.** One line per change, in
   plain language, saying what a player will notice. Not commit messages,
   not internal names, not the reasoning. If a change is invisible to the
   player, it does not need a line.

2. **Ship every `.rbf`.** `releases/` must contain the bitstream for this
   release *and* every earlier one it has ever shipped. Users pin to a
   working core and roll back when a new one misbehaves; deleting an old
   bitstream takes that away. `builds/` and `output_files/` are gitignored,
   so a bitstream that is not copied into `releases/` and committed does not
   exist for anyone who clones the repository.

3. **Games must boot to the game.** Not the self-test page, not Service
   Mode. This has to hold even on a card whose saved `Rayforce.CFG` has one
   of those switched on from an earlier session.

4. **Games must start on level 1.** No zone or level injection in a
   shipping MRA, and no MRA that pins UART Debug to a diagnostic mode.
   Those exist -- `(zone 2)` and `(write ring)` variants -- but as of
   2026-09-09 they live in `debug-mra/`, which is gitignored, NOT in
   `releases/`. `releases/` contains only what ships, so `md5sums.txt`
   describes exactly the shipped set and a clone cannot pick up a core that
   starts on the wrong level or talks debug over the UART.

5. **Refresh `md5sums.txt`.** Run `python3 tools/check_files.py --update`
   after changing anything in `releases/`, and `python3 tools/check_files.py`
   to confirm it passes before committing.

### How to check rules 3 and 4 before releasing

Rule 3, in `Rayforce.sv`: `Self Test` and `Service Mode` are the two OSD
options that can boot something other than the game. Both must list `Off`
first in `CONF_STR`, because MiSTer's status word powers up at 0 and takes
the first entry. That alone is not enough — MiSTer replays a *saved* status
word over the top of it — so both bits are also armed in RTL (`st_inherit` /
`sv_inherit`): whatever value a bit carries when the ROM download ends is
treated as inherited and ignored, and only a deliberate change afterwards
turns it on. Both power up armed, so an inherited page never shows.

Rule 4, in the MRAs: the start zone is bits `[4:3]` of the config byte on
ioctl index 1, and `rf_main.sv` only intercepts the level write when those
bits are non-zero. Decode them for every MRA you are shipping:

```sh
for f in releases/*.mra releases/experimental/*.mra; do
  b=$(grep -A2 'index="1"' "$f" | sed -n 's:.*<part>\([0-9A-Fa-f]\{1,2\}\)</part>.*:\1:p' | head -1)
  [ -z "$b" ] && b=00
  printf '%-46s byte=0x%-2s zone_inj=%d\n' "$(basename "$f")" "$b" $(( (0x$b >> 3) & 3 ))
done
```

`zone_inj` must be 0 for every MRA. The only files allowed to report 1 are
the ones with `(zone 2)` in the name.

**`python3 tools/check_mra_cfg.py` does this and more, and is the gate to
run.** It decodes every config byte in every shipped MRA and fails on a
start zone in a non-debug file, on two different games sharing a game id,
on a shipping MRA that pins the UART to a debug stream, and on the 12-bit
palette being claimed by both the MRA and the RTL id table. Both of its
first two checks were verified against real historical failures before it
was trusted. Last run 2026-09-08: 39 MRAs, 36 distinct ids, all pass.

Why this exists: every other gate in the project validates a transform --
the benches feed the RTL a stream captured from MAME and compare the
output. Config bytes are pure input, so a wrong one renders a different
game's geometry with every bench still green. On 2026-09-08 nine of
thirteen generated MRAs had the wrong game id and nothing caught it.

---

## Rayforce_20260909

- **Bubble Bobble II and Bubble Memories: the backgrounds and on-screen text
  are no longer scrambled.** Level tiles were mispositioned and story text was
  repeated across the screen. Fixes issue #5.
- **New: Bubble Memories (bb3be alt program)** in `releases/experimental/`, an
  alternate program ROM set.
- Nothing else changes for any other game.

Still broken, and not touched by this release: Riding Fight has no sound,
Grid Seeker's fire button does nothing, Puzzle Bobble 4's character-select art
is wrong (issue #3), Puzzle Bobble 3 has a flickering first line (issue #4).

Why the Bubble games were broken, and what it cost to fix, is in PIVOT-RAM.md.
This build uses all 553 block RAMs, so anything added next has to free some.

## Rayforce_20260908b.rbf

Build stamp `08201940`.

- **Nothing changes for any game you can play.** This is `Rayforce_20260908`
  with the sound-ROM banking put back in correctly, so the published
  bitstream matches the source in the repository again. Both files play all
  35 games with sound; `20260908` stays where it is and is still fine to use.
- The banking is the feature that broke sound a few hours earlier. It now
  starts on the same bank the real board does, and stays completely out of
  the way until a game asks for it -- which no shipping game does. Verified
  on hardware after building: Ray Force and Puzzle Bobble 3 both captured
  live audio off the board, 4,096 samples with no silence in them.
- Kirameki Star Road, the game the banking is for, still has no MRA and
  still does not run.
- Known problems are unchanged from `Rayforce_20260908` below.

## Rayforce_20260908.rbf

Build stamp `08142400`.

> **A bitstream stamped `08154107` was briefly published here and HAD NO
> SOUND IN ANY GAME.** If you have it, replace it with this one. The cause was
> the sound CPU's 0xC20000 window: it was given a bank index that reset to 0
> where the hardware resets it to 1, so the sound 68000 executed the wrong
> 128 KB of its own program. Reported from a board within hours -- "installed
> the 20260908 version, however I didn't get any sound, reverted and got the
> sound back" -- and this file is now the same build with that change simply
> absent. The banking it was added for (Kirameki Star Road) is not in this
> bitstream and Kirameki does not run either way.

- **29 more games run**, taking the core from 6 to 35 of the 38 Taito F3
  sets. Arkanoid Returns, Grid Seeker, Space Invaders '95, Cleopatra
  Fortune, Twin Qix, Recalhorn, Quiz Theater, Pop 'n Pop, Gekirindan,
  Darius Gaiden Extra, Puzzle Bobble 3 and 4, Arabian Magic, Riding Fight,
  Ring Rage, Land Maker, and the thirteen largest sets including Kaiser
  Knuckle and Dan-Ku-Ga.
- **Horizontal games no longer rotate.** Rotating one cost a frame of input
  latency through MiSTer's framebuffer and showed it at the wrong aspect; a
  player reported it as lag on Darius Gaiden. The core now decides per game
  and the OSD's Rotate applies to the vertical ones only.
- **12-bit colour** for Arabian Magic, Riding Fight and Ring Rage, which
  store colour differently from every other F3 game.
- **Sound fixes** for games whose sample ROM is banked differently from Ray
  Force's: Puzzle Bobble 3 and 4, Land Maker, Kaiser Knuckle, Dan-Ku-Ga,
  Puchi Carat, Quiz de Hyuuhyuu; and correct banking for Arkanoid Returns,
  Cleopatra Fortune and Twin Qix.
- Kirameki Star Road's sound-ROM banking is implemented, but that game still
  has no MRA and does not run.
- Known problems in this build, by game:
  - **Ray Force** still drops sprite rows on the zone 2 boss.
  - **Darius Gaiden** renders some background objects in the wrong colours
    until the game rewrites its palette, which it does as the first boss
    arrives. Reported from play.
  - **Bubble Memories** asks for the TEST switch on a fresh card; turn on
    Service Mode in the OSD and reset, once.
  - **Kirameki Star Road** still does not run and has no MRA.
  - The 29 games added here have not been played through. They boot, render
    and take a coin.

## Rayforce_20260907.rbf

Build stamp `07213908`.

- **The sprite corruption is fixed.** Explosions and enemy sprites no longer
  break into flickering, offset copies of themselves. This was the core's
  worst and longest-standing defect: nine days, about thirty instruments.

  **What it actually was.** The sprite engine keeps a store of sprite-row
  records, double-banked so one frame is drawn while the next is built. It
  was declared as two banks of 12,288 records -- 24,576 words, which needs 15
  address bits -- but the address was only 14 bits wide, so Quartus built a
  16,384-word RAM and the top third simply did not exist. Bank 1's records
  from 4,096 up landed on bank 0's. Any frame with more than 4,096 records
  had its tail overwrite the other frame's head, so one frame drew a live
  list and the next drew a half-stale one: two images, offset, flickering.

  That is why it got WORSE when the store was made bigger, and why every
  simulation passed -- Verilator models all 24,576 words, so the bug existed
  only on silicon. **The fix is one number:** 8,192 records per bank, so the
  two banks are exactly the 16,384-word RAM Quartus builds and no address can
  alias. The cost is that the very heaviest frames now DROP rows instead of
  corrupting them, which the self-test page counts on `SPR REC : DROP`.
- Ray Force, Gunlock and Ray Force (Japan) all start on zone 1.
- Two debug MRAs added that start at zone 2 on purpose, in
  `releases/experimental/`.
- Known problem: some sprite rows still drop on the zone 2 boss, so parts of
  it draw as broken lines. Sprites missing, not corrupted.

## Rayforce_20260831.rbf

- Elevator Action Returns, Bubble Bobble II and Puzzle Bobble 2 run.
- High scores save. They do not come back on reboot yet.
- Audio Boost added: the real board is very quiet, and 8x is the default.

## Rayforce_20260828.rbf

First release. Ray Force plays with sound.

---

**The bitstream and the MRAs must come from the same release.** The ROM
layout changed when this became a general F3 core; mismatched files fail the
`ROM BYTES` self-test row and show wrong graphics.
