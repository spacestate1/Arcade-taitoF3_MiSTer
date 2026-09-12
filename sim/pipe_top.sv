// Bench wrapper: rf_video_pipe with the sprite gfx planes behind
// rf_spr_ch_share, exactly as Rayforce.sv wires them, so the arbiter is
// covered by the pipe regression instead of meeting hardware untested.
//
// TWO shared channels, one per fetch bus: bus A's two planes on sps_a and
// bus B's two planes on sps_b. A sharer serialises the planes behind it --
// it holds one burst outstanding -- so with all four planes on one channel
// the four bursts a record-pair needs are strictly one after another, and
// the line's draw time is (bursts x round trip) with nothing overlapped.
// Splitting the buses across two channels lets the two records overlap and
// halves that, which is what the board needs (see "The sprite fetch path" in
// HANDOFF.md). Ray Force's ch4 and ch7 on the real controller.
module pipe_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        clk_ram,

    input  logic  [2:0] div,
    input  logic  [8:0] hcnt,
    input  logic  [8:0] vcnt,
    input  logic        hblank,
    input  logic        vblank,
    input  logic        rate_60,

    input  logic [7:0][15:0] ctrl0,
    input  logic [7:0][15:0] ctrl1,
    input  logic        flip,

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

    output logic [26:1] ch1_addr,
    input  logic [63:0] ch1_dout,
    output logic        ch1_req,
    input  logic        ch1_ready,
    output logic [26:1] ch2_addr,
    input  logic [63:0] ch2_dout,
    output logic        ch2_req,
    input  logic        ch2_ready,

    output logic [14:0] spr_addr,
    input  logic [15:0] spr_q,

    // the two shared sprite gfx channels (ch4 and ch7 on the real board)
    output logic [26:1] sps_addr,
    input  logic [63:0] sps_dout,
    output logic        sps_req,
    input  logic        sps_ready,
    output logic [26:1] sps_b_addr,
    input  logic [63:0] sps_b_dout,
    output logic        sps_b_req,
    input  logic        sps_b_ready,

    output logic [23:0] rgb,

    output logic [31:0] dbg_lines,
    output logic [31:0] dbg_fetch,
    output logic [31:0] dbg_max,
    output logic [31:0] dbg_nz,
    // the sprite framebuffer's DDR3 port, modelled in pipe_tb.cpp
    output logic  [7:0] ddr_burstcnt,
    output logic [28:0] ddr_addr,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    output logic        ddr_we,
    output logic        ddr_rd,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,

    output logic [31:0] dbg_sfetch,
    output logic [31:0] dbg_sprpix,
    output logic [31:0] dbg_mixpix,
    input  logic  [1:0] row_cap,
    input  logic        pal12,
    output logic [31:0] dbg_spr,
    output logic [31:0] dbg_rec,
    input  logic  [1:0] vis_mode,
    // the output flip (rf_out_flip): the raw output upside down, a frame late
    input  logic        out_flip,
    output logic [31:0] dbg_flip,
    output logic [15:0] dbg_short,     // rf_spr_fb: reads that under-delivered
    // f3_config_table extend; the bench's games are all extend=1, so the
    // testbench leaves this at 1 unless it is driving a 32x32 set
    input  logic        extend
);

    logic [26:1] a_lo_addr, a_hi_addr, b_lo_addr, b_hi_addr;
    logic [63:0] a_lo_dout, a_hi_dout, b_lo_dout, b_hi_dout;
    logic        a_lo_req, a_lo_ready, a_hi_req, a_hi_ready;
    logic        b_lo_req, b_lo_ready, b_hi_req, b_hi_ready;

    rf_video_pipe pipe (
        .spr_wr_stb(1'b0),   // no CPU in the bench: sprite RAM is a static
                             // snapshot, which is exactly why it cannot see the tear
        .dbg_tear(),
        .clk(clk), .reset(reset), .clk_ram(clk_ram),
        .div(div), .hcnt(hcnt), .vcnt(vcnt),
        .hblank(hblank), .vblank(vblank), .rate_60(rate_60),
        .ctrl0(ctrl0), .ctrl1(ctrl1), .flip(flip), .vis_mode(vis_mode),
        .extend(extend),
        .line_addr(line_addr), .line_q(line_q),
        .pf_addr(pf_addr),     .pf_q(pf_q),
        .pal_addr(pal_addr),   .pal_q(pal_q), .pal12(pal12),
        // SDRAM map profile 0 -- the layout every dumped reference used
        .tile_base_lo(26'h440000), .tile_base_hi(26'h640000),
        .sgfx_base_lo(26'h140000), .sgfx_base_hi(26'h340000),
        .text_addr(text_addr), .text_q(text_q),
        .char_addr(char_addr), .char_q(char_q),
        .pivot_addr(pivot_addr), .pivot_q(pivot_q),
        .ch1_addr(ch1_addr), .ch1_dout(ch1_dout), .ch1_req(ch1_req), .ch1_ready(ch1_ready),
        .ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_req(ch2_req), .ch2_ready(ch2_ready),
        .spr_addr(spr_addr), .spr_q(spr_q),
        .spr_a_lo_addr(a_lo_addr), .spr_a_lo_dout(a_lo_dout), .spr_a_lo_req(a_lo_req), .spr_a_lo_ready(a_lo_ready),
        .spr_a_hi_addr(a_hi_addr), .spr_a_hi_dout(a_hi_dout), .spr_a_hi_req(a_hi_req), .spr_a_hi_ready(a_hi_ready),
        .spr_b_lo_addr(b_lo_addr), .spr_b_lo_dout(b_lo_dout), .spr_b_lo_req(b_lo_req), .spr_b_lo_ready(b_lo_ready),
        .spr_b_hi_addr(b_hi_addr), .spr_b_hi_dout(b_hi_dout), .spr_b_hi_req(b_hi_req), .spr_b_hi_ready(b_hi_ready),
        .rgb(rgb),
        .dbg_lines(dbg_lines), .dbg_fetch(dbg_fetch),
        .dbg_max(dbg_max), .dbg_nz(dbg_nz), .dbg_spr(dbg_spr), .dbg_rec(dbg_rec),
        .dbg_sfetch(dbg_sfetch), .dbg_sprpix(dbg_sprpix), .dbg_mixpix(dbg_mixpix), .row_cap(row_cap),
        .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_din(ddr_din),
        .ddr_be(ddr_be), .ddr_we(ddr_we), .ddr_rd(ddr_rd),
        .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
        .out_flip(out_flip), .dbg_flip(dbg_flip), .dbg_short(dbg_short)
    );

    // Bus A's planes on channel 1, bus B's on channel 2. The sharer's b_*
    // ports are tied off: two ports each is all that is wanted, and an
    // unused port with its request low never wins the arbiter.
    rf_spr_ch_share share_a (
        .clk_ram(clk_ram),
        .a_lo_addr(a_lo_addr), .a_lo_dout(a_lo_dout), .a_lo_req(a_lo_req), .a_lo_ready(a_lo_ready),
        .a_hi_addr(a_hi_addr), .a_hi_dout(a_hi_dout), .a_hi_req(a_hi_req), .a_hi_ready(a_hi_ready),
        .b_lo_addr(26'd0), .b_lo_dout(), .b_lo_req(1'b0), .b_lo_ready(),
        .b_hi_addr(26'd0), .b_hi_dout(), .b_hi_req(1'b0), .b_hi_ready(),
        .ch_addr(sps_addr), .ch_dout(sps_dout),
        .ch_req(sps_req),   .ch_ready(sps_ready)
    );

    rf_spr_ch_share share_b (
        .clk_ram(clk_ram),
        .a_lo_addr(b_lo_addr), .a_lo_dout(b_lo_dout), .a_lo_req(b_lo_req), .a_lo_ready(b_lo_ready),
        .a_hi_addr(b_hi_addr), .a_hi_dout(b_hi_dout), .a_hi_req(b_hi_req), .a_hi_ready(b_hi_ready),
        .b_lo_addr(26'd0), .b_lo_dout(), .b_lo_req(1'b0), .b_lo_ready(),
        .b_hi_addr(26'd0), .b_hi_dout(), .b_hi_req(1'b0), .b_hi_ready(),
        .ch_addr(sps_b_addr), .ch_dout(sps_b_dout),
        .ch_req(sps_b_req),   .ch_ready(sps_b_ready)
    );

endmodule
