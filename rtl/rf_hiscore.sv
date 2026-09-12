//============================================================================
//  High-score save/restore -- the hiscore.dat mechanism, in RTL.
//
//  Neither game saves scores itself: the 93C46 holds settings only, and the
//  score table lives in main RAM and dies with the power. MAME's answer is
//  the hiscore plugin -- per-game RAM ranges plus guard bytes that say when
//  the game has finished initialising its default table; dumped on exit,
//  written back on boot once the guards match. This is that mechanism, with
//  the tables from MAME's own plugins/hiscore/hiscore.dat:
//
//    gunlock/rayforce/rayforcej:  40eff4 len 40 start 41 end 00
//                                 4022fa len  4 start 01 end 00
//    elvactr family:              40ce3a len 7c start 00 end 01
//                                 40ce3c len  1 start c3 end c3
//
//  (Main RAM is at 0x400000: byte offsets 0xeff4/0x22fa and 0xce3a/0xce3c.
//  EAR's second range sits inside its first -- an extra check byte -- and
//  is dumped after it all the same, so a dump here lays out exactly as the
//  dat describes and hi2txt can read the .nvm's upper half.)
//
//  STORAGE rides the EXISTING NVRAM blob: bytes 0-127 of ioctl index 254
//  stay the EEPROM, bytes 128-255 are the score snapshot, and the MRA's
//  <nvram> grows to 256. The same OSD-open save writes both. An old
//  128-byte .nvm never delivers the upper half, the shadow then fails the
//  guard check, and nothing is injected -- backward compatible by
//  construction.
//
//  RAM ACCESS borrows the CPU's own port: raise hs_pause (rf_main's clkena
//  hold, the same one the OSD Pause uses), wait out any in-flight bus
//  cycle, mux u_ram. The CPU latches nothing while clkena is held and its
//  read is re-presented on release, so the borrow is invisible. An inject
//  is ~500 cycles of pause -- ten microseconds, once per boot; the guard
//  polls while waiting are ~30 cycles, once per vblank, and stop for good
//  once the answer is known.
//
//  FIRST RUN MATTERS: with no valid file there is nothing to inject, but
//  the save must still happen or no score would ever be written. So the
//  guard poll runs regardless, and save_ready is raised the first time the
//  GAME's guards match -- inject or no inject.
//
//  Rules this module keeps (each one a build failure elsewhere in this
//  core's history): the shadow has ONE writer block (loader words are
//  queued and drained by the same FSM that writes captures -- Quartus
//  refuses multiple constant drivers); reads honour the REGISTERED
//  address + registered q = data valid two cycles after presenting; and
//  the guard bytes are checked by walking them one per step, not as a
//  four-way combinational read of one MLAB.
//============================================================================

