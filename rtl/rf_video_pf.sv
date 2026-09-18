//============================================================================
//  Playfield line builder -- four scrolling tilemaps, one scanline at a time.
//
//  Port of PlayfieldInf / build_playfields / x_index / y_index from
//  tools/f3_render.py, which reproduces MAME's frames pixel-exact and is
//  the spec. sim/pf_tb.cpp diffs this module's output against that model
//  for every pixel of every line of a dumped frame (make -C sim pf).
//
//  Shape. Per line, per playfield:
//    1. y: gy = ((fx_y >> 8) + colscroll) & 0x1ff, fx_y being a 24.8
//       accumulator that steps by y_scale per line (from line 1 -- the
//       model does not add after line 0, and neither does this).
//    2. MAME's row-usage skip: a tilemap row whose 64 tile codes are all 0
//       draws NOTHING, even though tile 0 in this ROM is opaque. That is a
//       visible behaviour, not an optimisation, so it is reproduced with a
//       64-word scan of the row's code words.
//    3. x: the source span for the line is contiguous (x_scale > 0), at most
//       320 source pixels wide, so at most 22 tile rows are fetched from
//       SDRAM (rf_gfx_bus) and unpacked into a 512-entry SOURCE line buffer
//       indexed by gx[8:0] -- a span under 512 cannot alias, so no base
//       subtraction is needed.
//    4. The read side maps screen x -> gx with an accumulator that steps by
//       x_scale (the model's x_index, without the multiply), applying the
//       mosaic sample-and-hold when enabled, and reads the four buffers in
//       parallel so the mixer sees all four playfields for a pixel at once.
//
//  Flipscreen -- which Ray Force runs with permanently -- mirrors the whole
//  tilemap in both axes (MAME set_flip_all), THEN each tile's own flip bits
//  apply. Source pixel gx therefore lands on tile 63 - (gx >> 4), and the
//  pixel column inside the tile is j ^ 15 ^ (flipx ? 15 : 0).
//
//  The tile fetch overlaps the unpack: the next tile's SDRAM request goes
//  out as soon as this tile's row has landed, while the 16-cycle writer is
//  still draining it, and a row that lands before the writer is free waits
//  in a one-entry pending slot. The first version gated the fetch on the
//  writer being idle, so every tile cost attribute read + fetch + unpack in
//  series -- 3107 of the 3456 clocks on hardware, the tightest number on
//  the self-test page, and one the sprite engine's fetches (lowest priority
//  on the same SDRAM, but they still occupy it) would have pushed over.
//
//  Buffers are double-banked: a line is built into one bank while the mixer
//  reads the previous line out of the other. The bank swap is at rd_start,
//  which also captures the per-line read parameters, because by then the
//  line decoder has moved on to the NEXT line's values.
//
//  Limits, stated rather than hidden: extend mode only (1024x512, the mode
//  gunlock uses; the model's non-extend path is unverified too), and a
//  line_start while busy is ignored.
//============================================================================

