# Verilator benches for the Ray Force video RTL.
#
#   make gfx    fetch tile rows through rf_gfx_bus and diff against f3_gfx.py
#   make line   decode line RAM through rf_video_line and diff against f3_render.py
#   make line-all  the same over every dumped frame
#   make eeprom   93C46 protocol: EWEN, WRITE, READ with the dummy bit, idle DO
#   make pf       a frame of playfield lines through rf_video_pf vs the model
#   make pf-mosaic  the same with mosaic forced on (Ray Force never uses it)
#   make pf-all   the playfield bench over every dumped frame
#   make mix      END TO END: decode + playfields + tile fetch + mixer vs MAME's frame
#   make mix-all  the same over every frame that has its two predecessors dumped
#   make pipe     rf_video_pipe under real raster timing vs the playfields-only model
#   make pipe-60  the same with the 257-line 60 Hz frame (Refresh Rate OSD option)
#   make spr-lat  frame 2930 -- the frame the BOARD was caught getting wrong --
#                 with only the sprite channel slowed (F3_SPS_LAT). This is
#                 the gate for the sprite fetch path; see the target below.
#   make spr-rec  the sprite record count (rec_peak) against the model's run
#                 count, on three frames incl. the shrink-heavy one (4200)
#   make pipe-lat frame 3000 (114 sprite-rows on a line) at a hardware-like
#                 channel turnaround. The bench's latency IS the per-burst
#                 occupancy of the shared sprite channel (rf_spr_ch_share
#                 holds one burst outstanding), so it stands for the real
#                 controller's turnaround: ~14 ram clocks idle (traced through
#                 rf_sdram's states), more with the playfield channels
#                 contending. 24 is the gate; 34 is printed for information
#                 (the 114-record line cannot fit 228 bursts x 34 whatever the
#                 queue depth). The sprmax:missed field is what the self-test
#                 page's SPRLINE : MISS row reports, which calibrates this.
#
# Needs the gfx region dumps in ../dump -- see "How to run the video oracle"
# in HANDOFF.md.
VERILATOR ?= verilator
VFLAGS = -DVERILATOR --cc --exe --build -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
RTL = ../rtl

.PHONY: ddrarb ddr-sweep gfx spr-gfx line line-all eeprom pf pf-mosaic pf-all mix mix-all pipe pipe-60 pipe-lat spr-lat spr-rec spr spr-all spr-line spr-line-all spr-ghost es5505 es5505-rw \
        ear-mix ear-mix-all ear-pipe-all ear-spr-line-all clean

gfx: obj_dir/gfxtb
	./obj_dir/gfxtb ../dump fetched.txt
	python3 check_gfx.py

obj_dir/gfxtb: gfx_tb.cpp $(RTL)/rf_gfx_bus.sv
	$(VERILATOR) $(VFLAGS) --top-module rf_gfx_bus $(RTL)/rf_gfx_bus.sv gfx_tb.cpp -o gfxtb

line: obj_dir/linetb line_ref.txt
	./obj_dir/linetb ../dump/f3_01800_line_ram.bin 1 line_out.txt
	python3 check_line.py

line-all: obj_dir/linetb
	./run_line_all.sh

line_ref.txt: gen_line_ref.py ../tools/f3_render.py
	python3 gen_line_ref.py ../dump 1800 > $@

obj_dir/linetb: line_tb.cpp $(RTL)/rf_video_line.sv
	$(VERILATOR) $(VFLAGS) --top-module rf_video_line $(RTL)/rf_video_line.sv line_tb.cpp -o linetb

eeprom: obj_dir/eetb
	./obj_dir/eetb

# Does rotation ever lose a write on the shared DDRAM port? See ddrarb_tb.cpp
# and the header of rf_ddr_arb.sv -- this is the bench for the one defect that
# lives on the ROTATION side of that port, which every other bench here is
# blind to because they all model the sprite side.
ddrarb: obj_dir/ddrarbtb
	./obj_dir/ddrarbtb

obj_dir/ddrarbtb: ddrarb_tb.cpp $(RTL)/rf_ddr_arb.sv
	$(VERILATOR) $(VFLAGS) --top-module rf_ddr_arb $(RTL)/rf_ddr_arb.sv ddrarb_tb.cpp -o ddrarbtb

obj_dir/eetb: ee_tb.cpp $(RTL)/rf_eeprom_93c46.sv
	$(VERILATOR) $(VFLAGS) --top-module rf_eeprom_93c46 $(RTL)/rf_eeprom_93c46.sv ee_tb.cpp -o eetb