module rf_hiscore
(
    input  logic        clk,
    input  logic        reset,

    input  logic  [5:0] game_id,        // 0 = Ray Force family, 1 = EAR
    input  logic        run,            // CPU out of reset and running
    input  logic        vbl_rise,       // poll cadence while waiting

    // ---- load: the upper half of the ioctl-254 blob (16-bit LE words) ---
    input  logic        ld_wr,
    input  logic  [5:0] ld_word,        // word 0-63 of the 128-byte slot
    input  logic [15:0] ld_data,

    // ---- save: the same words back; valid 2 clocks after sv_word --------
    input  logic  [5:0] sv_word,
    output logic [15:0] sv_data,
    input  logic        ioctl_upload,   // rising edge = capture RAM first

    // ---- the borrowed RAM port ------------------------------------------
    output logic        hs_pause,
    output logic [15:0] hs_addr,        // 16-bit word address in the 128 KB
    output logic [15:0] hs_wdata,
    output logic  [1:0] hs_be,
    output logic        hs_we,
    input  logic [15:0] hs_q,           // registered raddr + registered q

    output logic        save_ready,    // guards seen: worth requesting a save
    // Diagnostics for the self-test page. The restore path fails somewhere
    // downstream of save_ready and two builds were spent guessing at it, so
    // the two signals that actually distinguish the cases are brought out:
    // sh_ok says the shadow guards matched (the .nvm is for this game and
    // intact), injected says the table was actually written into game RAM.
    output logic        sh_ok_o,
    output logic        injected_o
);

    // ---- per-game table --------------------------------------------------
    logic [16:0] r0_off, r1_off;
    logic  [7:0] r0_len, r1_len;
    logic  [7:0] gv [0:3];              // guard values, in walk order
    // ONLY these games have a table here. Every other id used to fall into
    // the Ray Force branch below and poll Ray Force's RAM offsets in a game
    // that has nothing there -- and had those four bytes ever read 41 00 01
    // 00 by coincidence, the inject would have written 68 bytes of Ray
    // Force's high-score table into an unrelated game's work RAM. Ids 6 and
    // 7 (Gunlock, Ray Force Japan) genuinely ARE the Ray Force table: same
    // game, same map, one program ROM apart.
    wire has_table = (game_id == 6'd0) || (game_id == 6'd1) ||
                     (game_id == 6'd6) || (game_id == 6'd7);
    always_comb begin
        if (game_id == 6'd1) begin      // Elevator Action Returns
            r0_off = 17'h0ce3a; r0_len = 8'h7c;
            r1_off = 17'h0ce3c; r1_len = 8'h01;
            gv[0] = 8'h00; gv[1] = 8'h01; gv[2] = 8'hc3; gv[3] = 8'hc3;
        end else begin                  // Ray Force / Gunlock
            r0_off = 17'h0eff4; r0_len = 8'h40;
            r1_off = 17'h022fa; r1_len = 8'h04;
            gv[0] = 8'h41; gv[1] = 8'h00; gv[2] = 8'h01; gv[3] = 8'h00;
        end
    end
    wire [7:0] total = r0_len + r1_len;

    // dump byte index -> RAM byte offset (ranges concatenated, dat order)
    function automatic logic [16:0] dump_off(input logic [7:0] i);
        dump_off = (i < r0_len) ? (r0_off + 17'(i))
                                : (r1_off + 17'(i - r0_len));
    endfunction
    // guard g -> RAM byte offset / dump byte index
    function automatic logic [16:0] guard_off(input logic [1:0] g);
        guard_off = (g == 2'd0) ? r0_off
                  : (g == 2'd1) ? (r0_off + 17'(r0_len) - 17'd1)
                  : (g == 2'd2) ? r1_off
                                : (r1_off + 17'(r1_len) - 17'd1);
    endfunction
    function automatic logic [7:0] guard_idx(input logic [1:0] g);
        guard_idx = (g == 2'd0) ? 8'd0
                  : (g == 2'd1) ? (r0_len - 8'd1)
                  : (g == 2'd2) ? r0_len
                                : (total - 8'd1);
    endfunction

    typedef enum logic [2:0] { H_IDLE, H_SETTLE, H_GUARD, H_INJ, H_CAP, H_DONE } hst_t;
    hst_t hst;

    // ---- the shadow: 64 x 16, LE within the word, ONE writer -------------
    (* ramstyle = "MLAB, no_rw_check" *) logic [15:0] shadow [0:63];

    // loader words are queued (one deep is plenty: they arrive microseconds
    // apart) and drained below, so the capture path and the loader are the
    // same writer block
    logic        ld_pend;
    logic  [5:0] ld_pw;
    logic [15:0] ld_pd;

    // ONE read port, address-muxed. Two read ports at different addresses is
    // what stopped Quartus inferring memory here at all ("can't infer memory
    // for variable 'shadow'", warning 10999), so 64 x 16 was built as ~1,024
    // flip-flops and TWO 64:1 muxes -- and LABs, not ALMs, are what this
    // design runs out of. RESOURCES.md has called this the best free lever in
    // the design for weeks; the 2026-09-11 fit missed by 16 LABs and this is
    // what paid for it.
    //
    // Safe because the two readers are disjoint in time: sv_word is driven by
    // the HPS only while ioctl_upload is asserted, and sh_idx is only read in
    // H_GUARD and H_INJ, which run off the vblank poll after a load. The FSM
    // keeps priority in those two states so that a save arriving mid-restore
    // cannot corrupt the restore -- it would delay the save's word, and a
    // wrong high-score table is worse than a late one.
    logic  [7:0] sh_idx;
    wire        fsm_reading = (hst == H_GUARD) || (hst == H_INJ);
    wire  [5:0] sh_addr     = sh_idx[6:1];
    wire  [5:0] rd_addr     = (ioctl_upload && !fsm_reading) ? sv_word : sh_addr;
    wire [15:0] rd_q        = shadow[rd_addr];

    logic [15:0] sv_q;
    always_ff @(posedge clk) sv_q <= rd_q;
    assign sv_data = sv_q;

    wire  [15:0] sh_word = rd_q;
    wire   [7:0] sh_byte = sh_idx[0] ? sh_word[15:8] : sh_word[7:0];

    // even 68k byte address = UPPER lane (UDS)
    function automatic logic [1:0] lane_of(input logic [16:0] b);
        lane_of = b[0] ? 2'b01 : 2'b10;
    endfunction

    // ---- FSM -------------------------------------------------------------
    logic       injected;               // the table has been written at least once
    assign      injected_o = injected;
    logic       poll_done;              // done: no (further) poll will help

    // ONE INJECT IS NOT ENOUGH, measured on hardware 2026-08-31. The guards
    // say "the game has written the byte we recognise", not "the game has
    // finished initialising". Ray Force's gv[0] is the 'A' of the default
    // top scorer ABE, so the guard passes the moment that byte lands and the
    // inject can be overwritten by the rest of the game's own table build.
    // A one-shot inject then loses the save for good: the board loaded a
    // valid 256-byte .nvm with all four file guards intact and still showed
    // the game's defaults.
    //
    // So inject on every vblank the guards allow, for a bounded window,
    // rather than once. The write is idempotent -- the same bytes over the
    // same addresses -- and the window closes long before a player can post
    // a score, so a late re-inject cannot eat one. Costs the same ~10 us of
    // clkena hold the guard poll already takes each vblank.
    localparam logic [9:0] INJ_TRIES = 10'd600;   // ~10 s at 60 Hz
    logic [9:0] inj_left;
    logic       capturing;
    logic       sh_ok;                  // shadow guards match, so far
    assign      sh_ok_o = sh_ok;
    logic [7:0] idx;
    logic  [1:0] gph;
    logic  [7:0] settle;
    logic  [1:0] rd_ph;                 // 0 present, 1 ram latch, 2 q valid
    logic        upload_d;
    logic [15:0] cap_lo;                // capture assembles LE words

    wire [16:0] cur_b = (hst == H_GUARD) ? guard_off(gph) : dump_off(idx);

    always_ff @(posedge clk) begin
        hs_we    <= 1'b0;
        upload_d <= ioctl_upload;
        if (reset) begin
            hst <= H_IDLE; hs_pause <= 1'b0;
            injected <= 1'b0; poll_done <= 1'b0; save_ready <= 1'b0;
            capturing <= 1'b0; ld_pend <= 1'b0; rd_ph <= 2'd0;
            inj_left <= INJ_TRIES;
        end else begin
            // Loader words write the shadow directly unless a capture is
            // mid-flight (H_CAP is the only other shadow writer); then one
            // is queued and drained after. Writing only via the queue
            // dropped every word but the last under back-to-back input --
            // the bench's loader is gapless even though MiSTer's is not,
            // and a mechanism that only works because the input is slow is
            // not a mechanism.
            if (ld_wr && hst != H_CAP) begin
                shadow[ld_word] <= ld_data;
            end else if (ld_wr) begin
                ld_pend <= 1'b1; ld_pw <= ld_word; ld_pd <= ld_data;
            end else if (ld_pend && hst != H_CAP) begin
                shadow[ld_pw] <= ld_pd;
                ld_pend <= 1'b0;
            end

            case (hst)
                H_IDLE: begin
                    if (ioctl_upload && !upload_d && run && has_table) begin
                        capturing <= 1'b1; idx <= 8'd0; cap_lo <= 16'd0;
                        hs_pause <= 1'b1; settle <= 8'd64; rd_ph <= 2'd0;
                        hst <= H_SETTLE;
                    end else if (run && has_table && !poll_done && vbl_rise) begin
                        capturing <= 1'b0; gph <= 2'd0; sh_ok <= 1'b1;
                        sh_idx <= guard_idx(2'd0);
                        hs_pause <= 1'b1; settle <= 8'd64; rd_ph <= 2'd0;
                        hst <= H_SETTLE;
                    end
                end
                // let any in-flight CPU bus cycle finish before the borrow
                H_SETTLE: begin
                    settle <= settle - 8'd1;
                    if (settle == 0) hst <= capturing ? H_CAP : H_GUARD;
                end
                // walk the four guards: RAM byte must match; the shadow's
                // matching byte decides whether an inject may follow
                H_GUARD: begin
                    hs_addr <= cur_b[16:1];
                    rd_ph   <= (rd_ph == 2'd2) ? 2'd0 : rd_ph + 2'd1;
                    if (rd_ph == 2'd2) begin
                        if ((cur_b[0] ? hs_q[7:0] : hs_q[15:8]) != gv[gph]) begin
                            // not initialised yet: release, retry next vblank
                            hs_pause <= 1'b0; hst <= H_IDLE;
                        end else begin
                            if (sh_byte != gv[gph]) sh_ok <= 1'b0;
                            if (gph == 2'd3) begin
                                save_ready <= 1'b1;    // guards seen: saves on
                                if (sh_ok && (sh_byte == gv[gph]) && (inj_left != 10'd0)) begin
                                    idx <= 8'd0; sh_idx <= 8'd0; hst <= H_INJ;
                                end else begin
                                    poll_done <= 1'b1; hst <= H_DONE;
                                end
                            end else begin
                                gph    <= gph + 2'd1;
                                sh_idx <= guard_idx(gph + 2'd1);
                            end
                        end
                    end
                end
                // write the shadow over the table, one byte-lane write each
                H_INJ: begin
                    hs_addr  <= cur_b[16:1];
                    hs_wdata <= {sh_byte, sh_byte};
                    hs_be    <= lane_of(cur_b);
                    hs_we    <= 1'b1;
                    if (idx == total - 8'd1) begin
                        injected <= 1'b1;
                        inj_left <= inj_left - 10'd1;
                        // the window closing is the only thing that ends the
                        // poll now; save_ready is already up either way
                        if (inj_left == 10'd1) poll_done <= 1'b1;
                        hst <= H_DONE;
                    end else begin
                        idx <= idx + 8'd1; sh_idx <= idx + 8'd1;
                    end
                end
                // read the table into the shadow for the upload to stream
                H_CAP: begin
                    hs_addr <= cur_b[16:1];
                    rd_ph   <= (rd_ph == 2'd2) ? 2'd0 : rd_ph + 2'd1;
                    if (rd_ph == 2'd2) begin
                        if (!idx[0]) cap_lo[7:0] <= cur_b[0] ? hs_q[7:0] : hs_q[15:8];
                        else shadow[idx[7:1]] <= {(cur_b[0] ? hs_q[7:0] : hs_q[15:8]), cap_lo[7:0]};
                        if (idx == total - 8'd1) begin
                            // an odd total leaves the last byte unpaired
                            if (!idx[0])
                                shadow[idx[7:1]] <= {8'd0, cur_b[0] ? hs_q[7:0] : hs_q[15:8]};
                            hst <= H_DONE;
                        end else idx <= idx + 8'd1;
                    end
                end
                H_DONE: begin
                    hs_pause <= 1'b0;
                    hst <= H_IDLE;
                end
                default: hst <= H_IDLE;
            endcase
        end
    end

endmodule
