//============================================================================
//  ES5505 -- the Ensoniq 32-voice sampler, as MAME computes it.
//
//  This is the RTL of tools/es5505_model.py (itself an exact port of
//  es5506.cpp's ES5505 paths), and it is checked against that model sample
//  for sample (sim/es5505_tb.cpp, make -C sim es5505). Every arithmetic
//  step keeps MAME's integer semantics, including C's truncating division
//  in the filters, so the diff is exact, not "close".
//
//  Shape. One output sample every `tick` (the host sets the rate: master
//  clock / (16 x (active voices + 1)), 29.76 kHz with all 32). Between
//  ticks the voices are processed one at a time on ONE datapath: the
//  voice's record is read from the voice file, its two source samples are
//  read (from a per-voice pair of 8-sample line caches, refilled from
//  SDRAM on a miss), then interpolate -> four filter poles -> volume ->
//  accumulate into the 8 output channels (four stereo pairs, control CA
//  selects the pair), then the record is written back with the advanced
//  accumulator, the loop/stop handling applied, and the filter poles
//  updated. ONE multiplier (34 x 18, registered product) serves every
//  step -- the interpolation, the four poles, the two volumes -- so a
//  voice costs 17 clocks with its samples cached, ~40 more per miss; 32
//  voices fit the 1793-clock period with room for ~30 misses. (The first
//  version instantiated a multiplier per expression: 28 DSP blocks, 5000
//  ALMs and a -32 ns path. This one is 2 DSPs.)
//
//  Register writes from the 68000 (es_*, bk_*) are queued and applied at
//  the start of the next sample -- which is exactly the model's discipline
//  ("all samples up to the write's time, then the write"), so the bench
//  can place every write on the same boundary in both and demand equality.
//
//  Fixed point. MAME keeps the accumulator in 20.11 with the 5505's 20.9
//  registers shifted up 2; the low 2 bits are always 0 (every quantity is
//  a multiple of 4), so this works in 20.9 directly: accum, start, end are
//  29 bits, the step is the FC register's bits [15:1] (15 bits), the
//  interpolation fraction is accum[8:0] over 512 (MAME's frac[10:0] over
//  2048 with two zero LSBs -- identical result), and the integer address
//  is accum[28:9].
//
//  Sample memory: word address = {bank[2:0], integer address[19:0]}. THREE
//  bank bits, not two: the Taito EN board's otisbank register is masked by
//  MAME with (ensoniq_region_bytes / 0x200000) - 1, which is 3 for Ray
//  Force's 8 MB region but 7 for Puzzle Bobble 3/4's 16 MB one. The mask is
//  per-game and comes in on bank_mask, so a 2-bit game cannot reach the
//  extra space and behaves exactly as before. The
//  word is the ROM byte in the high half, 0 in the low (see ROADMAP Phase
//  3), i.e. SDRAM byte 0x780000 + address. A line is 8 consecutive bytes =
//  8 samples, one SDRAM burst.
//============================================================================