PF_RTL = $(RTL)/rf_video_line.sv $(RTL)/rf_video_pf.sv $(RTL)/rf_gfx_bus.sv $(RTL)/rf_bram.sv

pf: obj_dir/pftb pf_ref.txt
	./obj_dir/pftb ../dump 1800 pf_out.txt
	python3 check_pf.py pf_ref.txt pf_out.txt

pf-mosaic: obj_dir/pftb
	python3 gen_pf_ref.py ../dump 1800 --mosaic 5 > pf_ref_m5.txt
	./obj_dir/pftb ../dump 1800 pf_out_m5.txt 5
	python3 check_pf.py pf_ref_m5.txt pf_out_m5.txt

pf-all: obj_dir/pftb
	./run_pf_all.sh

pf_ref.txt: gen_pf_ref.py ../tools/f3_render.py
	python3 gen_pf_ref.py ../dump 1800 > $@

obj_dir/pftb: pf_tb.cpp pf_top.sv $(PF_RTL)
	$(VERILATOR) $(VFLAGS) --top-module pf_top pf_top.sv $(PF_RTL) pf_tb.cpp -o pftb

MIX_RTL = $(PF_RTL) $(RTL)/rf_video_mix.sv

mix: obj_dir/mixtb mix_ref.txt
	./obj_dir/mixtb ../dump 1800 mix_ref.txt mix_out.txt

mix-all: obj_dir/mixtb
	./run_mix_all.sh

mix_ref.txt: gen_mix_ref.py ../tools/f3_render.py
	python3 gen_mix_ref.py ../dump 1800 > $@

obj_dir/mixtb: mix_tb.cpp mix_top.sv $(MIX_RTL)
	$(VERILATOR) $(VFLAGS) --top-module mix_top mix_top.sv $(MIX_RTL) mix_tb.cpp -o mixtb

PIPE_RTL = $(MIX_RTL) $(RTL)/rf_video_pivot.sv $(RTL)/rf_video_spr_list.sv $(RTL)/rf_spr_gfx_bus.sv $(RTL)/rf_spr_ch_share.sv $(RTL)/rf_spr_fb.sv $(RTL)/rf_video_spr.sv $(RTL)/rf_video_pipe.sv

# ---- sprite list walker (stage a) ----
spr: obj_dir/sprtb spr_ref.txt
	./obj_dir/sprtb ../dump 1800 spr_ref.txt

spr-all: obj_dir/sprtb
	@for f in $$(ls ../dump/f3_*_spriteram.bin | sed 's/.*f3_0*\([0-9]*\)_spriteram.bin/\1/'); do \
	  s2=$$(printf '../dump/f3_%05d_spriteram.bin' $$((f-2))); [ -f $$s2 ] || continue; \
	  python3 gen_spr_ref.py ../dump $$f > spr_ref_$$f.txt; \
	  printf '%-8s ' "frame $$f:"; ./obj_dir/sprtb ../dump $$f spr_ref_$$f.txt | tail -1 || exit 1; \
	done

spr_ref.txt: gen_spr_ref.py ../tools/f3_render.py
	python3 gen_spr_ref.py ../dump 1800 > $@

obj_dir/sprtb: spr_tb.cpp $(RTL)/rf_video_spr_list.sv
	$(VERILATOR) $(VFLAGS) --top-module rf_video_spr_list $(RTL)/rf_video_spr_list.sv spr_tb.cpp -o sprtb

# ---- sprite gfx fetch (stage b) ----
spr-gfx: obj_dir/sprgfxtb
	./obj_dir/sprgfxtb ../dump spr_fetched.txt
	python3 check_spr_gfx.py ../dump spr_fetched.txt

obj_dir/sprgfxtb: spr_gfx_tb.cpp $(RTL)/rf_spr_gfx_bus.sv $(RTL)/rf_bram.sv
	$(VERILATOR) $(VFLAGS) --top-module rf_spr_gfx_bus $(RTL)/rf_spr_gfx_bus.sv $(RTL)/rf_bram.sv spr_gfx_tb.cpp -o sprgfxtb

# ---- per-line sprite builder (stage c) ----
SPR_RTL = $(RTL)/rf_video_spr_list.sv $(RTL)/rf_spr_gfx_bus.sv $(RTL)/rf_bram.sv $(RTL)/rf_video_spr.sv

