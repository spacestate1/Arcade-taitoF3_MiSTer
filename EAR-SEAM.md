# Elevator Action Returns: the horizontal seam

The remaining rendering fault with a clear symptom and no cause. This file is
the register for it, in the shape [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md)
proved out: the symptom as the player describes it, what is ruled out and by
what evidence, the live theories with the code that would produce each, and
**the measurement that kills or confirms each one, stated before anything is
built.**

Last updated: 2026-09-13.

**State: the instrument is built and on the board, the control reads clean,
and the reading that matters has NOT been taken.** EAR attract reports
`MIX LN : BUILDS 01000100 PASS` on every sample -- 256 composed, 256 built, no
drops -- which is exactly the control the test needs. **What is missing is a
scrolling gameplay scene**, and attract is the wrong regime for it, as it has
been for every sizing bug in this project.

The bitstream carrying the instrument is `builds/Rayforce_earinstr_*.rbf`
(stamp `13195759`). It is **deliberately not in `releases/`**: one core-clock
path fails by -0.224 ns (`rf_video_spr_list:walker|offs[1]` to sprite RAM's
port-B address register, 17.534 ns of the 18.118 ns data path being pure
interconnect -- fitter congestion at 99 % ALMs, on modules nobody touched).
It must be reseeded before it ships. The violation is on a sprite path and
cannot fake a line-build count, so the measurement below stays valid on it.

---

## The symptom

A horizontal seam across the picture while the game scrolls vertically: the
image above the line and the image below it are offset from each other.

Two facts narrow it already:

1. **Seen on HDMI and on a CRT alike** (2026-09-10). The analog output never
   passes through the scaler or the rotation framebuffer, so the fault is in
   the raster the mixer composes, not in anything downstream of it.
2. **It is tied to vertical scrolling.** A seam that appears when the
   playfield advances in Y and not otherwise is a Y-position fault, not a
   timing artefact that would show on any content.

## Ruled out

| Suspect | Why it is out |
|---|---|
| The CPU rewriting scroll registers under the beam | **Measured twice.** MAME (`tools/mame/vctrltap.lua`, 2800 frames of `elvactr`): 11 writes to 0x660000-0x66001F every frame, all at vblank lines 9-10 of 30, zero under the beam, with scroll genuinely moving (0x660004 took 64 distinct values). The board (`VCTRL MIN:MAX:N`): EAR reads `0304000B` -- lines 3..4, 11 writes -- and EAR's picture starts at line 24. Twenty lines of margin. For the CPU to spill past vblank it would have to be ~3x slow; it is 1.27x. |
| The scaler or the rotation framebuffer | The seam is on the analog output too, which passes through neither. |
| Scroll not being latched per frame | `rf_video_pf` latches both axes at `frame_start` (`rf_video_pf.sv:381-384`), so a mid-frame register write cannot reach a line already built. |

**The README carried the CPU theory as the "likely mechanism" until
2026-09-13**, months after the measurement that killed it. It is corrected
there now.

## The leading theory: a dropped line build desynchronises the Y accumulator

Three facts about the renderer, each one a line of RTL:

1. **The playfield Y position is a running accumulator, not a function of the
   line number.** `fx_y[i]` is loaded once at `frame_start` and advanced by
   `y_scale[i]` once per line, in `B_DONE`:

   ```systemverilog
   // rf_video_pf.sv:500
   if (b_sy != 8'd0)
       fx_y[i] <= fx_y[i] + 24'(signed'({15'd0, y_scale[i]}));
   ```

2. **A build request arriving while the builder is busy is silently
   discarded.** The only consumer of `line_start` is `B_IDLE: if (line_start)`
   at `rf_video_pf.sv:388`; in any other state the pulse is gone. The module
   header states it as a limit rather than hiding it (`rf_video_pf.sv:48`:
   *"a line_start while busy is ignored"*). `pf_go` is a one-cycle pulse
   derived from the line decoder finishing (`rf_video_pipe.sv:325`), so there
   is nothing to retry it.

3. **Nothing counts a dropped build.** Until 2026-09-13 the counter that would
   (`n_bld`) existed in `rf_video_pipe`, was wired into `rf_selftest` as
   `vid_lines`, and was then never used -- it was not on the page.

