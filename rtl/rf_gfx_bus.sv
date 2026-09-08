//============================================================================
//  Tile graphics fetch: one 16-pixel, 6bpp playfield tile row from SDRAM.
//
//  F3 playfield tiles are 6bpp stored as two separate ROM regions: the low
//  4 bits in "tilemap" and the top 2 bits in "tilemap_hi". MAME merges them
//  at load time (tile_decode: pixel = (low & 0x0f) | (hi & 0x30)); the real
//  board has no merge pass, it simply reads both planes in parallel. This
//  does what the board does -- two SDRAM channels, one request each, results
//  concatenated -- so no preprocessed third copy of the graphics is needed.
//
//  Layout, taken from the gfx_layouts in taito_f3.cpp and cross-checked
//  against tools/f3_gfx.py (which renders MAME's own frames pixel-exact, so
//  it is the authority on this byte order, not a guess):
//
//    low  gfx_16x16x4_packed_lsb : 128 bytes/tile, 8 bytes/row, and the low
//         nibble is the FIRST pixel, so pixel p is simply nibble p of the row
//    hi   layout_6bpp_tile_hi    : 64 bytes/tile, 4 bytes/row. Per row,
//         byte0 = bit4 for pixels 0-7 (LSB = pixel 0), byte1 = bit5 for 0-7,
//         bytes 2/3 the same for pixels 8-15.
//
//  A row of low data is 8 bytes, which is exactly one aligned 4-word SDRAM
//  burst -- one request per tile row, nothing discarded. A row of hi data is
//  4 bytes, so a burst carries two rows and row[0] picks the half.
//
//  SDRAM byte order: the download loader stores every non-maincpu region RAW
//  (only maincpu is byte-swapped LE->BE for the 68020), so region byte n sits
//  in SDRAM word n>>1, bits [8*(n&1) +: 8], and the controller returns
//  dout[15:0] = the lowest-addressed word. Net effect: dout[8k +: 8] is byte
//  k of the burst. Getting this wrong is the same class of bug that scrambled
//  the character generator (see the byte-order note in HANDOFF.md), so it is
//  checked in simulation against f3_gfx.py rather than reasoned about once.
//
//  CDC follows rf_prog_bus exactly, which is the pattern proven on hardware:
//    - the request is a LEVEL held until completion; the controller's own
//      two-flop synchronizer edge-detects it, and the address is stable the
//      whole time the level is up
//    - completion returns as a TOGGLE flipped in the ram domain (a one-cycle
//      ram-clock pulse would be missed at cpu clock), double-flopped and
//      edge-detected in the cpu domain. THREE stages before the edge, not
//      two: consuming the toggle also samples the burst data, whose routing
//      is cut from timing analysis by the async clock groups -- with a
//      2-deep chain that arrival passed or failed by fitter seed.
//============================================================================