spr-line: obj_dir/sprlinetb spr_fb_ref.txt
	./obj_dir/sprlinetb ../dump 1800 spr_fb_ref.txt

# ghost regression: a busy frame (3000, 198 sprites) followed by a quiet one
# (300). The line buffer is never cleared, so frame 300 must show none of
# frame 3000's pixels -- it did before the frame-parity tag (2026-08-28).
# Elevator Action Returns against MAME. Its visible raster is the base f3 one
# (232 lines from line 24), so the model needs F3_VIS=f3 or every comparison
# is off by seven lines and reads as a total mismatch.
#   make ear-mix              one frame
#   make ear-mix EAR_FRAME=1800
EAR_FRAME ?= 600
ear-mix: obj_dir/mixtb
	F3_VIS=f3 python3 gen_mix_ref.py ../dump/ear $(EAR_FRAME) > mix_ref_ear.txt
	F3_FLIP=0 ./obj_dir/mixtb ../dump/ear $(EAR_FRAME) mix_ref_ear.txt mix_out_ear.txt

ear-mix-all: obj_dir/mixtb
	@for f in $(EAR_FRAMES); do \
	  printf 'frame %5s: ' $$f; \
	  F3_VIS=f3 python3 gen_mix_ref.py ../dump/ear $$f > mix_ref_ear.txt 2>/dev/null; \
	  F3_FLIP=0 ./obj_dir/mixtb ../dump/ear $$f mix_ref_ear.txt mix_out_ear.txt 2>&1 | grep -E 'identical' | tail -1; \
	done

# ---- Elevator Action Returns --------------------------------------------
# EAR uses the base f3 visarea (232 lines from 24), not Ray Force's f3_224a
# (224 from 31), so both the bench window (F3_V0/F3_V1, F3_VIS) and the RTL's
# own sprite cull (F3_VISMODE / the vis_mode port) have to say so. Running it
# with Ray Force's window hides every defect in the 8 lines outside it.
# every dumped frame whose two predecessors are also dumped (sprite lag 2)
EAR_FRAMES = $(shell ls ../dump/ear/f3_*_frame.argb 2>/dev/null | \
  sed 's|.*f3_0*\([0-9]*\)_frame.argb|\1|' | \
  while read f; do \
    [ -f ../dump/ear/f3_$$(printf '%05d' $$((f-1)))_frame.argb ] && \
    [ -f ../dump/ear/f3_$$(printf '%05d' $$((f-2)))_frame.argb ] && echo $$f; \
  done)

ear-pipe-all: obj_dir/pipetb
	@for f in $(EAR_FRAMES); do \
	  printf 'frame %5s: ' $$f; \
	  F3_VIS=f3 python3 gen_pipe_ref.py ../dump/ear $$f > pipe_ref_ear_$$f.txt; \
	  F3_V0=24 F3_V1=256 ./obj_dir/pipetb ../dump/ear $$f pipe_ref_ear_$$f.txt \
	      pipe_out_ear_$$f.ppm 2>&1 | tail -1 || exit 1; \
	done

ear-spr-line-all: obj_dir/sprlinetb
	@for f in $(EAR_FRAMES); do \
	  printf 'frame %5s: ' $$f; \
	  F3_VIS=f3 python3 gen_spr_fb_ref.py ../dump/ear $$f > spr_fb_ref_ear_$$f.txt; \
	  F3_VISMODE=3 ./obj_dir/sprlinetb ../dump/ear $$f spr_fb_ref_ear_$$f.txt \
	      2>&1 | tail -1 || exit 1; \
	done

# ---- Bubble Bobble II / Bubble Memories ---------------------------------
# Both use f3_224a, Ray Force's own crop, so NO visarea override is needed --
# unlike the ear-* targets above. What they DO need is F3_LAG=1: MAME's
# f3_config_table gives these two games sprite_lag 1 where Ray Force has 2.
#
# Getting that wrong does not look like a timing bug, it looks like a sprite
# RENDERING bug confined to sprite pixels, and it cost a wrong conclusion in
# PREP-BUBBLE.md (blamed on the sprite block/multi path, which these games
# exercise on 97% of sprites against Ray Force's 2%). At lag 1 the model is
# 0/71680 against MAME on all ten frames of both games; at lag 2 it is not.
# F3_LAG goes to BOTH sides -- the generator and the bench -- or they compare
# different frames.
#
#   make bb2-pipe-all        every dumped bb2 frame through the full pipe
#   make bmem-spr-line-all   sprite framebuffer only
BUBBLE_LAG = 1
# Only frames whose LAG-back sprite dump also exists. The dumps come in
# triples (f-2, f-1, f) sized for lag 2, so at lag 1 the FIRST of each triple
# has no predecessor and must be skipped rather than reported as a failure.
bb2_FRAMES = $(shell ls ../dump/bb2/f3_*_frame.argb 2>/dev/null | \
  sed 's|.*f3_0*\([0-9]*\)_frame.argb|\1|' | \
  while read f; do \
    [ -f ../dump/bb2/f3_$$(printf '%05d' $$((f-$(BUBBLE_LAG))))_spriteram.bin ] && echo $$f; \
  done)
