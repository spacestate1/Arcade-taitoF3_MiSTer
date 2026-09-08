//============================================================================
//  The sprite framebuffer in DDR3 -- what the arcade board and MAME do.
//
//  WHY THIS EXISTS. The sprite draw used to write into a ring of on-chip line
//  buffers that the mixer read a few lines later, so the draw had to keep up
//  with the RASTER, line by line. It cannot. Measured on build 30101648, the
//  worst line carries 784 sprite rows and the draw loop is 17 clocks a row:
//  13328 clocks against a 3456-clock line budget, 3.9x over, and no fetch or
//  priority change touches that because the draw loop IS the floor (the same
//  build measured 17.8 clocks a row, i.e. almost no fetch wait). A ring of 16
//  banks 55296 clocks of slack, which covers about four such lines and then
//  runs dry -- which is exactly what a busy scene or a boss fight is.
//
//  But the frame as a whole is not remotely full: ~8000 sprite rows a frame
//  at 17 clocks is ~15 % of a frame's 884736 clocks. The work fits easily;
//  only its DISTRIBUTION does not. The real F3 board knows this, which is why
//  it draws sprites into a framebuffer and displays it a frame later, and why
//  MAME's config table carries a sprite_lag of 2 for this game.
//
//  So: the draw fills one line at a time into a small ping-pong buffer with
//  no deadline but the frame's, each finished line is streamed to a DDR3
//  framebuffer, and the mixer reads LAST frame's framebuffer back a line
//  ahead of where it is displaying. There is no per-line deadline left to
//  miss. Three consequences, all wanted:
//
//    - the glitching is gone structurally, not mitigated
//    - sprite lag becomes 2 frames, which is what MAME uses for this game
//      (README Known problem #3, fixed as a side effect)
//    - the on-chip line-buffer ring drops from 16 banks to 2 + 2, freeing
//      about 12 M10K on a device sitting at 551/553
//
//  LAYOUT. 16 bits a pixel, 4 pixels a 64-bit word, 80 words a line, 256
//  lines a bank, 2 banks (the frame being drawn and the frame being shown):
//  40960 words = 320 KB, at 0x30000000 -- the conventional base for a core's
//  own DDR3, well clear of screen_rotate's 0x24000000. Bandwidth is 19 MB/s
//  read plus write, against a port that does hundreds.
//
//  Every transaction is a single word (BURSTCNT 1). 80 words in and 80 out
//  per line against 3456 clocks is under 5 % occupancy, so bursting would buy
//  nothing and cost the arbiter its statelessness -- see rf_ddr_arb.
//============================================================================

