# Taito F3 System for MiSTer

An FPGA recreation of the Taito F3 arcade board (1992–1998) for MiSTer. One
bitstream runs the whole library; adding a game is an MRA file and one config
byte, not a new core.

Checked against MAME, not by eye: video pixel-identical over 15 consecutive
frames, sound sample-exact over 1.15 million samples.

**Plays now:** Ray Force (*Gunlock*, *Layer Section*) in all three regions,
Elevator Action Returns, Bubble Bobble II. Bubble Memories, Puzzle Bobble 2
and Darius Gaiden are in progress.

## Status

| Game | State |
|---|---|
| **Ray Force** (US) | Plays with sound. The sprite corruption is fixed (2026-09-08). Some sprite rows drop on the zone 2 boss. |
| **Gunlock** / **Ray Force (Japan)** | Same board, one program chip different. Built, not yet run on hardware. |
| *Elevator Action Returns* | Plays. Ten frames match MAME pixel for pixel. Sound not yet checked. |
| *Bubble Bobble II* | Plays on hardware. Not yet frame-checked. |
| *Puzzle Bobble 2* | Renders correctly on hardware. Never played through. |
| *Darius Gaiden* | Boots and renders. Uses the pixel layer, which this core only mirrors. |
| *Bubble Memories* | MRA written. Never loaded on a board. |

**The bitstream and the MRAs must come from the same release.** The ROM
layout changed when this became a general F3 core; mismatched files fail the
`ROM BYTES` self-test row and show wrong graphics.

## Known problems

- **Sprite rows drop on the zone 2 boss.** The record store holds 8,192 rows
  a frame; the boss asks for ~10,800. Missing rows, not corruption. The full
  story of the corruption this replaced — nine days, ~30 instruments, one
  wrong RAM size — is in [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md).
- **High scores save but do not restore.** The table reaches the `.nvm` file
  correctly; putting it back on boot does not work yet.
- **The ES5510 DSP is not emulated**, only its host port. The dry mix
  correlates 0.95–0.99 with MAME, so the difference is small.
- **NVRAM only saves when you open the OSD.** That is MiSTer, not the core.
- **Untested on hardware:** Gunlock, Ray Force (Japan), the 60 Hz option.

The FPGA is 95–98 % full. [RESOURCES.md](RESOURCES.md) says where it goes and
what each lever costs. Read it before adding anything to the RTL.

## How to run it

1. Copy the newest `releases/Rayforce_*.rbf` to `/media/fat/_Arcade/cores/`.
   Today that is `Rayforce_20260907.rbf` (build stamp `07213908`, the one
   the sprite-corruption fix went into). The older bitstreams in that
   directory predate the per-game config byte and do not match these MRAs.
   [RELEASE-NOTES.md](RELEASE-NOTES.md) says what changed in each.
2. Copy the `.mra` files you want to `/media/fat/_Arcade/`.
3. Put the MAME ROM zips in `/media/fat/games/mame/`. ROMs are matched by
   CRC, so a merged set is fine.
4. Pick the game from the MiSTer arcade menu.

| Game | MRA (in `releases/`) | ROM zip | Screen | State |
|---|---|---|---|---|
| Ray Force (US) | `Ray Force.mra` | `rayforce.zip` or `gunlock.zip` | vertical | plays; verified vs MAME |
| Gunlock (World) | `Gunlock.mra` | same | vertical | built, not run on hardware |
| Ray Force (Japan) | `Ray Force (Japan).mra` | same | vertical | built, not run on hardware |
| Elevator Action Returns | `experimental/Elevator Action Returns.mra` | `elvactr.zip` | horizontal | plays; video verified, sound unchecked |
| Bubble Bobble II | `experimental/Bubble Bobble II.mra` | `bublbob2.zip` | horizontal | plays on hardware |
| Puzzle Bobble 2 | `experimental/Puzzle Bobble 2.mra` | `pbobble2.zip` | horizontal | renders correctly; never played through |
| Darius Gaiden | `experimental/Darius Gaiden.mra` | `dariusg.zip` | horizontal | boots and renders; pixel layer only mirrored |
| Bubble Memories | `experimental/Bubble Memories.mra` | `bubblem.zip` | horizontal | MRA written; never loaded |

