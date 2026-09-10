//============================================================================
//  Pivot RAM backing store in SDRAM, with a per-cell-row read cache.
//
//  WHY THIS EXISTS. The F3 pivot RAM is 64 KB (MAME: map(0x630000,0x63ffff)
//  backed by memory_share_creator<u16> m_pivot_ram(0x10000) = 32768 words).
//  The core held it in an 8 KB block RAM, so CPU writes past 8 KB aliased
//  back over the start and destroyed what was there. The pivot pixel layer
//  is 512 px wide, so an 8x shortfall repeats it every 64 px -- measured on
//  hardware as 8 characters of story text and 4 background tiles. That is
//  GitHub issue #5 (Bubble Bobble II / Bubble Symphony).
//
//  Full size cannot go back in block RAM: 32768 x 16 = 512 Kbit ~ 64 M10K
//  against 8 today, and the design sits at 551/553 M10K with only ~19
//  reclaimable. So the store moves to SDRAM.
//
//  WHAT THE VIDEO SIDE ACTUALLY NEEDS. rf_video_pivot addresses the store as
//      pivot_addr = {t_cell, t_r, w} = col*512 + row*16 + r*2 + w
//  with cell = {col[5:0], row[4:0]}. For one screen line `row` is fixed and
//  only col (0..63), r (0..7) and w vary -- and `r` is ys[2:0]^flip_y, so a
//  per-tile flip can pick any r. Caching a whole CELL ROW therefore covers
//  every case: 64 cols x 16 words = 1024 words. The cell row only advances
//  every 8 screen lines, which is 8 lines of prefetch lead time.
//
//  So: two 1024-word banks. One serves the line being drawn, the other is
//  filled with the NEXT cell row. 256 four-word bursts per fill, ~6.6 us at
//  clk_ram 97 MHz against 8 lines (~508 us). Bandwidth is not the issue.
//
//  CPU READS ARE DELIBERATELY NOT SERVED HERE. rf_main keeps its existing
//  8 KB BRAM as the CPU's read-back path, so CPU reads behave EXACTLY as
//  they do today -- aliased above 8 KB, which is what shipped. That is not a
//  regression, and it keeps the CPU stall logic untouched. Only the video
//  path, which is what the screen shows, gets the full 64 KB. If a game is
//  ever found to read pivot RAM back above 8 KB, that becomes a real read
//  port here and rf_main gains a wait state like sel_rom's.
//
//  CDC follows rf_prog_bus's two proven rules: a request is a LEVEL held by
//  the originating domain with its payload stable, and completion returns as
//  a TOGGLE (a one-cycle pulse in the other domain would be missed).
//============================================================================

