# Experimental

Games that run on this core but have not earned the evidence the Ray Force
set has. **They use the same bitstream as everything else** -- every MRA here
says `<rbf>Rayforce</rbf>`. "Experimental" is a statement about how much is
known about them, not about how they are built or loaded. Copy one to
`/media/fat/_Arcade/` and it appears in the menu and plays like any other.

What "confirmed" means below, and it is a low bar: the game booted on real
hardware, rendered its attract screen correctly, and accepted a coin. **None
of these has been played through.** A rendering fault that only shows in play
would not have been caught -- the Darius Gaiden colour bug is exactly that
kind, and it took a player to find it.

Horizontal games no longer need Rotate set by hand; the core forces it per
game. Vertical ones still want Rotate CW or CCW.

`profile 1` marks the sets that use the 42 MB SDRAM map rather than the
18.5 MB one. Nothing about loading them differs; it is which region layout
the MRA and the core agree on.

| MRA | MAME set | screen | map | state |
|---|---|---|---|---|
| Arabian Magic | `arabianm` | horizontal | profile 0 | confirmed on hardware |
| Arkanoid Returns | `arkretrn` | horizontal | profile 0 | confirmed on hardware |
| Bubble Memories | `bubblem` | horizontal | profile 0 | confirmed on hardware |
| Cleopatra Fortune | `cleopatr` | horizontal | profile 0 | confirmed on hardware |
| Command War | `commandw` | horizontal | profile 1 | confirmed on hardware |
| Dan-Ku-Ga | `dankuga` | horizontal | profile 1 | confirmed on hardware |
| Darius Gaiden (write ring) | `dariusg` | horizontal | profile 0 | **never loaded** |
| Darius Gaiden Extra Version | `dariusgx` | horizontal | profile 0 | confirmed on hardware |
| Gekirindan | `gekiridn` | vertical | profile 0 | confirmed on hardware |
| Grid Seeker | `gseeker` | vertical | profile 0 | confirmed on hardware |
| Gunlock (zone 2) | `gunlock` | vertical | profile 0 | **never loaded** |
| International Cup 94 | `intcup94` | horizontal | profile 1 | confirmed on hardware |
| Kaiser Knuckle | `kaiserkn` | horizontal | profile 1 | confirmed on hardware |
| Land Maker | `landmakr` | horizontal | profile 0 | confirmed on hardware |
| Light Bringer | `lightbr` | horizontal | profile 1 | confirmed on hardware |
| Pop 'n Pop | `popnpop` | horizontal | profile 0 | confirmed on hardware |
| Puchi Carat | `puchicar` | horizontal | profile 1 | confirmed on hardware |
| Puzzle Bobble 3 | `pbobble3` | horizontal | profile 0 | confirmed on hardware |
| Puzzle Bobble 4 | `pbobble4` | horizontal | profile 0 | confirmed on hardware |
| Quiz Theater | `qtheater` | horizontal | profile 0 | confirmed on hardware |
| Quiz de Hyuuhyuu | `quizhuhu` | horizontal | profile 1 | confirmed on hardware |
| Ray Force (zone 2) | `rayforce` | vertical | profile 0 | **never loaded** |
| Recalhorn | `recalh` | horizontal | profile 0 | confirmed on hardware |
| Riding Fight | `ridingf` | horizontal | profile 0 | confirmed on hardware |
| Ring Rage | `ringrage` | horizontal | profile 0 | confirmed on hardware |
| Space Invaders '95 | `spcinv95` | vertical | profile 0 | confirmed on hardware |
| Super Cup Finals | `scfinals` | horizontal | profile 1 | confirmed on hardware |
| Taito Cup Finals | `cupfinal` | horizontal | profile 1 | confirmed on hardware |
| Taito Power Goal | `pwrgoal` | horizontal | profile 1 | confirmed on hardware |
| Top Ranking Stars | `trstar` | horizontal | profile 1 | confirmed on hardware |
| Twin Cobra II | `tcobra2` | vertical | profile 1 | confirmed on hardware |
| Twin Qix | `twinqix` | horizontal | profile 0 | confirmed on hardware |

## The ones that are not merely untested

- **Kaiser Knuckle** and **Dan-Ku-Ga** are the largest sets in the library at
  36 MB, and the reason the 42 MB map profile exists. They also needed sprite
  tile codes widened from 15 bits to 17: at 15 bits the core could address
  4 MB of their 13 MB of sprites, and they rendered as coloured noise.
- **Puzzle Bobble 3** and **4** were long listed as blocked on ROM space and
  were not. Their sample region is 16 MB against Ray Force's 8, which makes
  taito_en's otisbank mask 7 rather than 3 -- three bank bits, not two. They
  fit the ordinary map once that was fixed.
- **Land Maker** needed nothing of its own. It fell out of the ensoniq region
  growing for Puzzle Bobble 3/4 and the same 3-bit bank.
- **Arabian Magic**, **Riding Fight** and **Ring Rage** are the 12-bit palette
  games: they store colour as RRRRGGGGBBBB0000 in the low word rather than as
  32-bit 0RGB. MAME selects that by game rather than by register, and so does
  this core.
- **Kirameki Star Road** is the one F3 game with NO MRA here. It is the only
  set that banks its sound ROM, and while the core now implements that bank,
  its 4 MB audiocpu region with a ROM_LOAD16_WORD_SWAP block still needs a
  layout working out. Nothing can verify it either: wrong banking sounds
  wrong rather than looking wrong, and there is no reference dump.
- **Space Invaders DX** (`spcinvdj`) has no MRA for a duller reason: the ROM
  is not on the shelf. It is the fourth 12-bit palette game.

## Regional and alternative versions

Not shipped. 62 of them exist -- Bubble Symphony, Dungeon Magic, Global
Champion, Kyukyoku Tiger II, Bust-A-Move Again, Hat Trick Hero '93/'94/'95,
several prototypes and two bootlegs -- and they all live inside the merged
ROM zips already required here, so none needs a new ROM. They need an MRA
each and a game id, and the id field has 64 slots with 37 used.
