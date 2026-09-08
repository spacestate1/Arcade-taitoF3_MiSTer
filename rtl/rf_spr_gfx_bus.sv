//============================================================================
//  Sprite graphics fetch: one 16-pixel, 6bpp SPRITE tile row from SDRAM.
//
//  Structurally identical to rf_gfx_bus (two SDRAM planes, one row per
//  request, results concatenated) -- see that file for the CDC reasoning.
//  Two differences, both from the sprite gfx layouts in taito_f3.cpp:
//    - the regions: sprites at byte 0x180000, sprites_hi at 0x380000.
//    - sprite_hi packing: layout_6bpp_sprite_hi stores each pixel's two top
//      bits as an adjacent (bit4,bit5) pair, LSB first -- so for pixel p the
//      pair is hi-row bits [2p +: 2], where tile_hi instead grouped all the
//      bit4s then all the bit5s. Everything else (the low 4bpp packed_lsb
//      plane, the burst-carries-two-rows arithmetic) is the same.
//
//  ORIGINAL header follows:
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

module rf_spr_gfx_bus
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
    // FETCH SELF-CHECK: sprite graphics are ROM, so two reads of the same
    // row MUST agree. Every 16th cache HIT is re-fetched from SDRAM anyway and
    // compared against the cached copy; a difference can only be the fetch
    // path returning wrong data. Missing pixels inside sprites (pens that
    // should be non-zero arriving as 0) is the board's visible defect, and
    // this is the instrument that says whether the fetch is where they die.
    output logic [15:0] fetch_bad,     // rows where SDRAM disagreed with cache (saturating)
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
    input  logic        ch_hi_ready
);

    // Word addresses in the flat SDRAM map: sprites at byte 0x180000,
    // sprites_hi at byte 0x380000 (word = byte >> 1).
    localparam logic [26:1] BASE_LO = 26'h140000;   // byte 0x280000
    localparam logic [26:1] BASE_HI = 26'h340000;   // byte 0x680000

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

    // ---- tile-row cache --------------------------------------------------
    //  A dense line re-fetches the SAME (code,row) many times: a boss is one
    //  large object built from repeated tiles, and y-zoom makes consecutive
    //  screen lines land on the same tile row. Measured over the model's own
    //  fetch order on the heaviest line of three dumped Ray Force frames,
    //  66-70 % of the fetches are exact repeats -- 114 fetches collapse to
    //  34. That is the difference between a 14,676-clock line and one that
    //  fits inside the ring's slack.
    //
    //  This is the safest cache that can be built: sprite graphics live in
    //  ROM and NEVER change, so there is no invalidation, no coherency and
    //  no frame boundary to get wrong -- the failure this project keeps
    //  hitting. The only state that needs clearing is the valid bits, once,
    //  at reset.
    //
    //  256 sets, DIRECT MAPPED. Direct mapped because it reaches the
    //  fully-associative bound on every frame measured (a 2-way costs a
    //  second tag compare and buys nothing), and 256 deep because an M10K is
    //  width-limited: a 96-bit memory costs three blocks whatever its depth,
    //  so a shallower cache would waste them. 3 M10Ks of data + 1 of tag per
    //  bus.
    localparam int CIDXW = 8;                       // 256 sets
    localparam int CTAGW = 15 + 4 - CIDXW;          // key is {code,row} = 19
    wire [CIDXW-1:0] cidx_req = {code[3:0], row};
    wire [CTAGW-1:0] ctag_req = code[14:4];

    logic [CIDXW-1:0] cidx_r;
    logic [CTAGW-1:0] ctag_r;
    logic             hit_r;
    logic  [3:0]      r_row;
    logic             lo_got, hi_got;
    logic             clring;
    logic [CIDXW:0]   clr_a;

    // Present the index combinationally on the request cycle so the RAM has
    // it one clock earlier: rf_bram registers the address, so q is good the
    // cycle after it is driven, and a hit answers in two clocks against 87
    // for a fetch.
    wire [CIDXW-1:0] craddr = (!busy && req) ? cidx_req : cidx_r;

    wire [CTAGW:0]   ctag_q;                        // {valid, tag}
    wire [95:0]      cdat_q;

    // fill on the cycle the fetch completes (see the engine below)
    logic            fill;
    wire [95:0]      pix_fetch;

    rf_bram #(.WIDTH(CTAGW+1), .AW(CIDXW)) u_ctag (
        .clk(clk_cpu),
        .waddr(clring ? clr_a[CIDXW-1:0] : cidx_r),
        .wdata(clring ? {(CTAGW+1){1'b0}} : {1'b1, ctag_r}),
        .wren (clring | fill),
        .raddr(craddr), .q(ctag_q)
    );
    rf_bram #(.WIDTH(96), .AW(CIDXW)) u_cdat (
        .clk(clk_cpu),
        .waddr(cidx_r), .wdata(pix_fetch), .wren(fill),
        .raddr(craddr), .q(cdat_q)
    );

    // BISECT SWITCH 3 (2026-09-07): the tile-row cache is uncommitted. A hit
    // on the wrong key returns another tile's artwork -- same sprite extent,
    // different pixel values, which is exactly the measured signature. The
    // fetch self-check cannot see it: it re-fetches for the SAME key and
    // compares, so a wrong key agrees with itself.
    //   CACHE_EN = 1  working tree (cache live)
    //   CACHE_EN = 0  committed    (every row fetched from SDRAM)
    localparam bit CACHE_EN = 1'b1;
    wire cache_hit = CACHE_EN && ctag_q[CTAGW] && (ctag_q[CTAGW-1:0] == ctag_r);

    // ---- request engine --------------------------------------------------
    // The two channels are independent, so both requests go out together and
    // the fetch costs one round trip rather than two.
    //  busy covers the whole transaction, lookup included, so nothing
    //  upstream has to know the cache exists: a hit simply returns sooner.
    logic looking;
    logic        chk;                  // this fetch is a verification of a hit
    logic  [3:0] chk_cnt;
    logic [95:0] chk_ref;

    always_ff @(posedge clk_cpu) begin
        valid <= 1'b0;
        fill  <= 1'b0;
        if (reset) begin
            busy      <= 1'b1;              // held until the valid bits are 0
            ch_lo_req <= 1'b0;
            ch_hi_req <= 1'b0;
            lo_got    <= 1'b0;
            hi_got    <= 1'b0;
            looking   <= 1'b0;
            hit_r     <= 1'b0;
            chk <= 1'b0; chk_cnt <= 4'd0; fetch_bad <= 16'd0;
            clring    <= 1'b1;
            clr_a     <= '0;
        end else if (clring) begin
            // 256 cycles at boot. The RAM's power-up contents are not part
            // of any contract this file wants to depend on, and a stale tag
            // that happens to match would return all-zero pixels FOREVER
            // for that key, since nothing would ever refill it.
            clr_a <= clr_a + 1'b1;
            if (clr_a[CIDXW]) begin
                clring <= 1'b0;
                busy   <= 1'b0;
            end
        end else if (!busy) begin
            if (req) begin
                cidx_r <= cidx_req;
                ctag_r <= ctag_req;
                r_row  <= row;
                looking<= 1'b1;
                busy   <= 1'b1;
            end
        end else if (looking) begin
            // ctag_q/cdat_q are good this cycle for the index driven last
            looking <= 1'b0;
            if (cache_hit && chk_cnt != 4'd15) begin
                chk_cnt <= chk_cnt + 4'd1;
                hit_r <= 1'b1;              // pix reads from cdat_q
                busy  <= 1'b0;
                valid <= 1'b1;
            end else begin
                // a miss, OR the 16th hit: fetch from SDRAM. For the hit the
                // cached row is kept to compare against when the fetch lands.
                chk     <= cache_hit;
                chk_ref <= cdat_q;
                if (cache_hit) chk_cnt <= 4'd0;
                hit_r      <= 1'b0;
                ch_lo_addr <= BASE_LO + {5'd0, ctag_r, cidx_r, 2'b00};
                ch_hi_addr <= BASE_HI + {6'd0, ctag_r, cidx_r[CIDXW-1:1], 2'b00};
                ch_lo_req  <= 1'b1;
                ch_hi_req  <= 1'b1;
                lo_got     <= 1'b0;
                hi_got     <= 1'b0;
            end
        end else begin
            if (lo_edge) begin ch_lo_req <= 1'b0; lo_got <= 1'b1; end
            if (hi_edge) begin ch_hi_req <= 1'b0; hi_got <= 1'b1; end
            if ((lo_got || lo_edge) && (hi_got || hi_edge)) begin
                busy  <= 1'b0;
                valid <= 1'b1;
                fill  <= 1'b1;              // pix_fetch is good now
                if (chk && pix_fetch != chk_ref && fetch_bad != 16'hFFFF)
                    fetch_bad <= fetch_bad + 16'd1;
                chk <= 1'b0;
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
            // top two bits: sprite_hi stores them as adjacent (bit4,bit5)
            // pairs, LSB first -- pixel p is hi-row bits [2p +: 2]
            assign pix_fetch[6*p +: 6] = {hb[2*p + 1], hb[2*p], lo4};
        end
    endgenerate

    // On a hit the pixels come from the cache; cdat_q still holds the looked
    // up line during the valid cycle because craddr is unchanged until the
    // next request is accepted.
    assign pix = hit_r ? cdat_q : pix_fetch;

endmodule
