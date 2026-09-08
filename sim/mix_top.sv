// Bench wrapper: line decoder -> playfield builder -> tile fetch -> mixer.
// The wiring Rayforce.sv will use, minus the raster-driven sequencing: the
// bench decodes and builds a line, then starts the mixer on it.
module mix_top (
    input  logic        pal12,
input  logic        clk,
    input  logic        reset,

    input  logic        frame_start,
    input  logic [7:0][15:0] ctrl0,
    input  logic        flip,
    input  logic        extend,

    input  logic        line_start,          // decode + build one line
    input  logic  [7:0] screen_y,
    input  logic  [7:0] lr_y,
    output logic        busy,

    input  logic        mix_start,           // mix the line just built
    output logic        mix_busy,

    output logic [14:0] lr_addr,
    input  logic [15:0] lr_q,
    output logic [13:0] pf_addr,
    input  logic [15:0] pf_q,
    output logic [13:0] pal_addr,
    input  logic [15:0] pal_q,

    input  logic        clk_ram,
    output logic [26:1] ch_lo_addr,
    input  logic [63:0] ch_lo_dout,
    output logic        ch_lo_req,
    input  logic        ch_lo_ready,
    output logic [26:1] ch_hi_addr,
    input  logic [63:0] ch_hi_dout,
    output logic        ch_hi_req,
    input  logic        ch_hi_ready,

    // sprite / pivot samples for smp_x (bench supplies, zero latency)
    output logic  [8:0] smp_x,
    input  logic [15:0] sp_color,
    input  logic  [3:0] sp_used,
    input  logic [15:0] pv_color,
    input  logic        pv_opaque,
    input  logic        pv_used,

    output logic        out_valid,
    output logic  [8:0] out_x,
    output logic [23:0] out_rgb
);
    logic line_busy, pf_busy;
    logic [3:0][8:0]  colscroll, x_scale, y_scale, clip_l, clip_r;
    logic [3:0][19:0] rowscroll;
    logic [3:0]       pf_mosaic, sp_bsel, pf_alt;
    logic [4:0]       x_sample;
    logic [3:0][3:0]  blend;
    logic [7:0]       fx_6400, pivot_control;
    logic [15:0]      bg_palette, pivot_enable, pivot_mix;
    logic             pivot_bsel, pivot_mosaic, sp_mosaic;
    logic [3:0][15:0] sp_mix, pf_pal_add, pf_mix;

    rf_video_line line (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .line_start(line_start), .y(lr_y),
        .extend(extend), .busy(line_busy),
        .lr_addr(lr_addr), .lr_q(lr_q),
        .clip_l(clip_l), .clip_r(clip_r), .blend(blend), .x_sample(x_sample),
        .fx_6400(fx_6400), .bg_palette(bg_palette),
        .pivot_control(pivot_control), .pivot_bsel(pivot_bsel),
        .pivot_enable(pivot_enable), .pivot_mix(pivot_mix), .pivot_mosaic(pivot_mosaic),
        .sp_mix(sp_mix), .sp_bsel(sp_bsel), .sp_mosaic(sp_mosaic),
        .pf_colscroll(colscroll), .pf_alt_tilemap(pf_alt),
        .pf_x_scale(x_scale), .pf_y_scale(y_scale), .pf_pal_add(pf_pal_add),
        .pf_rowscroll(rowscroll), .pf_mix(pf_mix), .pf_mosaic(pf_mosaic)
    );

    logic line_busy_d, pf_go;
    always_ff @(posedge clk) begin
        line_busy_d <= line_busy;
        pf_go <= line_busy_d & ~line_busy;
    end
    assign busy = line_busy | line_busy_d | pf_go | pf_busy;

    logic [13:0] gfx_code; logic [3:0] gfx_row; logic gfx_req, gfx_valid, gfx_busy;
    logic [95:0] gfx_pix;
    logic pf_rd_start, pf_rd_step, x_req;
    logic [8:0] x_req_x;
    logic [3:0][15:0] pf_rd_q;
    logic [3:0] pf_used;

    rf_video_pf pf (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .ctrl0(ctrl0), .flip(flip),
        .line_start(pf_go), .screen_y(screen_y),
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
        .ch_lo_addr(ch_lo_addr), .ch_lo_dout(ch_lo_dout), .ch_lo_req(ch_lo_req), .ch_lo_ready(ch_lo_ready),
        .ch_hi_addr(ch_hi_addr), .ch_hi_dout(ch_hi_dout), .ch_hi_req(ch_hi_req), .ch_hi_ready(ch_hi_ready),
        // SDRAM map profile 0, the 18.5 MB map these references were made with
        .base_lo(26'h440000), .base_hi(26'h640000)
    );

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
        .out_valid(out_valid), .out_x(out_x), .out_rgb(out_rgb)
    );
endmodule
