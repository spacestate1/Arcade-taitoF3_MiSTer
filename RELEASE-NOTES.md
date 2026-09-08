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
   shipping MRA. The debug MRAs that do start elsewhere say so in their
   filename and live in `releases/experimental/`.

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
the ones with `(zone 2)` in the name. Last checked 2026-09-08: all eleven
MRAs correct.

---

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
