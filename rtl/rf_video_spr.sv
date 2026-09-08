//============================================================================
//  Sprite engine: the walked list, drawn per screen line into a line buffer.
//
//  No framebuffer. The measurement in HANDOFF.md showed Ray Force never uses
//  sprite trails and never exceeds a few tens of sprites on a line, so a
//  full-screen 16-bit framebuffer (~160 BRAM) is not needed. Instead:
//
//    PREPASS (once per frame, runs the whole frame long, off the beam):
//      1. rf_video_spr_list walks sprite RAM -> a compact sprite list.
//      2. EXPAND: each sprite is spread over the screen lines it covers. The
//         dy8 accumulator maps its 16 source rows (walked 15->0) to screen
//         lines; EVERY in-range row becomes a record appended to that line's
//         bucket (a linked list: head/tail per line, a next pointer per
//         record). No vertical dedup -- when zoom crushes several rows onto
//         one line they OVERLAY, a later row filling the transparent gaps of
//         an earlier one. Row order (15->0) and sprite order (list order) are
//         chosen so the bucket, drawn head->tail with overwrite, lands the
//         LAST write on the model's winner (forward-row / reverse-list
//         write-if-empty, first opaque wins).
//
//    DRAW (runs AHEAD of the mixer, into a ring of NB line buffers):
//      from frame_start, draw lines 0..255 in order as fast as the fetches
//      allow, up to NB-1 lines ahead of the line the mixer is composing
//      (rd_line) -- the bank the mixer reads is the one bank the draw may
//      not touch. The first version drew exactly one line per raster line,
//      so a dense line had one line's 3456 clocks and no more; the board
//      showed 3582-clock lines in attract mode and lost the next line each
//      time. The buckets are ready for the whole frame and sprites cost
//      ~10 % of it on average, so only local density matters, and a ring
//      of NB absorbs NB-1 consecutive dense lines.
//      Per line: walk the line's bucket; for each record fetch its 16-pixel sprite row
//      (rf_spr_gfx_bus) and lay it down with the dx8 accumulator -- x zoom,
//      the "last source pixel wins a shared screen pixel" dedup, flipx, the
//      pen mask, the colour base -- overwriting, into a double-banked line
//      buffer the mixer samples at smp_x. TWO fetches are kept in flight:
//      two rf_spr_gfx_bus instances take alternate records and a two-slot
//      queue hands them to the draw in issue order (the order is what the
//      overwrite semantics rest on). With one fetch in flight a record cost
//      the whole SDRAM round trip (~30 clocks on the board: two bursts on
//      the lowest-priority channel plus the CDC both ways) and a 114-record
//      line overran the 3456-clock budget; with two, the channel is kept
//      busy and the 17-clock draw is the bound. sim/Makefile `pipe-lat`
//      is the regression for this at a hardware-like latency.
//
//  The bucket store is DOUBLE BANKED: the prepass fills one bank across the
//  whole frame while the draw reads last frame's bank, swapped at frame_start.
//  So sprites lag the playfields by one frame here; MAME's sprite_lag for
//  gunlock is 2 -- close, tuned on hardware if it reads wrong, the same way
//  the raster timing was. Prepass and draw are separate always blocks: the
//  buckets have a single writer (the prepass, into the write bank) and the
//  draw only reads (the read bank), so there is no multi-driver on the store.
//
//  The line buffer needs no clearing: each entry tags the line it was written
//  for, and a read for another line reads as empty. Zoom is reproduced
//  exactly (dy8/dx8), which Ray Force needs -- it shrinks sprites to a line.
//
//  Storage -- sized for the MLAB budget, which is the binding one. A record
//  is a RUN: {sprite index, first source row, last source row} (18 bits),
//  the consecutive source rows of one sprite that land on the same screen
//  line. A y-shrunk sprite puts several of its 16 rows on one line, and the
//  draw lays them down back to back in the same order either way, so one
//  record for the run costs no exactness and no draw time -- only store.
//  Measured over every Ray Force dump (2026-08-29): 1.0-1.3 rows a record in
//  ordinary play, 2.8-3.25 in the shrink-heavy scenes (frame 4200: 2960 rows
//  -> 1046 records), and it is the shrink scenes that set the board's peak.
//  The per-sprite data (x, x scale, code, colour, flipx) is stored ONCE, in
//  sl_d, and looked up by the draw. The list is split by consumer: sl_y (ty, y scale, flipy) is read
//  only by the expand, in the same prepass that wrote it, so it is
//  single-banked; sl_d is read by the draw a frame later, so it is
//  double-banked like the record store. The buckets are built by counting
//  sort (see the store below), so there are no per-line heads, tails or
//  next pointers -- one run table per bank, in an rf_bram.
//
//  History: the first version stored 54-bit records in linked lists and at
//  3328 records/bank needed 960 of the device's 985 MLAB-capable LABs; the
//  second slimmed the records and reached 4096; this one drops the links
//  and holds 8192 in the same ~780 MLABs.
//
//  MLAB rules (each learned from a failed map): one full-word read wire per
//  memory, sliced afterwards; `no_rw_check` because the async-read MLAB has
//  no defined same-cycle same-address read-during-write -- so the RTL never
//  does one. rec/sl_d: the prepass writes bank wb, the draw reads bank rb.
//  sl_y: written in P_WALK, read in P_C0/P_E0. cnt/lim: every read-modify-
//  write is a read state followed by a write state (P_CRD/P_CWR, P_SRD/
//  P_SWR, P_ERD/P_EWR). One write per array per cycle throughout.
//
//  The two gfx planes share the one free SDRAM channel through
//  rf_spr_ch_share at the top level (the bench wraps the pipe the same way).
//============================================================================

