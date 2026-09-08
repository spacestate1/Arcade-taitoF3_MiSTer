# The Taito F3 library, and what this core needs for each of it

Extracted mechanically from MAME 0.288's `taito_f3.cpp` (the `GAME()` lines and
the `init_` functions, joined through them) and `taito_f3_v.cpp`'s `f3_config_table`, which is
where `extend` and `sprite_lag` actually live. **All 35 parent sets**, so
that every game the core could ever run has a row here and a place in the
config layout before it is needed rather than after.

Regional variants are not listed: they differ by a program ROM and share
their parent's row entirely -- with one exception now measured. The Ray
Force family does NOT share a row: `gunlock` (World), `rayforce` (US) and
`rayforcej` (Japan) each need their own game id, because their download
streams differ and the self test judges each against its own ROM CHECKSUM
and SDRAM BIST. They carry ids 6, 0 and 7 (cfg `A0`, none, `E0`). Their
write hashes and sample folds ARE shared -- measured 2026-09-01, all three
boot through the same F3 code and hash to 10620931.

## What the core can express today

| Parameter | Values in the library | State |
|---|---|---|
| visarea | `f3` 232/24, `f3_224a` 224/31, `f3_224b` 224/32, `f3_224c` 224/24 | **all four implemented** (`rayforce_video.sv:98`) |
| `extend` | 0 and 1 | **both implemented** (`cfg_extend`) |
| rotation | ROT0, ROT90, ROT270 | MRA-level, nothing needed in the core |
| sprite lag | 0, 1, 2 (2 sets want 0, 24 sets want 1, 9 sets want 2) | **NOT expressible** — the engine is structurally lag 2. Field reserved at index 2 `[4:3]` |
| 12-bit palette | `spcinvdj`, `ridingf`, `arabianm`, `ringrage` | **implemented** 2026-09-08 (`cfg_pal12`). Per game, as MAME does it; MRA index 2 `[5]` also turns it on |
| game id | 35 parents | 6 bits = 64 ids, so the field can name every one |

## Every parent set

`fits` is against the SDRAM map, region by region. **There are two map
profiles now** (`cfg_map`, MRA index 2 bit `[4]`): profile 0 is the original
layout, unchanged, and profile 1 is a 36 MB layout with a 13 MB sprites
region. **Profile 1 fits ALL 100 F3 sets, parents and clones**, so nothing in
the library is blocked on ROM space any more.

**The sizes below were re-measured on 2026-09-08 from REAL ROM bytes.** The
figures this file used to carry came from MAME's *declared* region sizes and
overstated several sets badly -- the largest set in the library is Kirameki
Star Road at **31 MB**, not the 36-40 MB the declared sizes imply. Two
consequences worth knowing:

- `sprites` is the region that overflows for THIRTEEN of the fourteen sets
  that missed profile 0. The 4 MB slot was the bottleneck, not capacity.
- **Land Maker now fits profile 0**, because ensoniq grew 4 MB -> 8 MB for
  Puzzle Bobble 3/4 and its 6 MB of samples fit that. It is listed as not
  fitting further down; that row is stale.

The SDRAM itself was MEASURED at **>= 64 MB** (aliasing probe, 2026-09-08:
1 MB of 0xFF at byte 32 MB left the program ROM intact, where the same write
at byte 0 destroyed it), so both profiles have room to spare.

`cfg` is the config the MRA would carry: index 1, then index 2 when the
game id needs the high bits. Ids are assigned only to games that have
actually been given one; the rest show `-`.

| set | real ROM | profile 0 (18.5 MB) | id | state |
|---|---:|---|---|---|
| `spcinvdj` *12-bit* | 4.00 MB | yes | - |  |
| `arkretrn` | 5.00 MB | yes | 8 | **runs** |
| `cleopatr` | 7.25 MB | yes | 13 | **runs** |
| `arabianm` *12-bit* | 7.25 MB | yes | - |  |
| `twinqix` | 7.50 MB | yes | 14 | **runs** |
| `gseeker` | 8.75 MB | yes | 11 | **runs** |
| `spcinv95` | 9.00 MB | yes | 12 | **runs** |
| `recalh` | 9.25 MB | yes | 15 | **runs** |
| `ridingf` *12-bit* | 9.25 MB | yes | - |  |
| `ringrage` *12-bit* | 9.25 MB | yes | - |  |
| `pbobble2` | 9.50 MB | yes | 5 | **runs** |
| `bublbob2` | 9.50 MB | yes | 2 | **runs** |
| `gunlock` | 9.50 MB | yes | 6 | **runs** |
| `rayforce` | 9.50 MB | yes | 0 | **runs** |
| `rayforcej` | 9.50 MB | yes | 7 | MRA written |
| `cupfinal` | 10.75 MB | **no** (sprites) | - |  |
| `intcup94` | 10.75 MB | **no** (sprites) | - |  |
| `scfinals` | 11.25 MB | **no** (sprites) | - |  |
| `bubblem` | 12.50 MB | yes | 3 | **runs** |
| `pbobble3` | 12.50 MB | yes | 9 | staged, needs build |
| `pbobble4` | 12.50 MB | yes | 10 | staged, needs build |
| `popnpop` | 12.50 MB | yes | 17 | **runs** |
| `trstar` | 13.25 MB | **no** (sprites) | - |  |
| `gekiridn` | 13.50 MB | yes | 18 | **runs** |
| `qtheater` | 14.50 MB | yes | 16 | **runs** |
| `dariusg` | 14.50 MB | yes | 4 | **runs** |
| `dariusgx` | 14.50 MB | yes | 19 | **runs** |
| `elvactr` | 14.50 MB | yes | 1 | **runs** |
| `commandw` | 15.25 MB | **no** (sprites) | - |  |
| `lightbr` | 16.25 MB | **no** (sprites) | - |  |
| `quizhuhu` | 16.25 MB | **no** (sprites) | - |  |
| `landmakr` | 16.50 MB | yes | - |  |
| `tcobra2` | 17.25 MB | **no** (sprites, tilemap) | - |  |
| `puchicar` | 18.50 MB | **no** (sprites) | - |  |
| `pwrgoal` | 19.50 MB | **no** (sprites) | - |  |
| `kaiserkn` | 26.50 MB | **no** (sprites, tilemap) | - |  |
| `dankuga` | 26.50 MB | **no** (sprites, tilemap) | - |  |
| `kirameki` | 31.00 MB | **no** (audiocpu, sprites, tilemap) | - |  |

`*12-bit*` marks the four sets needing the 12-bit palette, implemented
2026-09-08. **Every set above fits profile 1**, so the `profile 0` column is
now only about which games need no MRA change rather than which are possible.

**17 of these run on hardware**, 20 have an id.
Sizes are REAL ROM bytes measured 2026-09-08, not MAME's declared region
sizes; see the note above for why that matters.
per-game parameter. See the map-size tiers in README.
