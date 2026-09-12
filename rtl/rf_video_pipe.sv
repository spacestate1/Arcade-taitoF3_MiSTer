//============================================================================
//  Video pipeline: the verified blocks, driven by the raster.
//
//  Line decode (rf_video_line), playfield build (rf_video_pf) over the SDRAM
//  tile fetch (rf_gfx_bus), and the mixer (rf_video_mix) each work a whole
//  scanline at a time, so they run AHEAD of the beam and hand off through
//  double-banked line buffers. During raster line T:
//
//      mixer      composes screen line T+1 into output bank (T+1)&1
//      decoder    decodes  screen line T+2       -- then --
//      builder    builds   screen line T+2 into its other playfield bank
//      the beam   reads    output bank T&1
//
//  Screen lines are 0..255 (the line-RAM index runs over exactly those);
//  raster lines 256..261 are the vertical blank and have nothing to decode,
//  so the lookahead wraps: line 0 is decoded during raster 260 and mixed
//  during raster 261. frame_start -- which reloads the scroll registers and
//  clears the per-frame latch state, as the model does at the top of
//  render_frame -- fires at the start of raster 260, before line 0 is
//  decoded.
//
//  Ordering inside a raster line matters: the mixer latches its copy of the
//  line decode two clocks after mix_start, so mix_start goes first and the
//  decoder is started a few clocks later; otherwise the decoder would
//  already be overwriting line T+1's values with T+2's. The builder waits
//  for the decoder by construction (pf_go).
//
//  Budget per raster line is 3456 clocks. Measured in simulation against a
//  behavioural SDRAM: mixer 1307, decode + build up to ~2315, concurrent.
//  The real controller's latency is higher; the count is re-measured on
//  hardware from the frame counter on the self-test page.
//
//  The pivot/text layer (rf_video_pivot) builds alongside the playfields on
//  its own RAM ports. The sprite engine (rf_video_spr) draws the same line
//  as the playfields, started at the top of the raster line.
//============================================================================