bmem_FRAMES = $(shell ls ../dump/bmem/f3_*_frame.argb 2>/dev/null | \
  sed 's|.*f3_0*\([0-9]*\)_frame.argb|\1|' | \
  while read f; do \
    [ -f ../dump/bmem/f3_$$(printf '%05d' $$((f-$(BUBBLE_LAG))))_spriteram.bin ] && echo $$f; \
  done)

bb2-pipe-all: obj_dir/pipetb
	@for f in $(bb2_FRAMES); do \
	  printf 'bb2   frame %5s: ' $$f; \
	  F3_LAG=$(BUBBLE_LAG) python3 gen_pipe_ref.py ../dump/bb2 $$f > pipe_ref_bb2_$$f.txt; \
	  F3_LAG=$(BUBBLE_LAG) ./obj_dir/pipetb ../dump/bb2 $$f pipe_ref_bb2_$$f.txt \
	      pipe_out_bb2_$$f.ppm 2>&1 | tail -1 || exit 1; \
	done

bmem-pipe-all: obj_dir/pipetb
	@for f in $(bmem_FRAMES); do \
	  printf 'bmem  frame %5s: ' $$f; \
	  F3_LAG=$(BUBBLE_LAG) python3 gen_pipe_ref.py ../dump/bmem $$f > pipe_ref_bmem_$$f.txt; \
	  F3_LAG=$(BUBBLE_LAG) ./obj_dir/pipetb ../dump/bmem $$f pipe_ref_bmem_$$f.txt \
	      pipe_out_bmem_$$f.ppm 2>&1 | tail -1 || exit 1; \
	done

bb2-spr-line-all: obj_dir/sprlinetb
	@for f in $(bb2_FRAMES); do \
	  printf 'bb2   frame %5s: ' $$f; \
	  F3_LAG=$(BUBBLE_LAG) python3 gen_spr_fb_ref.py ../dump/bb2 $$f > spr_fb_ref_bb2_$$f.txt; \
	  F3_LAG=$(BUBBLE_LAG) ./obj_dir/sprlinetb ../dump/bb2 $$f spr_fb_ref_bb2_$$f.txt \
	      2>&1 | tail -1 || exit 1; \
	done

bmem-spr-line-all: obj_dir/sprlinetb
	@for f in $(bmem_FRAMES); do \
	  printf 'bmem  frame %5s: ' $$f; \
	  F3_LAG=$(BUBBLE_LAG) python3 gen_spr_fb_ref.py ../dump/bmem $$f > spr_fb_ref_bmem_$$f.txt; \
	  F3_LAG=$(BUBBLE_LAG) ./obj_dir/sprlinetb ../dump/bmem $$f spr_fb_ref_bmem_$$f.txt \
	      2>&1 | tail -1 || exit 1; \
	done

bubble-all: bb2-spr-line-all bmem-spr-line-all bb2-pipe-all bmem-pipe-all

spr-ghost: obj_dir/sprlinetb spr_fb_ref_3000.txt spr_fb_ref_300.txt
	./obj_dir/sprlinetb ../dump 3000 spr_fb_ref_3000.txt 300 spr_fb_ref_300.txt

spr_fb_ref_%.txt: gen_spr_fb_ref.py ../tools/f3_render.py
	python3 gen_spr_fb_ref.py ../dump $* > $@

spr-line-all: obj_dir/sprlinetb
	@for f in $$(ls ../dump/f3_*_spriteram.bin | sed 's/.*f3_0*\([0-9]*\)_spriteram.bin/\1/'); do \
	  s2=$$(printf '../dump/f3_%05d_spriteram.bin' $$((f-2))); [ -f $$s2 ] || continue; \
	  python3 gen_spr_fb_ref.py ../dump $$f > spr_fb_ref_$$f.txt; \
	  printf '%-10s ' "frame $$f:"; ./obj_dir/sprlinetb ../dump $$f spr_fb_ref_$$f.txt | tail -1 || exit 1; \
	done