module rf_video_spr
(
    input  logic        clk,
    input  logic        reset,
    // TEARING INSTRUMENT: the CPU's sprite-RAM write strobe. See rf_main.sv.
    input  logic        spr_wr_stb,
    output logic [15:0] tear_cnt,       // writes landing DURING the walk
    output logic [15:0] tear_frames,    // frames in which that happened
    // SEQUENCE INSTRUMENTS (2026-09-07). Every sprite counter on the page is
    // PEAK-HELD, and a peak cannot see an alternation: a frame that builds
    // 6,500 records and one that builds 3,000 leave the same 6,500 behind.
    // The board's corruption is exactly that -- two renderings alternating on
    // a static scene -- so these report the last FOUR frames as a sequence,
    // newest first. Healthy: four similar numbers drifting with the action.
    // The bug: X Y X Y.
    output logic [31:0] seq_rec01,      // {records built, frame n  , frame n-1}
    output logic [31:0] seq_rec23,      // {                frame n-2, frame n-3}
    output logic [31:0] seq_nspr01,     // {sprites walked, n, n-1}  -- splits the
    output logic [31:0] seq_nspr23,     // {                n-2, n-3} walk from the fill
    // {frames where the prepass was STILL BUSY at frame_start -- the direct
    //  test of "the list was not finished being built" -- ,
    //  clocks from frame_start to the prepass going idle, in units of 16
    //  (a frame is ~0xDD00 of them, so a reading near that is a near miss)}
    output logic [31:0] seq_ovr,
    // USEDSEQ: a rotate-xor hash of every used_line[par][*] value the draw
    // published this frame, last four frames newest first. The prepass has
    // been proved identical frame to frame on a paused glitch (RECSEQ and
    // NSPRSEQ constant), so the fault is downstream. This says whether the
    // per-line priority-group flags -- which the MIXER uses to decide what is
    // in front, and which are double banked by frame parity -- differ between
    // the two parities. X Y X Y here = the mixer is composing alternate frames
    // differently from IDENTICAL sprite pixels.
    output logic [31:0] seq_used01,
    output logic [31:0] seq_used23,
    input  logic        clk_ram,

    // which F3 visarea this game uses; feeds the sprite cull bounds
    input  logic  [1:0] vis_mode,

    input  logic        frame_start,    // swap banks, start a fresh prepass
    output logic        prepass_busy,
    output logic        line_busy,      // a line is being drawn (drops for
                                        // one cycle between lines)
    output logic  [8:0] lines_done,     // lines drawn so far this frame, 0-256
    // The flipscreen bit, straight from the sprite command word (word 5 bit
    // 13) -- the same place MAME takes m_flipscreen from. The playfields and
    // the pivot layer need it too, and it must be the GAME's bit rather than
    // a constant: Ray Force sets it permanently, Elevator Action Returns does
    // not, and this core had it wired to 1, so that game rendered upside down.
    output logic        o_flipscreen,

    output logic [15:0] rec_peak,       // records the last prepass built
    output logic [15:0] rec_drop,       // sprite rows it had no room for
    // Why a line is slow, which the clock count alone cannot say: is it
    // carrying a lot of rows, or is each row's fetch slow? SPRLINE says a
    // line took 15864 clocks; the worst line in every dumped frame carries
    // only 61 rows, and the draw loop is 17 clocks a row, so either the
    // board's lines are far denser than any dump (all of them are attract)
    // or a row costs ~260 clocks and is almost all fetch wait. These two
    // numbers divide one case from the other.
    output logic [15:0] fetch_max,      // longest single gfx fetch, in clocks
    output logic [15:0] rows_line_max,  // most rows drawn on one line
    // FETCH SELF-CHECK (rf_spr_gfx_bus): tile rows where a re-fetch from
    // SDRAM disagreed with the cached copy of the same immutable ROM row.
    // Any non-zero value is fetch corruption, counted across both buses.
    output logic [15:0] fetch_bad,

    // ---- DIAGNOSTIC ------------------------------------------------------
    // The draw's frame_start handler says "in normal running the draw
    // finished line 255 long ago". On Darius Gaiden's first zone the board
    // reports 38485 late lines with a longest line of 8656 clocks against a
    // 3456-clock budget, so that assumption is worth measuring rather than
    // asserting. This counts the frames in which frame_start arrived with
    // lines still undrawn -- the draw is then restarted at line 0 with the
    // record and sprite-list banks swapped under it (rb <= wb below).
    output logic  [7:0] draw_unfinished,
    // Cap the sprite rows drawn on one line: 0 = no cap, 1 = 256, 2 = 128,
    // 3 = 8 (a deliberate stress setting; see cap_rows).
    // A workload cap is the direct test of whether lateness is what breaks
    // the picture -- if the colours come right when the line is forced to
    // fit its budget (at the cost of sprites the cap throws away), the
    // mechanism is the overrun and not the drawing.
    input  logic  [1:0] row_cap,

    output logic [14:0] spr_addr,       // sprite RAM (walker)
    input  logic [15:0] spr_q,

    // sprite gfx SDRAM: two fetch buses (A, B) of two planes (lo, hi) each,
    // merged onto one channel by rf_spr_ch_share outside this module
    output logic [26:1] ch_a_lo_addr,
    input  logic [63:0] ch_a_lo_dout,
    output logic        ch_a_lo_req,
    input  logic        ch_a_lo_ready,
    output logic [26:1] ch_a_hi_addr,
    input  logic [63:0] ch_a_hi_dout,
    output logic        ch_a_hi_req,
    input  logic        ch_a_hi_ready,
    output logic [26:1] ch_b_lo_addr,
    input  logic [63:0] ch_b_lo_dout,
    output logic        ch_b_lo_req,
    input  logic        ch_b_lo_ready,
    output logic [26:1] ch_b_hi_addr,
    input  logic [63:0] ch_b_hi_dout,
    output logic        ch_b_hi_req,
    input  logic        ch_b_hi_ready,

    input  logic  [7:0] rd_line,        // line the mixer is composing
    output logic  [3:0] rd_used,        // priority groups present on it

    // ---- the line just finished, for rf_spr_fb to stream to DDR3 --------
    // The draw no longer races the raster: it fills one bank while the
    // framebuffer writer empties the other, and a line is published by
    // handing it over here rather than by the mixer catching up to it.
    output logic        o_par,          // parity of the frame being drawn
    output logic        fb_req,         // pulse: fb_line is ready in the
    output logic  [7:0] fb_line,        //        bank the writer may read
    output logic  [3:0] fb_used,        // that line's priority groups, handed
                                        // over with it: rd_used reports the
                                        // frame being SHOWN, so it cannot
                                        // answer for the line just drawn
    input  logic        fb_busy,        // writer still emptying the other
    input  logic  [8:0] fb_addr,        // writer's read port into the buffer
    output logic [15:0] fb_q,
    // sprite gfx region bases (SDRAM map profile, see cfg_map)
    input  logic [26:1] gfx_base_lo,
    input  logic [26:1] gfx_base_hi
);
    // Visible span. X is the same for every F3 game; the Y pair is the
    // game's visarea and MUST follow vis_mode -- it is the per-row clip that
    // matches the model's _drawgfx, so a window narrower than the game's
    // real one silently drops sprite rows on the lines outside it (Elevator
    // Action Returns shows 24..255 where Ray Force shows 31..254).
    localparam int VX0 = 46, VX1 = 365;
    wire [8:0] VY0 = (vis_mode == 2'd0) ? 9'd31 :
                     (vis_mode == 2'd1) ? 9'd32 : 9'd24;
    wire [8:0] VY1 = (vis_mode == 2'd0) ? 9'd254 :
                     (vis_mode == 2'd2) ? 9'd247 : 9'd255;
    localparam int NSPR = 1024;

    // ---- the walker ------------------------------------------------------
    logic        wk_start, wk_busy, wk_done;
    logic        wk_flip; logic [1:0] wk_extra; logic [5:0] wk_penmask;
    logic        s_valid;
    logic signed [17:0] s_tx, s_ty;
    logic        [8:0]  s_sx, s_sy;
    logic       [16:0]  s_code;
    logic        [7:0]  s_color;
    logic               s_fx, s_fy;
    logic        [1:0]  s_pri;

    rf_video_spr_list walker (
        .clk(clk), .reset(reset), .vis_mode(vis_mode),
        .start(wk_start), .start_bank(1'b0), .busy(wk_busy), .done(wk_done),
        .o_flip(wk_flip), .o_extra(wk_extra), .o_penmask(wk_penmask),
        .spr_addr(spr_addr), .spr_q(spr_q),
        .s_valid(s_valid), .s_tx(s_tx), .s_ty(s_ty), .s_sx(s_sx), .s_sy(s_sy),
        .s_code(s_code), .s_color(s_color), .s_fx(s_fx), .s_fy(s_fy), .s_pri(s_pri)
    );

    // ---- stored sprite list, split by consumer ---------------------------
    // sl_y: {ty[17:0], sy[8:0], fy}                 -- the expand (prepass)
    // sl_d: {tx[17:0], sx[8:0], code[16:0], color[7:0], fx} -- the draw
    // CODE IS 17 BITS, not 15. rf_video_spr_list already produces all
    // seventeen ({w[5][0], w[0]}, the same field MAME reads) and this
    // stored only fifteen, which reaches 2^15 * 128 = 4 MB of sprite ROM.
    // Ray Force has exactly 4 MB so nothing ever showed it, but every F3
    // set with more -- twelve of them, up to Kaiser Knuckle's 13 MB -- had
    // most of its sprite graphics unaddressable. 17 bits reaches 16 MB,
    // which covers the whole library. 51 -> 53 bits is still three MLAB
    // lanes of 20, so the store costs exactly what it did.
    // M10K, not MLAB: its read is registered (sly_q), so it does not need
    // the async read the MLAB arrays below are chosen for. 1024 x 28 bits is
    // 3 M10Ks against 64 MLABs, and M10K is the resource with headroom.
    (* ramstyle = "M10K, no_rw_check" *) logic [27:0] sl_y [0:NSPR-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [52:0] sl_d [0:1][0:NSPR-1];
    logic [10:0] nspr;

    // ---- bucket store, double banked: a COUNTING SORT ---------------------
    // Pass 1 counts the rows landing on each line, a prefix sum hands every
    // line a contiguous run [base, end) of the record store, pass 2 places
    // each row at its line's fill pointer. Rows are visited in the same
    // order both passes (list order, rows 15->0), so a run IS the bucket in
    // draw order. No linked list and no next pointers: that is what pays
    // for 8192 records per bank at the MLAB cost of 4096 linked ones.
    //
    // Overflow: the prefix sum clamps each line's run to what is left, in
    // line order, so a frame past NREC rows loses rows from its LAST lines
    // and reports them on the self-test page (rec_drop). That is the same
    // visible symptom as the sprite fetch running late -- sprites missing
    // from the bottom of the frame -- so when the bottom goes, read
    // SPR REC : DROP before blaming the fetch path.
    //
    // Sizing history. The busiest dumped frame needs 3144 rows; the BOARD
    // peaked at 8296 in a five-minute attract capture (2026-08-28) and
    // dropped 104 rows once in 632 page passes, which 8192 could not hold.
    // 12288 was chosen as ~45 % over that. It is not: a longer run on
    // 2026-08-29 (build 29101900) peaked at 10714 rows, 87 % of the store,
    // with 0 dropped -- 13 % margin, not 45 %. Whether the game ever asks
    // for more than 12288 is unknown; nothing has yet.
    //
    // Growing it is not free to try. An MLAB is 32 x 20 bits, so this store
    // is 2 x 384 = 768 MLABs at 18 bits a record (two bits of every word
    // unused, and no narrower packing fits: 64 x 10 mode is too narrow).
    // 16384 would be 1024. Run-length records (2026-08-29) are the cheaper
    // answer: the same 12288 slots hold 1.0-3.25x the rows they used to. The fitter has already died once at ~960 MLABs
    // in this design (HANDOFF, "The BRAM wall had moved into the MLABs")
    // and no fit report since B15 records the real headroom, so raising
    // NREC is a 35-minute build to find out, and it should be its own
    // build rather than confound one that is testing something else.
    // M10K is not an alternative either: 24 blocks a bank against ~26 free.
    //
    // 12288 -> 10240, 2026-08-31, because THE BINDING RESOURCE MOVED. The
    // note above reasons about MLAB count; the fitter now dies on ALMs. A
    // build on this date failed outright at 41,932 / 41,910 ALMs (100 %),
    // and the fit report puts THIS STORE at 7,996 of them -- 19 % of the
    // whole device, the single largest block in the design. 768 MLABs at
    // ~10.4 ALMs each is what an 18-bit record in a 32x20 MLAB costs.
    //
    // The old 10714 peak that justified 12288 was measured in ROWS, before
    // run-length records landed the same day (2026-08-29); it cannot be
    // compared against a record count. Re-measured on the board with the
    // record encoding: Ray Force peaks 4462 (SPR REC 116E, 0 dropped) and
    // Elevator Action Returns 8645 (21C5, 0 dropped), the higher of the
    // two. 10240 keeps 18 % over the worst case actually observed and
    // returns ~1300 ALMs, which is what makes the design fit again.
    //
    // If a game ever does exceed this, it is not silent: the prefix sum
    // clamps in line order, so rows go missing from the BOTTOM of the frame
    // and rec_drop counts them on the self-test page. Read SPR REC : DROP
    // before blaming anything else.
    // Back to 10240 after 9728 was tried and the fit got WORSE (4321 LABs
    // against 4201), which is the clearest evidence that at this utilisation
    // the fitter's variance is bigger than these reductions -- shrinking the
    // store by 512 records cannot cost 120 LABs. 10240 is the size with a
    // reason behind it: 18 % over EAR's measured 8645-record peak, where
    // 9728 left only 12.5 %. Overflow drops rows from the BOTTOM of the
    // frame and rec_drop counts them on the page, so it fails loudly.
    // MEASURED ON HARDWARE, Zone 2 boss, 2026-09-03: the game builds
    // **10,836 records** and the store DROPPED 646 of them. A dropped record
    // is a sprite row that never gets drawn, which is exactly the broken,
    // dotted wireframe the boss renders with -- the lines come out as
    // dashes and loose specks.
    //
    // 1d49395 CUT this from 12288 to 10240 on peaks of 6517 (Ray Force) and
    // 8645 (Elevator Action Returns), concluding "36 % spare". Every one of
    // those numbers was ATTRACT MODE. No dump or capture in this project had
    // ever contained a boss, so the sizing was derived from a workload that
    // does not include the heaviest scene in the game. The heavy MAME frame
    // added the same night (dump/rf_heavy, 344 sprite rows) still only
    // reaches 2190 records -- a fifth of what the boss needs.
    //
    // 13312 was tried first (23 % headroom) and the fitter threw Error
    // 11802, can't fit -- +173 MLABs is more than tying off the
    // scandoubler FX gives back. 12288 is +115 and clears the measured
    // peak by 13 %. If a later zone still overflows, the room has to come
    // from moving sl_d out of MLABs into M10K the way sl_y went in
    // 1d49395; there is no slack left to take otherwise.
    // This is self-verifying: SPR REC : DROP's low half counts dropped
    // rows, so a later zone that still overflows says so on the page.
    // Paid for by tying off the
    // scandoubler FX (Rayforce.sv), which folds the framework's Hq2x block
    // away; rec and sl_d are the only MLAB consumers in the design and LABs
    // were at 4187/4191, so the room had to come from somewhere.
    // ROOT CAUSE OF THE SPRITE CORRUPTION, found 2026-09-08 in the map report:
    //
    //   rec_rtl_0:  WIDTH 18,  WIDTHAD 14,  NUMWORDS 16384
    //
    // rec is declared [0:1][0:NREC-1] -- 2 x 12288 = 24576 words, needing 15
    // address bits. Quartus inferred a 16384-word RAM with a 14-bit address:
    // wb * NREC + f_rd truncated to 14 bits. Bank 0 is words 0..12287; bank 1
    // should be 12288..24575 but the top third does not exist, so BANK 1's
    // RECORDS FROM 4096 UP ALIAS ONTO BANK 0's RECORDS 0..8191. Every frame
    // that builds more than 4096 records has its tail clobber the other
    // bank's head -- and that threshold is the whole reported behaviour:
    //   attract        ~3-4k records   clean
    //   continue screen  4,587         slightly corrupt   (what was captured)
    //   zone 2 boss     10,836         severe
    // At the committed NREC = 10240 the threshold was 6144, so the continue
    // screen was clean there and only the boss showed it: "GitHub has fewer
    // streaks but not none". Raising NREC to 12288 to stop the boss drops
    // LOWERED the threshold to 4096: "it got worse when the core expanded".
    // The simulator models all 24576 words, so every bench passed.
    //
    // 24576 real words is +256 MLABs, and an MLAB is a LAB, on a device at
    // 4185/4191 -- the truncation is WHY it fit. So the store is sized to
    // exactly the RAM Quartus builds: 2 x 8192 = 16384 = 2^RW, where no
    // address can alias. The cost is graceful row DROPS on the very heaviest
    // boss frames (rec_drop counts them), which is far better than rows
    // ALIASED. Any future NREC must satisfy 2*NREC <= 2^RW, or RW must grow
    // -- and the map report's NUMWORDS for rec_rtl_0 must be checked.
    localparam int NREC = 8192;         // per bank -- see above before changing
    localparam int RW   = 14;           // record index width
    localparam int RW1  = RW + 1;       // the prefix sum reaches NREC
    // record: {sidx[9:0], srow_a[3:0], srow_b[3:0]} -- the run's first and
    // last source row. The draw steps from a toward b, so the direction
    // (rows walk 15 -> 0, and flipy inverts the source row) is implied.
    (* ramstyle = "MLAB, no_rw_check" *) logic [17:0]   rec [0:1][0:NREC-1];
    // per line, prepass scratch: rows counted (pass 1), then the fill
    // pointer (pass 2); and the clamped end of the line's run
    (* ramstyle = "MLAB, no_rw_check" *) logic [RW-1:0] cnt [0:255];
    (* ramstyle = "MLAB, no_rw_check" *) logic [RW-1:0] lim [0:255];
    logic [15:0] rows_tot;              // records the frame asked for
    logic [15:0] drop_cnt;              // records refused (store full)
    logic        wb, rb;                // write (prepass) / read (draw) bank
    logic  [5:0] penmask_r;                 // 6bpp: pens run 0..63
    // BISECT SWITCH 2 (2026-09-07): the pen mask was widened 5 -> 6 bits in
    // uncommitted work. It decides which pen values are opaque, and the
    // corruption is 95 % same-geometry/different-COLOUR, so a mask that lets
    // the top pen bit through changes colours without moving anything.
    //   PENMASK6 = 1  working tree (6-bit mask)
    //   PENMASK6 = 0  committed    (top bit forced off)
    localparam bit PENMASK6 = 1'b1;
    wire   [5:0] penmask_e = PENMASK6 ? penmask_r : {1'b0, penmask_r[4:0]};
    logic        flip_r;
    // Published continuously rather than registered again: two always_ff
    // blocks assigning it is a multiple-driver error in Quartus (Verilator
    // only warns), and flip_r already holds exactly the value.
    assign o_flipscreen = flip_r;

    // the draw's run table: {end, base} per line, written by the prefix
    // pass into bank wb, read by the draw at {rb, nxt} -- data the cycle
    // after the address, so it is presented during D_IDLE
    logic            bt_we;
    logic      [8:0] bt_wa;
    logic [2*RW-1:0] bt_wd, bt_q;

    rf_bram #(.WIDTH(2*RW), .AW(9)) u_bt (
        .clk(clk),
        .waddr(bt_wa), .wdata(bt_wd), .wren(bt_we),
        .raddr({rb, nxt[7:0]}), .q(bt_q)
    );

    // ---- prepass state ---------------------------------------------------
    logic [10:0] ex_i;
    logic  [4:0] ex_yy;
    logic signed [24:0] ex_dy8;
    logic        [8:0]  ex_sy;
    logic               ex_fy;
    logic  [8:0] clr_i;                 // cnt clear, runs under the walk
    logic        wk_fin;                // the walk finished (clear may not have)
    logic  [7:0] sum_y;
    logic [RW:0] sum_acc;               // one bit wider: reaches NREC
    logic [RW-1:0] c_rd, f_rd, l_rd;    // MLAB reads, taken the cycle before use
    // the run being built (r_*) and the one being emitted (e_*). A row that
    // lands on a new line closes the open run into e_* and opens the next
    // in r_* in the same cycle, so the two must be separate registers.
    logic        r_open;
    logic  [7:0] r_dy, e_dy;
    logic  [3:0] r_a, r_b, e_a, e_b;
    logic        ret_end;               // after the emit: sprite end, not next row

    wire signed [24:0] ex_dy   = ex_dy8 >>> 8;
    wire               ex_inr  = (ex_dy >= $signed({16'd0, VY0})) &&
                                 (ex_dy <= $signed({16'd0, VY1}));
    wire  [7:0]        ex_dyb  = ex_dy[7:0];
    wire  [3:0]        ex_srow = ex_yy[3:0] ^ {4{ex_fy}};

    // One full-word read wire per memory, sliced afterwards: Quartus will not
    // infer an MLAB from N separately-sliced reads of the same array (the
    // build died on exactly that -- "can't infer memory for variable 'slist'"),
    // this is the canonical pattern it accepts.
    // sl_y is read through a REGISTER, which is what lets it live in an M10K
    // instead of costing 64 MLABs -- and an MLAB is a whole LAB, the resource
    // the fitter actually runs out of. The read is unconditional, so sly_q
    // holds sl_y[ex_i] one clock after ex_i settles; P_C0W / P_E0W are that
    // clock. Only SPR_LOAD_EX consumes these, and only from those states.
    logic [27:0]       sly_q;
    always_ff @(posedge clk) sly_q <= sl_y[ex_i];
    wire signed [17:0] sly_ty = sly_q[27:10];
    wire        [8:0]  sly_sy = sly_q[9:1];
    wire               sly_fy = sly_q[0];

    // the prefix sum's clamp: what is left of the store for this line
    wire [RW:0]   sum_left = (sum_acc >= RW1'(NREC)) ? '0 : RW1'(NREC) - sum_acc;
    wire [RW:0]   sum_cap  = ({1'b0, c_rd} > sum_left) ? sum_left : {1'b0, c_rd};
    wire [RW:0]   sum_end  = sum_acc + sum_cap;

    // ---- draw state ------------------------------------------------------
    logic  [4:0] dr_xx;
    logic signed [24:0] dr_dx8;
    logic        [8:0]  dr_sx;
    logic       [12:0]  dr_base;
    logic        [1:0]  dr_pri;
    logic               dr_fx;
    logic        [7:0]  dr_line;
    logic        [3:0]  dr_used;
    logic       [95:0]  dr_pix;

    wire signed [24:0] dr_dx  = dr_dx8 >>> 8;
    wire signed [24:0] dr_dxn = (dr_dx8 + $signed({16'd0, dr_sx})) >>> 8;
    wire               dr_vis = (dr_dx >= VX0) && (dr_dx <= VX1) && (dr_dx != dr_dxn);
    wire  [3:0]        dr_src = dr_xx[3:0] ^ {4{dr_fx}};
    wire  [5:0]        dr_pen6= dr_pix[6*dr_src +: 6];

    // ---- skip source pixels that provably do not write -------------------
    // The draw costs ONE CLOCK PER SOURCE PIXEL, sixteen a row, whether or
    // not the pixel writes anything -- and that, not fetch latency, is what
    // breaks a heavy line. Measured on the board: 784 rows on the worst
    // line, 12,544 source pixels, 14,236 clocks = 1.135 clocks a pixel
    // against a 3,456-clock budget.
    //
    // The rows on those lines are ZOOMED OUT, not 1:1 -- 100 of the 114 rows
    // on frame 3000's worst line have scale_x 0x40, i.e. four source pixels
    // collapse onto one destination pixel, so THREE IN FOUR write nothing
    // and still cost a clock. (Two more heavy frames measure the same: 105
    // of 114 at 0x3D, and the rest spread below 0x100.) So the lever is not
    // a wider write port -- which would need a multi-write line buffer, the
    // exact inference trap that produced the sprite splits, and would only
    // align at 1:1 zoom anyway. It is to STOP VISITING pixels that cannot
    // write.
    //
    // Each clock, look four source positions ahead and jump to the first one
    // that writes. Still exactly one write per clock and the same set of
    // written pixels -- a skipped position is one where the pen is
    // transparent, the destination is off-screen, or zoom has already
    // mapped a later source pixel onto the same destination (dr_vis's
    // dr_dx != dr_dxn, which is what makes the LAST source pixel of a
    // zoom group the one that draws). Worst case (1:1 and fully opaque) it
    // degenerates to today's one pixel a clock; on the lines that actually
    // overrun it is close to 4x.
    //
    // This replaces the transparent-quad skip, which was a strict subset:
    // "none of the next four writes" is covered by finding no writer.
    wire  [8:0] sx1 = dr_sx;
    wire [10:0] sx2 = {sx1, 1'b0};
    wire [10:0] sx3 = {2'd0, sx1} + sx2;
    wire [10:0] sx4 = {sx1, 2'b00};

    logic signed [24:0] la  [0:4];      // dr_dx8 at each lookahead position
    logic signed [24:0] dxk [0:4];      // and its destination pixel
    always_comb begin
        la[0] = dr_dx8;
        la[1] = dr_dx8 + $signed({16'd0, sx1});
        la[2] = dr_dx8 + $signed({14'd0, sx2});
        la[3] = dr_dx8 + $signed({14'd0, sx3});
        la[4] = dr_dx8 + $signed({14'd0, sx4});
        for (int k = 0; k <= 4; k++) dxk[k] = la[k] >>> 8;
    end

    logic  [3:0] lk_src  [0:3];
    logic  [5:0] lk_pen  [0:3];
    logic  [8:0] lk_ix   [0:3];
    logic  [3:0] lk_wr;                 // this position writes
    always_comb begin
        for (int k = 0; k < 4; k++) begin
            automatic logic [4:0] xx = dr_xx + 5'(k);
            lk_src[k] = xx[3:0] ^ {4{dr_fx}};
            lk_pen[k] = dr_pix[6*lk_src[k] +: 6] & penmask_e;
            lk_ix[k]  = dxk[k][8:0] - 9'd46;
            lk_wr[k]  = (xx < 5'd16)
                        && (dxk[k] >= VX0) && (dxk[k] <= VX1)
                        && (dxk[k] != dxk[k+1])
                        && (lk_pen[k] != 6'd0);
        end
    end

    // first writer among the four, and how many source pixels that consumes
    // ---- BISECT SWITCH (2026-09-07) --------------------------------------
    // The lookahead skip is one of three FUNCTIONAL changes that live only in
    // the working tree and not on origin/master. The player reports the
    // committed build has FEWER streaks but not none, so these three amplify
    // a bug that already exists in the committed code. This switch degenerates
    // the skip to the committed behaviour -- consider source pixel 0 only,
    // advance exactly one -- so the amplifier can be tested without reverting
    // NREC, the pen mask or the instruments.
    //   LK_SKIP = 1  working tree: skip up to four transparent source pixels
    //   LK_SKIP = 0  committed:    one source pixel per clock
    // It is the prime suspect because it is the only one of the three that
    // moves dr_dx8, the x-position accumulator -- and the corruption is
    // pixels landing at the wrong x ALONG a scanline.
    // VERDICT 2026-09-07: the skip is NOT the cause. Build 07154217 ran with
    // it OFF and the player reported the target glitches UNCHANGED -- while
    // other screen tears CAME BACK, because the worst sprite line went
    // 9,951 -> 15,615 clocks (+56 %) with every transparent source pixel
    // visited again. So the skip earns its place and is back ON; suspect #1
    // of three is eliminated. See SPRITE-CORRUPTION.md.
    localparam bit LK_SKIP = 1'b1;

    wire [3:0] lk_wr_e  = LK_SKIP ? lk_wr : {3'b000, lk_wr[0]};
    wire [1:0] lk_first = lk_wr_e[0] ? 2'd0 : lk_wr_e[1] ? 2'd1 :
                          lk_wr_e[2] ? 2'd2 : 2'd3;
    wire       lk_any   = |lk_wr_e;
    wire [2:0] lk_adv   = LK_SKIP ? (lk_any ? (3'(lk_first) + 3'd1) : 3'd4)
                                  : 3'd1;
    wire [10:0] lk_dadv = (lk_adv == 3'd1) ? {2'd0, sx1} :
                          (lk_adv == 3'd2) ? sx2 :
                          (lk_adv == 3'd3) ? sx3 : sx4;
    wire  [5:0]        dr_pen = dr_pen6 & penmask_e;
    wire  [8:0]        dr_ix  = dr_dx[8:0] - 9'd46;

    // record at `fc` -- the next to issue; the line's run ends at `fe`. Two
    // lookups deep: rec[fc] gives the sprite index (async), registered into
    // sidx_r, then sl_d[sidx_r] gives the sprite (async). So the sprite
    // fields are good from TWO cycles after fc changes (fc_ok); every use
    // below waits for that.
    logic [RW-1:0] fc, fe;
    wire [17:0]        rc_w    = rec[rb][fc];
    wire        [9:0]  rc_sidx = rc_w[17:8];
    wire        [3:0]  rc_a    = rc_w[7:4];      // the run's first source row
    wire        [3:0]  rc_b    = rc_w[3:0];      // ... and its last
    // partway through the record at fc: the next row of it to issue. fc
    // only advances on the run's last row, so fc_ok stays settled between
    // rows and the rows of a run issue on consecutive free slots.
    logic              ir_open;
    logic        [3:0] ir_row;
    wire        [3:0]  is_row  = ir_open ? ir_row : rc_a;
    wire        [3:0]  is_next = (rc_b > rc_a) ? is_row + 4'd1 : is_row - 4'd1;
    logic       [9:0]  sidx_r;
    always_ff @(posedge clk) sidx_r <= rc_sidx;
    wire [52:0]        sd_w    = sl_d[rb][sidx_r];
    wire signed [17:0] sd_tx   = sd_w[52:35];
    wire        [8:0]  sd_sx   = sd_w[34:26];
    wire       [16:0]  sd_code = sd_w[25:9];
    wire        [7:0]  sd_col  = sd_w[8:1];
    wire               sd_fx   = sd_w[0];
    wire signed [17:0] sd_x8   = sd_tx + 18'sd128;

    // ---- prefetch queue: two slots, slot i bound to fetch bus i ----------
    // Records are issued into alternate slots (q_is) and consumed from
    // alternate slots (q_cs), so the slot at q_cs is always the OLDEST
    // outstanding one and the draw order equals the bucket order. A slot
    // carries the sprite fields the draw needs, captured at issue, because
    // by promotion time `fc` has moved on.
    logic [1:0]        q_busy, q_ready;   // issued / pixels arrived
    logic [1:0][95:0]  q_pix;
    logic [1:0][17:0]  q_x8;
    logic [1:0][8:0]   q_sx;
    logic [1:0][7:0]   q_col;
    logic [1:0]        q_fx;
    logic              q_is, q_cs;
    logic              cur;              // a record is being drawn

    // ---- blank-row skip --------------------------------------------------
    // A fetched row whose 16 pens are all zero after the pen mask draws
    // NOTHING: every write below is guarded by (dr_vis && dr_pen != 0). It
    // still costs the full 17-cycle draw loop, and in a dense scene most of
    // what stacks up on a line is sprite edges, which are transparent.
    //
    // Skipping it is exactly equivalent -- not an approximation. The board
    // needs it: SPRFETCH:ROWMAX on build 30101648 read 784 rows on the worst
    // line at 17.8 clocks each, i.e. the draw loop IS the floor and 784 x 17
    // = 13328 clocks against a 3456 budget. No fetch or priority change can
    // touch that; the only ways down are fewer rows or fewer cycles a row,
    // and this is the free half of the first.
    logic q_any;
    always_comb begin
        q_any = 1'b0;
        for (int k = 0; k < 16; k++)
            if ((q_pix[q_cs][6*k +: 6] & penmask_e) != 6'd0) q_any = 1'b1;
    end
    logic              fc_ok;            // fc's two-deep lookup has settled

    // ---- sprite gfx fetch, two buses ------------------------------------
    logic [1:0][16:0] gfx_code;
    logic [1:0][3:0]  gfx_row;
    logic [1:0]       gfx_req, gfx_valid, gfx_busy;
    logic [15:0]      gfx_bad [0:1];
    wire  [16:0]      gfx_bad_sum = {1'b0, gfx_bad[0]} + {1'b0, gfx_bad[1]};
    assign fetch_bad = gfx_bad_sum[16] ? 16'hFFFF : gfx_bad_sum[15:0];
    logic [1:0][95:0] gfx_pix;

    rf_spr_gfx_bus gfx_a (
        .clk_cpu(clk), .reset(reset),
        .code(gfx_code[0]), .row(gfx_row[0]), .req(gfx_req[0]),
        .pix(gfx_pix[0]), .valid(gfx_valid[0]), .busy(gfx_busy[0]), .fetch_bad(gfx_bad[0]),
        .clk_ram(clk_ram),
        .ch_lo_addr(ch_a_lo_addr), .ch_lo_dout(ch_a_lo_dout), .ch_lo_req(ch_a_lo_req), .ch_lo_ready(ch_a_lo_ready),
        .ch_hi_addr(ch_a_hi_addr), .ch_hi_dout(ch_a_hi_dout), .ch_hi_req(ch_a_hi_req), .ch_hi_ready(ch_a_hi_ready),
        .base_lo(gfx_base_lo), .base_hi(gfx_base_hi)
    );

    rf_spr_gfx_bus gfx_b (
        .clk_cpu(clk), .reset(reset),
        .code(gfx_code[1]), .row(gfx_row[1]), .req(gfx_req[1]),
        .pix(gfx_pix[1]), .valid(gfx_valid[1]), .busy(gfx_busy[1]), .fetch_bad(gfx_bad[1]),
        .clk_ram(clk_ram),
        .ch_lo_addr(ch_b_lo_addr), .ch_lo_dout(ch_b_lo_dout), .ch_lo_req(ch_b_lo_req), .ch_lo_ready(ch_b_lo_ready),
        .ch_hi_addr(ch_b_hi_addr), .ch_hi_dout(ch_b_hi_dout), .ch_hi_req(ch_b_hi_req), .ch_hi_ready(ch_b_hi_ready),
        .base_lo(gfx_base_lo), .base_hi(gfx_base_hi)
    );

    // ---- line buffer ring: NB banks x 320 x {tag[6:0], val[12:0]} -------
    // Bank = line mod NB, so every line sharing a bank has the same
    // line[NBW-1:0] and is told apart by line[7:NBW]. The tag is that plus
    // the FRAME PARITY:
    //
    //     tag = {par, line[7:NBW]}
    //
    // The parity is the cheap half of the fix for the ghosting reported from
    // the cabinet on 2026-08-28 (player shots leaving their pixels behind
    // along the whole path). The original claim that "the line buffer needs
    // no clearing" was wrong: an entry is only ever overwritten by another
    // sprite pixel at the same address, so a pixel written at (line L, x)
    // still carried a matching tag at (line L, x) in the NEXT frame and read
    // as a live sprite pixel until something happened to overwrite it.
    //
    // The parity alone is NOT enough -- it only tells adjacent frames apart,
    // so a pixel untouched for two frames comes back (sim/Makefile
    // `spr-ghost` failed exactly that way with the parity and no clear). The
    // buffer is therefore CLEARED per line, in D_CLR below, which is what
    // the real chip's framebuffer does (the model clears it every frame;
    // "sprite trails" is the F3 feature for not clearing, and Ray Force
    // never sets it). The tag then costs nothing and still guards the window
    // where the draw has not reached a line the mixer asks for.
    //
    // The clear is a SPAN, not the whole 320: each bank remembers the
    // leftmost and rightmost pixel its last occupant wrote, and only that
    // range is cleared before the next line uses it. Every pixel any
    // occupant wrote is therefore cleared before the next one draws, which
    // is the whole requirement -- and a flat 320-pixel clear was far too
    // expensive: it pushed the longest line from 3288 to 3608 clocks and
    // made 254 of 256 lines late in `pipe-lat` (the pathological frame at
    // hardware-like SDRAM latency). The span costs nothing on the empty and
    // near-empty lines that most of a frame is made of.
    //
    // It costs no memory: line[7:NBW] is 6 bits for NB = 4, so the tag is
    // still 7 bits and an entry still 20, i.e. NB x 512 x 20 bits = NB/2
    // M10Ks (2 banks were three M10Ks at 21 bits).
    // NB = 16, was 8, was 4. The draw has to bank slack across quiet lines:
    // the budget is 3456 clocks a line and the board's worst line needs
    // ~16000, so what matters is how many lines of slack the ring holds --
    // NB x 3456 in total.
    //
    //   NB=4   13824 clocks   under the worst single line; late lines came
    //                         in bursts (0 -> 4770 -> 6820) as scenes got busy
    //   NB=8   27648          covers any ONE line (the worst is 57 % of it),
    //                         but not a RUN of heavy lines -- which is what
    //                         a boss fight is, and the board still glitched
    //                         there with late lines saturating at 65535
    //   NB=16  55296          two full bosses' worth of run
    //
    // The cost is memory, not logic: the line buffer is NB x 512 x 20 bits,
    // so 8 -> 16 banks is +8 M10K against 12 free (541/553 in build
    // 29224005). The tag stays inside the 20-bit word -- it is
    // {par, line[7:NBW]}, and a wider NBW makes it SHORTER, 5 bits at NB=16.
    // TWO banks, ping-pong: the draw fills one while rf_spr_fb streams the
    // other to DDR3. The ring used to be 16 deep because its whole job was
    // to bank slack against the raster; with a frame buffered in DDR3 that
    // job is gone, and 14 banks of M10K come back on a device at 551/553.
    localparam int NB  = 2;
    localparam int NBW = $clog2(NB);

    logic            wr_en;
    logic [NBW+8:0]  wr_addr;
    logic [15:0]     wr_data;

    // The draw writes the bank it is filling; the framebuffer writer reads
    // the one it was handed. The mixer does not read this at all any more --
    // it reads DDR3, a frame later -- so the entry loses its tag and is just
    // the 13-bit colour. The tag existed to catch the mixer asking for a line
    // the draw had not reached, which is a state that no longer exists.
    rf_bram #(.WIDTH(16), .AW(NBW + 9)) u_lbuf (
        .clk(clk),
        .waddr(wr_addr), .wdata(wr_data), .wren(wr_en),
        .raddr({~dbank, fb_addr}), .q(fb_q)
    );
    // the parity of the frame being drawn; the mixer reads the line the draw
    logic par;                          // parity of the frame being DRAWN
    assign o_par = par;
    logic dbank;                        // the bank the draw is filling

    // The per-line priority-group flags have to lag with the pixels they
    // describe, so they are double banked the same way the framebuffer is:
    // written for the frame being drawn, read for the frame being shown.
    // 2 x 256 x 4 bits is nothing, and keeping them on chip avoids widening
    // the DDR3 word to carry four bits that are constant across a line.
    logic [3:0] used_line [0:1][0:255];
    assign rd_used = used_line[~par][rd_line];

    // ---- the run-ahead window ----------------------------------------------
    // nxt is the next line to draw (256 = the frame is done). The draw may
    // run while nxt is within NB-1 lines past the mixer's line, in 8-bit
    // modular arithmetic so the frame wrap (mixer still on 255 when the
    // draw restarts at 0) needs no special case.
    logic        active;
    logic  [8:0] nxt;
    // The only thing that can hold the draw up now is the framebuffer writer
    // still emptying the bank this line wants. There is no per-line deadline
    // left: the draw has the whole frame for its 256 lines, and the frame is
    // only ~15 % full of sprite work.
    wire         can_draw = active && !nxt[8];
    assign lines_done = nxt;

    // ================= PREPASS FSM (writes bank wb) =================
    typedef enum logic [3:0] {
        P_IDLE, P_WALK,
        // P_C0W / P_E0W are one dead cycle each, waiting for sly_q to catch
        // up with ex_i now that sl_y is an M10K with a REGISTERED read
        // rather than an async MLAB. Two per sprite, so 2048 clocks a frame
        // against ~905,000 -- unmeasurable -- and it buys back 64 LABs,
        // which the fitter cares about far more than the prepass does.
        P_C0, P_C0W, P_CROW, P_CRD, P_CWR, P_CEND, // pass 1: count records
        P_SRD, P_SWR,                         // prefix sum -> runs
        P_E0, P_E0W, P_EROW, P_ERD, P_EWR, P_EEND  // pass 2: place records
    } pst_t;
    pst_t pst;
    assign prepass_busy = (pst != P_IDLE);
    assign fetch_max     = f_max_q;
    assign rows_line_max = rows_line_pk_q;

    // One row of the walk, shared by both passes so they cannot disagree
    // about where a run starts and ends (pass 1 counts what pass 2 places).
    // A row in range on the open run's line extends it; any other row
    // closes the open run into e_* (RDST emits it) and, if in range, opens
    // a new one. The row is advanced here either way; the emit states use
    // e_* only, and come back to ROWST for the next row or ENDST after the
    // last. Every next state is written out explicitly (a "stay" that
    // landed in the wrong state was the bug the spr-line bench caught in
    // the linked-list version).
    `define RUN_STEP(ROWST, RDST, ENDST) \
        begin \
            if (ex_inr && r_open && ex_dyb == r_dy) begin \
                r_b <= ex_srow; \
                pst <= (ex_yy == 5'd0) ? ENDST : ROWST; \
            end else begin \
                e_dy <= r_dy; e_a <= r_a; e_b <= r_b; \
                r_open <= ex_inr; r_dy <= ex_dyb; r_a <= ex_srow; r_b <= ex_srow; \
                ret_end <= (ex_yy == 5'd0); \
                pst <= r_open ? RDST : (ex_yy == 5'd0) ? ENDST : ROWST; \
            end \
            if (ex_yy != 5'd0) begin \
                ex_dy8 <= ex_dy8 - $signed({16'd0, ex_sy}); \
                ex_yy  <= ex_yy - 5'd1; \
            end \
        end
    // the sprite's last row has been walked: emit the run still open, then
    // move to the next sprite
    `define RUN_END(RDST, SPRST) \
        begin \
            if (r_open) begin \
                e_dy <= r_dy; e_a <= r_a; e_b <= r_b; \
                r_open <= 1'b0; ret_end <= 1'b1; \
                pst <= RDST; \
            end else begin \
                ex_i <= ex_i + 11'd1; \
                pst  <= SPRST; \
            end \
        end
    // load sprite ex_i's expand state (its 16 rows walked 15 -> 0)
    `define SPR_LOAD_EX \
        begin ex_sy <= sly_sy; ex_fy <= sly_fy; ex_yy <= 5'd15; r_open <= 1'b0; \
              ex_dy8 <= $signed(sly_ty) + (flip_r ? 25'sd0 : 25'sd255) \
                      + $signed({16'd0, ({sly_sy, 4'd0} - {4'd0, sly_sy})}); end

    // ---- SEQUENCE INSTRUMENTS -------------------------------------------
    logic [15:0] rec_seq  [0:3];
    logic [15:0] used_seq [0:3];
    logic [15:0] used_acc;                // this frame's running hash
    logic [15:0] nspr_seq [0:3];
    logic [15:0] ovr_cnt;
    logic [19:0] pp_clk;                // clocks since frame_start
    logic [15:0] pp_end;                // pp_clk >> 4 when the prepass went idle
    logic        pp_seen;               // ... captured once per frame
    logic        pb_q;                  // prepass_busy, one clock late
    assign seq_rec01  = {rec_seq[0],  rec_seq[1]};
    assign seq_rec23  = {rec_seq[2],  rec_seq[3]};
    assign seq_nspr01 = {nspr_seq[0], nspr_seq[1]};
    assign seq_nspr23 = {nspr_seq[2], nspr_seq[3]};
    // Top byte: {6'b0, rb, par} -- WHICH record bank the draw reads, and the
    // frame parity, at the instant the page samples this row. Rows 17 and 25
    // sample 8 frames apart (even), so this reads the same parity FOLDSEQ's
    // first column does. With the reset parity swapped (below), one build says
    // whether the bad half follows the BANK or the frame parity.
    assign seq_ovr    = {6'd0, rb, par, ovr_cnt[7:0], pp_end};
    assign seq_used01 = {used_seq[0], used_seq[1]};
    assign seq_used23 = {used_seq[2], used_seq[3]};
    always_ff @(posedge clk) begin
        pb_q <= prepass_busy;
        if (reset) begin
            for (int i = 0; i < 4; i++) begin rec_seq[i] <= 16'd0; nspr_seq[i] <= 16'd0; end
            ovr_cnt <= 16'd0; pp_clk <= 20'd0; pp_end <= 16'd0; pp_seen <= 1'b0;
            for (int i = 0; i < 4; i++) used_seq[i] <= 16'd0;
            used_acc <= 16'd0;
        end else if (frame_start) begin
            // rows_tot and nspr are reset by the prepass FSM in this same
            // cycle (non-blocking), so what is read here is the frame just
            // ended -- complete or not. A short frame shows as a small number.
            rec_seq[0]  <= rows_tot;      rec_seq[1]  <= rec_seq[0];
            rec_seq[2]  <= rec_seq[1];    rec_seq[3]  <= rec_seq[2];
            nspr_seq[0] <= {5'd0, nspr};  nspr_seq[1] <= nspr_seq[0];
            nspr_seq[2] <= nspr_seq[1];   nspr_seq[3] <= nspr_seq[2];
            if (prepass_busy && ovr_cnt != 16'hFFFF) ovr_cnt <= ovr_cnt + 16'd1;
            used_seq[0] <= used_acc;      used_seq[1] <= used_seq[0];
            used_seq[2] <= used_seq[1];   used_seq[3] <= used_seq[2];
            used_acc    <= 16'd0;
            pp_clk  <= 20'd0;
            pp_seen <= 1'b0;
        end else begin
            if (pp_clk != 20'hFFFFF) pp_clk <= pp_clk + 20'd1;
            if (used_pub) used_acc <= {used_acc[14:0], used_acc[15]} ^ {12'd0, used_val};
            if (pb_q && !prepass_busy && !pp_seen) begin
                pp_end  <= pp_clk[19:4];
                pp_seen <= 1'b1;
            end
        end
    end

    // ---- TEARING INSTRUMENT ---------------------------------------------
    // The walk reads sprite RAM through the B port while the CPU writes the A
    // port, with no snapshot between them. Every write that lands while
    // wk_busy is high can put a torn entry into the list: part of the old
    // frame's sprite, part of the new one. tear_cnt counts those writes,
    // tear_frames counts the frames that had at least one. Both saturate.
    // If these read zero on the board the CPU and the walk never overlap and
    // this whole theory is dead; if they are large, the list the draw works
    // from is not a coherent snapshot of anything.
    logic tear_seen;
    always_ff @(posedge clk) begin
        if (reset) begin
            tear_cnt <= 16'd0; tear_frames <= 16'd0; tear_seen <= 1'b0;
        end else begin
            if (frame_start) begin
                if (tear_seen && tear_frames != 16'hFFFF)
                    tear_frames <= tear_frames + 16'd1;
                tear_seen <= 1'b0;
            end
            if (wk_busy && spr_wr_stb) begin
                tear_seen <= 1'b1;
                if (tear_cnt != 16'hFFFF) tear_cnt <= tear_cnt + 16'd1;
            end
        end
    end

    always_ff @(posedge clk) begin
        wk_start <= 1'b0;
        bt_we    <= 1'b0;
        if (reset) begin
            pst <= P_IDLE;
            wb  <= 1'b0; rb <= 1'b1;
            nspr <= 11'd0;
            flip_r <= 1'b0; penmask_r <= 6'h0F;
        end else if (frame_start) begin
            // publish the bank just built, start filling the other
            rb <= wb;
            wb <= ~wb;
            nspr     <= 11'd0;
            clr_i    <= 9'd0;
            wk_fin   <= 1'b0;
            rows_tot <= 16'd0;
            drop_cnt <= 16'd0;
            wk_start <= 1'b1;
            pst <= P_WALK;
        end else case (pst)
            // the walk streams sprites in; the count table is cleared under
            // it (256 cycles -- an empty list finishes first, hence wk_fin)
            P_WALK: begin
                if (s_valid && nspr < 11'(NSPR)) begin
                    sl_y[nspr]     <= {s_ty, s_sy, s_fy};
                    sl_d[wb][nspr] <= {s_tx, s_sx, s_code, s_color, s_fx};
                    nspr <= nspr + 11'd1;
                end
                if (!clr_i[8]) begin
                    cnt[clr_i[7:0]] <= '0;
                    clr_i <= clr_i + 9'd1;
                end
                if (wk_done) begin
                    penmask_r <= wk_penmask;
                    flip_r    <= wk_flip;
                    wk_fin    <= 1'b1;
                end
                if ((wk_done || wk_fin) && clr_i[8]) begin
                    ex_i <= 11'd0;
                    pst  <= P_C0;
                end
            end

            // ---- pass 1: count records per line
            P_C0: begin
                if (ex_i >= nspr) begin
                    sum_y   <= 8'd0;
                    sum_acc <= '0;
                    pst     <= P_SRD;
                end else pst <= P_C0W;    // let sly_q catch up with ex_i
            end
            P_C0W: begin
                `SPR_LOAD_EX
                pst <= P_CROW;
            end
            P_CROW: `RUN_STEP(P_CROW, P_CRD, P_CEND)
            P_CRD: begin
                c_rd <= cnt[e_dy];
                pst  <= P_CWR;
            end
            P_CWR: begin
                cnt[e_dy] <= c_rd + 1'b1;
                if (rows_tot != 16'hFFFF) rows_tot <= rows_tot + 16'd1;
                pst <= ret_end ? P_CEND : P_CROW;
            end
            P_CEND: `RUN_END(P_CRD, P_C0)

            // ---- prefix sum: line y gets [sum_acc, sum_acc + cap); cnt[y]
            // becomes its fill pointer, lim[y] its end. Ends are 13-bit
            // modular (8192 reads as 0): the draw compares for equality and
            // fc wraps with it, so a run touching the top of the store is
            // still walked in full.
            P_SRD: begin
                c_rd <= cnt[sum_y];
                pst  <= P_SWR;
            end
            P_SWR: begin
                bt_we   <= 1'b1;
                bt_wa   <= {wb, sum_y};
                bt_wd   <= {sum_end[RW-1:0], sum_acc[RW-1:0]};
                lim[sum_y] <= sum_end[RW-1:0];
                cnt[sum_y] <= sum_acc[RW-1:0];
                sum_acc <= sum_end;
                sum_y   <= sum_y + 8'd1;
                if (sum_y == 8'd255) begin
                    ex_i <= 11'd0;
                    pst  <= P_E0;
                end else begin
                    pst  <= P_SRD;
                end
            end

            // ---- pass 2: place records
            P_E0: begin
                if (ex_i >= nspr) begin
                    // what the frame asked for and what was refused, for
                    // the self-test page: refused records come off the END
                    // of the run order, i.e. the sprites drawn on top
                    rec_peak <= rows_tot;
                    rec_drop <= drop_cnt;
                    pst <= P_IDLE;
                end else pst <= P_E0W;    // let sly_q catch up with ex_i
            end
            P_E0W: begin
                `SPR_LOAD_EX
                pst <= P_EROW;
            end
            P_EROW: `RUN_STEP(P_EROW, P_ERD, P_EEND)
            P_ERD: begin
                f_rd <= cnt[e_dy];
                l_rd <= lim[e_dy];
                pst  <= P_EWR;
            end
            P_EWR: begin
                if (f_rd != l_rd) begin
                    rec[wb][f_rd] <= {ex_i[9:0], e_a, e_b};
                    cnt[e_dy]     <= f_rd + 1'b1;
                end else if (drop_cnt != 16'hFFFF) begin
                    drop_cnt <= drop_cnt + 16'd1;
                end
                pst <= ret_end ? P_EEND : P_EROW;
            end
            P_EEND: `RUN_END(P_ERD, P_E0)

            default: pst <= P_IDLE;
        endcase
    end
    `undef RUN_STEP
    `undef RUN_END
    `undef SPR_LOAD_EX

    // ================= DRAW FSM (reads bank rb) =================
    // Issue: whenever the next record's lookup has settled and the issue
    // slot is free, start its fetch and advance fc. Promote: when the
    // current record is drawn (or there is none), take the consume slot as
    // soon as its pixels are in. Done: nothing drawing, nothing in flight,
    // no records left.
    // DIAGNOSTIC: rows a line may draw before the rest are abandoned.
    // 3 is a HARD cap, well under any real line, so the abandon path is
    // exercised in simulation -- at 128 and 256 it never triggers on any
    // dumped frame (the worst is 27 rows) and would ship untested.
    wire [15:0] cap_rows = (row_cap == 2'd1) ? 16'd256 :
                           (row_cap == 2'd2) ? 16'd128 : 16'd8;

    typedef enum logic [2:0] { D_IDLE, D_CLR, D_LEAD0, D_RUN, D_DONE } dst_t;
    dst_t dst;
    assign line_busy = (dst != D_IDLE && dst != D_DONE);
    // the clear span: what the bank's last occupant wrote, and what this
    // line is writing (lo > hi means nothing)
    logic [8:0] clr_x, clr_hi;
    logic [8:0] span_lo [0:NB-1];
    logic [8:0] span_hi [0:NB-1];
    logic [8:0] cur_lo, cur_hi;

    // ---- fetch/density diagnostics (see the ports) ----------------------
    // f_cnt runs while a bus has a fetch outstanding and is banked at the
    // fall; rows_line counts the rows ISSUED on the line being drawn. Both
    // peaks are per frame and are published at frame_start, which is the
    // only moment the draw is guaranteed idle.
    logic [15:0] f_cnt   [0:1];
    logic [15:0] f_max, f_max_q;
    logic [15:0] rows_line, rows_line_pk, rows_line_pk_q;
    logic  [1:0] gfx_busy_d;

    logic       used_pub;               // a used_line entry was published
    logic [3:0] used_val;               // ... with this value
    always_ff @(posedge clk) begin
        gfx_req <= 2'b00;
        wr_en   <= 1'b0;
        fb_req  <= 1'b0;
        used_pub <= 1'b0;
        fc_ok   <= 1'b1;                 // cleared below whenever fc changes

        // capture completions (bus i serves slot i)
        if (gfx_valid[0] && q_busy[0]) begin q_pix[0] <= gfx_pix[0]; q_ready[0] <= 1'b1; end
        if (gfx_valid[1] && q_busy[1]) begin q_pix[1] <= gfx_pix[1]; q_ready[1] <= 1'b1; end

        // longest single fetch: count while a bus is busy, bank it at the fall
        gfx_busy_d <= gfx_busy;
        for (int b = 0; b < 2; b++) begin
            if (gfx_busy[b]) f_cnt[b] <= f_cnt[b] + 16'd1;
            else             f_cnt[b] <= 16'd0;
            if (gfx_busy_d[b] && !gfx_busy[b] && f_cnt[b] > f_max) f_max <= f_cnt[b];
        end

        if (reset) begin
            dst <= D_IDLE; q_busy <= 2'b00; q_ready <= 2'b00; cur <= 1'b0;
            active <= 1'b0; nxt <= 9'd0; par <= 1'b0; ir_open <= 1'b0;
            draw_unfinished <= 8'd0;
            dbank <= 1'b0; fb_line <= 8'd0; fb_used <= 4'd0;
            f_cnt[0] <= 0; f_cnt[1] <= 0; f_max <= 0; f_max_q <= 0;
            rows_line <= 0; rows_line_pk <= 0; rows_line_pk_q <= 0;
            gfx_busy_d <= 2'b00;
            for (int b = 0; b < NB; b++) begin
                span_lo[b] <= 9'd511; span_hi[b] <= 9'd0;      // empty
            end
        end else if (frame_start) begin
            par <= ~par;                // every entry of the frame just drawn
                                        // now reads as empty
            // MEASURED, not assumed: did the draw actually get through all
            // 256 lines before the banks swapped? Saturating, so a board
            // left running does not wrap the evidence away.
            if (active && nxt < 9'd256 && draw_unfinished != 8'hFF)
                draw_unfinished <= draw_unfinished + 8'd1;
            // the buckets just swapped: restart at line 0. In normal running
            // the draw finished line 255 long ago; a fetch still in flight
            // (a frame_start mid-line, e.g. the bench's priming pass) is
            // simply not captured -- q_busy is cleared -- and the bus stays
            // busy until it lands, which the issue rule waits for.
            dst <= D_IDLE; q_busy <= 2'b00; q_ready <= 2'b00; cur <= 1'b0;
            active <= 1'b1; nxt <= 9'd0; ir_open <= 1'b0;
            // publish last frame's peaks and start fresh
            f_max_q        <= f_max;        f_max        <= 16'd0;
            rows_line_pk_q <= rows_line_pk; rows_line_pk <= 16'd0;
            rows_line      <= 16'd0;
        end else case (dst)
            D_IDLE: if (can_draw) begin
                dr_line <= nxt[7:0];
                dr_used <= 4'd0;
                q_busy  <= 2'b00; q_ready <= 2'b00;
                q_is    <= 1'b0;  q_cs    <= 1'b0;
                cur     <= 1'b0;
                clr_x   <= span_lo[dbank];
                clr_hi  <= span_hi[dbank];
                cur_lo  <= 9'd511; cur_hi <= 9'd0;             // this line: empty
                if (rows_line > rows_line_pk) rows_line_pk <= rows_line;
                rows_line <= 16'd0;
                dst <= (span_lo[dbank] > span_hi[dbank]) ? D_LEAD0 : D_CLR;
            end

            // Clear this line's bank: 320 writes, ~9 % of the frame's clocks
            // and the reason a sprite goes away when it stops being drawn.
            // The run table's answer for {rb, nxt} is presented from D_IDLE
            // and nxt does not move until D_DONE, so bt_q is still valid at
            // the end of this.
            D_CLR: begin
                wr_en   <= 1'b1;
                wr_addr <= {dbank, clr_x};
                wr_data <= 16'd0;
                clr_x   <= clr_x + 9'd1;
                if (clr_x >= clr_hi) dst <= D_LEAD0;
            end

            // the run table answers for {rb, nxt} (presented during D_IDLE)
            D_LEAD0: begin
                if (bt_q[RW-1:0] == bt_q[2*RW-1:RW]) begin
                    used_line[par][dr_line] <= dr_used;         // empty line
                    used_pub <= 1'b1; used_val <= dr_used;
                    span_lo[dbank] <= cur_lo;                  // nothing written
                    span_hi[dbank] <= cur_hi;
                    dst <= D_DONE;
                end else begin
                    fc    <= bt_q[RW-1:0];
                    fe    <= bt_q[2*RW-1:RW];
                    fc_ok <= 1'b0;
                    ir_open <= 1'b0;
                    dst   <= D_RUN;
                end
            end

            D_RUN: begin
                // ---- DIAGNOSTIC workload cap ------------------------------
                // Abandon the rest of this line's rows once it has drawn
                // `cap_rows` of them. Ending the run (fc <= fe) hands the
                // line to the ordinary drain-and-finish branch below, so
                // nothing else in the FSM has to know the cap exists. The
                // sprites past the cap are simply not drawn -- the point is
                // to see whether the COLOURS come right when the line is
                // forced inside its budget.
                if (row_cap != 2'd0 && rows_line >= cap_rows && fc != fe) begin
                    fc      <= fe;
                    fc_ok   <= 1'b0;
                    ir_open <= 1'b0;
                end
                // ---- issue the next row of the record at fc into the free
                // slot; fc advances on the run's last row only
                else if (fc != fe && fc_ok && !q_busy[q_is] && !gfx_busy[q_is]) begin
                    gfx_code[q_is] <= sd_code;
                    gfx_row[q_is]  <= is_row;
                    gfx_req[q_is]  <= 1'b1;
                    q_busy[q_is]   <= 1'b1;
                    q_ready[q_is]  <= 1'b0;
                    q_x8[q_is]     <= sd_x8;
                    q_sx[q_is]     <= sd_sx;
                    q_col[q_is]    <= sd_col;
                    q_fx[q_is]     <= sd_fx;
                    if (is_row == rc_b) begin
                        fc      <= fc + 1'b1;
                        fc_ok   <= 1'b0;
                        ir_open <= 1'b0;
                    end else begin
                        ir_open <= 1'b1;
                        ir_row  <= is_next;
                    end
                    q_is  <= ~q_is;
                    rows_line <= rows_line + 16'd1;
                end

                // ---- draw the current record / promote the next / finish
                if (!cur || dr_xx == 5'd16) begin
                    if (q_ready[q_cs]) begin
                        dr_pix  <= q_pix[q_cs];
                        dr_sx   <= q_sx[q_cs];
                        dr_base <= 13'h1000 + {1'b0, q_col[q_cs], 4'd0};
                        dr_pri  <= q_col[q_cs][7:6];
                        dr_fx   <= q_fx[q_cs];
                        dr_dx8  <= $signed(q_x8[q_cs]);
                        dr_xx   <= 5'd0;
                        q_busy[q_cs]  <= 1'b0;
                        q_ready[q_cs] <= 1'b0;
                        q_cs <= ~q_cs;
                        // an all-transparent row writes nothing, so take the
                        // next record instead of spending 17 cycles on it
                        cur  <= q_any;
                    end else if (!q_busy[q_cs] && fc == fe) begin
                        used_line[par][dr_line] <= dr_used;
                        used_pub <= 1'b1; used_val <= dr_used;
                        span_lo[dbank] <= cur_lo;
                        span_hi[dbank] <= cur_hi;
                        dst <= D_DONE;
                    end
                    // else wait for the oldest fetch to land
                end else begin
                    // write the first of the next four source pixels that
                    // writes at all, and step past it; if none of the four
                    // writes, step over all four. See the lookahead above.
                    if (lk_any) begin
                        wr_en   <= 1'b1;
                        wr_addr <= {dbank, lk_ix[lk_first]};
                        wr_data <= {3'd0, dr_base | {7'd0, lk_pen[lk_first]}};
                        dr_used <= dr_used | (4'd1 << dr_pri);
                        if (lk_ix[lk_first] < cur_lo) cur_lo <= lk_ix[lk_first];
                        if (lk_ix[lk_first] > cur_hi) cur_hi <= lk_ix[lk_first];
                    end
                    // dr_xx never overshoots 16: a writing position is only
                    // considered while dr_xx+k < 16, so lk_adv <= 16-dr_xx.
                    // The no-writer case steps 4 and is clamped, since the
                    // row is finished either way and dr_dx8 is reloaded.
                    dr_xx  <= (5'({1'b0, dr_xx}) + 5'({2'd0, lk_adv}) > 5'd16)
                              ? 5'd16 : dr_xx + 5'({2'd0, lk_adv});
                    dr_dx8 <= dr_dx8 + $signed({14'd0, lk_dadv});
                end
            end

            // Publish the line: hand the bank to rf_spr_fb and start filling
            // the other one. can_draw holds the next line off until the
            // writer has finished, which is the only back-pressure left.
            // Hand over only when the writer can take it. wr_req is a pulse
            // and rf_spr_fb accepts it only in W_IDLE, so issuing it while
            // the writer was still emptying the previous line dropped that
            // line silently -- it never reached DDR3 and its sprites simply
            // were not there. Waiting here also guarantees dbank cannot flip
            // under the writer, which reads the bank as ~dbank.
            D_DONE: if (!fb_busy) begin
                fb_req  <= 1'b1;
                fb_line <= dr_line;
                fb_used <= dr_used;
                dbank   <= ~dbank;
                nxt     <= nxt + 9'd1;
                dst     <= D_IDLE;
            end
            default: dst <= D_IDLE;
        endcase
    end

endmodule