Put together: **one dropped build shifts every line below it by exactly one
`y_scale` step.** That is a horizontal seam. It is invisible unless the
playfield is advancing in Y, because a missed step of zero is no step at all
-- which is why the symptom is specific to vertical scrolling.

### What argues against it

**Measured on the board 2026-09-13, EAR attract:** longest line build
**1817-1867 clocks against a 3456-clock line budget** (432 pixels x 8 clk_sys),
about 54 %, and *lower* than Ray Force's 2346. `MAXFETCH:BUILD` is a
last-frame figure, not a peak hold (`t_bld_max` is cleared at `frame_end`), so
that is a real per-frame maximum and not a warm-up artefact. A drop needs the
build to nearly double.

That does not kill it. Every sizing lesson in this project is that attract is
the wrong regime -- `RESOURCES.md`: the zone 2 boss needed 10,836 sprite
records where attract peaked at 6,517, and *"no dump, bench or capture in this
project had ever contained a boss"*. The seam is reported from scrolling
gameplay. But it does mean the drop, if there is one, may not be plain build
overrun, and that is the argument for **counting it rather than arguing about
it.**

### The measurement that settles it

**Row 19 of the self-test page is now `MIX LN : BUILDS`** = `dbg_lines` =
{mixer lines composed, playfield lines built} last frame, both reset every
frame. Added 2026-09-13, replacing `PF WR : SPR WR`, whose two halves both
saturate at `FFFF` within a second of boot and can never move again.

```
MIX LN : BUILDS  01000100   256 and 256 -- every line built
MIX LN : BUILDS  010000FF   one build dropped last frame
```

- **BUILDS below `0100` while EAR tears: CONFIRMED**, and the row counts it.
- **`01000100` throughout a tearing scene: the theory is DEAD**, and the seam
  is somewhere that does not skip a build -- go to the second suspect below.

Read it during actual vertical scrolling, not attract. That is the whole point.

Note the row was on the page once before, as `MIX : BUILD`, and was removed as
*"the constant 01000100 whenever the pipe runs at all"* (the comment survives
at `rf_selftest.sv` row 22). That was true of every scene anyone had looked
at, and it is exactly why it is worth reading now.

## Second suspect: per-line scroll out of line RAM

Untested, and it needs no build to test. The F3 makes every scanline
independently scrollable through line RAM at 0x620000, which `rf_video_line`
decodes into `rowscroll` / `colscroll` per line. If the game rewrites line RAM
while the frame is being built, per-line scroll changes under the beam with
the video control registers -- and therefore the `VCTRL` instrument --
entirely innocent.

**How to test, off-board:** point `tools/mame/vctrltap.lua` at line RAM with
`VT_LO` / `VT_HI` and look for writes landing outside vblank on a scrolling
scene, exactly as the 0x660000 tap did.

## Candidate fixes, if the dropped-build theory confirms

Ranked by cost. None of these is worth building before the measurement says
which problem is being solved.

1. **Make the Y position a function of the line number instead of an
   accumulator.** `gy = sy + line * y_scale` computed per line rather than
   summed. A dropped build then costs one stale line instead of shifting the
   whole bottom of the frame -- the failure degrades from a seam to a single
   line, which is the same trade `NREC = 8192` made for the sprite store
   (rows dropped beats rows aliased). Costs a multiplier per playfield, which
   on a device at 99 % ALMs is the thing to check first.
2. **Make `line_start` sticky.** Latch a pending request instead of dropping
   it, so an overrunning build is followed immediately by the one it delayed
   and the accumulator keeps its count. Cheap in logic. Does not fix the
   picture -- the late line still misses its raster -- but it stops one late
   line from corrupting every line beneath it.
3. **Find and remove the overrun.** Only worth doing once the counter says
   which scene overruns and by how much; `MAXFETCH:BUILD` on that scene says
   whether it is fetch wait or sheer density, exactly as `SPRFETCH:ROWMAX`
   does for the sprite side.

## The rule this file exists to enforce

The same one [SPRITE-CORRUPTION.md](SPRITE-CORRUPTION.md) ends with, because
this bug has already cost one wrong answer in the README for months:

**Take the measurement first. State what result would kill the theory, before
building anything.** The row above is that statement for the leading theory.
