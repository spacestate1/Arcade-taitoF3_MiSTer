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
| 12-bit palette | `ridingf`, and with extend=0 `arabianm`/`ringrage` | **not implemented**. Field reserved at index 2 `[5]` |
| game id | 35 parents | 6 bits = 64 ids, so the field can name every one |

## Every parent set

`fits` is against the current 18.5 MB universal map, region by region.
`cfg` is the config the MRA would carry: index 1, then index 2 when the
game id needs the high bits. Ids are assigned only to games that have
actually been given one; the rest show `-`.

| set | vis | ext | lag | rot | ROM | fits 18.5 MB | id | cfg | state |
|---|---|---|---|---|---|---|---|---|---|
| `arkretrn` | 3 | 1 | 1 | 0 | 5.75 MB | yes | - | `03` |  |
| `twinqix` | 0 | 1 | 1 | 0 | 7.50 MB | yes | - | `00` |  |
| `cleopatr` | 0 | 0 | 1 | 0 | 8.25 MB | yes | - | `04` |  |
| `arabianm` | 0 | 0 | 2 | 0 | 8.75 MB | yes | - | `04` |  |
| `gseeker` | 1 | 0 | 1 | 90 | 8.75 MB | yes | - | `05` |  |
| `recalh` | 3 | 1 | 1 | 0 | 9.25 MB | yes | - | `03` |  |
| `ridingf` | 1 | 1 | 1 | 0 | 9.25 MB | yes | - | `01` |  |
| `pbobble2` | 3 | 0 | 1 | 0 | 10.50 MB | yes | 5 | `67` | **runs** |
| `spcinv95` | 0 | 0 | 1 | 270 | 11.00 MB | yes | - | `04` |  |
| `bublbob2` | 0 | 1 | 1 | 0 | 11.50 MB | yes | 2 | `80` | **runs** |
| `gunlock` | 0 | 1 | 2 | 90 | 11.50 MB | yes | 6 | `A0` | **runs** |
| `rayforce` (US) | 0 | 1 | 2 | 90 | 11.50 MB | yes | 0 | none | **runs** |
| `rayforcej` | 0 | 1 | 2 | 90 | 11.50 MB | yes | 7 | `E0` | MRA written |
| `ringrage` | 0 | 0 | 2 | 0 | 11.75 MB | yes | - | `04` |  |
| `bubblem` | 0 | 1 | 1 | 0 | 13.50 MB | yes | 3 | `C0` | MRA written |
| `qtheater` | 2 | 1 | 1 | 0 | 14.50 MB | yes | - | `02` |  |
| `popnpop` | 3 | 1 | 1 | 0 | 15.50 MB | yes | - | `03` |  |
| `gekiridn` | 3 | 0 | 1 | 270 | 17.50 MB | yes | - | `07` |  |
| `dariusg` | 3 | 0 | 2 | 0 | 18.50 MB | yes | 4 | `27` | **runs** |
| `dariusgx` | 3 | 0 | 2 | 0 | 18.50 MB | yes | - | `07` |  |
| `elvactr` | 3 | 1 | 2 | 0 | 18.50 MB | yes | 1 | `43` | **runs** |
| `pbobble3` | 3 | 0 | 1 | 0 | 13.50 MB | **no** (ensoniq) | - | `07` |  |
| `pbobble4` | 3 | 0 | 1 | 0 | 13.50 MB | **no** (ensoniq) | - | `07` |  |
| `cupfinal` | 0 | 0 | 1 | 0 | 14.25 MB | **no** (sprites, sprites_hi) | - | `04` |  |
| `intcup94` | 0 | 0 | 1 | 0 | 14.25 MB | **no** (sprites, sprites_hi) | - | `04` |  |
| `scfinals` | 0 | 0 | 1 | 0 | 14.75 MB | **no** (sprites, sprites_hi) | - | `04` |  |
| `tcobra2` | 3 | 0 | 0 | 270 | 17.25 MB | **no** (sprites, tilemap) | - | `07` |  |
| `trstar` | 3 | 1 | 0 | 0 | 17.25 MB | **no** (sprites, sprites_hi) | - | `03` |  |
| `commandw` | 1 | 1 | 1 | 0 | 20.25 MB | **no** (sprites, sprites_hi) | - | `01` |  |
| `quizhuhu` | 3 | 1 | 1 | 0 | 20.25 MB | **no** (sprites, sprites_hi, ensoniq) | - | `03` |  |
| `landmakr` | 3 | 1 | 1 | 0 | 20.50 MB | **no** (ensoniq) | - | `03` |  |
| `lightbr` | 0 | 1 | 2 | 0 | 21.25 MB | **no** (sprites, sprites_hi) | - | `00` |  |
| `puchicar` | 3 | 1 | 1 | 0 | 23.50 MB | **no** (sprites, sprites_hi, ensoniq) | - | `03` |  |
| `pwrgoal` | 0 | 0 | 1 | 0 | 26.50 MB | **no** (sprites, sprites_hi) | - | `04` |  |
| `dankuga` | 0 | 0 | 2 | 0 | 36.00 MB | **no** (sprites, sprites_hi, tilemap, tilemap_hi, ensoniq) | - | `04` |  |
| `kaiserkn` | 0 | 0 | 2 | 0 | 36.00 MB | **no** (sprites, sprites_hi, tilemap, tilemap_hi, ensoniq) | - | `04` |  |
| `kirameki` | 0 | 0 | 1 | 0 | 40.00 MB | **no** (audiocpu, sprites, sprites_hi, tilemap, tilemap_hi, ensoniq) | - | `04` |  |

**19 of 35 fit the current map**; the rest are blocked on room, not on any
per-game parameter. See the map-size tiers in README.
