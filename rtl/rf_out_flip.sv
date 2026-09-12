//============================================================================
//  Output flip: the raw 15 kHz output upside down, for a CRT that is
//  mounted the other way round.
//
//  MiSTer's own Flip Screen acts on screen_rotate's DDR3 framebuffer, which
//  only the scaler (HDMI) reads; the analog output is the raster exactly as
//  the mixer composes it, and that raster CANNOT be composed bottom-up: the
//  F3's line RAM values are sticky from one line to the next (rf_video_line)
//  and the playfield y is a running accumulator (rf_video_pf), both
//  top-down by nature. So the analog flip costs what the HDMI one costs -- a
//  frame in DDR3:
//
//    writer  during raster T, reads the mixer's finished line T back out of
//            the pipe's output line buffer (bank T&1, which the beam is not
//            reading while this is on) and writes it to DDR3, two pixels a
//            64-bit word, twenty 8-beat write bursts a line, into THIS
//            frame's parity. BURSTS, not singles: the bench's DDR3 model at
//            30 clocks a command (a gated point of the ddr-sweep) put 160
//            single writes at 4800 clocks against a 3456-clock line and the
//            writer was late on every one; twenty commands are 600. The
//            port's other clients never burst a write, so both arbiters on
//            the way out hold the grant for the beats (rf_ddr_tag_mux,
//            rf_ddr_arb);
//    reader  during raster T, fetches the line raster T+2 must SHOW --
//            source line (axis - (T+2)), axis = top + bottom of the visible
//            window -- from LAST frame's parity, twenty 8-beat bursts, and
//            writes it into the display buffer's third bank with the words
//            in reverse order and the two pixels of each word swapped. That
//            is the whole 180 degrees. The beam reads the display buffer
//            instead of the line buffer while this is enabled.
//
//  TWO lines ahead, three display banks (they fit the same three M10K as
//  two: 480 words of 512), because the sprite framebuffer owns the port --
//  rf_ddr_tag_mux gives it every slot it asks for -- and this reader takes
//  what is left. A line's fetch may therefore start late or run long; with
//  a line of extra slack it still lands before its raster. A request that
//  arrives while a fetch is running waits in a one-deep queue; a third
//  behind that is dropped and counted.
//
//  One frame of latency, only while enabled; off, the beam reads the line
//  buffer exactly as before and this module is idle.
//
//  The two frames live at 0x30100000 -- rf_spr_fb owns 0x30000000, MiSTer's
//  rotation buffer 0x24000000 -- as word {parity, line[7:0], word[7:0]}
//  above FLIP_BASE: 1 MB. Parity flips at raster 0, so lines 0..255 of a
//  frame always land in one buffer and the reader always sees the other.
//
//  Instruments (self-test page, FLIP LATE:WLATE): display lines whose fetch
//  had not landed when their raster began (or was dropped), and source lines
//  the writer had not finished when the next began. Both must read zero.
//  Both saturate.
//============================================================================
module rf_out_flip (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,
    input  logic        h0,             // hcnt == 0
    input  logic  [2:0] div,
    input  logic  [8:0] vcnt,
    input  logic  [1:0] vis_mode,
    // the mixer's finished line: rf_video_pipe's u_lbuf read port. lb_base
    // is the bank the beam shows this raster; the writer latches it and
    // keeps reading it through the next raster (the bank survives two)
    input  logic  [9:0] lb_base,
    output logic  [9:0] lb_addr,
    input  logic [23:0] lb_q,           // valid one clock after lb_addr
    // the display buffer: three banks of 160 two-pixel words
    output logic        db_we,
    output logic  [8:0] db_waddr,       // bank base + word
    output logic [47:0] db_wdata,       // {odd pixel, even pixel} of the DISPLAY line
    output logic  [8:0] db_rbase,       // base of the bank the beam reads this raster line
    // DDR3, through rf_ddr_tag_mux
    output logic  [7:0] ddr_burstcnt,
    output logic [28:0] ddr_addr,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    output logic        ddr_we,
    output logic        ddr_rd,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,
    output logic [15:0] late_cnt,
    output logic [15:0] wlate_cnt
);
    localparam logic [28:0] FLIP_BASE = 29'h0602_0000;    // 0x30100000 in bytes
    localparam logic  [4:0] NCMD      = 5'd20;             // 8-beat commands a line
    localparam logic  [7:0] LASTW     = 8'd159;            // words a line - 1
    localparam logic  [7:0] INFLIGHT  = 8'd32;             // beats outstanding, at most

    // the visible window, as rayforce_video.sv defines it
    wire [8:0] v_start = (vis_mode == 2'd0) ? 9'd31 :
                         (vis_mode == 2'd1) ? 9'd32 : 9'd24;
    wire [8:0] v_end   = (vis_mode == 2'd3) ? 9'd256 : (v_start + 9'd224);
    wire [8:0] axis    = v_start + v_end - 9'd1;

    // one pulse per raster line, at a div slot nothing else in the pipe uses
    wire line_go = h0 && (div == 3'd6);

    logic par;                                   // the frame the writer fills
    always_ff @(posedge clk) begin
        if (reset) par <= 1'b0;
        else if (line_go && vcnt == 9'd0) par <= ~par;
    end
    // line 0's pulse is the one that flips par; sample what it will be
    wire par_now = (vcnt == 9'd0) ? ~par : par;

    // ---- the display bank ring: raster line mod 3 ------------------------
    // Counted, not divided: +1 a line, 0 at raster 0. The lines this module
    // ever fetches or shows are 24..255, all inside one clean run.
    logic [1:0] c3;
    wire  [1:0] c3_next = (vcnt == 9'd0) ? 2'd0 : (c3 == 2'd2) ? 2'd0 : c3 + 2'd1;
    always_ff @(posedge clk) begin
        if (reset) c3 <= 2'd0;
        else if (line_go) c3 <= c3_next;
    end
    function automatic logic [8:0] bank_base(input logic [1:0] b);
        bank_base = (b == 2'd0) ? 9'd0 : (b == 2'd1) ? 9'd160 : 9'd320;
    endfunction
    assign db_rbase = bank_base(c3);
    wire [1:0] c3_plus2 = (c3_next == 2'd0) ? 2'd2 : (c3_next == 2'd1) ? 2'd0 : 2'd1;

    // ---- writer ---------------------------------------------------------
    typedef enum logic [1:0] { W_IDLE, W_RD, W_CAP, W_ISSUE } wst_t;
    wst_t        wst;
    logic  [8:0] wx;                    // pixel being read, 0..319
    logic  [4:0] w_chunk;               // 8-word chunk being issued, 0..19
    logic  [2:0] w_beat;                // beat of it on the bus
    logic  [7:0] w_line;
    logic        w_par;
    logic  [9:0] w_base;
    logic [23:0] w_even;
    (* ramstyle = "logic" *) logic [47:0] w_buf [0:7];   // the chunk, {odd, even}
    assign lb_addr = w_base + 10'(wx);
    // once a write burst has a beat on the bus it must run to the end: a
    // read command in the middle of it would break the burst
    wire w_inburst = (wst == W_ISSUE) && (w_beat != 3'd0);

    // ---- reader ---------------------------------------------------------
    logic        r_busy;                // a line is being fetched
    logic  [4:0] r_cmd;                 // 8-beat commands issued, 0..20
    logic  [7:0] r_got;                 // beats landed, 0..160
    logic  [7:0] r_src;                 // its source line
    logic  [8:0] r_base;                // its display bank base
    logic  [8:0] r_dline;               // the raster it shows on
    logic        r_par;
    logic [11:0] r_idle;                // cycles since a beat landed
    // the one waiting behind it
    logic        p_valid;
    logic  [7:0] p_src;
    logic  [8:0] p_base, p_dline;
    logic        p_par;

    // only the visible lines: the reader never asks for the others, and
    // every command not issued is port time the sprite framebuffer keeps
    wire       w_line_go = line_go && enable && (vcnt >= v_start) && (vcnt < v_end);
    wire [8:0] d_line    = vcnt + 9'd2;                            // what T+2 shows
    wire       r_line_go = line_go && enable &&
                           (d_line >= v_start) && (d_line < v_end);
    wire [7:0] r_outst   = {r_cmd, 3'd0} - r_got;                  // beats in flight

    // done: the last beat landed, or the beats stopped coming (the bridge is
    // not known to do that -- rf_spr_fb -- but a wedge here would freeze the
    // picture, so give the line up and count it)
    wire       r_done = r_busy && ((r_got == 8'd160) || (&r_idle && r_outst != 8'd0));
    wire       r_free = !r_busy || r_done;

    wire rd_want = r_busy && (r_cmd != NCMD) && (r_outst < INFLIGHT) && !w_inburst;
    wire wr_want = (wst == W_ISSUE);
    assign ddr_rd       = rd_want;                 // the reader has the nearer deadline
    assign ddr_we       = wr_want && !rd_want;
    assign ddr_burstcnt = 8'd8;                    // both sides, always
    assign ddr_be       = 8'hFF;
    assign ddr_din      = {16'd0, w_buf[w_beat]};
    assign ddr_addr     = rd_want ? (FLIP_BASE | 29'({r_par, r_src, r_cmd, 3'd0}))
                                  : (FLIP_BASE | 29'({w_par, w_line, w_chunk, 3'd0}));

    always_ff @(posedge clk) begin
        db_we <= 1'b0;
        if (reset) begin
            wst <= W_IDLE; wx <= '0; w_chunk <= '0; w_beat <= '0;
            r_busy <= 1'b0; r_cmd <= '0; r_got <= '0; r_idle <= '0; p_valid <= 1'b0;
            late_cnt <= '0; wlate_cnt <= '0;
        end else begin
            // ---- writer: line T out of bank T&1, while the beam is elsewhere.
            // Sixteen pixels into w_buf, then one 8-beat burst; twenty times.
            // A line's write-out may run into the next raster; the one after
            // that reuses its bank, so a line still unfinished when the NEXT
            // request arrives is abandoned and counted. (The beam's bank
            // arithmetic gives every line two rasters -- see mix_b3 in
            // rf_video_pipe -- so this counts a line that took more than that.)
            if (w_line_go) begin
                if (wst != W_IDLE && wlate_cnt != 16'hFFFF) wlate_cnt <= wlate_cnt + 16'd1;
                wx <= 9'd0; w_chunk <= 5'd0; w_beat <= 3'd0; w_base <= lb_base;
                w_line <= vcnt[7:0]; w_par <= par_now; wst <= W_RD;
            end else case (wst)
                W_RD:  wst <= W_CAP;                       // lb_q lands next clock
                W_CAP: begin
                    wx <= wx + 9'd1;
                    if (!wx[0]) begin w_even <= lb_q; wst <= W_RD; end
                    else begin
                        w_buf[wx[3:1]] <= {lb_q, w_even};
                        wst <= (wx[3:0] == 4'd15) ? W_ISSUE : W_RD;
                    end
                end
                // a beat goes on a cycle our write was actually on the bus
                W_ISSUE: if (!ddr_busy && ddr_we) begin
                    w_beat <= w_beat + 3'd1;
                    if (w_beat == 3'd7) begin
                        w_chunk <= w_chunk + 5'd1;
                        wst <= (w_chunk == 5'd19) ? W_IDLE : W_RD;
                    end
                end
                default: ;
            endcase

            // ---- reader: commands out, beats into the display bank
            if (rd_want && !ddr_busy) r_cmd <= r_cmd + 5'd1;
            r_idle <= ddr_dout_ready ? 12'd0 : (r_idle + 12'd1);
            if (ddr_dout_ready && r_busy) begin
                db_we    <= 1'b1;
                db_waddr <= r_base + 9'(LASTW - r_got);
                db_wdata <= {ddr_dout[23:0], ddr_dout[47:24]};   // swap the pair
                r_got    <= r_got + 8'd1;
            end

            if (r_done) begin
                if (r_got != 8'd160 && late_cnt != 16'hFFFF) late_cnt <= late_cnt + 16'd1;
                r_busy <= 1'b0;
            end
            // the line raster T shows must have landed by now
            if (line_go && enable &&
                ((r_busy && !r_done && r_dline == vcnt) || (p_valid && p_dline == vcnt))) begin
                if (late_cnt != 16'hFFFF) late_cnt <= late_cnt + 16'd1;
            end
            // start: the queued line first, else this raster's request
            if (r_free) begin
                if (p_valid) begin
                    r_src <= p_src; r_base <= p_base; r_dline <= p_dline; r_par <= p_par;
                    r_cmd <= 5'd0; r_got <= 8'd0; r_busy <= 1'b1; p_valid <= 1'b0;
                end else if (r_line_go) begin
                    r_src <= 8'(axis - d_line); r_base <= bank_base(c3_plus2);
                    r_dline <= d_line; r_par <= ~par_now;
                    r_cmd <= 5'd0; r_got <= 8'd0; r_busy <= 1'b1;
                end
            end
            // queue: the request could not start now. One waits; one already
            // waiting is two lines behind the beam and will not make it --
            // dropped, counted.
            if (r_line_go && !(r_free && !p_valid)) begin
                if (p_valid && !r_free && late_cnt != 16'hFFFF) late_cnt <= late_cnt + 16'd1;
                p_src <= 8'(axis - d_line); p_base <= bank_base(c3_plus2);
                p_dline <= d_line; p_par <= ~par_now; p_valid <= 1'b1;
            end
        end
    end

endmodule
