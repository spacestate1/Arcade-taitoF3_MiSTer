//============================================================================
//  WHAT THIS IS, IN PLAIN ENGLISH
//
//  The video pipe has ONE door to DDR3 memory and TWO things that need to go
//  through it: the sprite framebuffer and the screen flip. This module is the
//  doorman, and it has two jobs.
//
//  Job one, whose turn is it. They take turns, strictly. Not "sprites first",
//  because the sprite framebuffer dumps a whole frame of writes at the top of
//  the raster and the flip would never get in (measured: 105 late lines in
//  six frames). Taking turns bounds how long either one waits.
//
//  Job two, whose data is this. Memory hands data back with NO label on it --
//  just "here are eight words", in the order they were asked for. So the
//  doorman keeps a queue of cloakroom tickets: every read gets a ticket
//  saying who asked and how many words they wanted. When words arrive, the
//  ticket at the front of the queue says whose they are; when that ticket's
//  words are all delivered it is torn up and the next ticket moves to the
//  front.
//
//  The whole scheme rests on memory returning exactly as many words as were
//  asked for. If it ever returns fewer, the front ticket never gets torn up,
//  and from then on EVERY delivery goes to the wrong person -- forever. That
//  does not look like a hiccup, it looks like both clients dying at once. So
//  there is a watchdog: if words stop arriving while tickets are outstanding,
//  the queue is thrown away and both sides resynchronise on their next line.
//
//  The rest of this header is the precise version.
//============================================================================
//  Two clients on one DDR3 port, with the returning read beats told apart.
//
//  rf_ddr_arb (top level) shares the port between MiSTer's rotation
//  framebuffer and this pipe; this module shares the pipe's half between the
//  sprite framebuffer (client F, rf_spr_fb) and the output flip (client V,
//  rf_out_flip). BOTH READ, which rf_ddr_arb never had to handle: Avalon
//  returns read data in command order with nothing on it saying whose it
//  is, so a tag FIFO records {client, beats} for every accepted read command
//  and the head entry owns every DOUT_READY until its beats are spent.
//
//  That depends on a burst returning EXACTLY the beats it asked for. Both
//  clients ask for at most 8, the length rf_spr_fb established no MiSTer
//  bridge under-delivers (its notes on the f2sdram burst cap); a short burst
//  here would hand the next command's beats to the wrong client. A WRITE
//  burst (the flip's writer sends eight beats a command) holds the grant
//  until its beats are on the bus: a command from the other side in the
//  middle of one would break it.
//
//  Grant: whoever asks; when both ask, they alternate -- the toggle flips
//  on every accepted command. Three policies were measured in the pipe
//  bench (2026-09-10), and this is the only one that is exact at the
//  default port model: the sprite framebuffer free-runs a frame's worth of
//  writes at the start of the raster, so "sprite framebuffer first" starved
//  the flip's per-line deadlines (105 late lines in six frames), and
//  "sprite reads first" left the flip late under the slow-command model
//  without helping the sprite path. Alternation bounds both waits, which is
//  the same lesson rf_spr_fb learned about its own reads and writes. What
//  remains under the model's 30-clocks-a-command point is a few stale
//  sprite lines a frame, which the STALELN row on the board will confirm
//  or dismiss for the real port.
//  Each client's `busy` is Avalon waitrequest from its point of view -- the
//  port's own busy, or the grant belonging to the other side -- and both
//  clients hold a command until their busy is low, so nothing is lost.
//============================================================================
module rf_ddr_tag_mux (
    input  logic        clk,
    input  logic        reset,
    // The flip is an OSD option that DEFAULTS OFF, but this module sat in the
    // sprite framebuffer's path unconditionally, so every game paid for
    // machinery only the flip needs -- including the header's own warning
    // above about "a few stale sprite lines a frame". Bisected on hardware
    // 2026-09-11: Darius Gaiden's Zone A palette is correct on 20260909,
    // yc_10210215 and flip_11083215, and stale on every build after this
    // module was wired in. With enable low the port belongs to client F
    // alone, straight through, exactly as it was before rf_out_flip existed.
    input  logic        enable,
    // ---- client F: the sprite framebuffer ------------------------------
    input  logic  [7:0] f_burstcnt,
    input  logic [28:0] f_addr,
    input  logic [63:0] f_din,
    input  logic  [7:0] f_be,
    input  logic        f_we,
    input  logic        f_rd,
    output logic        f_busy,
    output logic [63:0] f_dout,
    output logic        f_dout_ready,
    // ---- client V: the output flip -------------------------------------
    input  logic  [7:0] v_burstcnt,
    input  logic [28:0] v_addr,
    input  logic [63:0] v_din,
    input  logic  [7:0] v_be,
    input  logic        v_we,
    input  logic        v_rd,
    output logic        v_busy,
    output logic [63:0] v_dout,
    output logic        v_dout_ready,
    // ---- the port (rf_video_pipe's ddr_*, on to rf_ddr_arb) ------------
    output logic  [7:0] ddr_burstcnt,
    output logic [28:0] ddr_addr,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    output logic        ddr_we,
    output logic        ddr_rd,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,
    // how many times the watchdog below had to throw the queue away. Must be
    // zero; anything else means a read burst under-delivered and the beat
    // ordering was lost, which is the difference between "the port is slow"
    // and "the port lied about a burst length".
    output logic [15:0] flush_cnt
);
    // ---- tag FIFO: {is_v, beats} per accepted read command --------------
    // Flops, not a RAM: 32 x 5 bits, read asynchronously at the head.
    // 16, not 32. INFLIGHT caps a client at 32 beats outstanding and every
    // command is 8 beats, so each side can have at most 4 commands in the
    // queue and BOTH sides together at most 8. 32 entries was four times
    // what the design can reach, and these are flops with an async read at
    // the head -- LABs, which is what the fitter ran out of (2026-09-11).
    localparam int TD = 16;
    (* ramstyle = "logic" *) logic [4:0] tags [0:TD-1];
    logic [5:0] twp, trp;
    wire        tfull  = ((twp - trp) == 6'(TD));
    wire        tempty = (twp == trp);
    wire  [4:0] head   = tags[trp[4:0]];
    logic [3:0] bcnt;                       // beats of the head already landed

    // ---- desync watchdog -------------------------------------------------
    // Everything above rests on a read burst returning EXACTLY the beats it
    // asked for. If a bridge ever under-delivers, the head entry never
    // retires, every later beat is handed to the wrong client, and it stays
    // that way FOREVER -- which does not look like a short burst, it looks
    // like two clients that have both stopped working. That is precisely the
    // signature the board showed on 2026-09-11: rf_out_flip's late AND wlate
    // both pinned at 0xFFFF while the same design is exact in the bench.
    //
    // So do not trust the assumption -- time it out. Entries outstanding and
    // no beat for STALL_MAX cycles means the order is lost; drop the whole
    // FIFO and let both clients resynchronise, which costs at most the lines
    // in flight because each restarts its command count every raster line.
    // A line is 3456 clocks, so 4096 cannot fire on a merely slow port.
    localparam int STALL_MAX = 4096;
    logic [12:0] stall;
    wire         flush = (stall == 13'd4096);   // == STALL_MAX, written out
                                                 // because Quartus 17.0 dislikes N'(x)

    // a read that would overflow the tag FIFO is not offered to the port;
    // its client sees busy and holds it
    wire f_want  = f_we | (f_rd & ~tfull);
    wire v_want  = v_we | (v_rd & ~tfull);
    logic tog;                              // 1: V goes first when both ask
    // a write burst in progress: beats still owed, and whose
    logic [3:0] wl_left;
    logic       wl_v;
    wire  locked  = (wl_left != 4'd0);
    // EXPERIMENT 3: the flip's WRITES yield to the sprite framebuffer's
    // READS (the window refill that goes stale); everything else alternates
    wire  v_rd_want = v_rd & ~tfull;
    wire  f_rd_want = f_rd & ~tfull;
    wire grant_v = locked ? wl_v  : (v_want & (tog | ~f_want));   // POLICY: alternate
    wire grant_f = locked ? ~wl_v : (f_want & ~grant_v);

    always_comb begin
        if (!enable) begin              // bypass: client F owns the port
            ddr_burstcnt = f_burstcnt; ddr_addr = f_addr; ddr_din = f_din;
            ddr_be = f_be; ddr_we = f_we; ddr_rd = f_rd;
        end else if (grant_v) begin
            ddr_burstcnt = v_burstcnt; ddr_addr = v_addr; ddr_din = v_din;
            ddr_be = v_be; ddr_we = v_we; ddr_rd = v_rd & ~tfull;
        end else if (grant_f) begin
            ddr_burstcnt = f_burstcnt; ddr_addr = f_addr; ddr_din = f_din;
            ddr_be = f_be; ddr_we = f_we; ddr_rd = f_rd & ~tfull;
        end else begin
            ddr_burstcnt = 8'd1; ddr_addr = '0; ddr_din = '0;
            ddr_be = '0; ddr_we = 1'b0; ddr_rd = 1'b0;
        end
    end
    assign f_busy = enable ? (ddr_busy | ~grant_f) : ddr_busy;
    assign v_busy = enable ? (ddr_busy | ~grant_v) : 1'b1;   // V never runs

    wire        accept = ~ddr_busy & (ddr_we | ddr_rd);
    wire  [3:0] beats  = (ddr_burstcnt == 8'd0) ? 4'd1 : ddr_burstcnt[3:0];

    always_ff @(posedge clk) begin
        if (reset || !enable) begin
            twp <= '0; trp <= '0; bcnt <= '0; tog <= 1'b1;
            wl_left <= '0; wl_v <= 1'b0; stall <= '0; flush_cnt <= '0;
        end else begin
            // no entries outstanding, or a beat landed: the order is good
            if (tempty || ddr_dout_ready) stall <= '0;
            else if (!flush)              stall <= stall + 13'd1;
            if (accept) begin
                tog <= ~grant_v;            // the other side next
                if (ddr_rd) begin
                    tags[twp[4:0]] <= {grant_v, beats};
                    twp <= twp + 6'd1;
                end
                if (ddr_we) begin
                    if (locked) wl_left <= wl_left - 4'd1;
                    else if (beats != 4'd1) begin wl_left <= beats - 4'd1; wl_v <= grant_v; end
                end
            end
            if (ddr_dout_ready && !tempty) begin
                if (bcnt + 4'd1 == head[3:0]) begin
                    bcnt <= 4'd0;
                    trp  <= trp + 6'd1;
                end else bcnt <= bcnt + 4'd1;
            end
            // last, so it wins over the pointer updates above
            if (flush) begin
                twp <= '0; trp <= '0; bcnt <= '0; stall <= '0;
                if (flush_cnt != 16'hFFFF) flush_cnt <= flush_cnt + 16'd1;
            end
        end
    end

    assign f_dout       = ddr_dout;
    assign v_dout       = ddr_dout;
    // Bypassed, every beat is F's -- and NOT gated on ~tempty, which is the
    // one thing that could swallow a beat the sprite framebuffer was waiting
    // for if a tag ever went missing.
    assign f_dout_ready = enable ? (ddr_dout_ready & ~tempty & ~head[4])
                                 :  ddr_dout_ready;
    assign v_dout_ready = enable ? (ddr_dout_ready & ~tempty &  head[4]) : 1'b0;

endmodule
