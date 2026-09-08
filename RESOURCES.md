# The resource budget

The Cyclone V on a DE10-Nano (5CSEBA6U23I7) is **full**. Every build since
2026-08-31 has run at 95-98 % ALMs, and four fits have failed outright. This
file exists because that budget was never written down: the costs, the levers
and the traps all had to be re-derived from fit reports each time, and one of
those re-derivations cost a 66-minute build on 2026-09-03.

## Read the right number

**The LAB percentage is misleading.** Every recent build reports
`Total LABs: partially or completely used  4,187-4,191 / 4,191 (100 %)`,
including builds that fit comfortably and closed timing. It means the fitter
touched every LAB, not that they are full.

**ALM headroom is the number that means something:**

| build | contents | ALMs | spare | LABs | mem LABs | M10K | timing |
|---|---|---:|---:|---|---:|---|---|
| A `02205428` | penmask fix, ring trigger | 39,789 | 2,121 | 4,191 | 772 | 541 | met +0.013 |
| B `02214052` | + tile-row cache | 41,086 | 824 | 4,188 | 772 | 549 | HDMI -0.514 |
| C `02222040` | + MRA uart, seed 8 | 41,068 | 842 | 4,188 | 772 | 549 | met +0.124 |
| E `03075159` | + lookahead skip | 41,095 | 815 | 4,190 | 772 | 552 | met +0.059 |
| F `03084458` | + miss fix | 41,100 | 810 | 4,187 | 772 | 552 | HDMI -0.334 |
| G seed 11 | same RTL as F | 41,181 | 729 | 4,191 | 772 | 552 | HDMI -0.355 |
| — `03192643` | NREC **13,312**, no cache, FX off | — | — | — | — | — | **Error 11802, can't fit** |
| — `03203511` | NREC 12,288, no cache, FX off | 39,343 | 2,567 | 4,185 | 772 | 545 | met +0.174 |
| **H `03213829`** | NREC 12,288 **+ cache**, ring 512, fold removed, FX off | 39,719 | 2,191 | 4,190 | 772 | 547 | **met +0.232** |
| **I `04074618`** | + zone injector, fetch self-check, stale detector | 39,775 | 2,135 | 4,190 | 772 | 547 | **met +0.266** |

Note from the last three rows: **ALMs were never what stopped `13,312`** -- the
12,288 build that followed had 2,567 ALMs spare. That failure was memory
placement (MLAB/LAB), so ALM headroom does NOT mean `NREC` can grow.

Two error numbers, and they mean different things:

- **Error 170012** — a LAB shortage specifically. Seen four times in a row
  before `1d49395`, with ALMs *under* capacity the whole time.
- **Error 11802** — "can't fit design in device", the general one. Seen on
  2026-09-03 at `NREC = 13312`. The fitter dies **before writing a resource
  report**, so read the synthesis estimate BEFORE starting another build:
  `build.sh` wipes `output_files/` and the evidence goes with it.

## Where the memory goes

An **MLAB** is a LAB configured as memory, so it consumes a LAB and cannot
hold logic. This is the trap that made four fits fail with ALMs looking
comfortable. Only two stores in this design are MLAB, and both are MLAB
because their reads are ASYNCHRONOUS:

| store | shape | bits | MLABs | why MLAB |
|---|---|---:|---:|---|
| `rec` (rf_video_spr) | 2 x NREC x 18 | 368,640 @10240 | ~576 | async read `rec[rb][fc]` |
| `sl_d` (rf_video_spr) | 2 x 1024 x 51 | 104,448 | ~163 | async read `sl_d[rb][sidx_r]` |

`rec` scales at **58 MLABs per 1,024 records**:

```
NREC 10,240  = 576 MLABs
NREC 11,264  = 634          NREC 13,312 = 749   <- Error 11802, too big
NREC 12,288  = 691          NREC 14,336 = 806
```

**M10K is width-limited, not just depth-limited.** A block gives ~40 bits of
width, so a 96-bit-wide memory costs **three blocks whatever its depth** --
which is why the sprite tile-row cache was built 256 deep rather than 64: the
shallow version wasted the same three blocks.