module rf_video_pipe
(
    input  logic        clk,
    input  logic        reset,
    input  logic        clk_ram,

    // raster position from rayforce_video
    input  logic  [2:0] div,
    input  logic  [8:0] hcnt,
    input  logic  [8:0] vcnt,
    input  logic        hblank,
    input  logic        vblank,
    input  logic        rate_60,       // 257-line frame (see rayforce_video)

    // video control registers 0x660000-1F
    input  logic [7:0][15:0] ctrl0,
    input  logic [7:0][15:0] ctrl1,
    // Flipscreen DEFAULT only. The live value comes from the sprite command
    // word via the sprite engine (`flip_eff` below) -- MAME takes
    // m_flipscreen from exactly that bit, and it must follow the game: Ray
    // Force sets it permanently, Elevator Action Returns does not, and this
    // core used to wire it to a constant 1, which rendered that game upside
    // down. The port is what the layers use until the first prepass has run.
    input  logic        flip,

    // which F3 visarea this game uses -- the sprite cull needs it, or the
    // lines outside Ray Force's 224-line window are dropped
    input  logic  [1:0] vis_mode,

    // f3_config_table "extend": 1 = four 64x32 playfields (Ray Force,
    // Elevator Action Returns, both Bubble Bobble games), 0 = eight 32x32
    // (Puzzle Bobble, Darius Gaiden, Cleopatra Fortune, Grid Seeker,
    // Space Invaders '95, Gekirindan). Changes playfield addressing.
    input  logic        extend,

    // video RAM read ports (B side of the CPU's BRAMs)
    output logic [14:0] line_addr,
    input  logic [15:0] line_q,
    output logic [13:0] pf_addr,
    input  logic [15:0] pf_q,
    output logic [13:0] pal_addr,
    input  logic [15:0] pal_q,
    output logic [11:0] text_addr,
    input  logic [15:0] text_q,
    output logic [11:0] char_addr,
    input  logic [15:0] char_q,
    output logic [14:0] pivot_addr,
    input  logic [15:0] pivot_q,

    // SDRAM channels for the two tile planes
    output logic [26:1] ch1_addr,
    input  logic [63:0] ch1_dout,
    output logic        ch1_req,
    input  logic        ch1_ready,
    output logic [26:1] ch2_addr,
    input  logic [63:0] ch2_dout,
    output logic        ch2_req,
    input  logic        ch2_ready,

    // sprite RAM read port (B side of the CPU's sprite BRAM), for the walker
    output logic [14:0] spr_addr,
    input  logic [15:0] spr_q,

    // sprite gfx SDRAM channels: two fetch buses (A, B) x two planes (lo,
    // hi). Only ch4 is free on the real controller, so all four share it
    // through rf_spr_ch_share at Rayforce.sv (and in the bench's pipe_top).
    output logic [26:1] spr_a_lo_addr,
    input  logic [63:0] spr_a_lo_dout,
    output logic        spr_a_lo_req,
    input  logic        spr_a_lo_ready,
    output logic [26:1] spr_a_hi_addr,
    input  logic [63:0] spr_a_hi_dout,
    output logic        spr_a_hi_req,
    input  logic        spr_a_hi_ready,
    output logic [26:1] spr_b_lo_addr,
    input  logic [63:0] spr_b_lo_dout,
    output logic        spr_b_lo_req,
    input  logic        spr_b_lo_ready,
    output logic [26:1] spr_b_hi_addr,
    input  logic [63:0] spr_b_hi_dout,
    output logic        spr_b_hi_req,
    input  logic        spr_b_hi_ready,

    output logic [23:0] rgb,           // blanked outside the visible area

    // per-frame diagnostics for the self-test page, latched at frame end
    output logic [31:0] dbg_lines,     // {mixer lines done, playfield builds done}
    output logic [31:0] dbg_fetch,     // {tile fetches done, non-black output pixels}
    output logic [31:0] dbg_max,       // {longest fetch, longest build} in clocks
    output logic [31:0] dbg_nz,        // {fetches with non-zero pixels,
                                       //  OR of playfield samples[7:0],
                                       //  OR of palette reads[7:0]}
    // {longest single sprite gfx fetch in clocks, most rows drawn on one
    // line}. SPRLINE gives a line's total; these two say which half of it
    // is fetch wait and which is sheer density -- the question the dumps
    // cannot answer because every one of them is attract.
    // ---- the sprite framebuffer's DDR3 port, out to rf_ddr_arb ----------
    output logic  [7:0] ddr_burstcnt,
    output logic [28:0] ddr_addr,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    output logic        ddr_we,
    output logic        ddr_rd,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,
    // ---- the output flip (rf_out_flip): the raw output upside down ------
    input  logic        out_flip,
    output logic [31:0] dbg_flip,      // {reader late lines, writer late lines}

    output logic [31:0] dbg_sfetch,
    output logic [31:0] dbg_spr,       // {longest sprite line draw in clocks,
                                       //  lines the mixer started before the
                                       //  sprite draw had finished them}
    output logic [31:0] dbg_rec,       // {sprite-row records built last
                                       //  prepass, rows dropped at the cap}

    // ---- DIAGNOSTIC (see rf_spr_fb.sv) ----------------------------------
    // {fold of the sprite pixels handed to DDR3, fold of the ones read back}
    // INSTRUMENT (see rf_ddr_arb.sv): times a sprite line's DDR3 read came
    // back short and the line had to be refetched from zero.
    output logic [15:0] dbg_short,
    output logic [15:0] dbg_flush,   // rf_ddr_tag_mux watchdog flushes
    // THE FOLD PAIR (rf_spr_fb.sv's own decision table). Same pixels summed
    // either side of the DDR3 round trip, the write side delayed a frame so
    // both describe the SAME drawn frame:
    //   wr != rd            the round trip corrupts        -> DDR3 path
    //   wr == rd != model   the draw wrote it wrong        -> record / list
    //   wr == rd == model   both fine                      -> mixer / palette
    // Built long ago and never routed to the page, which is why the question
    // it answers has stayed open.
    output logic [31:0] dbg_fold,
    // TEARING INSTRUMENT (see rf_video_spr.sv): {writes to sprite RAM that
    // landed while the list walk was reading it, frames in which that
    // happened}.
    input  logic        spr_wr_stb,
    output logic [31:0] dbg_tear,
    // SEQUENCE INSTRUMENTS (see rf_video_spr.sv): last four frames, newest first
    output logic [31:0] dbg_seq_rec01, dbg_seq_rec23,
    output logic [31:0] dbg_seq_nspr01, dbg_seq_nspr23,
    output logic [31:0] dbg_seq_ovr,
    // FOLDSEQ: rf_spr_fb's wr_fold -- the sum of every sprite pixel the draw
    // handed to DDR3 that frame -- as a ring of the last four frames. On a
    // paused glitch the prepass is identical every frame; if THIS is
    // X Y X Y the draw's output is not, and the fault is in the draw.
    // If it is constant, the draw is deterministic and the fault is in the
    // mixer (see USEDSEQ).
    output logic [31:0] dbg_seq_fold01, dbg_seq_fold23,
    output logic [31:0] dbg_seq_used01, dbg_seq_used23,
    output logic [31:0] dbg_sprpix,
    // DIAGNOSTIC: the mixer's own inputs on a wrong pixel (rf_video_mix)
    output logic [31:0] dbg_mixpix,
    // 0 = no cap, 1 = 256 rows a line, 2 = 128
    input  logic  [1:0] row_cap,
    // 12-bit palette entries, per game -- see rf_video_mix.sv
    input  logic        pal12,
    // SDRAM map profile bases (see cfg_map in Rayforce.sv). Two profiles:
    // the 18.5 MB map every earlier game uses, and a 36 MB map whose
    // sprites region is 13 MB, which is what the sets that did not fit need.
    input  logic [26:1] tile_base_lo,
    input  logic [26:1] tile_base_hi,
    input  logic [26:1] sgfx_base_lo,
    input  logic [26:1] sgfx_base_hi
);

    localparam int H_START = 46;

    // DIAGNOSTIC: 16 bits into 8, saturating rather than wrapping, so a
    // clamped field reads as ">= 255" instead of as a small honest number.
    function automatic logic [7:0] sat8(input logic [15:0] v);
        sat8 = (v > 16'd255) ? 8'hFF : v[7:0];
    endfunction

    // DIAGNOSTIC: the two folds either side of the DDR3 round trip.
    // Per-line verdict: which lines of the frame read back differently from
    // the way they were written, and how many. The frame TOTALS that this
    // replaces did their job -- they proved the read side returns pixels that
    // were never written, and that it happens only on visarea f3 -- but a
    // total cannot name a line, and the line numbers are the whole question
    // now (f3 admits sprites on lines 24..30 and 255; f3_224a does not).
    assign dbg_sprpix = {spr_bad_first, spr_bad_last, spr_bad_count};
    assign dbg_fold   = {spr_wr_fold, spr_rd_fold};
    assign dbg_tear   = {spr_tear_cnt, spr_tear_frames};
    logic [15:0] fold_seq [0:3];
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 4; i++) fold_seq[i] <= 16'd0;
        end else if (frame_start) begin
            fold_seq[0] <= spr_wr_fold;  fold_seq[1] <= fold_seq[0];
            fold_seq[2] <= fold_seq[1];  fold_seq[3] <= fold_seq[2];
        end
    end
    assign dbg_seq_fold01 = {fold_seq[0], fold_seq[1]};
    assign dbg_seq_fold23 = {fold_seq[2], fold_seq[3]};

    // ---- raster-driven sequencing ----------------------------------------
    // hcnt holds each value for eight clocks (div 0..7); div picks the clock.
    wire        h0        = (hcnt == 9'd0);
    // The frame is 262 lines native or 257 with the 60 Hz option (the same
    // pair of constants as rayforce_video); either way the last two raster
    // lines are the wrap where line 0 is decoded, then mixed.
    wire  [8:0] v_last    = rate_60 ? 9'd256 : 9'd261;     // V_TOTAL - 1
    wire  [8:0] v_last1   = v_last - 9'd1;                 // V_TOTAL - 2
    wire  [8:0] l_mix     = (vcnt == v_last)  ? 9'd0 : vcnt + 9'd1;
    wire  [8:0] l_bld     = (vcnt == v_last1) ? 9'd0 :
                            (vcnt == v_last)  ? 9'd1 : vcnt + 9'd2;
    wire        do_mix    = (l_mix <= 9'd255);
    wire        do_bld    = (l_bld <= 9'd255);

    logic frame_start, mix_start, dec_start;
    logic [7:0] bld_y;
    logic       mix_bank;
    logic [7:0] mix_y;                  // the line the mixer is composing
    // The output line buffer is THREE banks of 320 (960 of the 1024 words
    // its three M10K hold) as of the analog flip: the flip's writer reads a
    // finished line back out over the two rasters after it, so the bank has
    // to survive two lines, not one. mix_b3 is the bank the mixer composes
    // into this raster (line mod 3), beam_b3 the one it composed last raster
    // -- the line the beam shows now. Counted, not divided: +1 a line, 0 at
    // line 0.
    logic [1:0] mix_b3, beam_b3;
    function automatic logic [9:0] lb_base(input logic [1:0] b);
        lb_base = (b == 2'd0) ? 10'd0 : (b == 2'd1) ? 10'd320 : 10'd640;
    endfunction

    always_ff @(posedge clk) begin
        frame_start <= 1'b0;
        mix_start   <= 1'b0;
        dec_start   <= 1'b0;
        if (!reset && h0) begin
            case (div)
                3'd0: frame_start <= (vcnt == v_last1);
                3'd1: begin
                          beam_b3 <= mix_b3;
                          mix_b3  <= (l_mix == 9'd0) ? 2'd0 : (mix_b3 == 2'd2) ? 2'd0 : mix_b3 + 2'd1;
                          if (do_mix) begin
                              mix_start <= 1'b1;
                              mix_bank  <= l_mix[0];
                              mix_y     <= l_mix[7:0];
                          end
                      end
                // (the sprite draw is not started per line: it runs ahead
                // of the mixer on its own, see rf_video_spr)
                3'd4: if (do_bld) begin
                          dec_start <= 1'b1;
                          bld_y     <= l_bld[7:0];
                      end
                default: ;
            endcase
        end
    end

    // ---- line decoder ----------------------------------------------------
    logic line_busy;
    logic [3:0][8:0]  colscroll, x_scale, y_scale, clip_l, clip_r;
    logic [3:0][19:0] rowscroll;
    logic [3:0]       pf_mosaic, sp_bsel, pf_alt;
    logic [4:0]       x_sample;
    logic [3:0][3:0]  blend;
    logic [7:0]       fx_6400, pivot_control;
    logic [15:0]      bg_palette, pivot_enable, pivot_mix;
    logic             pivot_bsel, pivot_mosaic, sp_mosaic;
    logic [3:0][15:0] sp_mix, pf_pal_add, pf_mix;

    // "extend" (1024x512 playfields) comes from MAME's per-game config
    // table, not from control word 15, and so it comes from the MRA's game
    // config byte here rather than from anything the game writes.
    rf_video_line line (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .line_start(dec_start),
        .y(flip_eff ? (8'd255 - bld_y) : bld_y),
        .extend(extend), .busy(line_busy),
        .lr_addr(line_addr), .lr_q(line_q),
        .clip_l(clip_l), .clip_r(clip_r), .blend(blend), .x_sample(x_sample),
        .fx_6400(fx_6400), .bg_palette(bg_palette),
        .pivot_control(pivot_control), .pivot_bsel(pivot_bsel),
        .pivot_enable(pivot_enable), .pivot_mix(pivot_mix), .pivot_mosaic(pivot_mosaic),
        .sp_mix(sp_mix), .sp_bsel(sp_bsel), .sp_mosaic(sp_mosaic),
        .pf_colscroll(colscroll), .pf_alt_tilemap(pf_alt),
        .pf_x_scale(x_scale), .pf_y_scale(y_scale), .pf_pal_add(pf_pal_add),
        .pf_rowscroll(rowscroll), .pf_mix(pf_mix), .pf_mosaic(pf_mosaic)
    );

    // the builder starts the clock after the decoder finishes
    logic line_busy_d, pf_go, pf_busy;
    always_ff @(posedge clk) begin
        line_busy_d <= line_busy;
        pf_go       <= line_busy_d & ~line_busy;
    end

    // ---- playfields + tile fetch -----------------------------------------
    logic [14:0] gfx_code; logic [3:0] gfx_row;
    logic gfx_req, gfx_valid, gfx_busy;
    logic [95:0] gfx_pix;
    logic pf_rd_start, pf_rd_step;
    logic [3:0][15:0] pf_rd_q;
    logic [3:0] pf_used;

    rf_video_pf pf (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .ctrl0(ctrl0), .flip(flip_eff),
        .line_start(pf_go), .screen_y(bld_y),
        .extend(extend), .alt_tilemap(pf_alt),
        .colscroll(colscroll), .x_scale(x_scale), .y_scale(y_scale),
        .rowscroll(rowscroll), .mosaic_en(pf_mosaic), .x_sample(x_sample),
        .busy(pf_busy),
        .pf_addr(pf_addr), .pf_q(pf_q),
        .gfx_code(gfx_code), .gfx_row(gfx_row), .gfx_req(gfx_req),
        .gfx_pix(gfx_pix), .gfx_valid(gfx_valid), .gfx_busy(gfx_busy),
        .rd_start(pf_rd_start), .rd_step(pf_rd_step), .rd_q(pf_rd_q), .rd_used(pf_used)
    );

    rf_gfx_bus gfx (
        .clk_cpu(clk), .reset(reset),
        .code(gfx_code), .row(gfx_row), .req(gfx_req),
        .pix(gfx_pix), .valid(gfx_valid), .busy(gfx_busy),
        .clk_ram(clk_ram),
        .ch_lo_addr(ch1_addr), .ch_lo_dout(ch1_dout), .ch_lo_req(ch1_req), .ch_lo_ready(ch1_ready),
        .ch_hi_addr(ch2_addr), .ch_hi_dout(ch2_dout), .ch_hi_req(ch2_req), .ch_hi_ready(ch2_ready),
        .base_lo(tile_base_lo), .base_hi(tile_base_hi)
    );

    // ---- pivot / text layer ------------------------------------------------
    // Same start as the playfield builder (after the decoder), same line;
    // read by the mixer at smp_x out of the bank it is composing.
    logic        pv_busy, pv_opaque, pv_used;
    logic [15:0] pv_color;

    rf_video_pivot pivot (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .ctrl1(ctrl1), .flip(flip_eff),
        .line_start(pf_go), .screen_y(bld_y),
        .pivot_control(pivot_control), .mosaic_en(pivot_mosaic), .x_sample(x_sample),
        .busy(pv_busy),
        .text_addr(text_addr), .text_q(text_q),
        .char_addr(char_addr), .char_q(char_q),
        .pivot_addr(pivot_addr), .pivot_q(pivot_q),
        .rd_bank(mix_bank), .rd_x(smp_x),
        .rd_color(pv_color), .rd_opaque(pv_opaque), .rd_used(pv_used)
    );

    // ---- sprite engine ---------------------------------------------------
    // Prepass once per frame (frame_start swaps its double-banked buckets and
    // walks sprite RAM); the draw runs ahead of the mixer into its own ring
    // of line buffers, held back only by the mixer's line (mix_y); the mixer
    // samples it at smp_x for the line it is composing.
    logic        spr_prepass_busy, spr_line_busy;
    logic  [8:0] spr_lines_done;
    logic        spr_flipscreen;
    // the game's own bit once the prepass has read it; the port until then
    wire         flip_eff = spr_flipscreen;
    logic [15:0] spr_rec_peak, spr_rec_drop;
    logic [15:0] spr_fetch_max, spr_rows_line_max;
    logic [15:0] spr_fetch_bad;                     // fetch self-check, see rf_spr_gfx_bus
    /* verilator lint_off UNUSED */
    logic  [7:0] spr_unfinished;                    // DIAGNOSTIC (measured 0)
    /* verilator lint_on UNUSED */
    logic  [7:0] spr_defer;                         // DIAGNOSTIC
    logic [15:0] spr_wr_fold, spr_rd_fold;          // DIAGNOSTIC
    logic [15:0] spr_tear_cnt, spr_tear_frames;     // TEARING INSTRUMENT
    logic  [7:0] spr_bad_first, spr_bad_last;       // DIAGNOSTIC
    logic [15:0] spr_bad_count;                     // DIAGNOSTIC
    // peak-hold accumulators for the two sprite rows (see frame_end below)
    logic [15:0] h_spr_max, h_late, h_rec_max, h_drop;
    logic [15:0] h_fetch_max, h_rows_max;
    // ...held from the WARM frame on. The first frames after a reset have no
    // sprite buckets built yet, so the mixer legitimately starts lines the
    // draw has not reached and the late counter would latch a permanent FAIL
    // out of the boot (the bench shows exactly 254 such lines in its priming
    // frame). Eight frames is well past the first real prepass.
    logic  [3:0] warm;
    wire         held = (warm == 4'hF);
    wire  [15:0] sp_color;              // from the framebuffer, a frame later
    logic  [3:0] sp_used;
    wire   [8:0] smp_x;
    // sprite engine <-> framebuffer
    wire         spr_par, spr_fb_req, spr_fb_busy;
    wire  [15:0] spr_fb_miss;
    wire   [7:0] spr_fb_line;
    wire   [8:0] spr_fb_addr;
    wire  [15:0] spr_fb_q;

    rf_video_spr sprites (
        .clk(clk), .reset(reset), .clk_ram(clk_ram), .vis_mode(vis_mode),
        .spr_wr_stb(spr_wr_stb), .tear_cnt(spr_tear_cnt), .tear_frames(spr_tear_frames),
        .seq_rec01(dbg_seq_rec01), .seq_rec23(dbg_seq_rec23),
        .seq_nspr01(dbg_seq_nspr01), .seq_nspr23(dbg_seq_nspr23), .seq_ovr(dbg_seq_ovr),
        .seq_used01(dbg_seq_used01), .seq_used23(dbg_seq_used23),
        .frame_start(frame_start), .prepass_busy(spr_prepass_busy),
        .line_busy(spr_line_busy), .lines_done(spr_lines_done),
        .o_flipscreen(spr_flipscreen),
        .rec_peak(spr_rec_peak), .rec_drop(spr_rec_drop),
        .fetch_max(spr_fetch_max), .rows_line_max(spr_rows_line_max), .fetch_bad(spr_fetch_bad),
        .draw_unfinished(spr_unfinished), .row_cap(row_cap),
        .spr_addr(spr_addr), .spr_q(spr_q),
        .ch_a_lo_addr(spr_a_lo_addr), .ch_a_lo_dout(spr_a_lo_dout), .ch_a_lo_req(spr_a_lo_req), .ch_a_lo_ready(spr_a_lo_ready),
        .ch_a_hi_addr(spr_a_hi_addr), .ch_a_hi_dout(spr_a_hi_dout), .ch_a_hi_req(spr_a_hi_req), .ch_a_hi_ready(spr_a_hi_ready),
        .ch_b_lo_addr(spr_b_lo_addr), .ch_b_lo_dout(spr_b_lo_dout), .ch_b_lo_req(spr_b_lo_req), .ch_b_lo_ready(spr_b_lo_ready),
        .ch_b_hi_addr(spr_b_hi_addr), .ch_b_hi_dout(spr_b_hi_dout), .ch_b_hi_req(spr_b_hi_req), .ch_b_hi_ready(spr_b_hi_ready),
        .rd_line(mix_y), .rd_used(sp_used),
        .o_par(spr_par),
        .fb_req(spr_fb_req), .fb_line(spr_fb_line), .fb_busy(spr_fb_busy), .fb_used(),
        .fb_addr(spr_fb_addr), .fb_q(spr_fb_q),
        .gfx_base_lo(sgfx_base_lo), .gfx_base_hi(sgfx_base_hi)
    );

    // The sprite framebuffer: the draw's finished lines go out to DDR3 and
    // the mixer reads LAST frame's back. This is what takes the per-line
    // deadline off the draw entirely -- see rf_spr_fb.sv for the measurements
    // that forced it.
    // the pipe's DDR3 port, shared below between spr_fb (F) and the flip (V)
    logic  [7:0] f_burstcnt, v_burstcnt;
    logic [28:0] f_addr, v_addr;
    logic [63:0] f_din, v_din, f_dout, v_dout;
    logic  [7:0] f_be, v_be;
    logic        f_we, f_rd, f_busy, f_dout_ready;
    logic        v_we, v_rd, v_busy, v_dout_ready;
    rf_spr_fb spr_fb (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .par(spr_par),
        .wr_req(spr_fb_req), .wr_line(spr_fb_line), .wr_busy(spr_fb_busy),
        .lb_addr(spr_fb_addr), .lb_q(spr_fb_q),
        .rd_line(mix_y), .rd_x(smp_x), .rd_color(sp_color),
        .miss(spr_fb_miss),
        .wr_fold(spr_wr_fold), .rd_fold(spr_rd_fold), .defer_cnt(spr_defer),
        .short_cnt(dbg_short),
        .bad_first(spr_bad_first), .bad_last(spr_bad_last), .bad_count(spr_bad_count),
        .ddr_burstcnt(f_burstcnt), .ddr_addr(f_addr), .ddr_din(f_din),
        .ddr_be(f_be), .ddr_we(f_we), .ddr_rd(f_rd),
        .ddr_busy(f_busy), .ddr_dout(f_dout), .ddr_dout_ready(f_dout_ready)
    );

    // The pipe's DDR3 port is shared between the sprite framebuffer and the
    // output flip. Both read, so the returning beats have to be told apart
    // -- see rf_ddr_tag_mux.
    rf_ddr_tag_mux ddr_mux (
        .flush_cnt(dbg_flush),
        .clk(clk), .reset(reset),
        // inert unless the flip is actually on -- see the module header
        .enable(out_flip),
        .f_burstcnt(f_burstcnt), .f_addr(f_addr), .f_din(f_din), .f_be(f_be),
        .f_we(f_we), .f_rd(f_rd), .f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),
        .v_burstcnt(v_burstcnt), .v_addr(v_addr), .v_din(v_din), .v_be(v_be),
        .v_we(v_we), .v_rd(v_rd), .v_busy(v_busy), .v_dout(v_dout), .v_dout_ready(v_dout_ready),
        .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_din(ddr_din),
        .ddr_be(ddr_be), .ddr_we(ddr_we), .ddr_rd(ddr_rd),
        .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready)
    );

    // The output flip: last frame's raster, upside down, for the analog
    // output (see rf_out_flip.sv). It reads the line buffer the beam is not
    // using and fills the display buffer the beam reads instead.
    logic  [9:0] flip_lb_addr;
    logic        flip_db_we;
    logic  [8:0] flip_db_waddr;
    logic [47:0] flip_db_wdata;
    logic [15:0] flip_late, flip_wlate;
    assign dbg_flip = {flip_late, flip_wlate};
    // (rf_out_flip itself is instantiated with the line buffers below,
    // which it reads and writes)

    // ---- mixer -----------------------------------------------------------
    logic mix_busy, out_valid;
    logic [8:0] out_x;
    logic [23:0] out_rgb;
    wire         x_req;
    wire   [8:0] x_req_x;

    rf_video_mix mix (
        .clk(clk), .reset(reset),
        .line_start(mix_start), .busy(mix_busy),
        .clip_l(clip_l), .clip_r(clip_r), .blend(blend), .bg_palette(bg_palette),
        .pivot_mix(pivot_mix), .pivot_bsel(pivot_bsel),
        .sp_mix(sp_mix), .sp_bsel(sp_bsel),
        .pf_pal_add(pf_pal_add), .pf_mix(pf_mix),
        .pf_rd_start(pf_rd_start), .pf_rd_step(pf_rd_step), .pf_q(pf_rd_q), .pf_used(pf_used),
        .x_req(x_req), .x_req_x(x_req_x), .smp_x(smp_x),
        .sp_color(sp_color), .sp_used(sp_used),
        .pv_color(pv_color), .pv_opaque(pv_opaque), .pv_used(pv_used),
        .pal_addr(pal_addr), .pal_q(pal_q), .pal12(pal12),
        .out_valid(out_valid), .out_x(out_x), .out_rgb(out_rgb),
        .line_y(mix_y), .dbg_pix(dbg_mixpix)
    );

    // ---- output line buffer ----------------------------------------------
    // Two banks of 320 x 24 bits. The mixer writes bank (T+1)&1 during
    // raster line T; the beam reads bank T&1. Read one pixel ahead and latch
    // at div 7, the same alignment rf_selftest uses (proven on hardware).
    wire  [8:0] xn = hcnt + 9'd1 - H_START[8:0];
    wire [23:0] lb_q;

    // While the output flip is on, the beam reads the display buffer below
    // and this buffer's read port belongs to the flip's writer, which reads
    // line T back out of the bank the beam would have read, over rasters T
    // and T+1 (three banks: see mix_b3).
    rf_bram #(.WIDTH(24), .AW(10)) u_lbuf (
        .clk(clk),
        // Three banks only while the flip needs a line to survive two
        // rasters. With the flip off this is the original two-bank buffer,
        // addressed exactly as it was before rf_out_flip existed -- the
        // 2026-09-11 bisect says every build without this machinery renders
        // Darius Gaiden's Zone A palette correctly.
        .waddr(out_flip ? (lb_base(mix_b3) + 10'(out_x)) : {mix_bank, out_x}),
        .wdata(out_rgb), .wren(out_valid),
        .raddr(out_flip ? flip_lb_addr : {vcnt[0], xn}), .q(lb_q)
    );

    // The flip's display buffer: three banks of 160 two-pixel words (480 of
    // the 512 the three M10K hold), written by rf_out_flip two lines ahead,
    // read by the beam a word per two pixels from the bank it names.
    wire [47:0] db_q;
    logic [8:0] flip_db_rbase;
    rf_bram #(.WIDTH(48), .AW(9)) u_dbuf (
        .clk(clk),
        .waddr(flip_db_waddr), .wdata(flip_db_wdata), .wren(flip_db_we),
        .raddr(flip_db_rbase + 9'(xn[8:1])), .q(db_q)
    );

    rf_out_flip out_flipper (
        .clk(clk), .reset(reset), .enable(out_flip),
        .h0(h0), .div(div), .vcnt(vcnt), .vis_mode(vis_mode),
        .lb_base(lb_base(beam_b3)), .lb_addr(flip_lb_addr), .lb_q(lb_q),
        .db_we(flip_db_we), .db_waddr(flip_db_waddr), .db_wdata(flip_db_wdata),
        .db_rbase(flip_db_rbase),
        .ddr_burstcnt(v_burstcnt), .ddr_addr(v_addr), .ddr_din(v_din),
        .ddr_be(v_be), .ddr_we(v_we), .ddr_rd(v_rd),
        .ddr_busy(v_busy), .ddr_dout(v_dout), .ddr_dout_ready(v_dout_ready),
        .late_cnt(flip_late), .wlate_cnt(flip_wlate)
    );

    logic [23:0] rgb_q;
    always_ff @(posedge clk)
        if (div == 3'd7) rgb_q <= !out_flip ? lb_q : (xn[0] ? db_q[47:24] : db_q[23:0]);

    assign rgb = (hblank | vblank) ? 24'd0 : rgb_q;

    // ---- diagnostics -------------------------------------------------------
    // What the pipeline actually did last frame. Expected, from sim/pipe_tb
    // on frame 1800: dbg_lines 01000100 (256 mixer lines, 256 builds),
    // dbg_fetch 2A8C58F7 (10892 tile fetches, 22775 non-black pixels out),
    // dbg_max 000C0872 (longest fetch 12 clocks, longest build 2162),
    // dbg_nz with all three fields non-zero. A black screen with these at
    // zero is a pipeline that never started; with fetches at zero it is the
    // SDRAM channels; fetches but no non-zero tile data is the SDRAM
    // contents; tile data but zero playfield samples is the unpack; samples
    // but black pixels is the mixer or the palette port; non-black pixels
    // and still a black screen is the line buffer readout or the output mux.
    logic [15:0] n_mix, n_bld, n_fet, n_pnz, n_tnz, t_fet, t_fet_max, t_bld, t_bld_max;
    logic [15:0] t_spr, t_spr_max, n_spr_miss;
    logic  [7:0] pf_or, pal_or;
    logic        mix_busy_d, pf_busy_d, gfx_busy_d, spr_busy_d;
    wire         frame_end = h0 && (div == 3'd0) && (vcnt == 9'd0);

    always_ff @(posedge clk) begin
        mix_busy_d <= mix_busy;
        pf_busy_d  <= pf_busy;
        gfx_busy_d <= gfx_busy;
        spr_busy_d <= spr_line_busy;
        if (reset) begin
            n_mix <= 0; n_bld <= 0; n_fet <= 0; n_pnz <= 0; n_tnz <= 0;
            pf_or <= 0; pal_or <= 0;
            t_fet <= 0; t_fet_max <= 0; t_bld <= 0; t_bld_max <= 0;
            t_spr <= 0; t_spr_max <= 0; n_spr_miss <= 0;
            h_spr_max <= 0; h_late <= 0; h_rec_max <= 0; h_drop <= 0; warm <= 0;
            h_fetch_max <= 0; h_rows_max <= 0; dbg_sfetch <= 0;
            dbg_lines <= 0; dbg_fetch <= 0; dbg_max <= 0; dbg_nz <= 0; dbg_spr <= 0; dbg_rec <= 0;
        end else begin
            if (mix_busy_d && !mix_busy) n_mix <= n_mix + 16'd1;
            if (pf_busy_d  && !pf_busy)  n_bld <= n_bld + 16'd1;
            if (gfx_valid)               n_fet <= n_fet + 16'd1;
            if (gfx_valid && gfx_pix != 96'd0 && n_tnz != 16'hFFFF) n_tnz <= n_tnz + 16'd1;
            if (out_valid && out_rgb != 24'd0 && n_pnz != 16'hFFFF) n_pnz <= n_pnz + 16'd1;
            pal_or <= pal_or | pal_q[7:0];
            pf_or  <= pf_or | pf_rd_q[0][7:0] | pf_rd_q[1][7:0] | pf_rd_q[2][7:0] | pf_rd_q[3][7:0];

            t_fet <= gfx_busy ? t_fet + 16'd1 : 16'd0;
            if (gfx_busy_d && !gfx_busy && t_fet > t_fet_max) t_fet_max <= t_fet;
            t_bld <= pf_busy ? t_bld + 16'd1 : 16'd0;
            if (pf_busy_d && !pf_busy && t_bld > t_bld_max) t_bld_max <= t_bld;

            // The sprite draw falling behind is otherwise SILENT: the mixer
            // composes a line whose sprites are not all there yet. Count the
            // lines the mixer started before the draw had finished them, and
            // the longest single line draw.
            t_spr <= spr_line_busy ? t_spr + 16'd1 : 16'd0;
            if (spr_busy_d && !spr_line_busy && t_spr > t_spr_max) t_spr_max <= t_spr;
            if (mix_start && spr_lines_done <= {1'b0, mix_y} && n_spr_miss != 16'hFFFF)
                n_spr_miss <= n_spr_miss + 16'd1;

            if (frame_end) begin
                dbg_lines <= {n_mix, n_bld};
                dbg_fetch <= {n_fet, n_pnz};
                dbg_max   <= {t_fet_max, t_bld_max};
                dbg_nz    <= {n_tnz, pf_or, pal_or};
                // The two sprite rows are PEAK HOLD, not last-frame: the
                // events they exist to catch (a boss transition overflowing
                // the record store, a dense line the mixer starts before the
                // draw finished it) last a frame or two, and the page is read
                // by eye or over a UART that samples it once a second -- a
                // last-frame value misses them. Over a five-minute attract
                // capture (632 passes) drops appeared in ONE pass and late
                // lines in two, which is exactly why these are held.
                if (!held) warm <= warm + 4'd1;
                if (held && spr_fetch_max     > h_fetch_max) h_fetch_max <= spr_fetch_max;
                if (held && spr_rows_line_max > h_rows_max)  h_rows_max  <= spr_rows_line_max;
                // DIAGNOSTIC BUILD: the top byte carries draw_unfinished, so
                // the longest-fetch field is clamped to 8 bits here. The
                // board has been reading 0x54 (84) for it, a long way from
                // saturating; if it ever reads FF, read it as ">= 255" and
                // restore the full field. Everything else is unchanged.
                dbg_sfetch <= held
                    ? {sat8(spr_fetch_bad),   // was spr_defer (measured 0, theory dead)
                       sat8((spr_fetch_max > h_fetch_max) ? spr_fetch_max : h_fetch_max),
                       (spr_rows_line_max > h_rows_max)  ? spr_rows_line_max : h_rows_max}
                    : {sat8(spr_fetch_bad), sat8(spr_fetch_max), spr_rows_line_max};
                if (held && spr_rec_peak > h_rec_max) h_rec_max <= spr_rec_peak;
                if (held && t_spr_max    > h_spr_max) h_spr_max <= t_spr_max;
                if (held) begin
                    h_drop <= (16'hFFFF - h_drop < spr_rec_drop) ? 16'hFFFF : h_drop + spr_rec_drop;
                    h_late <= (16'hFFFF - h_late < spr_fb_miss)  ? 16'hFFFF : h_late + spr_fb_miss;
                end
                // The low half was "lines the mixer started before the draw
                // had finished them". The draw has no per-line deadline now,
                // so that count is structurally zero and would say nothing;
                // what CAN still go wrong is the framebuffer not delivering a
                // line in time, which is the same question about the new
                // mechanism. Same row, same meaning.
                dbg_spr <= held ? {(t_spr_max > h_spr_max) ? t_spr_max : h_spr_max,
                                   (16'hFFFF - h_late < spr_fb_miss) ? 16'hFFFF : h_late + spr_fb_miss}
                                : {t_spr_max, 16'd0};
                dbg_rec <= held ? {(spr_rec_peak > h_rec_max) ? spr_rec_peak : h_rec_max,
                                   (16'hFFFF - h_drop < spr_rec_drop) ? 16'hFFFF : h_drop + spr_rec_drop}
                                : {spr_rec_peak, 16'd0};
                n_mix <= 0; n_bld <= 0; n_fet <= 0; n_pnz <= 0; n_tnz <= 0;
                pf_or <= 0; pal_or <= 0;
                t_fet_max <= 0; t_bld_max <= 0;
                t_spr_max <= 0; n_spr_miss <= 0;
            end
        end
    end

endmodule
