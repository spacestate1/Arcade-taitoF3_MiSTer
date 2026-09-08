//============================================================================
//  Share the one DDRAM port between MiSTer's rotation framebuffer and ours.
//
//  The DE10-Nano gives a core exactly ONE port onto the HPS's DDR3, and
//  `screen_rotate` (sys/arcade_video.v) already owns it -- that is what turns
//  this vertical game the right way up on an ordinary display, so it cannot
//  be given up.
//
//    - DDRAM_RD is tied to 0. It NEVER reads. So every DOUT that ever comes
//      back belongs to the other client, and no read tagging is needed.
//    - DDRAM_BURSTCNT is 1. Single 64-bit words, ~2.1 M/s.
//
//  ROTATION DROPS WRITES WHEN THE PORT IS BUSY, AND THAT IS THE BUG THIS
//  MODULE NOW FIXES  (found 2026-09-07)
//  ------------------------------------------------------------------------
//  DDRAM_BUSY is the f2sdram bridge's Avalon-MM `waitrequest` (sys_top.v
//  wires it straight to ram_waitrequest). Avalon says a master must HOLD
//  write/address/writedata stable until waitrequest deasserts; a transfer
//  happens only on a cycle where write is high AND waitrequest is low.
//
//  `screen_rotate` does not do that. Its write is a ONE-CYCLE PULSE:
//
//      always @(posedge CLK_VIDEO) begin
//          ram_wr <= 0;                       // cleared every cycle
//          if (CE_PIXEL && FB_EN) begin
//              if (VGA_DE) begin ram_wr <= 1; ram_addr <= ...; end
//
//  and DDRAM_BUSY appears nowhere in that module except its port list -- it
//  is never read. So if waitrequest is high on the single cycle rotation
//  asserts DDRAM_WE, THAT PIXEL IS SILENTLY LOST. In a stock core this is
//  harmless: rotation owns the port, waitrequest is essentially never
//  asserted, and nobody notices. It stops being harmless the moment a second
//  client shares the port -- which is exactly what rf_spr_fb became.
//
//  This is the whole reported defect, and every observation fits it:
//
//    - IT SCALES WITH ON-SCREEN LOAD. Rotation's traffic is constant (one
//      word per visible pixel), but rf_spr_fb's is not: more sprite lines
//      means more time with waitrequest asserted, so more rotation pixels
//      land on a busy cycle and die. "Only when the screen is busy with lots
//      of objects and explosions" is the signature of this and not of
//      anything in the sprite pipeline.
//    - IT IS INVISIBLE TO EVERY EXISTING INSTRUMENT. SPRLINE:LATE,
//      SPR REC:DROP, STALELN:AGE:CNT and SPRFETCH all measure the SPRITE
//      side of this port -- the side that wins arbitration and is working
//      correctly. They read clean while the screen is visibly wrong because
//      the loser is rotation, and nothing has ever counted rotation.
//    - IT IS WORSE ON THE SCREEN THAN IN A SCREENSHOT. MiSTer's screenshot
//      captures the core's native 320x224 output, which is upstream of
//      rotation and therefore correct. The damage only exists in the rotated
//      framebuffer that actually drives the display.
//    - IT SHOWS AS VERTICAL LINES. Within a scanline screen_rotate steps
//      next_addr by STRIDE per pixel, so one native scanline is written down
//      a COLUMN of the rotated buffer. A run of dropped writes is therefore a
//      vertical streak on the rotated display -- which is how it was
//      described from the board before any of this was understood.
//    - IT ARRIVED WITH THE DDR3 SPRITE FRAMEBUFFER. Before that commit
//      rotation had the port to itself and waitrequest never fired.
//
//  THE FIX: a short write FIFO in front of rotation. Its fire-and-forget
//  pulse is captured here and re-presented until the bridge actually takes
//  it, which is the Avalon handshake screen_rotate should have implemented.
//  sys/ is not ours to patch, so the retry lives on this side of the port.
//
//  DEPTH. Rotation offers one word per CE_PIXEL (~one per 8 clk_sys cycles at
//  this pixel clock) and the FIFO drains one per cycle, so FD entries absorb
//  roughly 8*FD consecutive stalled cycles. Depth 8 was the first guess and
//  the bench killed it: waitrequest does not arrive as independent coin flips,
//  it arrives in RUNS, and rf_spr_fb pipelines its chunk commands so it can
//  hold the command bus for most of an 80-word line. 16 covers ~128
//  consecutive stalled cycles.
//
//  That number is still an estimate from a bench whose stall model is
//  invented, so DO NOT TRUST IT -- read rot_peak off the board instead. It is
//  the high-water mark of actual occupancy, and it is the field that says
//  whether FD is right. rot_lost is the failure it precedes.
//
//  Rotation still has absolute priority. That was always right; what was
//  missing was that losing the arbitration for a cycle used to mean losing
//  the pixel, and now it only means waiting a cycle.
//
//  BURST LENGTH IS 1 ON THE ROTATION SIDE. It is NOT 1 on the sprite side --
//  rf_spr_fb asks for up to BL beats per read (see its ddr_burstcnt) -- so
//  the original "stateless mux" reasoning in this header no longer holds in
//  full. It is still safe: a burst read's COMMAND is a single cycle, the
//  beats stream back on DOUT_READY independently of who holds the command
//  bus, and rotation never reads, so returning data is unambiguous.
//
//  Everything is in the CLK_VIDEO domain, which this core drives from
//  clk_sys (Rayforce.sv wires video_mixer's clk_video to clk_sys), so the
//  sprite engine is in the same domain and there is no CDC here at all.
//============================================================================