Debug variants, same games: `Ray Force (zone 2).mra` and `Gunlock (zone 2).mra`
open at zone 2 on coin + Start; `Darius Gaiden (write ring).mra` streams the
CPU's writes over the serial port instead of the self-test page.

One `gunlock.zip` covers all three Ray Force regions. Horizontal games need
**Rotate: None** in the OSD. `experimental/` means it runs but has less
evidence behind it.

## Controls

| Pad | Action |
|---|---|
| D-pad or left stick | Move |
| A | Shot |
| B | Bomb (lock-on laser) |
| R | Start |
| L | Insert coin |
| Select | Service |
| Start | Pause |

If the stick does nothing, assign it under MiSTer's *Define analog joystick*
first. Input adds no latency in the core; the one frame that exists is
MiSTer's rotation framebuffer.

## Options

- **Rotate** — CW is the right way up for Ray Force. None keeps raster order
  and avoids one frame of latency.
- **Flip Screen** — 180° on the rotated output. Does nothing with Rotate = None.
- **Audio Boost** — the real board is very quiet (about 25–30 dB below a
  normal core). 8x is the default; 1x is MAME's own level.
- **Refresh Rate** — native 58.94 Hz. 60 Hz trims the frame and runs ~1.8 % fast.
- **Pause When OSD Open** — freezes both CPUs.
- **Service Mode** — the cabinet TEST switch. The F3 has no DIP switches;
  difficulty, lives and coinage are in the game's own service menu. Turn it
  on and reset.
- **Self Test** — shows the 28-row diagnostic page instead of the game.

**Saving settings:** the game writes its EEPROM when a setting changes;
MiSTer writes that to `config/nvram/<mra>.nvm` when you open the OSD. So:
change a setting, leave the menu, open the OSD once.

## Self test

The core carries a 28-row page: ROM load and checksum, SDRAM, CPU writes,
every video RAM, interrupt rates, sprite-engine counters and the sound board.
It is also streamed over the DE10-Nano's serial port, which is how the core is
tested with nobody at the monitor:

```sh
.venv/bin/python tools/rf_uart.py -t 12      # the page
tools/rf_flicker.py <tag>                   # diff a static screen against itself
```

`UART Debug` in the OSD switches the port between the page, the CPU write
ring, the sound write ring and the audio capture.

## Building

Quartus Prime Lite 17.0.2, the version the MiSTer framework targets.

```sh
./build.sh                    # ~40 min, writes output_files/Rayforce.rbf
```

`build.sh` runs Quartus under a memory cap, prints progress, and checks that
a bitstream came out and timing was met. Copy `output_files/Rayforce.rbf`
somewhere before the next build — it wipes that directory.

**After any memory change, read the RAM inference lines in the map log
(`NUMWORDS`, `WIDTHAD`) before trusting a passing bench.** Twice now Quartus
has built a memory differently from what Verilator simulated, and both times
it was the bug.

The Verilator benches are the regression suite and need no FPGA:

```sh
make -C sim pipe                  # the raster pipeline against MAME's frames
make -C sim spr-all spr-line-all  # the sprite engine
make -C sim es5505                # the sampler
make -C sim ddrarb                # the shared DDR3 port
```

They compare against data produced from MAME by the Lua scripts in `tools/`;
those dumps are not in the repository.

## Other F3 games

The F3 library is 35 games on one chipset, differing by four small
parameters: visible raster window, `extend` (playfield RAM layout), sprite lag
(0–2 frames) and orientation. All four now live in the MRA config byte, so a
compatible game is an MRA and a byte. That is how Bubble Bobble II, Puzzle
Bobble 2 and Darius Gaiden came up without RTL changes.

What still blocks games: the pixel (pivot) layer is an 8 KB mirror, not real
RAM — fine for every game that only clears it, wrong for Darius Gaiden — and
the 18.5 MB SDRAM map excludes the two 48 MB sets. Every rendering bug found
on the second game was a Ray Force dimension frozen into the RTL as a
constant; anything sized from a ROM region or a visarea has to be a parameter.
[F3-LIBRARY.md](F3-LIBRARY.md) lists what each game needs.

## Credits and licence

- **MAME** — the reference for everything here (`taito_f3`, `taito_en`,
  ES5505/ES5510).
- **TG68K.C** by Tobias Gubener — the 68000/68020 CPU.
- The **MiSTer** framework and its `sys/` files.

GNU General Public License v3 — see [LICENSE](LICENSE).
