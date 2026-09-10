//
// sdram
// Copyright (c) 2015-2019 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

module sdram
(
    input             init,        // reset to initialize RAM
    input             clk,         // clock 64MHz
   
    input             doRefresh,

    inout      [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
    output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
    output            SDRAM_DQML,  // two byte masks
    output            SDRAM_DQMH,  // 
    output reg  [1:0] SDRAM_BA,    // two banks
    output            SDRAM_nCS,   // a single chip select
    output            SDRAM_nWE,   // write enable
    output            SDRAM_nRAS,  // row address select
    output            SDRAM_nCAS,  // columns address select
    output            SDRAM_CKE,   // clock enable
    output            SDRAM_CLK,   // clock for chip

    input      [26:1] ch1_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
    output reg [63:0] ch1_dout,    // data output to cpu -- 64-bit since
                                   // 2026-08-24: the chip is programmed
                                   // BURST_LENGTH=4, so every ch1 read
                                   // already put 4 words on the bus and
                                   // this channel latched only the first
                                   // two. ch2/3/4 always took all four.
                                   // Taking all four costs 2 cycles of
                                   // latency and doubles the bytes per
                                   // CDC round trip -- which is what the
                                   // texel fetch is actually bound by.
    input             ch1_req,     // request
    output reg        ch1_ready,
    
    input      [26:1] ch2_addr,    
    output reg [63:0] ch2_dout,    
    input             ch2_req,     
    output reg        ch2_ready,

    input      [26:1] ch3_addr,
    output reg [63:0] ch3_dout,
    input      [15:0] ch3_din,
    input      [ 1:0] ch3_be,
    input             ch3_req,
    input             ch3_rnw,     // 1 - read, 0 - write
    output reg        ch3_ready,

    input      [26:1] ch4_addr,
    output reg [63:0] ch4_dout,
    input             ch4_req,
    output reg        ch4_ready,

    // ch5: the sound 68000's program fetch (2026-08-27, Phase 3). Read
    // only, served after the main CPU and before the sprites: the sound
    // CPU stalls on every miss, the sprite draw has a ring to absorb its
    // waits (rf_video_spr).
    input      [26:1] ch5_addr,
    output reg [63:0] ch5_dout,
    input             ch5_req,
    output reg        ch5_ready,

    // ch6: ES5505 sample lines (rf_smp_bus). Read only, lowest priority:
    // the sampler's per-voice line cache makes its fetches few and its
    // deadline soft (a whole sample period).
    input      [26:1] ch6_addr,
    output reg [63:0] ch6_dout,
    input             ch6_req,
    output reg        ch6_ready,

    // ch7: the SECOND sprite graphics channel (2026-08-29). The sprite
    // engine has two fetch buses and each needs two planes; with all four
    // behind one channel a sharer can only hold ONE burst outstanding, so a
    // dense line's bursts were strictly serial and its draw time was
    // (bursts x round trip) with nothing overlapped -- which is what made
    // sprites vanish from the bottom of the screen in attract. One channel
    // per bus lets the two records overlap. Sits immediately after ch4 so
    // the sprite path's priority against the other clients is unchanged;
    // the only thing that changed is how many of its bursts can be in
    // flight at once.
    input      [26:1] ch7_addr,
    output reg [63:0] ch7_dout,
    input             ch7_req,
    output reg        ch7_ready,

    // ch8: the pivot store (rf_pivot_bus). READ/WRITE like ch3, lowest
    // priority in the chain -- its fills have eight scanlines of slack and
    // must never delay a playfield or sprite fetch.
    input      [26:1] ch8_addr,
    input      [15:0] ch8_din,
    input       [1:0] ch8_be,
    input             ch8_rnw,
    output reg [63:0] ch8_dout,
    input             ch8_req,
    output reg        ch8_ready
);

// DQ drive in canonical explicit-OE form. The original wrote 16'bZ into an
// `inout reg` as the release; Quartus synthesizes that correctly (proven on
// Raiden II hardware) but Verilator 5.051 never clears the drive, so every
// read after the first write ORs in stale write data. The raiden2 sdmain
// harness never caught it because it backdoor-loads the ROM and never
// exercises pin-side writes (tb_sdmain.cpp:91). This form synthesizes to
// the identical OE and simulates honestly in both worlds.
reg [15:0] dq_drv;
reg        dq_drv_oe;
assign SDRAM_DQ = dq_drv_oe ? dq_drv : 16'bZ;

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];