module rf_pivot_bus #(
    // SDRAM word address of the 32768-word pivot store. Core-private space
    // ABOVE the 18.5 MB game stream (0x1280000 bytes = 0x940000 words), so
    // it is not part of any MRA and no MRA has to be re-issued.
    parameter [26:1] BASE = 26'h0A00000
) (
    input  logic        reset,

    // ---- CPU side (clk_sys) --------------------------------------------
    input  logic        clk_sys,
    input  logic [14:0] cpu_addr,
    input  logic [15:0] cpu_din,
    input  logic  [1:0] cpu_be,
    input  logic        cpu_wr,        // one clk_sys pulse, qualified by clkena
    output logic        cpu_busy,      // hold clkena low while set

    // ---- video side (clk_sys) ------------------------------------------
    input  logic  [4:0] row,           // ys[7:3] of the line being built
    input  logic [14:0] v_addr,
    output logic [15:0] v_q,

    // ---- SDRAM channel (clk_ram) ---------------------------------------
    input  logic        clk_ram,
    output logic [26:1] ch_addr,
    output logic [15:0] ch_din,
    output logic  [1:0] ch_be,
    output logic        ch_rnw,        // 1 = read
    output logic        ch_req,
    input  logic        ch_ready,
    input  logic [63:0] ch_dout
);

    // =====================================================================
    //  CPU write: level request across to clk_ram, toggle back
    // =====================================================================
    logic        wr_lvl;               // held by clk_sys until acked
    logic [14:0] wr_addr;
    logic [15:0] wr_data;
    logic  [1:0] wr_be;

    logic        wr_ack_t;             // toggled in clk_ram on completion
    logic        wr_ack_s, wr_ack_1, wr_ack_2;

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            wr_lvl <= 1'b0;
            wr_ack_s <= 1'b0; wr_ack_1 <= 1'b0; wr_ack_2 <= 1'b0;
        end else begin
            wr_ack_s <= wr_ack_t;
            wr_ack_1 <= wr_ack_s;
            wr_ack_2 <= wr_ack_1;
            if (!wr_lvl && cpu_wr) begin
                wr_lvl  <= 1'b1;
                wr_addr <= cpu_addr;
                wr_data <= cpu_din;
                wr_be   <= cpu_be;
            end else if (wr_lvl && (wr_ack_1 ^ wr_ack_2)) begin
                wr_lvl <= 1'b0;
            end
        end
    end

    // Registered level ONLY. Gating clkena with anything combinational in
    // cpu_wr would close a loop: cpu_wr is qualified by clkena. rf_main holds
    // clkena low while this is set, so the CPU cannot issue a second write
    // until the first retires and none is ever dropped.
    assign cpu_busy = wr_lvl;

    // =====================================================================
    //  Which cell row each bank holds (clk_sys owns the request, clk_ram
    //  owns the fill). Bank `disp` serves the video; the other is filled.
    // =====================================================================
    logic       disp;                  // bank currently displayed
    logic [4:0] row_q;
    logic       want_t;                // toggled by clk_sys on a row change
    logic [4:0] want_row;              // the row to PREFETCH (row + 1)

    // A CPU write into a cached row makes that bank stale.
    logic       inval_t;
    logic [4:0] inval_row;

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            row_q <= 5'd31; disp <= 1'b0; want_t <= 1'b0;
            want_row <= 5'd0;
            inval_t <= 1'b0; inval_row <= 5'd0;
        end else begin
            row_q <= row;
            if (row != row_q) begin
                // the line just moved into a new cell row: show the bank that
                // was being filled, and start filling the one after
                disp     <= ~disp;
                want_row <= row + 5'd1;
                want_t   <= ~want_t;
            end
            if (cpu_wr) begin
                inval_row <= cpu_addr[8:4];      // the cell row it lands in
                inval_t   <= ~inval_t;
            end
        end
    end

    // =====================================================================
    //  clk_ram: an explicit FSM. A CPU write wins (they are rare); a fill has
    //  eight screen lines to finish, so it never needs to race anything.
    // =====================================================================
    localparam logic [1:0] R_IDLE  = 2'd0,
                           R_WRITE = 2'd1,
                           R_READ  = 2'd2,
                           R_SPILL = 2'd3;

    logic  [1:0] rst_;                  // FSM state
    logic        wr_seen;               // this wr_1 level already serviced
    logic        want_s, want_1, want_2;
    logic        wr_s, wr_1, wr_2;
    logic        inv_s, inv_1, inv_2;
    logic  [4:0] fill_row;
    logic  [5:0] fill_col;
    logic  [1:0] fill_burst;
    logic        fill_go, fill_busy, fill_bank;
    logic [63:0] rd_data;
    logic  [1:0] spill_cnt;
    logic  [7:0] spill_base;            // {col[5:0], burst[1:0]}
    logic        cache_we;
    logic [10:0] cache_wa;
    logic [15:0] cache_wd;

    always_ff @(posedge clk_ram) begin
        if (reset) begin
            want_s <= 1'b0; want_1 <= 1'b0; want_2 <= 1'b0;
            wr_s   <= 1'b0; wr_1   <= 1'b0; wr_2   <= 1'b0;
            inv_s  <= 1'b0; inv_1  <= 1'b0; inv_2  <= 1'b0;
            ch_req <= 1'b0; ch_rnw <= 1'b1; ch_be <= 2'b11;
            fill_go <= 1'b0; fill_busy <= 1'b0; fill_bank <= 1'b0;
            fill_row <= 5'd0; fill_col <= 6'd0; fill_burst <= 2'd0;
            cache_we <= 1'b0; wr_ack_t <= 1'b0; rst_ <= R_IDLE;
            wr_seen <= 1'b0;
            spill_cnt <= 2'd0;
        end else begin
            want_s <= want_t;  want_1 <= want_s;  want_2 <= want_1;
            wr_s   <= wr_lvl;  wr_1   <= wr_s;    wr_2   <= wr_1;
            inv_s  <= inval_t; inv_1  <= inv_s;   inv_2  <= inv_1;
            cache_we <= 1'b0;
            if (!wr_1) wr_seen <= 1'b0;   // level dropped: ready for the next

            // a new cell row was asked for (payload stable before the toggle)
            if (want_1 ^ want_2) begin
                fill_go   <= 1'b1;
                fill_row  <= want_row;
                fill_bank <= ~disp;
            end
            // a CPU write landed in the row being cached: refill it
            if ((inv_1 ^ inv_2) && (inval_row == fill_row)) fill_go <= 1'b1;

            case (rst_)
            R_IDLE: begin
                if (wr_1 && !wr_seen) begin            // CPU write outstanding
                    ch_addr <= BASE + {11'd0, wr_addr};
                    ch_din  <= wr_data;
                    ch_be   <= wr_be;
                    ch_rnw  <= 1'b0;
                    ch_req  <= 1'b1;
                    rst_    <= R_WRITE;
                end else if (fill_go || fill_busy) begin
                    if (fill_go) begin
                        fill_go    <= 1'b0;
                        fill_busy  <= 1'b1;
                        fill_col   <= 6'd0;
                        fill_burst <= 2'd0;
                        // cell = col*32 + row; 16 words each; 4 per burst
                        ch_addr <= BASE + {11'd0, 6'd0, fill_row, 2'd0, 2'd0};
                    end else begin
                        ch_addr <= BASE + {11'd0, fill_col, fill_row,
                                           fill_burst, 2'd0};
                    end
                    ch_rnw <= 1'b1;
                    ch_be  <= 2'b11;
                    ch_req <= 1'b1;
                    rst_   <= R_READ;
                end
            end
            R_WRITE: if (ch_ready) begin
                ch_req   <= 1'b0;
                wr_ack_t <= ~wr_ack_t;
                wr_seen  <= 1'b1;
                rst_     <= R_IDLE;
            end
            R_READ: if (ch_ready) begin
                ch_req     <= 1'b0;
                rd_data    <= ch_dout;
                spill_base <= {fill_col, fill_burst};
                spill_cnt  <= 2'd0;
                rst_       <= R_SPILL;
            end
            R_SPILL: begin
                cache_we <= 1'b1;
                cache_wa <= {fill_bank, spill_base, spill_cnt};
                cache_wd <= (spill_cnt == 2'd0) ? rd_data[15:0]
                          : (spill_cnt == 2'd1) ? rd_data[31:16]
                          : (spill_cnt == 2'd2) ? rd_data[47:32]
                                                : rd_data[63:48];
                if (spill_cnt == 2'd3) begin
                    spill_cnt <= 2'd0;
                    if (fill_burst == 2'd3) begin
                        fill_burst <= 2'd0;
                        if (fill_col == 6'd63) fill_busy <= 1'b0;
                        else fill_col <= fill_col + 6'd1;
                    end else fill_burst <= fill_burst + 2'd1;
                    rst_ <= R_IDLE;
                end else spill_cnt <= spill_cnt + 2'd1;
            end
            endcase
        end
    end

    // =====================================================================
    //  The cache: 2 banks x 1024 words. Filled on clk_ram, read on clk_sys.
    //  index = {bank, col[5:0], r[2:0], w} = {bank, addr[14:9], addr[3:0]}
    // =====================================================================
    rf_bram_dc #(.WIDTH_A(16), .AW_A(11), .RATIO_B(1)) u_cache (
        .clk_a  (clk_ram),
        .addr_a (cache_wa),
        .wdata_a(cache_wd),
        .wren_a (cache_we),
        .q_a    (),
        .clk_b  (clk_sys),
        .addr_b ({disp, v_addr[14:9], v_addr[3:0]}),
        .q_b    (v_q)
    );

endmodule
