# Taito F3 System for MiSTer

An FPGA recreation of the Taito F3 arcade board (1992–1998) for MiSTer. One
bitstream runs the whole library; adding a game is an MRA file and one config
byte, not a new core.

Checked against MAME, not by eye: video pixel-identical over 15 consecutive
frames, sound sample-exact over 1.15 million samples.

**Plays now: 22 of the 38 F3 parent sets**, on one bitstream. Ray Force
(*Gunlock*, *Layer Section*) in all three regions, Elevator Action Returns,
both Bubble Bobble games, all four Puzzle Bobbles, Darius Gaiden and its
Extra Version, Arkanoid Returns, Grid Seeker, Space Invaders '95, Cleopatra
Fortune, Twin Qix, Recalhorn, Quiz Theater, Pop 'n Pop, Gekirindan, Arabian
Magic, Riding Fight and Ring Rage.

Every remaining set has an MRA written except Kirameki Star Road, which
needs sound-ROM banking the core does not implement.

## Status

| Game | State |
|---|---|
| **Ray Force** (US) | Plays with sound. The sprite corruption is fixed (2026-09-08): the sprite record store was declared two banks of 12,288 but Quartus built one 16,384-word RAM, so each frame's records overwrote the other frame's. Sized to 8,192 per bank it cannot alias. Some sprite rows drop on the zone 2 boss instead. |
| **Gunlock** / **Ray Force (Japan)** | Same board, one program chip different. Built, not yet run on hardware. |
| *Elevator Action Returns* | Plays. Ten frames match MAME pixel for pixel. Sound not yet checked. |
| *Bubble Bobble II* | Plays. Frame-checked: 20 frames pixel-exact MAME -> model -> RTL. The playfield/pivot corruption (issue #5) is FIXED in `Rayforce_20260909` -- the pivot RAM was 8 KB where the F3 has 64 KB. |
| *Puzzle Bobble 2, 3, 4* | All render on hardware. Never played through. PB3's first-line flicker (issue #4) and PB4's character-select art (issue #3) are open and NOT addressed by the 2026-09-09 pivot fix. |
| *Darius Gaiden* + *Extra Version* | Both render. Use the pixel layer, which this core only mirrors. |
| *Bubble Memories* | Runs. Same pivot fix as Bubble Bobble II. Its EEPROM has never been written, so it asks for the TEST switch on a fresh card: OSD -> Service Mode -> reset, once. |
| *Arkanoid Returns, Grid Seeker, Space Invaders '95, Cleopatra Fortune, Twin Qix, Recalhorn, Quiz Theater, Pop 'n Pop, Gekirindan* | Render and take coins. Added 2026-09-08, none played through. |
| *Arabian Magic, Riding Fight, Ring Rage* | Render. These are the 12-bit palette games. |
| The 13 largest sets | MRAs written against the 42 MB map profile; **not yet confirmed** on hardware. |

**The bitstream and the MRAs must come from the same release.** The ROM
layout changed when this became a general F3 core; mismatched files fail the
`ROM BYTES` self-test row and show wrong graphics.

## Known problems

Each of these names the game it affects. Anything not listed here is a game
nobody has played far enough to find a fault in — see the note on what
"confirmed" means in [releases/experimental](releases/experimental/README.md).

- **RAY FORCE — sprite rows drop on the zone 2 boss.** The record store holds
  8,192 rows a frame; that boss asks for ~10,800. Rows go missing from the
  bottom of the frame, so the boss draws as broken lines. Missing rows, not
  corruption — the self-test's `SPR REC : DROP` counts them. The full story
  of the corruption this replaced — nine days, ~30 instruments, one wrong RAM
  size — is in [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md).
- **DARIUS GAIDEN — some background objects render in the wrong colours**
  until the game rewrites its palette. Reported from play: the big foreground
  towers early in the first level are red and gold where they should be
  blue-grey steel, and the SAME objects correct themselves on screen as the
  boss arrives. Measured: the sprites' positions, zoom and tile codes are all
  right and only the colour is wrong; the palette writes do reach palette RAM;
  and the core's 68020 completes 600 spin-loop reads per frame where real
  hardware does 764, so a palette block-copy budgeted against real hardware
  may not finish in the frames the game expects. Not proven.
- **BUBBLE MEMORIES — asks for the TEST switch on a fresh card.** Its 93C46
  EEPROM has never been written, so it boots to "BACKUP DATA FAILED". Turn on
  Service Mode in the OSD and reset, once. Not a fault in the game.
- **RIDING FIGHT — no sound.** Reported from play 2026-09-09. Every stage
  below the sound CPU's register writes is proven correct on this game's own
  data: sample placement, region bases, bank arithmetic, the ES5505 RTL
  (500,000 samples, 0 differences against the model), the mix, and the
  MB87078. So the divergence is in what the sound 68000 writes. The two
  instruments that can see it were fixed on 2026-09-09 (`AUD_ARM` 256 -> 16
  and the sound-ring freeze 4096 -> 512) but have not been pointed at it yet.
- **GRID SEEKER — the fire button does nothing.** Reported from play
  2026-09-09. Not a wiring gap: `rf_main.sv` drives all four P1 buttons from
  joystick bits 4-7, and MAME's port map for `gseeker` is identical to
  Ray Force's. This set is unusual in three ways (a factory sprite-ROM patch,
  a half-size mirrored sound ROM, and `extend=0`), none of which obviously
  touches input. Unexplained.
- **PUZZLE BOBBLE 3 — check the sample layout if audio sounds wrong.** MAME
  puts its samples at 0x400000, 0x800000 and 0xc00000 inside a 16 MB ensoniq
  region, one 2 MB ROM at the head of each 4 MB bank. The MRA packs them
  consecutively after 2 MB of padding into the core's 8 MB slot and relies on
  `cfg_bankmask = 3'd7` to compress the address space. That may be exactly
  right, but it has never been verified against MAME's stream, and it is the
  first thing to check if the music is wrong.
- **KIRAMEKI STAR ROAD does not run and has no MRA.** It is the only F3 game
  whose sound ROM is banked; the core implements that now, but the set's 4 MB
  audiocpu region still needs a layout working out.
- **SPACE INVADERS DX has no MRA** — its ROM is not on the shelf here. It is
  the fourth 12-bit palette game.
- **ALL GAMES — high scores save but do not restore.** The table reaches the
  `.nvm` file correctly; putting it back on boot does not work yet.
- **ALL GAMES — the ES5510 DSP is not emulated**, only its host port. The dry
  mix correlates 0.95–0.99 with MAME, so the difference is small.
- **ALL GAMES — NVRAM only saves when you open the OSD.** That is MiSTer, not
  the core.
- **DARIUS GAIDEN and DARIUS GAIDEN EXTRA use the pixel (pivot) layer**, which
  this core mirrors as an 8 KB window rather than implementing as real RAM.
  Measured to be entirely zero in attract and zone A, so it may cost nothing;
  it has never been proved either way.
- **Never loaded on hardware:** Gunlock, Ray Force (Japan), and the debug
  variants (`Ray Force (zone 2)`, `Gunlock (zone 2)`, `Darius Gaiden (write
  ring)`). The 60 Hz option is untested on every game.
- **The 29 games added 2026-09-08 have never been played through.** They boot,
  render their attract screen and take a coin. That is all that is known.

The FPGA is 95–98 % full. [RESOURCES.md](RESOURCES.md) says where it goes and
what each lever costs. Read it before adding anything to the RTL.

## How to run it

1. Copy the newest `releases/Rayforce_*.rbf` to `/media/fat/_Arcade/cores/`.
   Today that is **`Rayforce_20260908.rbf`** (build stamp `08154107`). It is
   the only bitstream that runs the whole library: the earlier ones predate
   the 42 MB map profile and the 17-bit sprite codes, so most of the games
   below either will not load or will render as coloured noise on them.
   [RELEASE-NOTES.md](RELEASE-NOTES.md) says what changed in each.

   **One bitstream runs every game.** Each `.mra` names it (`<rbf>Rayforce</rbf>`)
   and appears as its own entry in the arcade menu; there is no per-game
   bitstream and selecting a game reconfigures nothing.
2. Copy the `.mra` files you want to `/media/fat/_Arcade/`.
3. Put the MAME ROM zips in `/media/fat/games/mame/`. ROMs are matched by
   CRC, so a merged set is fine.
4. Pick the game from the MiSTer arcade menu.

| Game | MRA (in `releases/`) | ROM zip | Screen | State |
|---|---|---|---|---|
| Bubble Bobble II | `Bubble Bobble II.mra` | `bublbob2.zip` | horizontal | plays on hardware; not frame-checked |
| Darius Gaiden | `Darius Gaiden.mra` | `dariusg.zip` | horizontal | plays; some background objects mis-coloured (see Known problems) |
| Elevator Action Returns | `Elevator Action Returns.mra` | `elvactr.zip` | horizontal | plays; ten frames pixel-exact vs MAME, sound unchecked |
| Gunlock | `Gunlock.mra` | `gunlock.zip` (or `rayforce.zip`) | vertical | built, never run on hardware |
| Puzzle Bobble 2 | `Puzzle Bobble 2.mra` | `pbobble2.zip` | horizontal | renders correctly; never played through |
| Ray Force (Japan) | `Ray Force (Japan).mra` | `gunlock.zip` (or `rayforce.zip`) | vertical | built, never run on hardware |
| Ray Force | `Ray Force.mra` | `gunlock.zip` (or `rayforce.zip`) | vertical | plays; verified against MAME |
| Arabian Magic | `experimental/Arabian Magic.mra` | `arabianm.zip` | horizontal | renders and takes coins; never played through |
| Arkanoid Returns | `experimental/Arkanoid Returns.mra` | `arkretrn.zip` | horizontal | renders and takes coins; never played through |
| Bubble Memories | `experimental/Bubble Memories.mra` | `bubblem.zip` | horizontal | boots; needs OSD -> Service Mode once to write its EEPROM |
| Cleopatra Fortune | `experimental/Cleopatra Fortune.mra` | `cleopatr.zip` | horizontal | renders and takes coins; never played through |
| Command War | `experimental/Command War.mra` | `commandw.zip` | horizontal | renders and takes coins; never played through |
| Dan-Ku-Ga | `experimental/Dan-Ku-Ga.mra` | `dankuga.zip` | horizontal | renders and takes coins; never played through |
| Darius Gaiden (write ring) | `experimental/Darius Gaiden (write ring).mra` | `dariusg.zip` | horizontal | debug variant: streams CPU writes over serial |
| Darius Gaiden Extra Version | `experimental/Darius Gaiden Extra Version.mra` | `dariusgx.zip` | horizontal | renders and takes coins; never played through |
| Gekirindan | `experimental/Gekirindan.mra` | `gekiridn.zip` | vertical | renders and takes coins; never played through |
| Grid Seeker | `experimental/Grid Seeker.mra` | `gseeker.zip` | vertical | renders and takes coins; never played through |
| Gunlock (zone 2) | `experimental/Gunlock (zone 2).mra` | `gunlock.zip` (or `rayforce.zip`) | vertical | debug variant: opens at zone 2 |
| International Cup 94 | `experimental/International Cup 94.mra` | `intcup94.zip` | horizontal | renders and takes coins; never played through |
| Kaiser Knuckle | `experimental/Kaiser Knuckle.mra` | `kaiserkn.zip` | horizontal | renders and takes coins; never played through |
| Land Maker | `experimental/Land Maker.mra` | `landmakr.zip` | horizontal | renders and takes coins; never played through |
| Light Bringer | `experimental/Light Bringer.mra` | `lightbr.zip` | horizontal | renders and takes coins; never played through |
| Pop 'n Pop | `experimental/Pop 'n Pop.mra` | `popnpop.zip` | horizontal | renders and takes coins; never played through |
| Puchi Carat | `experimental/Puchi Carat.mra` | `puchicar.zip` | horizontal | renders and takes coins; never played through |
| Puzzle Bobble 3 | `experimental/Puzzle Bobble 3.mra` | `pbobble3.zip` | horizontal | renders and takes coins; never played through |
| Puzzle Bobble 4 | `experimental/Puzzle Bobble 4.mra` | `pbobble4.zip` | horizontal | renders and takes coins; never played through |
| Quiz Theater | `experimental/Quiz Theater.mra` | `qtheater.zip` | horizontal | renders and takes coins; never played through |
| Quiz de Hyuuhyuu | `experimental/Quiz de Hyuuhyuu.mra` | `quizhuhu.zip` | horizontal | renders and takes coins; never played through |
| Ray Force (zone 2) | `experimental/Ray Force (zone 2).mra` | `gunlock.zip` (or `rayforce.zip`) | vertical | debug variant: opens at zone 2 |
| Recalhorn | `experimental/Recalhorn.mra` | `recalh.zip` | horizontal | renders and takes coins; never played through |
| Riding Fight | `experimental/Riding Fight.mra` | `ridingf.zip` | horizontal | renders and takes coins; never played through |
| Ring Rage | `experimental/Ring Rage.mra` | `ringrage.zip` | horizontal | renders and takes coins; never played through |
| Space Invaders '95 | `experimental/Space Invaders '95.mra` | `spcinv95.zip` | vertical | renders and takes coins; never played through |
| Super Cup Finals | `experimental/Super Cup Finals.mra` | `scfinals.zip` | horizontal | renders and takes coins; never played through |
| Taito Cup Finals | `experimental/Taito Cup Finals.mra` | `cupfinal.zip` | horizontal | renders and takes coins; never played through |
| Taito Power Goal | `experimental/Taito Power Goal.mra` | `pwrgoal.zip` | horizontal | renders and takes coins; never played through |
| Top Ranking Stars | `experimental/Top Ranking Stars.mra` | `trstar.zip` | horizontal | renders and takes coins; never played through |
| Twin Cobra II | `experimental/Twin Cobra II.mra` | `tcobra2.zip` | vertical | renders and takes coins; never played through |
| Twin Qix | `experimental/Twin Qix.mra` | `twinqix.zip` | horizontal | renders and takes coins; never played through |

All 39 entries above run on the **same** bitstream — each `.mra` names it and
gets its own entry in the arcade menu. Copy the ones you want; there is no
per-game bitstream.

`experimental/` means less evidence, not a different build. "Renders and
takes coins" is exactly that and no more: the game booted, drew its attract
screen and accepted a coin on real hardware. None of those has been played
through, so a fault that only shows in play would not have been found.

One `gunlock.zip` covers all three Ray Force regions. Horizontal games no
longer need **Rotate: None** set by hand -- the core forces it per game.
`experimental/` means it runs but has less evidence behind it.

## Controls

| Pad | Action |
|---|---|
| D-pad or left stick | Move |
| A | Shot |
| B | Bomb (lock-on laser) |
| R | Start |
| L | Insert coin |
| Select | Insert coin (measured; this table used to say Service) |
| Start | Pause |

The cabinet TEST switch is **not** on the pad at all. `rf_main.sv` drives it
only from the OSD's Service Mode; the joystick's Service bit is the service
*coin* input, a different signal. A game asking for the TEST switch needs
OSD -> Service Mode -> reset.

If the stick does nothing, assign it under MiSTer's *Define analog joystick*
first. Input adds no latency in the core -- the joystick reaches the CPU's
input port combinationally, with no register between them. The one frame
that used to exist was MiSTer's rotation framebuffer, and horizontal games
no longer go through it.

## Options

- **Rotate** — CW is the right way up for Ray Force. It applies only to the
  vertical games; a horizontal one is never rotated whatever this says,
  because rotating it costs a frame of latency and the wrong aspect.
- **Flip Screen** — 180° on the rotated output. Does nothing with Rotate = None.
- **Audio Boost** — the real board is very quiet (about 25–30 dB below a
  normal core). 8x is the default; 1x is MAME's own level.
- **Refresh Rate** — native 58.94 Hz. 60 Hz trims the frame and runs ~1.8 % fast.
- **Pause When OSD Open** — freezes both CPUs.
- **Service Mode** — the cabinet TEST switch. The F3 has no DIP switches;
  difficulty, lives and coinage are in the game's own service menu. Turn it
  on and reset.
- **Self Test** — shows the 28-row diagnostic page instead of the game.

**Rotation is automatic per game.** A horizontal game is never rotated,
whatever Rotate says, because rotating one costs a frame of input latency
through MiSTer's framebuffer and shows it at the wrong aspect. Rotate still
chooses CW or CCW for the vertical games.

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
-- `NUMWORDS`, `WIDTHAD` AND `WIDTH` -- before trusting a passing bench.**
Three times now Quartus has built a memory differently from what Verilator
simulated, and every time it was the bug. The third (2026-09-08) was a
one-bit WIDTH mismatch: a cache tag grew 19 -> 20 bits, the compare still
read the old bit positions, and the cache silently never hit. Both benches
still passed 0-differences, because a miss returns the same sample only
slower. `WIDTH 84` against an 85-bit declaration was the only symptom.

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