spr_fb_ref.txt: gen_spr_fb_ref.py ../tools/f3_render.py
	python3 gen_spr_fb_ref.py ../dump 1800 > $@

obj_dir/sprlinetb: spr_line_tb.cpp $(SPR_RTL)
	$(VERILATOR) $(VFLAGS) --top-module rf_video_spr $(SPR_RTL) spr_line_tb.cpp -o sprlinetb

pipe: obj_dir/pipetb pipe_ref.txt
	./obj_dir/pipetb ../dump 1800 pipe_ref.txt pipe_out.ppm

# every frame whose two predecessors were dumped (the sprite lag), each
# against its own reference
# The DDR3 model's latency gate. Exact from 4 to 400 cycles with the port
# stalled up to 1-in-2; at LAT<=2 -- returns faster than the HPS DDR3
# controller can physically answer (~10+ cycle round trip) -- 12 pixels on
# the first three visible lines differ. Documented rather than hidden: it is
# outside the port's envelope, but it is not understood, and if a sprite
# corner ever misbehaves at the TOP of the screen on hardware, start here.
ddr-sweep: obj_dir/pipetb
	@for cfg in "20 7 8" "40 7 30" "200 3 30" "400 2 8"; do \
	  set -- $$cfg; printf "LAT=%-4s BUSY=%-3s CMD=%-3s " $$1 $$2 $$3; \
	  F3_DDR_LAT=$$1 F3_DDR_BUSY=$$2 F3_DDR_CMD=$$3 ./obj_dir/pipetb ../dump 2930 pipe_ref_2930.txt /dev/null | tail -1; \
	done
	@echo "(not gated: LAT<=12 -- under the HPS's ~300-500ns real round trip --"
	@echo " shows 4-12 px on the top rows; and CMD=60 BUSY=2, where raw port"
	@echo " capacity is below 256 lines of writes a frame. Neither is reachable"
	@echo " on hardware; the first is the documented top-of-screen corner.)"

pipe-all: obj_dir/pipetb
	@for f in $$(ls ../dump/f3_*_frame.argb | sed 's/.*f3_0*\([0-9]*\)_frame.argb/\1/'); do \
	  p1=$$(printf '../dump/f3_%05d_frame.argb' $$((f-1))); p2=$$(printf '../dump/f3_%05d_frame.argb' $$((f-2))); \
	  [ -f $$p1 ] && [ -f $$p2 ] || continue; \
	  python3 gen_pipe_ref.py ../dump $$f > pipe_ref_$$f.txt; \
	  echo "== frame $$f"; ./obj_dir/pipetb ../dump $$f pipe_ref_$$f.txt pipe_out_$$f.ppm | tail -1 || exit 1; \
	done

pipe-60: obj_dir/pipetb pipe_ref.txt
	./obj_dir/pipetb ../dump 1800 pipe_ref.txt pipe_out.ppm 14 1

# ---- ES5505 sampler vs the Python model (Phase 3, stage 2) ----
#   the model's raw 8-channel output for the captured stream, and the ROM
#   bytes it read, are the reference; 45 s of writes at 29.76 kHz
es5505: obj_dir/es5505tb es5505_rom.bin $(ES5505_REF)
	./obj_dir/es5505tb $(ES5505_STREAM) es5505_rom.bin $(ES5505_REF) $(ES5505_N)

ES5505_N ?= 60000
# the write(+read) stream and the model's raw reference for it; en5 carries
# the driver's ES5505 READS (ESR lines), which the bench checks too
ES5505_STREAM ?= ../dump/en3/en_writes.txt
ES5505_REF ?= es5505_ref.raw

es5505-rw:
	$(MAKE) es5505 ES5505_STREAM=../dump/en5/en_writes.txt ES5505_REF=es5505_ref5.raw ES5505_N=$(ES5505_N)

es5505_ref5.raw: ../tools/es5505_model.py
	python3 ../tools/es5505_model.py ../dump/en5 --rom .. --seconds 45 --raw $@

es5505_rom.bin: ../tools/es5505_model.py
	python3 ../tools/es5505_model.py ../dump/en3 --rom .. --dump-rom $@

es5505_ref.raw: ../tools/es5505_model.py
	python3 ../tools/es5505_model.py ../dump/en3 --rom .. --seconds 45 --raw $@