module rf_video_pf
(
    input  logic        clk,
    input  logic        reset,

    // ---- frame ---------------------------------------------------------
    input  logic        frame_start,   // latch scroll from ctrl0
    input  logic [7:0][15:0] ctrl0,    // 0x660000-0F: x scroll 0-3, y scroll 4-7
    input  logic        flip,          // flipscreen (from the sprite command)

    // ---- line build ----------------------------------------------------
    input  logic        line_start,
    input  logic  [7:0] screen_y,      // 0-255, for the "no y step after line 0" rule
    // The f3_config_table "extend" bit. It changes the tilemap geometry, so
    // it changes this module's addressing, not just a size somewhere:
    //   1: four  64x32 maps, word address {pf[1:0], ty[4:0], tx[5:0], sel}
    //   0: eight 32x32 maps, word address {map[2:0], ty[4:0], tx[4:0], sel}
    // and in the 32-wide case a playfield may draw from map pf+2 when line
    // RAM asked for it (alt_tilemap), which is what the extra four maps are
    // for. MAME: "[.ttt yyyy yxxx xxa|h] non-extend / [.tty yyyy xxxx xxa|h]
    // extend" in taito_f3_v.cpp pf_ram_w().
    input  logic        extend,
    input  logic [3:0]  alt_tilemap,   // per playfield, extend=0 only
    input  logic [3:0][8:0]  colscroll,
    input  logic [3:0][8:0]  x_scale,  // 1..256
    input  logic [3:0][8:0]  y_scale,
    input  logic [3:0][19:0] rowscroll,// signed 24.8 (see rf_video_line)
    input  logic [3:0]       mosaic_en,
    input  logic       [4:0] x_sample, // 1..16
    output logic        busy,

    // playfield RAM read port (B side of the CPU's playfield BRAM)
    output logic [13:0] pf_addr,
    input  logic [15:0] pf_q,

    // tile fetch (rf_gfx_bus)
    output logic [15:0] gfx_code,
    output logic  [3:0] gfx_row,
    output logic        gfx_req,
    input  logic [95:0] gfx_pix,
    input  logic        gfx_valid,
    input  logic        gfx_busy,

    // ---- line read (mixer side) -----------------------------------------
    input  logic        rd_start,      // swap banks, x = 0
    input  logic        rd_step,       // x = x + 1
    // {bsel, pal_code[8:0], pen[5:0]} per playfield, valid 2 clocks after
    // rd_start / rd_step. color = {pal_code, 4'b0} | pen; opaque = pen != 0.
    output logic [3:0][15:0] rd_q,
    output logic [3:0]       rd_used   // row usage for the line being read
);

    localparam int H_START = 46;

    // ---- frame scroll registers (get_pf_scroll) --------------------------
    // x: 10.6 with inverted fraction bits -> 24.8; y: 9.7 -> 24.8.
    // The two flipscreen x adjustments (320<<6 and (512+192)<<6) sum to
    // exactly 65536 and cancel in s16, so only y changes under flip.
    logic signed [23:0] reg_sx [0:3];
    logic signed [23:0] fx_y   [0:3];

    function automatic logic signed [23:0] calc_sx(input logic [15:0] raw, input int pf);
        logic [15:0] r16;
        logic signed [23:0] v;
        r16 = raw + 16'((40 - 4 * pf) << 6);
        v   = 24'(signed'({r16[15], r16[15], r16[15], r16[15], r16[15], r16[15], r16[15], r16[15], r16})) <<< 2;
        v   = v ^ 24'h0000FC;
        calc_sx = v - 24'sd11776;                       // H_START << 8
    endfunction

    function automatic logic signed [23:0] calc_sy(input logic [15:0] raw, input logic fl);
        logic [15:0] r16;
        logic signed [23:0] v;
        r16 = raw + 16'd128;
        if (fl) r16 = -r16;
        v   = 24'(signed'({r16[15], r16[15], r16[15], r16[15], r16[15], r16[15], r16[15], r16[15], r16})) <<< 1;
        calc_sy = fl ? -v : v;
    endfunction

    // ---- build-side state ----------------------------------------------
    typedef enum logic [3:0] {
        B_IDLE, B_SETUP, B_SCAN, B_TILE_A, B_TILE_C, B_TILE_W1, B_TILE_W2,
        B_FETCH, B_WAIT, B_NEXT_TILE, B_NEXT_PF, B_DONE
    } bst_t;
    bst_t bst;

    logic  [1:0] bpf;                  // playfield being built
    logic        wb;                   // bank being written
    logic  [7:0] b_sy;

    // per-pf values for the line under construction
    logic signed [23:0] b_fx_x  [0:3];
    logic        [8:0]  b_xs    [0:3];
    logic               b_mos   [0:3];
    logic               b_used  [0:3];
    logic        [4:0]  b_xsamp;

    // current pf working set
    logic        [8:0]  gy;
    logic        [8:0]  uy;            // unflipped tilemap y
    logic        [4:0]  ty;
    logic        [3:0]  py;
    logic        [9:0]  gx_start, gx_end;
    logic        [5:0]  n_tiles, k;
    logic        [6:0]  scan_i;
    logic               row_used;
    logic        [9:0]  gxt;           // 16-aligned source x of tile k
    logic        [5:0]  tx;
    logic       [15:0]  attr;

    wire signed [23:0] fx_x_cur = b_fx_x[bpf];
    wire signed [23:0] rs_ext   = {{4{rowscroll[bpf][19]}}, rowscroll[bpf]};
    wire signed [23:0] xs_m1    = 24'(signed'({15'd0, x_scale[bpf]})) - 24'sd256;
    // 10 * (x_scale - 256) = 8x + 2x
    wire signed [23:0] zoom_adj = (xs_m1 <<< 3) + (xs_m1 <<< 1);

    // x_index at screen x = H_START and at H_START + 319
    wire signed [23:0] fx_line  = reg_sx[bpf] + rs_ext + zoom_adj;
    wire signed [23:0] fx_last  = fx_line + 24'(signed'({6'd0, x_scale[bpf]})) * 24'sd319;
    wire [9:0] gxs = 10'((fx_line >>> 8) + 24'sd46);
    wire [9:0] gxe = 10'((fx_last >>> 8) + 24'sd46);

    wire signed [23:0] fy_shift = fx_y[bpf] >>> 8;
    wire [8:0] gy_c = 9'(fy_shift + 24'(signed'({15'd0, colscroll[bpf]})));

    // pf_ram word address of tile (ty, tx): {pf, ty, tx, code?}
    // extend=0 narrows tx to 5 bits and widens the map select to 3, so the
    // 14-bit address stays the same width either way.
    wire [2:0] tmap3 = extend ? {1'b0, bpf}
                              : (3'({1'b0, bpf}) + (alt_tilemap[bpf] ? 3'd2 : 3'd0));
    // last column to probe, and the count that ends the scan (two extra
    // steps for the RAM's registered q, as in extend mode)
    wire [6:0] scan_last = extend ? 7'd63 : 7'd31;
    wire [6:0] scan_end  = extend ? 7'd65 : 7'd33;
    wire [13:0] a_attr = extend ? {bpf, ty, tx, 1'b0} : {tmap3, ty, tx[4:0], 1'b0};
    wire [13:0] a_code = extend ? {bpf, ty, tx, 1'b1} : {tmap3, ty, tx[4:0], 1'b1};

    // ---- unpack writer (overlaps the next tile's fetch) ----------------
    logic        wr_active;
    logic  [3:0] wr_j;
    logic  [9:0] wr_gxt;
    logic [95:0] wr_pix;
    logic  [8:0] wr_pal;
    logic        wr_bsel, wr_flipx;
    logic  [5:0] wr_mask;
    logic        wr_flip;
    logic  [1:0] wr_pf;                // target playfield, LATCHED: the FSM
                                       // moves on to the next playfield while
                                       // this writer is still draining

    // a fetched row waiting for the writer (at most one: the next fetch is
    // not issued while this is occupied)
    logic        pend_v;
    logic  [9:0] pend_gxt;
    logic [95:0] pend_pix;
    logic  [8:0] pend_pal;
    logic        pend_bsel, pend_flipx, pend_flip;
    logic  [5:0] pend_mask;
    logic  [1:0] pend_pf;

    wire  [3:0] wr_col = wr_j ^ {4{wr_flip}} ^ {4{wr_flipx}};
    wire  [5:0] wr_pen = wr_pix[wr_col * 6 +: 6] & wr_mask;
    wire  [9:0] wr_addr = {wb, 9'((wr_gxt + {6'd0, wr_j}) & 10'h1FF)};
    wire [15:0] wr_data = {wr_bsel, wr_pal, wr_pen};
    logic [3:0] wr_en;

    always_comb begin
        wr_en = 4'b0000;
        if (wr_active) wr_en[wr_pf] = 1'b1;
    end

    wire row_lands = (bst == B_WAIT) && gfx_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            wr_active <= 1'b0;
            pend_v    <= 1'b0;
        end else begin
            if (wr_active) begin
                wr_j <= wr_j + 4'd1;
                if (wr_j == 4'd15) begin
                    if (pend_v) begin
                        // straight on to the waiting row
                        wr_j      <= 4'd0;
                        wr_gxt    <= pend_gxt;
                        wr_pix    <= pend_pix;
                        wr_pal    <= pend_pal;
                        wr_bsel   <= pend_bsel;
                        wr_flipx  <= pend_flipx;
                        wr_mask   <= pend_mask;
                        wr_flip   <= pend_flip;
                        wr_pf     <= pend_pf;
                        pend_v    <= 1'b0;
                    end else begin
                        wr_active <= 1'b0;
                    end
                end
            end else if (pend_v) begin
                // a row landed on the writer's last cycle and waited one
                wr_active <= 1'b1;
                wr_j      <= 4'd0;
                wr_gxt    <= pend_gxt;
                wr_pix    <= pend_pix;
                wr_pal    <= pend_pal;
                wr_bsel   <= pend_bsel;
                wr_flipx  <= pend_flipx;
                wr_mask   <= pend_mask;
                wr_flip   <= pend_flip;
                wr_pf     <= pend_pf;
                pend_v    <= 1'b0;
            end else if (row_lands) begin
                // writer idle: start directly, as before
                wr_active <= 1'b1;
                wr_j      <= 4'd0;
                wr_gxt    <= gxt;
                wr_pix    <= gfx_pix;
                wr_pal    <= attr[8:0];
                wr_bsel   <= attr[9];
                wr_flipx  <= attr[14];
                wr_mask   <= {attr[11:10] & ~attr[1:0], 4'hF};
                wr_flip   <= flip;
                wr_pf     <= bpf;
            end

            // a row landing while the writer is busy waits here. Written
            // last so that, on the one cycle the slot is both consumed and
            // refilled, the refill wins (the consumer read the old row).
            if (row_lands && (wr_active || pend_v)) begin
                pend_v     <= 1'b1;
                pend_gxt   <= gxt;
                pend_pix   <= gfx_pix;
                pend_pal   <= attr[8:0];
                pend_bsel  <= attr[9];
                pend_flipx <= attr[14];
                pend_mask  <= {attr[11:10] & ~attr[1:0], 4'hF};
                pend_flip  <= flip;
                pend_pf    <= bpf;
            end
        end
    end

    // ---- completed-line handoff and the read side ----------------------
    logic               done_bank;
    logic signed [23:0] d_fx_x [0:3];
    logic        [8:0]  d_xs   [0:3];
    logic               d_mos  [0:3];
    logic               d_used [0:3];
    logic        [4:0]  d_xsamp;

    logic               r_bank;
    logic signed [23:0] acc    [0:3];
    logic signed [23:0] held   [0:3];
    logic        [8:0]  r_xs   [0:3];
    logic               r_mos  [0:3];
    logic        [4:0]  r_xsamp;
    logic        [8:0]  r_x;
    logic        [3:0]  mcnt;

    // 114 % sample: the mosaic phase at the left edge of the screen
    function automatic logic [3:0] mos_phase0(input logic [4:0] s);
        case (s)
            5'd4: mos_phase0 = 4'd2;  5'd5: mos_phase0 = 4'd4;
            5'd7: mos_phase0 = 4'd2;  5'd8: mos_phase0 = 4'd2;
            5'd9: mos_phase0 = 4'd6;  5'd10: mos_phase0 = 4'd4;
            5'd11: mos_phase0 = 4'd4; 5'd12: mos_phase0 = 4'd6;
            5'd13: mos_phase0 = 4'd10; 5'd14: mos_phase0 = 4'd2;
            5'd15: mos_phase0 = 4'd9; 5'd16: mos_phase0 = 4'd2;
            default: mos_phase0 = 4'd0;
        endcase
    endfunction

    // the mosaic counter resets 2 px from the right edge (x_count wraps at 432)
    wire [3:0] mcnt_inc  = ({1'b0, mcnt} + 5'd1 == r_xsamp) ? 4'd0 : mcnt + 4'd1;
    wire [3:0] mcnt_next = (r_x == 9'd317) ? 4'd0 : mcnt_inc;

    always_ff @(posedge clk) begin
        if (rd_start) begin
            r_bank  <= done_bank;
            r_xsamp <= d_xsamp;
            r_x     <= 9'd0;
            mcnt    <= mos_phase0(d_xsamp);
            for (int i = 0; i < 4; i = i + 1) begin
                acc[i]   <= d_fx_x[i];
                held[i]  <= d_fx_x[i] - 24'(signed'({15'd0, d_xs[i]})) * 24'(signed'({20'd0, mos_phase0(d_xsamp)}));
                r_xs[i]  <= d_xs[i];
                r_mos[i] <= d_mos[i];
                rd_used[i] <= d_used[i];
            end
        end else if (rd_step) begin
            r_x  <= r_x + 9'd1;
            mcnt <= mcnt_next;
            for (int i = 0; i < 4; i = i + 1) begin
                acc[i] <= acc[i] + 24'(signed'({15'd0, r_xs[i]}));
                if (mcnt_next == 4'd0)
                    held[i] <= acc[i] + 24'(signed'({15'd0, r_xs[i]}));
            end
        end
    end

    // read addresses: gx = ((acc >> 8) + 46) & 0x3ff, buffer index gx[8:0]
    logic [9:0] rd_addr [0:3];
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_rd
            wire signed [23:0] src = r_mos[g] ? held[g] : acc[g];
            wire [9:0] gx = 10'((src >>> 8) + 24'sd46);
            assign rd_addr[g] = {r_bank, gx[8:0]};

            rf_bram #(.WIDTH(16), .AW(10)) u_buf (
                .clk(clk),
                .waddr(wr_addr), .wdata(wr_data), .wren(wr_en[g]),
                .raddr(rd_addr[g]), .q(rd_q[g])
            );
        end
    endgenerate

    // ---- build FSM -----------------------------------------------------
    assign busy = (bst != B_IDLE);

    always_ff @(posedge clk) begin
        gfx_req <= 1'b0;
        if (reset) begin
            bst <= B_IDLE;
            wb  <= 1'b0;
            done_bank <= 1'b1;
            for (int i = 0; i < 4; i = i + 1) begin
                reg_sx[i] <= '0; fx_y[i] <= '0;
                d_used[i] <= 1'b0; d_xs[i] <= 9'd256; d_fx_x[i] <= '0; d_mos[i] <= 1'b0;
            end
            d_xsamp <= 5'd16;
        end else if (frame_start) begin
            for (int i = 0; i < 4; i = i + 1) begin
                reg_sx[i] <= calc_sx(ctrl0[i], i);
                fx_y[i]   <= calc_sy(ctrl0[i + 4], flip);
            end
            bst <= B_IDLE;
        end else case (bst)
            B_IDLE: if (line_start) begin
                bpf  <= 2'd0;
                b_sy <= screen_y;
                b_xsamp <= x_sample;
                bst  <= B_SETUP;
            end

            // per-playfield line parameters
            B_SETUP: begin
                b_fx_x[bpf] <= fx_line;
                b_xs[bpf]   <= x_scale[bpf];
                b_mos[bpf]  <= mosaic_en[bpf];
                gy       <= gy_c;
                uy       <= flip ? (9'd511 - gy_c) : gy_c;
                gx_start <= gxs;
                gx_end   <= gxe;
                n_tiles  <= 6'((gxe[9:4] - gxs[9:4]) & 6'h3F) + 6'd1;
                scan_i   <= 7'd0;
                row_used <= 1'b0;
                bst      <= B_SCAN;
            end

            // MAME's row-usage test: any nonzero code word in tilemap row ty.
            // The RAM registers its address and answers the cycle after, so
            // the word addressed when scan_i was n is on pf_q when scan_i is
            // n+2: check from 2, and finish at 65 with word 63 in hand.
            B_SCAN: begin
                ty <= uy[8:4];
                py <= uy[3:0];
                // a 32-wide map has half the columns to look at, and walking
                // 64 of them would read the NEXT map's row and call this one
                // used on its data
                if (scan_i <= scan_last)
                    pf_addr <= extend ? {bpf, uy[8:4], scan_i[5:0], 1'b1}
                                      : {tmap3, uy[8:4], scan_i[4:0], 1'b1};
                if (scan_i >= 7'd2 && pf_q != 16'd0) row_used <= 1'b1;
                if (scan_i == scan_end) begin
                    b_used[bpf] <= row_used | (pf_q != 16'd0);
                    k   <= 6'd0;
                    gxt <= {gx_start[9:4], 4'd0};
                    bst <= (row_used | (pf_q != 16'd0)) ? B_TILE_A : B_NEXT_PF;
                end
                scan_i <= scan_i + 7'd1;
            end

            // tile (ty, tx): attribute word then code word. The RAM registers
            // the address and answers the cycle after: the attribute address
            // set in TILE_C is presented during W1 and its data is on pf_q
            // during W2; the code address set in W1 is answered during FETCH,
            // where pf_q holds still because the address does.
            //
            // HISTORY: this was right, then "fixed" to sample one cycle
            // earlier to satisfy a bench whose RAM model had no latency, and
            // the hardware showed a black screen. The bench was wrong.
            B_TILE_A: begin
                // extend=0 wraps x at 512, not 1024: MAME's m_width_mask
                tx      <= extend ? (flip ? (6'd63 - gxt[9:4]) : gxt[9:4])
                                  : {1'b0, (flip ? (5'd31 - gxt[8:4]) : gxt[8:4])};
                bst     <= B_TILE_C;
            end
            B_TILE_C: begin
                pf_addr <= a_attr;
                bst     <= B_TILE_W1;
            end
            B_TILE_W1: begin
                pf_addr <= a_code;
                bst     <= B_TILE_W2;
            end
            B_TILE_W2: begin
                attr    <= pf_q;                    // attribute arrives now
                bst     <= B_FETCH;
            end
            B_FETCH: begin
                // pf_q is the code word from here on. The previous tile's
                // unpack may still be writing -- that is the point -- but
                // the pending slot must be free to catch this row if it lands
                // early, and rf_gfx_bus drops a req while busy
                if (!gfx_busy && !pend_v) begin
                    // The tile number is the WHOLE code word. MAME takes it
                    // unmasked (taito_f3_v.cpp get_tile_info: tileinfo.set(3,
                    // tilep[1], ...)), and a 15-bit code here drew tile
                    // code-0x8000 instead for the four sets with a 6 MB
                    // tilemap -- Twin Cobra II's title emblem (codes to
                    // 0x9F64), its fade transition and its SCORE RANKING
                    // picture (to 0x8F74) all came out as scrambled gameplay
                    // tiles, 93 % of pixels wrong against MAME. Kaiser
                    // Knuckle, Dan-Ku-Ga and Kirameki Star Road have the same
                    // 6 MB tilemap. The sprite path was widened to 17 bits
                    // for Kaiser Knuckle and this one was left behind.
                    gfx_code <= pf_q;
                    gfx_row  <= py ^ {4{attr[15]}};
                    gfx_req  <= 1'b1;
                    bst      <= B_WAIT;
                end
            end
            B_WAIT: if (gfx_valid) bst <= B_NEXT_TILE;   // writer starts itself

            B_NEXT_TILE: begin
                if (k + 6'd1 == n_tiles) bst <= B_NEXT_PF;
                else begin
                    k   <= k + 6'd1;
                    gxt <= gxt + 10'd16;
                    bst <= B_TILE_A;
                end
            end

            B_NEXT_PF: begin
                if (bpf == 2'd3) bst <= B_DONE;
                else begin
                    bpf <= bpf + 2'd1;
                    bst <= B_SETUP;
                end
            end

            // hand the line over once the writer has drained; the y
            // accumulators step for the next one
            B_DONE: if (!wr_active && !pend_v) begin
                for (int i = 0; i < 4; i = i + 1) begin
                    d_fx_x[i] <= b_fx_x[i];
                    d_xs[i]   <= b_xs[i];
                    d_mos[i]  <= b_mos[i];
                    d_used[i] <= b_used[i];
                    if (b_sy != 8'd0)
                        fx_y[i] <= fx_y[i] + 24'(signed'({15'd0, y_scale[i]}));
                end
                d_xsamp   <= b_xsamp;
                done_bank <= wb;
                wb        <= ~wb;
                bst       <= B_IDLE;
            end

            default: bst <= B_IDLE;
        endcase
    end

endmodule
