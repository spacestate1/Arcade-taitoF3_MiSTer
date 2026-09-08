# MAME lua tooling for the F3 core

All run headless: `SDL_VIDEODRIVER=dummy mame gunlock -rompath /storage02/roms/mame
-video none -sound none -nothrottle -norotate -autoboot_script tools/mame/<x>.lua
-seconds_to_run N`. `-norotate` matters: without it MAME's frame dumps come out
224x320 and the model comparison needs rot90.

| script | what | env |
|---|---|---|
| `ramdump2.lua` | dump 68020 work RAM (0x400000-0x43FFFF) at frames and/or on a save-state load (`post_load` notifier) | `WD_OUT` base, `WD_AT` frames |
| `zonegame.lua` | coin + start a REAL game headless (`:EEPROMIN` Coin 1 @f400, `:IN.0` 1 Player Start @f600-700), optionally hold RAM bytes every frame, snapshot at offsets | `ZG_VAL`, `ZG_ADDRS`, `ZG_SHOTS` |
| `zonesub.lua` | the one that works: intercept the new-game init's store of 1 into the zone word (PC 004810) with a write tap and substitute the value AT the write | `ZS_VAL` |
| `zonewrite.lua` / `zonetap.lua` | log every write / read of the zone word with the PC that did it | — |
| `ports.lua` | print every input port and field (for scripting inputs) | — |

Findings these produced (2026-09-04):
- **zone word = 0x402312/13** (byte 0x402313 = zone 1..), shadow 0x4038C1, RAM
  mirror at 0x422313. `0x402317`/`0x402319` track it in gameplay (0 in attract).
- Written at new game by **PC 004810 as the constant 1**, consumed by the stage
  loader in the SAME frame (read at PC 009062). A once-per-frame poke never
  wins; substituting at the write does (44 % of the frame differs = zone 2).
- `-state N` and `machine:load()` both KILL frame notifiers; use
  `emu.add_machine_post_load_notifier` to act on a loaded state.
- `install_read_tap`/`install_write_tap` ranges must be 4-byte aligned.