obj_dir/es5505tb: es5505_tb.cpp $(RTL)/rf_es5505.sv
	$(VERILATOR) $(VFLAGS) --top-module rf_es5505 $(RTL)/rf_es5505.sv es5505_tb.cpp -o es5505tb

pipe-lat: obj_dir/pipetb
	python3 gen_pipe_ref.py ../dump 3000 > pipe_ref_3000.txt
	./obj_dir/pipetb ../dump 3000 pipe_ref_3000.txt pipe_out_3000_lat.ppm 24
	-./obj_dir/pipetb ../dump 3000 pipe_ref_3000.txt pipe_out_3000_lat34.ppm 34 | tail -2

# ---- the SPRITE FETCH gate ----------------------------------------------
# Frame 2930 is the frame the board was caught rendering WRONG (2026-08-29).
# The cabinet screenshot at that instant (screenshots/glitch_board/t062.png)
# and MAME's own frame 2930 differ in 1124 pixels, EVERY ONE of them on rows
# 210-223 -- the last 14 lines -- with rows 0-209 pixel-identical. Nothing was
# wrong with the rendering: the same frame is 71680/71680 identical here. The
# sprite draw ran out of time partway down and the ring's run-ahead never
# recovered before the frame ended.
#
# F3_SPS_LAT is the SPRITE channel's round trip in ram clocks, on its own.
# The `lat` positional argument cannot stand in for it: that slows the
# playfield channels too (ch1/ch2, the controller's top two priorities) and
# the frame then breaks everywhere instead of at the bottom, where the board
# breaks it. Measured (F3_FRAMES=20, see pipe_tb.cpp): with one channel the
# frame is exact to lat 70 and breaks at 75; with the two channels ch4/ch7 it
# is exact to 135 and breaks at 140. 130 is the gate -- inside what is
# verified, and not claiming margin that is not there.
SPS_LAT ?= 130
spr-lat: obj_dir/pipetb
	python3 gen_pipe_ref.py ../dump 2930 > pipe_ref_2930.txt
	F3_SPS_LAT=$(SPS_LAT) ./obj_dir/pipetb ../dump 2930 pipe_ref_2930.txt pipe_out_2930_lat.ppm

# ---- the record STORE gate ---------------------------------------------
# Records are run-length (2026-08-29): one per run of consecutive source rows
# of a sprite landing on one screen line, not one per row. The pixel benches
# prove the draw still lays every row down; this proves the prepass builds
# exactly as many records as the model says a frame needs -- rec_peak, the
# high half of dbg_rec, against tools/f3_rec_count.py --lag (the bench draws
# frame f from frame f-2's sprite RAM). 4200 is the shrink-heavy frame where
# the run-length form matters most (2672 rows -> 854 records); a prepass
# that split or merged runs wrongly would show here before it showed on the
# page.
SPR_REC_FRAMES ?= 1800 2930 4200
spr-rec: obj_dir/pipetb
	@rc=0; for f in $(SPR_REC_FRAMES); do \
	  [ -f pipe_ref_$$f.txt ] || python3 gen_pipe_ref.py ../dump $$f > pipe_ref_$$f.txt; \
	  got=$$(./obj_dir/pipetb ../dump $$f pipe_ref_$$f.txt /dev/null | grep -o 'dbg_rec [0-9a-f]*' | awk '{print $$2}'); \
	  got=$$((16#$${got:0:4})); \
	  want=$$(python3 ../tools/f3_rec_count.py ../dump $$f --lag | tail -1 | awk '{print $$4}'); \
	  if [ "$$got" = "$$want" ]; then echo "frame $$f: $$got records, matches the model"; \
	  else echo "frame $$f: RTL built $$got records, model says $$want -- MISMATCH"; rc=1; fi; \
	done; exit $$rc

pipe_ref.txt: gen_pipe_ref.py ../tools/f3_render.py
	python3 gen_pipe_ref.py ../dump 1800 > $@

obj_dir/pipetb: pipe_tb.cpp pipe_top.sv $(PIPE_RTL)
	$(VERILATOR) $(VFLAGS) --top-module pipe_top pipe_top.sv $(PIPE_RTL) pipe_tb.cpp -o pipetb

clean:
	rm -rf obj_dir fetched.txt spr_fetched.txt line_out.txt line_ref.txt pf_out*.txt pf_ref*.txt mix_out*.txt mix_ref*.txt pipe_out*.ppm pipe_ref*.txt spr_ref*.txt spr_fb_ref*.txt