module rf_ddr_arb
(
    input  logic        clk,
    input  logic        reset,

    // ---- client R: MiSTer's screen_rotate. Write only, never reads. ------
    input  logic  [7:0] r_burstcnt,
    input  logic [28:0] r_addr,
    input  logic [63:0] r_din,
    input  logic  [7:0] r_be,
    input  logic        r_we,
    output logic        r_busy,

    // ---- client F: the sprite framebuffer. Reads and writes. ------------
    input  logic  [7:0] f_burstcnt,
    input  logic [28:0] f_addr,
    input  logic [63:0] f_din,
    input  logic  [7:0] f_be,
    input  logic        f_we,
    input  logic        f_rd,
    output logic        f_busy,
    output logic [63:0] f_dout,
    output logic        f_dout_ready,

    // ---- INSTRUMENTS ----------------------------------------------------
    // rot_stall: rotation writes that arrived while the bridge was asserting
    //   waitrequest. These are exactly the pixels the UNFIXED path lost, so a
    //   non-zero value that TRACKS ON-SCREEN LOAD is the proof of the
    //   diagnosis above. With the FIFO they are held and delivered, not lost.
    // rot_lost:  rotation writes dropped because the FIFO was full. This is
    //   the only remaining way to lose a pixel here and it MUST read zero; if
    //   it does not, FD is too small.
    // Both saturate.
    output logic [15:0] rot_stall,
    output logic [15:0] rot_lost,
    // rot_peak: the deepest the FIFO ever got. This is how the BOARD tells us
    // whether FD is right, instead of us guessing from a bench whose stall
    // model is invented. Comfortably below FD means the depth is sound; at or
    // near FD means it is not, and rot_lost is about to stop reading zero.
    output logic  [7:0] rot_peak,

    // ---- the physical port ----------------------------------------------
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE,
    output logic        DDRAM_RD,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY
);

    // ---- rotation's write FIFO ------------------------------------------
    // Registers, not an inferred RAM: an async-read store here would be an
    // MLAB, an MLAB is a LAB, and LABs are what this design runs out of
    // first (see RESOURCES.md). 8 x 101 bits is small enough to spend flops.
    localparam int FD = 16;                      // power of two
    localparam int AW = $clog2(FD);

    logic [28:0] q_addr [0:FD-1];
    logic [63:0] q_din  [0:FD-1];
    logic  [7:0] q_be   [0:FD-1];
    logic [AW:0] wptr, rptr;                     // one spare bit for full

    wire [AW:0] fcnt   = wptr - rptr;
    wire        fempty = (wptr == rptr);
    wire        ffull  = (fcnt == (AW+1)'(FD));

    // The port takes a command on a cycle where the client drives it and the
    // bridge is not asserting waitrequest -- that is the whole Avalon rule.
    wire        r_take = !fempty && !DDRAM_BUSY;

    always_ff @(posedge clk) begin
        if (reset) begin
            wptr      <= '0;
            rptr      <= '0;
            rot_stall <= 16'd0;
            rot_lost  <= 16'd0;
            rot_peak  <= 8'd0;
        end else begin
            if (r_we && !ffull) begin
                q_addr[wptr[AW-1:0]] <= r_addr;
                q_din [wptr[AW-1:0]] <= r_din;
                q_be  [wptr[AW-1:0]] <= r_be;
                wptr <= wptr + 1'b1;
            end
            if (r_take) rptr <= rptr + 1'b1;

            // The counterfactual: would the stock fire-and-forget path have
            // lost this pixel? It would, on any cycle waitrequest was high.
            if (r_we && DDRAM_BUSY && rot_stall != 16'hFFFF)
                rot_stall <= rot_stall + 16'd1;
            if (r_we && ffull && rot_lost != 16'hFFFF)
                rot_lost <= rot_lost + 16'd1;
            if (8'(fcnt) > rot_peak) rot_peak <= 8'(fcnt);
        end
    end

    // ---- the mux --------------------------------------------------------
    // Rotation first, and now it holds the port until the write is actually
    // taken rather than offering it for one cycle and hoping.
    wire grant_r = !fempty;
    wire f_want  = f_we | f_rd;
    wire grant_f = ~grant_r & f_want;

    always_comb begin
        if (grant_r) begin
            DDRAM_BURSTCNT = 8'd1;               // screen_rotate ties this to 1
            DDRAM_ADDR     = q_addr[rptr[AW-1:0]];
            DDRAM_DIN      = q_din [rptr[AW-1:0]];
            DDRAM_BE       = q_be  [rptr[AW-1:0]];
            DDRAM_WE       = 1'b1;
            DDRAM_RD       = 1'b0;
        end else if (grant_f) begin
            DDRAM_BURSTCNT = f_burstcnt;
            DDRAM_ADDR     = f_addr;
            DDRAM_DIN      = f_din;
            DDRAM_BE       = f_be;
            DDRAM_WE       = f_we;
            DDRAM_RD       = f_rd;
        end else begin
            DDRAM_BURSTCNT = 8'd1;
            DDRAM_ADDR     = 29'd0;
            DDRAM_DIN      = 64'd0;
            DDRAM_BE       = 8'd0;
            DDRAM_WE       = 1'b0;
            DDRAM_RD       = 1'b0;
        end
    end

    // screen_rotate ignores this (that is the bug), but drive it correctly:
    // the only state in which it genuinely cannot be served is a full FIFO.
    assign r_busy = ffull;
    assign f_busy = DDRAM_BUSY | grant_r;

    // Rotation never reads, so every returning word is the framebuffer's.
    assign f_dout       = DDRAM_DOUT;
    assign f_dout_ready = DDRAM_DOUT_READY;

    // r_burstcnt is unused: screen_rotate ties it to a constant 1 and the
    // FIFO replays single words. Referenced so the port is not dangling.
    wire _unused_r_burstcnt = &{1'b0, r_burstcnt};

endmodule