module rf_spr_fb
(
    input  logic        clk,
    input  logic        reset,

    // ---- the frame boundary ---------------------------------------------
    // par is the parity of the frame being DRAWN; the mixer reads ~par. It
    // comes FROM the sprite engine rather than being toggled here as well:
    // two counters advancing on the same edge is a bug waiting for the one
    // reset that misses one of them, and if they ever disagreed the mixer
    // would read the bank being written.
    input  logic        frame_start,
    input  logic        par,

    // ---- write side: a finished line from the draw ----------------------
    input  logic        wr_req,         // pulse: line wr_line is ready
    input  logic  [7:0] wr_line,
    output logic        wr_busy,        // streaming; the draw must not reuse
                                        // the bank it just handed over
    output logic  [8:0] lb_addr,        // into the draw's line buffer
    input  logic [15:0] lb_q,           // 1-cycle read latency

    // ---- read side: what the mixer samples ------------------------------
    input  logic  [7:0] rd_line,        // the line being composed
    input  logic  [8:0] rd_x,
    output logic [15:0] rd_color,
    output logic [15:0] miss,           // lines composed without their sprites

    // ---- DIAGNOSTIC: the same pixels, either side of the DDR3 round trip -
    // Darius Gaiden renders its sprites in the wrong COLOURS on hardware
    // while every playfield and the text layer are pixel-exact, and the
    // whole video pipe is 74240/74240 identical to the model in simulation
    // on the very frame the board gets wrong. So the fault is in something
    // simulation does not reproduce, and the DDR3 round trip is the only
    // such thing in the sprite path.
    //
    // These two folds are the same quantity measured before and after it:
    // wr_fold sums every pixel the draw hands over (lb_q, as the writer
    // streams a finished line out), rd_fold sums every pixel the mixer gets
    // back (rd_color). Both are order-independent sums over the identical
    // set of pixels, so they are directly comparable to each other AND to
    // the model's sprite framebuffer for a matched frame:
    //
    //   wr != rd                  the round trip corrupts -- DDR3 path
    //   wr == rd  != model        the draw itself is wrong -- record/list
    //   wr == rd  == model        both fine; the fault is in the mixer or
    //                             the palette read after this point
    //
    // The write side is delayed by one frame before publication so the two
    // halves describe the SAME drawn frame (see wr_prev below); without that
    // they would differ on any moving picture and the row would only be
    // readable on a paused screen. Comparing the halves to EACH OTHER needs
    // no reference at all -- it is a self-check that works in attract.
    output logic [15:0] wr_fold,
    output logic [15:0] rd_fold,
    // PER-LINE verdict. The frame totals above proved the read side returns
    // pixels that were never written, and that it only happens on visarea f3
    // (232 lines, 24..255) -- 587/587 samples are perfect on f3_224a, and the
    // same game flips to 100 % by changing one MRA config bit. A frame total
    // cannot say WHICH lines, so this compares the two folds line by line:
    // the writer's fold for each line is kept (indexed by bank and line) and
    // checked against the reader's fold for the same line of the same bank.
    output logic  [7:0] bad_first,      // first line of the frame that differed
    output logic  [7:0] bad_last,       // and the last
    output logic [15:0] bad_count,      // how many lines differed
    // Times a refill was DEFERRED because the mixer was still displaying the
    // line in that slot -- i.e. how often the collision fixed below would
    // have corrupted a line. Non-zero on the board is the proof it was real;
    // zero would say the fix addresses something that never happens here.
    output logic  [7:0] defer_cnt,
    // Times a line's read UNDER-DELIVERED: the beats stopped arriving before
    // the line was full and the whole line had to be refetched from zero
    // (the R_WAIT -> R_DRAIN path). rf_spr_fb's own notes attribute that to
    // the f2sdram bridge capping a burst; rf_ddr_arb's preempt_cnt is the
    // competing explanation. Neither has ever been counted on hardware, and
    // every existing instrument sits on the sprite side of the shared port,
    // which is the side that wins arbitration -- so they all read clean
    // while the screen is visibly wrong. Saturating.
    output logic [15:0] short_cnt,

    // ---- DDR3, through rf_ddr_arb ---------------------------------------
    output logic  [7:0] ddr_burstcnt,
    output logic [28:0] ddr_addr,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    output logic        ddr_we,
    output logic        ddr_rd,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready
);

    // 0x30000000 in bytes is word 0x06000000; the top 7 bits are the region,
    // the same shape screen_rotate uses for its own 0x24000000.
    localparam logic [28:0] FB_BASE  = 29'h0600_0000;
    localparam int          WPL      = 80;          // 64-bit words per line
    localparam int          WPB      = 256 * WPL;   // words per frame bank
    // One checksum word per line, stored after both pixel banks. The read
    // side VERIFIES every line before the mixer may see it: three port
    // policies produced the same shredded screen while the same-instant
    // /dev/mem dump showed the stored image perfect, so whatever the real
    // port does to the returning stream, the answer is to stop trusting it.
    // A line whose checksum fails is refetched; the mixer only ever
    // composes verified data or a counted, empty line.
    localparam logic [28:0] CRC_BASE = FB_BASE + 29'(2 * WPB);
    function automatic logic [28:0] crc_word(input logic b, input logic [7:0] l);
        crc_word = CRC_BASE + 29'({b, l});
    endfunction

    // word index of (bank, line): bank*WPB + line*80, and 80 = 64 + 16 so
    // the multiply is two shifts and an add
    function automatic logic [28:0] line_word(input logic b, input logic [7:0] l);
        line_word = FB_BASE + 29'(b ? WPB : 0) + 29'({l, 6'd0}) + 29'({l, 4'd0});
    endfunction

    // ================= WRITE: draw line -> DDR3 =========================
    // Read four pixels out of the draw's line buffer, pack, issue one word.
    // 320 reads and 80 writes a line, interleaved, against 3456 clocks.
    // W_RD presents a pixel address; W_CAP captures it one clock later, which
    // is the line buffer's read latency. Collapsing the two (capturing in the
    // same state that advances the address) shifts every pixel by one and
    // wraps the last of each word into the next.
    typedef enum logic [2:0] { W_IDLE, W_RD, W_CAP, W_ISSUE, W_CRC } wst_t;
    wst_t wst;
    logic  [6:0] w_word;            // 0..79
    logic  [1:0] w_pix;             // which of the four
    logic [63:0] w_acc;
    logic [63:0] w_sum;                 // running XOR of the line's words
    // ---- STALE-LINE DETECTOR (2026-09-04) ----------------------------------
    // The per-line CRC proves a line's CONTENT round-tripped, but a line the
    // draw never rewrote this frame still carries LAST frame's pixels and
    // last frame's matching CRC, so it verifies and is shown -- one frame
    // behind everything around it. That is the "two layers, offset, at the
    // top of the frame" the player describes, and no counter here could see
    // it: `miss` fires only when a line is ABSENT. So the CRC word gives up
    // its low 8 bits to a frame number stamped when the line is written, and
    // the reader checks it against the frame it expects.
    logic  [7:0] fnum;                  // frames since reset
    logic  [7:0] fnum_w;                // the frame this line was drawn in
    always_ff @(posedge clk)
        if (reset) fnum <= 8'd0; else if (frame_start) fnum <= fnum + 8'd1;
    logic  [7:0] w_line;
    logic        w_bank;
    logic        w_crc;                 // the CRC word is on the bus

    assign wr_busy = (wst != W_IDLE);
    assign lb_addr = 9'({w_word, 2'd0}) + 9'(w_pix);

    // ================= READ: DDR3 -> the lines the mixer will want =======
    // A SLIDING WINDOW of NRB lines, filled in order and indexed by
    // line % NRB, so the mixer reads line L from buffer L[1:0] and the
    // prefetcher just walks forward.
    //
    // The first version held ONE line ahead and fetched reactively when the
    // mixer asked for a line it did not have. On the board that produced
    // sprites broken into dashes along the raster -- some scanlines had their
    // sprite data and some did not -- because a fetch that takes longer than
    // a line can never be caught up from one line of slack, and DDR3 here is
    // shared with screen_rotate and the HPS, so its stalls are nothing like
    // the model's. Depth is the fix, and it is cheap: 4 x 512 x 16 bits is
    // 4 M10K out of the 18 this change handed back.
    //
    // The window is refilled from line 0 at frame_start, and vblank is 31
    // lines long, so the first NRB lines are fetched with the mixer nowhere
    // near them.
    // 8 deep, was 4. With verification a line costs its beats plus a CRC
    // round trip, and on the real contended port that approaches a raster
    // line -- a 4-line window then has no slack, and lines arrive DURING
    // their own display: left part empty, sprite starting partway across,
    // which is exactly the split the screen showed while only ~2 lines a
    // frame counted as full misses. Seven lines of run-ahead absorbs the
    // jitter. 8 x 512 x 16 is 8 M10K of the 16 the framebuffer freed.
    localparam int NRB = 8;
    typedef enum logic [2:0] { R_IDLE, R_REQ, R_WAIT, R_CRC, R_VERIFY, R_DRAIN } rst_t;
    rst_t rst;
    logic  [6:0] r_word;            // words requested
    logic [11:0] r_to;              // watchdog on a line that never lands
    logic  [9:0] r_idle;            // cycles since the last beat arrived
    logic [63:0] r_sum;             // running XOR of the received words
    logic  [1:0] r_try;             // verification attempts for this line
    logic  [7:0] r_rem;
    logic  [7:0] r_got;             // words returned; see the >= test below
    logic  [8:0] nf;                // next line to fetch (256 = done)
    logic  [2:0] r_fill;            // nf % NRB
    logic  [7:0] buf_line [0:NRB-1];
    logic [NRB-1:0] buf_ok;

    // ONE rf_bram, 64 bits wide, addressed {slot, word}. This buffer was a
    // 2-D array (lbuf[slot][pixel]) and Quartus SILENTLY DID NOT INFER IT AS
    // RAM -- it is absent from the Fitter RAM Summary -- so the hardware
    // read back a degenerate structure while Verilator modelled the array
    // perfectly. That one divergence survived FIVE FSM redesigns, because
    // the corruption was never in the FSM: sim exact, screen striped, and
    // the same-instant DDR3 dump solid. The codebase already carries this
    // exact lesson ("can't infer memory for variable..."), which is why
    // rf_bram exists; this module now uses it like everything else does.
    // 64-bit words also mean ONE write per DDR beat instead of four pixel
    // writes in one cycle -- the very thing that forced the array shape.
    wire  [2:0] rd_sel = rd_line[2:0];
    wire        rd_hit = buf_ok[rd_sel] && (buf_line[rd_sel] == rd_line);
    logic [63:0] lb_rq;
    logic  [1:0] rd_lane_q;
    logic        rd_hit_q;
    always_ff @(posedge clk) begin
        rd_lane_q <= rd_x[1:0];
        rd_hit_q  <= rd_hit;
    end
    assign rd_color = rd_hit_q ? lb_rq[16*rd_lane_q +: 16] : 16'd0;

    // ---- the two diagnostic folds (see the port note) --------------------
    // One sample per x position: the mixer can hold rd_x for more than a
    // clock, and counting a pixel twice would make the two sides disagree
    // for a reason that is not the round trip.
    // The two sides are a frame apart and the published pair must NOT be:
    // the draw fills bank par during frame N while the mixer is showing the
    // bank drawn during N-1, so rd_acc always trails wr_acc by one frame.
    // Publishing them as they stand would make the halves differ on any
    // MOVING picture for a reason that is not the round trip -- which would
    // restrict the whole diagnostic to a paused screen. Delaying the write
    // side by one frame lines them up, so the row is readable in attract.
    // ---- per-line folds: REMOVED 2026-09-03 --------------------------
    // The per-line compare (a 512x16 M10K plus the wl/rl accumulators) did
    // its job: it proved on hardware that the DDR3 round trip returns the
    // sprite lines exactly as written wherever the picture was wrong, and
    // that the earlier 'bad line' readings were the instrument's own frame
    // boundary artifact. Its M10K went to the tile-row cache and the record
    // store (RESOURCES.md). The ports stay so nothing upstream rewires;
    // they read as zero, which is also what the corrected instrument read.
    // Carried out on the old fold ports (the plumbing to the page already
    // exists): bad_first = last stale line, bad_last = how many frames old
    // it was, bad_count = stale lines seen since reset (saturating).
    logic  [7:0] st_line, st_age, st_prev;
    logic [15:0] st_cnt;                // reset alongside the read FSM below
    assign bad_first = st_line;
    assign bad_last  = st_age;
    assign bad_count = st_cnt;

    logic [15:0] wr_acc, rd_acc, wr_prev;
    logic  [8:0] rd_x_q;
    logic        defer_q;
    wire         fill_want    = !nf[8] && (nf < {1'b0, rd_line} + NRB);
    wire         fill_collide = buf_ok[nf[2:0]] && (buf_line[nf[2:0]] == rd_line);
    wire         fill_defer   = (rst == R_IDLE) && fill_want && fill_collide;
    always_ff @(posedge clk) begin
        defer_q <= fill_defer;
        if (reset) defer_cnt <= 8'd0;
        else if (fill_defer && !defer_q && defer_cnt != 8'hFF)
            defer_cnt <= defer_cnt + 8'd1;
    end
    always_ff @(posedge clk) begin
        rd_x_q <= rd_x;
        if (reset) begin
            wr_acc <= 16'd0; rd_acc <= 16'd0; wr_prev <= 16'd0;
            wr_fold <= 16'd0; rd_fold <= 16'd0;
        end else if (frame_start) begin
            wr_fold <= wr_prev;  wr_prev <= wr_acc;
            rd_fold <= rd_acc;
            wr_acc  <= 16'd0;    rd_acc  <= 16'd0;
        end else begin
            // write side: lb_q is valid in W_CAP, the same cycle the packer
            // shifts it in, so tap exactly where the packer taps
            if (wst == W_CAP)      wr_acc <= wr_acc + lb_q;
            if (rd_x != rd_x_q)    rd_acc <= rd_acc + rd_color;
        end
    end


    logic        lb_we;
    logic  [9:0] lb_wa;
    logic [63:0] lb_wd;
    rf_bram #(.WIDTH(64), .AW(10)) u_lwin (
        .clk(clk),
        .waddr(lb_wa), .wdata(lb_wd), .wren(lb_we),
        .raddr({rd_sel, rd_x[8:2]}), .q(lb_rq)
    );

    // How many lines the mixer composed without their sprites being ready.
    // This is the direct successor of SPRLINE's late-line count: the same
    // question -- did the sprite data arrive in time -- for the new
    // mechanism. It must stay at zero.
    // A miss is counted only when it could have shown: the framebuffer must
    // have been primed (one whole frame written), and the line must still be
    // absent 512 cycles after the mixer moved onto it. Counting at the
    // transition instant scored the benign 255->0 wrap once every frame, and
    // counting before priming scored every boot frame 256 -- together they
    // buried the real signal under ~8000 counts and made SPRLINE's FAIL
    // unreadable for a whole day of builds.
    // END-OF-LINE verdict: a line is a miss only if its sprites were NEVER
    // present while the mixer was on it. The previous version sampled 512
    // cycles in and scored lines whose fetch completed later in their own
    // period -- a ~2/frame over-count on a screen proven solid, keeping
    // SPRLINE red with nothing wrong. hit_seen goes sticky the first cycle
    // the line is present; the verdict lands when the mixer moves on.
    logic  [7:0] rd_line_q;
    logic        primed, hit_seen;
    always_ff @(posedge clk) begin
        rd_line_q <= rd_line;
        if (reset) primed <= 1'b0;
        else if (frame_start && nf[8]) primed <= 1'b1;
        // miss is a per-FRAME count, so it clears at frame_start -- but
        // hit_seen must NOT. The mixer is mid-line when frame_start arrives
        // (it composes line L during raster L-1, and frame_start is raster
        // 260), so clearing the evidence here erases the hits that line had
        // already seen and the verdict at its end scores it a miss. That is
        // EXACTLY ONE SPURIOUS MISS PER FRAME, which is what the board has
        // been reporting: 28 late lines per self-test page pass, and a page
        // is 28 rows at one row per frame. It stayed exactly 28 across four
        // builds whose worst line ranged from 14,676 clocks down to 9,616 --
        // a load-dependent fault cannot be that constant.
        //
        // This is the same mistake SPRPIX made and the same fix: a quantity
        // the mixer produces belongs to the rd_line wrap, not to frame_start.
        // Letting hit_seen carry across the boundary lets the straddling
        // line be judged on the evidence it actually had.
        if (reset || frame_start) begin
            miss <= 16'd0;
        end else if (rd_line != rd_line_q) begin
            if (primed && !hit_seen && !rd_hit && miss != 16'hFFFF)
                miss <= miss + 16'd1;
            hit_seen <= rd_hit;
        end else if (rd_hit) hit_seen <= 1'b1;
    end

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (ddr_dout_ready && rst != R_IDLE && rst != R_CRC && rst != R_VERIFY) begin
            lb_we <= 1'b1;
            lb_wa <= {r_fill, r_got[6:0]};
            lb_wd <= ddr_dout;
        end
    end

    // ================= the port ==========================================
    // READS WIN, and a line is fetched as ONE 80-beat burst.
    //
    // Both are lessons from the board, not the bench. The first version gave
    // writes priority and issued reads one word at a time; the bench's
    // memory accepted a command every cycle, so it was exact to a 400-cycle
    // latency -- and on the board the sprites shredded into dashes. Dumping
    // the framebuffer back out of DDR3 through the HPS (/dev/mem mmap)
    // proved the STORED image perfect while the screen was broken: writes
    // were landing, and the read-back was starving behind them -- 80
    // commands a line on a port that takes real time per command, behind a
    // draw that free-runs its whole frame of writes at the start of the
    // raster.
    //
    // So: the reader goes first (the mixer is the one with a deadline; the
    // writer has the whole frame), and a line is ONE burst command whose 80
    // beats stream back on DOUT_READY -- which is what BURSTCNT exists for.
    // The write side stays single-beat: the stored dump proves it keeps up,
    // and single beats let rotation's writes slot between ours without the
    // arbiter needing a lock.
    // BURST 8, ten commands a line -- not 80 in one. The f2sdram bridge is
    // Avalon-MM and caps its burst well below 80; asking for more returned
    // fewer beats than requested, the wait state sat there for the rest it
    // would never get, and the miss counter went to 5389 a frame. Eight is
    // the length every MiSTer bridge accepts, and it still cuts the command
    // count per line by 8x, which was the whole point.
    // BURST, AND RE-ISSUE FROM WHAT ACTUALLY ARRIVED.
    //
    // Three measurements, all from the board's miss counter (lines composed
    // without their sprite data), all on the same attract loop:
    //
    //   single-word reads, writes first   8777 a frame
    //   80-beat burst, reads first        5389
    //   single-word reads, reads first    7937
    //
    // So bursting is what buys the bandwidth -- 80 commands a line is too
    // many however they are prioritised -- and the 80-beat attempt still
    // failed only because the f2sdram bridge CAPS its burst: it returned
    // fewer beats than asked and the wait state sat there for the rest.
    //
    // The fix: ask for 8 -- under-delivery only happens when a request
    // EXCEEDS the cap, and no known bridge caps below 8 (MiSTer's own
    // scaler bursts on this class of port) -- and complete on the BEAT
    // COUNT, not a timer: when a command's last beat lands, issue the next
    // chunk immediately. Ten commands a line instead of eighty. The idle
    // path is only a fallback for a bridge stranger than any known one,
    // and it DRAINS before re-asking so a straggling beat of the old
    // command can never land in the new one's slot.
    localparam int BL = 8;
    // Chunk commands are PIPELINED: each issues as soon as the port takes
    // the previous one, with PLANNED addresses (r_word walks the line), so a
    // line pays the DDR3 latency once, not once per chunk -- waiting for
    // each chunk's beats before asking again cost 20 x latency on a slow
    // port. The beat count is only the END-of-line verdict: if fewer beats
    // landed than were asked, the ones that did arrive may sit in the wrong
    // slots, so the whole line is refetched from zero after a drain --
    // never patched.
    logic [3:0] c_exp;                  // beats the next command asks for
    // STRICT ALTERNATION between read and write commands. Three boards'
    // worth of evidence says absolute priority starves the other side:
    // writes-first shredded the SCREEN (reads starved: 8777 misses) and
    // reads-first shredded the STORED image (writes starved -- the
    // /dev/mem dump grew horizontal tears it never had before). Neither
    // side needs more than a fraction of the port; each just needs a
    // bounded wait. A toggle gives both at least every other slot -- the
    // same fix, for the same reason, as ch4/ch7 in rf_sdram.
    logic rw_tog;                       // 1: reads have first refusal
    always_comb begin
        r_rem = 8'(WPL) - {1'b0, r_word};
        c_exp = (r_rem > 8'(BL)) ? 4'(BL) : r_rem[3:0];
    end
    assign ddr_burstcnt = (ddr_rd && rst == R_REQ) ? 8'(c_exp) : 8'd1;
    assign ddr_be       = 8'hFF;
    wire   rd_want      = (rst == R_REQ) || (rst == R_CRC);
    wire   wr_want      = (wst == W_ISSUE) || (wst == W_CRC);
    assign ddr_rd       = rd_want && (rw_tog  || !wr_want);
    assign ddr_we       = wr_want && (!rw_tog || !rd_want);
    assign ddr_din      = w_crc ? {w_sum[63:8], fnum_w} : w_acc;
    // reads resume from what has actually landed, not from what was asked
    // read commands use the PLANNED cursor (r_word): they pipeline ahead of
    // the returning beats, which land at r_got independently
    assign ddr_addr     = ddr_rd
                        ? (rst == R_CRC ? crc_word(~par, nf[7:0])
                                        : (line_word(~par, nf[7:0]) + 29'(r_word)))
                        : (w_crc ? crc_word(w_bank, w_line)
                                 : (line_word(w_bank, w_line) + 29'(w_word)));

    always_ff @(posedge clk) begin
        if (!ddr_busy) begin
            if (ddr_rd) rw_tog <= 1'b0;         // a read went: writes next
            if (ddr_we) rw_tog <= 1'b1;         // a write went: reads next
        end
        if (reset) begin
            rw_tog <= 1'b1;
            wst <= W_IDLE; rst <= R_IDLE;
            st_line <= 8'd0; st_age <= 8'd0; st_cnt <= 16'd0; st_prev <= 8'd0;
            r_fill <= 3'd0; buf_ok <= '0; nf <= 9'd0;
            for (int b = 0; b < NRB; b++) buf_line[b] <= 8'd0;
            w_word <= 0; w_pix <= 0; r_word <= 0; r_got <= 8'd0; r_to <= 12'd0;
            short_cnt <= 16'd0;
        end else begin
            if (frame_start) begin
                buf_ok <= '0;           // last frame's lines are stale
                nf     <= 9'd0;         // refill the window from line 0
                rst    <= R_IDLE;
            end

            // ---- write FSM
            case (wst)
                W_IDLE: if (wr_req) begin
                    w_line <= wr_line; w_bank <= par; fnum_w <= fnum;
                    w_word <= 0; w_pix <= 0; w_sum <= 64'd0; w_crc <= 1'b0;
                    wst <= W_RD;
                end
                // lb_q is valid one clock after lb_addr, so shift the pixel
                // into the accumulator on the cycle AFTER presenting it
                W_RD:  wst <= W_CAP;            // lb_addr presented; wait a clock
                W_CAP: begin
                    w_acc <= {lb_q, w_acc[63:16]};  // pixel 0 ends up lowest
                    if (w_pix == 2'd3) wst <= W_ISSUE;
                    else begin w_pix <= w_pix + 2'd1; wst <= W_RD; end
                end
                // advance only on a cycle our write was actually on the bus
                // (a pending read command masks ddr_we)
                W_ISSUE: if (!ddr_busy && ddr_we) begin
                    w_pix <= 2'd0;
                    w_sum <= w_sum ^ w_acc;
                    if (w_word == WPL - 1) begin w_crc <= 1'b1; wst <= W_CRC; end
                    else begin w_word <= w_word + 7'd1; wst <= W_RD; end
                end
                W_CRC: if (!ddr_busy && ddr_we) begin
                    w_crc <= 1'b0;
                    wst   <= W_IDLE;
                end
                default: wst <= W_IDLE;
            endcase

            // ---- read FSM: keep the buffer the mixer is NOT using filled
            // with the line after the one it is on
            // Walk forward: keep the window [rd_line, rd_line+NRB) filled.
            case (rst)
                // A slot being refilled must not read as valid. This was
                // written to explain Darius Gaiden's wrong sprite colours --
                // the theory being that the prefetcher wraps NRB lines round
                // onto the line the mixer is displaying and the mixer then
                // composes a mix of two lines. THE BOARD SAYS IT DOES NOT:
                // defer_cnt reads 0 on build 01232731, and the window
                // condition proves why -- refilling slot L%NRB happens at
                // nf = L+NRB, which the condition only allows once
                // rd_line > L, i.e. after the mixer has passed L. Kept
                // anyway: clearing buf_ok while a slot is being rewritten is
                // the invariant this module should have had, it costs
                // nothing, and defer_cnt is the evidence either way. It is
                // NOT the fix for the colours -- that is still open.
                R_IDLE: if (!nf[8] && (nf < {1'b0, rd_line} + NRB) &&
                           !(buf_ok[nf[2:0]] && (buf_line[nf[2:0]] == rd_line))) begin
                    buf_ok[nf[2:0]] <= 1'b0;   // invalid while it is rewritten
                    r_fill <= nf[2:0];
                    r_word <= 0; r_got <= 8'd0; r_to <= 12'd0; r_idle <= 10'd0;
                    r_sum <= 64'd0; r_try <= 2'd0;
                    rst <= R_REQ;
                end
                // one command per 8 beats; the beats stream back on DOUT
                R_REQ: if (!ddr_busy && ddr_rd) begin
                    r_idle <= 10'd0;
                    if (8'({1'b0, r_word}) + 8'(c_exp) >= 8'(WPL)) rst <= R_WAIT;
                    else r_word <= r_word + 7'(c_exp);
                end
                // >=, not the exact cycle the last word lands: with a fast
                // memory the returns keep pace with the requests and this
                // counter is already past it by the time R_WAIT is entered.
                // A short burst must never wedge this: if the beats do not
                // arrive, give the line up and move on rather than stalling
                // the window for the rest of the frame.
                // Beats land on DOUT_READY and bump r_got (below). When they
                // stop before the line is full, go back and ask for the rest
                // -- that is what makes any bridge cap self-correcting. r_to
                // is the outer watchdog: a line that will not come at all is
                // abandoned rather than stalling the window, and the miss
                // counter reports it.
                R_WAIT: begin
                    r_to   <= r_to + 12'd1;
                    r_idle <= ddr_dout_ready ? 10'd0 : r_idle + 10'd1;
                    if (r_got >= WPL) begin
                        r_idle <= 10'd0;
                        rst    <= R_CRC;
                    end else if (&r_to) begin
                        nf  <= nf + 9'd1;       // the line is not coming
                        rst <= R_IDLE;
                    // The threshold must exceed the port's WORST first-beat
                    // latency or a slow read is mistaken for a short one --
                    // at a modelled 400-cycle latency a 255-cycle threshold
                    // fired on every line and the retry loop ate the frame.
                    end else if (r_idle == 10'd1000) begin
                        rst <= R_DRAIN;         // under-delivery: start over
                        if (short_cnt != 16'hFFFF) short_cnt <= short_cnt + 16'd1;
                    end
                end
                // fetch the line's stored checksum (a single read)
                R_CRC: begin
                    r_to <= r_to + 12'd1;
                    if (!ddr_busy && ddr_rd) rst <= R_VERIFY;
                    if (&r_to) begin nf <= nf + 9'd1; rst <= R_IDLE; end
                end
                // The line is published ONLY when its content proves itself.
                // A mismatch means the port did something to the stream --
                // which three builds' worth of shredded screens say it does
                // -- so the line refetches, up to three tries, and an
                // unprovable line stays out of the window and is counted.
                R_VERIFY: begin
                    r_to   <= r_to + 12'd1;
                    r_idle <= r_idle + 10'd1;
                    if (ddr_dout_ready) begin
                        if (ddr_dout[63:8] == r_sum[63:8]) begin
                            // content proven -- now: is it THIS frame's?
                            // A fixed expected tag (fnum or fnum-1) flags a
                            // whole population of CORRECT lines -- the draw
                            // and the readout straddle frame_start differently
                            // for different lines, so tag-vs-fnum is not a
                            // constant. What IS invariant: a frame drawn in one
                            // pass has ONE tag on every line. "Two layers,
                            // offset" is exactly a run of lines whose tag
                            // differs from its neighbours'. So flag a tag that
                            // differs from the previous verified line's, except
                            // at line 0 where a new frame legitimately starts.
                            if (nf[7:0] != 8'd0 && ddr_dout[7:0] != st_prev) begin
                                st_line <= nf[7:0];
                                st_age  <= st_prev - ddr_dout[7:0];   // how many frames behind its neighbour
                                if (st_cnt != 16'hFFFF) st_cnt <= st_cnt + 16'd1;
                            end
                            st_prev <= ddr_dout[7:0];
                            buf_line[r_fill] <= nf[7:0];
                            buf_ok[r_fill]   <= 1'b1;
                            nf               <= nf + 9'd1;
                            rst              <= R_IDLE;
                        end else if (r_try != 2'd3) begin
                            r_try <= r_try + 2'd1;
                            r_word <= 0; r_got <= 8'd0; r_sum <= 64'd0;
                            r_idle <= 10'd0;
                            rst    <= R_REQ;
                        end else begin
                            nf  <= nf + 9'd1;   // unprovable: skip, count
                            rst <= R_IDLE;
                        end
                    end else if (&r_to || r_idle == 10'd1000) begin
                        nf <= nf + 9'd1; rst <= R_IDLE;
                    end
                end
                // quiet the port before re-asking, so a late beat of the
                // old command cannot land in the new one's slot
                // quiet the port, then refetch the WHOLE line: after an
                // under-delivered chunk the later beats sat in wrong slots,
                // so nothing already received can be trusted
                R_DRAIN: begin
                    r_to   <= r_to + 12'd1;
                    r_idle <= ddr_dout_ready ? 10'd0 : r_idle + 10'd1;
                    if (&r_to) begin nf <= nf + 9'd1; rst <= R_IDLE; end
                    else if (r_idle == 10'd300) begin
                        r_word <= 0; r_got <= 8'd0; r_sum <= 64'd0; rst <= R_REQ;
                    end
                end
                default: rst <= R_IDLE;
            endcase
            if (ddr_dout_ready && rst != R_IDLE && rst != R_CRC && rst != R_VERIFY) begin
                r_got <= r_got + 8'd1;
                r_sum <= r_sum ^ ddr_dout;
            end
        end
    end

endmodule
