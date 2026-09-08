//============================================================================
//  Ray Force -- core self-test page
//
//  A 40x28 character pass/fail page over the 320x224 raster, so a bring-up
//  run on real hardware reports what worked instead of leaving a screen full
//  of unlabelled hex to be decoded by eye. Same idea as the Raiden II core's
//  self-test, and for the same reason: the download path, the SDRAM
//  controller, the CPU's memory decode and the interrupt handshake have no
//  simulation coverage, and those are exactly the blocks that fail silently.
//
//  The page is deliberately independent of the video chipset: it reads only
//  its own two ROMs, so it still renders when the renderer is half-written or
//  completely dead.
//
//  THE SAME CHARACTERS GO OUT THE UART. Port B of the page ROM and a second
//  copy of the value/status mux are brought out on (u_row, u_col) -> u_char,
//  and rf_uart_log walks that port. Serial and screen are the same page by
//  construction, not by two pieces of code that have to be kept in step.
//
//  Static text and the layout constants come from
//  tools/make_selftest_page.py -> rf_selftest_page.sv.
//============================================================================

import rf_selftest_pkg::*;

module rf_selftest #(
    parameter int H_START = 46,
    parameter int V_START = 31
) (
    input  logic        clk,
    input  logic  [2:0] div,          // clk/8 phase from the video timing
    input  logic  [8:0] hcnt,
    input  logic  [8:0] vcnt,

    // ---- what the page reports ------------------------------------------
    input  logic        dl_active,
    input  logic        dl_seen,
    // per-game expectations (0 = not measured for this game; see below)
    // which game the MRA says this is (Rayforce.sv "GAME CONFIG": the id is
    // {bit 5, bits 7:6}, so the field grew to three bits without changing
    // what any MRA written before it meant -- bit 5 is 0 in all of them).
    // Row 0 of the page is the game's name, not the core's history: the
    // titles live after the visible rows in rf_selftest_page.
    input  logic  [5:0] game_id,
    // High-score restore diagnostics, carried in the spare top bits of the
    // TRAP row: a 320x224 page is exactly 28 rows and has no 29th to give.
    input  logic        hs_sh_ok,      // shadow guards matched
    input  logic        hs_injected,   // the table was written into RAM

    input  logic [31:0] exp_bytes,
    input  logic [31:0] exp_sum,
    input  logic [31:0] exp_bist,
    input  logic [31:0] exp_hash,

    input  logic [31:0] dl_bytes,
    input  logic [31:0] dl_sum,
    input  logic [31:0] bist_sum,
    input  logic        bist_done,
    input  logic [31:0] wr_count,
    input  logic [31:0] wr_hash,
    input  logic [31:0] last_pc,
    input  logic        trap_oor,
    input  logic [15:0] frame_cnt,
    input  logic [15:0] irq2_cnt,
    input  logic [15:0] irq3_cnt,
    input  logic [15:0] irq2_rate,
    input  logic [15:0] irq3_rate,
    input  logic        irq_rate_valid,
    input  logic [15:0] pal_wr_cnt,
    input  logic [15:0] pal_wr_hi,     // DIAGNOSTIC: palette writes at and
    input  logic [15:0] pal_wr_lo,     //   above entry 0x1000, and below
    input  logic [15:0] pf_wr_cnt,
    input  logic [15:0] spr_wr_cnt,
    input  logic [15:0] line_wr_cnt,
    input  logic [15:0] txt_wr_cnt,
    input  logic [31:0] build_hex,
    input  logic [31:0] vid_lines,     // rf_video_pipe dbg_lines
    input  logic [31:0] vid_fetch,     // dbg_fetch
    input  logic [31:0] vid_max,       // dbg_max
    input  logic [31:0] vid_nz,        // dbg_nz
    // SEQUENCE INSTRUMENTS, rows 17-20 (see rf_video_spr.sv)
    input  logic [31:0] seq_rec01, seq_rec23, seq_nspr01, seq_nspr23,
    input  logic        _unused_seq,
    input  logic [31:0] vid_sfetch,    // dbg_sfetch {frames the draw never
                                       // finished, longest fetch (8-bit,
                                       // saturating), rows on the worst line}
    // DIAGNOSTIC, and REPURPOSED PER BUILD -- the row label in
    // tools/make_selftest_page.py is the authority on what it means today.
    // It has carried the sprite-framebuffer folds and the mixer pixel probe;
    // this build feeds it rf_main's cpu_spin, so the row reads
    // SPIN:TWRA:TWRB = {vblank spin-loop reads (real hardware: 764), tower
    // palette block A writes, tower palette block B writes}.
    input  logic [31:0] vid_sprpix,
    input  logic [31:0] vid_spr,       // dbg_spr
    input  logic [31:0] vid_rec,       // dbg_rec
    input  logic [31:0] snd_diag1,     // {pivot RAM writes, sound CPU PC[15:0]}
    input  logic [31:0] snd_diag2,     // {sound ES5505 writes, 0, sound CPU running}
    input  logic [31:0] snd_diag3,     // {sample BIST sum[15:0], sampler overruns[7:0], queue drops[7:0]}
    input  logic        smp_bist_done,
    input  logic        smp_bist_pass,

    // ---- pixel output ----------------------------------------------------
    output logic [23:0] rgb,

    // ---- character port for rf_uart_log ---------------------------------
    input  logic  [4:0] u_row,
    input  logic  [5:0] u_col,
    output logic  [7:0] u_char        // ascii, valid 2 clocks after the address
);

    // Expected values. Phase 0/1 established every one of these against MAME
    // or against tools/rf_stream_sum.py; they are constants here so the board
    // says PASS or FAIL by itself instead of handing back a number to compare.
    // Four of these are properties of the GAME's ROMs, not of the core, so
    // they arrive from the top level, selected by the game-config byte the
    // MRA supplies (Rayforce.sv, "GAME CONFIG"). A value of zero means "not
    // measured for this game yet": the row then reports the number it found
    // and passes once the check has finished, instead of failing against an
    // expectation nobody has established. That is the honest state for a
    // game whose oracle has not been run -- not a green light.
    localparam logic [31:0] EXP_WRC   = 32'h00001000;
    localparam logic [15:0] EXP_RATE  = 16'd64;      // one ack per frame

    localparam logic [1:0] ST_WAIT = 2'd0;
    localparam logic [1:0] ST_BUSY = 2'd1;
    localparam logic [1:0] ST_PASS = 2'd2;
    localparam logic [1:0] ST_FAIL = 2'd3;

    wire cpu_running = bist_done && !dl_active;

    // ---- "has it ever" verdicts for the per-frame video rows -------------
    // FETCH:PIX NZ, MAXFETCH:BUILD and TILE NZ:PF:PAL are latched once per
    // frame by rf_video_pipe, and a frame with no playfield on it -- the
    // notice screen, a scene cut, the black frame between attract loops --
    // has zero tile fetches, zero non-zero tiles and no longest fetch,
    // legitimately. Judged frame by frame those rows said FAIL on every such
    // frame (3 of 95 page passes in a 45 s attract capture, 2026-08-29),
    // which teaches the reader to ignore a red word that elsewhere on this
    // page means something. What the rows exist to prove is that the
    // pipeline CAN fetch tiles and make non-black pixels; once it has, that
    // is proven, so each verdict latches PASS the first frame its condition
    // holds and stays there. Until then it reads BUSY, the same idiom as the
    // VIDEO RAM WRITES rows (a check that has started and not yet
    // succeeded). The VALUE stays per-frame, so a blank frame still reads as
    // blank on the page; only the verdict is sticky.
    //
    // MAXFETCH:BUILD carries a real per-frame limit as well (longest
    // playfield build under the 3456-clock line budget), and that fault
    // latches the other way: one frame over budget is FAIL from then on.
    // Peak-held, like the sprite rows, because the page is read twice a
    // second and a one-frame overrun would otherwise never be seen.
    //
    // All three clear while the CPU is not running (a download or the BIST
    // in progress), so a re-download starts the proof over. No reset port:
    // that is the reset.
    logic fetch_seen, max_seen, max_over, nz_seen;
    always_ff @(posedge clk) begin
        if (!cpu_running) begin
            fetch_seen <= 1'b0; max_seen <= 1'b0; max_over <= 1'b0; nz_seen <= 1'b0;
        end else begin
            if (vid_fetch[15:0] != 16'd0)     fetch_seen <= 1'b1;
            if (vid_max[31:16]  != 16'd0)     max_seen   <= 1'b1;
            if (vid_max[15:0]   >= 16'd3456)  max_over   <= 1'b1;
            if (vid_nz[31:16] != 16'd0 && vid_nz[15:8] != 8'd0 && vid_nz[7:0] != 8'd0)
                                              nz_seen    <= 1'b1;
        end
    end

    // ---- value / status per row -----------------------------------------
    // Written out twice (once per read port) rather than as a function:
    // quartus_map 17.0 is unreliable elaborating functions in this design,
    // and the duplication is a plain mux either way.
    logic [31:0] val_a, val_b;
    logic  [1:0] sta_a, sta_b;
    logic  [4:0] row_a;
    logic  [5:0] u_col_q;              // port B address, registered once so
    logic  [4:0] u_row_q;              // the value mux and the field masks
                                       // are evaluated for the SAME cell

`define RF_ST_ROWS(ROW, VAL, STA)                                            \
    begin                                                                    \
        VAL = 32'h0; STA = ST_WAIT;                                          \
        case (ROW)                                                           \
        5'd3:  begin VAL = dl_bytes;                                         \
                 STA = !dl_seen  ? ST_WAIT :                                 \
                       dl_active ? ST_BUSY :                                 \
                       (exp_bytes == 32'd0 || dl_bytes == exp_bytes)          \
                                       ? ST_PASS : ST_FAIL; end              \
        5'd4:  begin VAL = dl_sum;                                           \
                 STA = !dl_seen  ? ST_WAIT :                                 \
                       dl_active ? ST_BUSY :                                 \
                       (exp_sum == 32'd0 || dl_sum == exp_sum)                \
                                       ? ST_PASS : ST_FAIL; end              \
        5'd5:  begin VAL = bist_sum;                                         \
                 STA = bist_done ? (((exp_bist == 32'd0) ||                   \
                                    (bist_sum == exp_bist)) ? ST_PASS : ST_FAIL) \
                     : (dl_seen && !dl_active) ? ST_BUSY : ST_WAIT; end      \
        5'd7:  begin VAL = snd_diag1;   /* PIVOT WR : SND PC */              \
                 STA = !cpu_running ? ST_WAIT :                              \
                       (snd_diag1[31:16] == 16'd0) ? ST_PASS : ST_FAIL; end  \
        5'd8: begin VAL = wr_hash;                                          \
                 STA = (wr_count == EXP_WRC) ?                               \
                         (((exp_hash == 32'd0) ||                            \
                           (wr_hash == exp_hash)) ? ST_PASS : ST_FAIL)       \
                     : (wr_count != 32'h0) ? ST_BUSY : ST_WAIT; end          \
        5'd9: begin VAL = {5'd0, hs_injected, hs_sh_ok,                      \
                              trap_oor, last_pc[23:0]};                      \
                 STA = trap_oor ? ST_FAIL :                                  \
                       cpu_running ? ST_PASS : ST_WAIT; end                  \
        5'd10: begin VAL = vid_rec;                                          \
                 STA = !cpu_running ? ST_WAIT :                              \
                       (vid_rec[15:0] == 16'd0) ? ST_PASS : ST_FAIL; end     \
        5'd12: begin VAL = snd_diag2;   /* SND ES WR : RUN */                \
                 STA = !cpu_running ? ST_WAIT :                              \
                       !snd_diag2[0] ? ST_WAIT :                             \
                       (snd_diag2[31:16] != 16'd0) ? ST_PASS : ST_BUSY; end  \
        5'd13: begin VAL = {irq2_rate, irq2_cnt};                            \
                 STA = !irq_rate_valid ? ST_WAIT :                           \
                       (irq2_rate == EXP_RATE) ? ST_PASS : ST_FAIL; end      \
        /* DIAGNOSTIC BUILD: this row was SMP BIST:OVR:DR, which is stable  \
           and passing and has nothing to do with the sprite colours. It is  \
           BORROWED, not deleted -- restore it (and the label in            \
           tools/make_selftest_page.py) once the sprite bug is closed. The   \
           row reports rather than judges: there is no expectation to check  \
           against in RTL, the comparison is against the model off-board. */ \
        5'd14: begin VAL = vid_sprpix;  /* STALELN:AGE:CNT*/                  \
                 STA = ST_PASS; end                                          \
        5'd16: begin VAL = {pal_wr_hi, pal_wr_lo};                           \
                 STA = (pal_wr_cnt  != 16'd0) ? ST_PASS :                    \
                       cpu_running ? ST_BUSY : ST_WAIT; end                  \
        /* DRAW VS MIXER -- the last four frames, newest first. On a paused   \
           glitch the prepass is proved identical frame to frame (RECSEQ and  \
           NSPRSEQ constant, 2026-09-07), so the fault is downstream of the   \
           record store. FOLDSEQ = rf_spr_fb's wr_fold, the sum of every      \
           sprite pixel the DRAW handed over that frame: X Y X Y here means   \
           the draw's output alternates. USEDSEQ = a hash of the per-line     \
           priority flags the draw published, which the MIXER composes with:  \
           X Y X Y here with FOLDSEQ constant means identical sprite pixels   \
           are being composed differently. No pass criterion: measurement. */ \
        5'd17: begin VAL = seq_rec01;  STA = !cpu_running ? ST_WAIT : ST_PASS; end \
        5'd18: begin VAL = seq_rec23;  STA = !cpu_running ? ST_WAIT : ST_PASS; end \
        5'd19: begin VAL = seq_nspr01; STA = !cpu_running ? ST_WAIT : ST_PASS; end \
        5'd20: begin VAL = seq_nspr23; STA = !cpu_running ? ST_WAIT : ST_PASS; end \
        5'd26: VAL = build_hex;                                              \
        /* SPRFETCH:ROWMAX -- {longest single sprite gfx fetch in clocks,   \
           most rows drawn on one line}. This row replaced MIX : BUILD,      \
           whose value is the constant 01000100 whenever the pipe runs at    \
           all and which MAXFETCH:BUILD and TILE NZ already imply; the page   \
           is exactly 28 rows over 224 lines, so a new row costs an old one. \
           It exists to divide the two explanations of a slow sprite line:   \
           many rows, or slow fetches. The draw loop is 17 clocks a row, and \
           the worst line in every dumped frame carries 61 rows -- but every  \
           dump is attract, and the board glitches in boss fights. No pass    \
           criterion: it is a measurement, and what counts as too slow is    \
           exactly what is not known yet. */                                 \
        5'd22: begin VAL = vid_sfetch;                                       \
                 STA = !cpu_running ? ST_WAIT : ST_PASS; end                 \
        5'd23: begin VAL = vid_fetch;   /* FETCH : PIX NZ  (sticky, above) */ \
                 STA = !cpu_running ? ST_WAIT :                              \
                       fetch_seen   ? ST_PASS : ST_BUSY; end                 \
        /* PREPASS OVR:END -- {frames where the prepass was STILL BUSY at   \
           frame_start, i.e. the sprite list was published before it was      \
           finished being built -- the direct test of the leading theory --,  \
           clocks from frame_start to the prepass going idle, in units of 16  \
           (a frame is ~DD00 of them; a value near that is a near miss)}.     \
           OVR must be 0. Borrowed from SPRTEAR, which did its job. */        \
        5'd25: begin VAL = vid_nz;   /* {0,rb,par, overruns[7:0], end} */     \
                 STA = !cpu_running          ? ST_WAIT :                     \
                       (vid_nz[23:16] != 0)  ? ST_FAIL : ST_PASS; end        \
        5'd24: begin VAL = vid_max;     /* MAXFETCH:BUILD  (sticky, above) */ \
                 STA = !cpu_running ? ST_WAIT :                              \
                       max_over     ? ST_FAIL :                              \
                       max_seen     ? ST_PASS : ST_BUSY; end                 \
        5'd27: begin VAL = vid_spr;   /* SPRLINE : LATE */                   \
                 /* Late lines are the fault. The LONGEST line is not:      \
                    the draw runs into a ring of 8 line buffers, so it       \
                    banks 7 quiet lines' slack on top of the line's own      \
                    3456 -- 27648 clocks -- and a single line well over      \
                    budget is drawn in full with nothing missing. Judging    \
                    it against 3456 called that FAIL: the board read         \
                    39D90000 (14809 clocks, ZERO late) as a failure. Only    \
                    a line past the whole ring's 27648 cannot be covered. */ \
                 STA = !cpu_running          ? ST_WAIT :                     \
                       (vid_spr[15:0] != 0)  ? ST_FAIL :                     \
                       (vid_spr[31:16] < 16'd27648) ? ST_PASS : ST_FAIL; end \
        default: ;                                                           \
        endcase                                                              \
    end

    always_comb `RF_ST_ROWS(row_a, val_a, sta_a)
    always_comb `RF_ST_ROWS(u_row_q, val_b, sta_b)   // same cycle as the masks

    // ---- character composition ------------------------------------------
    // "PASS" / "FAIL" / "WAIT" / "BUSY" as four 6-bit codes each (ascii-0x20).
    function automatic logic [5:0] st_char(input logic [1:0] st, input logic [1:0] i);
        logic [31:0] word;
        case (st)
            ST_PASS: word = "PASS";
            ST_FAIL: word = "FAIL";
            ST_BUSY: word = "BUSY";
            default: word = "WAIT";
        endcase
        st_char = 6'(word[8*(3-i) +: 8] - 8'h20);
    endfunction

    function automatic logic [5:0] hex_char(input logic [3:0] n);
        hex_char = (n < 4'd10) ? 6'(6'd16 + n)          // '0' is 0x30-0x20
                               : 6'(6'd33 + n - 6'd10); // 'A' is 0x41-0x20
    endfunction

    // Port A: the pixel renderer. Port B: the UART.
    logic [10:0] pg_a_addr, pg_b_addr;
    logic  [5:0] pg_a_char, pg_b_char;

    rf_selftest_page page (
        .clk(clk),
        .a_addr(pg_a_addr), .a_char(pg_a_char),
        .b_addr(pg_b_addr), .b_char(pg_b_char)
    );

    // ---- port B (UART) ---------------------------------------------------
    always_ff @(posedge clk) begin
        u_col_q <= u_col;
        u_row_q <= u_row;
    end
    // Any id without a title of its own falls to the last one, so the game-id
    // field covers the whole F3 library (35 parent sets) while the page ROM
    // carries only the titles actually written.
    wire [5:0] title_ix  = (game_id >= 6'(ST_TITLES - 1)) ? 6'(ST_TITLES - 1) : game_id;
    wire [5:0] b_row_eff = (u_row == 0) ? 6'(ST_ROWS + title_ix) : 6'(u_row);
    assign pg_b_addr = 11'(b_row_eff * ST_COLS + u_col);

    wire       u_in_val = ST_VAL_ROWS[u_row_q] &&
                          (u_col_q >= ST_VAL_C0) && (u_col_q < ST_VAL_C0 + ST_VAL_W);
    wire       u_in_st  = ST_ST_ROWS[u_row_q] &&
                          (u_col_q >= ST_ST_C0) && (u_col_q < ST_ST_C0 + ST_ST_W);
    wire [2:0] u_vi     = 3'(u_col_q - ST_VAL_C0[5:0]);
    wire [1:0] u_si     = 2'(u_col_q - ST_ST_C0[5:0]);
    wire [5:0] u_code   = u_in_val ? hex_char(val_b[4*(3'd7 - u_vi) +: 4])
                        : u_in_st  ? st_char(sta_b, u_si)
                                   : pg_b_char;
    assign u_char = 8'h20 + {2'b00, u_code};

    // ---- port A (screen) -------------------------------------------------
    // Fetched on the div phases, the same shape the palette panel uses: the
    // page ROM and the font ROM are each one clock, and a character cell is
    // 64 clocks wide, so there is room to spare. The cell is taken from the
    // pixel ce_pix is about to present, not the one on screen now.
    wire [8:0] xn = hcnt + 9'd1 - H_START[8:0];
    wire [8:0] yv = vcnt - V_START[8:0];
    wire       in_page = (xn < 9'd320) && (yv < 9'd224);

    // Outside the page xn/yv have wrapped, so row/col are clamped to a blank
    // row before they index the ROM or the row-mask constants.
    wire [5:0] col_n = in_page ? xn[8:3] : 6'd0;
    wire [4:0] row_n = in_page ? yv[7:3] : 5'd2;
    wire [2:0] gcol  = xn[2:0];
    wire [2:0] grow  = yv[2:0];

    wire [5:0] a_row_eff = (row_n == 0) ? 6'(ST_ROWS + title_ix) : 6'(row_n);
    assign pg_a_addr = 11'(a_row_eff * ST_COLS + col_n);
    always_comb row_a = row_n;

    wire       a_in_val = ST_VAL_ROWS[row_n] &&
                          (col_n >= ST_VAL_C0) && (col_n < ST_VAL_C0 + ST_VAL_W);
    wire       a_in_st  = ST_ST_ROWS[row_n] &&
                          (col_n >= ST_ST_C0) && (col_n < ST_ST_C0 + ST_ST_W);
    wire [2:0] a_vi     = 3'(col_n - ST_VAL_C0[5:0]);
    wire [1:0] a_si     = 2'(col_n - ST_ST_C0[5:0]);
    wire [5:0] a_code   = a_in_val ? hex_char(val_a[4*(3'd7 - a_vi) +: 4])
                        : a_in_st  ? st_char(sta_a, a_si)
                                   : pg_a_char;

    logic [5:0] font_code;
    logic [2:0] font_row;
    wire  [7:0] font_bits;

    rf_font8x8 font (.clk(clk), .code(font_code), .row(font_row), .bits(font_bits));

    // Colour by field: headers cyan, labels grey, values white, and the
    // status word carries the verdict so a failure is visible from across
    // the room.
    localparam logic [23:0] C_HEAD  = 24'h50D0F0;
    localparam logic [23:0] C_LABEL = 24'hB0B0B0;
    localparam logic [23:0] C_VALUE = 24'hFFFFFF;
    localparam logic [23:0] C_PASS  = 24'h40E040;
    localparam logic [23:0] C_FAIL  = 24'hFF4040;
    localparam logic [23:0] C_WAIT  = 24'hE0C040;
    localparam logic [23:0] C_BG    = 24'h101828;

    logic [23:0] cell_col;
    always_comb begin
        if (a_in_st)
            cell_col = (sta_a == ST_PASS) ? C_PASS :
                       (sta_a == ST_FAIL) ? C_FAIL : C_WAIT;
        else if (a_in_val)                cell_col = C_VALUE;
        else if (row_n <= 5'd1)           cell_col = C_HEAD;
        else if (pg_a_char == 6'd13)      cell_col = C_HEAD;   // '-' rule rows
        else                              cell_col = C_LABEL;
    end

    logic [23:0] fg_q;
    logic [2:0]  bit_q;
    logic        page_q;

    always_ff @(posedge clk) begin
        case (div)
            // div 0 is the clock the cell address changes on, so the page ROM
            // output is only good from div 1; latch at div 2 and the font ROM
            // then has until div 7 to answer.
            3'd2: begin
                font_code <= a_code;
                font_row  <= grow;
                fg_q      <= cell_col;
                bit_q     <= gcol;
                page_q    <= in_page;
            end
            3'd7: rgb <= (page_q && font_bits[3'd7 - bit_q]) ? fg_q : C_BG;
            default: ;
        endcase
    end

endmodule