module rf_es5505
(
    input  logic        clk,
    input  logic        reset,

    // register writes (from rf_sound_main), any time
    input  logic        es_we,
    input  logic  [3:0] es_reg,
    input  logic [15:0] es_data,
    input  logic  [1:0] es_be,          // {upper byte, lower byte}
    input  logic        bk_we,
    input  logic  [4:0] bk_voice,
    input  logic  [2:0] bk_data,
    // per-game otisbank mask, MAME's m_bankmask (3 = 8 MB region, 7 = 16 MB)
    input  logic  [2:0] bank_mask,

    // sample line fetch: 8 bytes at {bank, addr[19:3]} -> line[63:0]
    output logic        sm_req,         // one-cycle pulse
    output logic [22:3] sm_addr,
    input  logic [63:0] sm_line,        // byte k of the line in [8k +: 8]
    input  logic        sm_valid,       // one-cycle pulse
    input  logic        sm_busy,

    // output: one 8-channel sample per tick, 20-bit signed each
    input  logic        tick,           // the sample clock (host-set rate)
    output logic        out_valid,      // one-cycle pulse
    output logic [7:0][19:0] out_ch,    // {ch3R, ch3L, ..., ch0R, ch0L}
    output logic  [4:0] out_active,     // ACT, for the host's rate
    output logic  [7:0] irqv_out,       // IRQV: 0x80 = nothing pending, else the voice

    // host register READS (rf_sound_main). rd_req is a level held for the
    // 68000 bus cycle; rd_valid rises once rd_data holds what the chip would
    // answer at that moment: every queued write applied and the sequencer
    // idle, i.e. es5505_device::read after its stream update. The driver
    // depends on this -- it reads its sound table out of the sample ROM
    // through a parked voice's O1(n-1) (see R_MUX) and polls the STOP bits.
    input  logic        rd_req,
    input  logic  [3:0] rd_reg,
    output logic [15:0] rd_data,
    output logic        rd_valid,
    input  logic        irqv_ack,       // the host read IRQV: back to 0x80

    // diagnostics
    output logic [15:0] dbg_overrun,    // ticks that arrived mid-sample
    output logic [15:0] dbg_miss,       // line fetches, running
    output logic [15:0] dbg_wqdrop      // register writes lost to a full queue
);
    // ---- control bits (es5506.cpp, 5505 placements) ----------------------
    localparam logic [15:0] C_STOP0 = 16'h0001, C_STOP1 = 16'h0002, C_LEI = 16'h0004,
                            C_LPE   = 16'h0008, C_BLE   = 16'h0010, C_IRQE = 16'h0020,
                            C_DIR   = 16'h0040, C_IRQ   = 16'h0080;

    // ---- voice file: 32 records ----------------------------------------
    // {bank[2:0], control[15:0], fc[15:0], start[28:0], end[28:0], accum[28:0],
    //  k2[15:0], k1[15:0], lvol[7:0], rvol[7:0],
    //  o1n1, o2n1, o2n2, o3n1, o3n2, o4n1 : 6 x [23:0]}  = 314 bits
    localparam int VW = 314;
    (* ramstyle = "MLAB, no_rw_check" *) logic [VW-1:0] vf [0:31] /*verilator public_flat_rd*/;
    logic  [4:0]   vf_wa, vf_ra;
    logic [VW-1:0] vf_wd;
    logic          vf_we;
    wire  [VW-1:0] vf_rd = vf[vf_ra];

    // ---- per-voice sample line cache: 2 slots per voice -------------------
    // {valid, tag[22:3], line[63:0]} = 85 bits
    (* ramstyle = "MLAB, no_rw_check" *) logic [84:0] lcx [0:31];
    (* ramstyle = "MLAB, no_rw_check" *) logic [84:0] lcy [0:31];
    logic  [4:0] lc_wa;
    logic [84:0] lc_wd;
    logic        lcx_we, lcy_we;
    wire  [84:0] lcx_rd = lcx[vf_ra];
    wire  [84:0] lcy_rd = lcy[vf_ra];

    // ---- chip state --------------------------------------------------------
    logic  [6:0] page /*verilator public_flat_rd*/;
    logic  [4:0] active /*verilator public_flat_rd*/;
    logic  [7:0] irqv;
    assign out_active = active;
    assign irqv_out   = irqv;

    // ---- write queue: {is_bank, voice[4:0]/reg[3:0], data[15:0], be[1:0]} ---
    // 256 deep: the driver sets a voice up with a burst of ~100 writes a
    // few hundred ns apart, more than one sample period holds (64 was not
    // enough -- the write that started the first voice was lost)
    logic [23:0] wq [0:255];
    logic  [7:0] wq_wp, wq_rp;
    wire         wq_empty = (wq_wp == wq_rp);
    wire         wq_full  = (wq_wp + 8'd1 == wq_rp);
    always_ff @(posedge clk) begin
        if (reset) begin wq_wp <= 8'd0; dbg_wqdrop <= 16'd0; end
        else if (es_we || bk_we) begin
            if (wq_full) dbg_wqdrop <= dbg_wqdrop + 16'd1;
            else begin
                wq[wq_wp] <= es_we ? {1'b0, 1'b0, es_reg, es_data, es_be}
                                   : {1'b1, bk_voice, 13'd0, bk_data, 2'b11};
                wq_wp <= wq_wp + 8'd1;
            end
        end
    end
    wire [23:0] wqh      = wq[wq_rp];
    wire        wq_isbk  = wqh[23];
    wire  [4:0] wq_voice = wqh[22:18];
    wire  [3:0] wq_reg   = wqh[21:18];
    wire [15:0] wq_data  = wqh[17:2];
    wire        wq_hi    = wqh[1];
    wire        wq_lo    = wqh[0];
    wire  [4:0] wq_tv    = wq_isbk ? wq_voice : page[4:0];    // target voice

    // ---- helpers -------------------------------------------------------------
    function automatic logic [15:0] vol_lut(input logic [7:0] i);
        logic [3:0] e; logic [4:0] m; logic [15:0] v;
        e = i[7:4]; m = {1'b1, i[3:0]};
        v = 16'(m) << 11;
        vol_lut = v >> (5'd16 - {1'b0, e});
    endfunction
    function automatic logic signed [15:0] line_sample(input logic [63:0] line, input logic [2:0] k);
        line_sample = {line[8 * k +: 8], 8'h00};
    endfunction

    // ---- the sequencer ------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE, A_NXT, A_RD, A_MOD, V_RD, V_CHK, V_MISS,
        V_I0, V_I1, V_I2,                       // interpolation: two products, sum
        V_F1A, V_F1B, V_F2A, V_F2B,             // poles 1, 2: multiply / divide+add
        V_F3A, V_F3B, V_F4A, V_F4B,             // poles 3, 4 (mode dependent)
        V_V0, V_V1, V_V2,                       // volumes: left, right
        V_END, S_OUT,
        R_GET, R_MUX, R_MISS                    // host register read
    } st_t;
    st_t st;

    logic  [4:0] vn;
    logic        tick_pend;
    logic        idle_drain;            // the queue is being applied between samples
    logic        sweeping;              // the reset clear of the 32 records is in progress
    logic        rd_done;               // this bus cycle's read has been answered
    wire         in_read = (st == R_GET) || (st == R_MUX) || (st == R_MISS);
    logic signed [31:0] acc [0:7];

    // the voice under work, unpacked from `r`
    logic [VW-1:0] r;
    logic  [2:0] bank;   logic [15:0] ctrl, fc, k2, k1;
    logic [28:0] vstart, vend, accum;
    logic  [7:0] lvol, rvol;
    logic signed [23:0] o1n1, o2n1, o2n2, o3n1, o3n2, o4n1;
    always_comb begin
        {bank, ctrl, fc, vstart, vend, accum, k2, k1, lvol, rvol, o1n1, o2n1, o2n2, o3n1, o3n2, o4n1} = r;
    end
    wire  [14:0] step  = fc[15:1];
    wire  [19:0] ia0   = accum[28:9];
    wire  [19:0] ia1   = accum[28:9] + 20'd1;
    wire  [19:0] tag0  = {bank, ia0[19:3]};
    wire  [19:0] tag1  = {bank, ia1[19:3]};
    wire         stopped = |(ctrl & (C_STOP0 | C_STOP1));
    wire  [1:0]  lp = ctrl[11:10];
    wire  [1:0]  ca = ctrl[9:8];

    // the voice's two cache slots, registered copies with lookup
    logic [84:0] lx, ly;
    // Bit 84 is valid, [83:64] the 20-bit tag, [63:0] the line. These indices
    // MUST move with the tag width: when the tag went 19 -> 20 bits for the
    // third otisbank bit and these still read lx[83]/lx[82:64], the valid bit
    // became the tag's top bit -- which is bank[2], zero for every game that
    // is not Puzzle Bobble 3/4 -- so the cache never hit and every sample
    // went to SDRAM. Quartus found it before the fitter did: it pruned the
    // unread bit 84 and built an 84-bit MLAB from an 85-bit declaration, and
    // that width mismatch in the map report is the only place it showed. The
    // es5505 bench cannot see it, because a cache miss returns the same
    // sample, only slower.
    wire x0 = lx[84] && (lx[83:64] == tag0), y0 = ly[84] && (ly[83:64] == tag0);
    wire x1 = lx[84] && (lx[83:64] == tag1), y1 = ly[84] && (ly[83:64] == tag1);
    wire have0 = x0 | y0, have1 = x1 | y1;
    wire [63:0] line0 = x0 ? lx[63:0] : ly[63:0];
    wire [63:0] line1 = x1 ? lx[63:0] : ly[63:0];
    // which slot a miss refills: never the one holding the other sample
    logic        miss_is1;              // the pending miss is for tag1
    wire         victim_y = miss_is1 ? x0 : x1;   // evict Y if X holds the other

    // working values through the stages
    logic signed [15:0] s0, s1;
    wire  signed [17:0] w1 = 18'($signed({9'd0, accum[8:0]}));       // frac
    wire  signed [17:0] w0 = 18'sd512 - w1;                           // 512 - frac
    logic signed [31:0] val;
    logic signed [51:0] p0;                                           // first interpolation product
    logic [28:0] nacc;
    logic [15:0] nctrl;
    logic signed [23:0] n1, n21, n22, n31, n32, n4;

    // the one multiplier: operands REGISTERED in an "A" state, the product
    // combinational from them and consumed (registered) in the "B" state
    // that follows -- one DSP delay plus an adder per cycle
    logic signed [33:0] mul_a;
    logic signed [17:0] mul_b;
    wire  signed [51:0] mul_p = mul_a * mul_b;

    // C's truncating divisions of the product by 2^12 and 2^13
    wire signed [39:0] q12 = 40'((mul_p < 0) ? ((mul_p + 52'sd4095) >>> 12) : (mul_p >>> 12));
    wire signed [39:0] q13 = 40'((mul_p < 0) ? ((mul_p + 52'sd8191) >>> 13) : (mul_p >>> 13));
    // the pole register the current highpass uses, halved with truncation
    function automatic logic signed [31:0] half(input logic signed [23:0] i);
        half = (i < 0) ? ((32'(i) + 32'sd1) >>> 1) : (32'(i) >>> 1);
    endfunction
    wire [12:0] k1s = {1'b0, k1[15:4]};
    wire [12:0] k2s = {1'b0, k2[15:4]};

    // ---- register-write application (A_MOD), field by field ------------------
    // Each field of the record gets its own small update mux; the record is
    // reassembled by wiring. (Rebuilding the whole 314-bit record in every
    // arm of one case cost ~2000 ALMs.)
    wire lo_pg = (page < 7'h20);
    wire hi_pg = (page >= 7'h20) && (page < 7'h40);
    wire [3:0] rg = wq_reg;
    wire w_lo = wq_lo, w_hi = wq_hi;
    wire [15:0] d = wq_data;

    // control: reg 0 on both register pages
    wire        u_ctrl = !wq_isbk && (lo_pg || hi_pg) && (rg == 4'h0);
    wire [15:0] ctrl_n = {4'hF, w_hi ? d[11:8] : ctrl[11:8], w_lo ? d[7:0] : ctrl[7:0]};
    // FC
    wire        u_fc   = !wq_isbk && lo_pg && (rg == 4'h1);
    wire [15:0] fc_n   = {w_hi ? d[15:8] : fc[15:8], w_lo ? {d[7:1], 1'b0} : fc[7:0]};
    // start / end / accum: hi word (regs 2/4/A) and lo word (3/5/B)
    function automatic logic [28:0] upd_addr(input logic [28:0] v, input logic hiw, input logic acc_lo);
        // hiw: the register's high word; acc_lo: ACC lo keeps bits 4:0 too
        logic [28:0] r; r = v;
        if (hiw) begin
            if (w_lo) r[23:16] = d[7:0];
            if (w_hi) r[28:24] = d[12:8];
        end else begin
            if (w_lo) begin if (acc_lo) r[7:0] = d[7:0]; else r[7:5] = d[7:5]; end
            if (w_hi) r[15:8] = d[15:8];
        end
        upd_addr = r;
    endfunction
    wire        u_st   = !wq_isbk && lo_pg && (rg == 4'h2 || rg == 4'h3);
    wire [28:0] st_n   = upd_addr(vstart, rg == 4'h2, 1'b0);
    wire        u_en   = !wq_isbk && lo_pg && (rg == 4'h4 || rg == 4'h5);
    wire [28:0] en_n   = upd_addr(vend, rg == 4'h4, 1'b0);
    wire        u_ac   = !wq_isbk && lo_pg && (rg == 4'hA || rg == 4'hB);
    wire [28:0] ac_n   = upd_addr(accum, rg == 4'hA, 1'b1);
    // K2 / K1
    wire        u_k2   = !wq_isbk && lo_pg && (rg == 4'h6);
    wire [15:0] k2_n   = {w_hi ? d[15:8] : k2[15:8], w_lo ? d[7:4] : k2[7:4], k2[3:0]};
    wire        u_k1   = !wq_isbk && lo_pg && (rg == 4'h7);
    wire [15:0] k1_n   = {w_hi ? d[15:8] : k1[15:8], w_lo ? d[7:4] : k1[7:4], k1[3:0]};
    // volumes: high byte only
    wire        u_lv   = !wq_isbk && lo_pg && (rg == 4'h8) && w_hi;
    wire        u_rv   = !wq_isbk && lo_pg && (rg == 4'h9) && w_hi;
    // filter poles (high page, regs 1-6): lo lane keeps the top bits, hi lane
    // sign-extends the 16-bit value
    function automatic logic signed [23:0] upd_pole(input logic signed [23:0] v);
        logic [23:0] r; r = v;
        if (w_lo) r[7:0] = d[7:0];
        if (w_hi) r = {{8{d[15]}}, d[15:8], r[7:0]};
        upd_pole = r;
    endfunction
    wire u_p4  = !wq_isbk && hi_pg && (rg == 4'h1);
    wire u_p31 = !wq_isbk && hi_pg && (rg == 4'h2);
    wire u_p32 = !wq_isbk && hi_pg && (rg == 4'h3);
    wire u_p21 = !wq_isbk && hi_pg && (rg == 4'h4);
    wire u_p22 = !wq_isbk && hi_pg && (rg == 4'h5);
    wire u_p1  = !wq_isbk && hi_pg && (rg == 4'h6);

    wire wr_rec_we = wq_isbk | u_ctrl | u_fc | u_st | u_en | u_ac | u_k2 | u_k1 | u_lv | u_rv
                   | u_p4 | u_p31 | u_p32 | u_p21 | u_p22 | u_p1;
    wire [VW-1:0] wr_rec = {
        wq_isbk ? (d[2:0] & bank_mask) : bank,
        u_ctrl  ? ctrl_n : ctrl,
        u_fc    ? fc_n   : fc,
        u_st    ? st_n   : vstart,
        u_en    ? en_n   : vend,
        u_ac    ? ac_n   : accum,
        u_k2    ? k2_n   : k2,
        u_k1    ? k1_n   : k1,
        u_lv    ? d[15:8] : lvol,
        u_rv    ? d[15:8] : rvol,
        u_p1    ? upd_pole(o1n1) : o1n1,
        u_p21   ? upd_pole(o2n1) : o2n1,
        u_p22   ? upd_pole(o2n2) : o2n2,
        u_p31   ? upd_pole(o3n1) : o3n1,
        u_p32   ? upd_pole(o3n2) : o3n2,
        u_p4    ? upd_pole(o4n1) : o4n1
    };
    wire wq_is_page = !wq_isbk && (wq_reg == 4'hF) && wq_lo;
    wire wq_is_act  = !wq_isbk && (wq_reg == 4'hD) && wq_lo;

    // ---- loop end handling (V_END), MAME's check_for_end_* for the 5505 -----
    logic [28:0] end_acc;
    logic [15:0] end_ctrl;
    always_comb begin
        end_acc  = nacc;
        end_ctrl = ctrl;
        if (!(ctrl & C_DIR)) begin
            if (nacc > vend) begin
                if (ctrl & C_IRQE) end_ctrl = end_ctrl | C_IRQ;
                case (ctrl & (C_LPE | C_BLE))
                    C_LPE:         end_acc = vstart + (nacc - vend);
                    C_LPE | C_BLE: begin end_acc = vend - (nacc - vend); end_ctrl = end_ctrl ^ C_DIR; end
                    default:       end_ctrl = end_ctrl | C_STOP0;
                endcase
            end
        end else begin
            if (nacc < vstart) begin
                if (ctrl & C_IRQE) end_ctrl = end_ctrl | C_IRQ;
                case (ctrl & (C_LPE | C_BLE))
                    C_LPE:         end_acc = vend - (vstart - nacc);
                    C_LPE | C_BLE: begin end_acc = vstart + (vstart - nacc); end_ctrl = end_ctrl ^ C_DIR; end
                    default:       end_ctrl = end_ctrl | C_STOP0;
                endcase
            end
        end
    end

    // ---- host read mux: es5505_device::reg_read_low/high/test ------------
    // From the page's record in `r` (loaded in R_GET). STRT/END/ACC are kept
    // in register form ({hi[12:0], lo[15:0]}), so the halves come straight
    // out; the pole registers give their low 16 bits.
    logic [15:0] rd_mux;
    always_comb begin
        rd_mux = 16'h0000;
        case (rd_reg)
            4'hD: rd_mux = {11'd0, active};                   // ACT
            4'hE: rd_mux = {8'h00, irqv};                     // IRQV
            4'hF: rd_mux = {9'd0, page};                      // PAGE
            default: begin
                if (page < 7'h20) begin
                    case (rd_reg)
                        4'h0: rd_mux = ctrl | 16'hF000;
                        4'h1: rd_mux = fc;
                        4'h2: rd_mux = {3'd0, vstart[28:16]};
                        4'h3: rd_mux = vstart[15:0];
                        4'h4: rd_mux = {3'd0, vend[28:16]};
                        4'h5: rd_mux = vend[15:0];
                        4'h6: rd_mux = k2;
                        4'h7: rd_mux = k1;
                        4'h8: rd_mux = {lvol, 8'h00};
                        4'h9: rd_mux = {rvol, 8'h00};
                        4'hA: rd_mux = {3'd0, accum[28:16]};
                        4'hB: rd_mux = accum[15:0];
                        default: rd_mux = 16'h0000;
                    endcase
                end else if (page < 7'h40) begin
                    case (rd_reg)
                        4'h0: rd_mux = ctrl | 16'hF000;
                        4'h1: rd_mux = o4n1[15:0];
                        4'h2: rd_mux = o3n1[15:0];
                        4'h3: rd_mux = o3n2[15:0];
                        4'h4: rd_mux = o2n1[15:0];
                        4'h5: rd_mux = o2n2[15:0];
                        4'h6: rd_mux = o1n1[15:0];
                        default: rd_mux = 16'h0000;
                    endcase
                end else begin
                    rd_mux = (rd_reg == 4'h8) ? 16'h07F8 : 16'h0000;   // SERMODE (mode 0), CHx/PAR 0
                end
            end
        endcase
    end
    // the Taito data-reader path: O1(n-1) read on a STOPPED voice returns
    // the raw sample word at the accumulator (and stores it as o1n1)
    wire rd_o1_stopped = (page >= 7'h20) && (page < 7'h40) && (rd_reg == 4'h6) && stopped;

    // ---- sequencer -------------------------------------------------------
    always_ff @(posedge clk) begin
        sm_req    <= 1'b0;
        vf_we     <= 1'b0;
        lcx_we    <= 1'b0;
        lcy_we    <= 1'b0;
        out_valid <= 1'b0;
        if (tick) begin
            // mid-sample means the voice loop (or the tick's own queue drain)
            // is still running; an idle-time drain or a host read is not
            if (tick_pend || (st != S_IDLE && !idle_drain && !in_read)) dbg_overrun <= dbg_overrun + 16'd1;
            tick_pend <= 1'b1;
        end
        // the read handshake follows the bus cycle
        if (!rd_req) begin rd_valid <= 1'b0; rd_done <= 1'b0; end
        // es5505_device::read of IRQV acknowledges: the vector goes back to
        // "nothing pending" (the sequencer's own writes to irqv, in V_CHK and
        // V_END, take precedence when they coincide)
        if (irqv_ack) irqv <= 8'h80;

        if (reset) begin
            st <= S_IDLE; page <= 7'd0; active <= 5'h1F; irqv <= 8'h80;
            wq_rp <= 8'd0; tick_pend <= 1'b0; dbg_overrun <= 16'd0; dbg_miss <= 16'd0;
            idle_drain <= 1'b0; rd_valid <= 1'b0; rd_done <= 1'b0; rd_data <= 16'h0000;
            sweeping <= 1'b1;
            vn <= 5'd0; vf_ra <= 5'd0;
            // clear the voice file: STOP, volumes at half (compute_tables)
            vf_we <= 1'b1; vf_wa <= 5'd0;
            vf_wd <= {3'd0, 16'h0003, 16'd0, 29'd0, 29'd0, 29'd0, 16'd0, 16'd0, 8'h80, 8'h80, 144'd0};
            lcx_we <= 1'b1; lcy_we <= 1'b1; lc_wa <= 5'd0; lc_wd <= 85'd0;
        end else case (st)
            S_IDLE: begin
                if (sweeping) begin
                    // reset sweep over the 32 records and cache slots. An
                    // explicit flag: the idle drain and the host read also
                    // enter S_IDLE with a record write in flight, and "vf_we
                    // still high" would restart the sweep from that voice
                    if (vf_wa == 5'd31) sweeping <= 1'b0;
                    else begin
                        vf_we <= 1'b1; vf_wa <= vf_wa + 5'd1;
                        lcx_we <= 1'b1; lcy_we <= 1'b1; lc_wa <= vf_wa + 5'd1;
                    end
                end else if (tick_pend) begin
                    tick_pend <= 1'b0;
                    for (int c = 0; c < 8; c++) acc[c] <= 32'sd0;
                    vf_ra <= 5'd0;
                    idle_drain <= 1'b0;
                    st <= wq_empty ? V_RD : A_NXT;
                end else if (!wq_empty) begin
                    // apply writes as they come, between samples: the same
                    // ordering as waiting for the tick (every sample up to
                    // now is done, the next is not), but a read that follows
                    // a write sees it -- the driver writes a page or an
                    // accumulator and reads straight back
                    idle_drain <= 1'b1;
                    st <= A_NXT;
                end else if (rd_req && !rd_done) begin
                    vf_ra <= page[4:0];
                    st <= R_GET;
                end
            end

            // ---- register writes, three cycles each: point the voice file
            // at the write's voice (the queue's head, read through its one
            // port), read the record, modify and write it back
            A_NXT: begin
                vf_ra <= wq_tv;
                st    <= A_RD;
            end

            // The voice-file write is registered and lands a cycle after
            // A_MOD, so a read of the same voice right behind it must take
            // the pending write (the driver writes a voice's registers back
            // to back)
            A_RD: begin
                r  <= (vf_we && vf_wa == vf_ra) ? vf_wd : vf_rd;
                st <= A_MOD;
            end
            A_MOD: begin
                if (wq_is_page) page <= wq_data[6:0];
                else if (wq_is_act) active <= wq_data[4:0];
                else if (wr_rec_we) begin
                    vf_we <= 1'b1; vf_wa <= wq_tv; vf_wd <= wr_rec;
                end
                wq_rp <= wq_rp + 8'd1;
                if (wq_wp == wq_rp + 8'd1) begin
                    if (idle_drain && !tick_pend) begin
                        st <= S_IDLE;
                    end else begin
                        // the tick's drain, or a tick arrived during an idle
                        // drain: start the sample (for the idle case this is
                        // what S_IDLE would have done on the pending tick)
                        if (idle_drain) begin
                            tick_pend <= 1'b0;
                            for (int c = 0; c < 8; c++) acc[c] <= 32'sd0;
                            idle_drain <= 1'b0;
                        end
                        vf_ra <= 5'd0;
                        st    <= V_RD;
                    end
                end else begin
                    st    <= A_NXT;
                end
            end

            // ---- the voice loop
            V_RD: begin
                r  <= (vf_we && vf_wa == vf_ra) ? vf_wd : vf_rd;
                lx <= (lcx_we && lc_wa == vf_ra) ? lc_wd : lcx_rd;
                ly <= (lcy_we && lc_wa == vf_ra) ? lc_wd : lcy_rd;
                st <= V_CHK;
            end
            V_CHK: begin
                if (stopped) begin
                    // generate_irq still runs for a stopped voice
                    if ((ctrl & C_IRQ) && irqv[7]) begin
                        irqv  <= {3'd0, vn};
                        vf_we <= 1'b1; vf_wa <= vn;
                        vf_wd <= {bank, ctrl & ~C_IRQ, fc, vstart, vend, accum, k2, k1, lvol, rvol, o1n1, o2n1, o2n2, o3n1, o3n2, o4n1};
                    end
                    if (vn == active) st <= S_OUT;
                    else begin vn <= vn + 5'd1; vf_ra <= vn + 5'd1; st <= V_RD; end
                end else if (!have0) begin
                    miss_is1 <= 1'b0; sm_addr <= tag0; sm_req <= 1'b1; st <= V_MISS;
                    dbg_miss <= dbg_miss + 16'd1;
                end else if (!have1) begin
                    miss_is1 <= 1'b1; sm_addr <= tag1; sm_req <= 1'b1; st <= V_MISS;
                    dbg_miss <= dbg_miss + 16'd1;
                end else begin
                    s0 <= line_sample(line0, ia0[2:0]);
                    s1 <= line_sample(line1, ia1[2:0]);
                    st <= V_I0;
                end
            end
            V_MISS: if (sm_valid) begin
                // refill the slot not holding the other sample, in the
                // registered copy and in the cache file
                lc_wa <= vn;
                lc_wd <= {1'b1, sm_addr, sm_line};
                if (victim_y) begin ly <= {1'b1, sm_addr, sm_line}; lcy_we <= 1'b1; end
                else          begin lx <= {1'b1, sm_addr, sm_line}; lcx_we <= 1'b1; end
                st <= V_CHK;
            end
            // ---- interpolation: (s0 * (512 - frac) + s1 * frac) >> 9
            V_I0: begin
                mul_a <= 34'(s0); mul_b <= w0;
                st <= V_I1;
            end
            V_I1: begin
                p0 <= mul_p;
                mul_a <= 34'(s1); mul_b <= w1;
                st <= V_I2;
            end
            V_I2: begin
                val  <= 32'((p0 + mul_p) >>> 9);
                nacc <= (ctrl & C_DIR) ? (accum - {14'd0, step}) : (accum + {14'd0, step});
                st   <= V_F1A;
            end
            // ---- pole 1: lowpass with K1: trunc(k * (val - o1n1) / 4096) + o1n1
            V_F1A: begin
                mul_a <= 34'(val) - 34'(o1n1); mul_b <= 18'(k1s);
                st <= V_F1B;
            end
            V_F1B: begin
                val <= 32'(q12) + 32'(o1n1);
                n1  <= 24'(32'(q12) + 32'(o1n1));
                st  <= V_F2A;
            end
            // ---- pole 2: lowpass with K1
            V_F2A: begin
                mul_a <= 34'(val) - 34'(o2n1); mul_b <= 18'(k1s);
                st <= V_F2B;
            end
            V_F2B: begin
                val <= 32'(q12) + 32'(o2n1);
                n21 <= 24'(32'(q12) + 32'(o2n1));
                n22 <= o2n1;
                st  <= V_F3A;
            end
            // ---- pole 3 by mode: 0 = highpass K2 (k * o3n1), else lowpass
            //      (K1 for modes 1 and 3, K2 for mode 2), prev = the NEW o2n2
            V_F3A: begin
                mul_a <= (lp == 2'd0) ? 34'(o3n1) : (34'(val) - 34'(o3n1));
                mul_b <= (lp == 2'd0 || lp == 2'd2) ? 18'(k2s) : 18'(k1s);
                st <= V_F3B;
            end
            V_F3B: begin
                if (lp == 2'd0) begin
                    val <= val - 32'(n22) + 32'(q13) + half(o3n1);
                    n31 <= 24'(val - 32'(n22) + 32'(q13) + half(o3n1));
                end else begin
                    val <= 32'(q12) + 32'(o3n1);
                    n31 <= 24'(32'(q12) + 32'(o3n1));
                end
                n32 <= o3n1;
                st  <= V_F4A;
            end
            // ---- pole 4: modes 0/1 highpass K2 (k * o4n1, prev = NEW o3n2), 2/3 lowpass K2
            V_F4A: begin
                mul_a <= lp[1] ? (34'(val) - 34'(o4n1)) : 34'(o4n1);
                mul_b <= 18'(k2s);
                st <= V_F4B;
            end
            V_F4B: begin
                if (lp[1]) begin
                    val <= 32'(q12) + 32'(o4n1);
                    n4  <= 24'(32'(q12) + 32'(o4n1));
                end else begin
                    val <= val - 32'(n32) + 32'(q13) + half(o4n1);
                    n4  <= 24'(val - 32'(n32) + 32'(q13) + half(o4n1));
                end
                st <= V_V0;
            end
            // ---- volumes: (val * volume) >> 11 into the pair's channels
            V_V0: begin
                mul_a <= 34'(val); mul_b <= 18'($signed({2'b00, vol_lut(lvol)}));
                st <= V_V1;
            end
            V_V1: begin
                acc[{ca, 1'b0}] <= acc[{ca, 1'b0}] + 32'(mul_p >>> 11);
                mul_a <= 34'(val); mul_b <= 18'($signed({2'b00, vol_lut(rvol)}));
                st <= V_V2;
            end
            V_V2: begin
                acc[{ca, 1'b1}] <= acc[{ca, 1'b1}] + 32'(mul_p >>> 11);
                st <= V_END;
            end
            V_END: begin
                // loop/stop, then generate_irq, then the write-back
                nctrl = end_ctrl;
                if ((end_ctrl & C_IRQ) && irqv[7]) begin
                    irqv  <= {3'd0, vn};
                    nctrl = end_ctrl & ~C_IRQ;
                end
                vf_we <= 1'b1; vf_wa <= vn;
                vf_wd <= {bank, nctrl, fc, vstart, vend, end_acc, k2, k1, lvol, rvol, n1, n21, n22, n31, n32, n4};
                if (vn == active) st <= S_OUT;
                else begin vn <= vn + 5'd1; vf_ra <= vn + 5'd1; st <= V_RD; end
            end

            // ---- host register read: the page's record, then the mux; the
            // stopped-voice O1(n-1) case fetches the sample word at the
            // accumulator through the voice's line cache (a miss goes to
            // the sample bus, which is idle here) and stores it as o1n1
            R_GET: begin
                r  <= (vf_we && vf_wa == vf_ra) ? vf_wd : vf_rd;
                lx <= (lcx_we && lc_wa == vf_ra) ? lc_wd : lcx_rd;
                ly <= (lcy_we && lc_wa == vf_ra) ? lc_wd : lcy_rd;
                st <= R_MUX;
            end
            R_MUX: begin
                if (rd_o1_stopped && !have0) begin
                    miss_is1 <= 1'b0; sm_addr <= tag0; sm_req <= 1'b1; st <= R_MISS;
                    dbg_miss <= dbg_miss + 16'd1;
                end else begin
                    if (rd_o1_stopped) begin
                        rd_data <= line_sample(line0, ia0[2:0]);
                        vf_we <= 1'b1; vf_wa <= vf_ra;
                        vf_wd <= {bank, ctrl, fc, vstart, vend, accum, k2, k1, lvol, rvol,
                                  24'(line_sample(line0, ia0[2:0])), o2n1, o2n2, o3n1, o3n2, o4n1};
                    end else begin
                        rd_data <= rd_mux;
                    end
                    rd_valid <= 1'b1; rd_done <= 1'b1;
                    st <= S_IDLE;
                end
            end
            R_MISS: if (sm_valid) begin
                lc_wa <= vf_ra;
                lc_wd <= {1'b1, sm_addr, sm_line};
                if (victim_y) begin ly <= {1'b1, sm_addr, sm_line}; lcy_we <= 1'b1; end
                else          begin lx <= {1'b1, sm_addr, sm_line}; lcx_we <= 1'b1; end
                st <= R_MUX;
            end

            S_OUT: begin
                for (int c = 0; c < 8; c++)
                    out_ch[c] <= (acc[c] > 32'sd524287) ? 20'sd524287 :
                                 (acc[c] < -32'sd524288) ? -20'sd524288 : 20'(acc[c]);
                out_valid <= 1'b1;
                vn <= 5'd0;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end

    // the cache file writes (registered strobes above)
    always_ff @(posedge clk) begin
        if (lcx_we) lcx[lc_wa] <= lc_wd;
        if (lcy_we) lcy[lc_wa] <= lc_wd;
        if (vf_we)  vf[vf_wa]  <= vf_wd;
    end

endmodule