// Burst length = 4
localparam BURST_LENGTH        = 4;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd3;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam cycles_per_refresh  = 14'd500;  // (64000*64)/8192-1 Calc'd as (64ms @ 64MHz)/8192 rose
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;
reg        chip;

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_RW1     = 2;
localparam STATE_IDLE    = 4;
localparam STATE_IDLE_1  = 5;
localparam STATE_IDLE_2  = 6;
localparam STATE_IDLE_3  = 7;
localparam STATE_IDLE_4  = 8;
localparam STATE_IDLE_5  = 9;
localparam STATE_RFSH    = 10;


always @(posedge clk) begin
    reg [CAS_LATENCY+BURST_LENGTH+1:0] data_ready_delay1, data_ready_delay2, data_ready_delay3, data_ready_delay4, data_ready_delay5, data_ready_delay6, data_ready_delay7, data_ready_delay8;

    reg        saved_wr;
    reg [12:0] cas_addr;
    reg [15:0] saved_data;
    reg [15:0] dq_reg;
    // The in-block initializer is the INTENDED power-on-once idiom here: the
    // controller starts in STARTUP exactly once and its own init sequence
    // handles every later reset. This is the narrow, documented exception to
    // the project-wide IMPLICITSTATIC gate (see HANDOFF #60) -- do not turn
    // this into a blanket waiver.
    /* verilator lint_off IMPLICITSTATIC */
    reg  [3:0] state = STATE_STARTUP;
    /* verilator lint_on IMPLICITSTATIC */

    // One sampling flop per crossing request net, then edge-detect between two
    // REGISTERED stages. The original compared the raw clk_sys-domain net
    // against its registered history -- two destinations for one crossing net.
    // The SDC's multicycle-2 relaxation legally allows enough skew between
    // those endpoints that the history flop can catch a rising edge a cycle
    // before the direct path does, and `req & ~req_1` then never fires: the
    // request is silently dropped and the client waits forever. This is
    // placement-dependent, which is why enabling ch4 (a refit) stalled the
    // CPU's ch3 fetches even though ch4 has the lowest priority here.
    reg       ch1_req_s, ch2_req_s, ch3_req_s, ch4_req_s, ch5_req_s, ch6_req_s, ch7_req_s, ch8_req_s;
    reg       ch1_req_1, ch2_req_1, ch3_req_1, ch4_req_1, ch5_req_1, ch6_req_1, ch7_req_1, ch8_req_1;
    reg       ch8_rq;
    reg [26:1] ch8_addr_1;
    reg [15:0] ch8_din_1;
    reg  [1:0] ch8_be_1;
    reg        ch8_rnw_1;
    reg       ch1_rq, ch2_rq, ch3_rq, ch4_rq, ch5_rq, ch6_rq, ch7_rq;
    // Which of the two sprite channels gets first refusal this time. They
    // MUST alternate rather than sit at fixed priority -- see the note at
    // the ch4/ch7 arm below; a strict order makes the pair worse than the
    // single shared channel they replaced.
    reg       spr_tog;
    reg [3:0] ch;

    reg        ch3_rnw_1;
    reg [26:1] ch3_addr_1;
    reg [15:0] ch3_din_1;
    reg [ 1:0] ch3_be_1;
    
    reg        doRefresh_1;
    
    ch1_req_s <= ch1_req;  ch1_req_1 <= ch1_req_s;
    ch2_req_s <= ch2_req;  ch2_req_1 <= ch2_req_s;
    ch3_req_s <= ch3_req;  ch3_req_1 <= ch3_req_s;
    ch4_req_s <= ch4_req;  ch4_req_1 <= ch4_req_s;
    ch5_req_s <= ch5_req;  ch5_req_1 <= ch5_req_s;
    ch6_req_s <= ch6_req;  ch6_req_1 <= ch6_req_s;
    ch7_req_s <= ch7_req;  ch7_req_1 <= ch7_req_s;
    
    ch3_rnw_1  <= ch3_rnw;
    ch8_req_s <= ch8_req;  ch8_req_1 <= ch8_req_s;
    ch8_addr_1 <= ch8_addr;  ch8_din_1 <= ch8_din;
    ch8_be_1   <= ch8_be;    ch8_rnw_1 <= ch8_rnw;
    ch3_addr_1 <= ch3_addr;
    ch3_din_1  <= ch3_din;
    ch3_be_1   <= ch3_be;
    
    doRefresh_1 <= doRefresh;

    if (ch1_req_s & ~ch1_req_1) ch1_rq <= 1;
    if (ch2_req_s & ~ch2_req_1) ch2_rq <= 1;
    if (ch3_req_s & ~ch3_req_1) ch3_rq <= 1;
    if (ch4_req_s & ~ch4_req_1) ch4_rq <= 1;
    if (ch5_req_s & ~ch5_req_1) ch5_rq <= 1;
    if (ch6_req_s & ~ch6_req_1) ch6_rq <= 1;
    if (ch7_req_s & ~ch7_req_1) ch7_rq <= 1;
    if (ch8_req_s & ~ch8_req_1) ch8_rq <= 1;

    ch1_ready <= 0;
    ch2_ready <= 0;
    ch3_ready <= 0;
    ch4_ready <= 0;
    ch5_ready <= 0;
    ch6_ready <= 0;
    ch7_ready <= 0;
    ch8_ready <= 0;

    refresh_count <= refresh_count+1'b1;

    data_ready_delay1 <= data_ready_delay1>>1;
    data_ready_delay2 <= data_ready_delay2>>1;
    data_ready_delay3 <= data_ready_delay3>>1;
    data_ready_delay4 <= data_ready_delay4>>1;
    data_ready_delay5 <= data_ready_delay5>>1;
    data_ready_delay6 <= data_ready_delay6>>1;
    data_ready_delay7 <= data_ready_delay7>>1;
    data_ready_delay8 <= data_ready_delay8>>1;

    dq_reg <= SDRAM_DQ;

    if(data_ready_delay1[4]) ch1_dout[15:00] <= dq_reg;
    if(data_ready_delay1[3]) ch1_dout[31:16] <= dq_reg;
    if(data_ready_delay1[2]) ch1_dout[47:32] <= dq_reg;
    if(data_ready_delay1[1]) ch1_dout[63:48] <= dq_reg;
    if(data_ready_delay1[1]) ch1_ready <= 1;

    if(data_ready_delay2[4]) ch2_dout[15:00] <= dq_reg;
    if(data_ready_delay2[3]) ch2_dout[31:16] <= dq_reg;
    if(data_ready_delay2[2]) ch2_dout[47:32] <= dq_reg;
    if(data_ready_delay2[1]) ch2_dout[63:48] <= dq_reg;
    if(data_ready_delay2[1]) ch2_ready <= 1;

    if(data_ready_delay3[4]) ch3_dout[15:00] <= dq_reg;
    if(data_ready_delay3[3]) ch3_dout[31:16] <= dq_reg;
    if(data_ready_delay3[2]) ch3_dout[47:32] <= dq_reg;
    if(data_ready_delay3[1]) ch3_dout[63:48] <= dq_reg;
    if(data_ready_delay3[1]) ch3_ready <= 1;

    if(data_ready_delay4[4]) ch4_dout[15:00] <= dq_reg;
    if(data_ready_delay4[3]) ch4_dout[31:16] <= dq_reg;
    if(data_ready_delay4[2]) ch4_dout[47:32] <= dq_reg;
    if(data_ready_delay4[1]) ch4_dout[63:48] <= dq_reg;
    if(data_ready_delay4[1]) ch4_ready <= 1;

    if(data_ready_delay5[4]) ch5_dout[15:00] <= dq_reg;
    if(data_ready_delay5[3]) ch5_dout[31:16] <= dq_reg;
    if(data_ready_delay5[2]) ch5_dout[47:32] <= dq_reg;
    if(data_ready_delay5[1]) ch5_dout[63:48] <= dq_reg;
    if(data_ready_delay5[1]) ch5_ready <= 1;

    if(data_ready_delay6[4]) ch6_dout[15:00] <= dq_reg;
    if(data_ready_delay6[3]) ch6_dout[31:16] <= dq_reg;
    if(data_ready_delay6[2]) ch6_dout[47:32] <= dq_reg;
    if(data_ready_delay6[1]) ch6_dout[63:48] <= dq_reg;
    if(data_ready_delay6[1]) ch6_ready <= 1;

    if(data_ready_delay7[4]) ch7_dout[15:00] <= dq_reg;
    if(data_ready_delay7[3]) ch7_dout[31:16] <= dq_reg;
    if(data_ready_delay7[2]) ch7_dout[47:32] <= dq_reg;
    if(data_ready_delay7[1]) ch7_dout[63:48] <= dq_reg;
    if(data_ready_delay7[1]) ch7_ready <= 1;

    if(data_ready_delay8[4]) ch8_dout[15:00] <= dq_reg;
    if(data_ready_delay8[3]) ch8_dout[31:16] <= dq_reg;
    if(data_ready_delay8[2]) ch8_dout[47:32] <= dq_reg;
    if(data_ready_delay8[1]) ch8_dout[63:48] <= dq_reg;
    if(data_ready_delay8[1]) ch8_ready <= 1;

    dq_drv_oe <= 1'b0;

    command <= CMD_NOP;
    case (state)
        STATE_STARTUP: begin
            SDRAM_A    <= 0;
            SDRAM_BA   <= 0;

            if (refresh_count == (startup_refresh_max-64)) chip <= 0;
            if (refresh_count == (startup_refresh_max-32)) chip <= 1;

            // All the commands during the startup are NOPS, except these
            if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
                // ensure all rows are closed
                command     <= CMD_PRECHARGE;
                SDRAM_A[10] <= 1;  // all banks
                SDRAM_BA    <= 2'b00;
            end
            if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
                // these refreshes need to be at least tREF (66ns) apart
                command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
                command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
                // Now load the mode register
                command     <= CMD_LOAD_MODE;
                SDRAM_A     <= MODE;
            end

            if (!refresh_count) begin
                state   <= STATE_IDLE;
                refresh_count <= 0;
            end
        end

        STATE_IDLE_5: state <= STATE_IDLE_4;
        STATE_IDLE_4: state <= STATE_IDLE_3;
        STATE_IDLE_3: state <= STATE_IDLE_2;
        STATE_IDLE_2: state <= STATE_IDLE_1;
        STATE_IDLE_1: state <= STATE_IDLE;

        STATE_RFSH: begin
            state    <= STATE_IDLE_5;
            command  <= CMD_AUTO_REFRESH;
            chip     <= 1;
        end

        STATE_IDLE: begin
            if (refresh_count > cycles_per_refresh) begin // emergency refresh, mainly for downloading rom/paused core
                state         <= STATE_RFSH;
                command       <= CMD_AUTO_REFRESH;
                refresh_count <= refresh_count - cycles_per_refresh + 1'd1;
                chip          <= 0;
            end 
            else if(ch2_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch2_addr[25:1]};
                chip       <= ch2_addr[26];
                saved_wr   <= 0;
                ch         <= 1;
                ch2_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch1_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch1_addr[25:1]};
                chip       <= ch1_addr[26];
                saved_wr   <= 0;
                ch         <= 0;
                ch1_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch3_rq) begin
                chip       <= ch3_addr_1[26];
                saved_data <= ch3_din_1;
                saved_wr   <= ~ch3_rnw_1;
                ch         <= 2;
                ch3_rq     <= 0;
                if (ch3_rnw_1) 
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch3_addr_1[25:1]};
                else
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~ch3_be_1, 1'b1, ch3_addr_1[25:1]};
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch5_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch5_addr[25:1]};
                chip       <= ch5_addr[26];
                saved_wr   <= 0;
                ch         <= 4;
                ch5_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            // Priority: the sprite pair sits BELOW the CPU (ch3) and the sound
            // CPU (ch5), where it started. Build 30101648 tried it above both
            // and the measurement said don't: SMP BIST:OVR:DR went 0 -> 3
            // sampler overruns (ch6 starved behind them) while SPRLINE was
            // unchanged within noise. There was nothing to win, because the
            // same build's SPRFETCH:ROWMAX showed the draw already running at
            // its floor -- 13919 clocks for 784 rows is 17.8 a row against a
            // 17-clock draw loop, so almost none of a row's time was fetch
            // wait and raising priority could not have helped.
            // ---- the two sprite graphics channels, served FAIRLY ------
            // ch4 is sprite fetch bus A, ch7 bus B. They alternate: whoever
            // was served last yields to the other next time.
            //
            // This is not a nicety. The sprite draw consumes the two buses'
            // records in STRICT ALTERNATION (rf_video_spr's q_cs), so the
            // SLOWER bus gates the pair -- a record from the fast bus cannot
            // be drawn out of turn. Under a fixed ch4-then-ch7 priority bus
            // B is served only when bus A is not asking, so B runs
            // systematically behind and the draw waits on it every other
            // record. That is worse than the ONE shared channel these
            // replaced, because a single rf_spr_ch_share round-robins its
            // four ports and so was already fair.
            //
            // Measured in sim/pipe_tb with F3_SPS_LAT / F3_SPS_LAT_B, frame
            // 2930: symmetric channels at 135 ram clocks each are exact,
            // but 90/180 -- the SAME 135 mean -- breaks the frame (67276 of
            // 71680), and 60/240 is worse than 90/90 despite the faster bus
            // A. Asymmetry costs far more than the mean latency predicts.
            //
            // The board found this the hard way: the first build with ch7
            // (29224005) improved the longest sprite line only 8 %
            // (16063 -> 14809 clocks) where the bench had predicted about
            // 2x, because the bench modelled both channels with the same
            // latency and the real controller does not.
            else if(ch4_rq && !(ch7_rq && spr_tog)) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch4_addr[25:1]};
                chip       <= ch4_addr[26];
                saved_wr   <= 0;
                ch         <= 3;
                ch4_rq     <= 0;
                spr_tog    <= 1'b1;             // next sprite burst: prefer ch7
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch7_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch7_addr[25:1]};
                chip       <= ch7_addr[26];
                saved_wr   <= 0;
                ch         <= 6;
                ch7_rq     <= 0;
                spr_tog    <= 1'b0;             // next sprite burst: prefer ch4
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch6_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch6_addr[25:1]};
                chip       <= ch6_addr[26];
                saved_wr   <= 0;
                ch         <= 5;
                ch6_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            // LAST in the chain ON PURPOSE. A pivot fill is 256 bursts every
            // eight scanlines and has a whole cell row of slack; ch6 (ES5505
            // samples) and ch7 (sprite fetch) have hard deadlines. Putting
            // ch8 above ch6 made Puzzle Bobble 3's music audibly swishy.
            else if(ch8_rq) begin
                chip       <= ch8_addr_1[26];
                saved_data <= ch8_din_1;
                saved_wr   <= ~ch8_rnw_1;
                ch         <= 7;
                ch8_rq     <= 0;
                if (ch8_rnw_1)
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch8_addr_1[25:1]};
                else
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~ch8_be_1, 1'b1, ch8_addr_1[25:1]};
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if (doRefresh_1) begin
                state         <= STATE_RFSH;
                command       <= CMD_AUTO_REFRESH;
                refresh_count <= 0;
                chip          <= 0;
            end
        end

        STATE_WAIT: state <= STATE_RW1;
        STATE_RW1: begin
            SDRAM_A <= cas_addr;
            if(saved_wr) begin
                command  <= CMD_WRITE;
                dq_drv <= saved_data;
                dq_drv_oe <= 1'b1;
                if(ch == 0) ch1_ready  <= 1;
                if(ch == 1) ch2_ready  <= 1;
                if(ch == 2) ch3_ready  <= 1;
                if(ch == 3) ch4_ready  <= 1;
                if(ch == 4) ch5_ready  <= 1;
                if(ch == 5) ch6_ready  <= 1;
                if(ch == 6) ch7_ready  <= 1;
                if(ch == 7) ch8_ready  <= 1;
                state <= STATE_IDLE_2;
            end
            else begin
                command <= CMD_READ;
                state   <= STATE_IDLE_5;
                     if(ch == 0) data_ready_delay1[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 1) data_ready_delay2[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 2) data_ready_delay3[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 3) data_ready_delay4[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 4) data_ready_delay5[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 5) data_ready_delay6[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 6) data_ready_delay7[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else             data_ready_delay8[CAS_LATENCY+BURST_LENGTH+1] <= 1;
            end
        end
      
    endcase

    if (init) begin
        state <= STATE_STARTUP;
        refresh_count <= startup_refresh_max - sdram_startup_cycles;
    end
end

altddio_out
#(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
)
sdramclk_ddr
(
    .datain_h(1'b0),
    .datain_l(1'b1),
    .outclock(clk),
    .dataout(SDRAM_CLK),
    .aclr(1'b0),
    .aset(1'b0),
    .oe(1'b1),
    .outclocken(1'b1),
    .sclr(1'b0),
    .sset(1'b0)
);

endmodule