module rf_gfx_bus
(
    input  logic        clk_cpu,
    input  logic        reset,

    // ---- request port (cpu domain) --------------------------------------
    input  logic [14:0] code,          // tile number, already masked to the
                                       // 32768 elements the 4 MB region
                                       // holds (Ray Force uses 16384 and
                                       // never sets bit 14)
    input  logic  [3:0] row,           // tile row 0-15, flipy already applied
    input  logic        req,           // one-cycle pulse
    output logic [95:0] pix,           // 16 pixels, 6 bits each, pixel 0 low
    output logic        valid,         // one-cycle pulse when pix is good
    output logic        busy,          // a req while busy is DROPPED -- the
                                       // caller must wait. pix is only
                                       // guaranteed on the valid cycle and
                                       // until the next request completes.

    // ---- SDRAM channels (clk_ram domain) --------------------------------
    input  logic        clk_ram,
    output logic [26:1] ch_lo_addr,
    input  logic [63:0] ch_lo_dout,
    output logic        ch_lo_req,
    input  logic        ch_lo_ready,
    output logic [26:1] ch_hi_addr,
    input  logic [63:0] ch_hi_dout,
    output logic        ch_hi_req,
    input  logic        ch_hi_ready,
    // The gfx region bases are PORTS, not constants: the core carries two
    // SDRAM map profiles now (see cfg_map in Rayforce.sv). Profile 0 is the
    // 18.5 MB map every game shipped before 2026-09-08 uses, and its MRAs
    // are untouched; profile 1 is a 36 MB map whose sprites region is 13 MB
    // rather than 4, which is what the fourteen sets that did not fit need
    // -- sprites is the region that overflows for thirteen of them.
    input  logic [26:1] base_lo,
    input  logic [26:1] base_hi
);

    // Word addresses of the two regions in the flat SDRAM map (the MRA
    // stream order IS the map): tilemap at byte 0x480000, tilemap_hi at
    // 0x680000.

    // ---- ram-domain completion capture ----------------------------------
    /* verilator lint_off PROCASSINIT */
    logic lo_done_t = 1'b0;
    logic hi_done_t = 1'b0;
    /* verilator lint_on PROCASSINIT */
    logic [63:0] lo_ram, hi_ram;

    always_ff @(posedge clk_ram) begin
        if (ch_lo_ready) begin lo_ram <= ch_lo_dout; lo_done_t <= ~lo_done_t; end
        if (ch_hi_ready) begin hi_ram <= ch_hi_dout; hi_done_t <= ~hi_done_t; end
    end

    logic lo_s, lo_1, lo_2, lo_3;
    logic hi_s, hi_1, hi_2, hi_3;
    always_ff @(posedge clk_cpu) begin
        lo_s <= lo_done_t; lo_1 <= lo_s; lo_2 <= lo_1; lo_3 <= lo_2;
        hi_s <= hi_done_t; hi_1 <= hi_s; hi_2 <= hi_1; hi_3 <= hi_2;
    end
    wire lo_edge = lo_2 ^ lo_3;
    wire hi_edge = hi_2 ^ hi_3;

    // ---- request engine --------------------------------------------------
    // The two channels are independent, so both requests go out together and
    // the fetch costs one round trip rather than two.
    logic  [3:0] r_row;
    logic        lo_got, hi_got;

    always_ff @(posedge clk_cpu) begin
        valid <= 1'b0;
        if (reset) begin
            busy      <= 1'b0;
            ch_lo_req <= 1'b0;
            ch_hi_req <= 1'b0;
            lo_got    <= 1'b0;
            hi_got    <= 1'b0;
        end else if (!busy) begin
            if (req) begin
                ch_lo_addr <= base_lo + {5'd0, code, row, 2'b00};
                ch_hi_addr <= base_hi + {6'd0, code, row[3:1], 2'b00};
                r_row      <= row;
                ch_lo_req  <= 1'b1;
                ch_hi_req  <= 1'b1;
                lo_got     <= 1'b0;
                hi_got     <= 1'b0;
                busy       <= 1'b1;
            end
        end else begin
            if (lo_edge) begin ch_lo_req <= 1'b0; lo_got <= 1'b1; end
            if (hi_edge) begin ch_hi_req <= 1'b0; hi_got <= 1'b1; end
            if ((lo_got || lo_edge) && (hi_got || hi_edge)) begin
                busy  <= 1'b0;
                valid <= 1'b1;
            end
        end
    end

    // ---- plane assembly --------------------------------------------------
    // hi holds two tile rows per burst; row[0] selects which.
    wire [31:0] hb = r_row[0] ? hi_ram[63:32] : hi_ram[31:0];

    genvar p;
    generate
        for (p = 0; p < 16; p = p + 1) begin : g_pix
            // low nibble of the pixel: nibble p of the 8-byte row
            wire [3:0] lo4 = lo_ram[4*p +: 4];
            // top two bits: byte0/byte1 for pixels 0-7, byte2/byte3 for 8-15
            wire b4 = (p < 8) ? hb[p]        : hb[16 + (p - 8)];
            wire b5 = (p < 8) ? hb[8 + p]    : hb[24 + (p - 8)];
            assign pix[6*p +: 6] = {b5, b4, lo4};
        end
    endgenerate

endmodule