M10K consumers worth knowing: the debug write ring is 2048 x 56 = **11
blocks** (halving it to 1024 frees ~5), the sprite line-buffer ring is
NB(8) x 512 x 16 = ~6.4, and the tile-row cache was 8.

## The levers, and what each is worth

Ranked by what they buy against what they cost. Everything here is measured,
not estimated, except where it says otherwise.

1. **Move an async-read store into M10K with a registered read.** The proven
   move: `1d49395` took `sl_y` from 64 MLABs to 3 M10Ks by making its read
   registered and adding two wait states (`P_C0W` / `P_E0W`), and that is what
   made the design fit after four failures. `sl_d` is the remaining
   candidate: **+163 LABs for ~10 M10Ks**. `rec` is NOT a candidate -- at
   368,640 bits it needs 36 M10Ks and only ~12 are ever spare.
2. **Tie off the scandoubler FX** (`Rayforce.sv`, `scandoubler_fx = 3'd0`).
   `hq2x` is `fx == 1` and the scanline blender is also built from `fx`, so
   holding it at 0 folds both away. Measured bound 2026-09-03: worth
   **fewer than 169 LABs** (the +173 build failed with 4 LABs spare
   beforehand). Costs the OSD's scanline and HQ2x filters.
3. **Framework macros in the qsf.** `MISTER_DISABLE_YC=1` and
   `MISTER_DISABLE_ADAPTIVE=1` are already set and together paid for
   `extend=0` (Puzzle Bobble 2, Darius Gaiden). `MISTER_SMALL_VBUF=1` and
   `MISTER_DOWNSCALE_NN=1` are commented out and untried.
4. **Shrink the debug write ring** (rf_main, 2048 entries): ~5 M10Ks, no LABs.
   It was already halved once from 4096.
5. **Drop the sprite tile-row cache** (`rf_spr_gfx_bus`): 8 M10Ks plus its
   tag-compare logic. Removed 2026-09-03 -- its only claimed benefit was
   never confirmed with a control and it bought 3 % on the board.

## The sizing lesson

`NREC` was CUT from 12,288 to 10,240 in `1d49395` on measured peaks of 6,517
(Ray Force) and 8,645 (Elevator Action Returns), concluding "36 % spare".
**Every one of those numbers was attract mode.** On 2026-09-03 a player
reached the Zone 2 boss and the board reported **10,836 records with 646
DROPPED** -- dropped rows are sprite rows never drawn, which is the broken,
dotted wireframe that boss renders with.

No dump, bench or capture in this project had ever contained a boss. Even
`dump/rf_heavy`, a 344-sprite-row frame pulled from MAME specifically to be
heavy, only reaches 2,190 records -- a fifth of what the boss needs.

**Size against gameplay, not attract.** And `SPR REC : DROP` on the self-test
page makes it self-verifying: the low half counts dropped rows, so a scene
that still overflows says so.

## Building

`build.sh` runs Quartus in a systemd scope at **MemoryHigh=9G, MemoryMax=9G,
CPUWeight=80**. The two values are deliberately EQUAL:

> With `MemoryHigh=8G` under `MemoryMax=9G`, a build with a larger `NREC`
> array reached 8 GB in `quartus_map`, was throttled **286,694 times** and
> made no progress for 23 minutes. Raising `MemoryHigh` to 9G live freed it
> instantly and memory FELL back to 4 GB -- it was thrashing the soft limit,
> not needing the memory.

A build peaks 4-8 GB and takes 40-70 minutes. **`/tmp` is a tmpfs on this
machine** -- files there occupy RAM and are not reclaimable like page cache;
6 GB of another session's downloads sitting in `/tmp` is the most likely
explanation for the machine lock-up that killed a build on 2026-09-02.

`build_seeds.sh` is **stale and hazardous**: it still sets 11G/11G, the values
that got builds killed. Set `SEED` in `Rayforce.qsf` and use `build.sh`.
Seeds matter only for the framework HDMI PLL, which has missed by -0.04 to
-0.51 ns in many builds and is fitter variance, not a real path: seed 8 turned
-0.514 into +0.124 on identical RTL. The two CORE clocks have never been the
problem -- they run +1.1 to +1.7 ns.
