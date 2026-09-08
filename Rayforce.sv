//============================================================================
//  Ray Force / Gunlock (Taito F3) for MiSTer
//
//  Phase 0 proved the plumbing (MRA -> HPS -> ioctl download, F3 raster
//  timing, TG68K.C in 020 mode running the real boot ROM). Phase 1 put the
//  ROM in SDRAM behind rf_prog_bus and closed timing. Phase 2 starts here.
//
//  What this build is: the real F3 main board (rf_main.sv) -- the full
//  taito_f3.cpp memory map with every video RAM present, the vblank and
//  timer interrupts delivered, inputs and EEPROM wired -- driving a
//  diagnostic page instead of a renderer.
//
//  Why that order: with the spike's fake map the boot code ran to its vblank
//  wait at ~0x4060 and stopped, so no video RAM ever held real data. Nothing
//  in the pixel pipeline can be developed, let alone diffed against MAME,
//  until the program is actually running its frame loop. The acceptance test
//  for THIS build is therefore not a picture of the game, it is:
//
//    - download 0x00B80000 bytes, checksum 0x77E1C279, 1 MB BIST 0xD53D7C04
//    - write hash still 0x10620931 (the map got bigger; the first 4096
//      writes are boot clear loops and must not have changed)
//    - frame counter advancing at ~59 Hz, irq2 acknowledges tracking it
//    - playfield / sprite / palette write counters climbing, i.e. the game
//      is drawing
//    - the palette dump showing the game's real colours
//============================================================================

module emu
(
    input         CLK_50M,
    input         RESET,
    inout  [48:0] HPS_BUS,
    output        CLK_VIDEO,
    output        CE_PIXEL,
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output [1:0]  VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,

    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
    output        FB_PAL_CLK,
    output  [7:0] FB_PAL_ADDR,
    output [23:0] FB_PAL_DOUT,
    input  [23:0] FB_PAL_DIN,
    output        FB_PAL_WR,
`endif
`endif

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,
    output  [1:0] BUTTONS,

    input         CLK_AUDIO,
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    inout   [3:0] ADC_BUS,

    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
    input         SDRAM2_EN,
    output        SDRAM2_CLK,
    output [12:0] SDRAM2_A,
    output  [1:0] SDRAM2_BA,
    inout  [15:0] SDRAM2_DQ,
    output        SDRAM2_nCS,
    output        SDRAM2_nCAS,
    output        SDRAM2_nRAS,
    output        SDRAM2_nWE,
`endif

    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,

    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,

    input         OSD_STATUS
);

///////// Outputs this skeleton does not drive /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;
// UART_TXD is driven further down: it carries either the self-test page
// (rf_uart_log) or the write-ring dump (rf_uart_dump), selected in the OSD.
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

`ifdef MISTER_DUAL_SDRAM
assign {SDRAM2_A, SDRAM2_BA, SDRAM2_DQ, SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE, SDRAM2_CLK} = 'Z;
`endif

// DDRAM_* and FB_EN/FORMAT/WIDTH/HEIGHT/BASE/STRIDE are driven by
// screen_rotate (video out, below): the cabinet monitor is vertical.
`ifdef MISTER_FB
assign FB_FORCE_BLANK = 0;
`ifdef MISTER_FB_PALETTE
assign {FB_PAL_CLK, FB_PAL_ADDR, FB_PAL_DOUT, FB_PAL_WR} = 0;
`endif
`endif

assign VGA_F1         = 0;
assign VGA_SCALER     = 0;
assign VGA_DISABLE    = 0;
assign HDMI_FREEZE    = 0;
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

// AUDIO_L/R are driven by the ES5505 mix below (sound board section)
assign AUDIO_S   = 1;
// Stereo Mix (OSD): 0 none, 1 25 %, 2 50 %, 3 100 % (mono). The ES5505 pans
// its voices, so this is a real choice on headphones, not a placeholder.
assign AUDIO_MIX = status[13:12];

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

// VIDEO_ARX/ARY are assigned after the OSD decode below (a net used before
// its declaration would become an implicit 1-bit wire).

//////////////////////////   HPS   ///////////////////////////////

`include "build_id.v"
// ddhhmmss of this compile -- see tools/make_build_stamp.sh. build_id.v is
// regenerated by the MiSTer build flow, so the stamp cannot live there.
`include "rf_build_stamp.vh"

// Button order in the J1 list is the MiSTer arcade convention: buttons start
// at joystick bit 4 and every core places Start at bit 10 and Coin at bit 11,
// which is what the placeholder dashes are for (raiden2 note, same layout).
// Video options follow the Raiden II core (Arcade-Raiden2_MiSTer/Raiden2.sv).
// Ray Force is MAME ROT270 but its flipscreen inverts the raster, so the
// upright rotation is CW (see rotate_ccw below); that is the default.
// F3 boards have no DIP switches: game settings live in the service menu
// (Service Mode below is the cabinet TEST switch) and in the 93C46 EEPROM.
// Bits 2-5 are the debug options and predate the video ones; they keep their
// numbers so a saved Rayforce.CFG still means the same thing.
localparam CONF_STR = {
    "Rayforce;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[7:6],Rotate,CW (TATE),CCW,None;",
    "O[14],Flip Screen,Off,On;",
    "O[10:8],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "O[11],Refresh Rate,58.9Hz Native,60Hz;",
    "-;",
    "O[13:12],Stereo Mix,None,25%,50%,100% (Mono);",
    // The board's own output is very quiet -- see "Audio Boost" below. The
    // first entry is the power-up default (MiSTer's status word starts at
    // 0), which is why 8x leads and the exact level is second rather than
    // the list running 1x..16x.
    "O[17:16],Audio Boost,8x,1x (exact),4x,16x;",
    "-;",
    "O[15],Pause When OSD Open,Off,On;",
    // Darius Gaiden's vblank handler spins on a flag waiting for IRQ3 and
    // only then runs its frame handler, so how much work the game fits in a
    // frame depends on the 68020's real speed. "Full" is the core as it has
    // always been built; the rest hold the CPU clock enable off in
    // proportion. Watch the SPIN row on the self test page -- real hardware
    // reads 764 there.
    "O[20:18],CPU Speed,Full,94%,88%,81%,75%,62%,50%,37%;",
    "O[2],Service Mode,Off,On;",
    // "Off" MUST stay first. MiSTer's status word powers up at 0, so the
    // FIRST entry is what a fresh core load gets -- and with "On" first this
    // core booted into the diagnostic page instead of the game, which is how
    // v1.1 shipped. A released core boots to the GAME; the self test is
    // something you ask for. (The Raiden 2 core carries the same note, after
    // the same mistake.)
    //
    // First entry is necessary and not sufficient: MiSTer replays a SAVED
    // status word over the top of it, so a card used for bring-up boots a
    // fresh bitstream straight back to the page. Both of these bits are
    // therefore also armed in RTL -- see st_inherit / sv_inherit below.
    "O[3],Self Test,Off,On;",
    "O[5:4],UART Debug,Self Test,Audio Ring,Write Ring,Sound Ring;",
    "-;",
    "R[0],Reset;",
    // Same order as the MRA's <buttons names=...>: buttons start at joystick
    // bit 4, Start is bit 10, Coin bit 11, Service bit 12, Pause bit 13.
    "J1,Shot,Bomb,-,-,-,-,Start,Coin,Service,Pause;",
    "V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_wr;
wire        ioctl_upload, ioctl_rd;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire  [7:0] ioctl_index;
wire        ioctl_wait;

wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;   // Y[15:8], X[7:0], -127..127
wire [15:0] nv_din;                                     // NVRAM readback to hps_io

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .EXT_BUS(),
    .gamma_bus(gamma_bus),

    .forced_scandoubler(forced_scandoubler),
    .buttons(buttons),
    .status(status),
    .status_menumask(0),
    .video_rotated(video_rotated),     // so the OSD follows the TATE rotation

    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait),

    // NVRAM save: the core asks (nv_save_req), MiSTer reads the 128 bytes
    // back on index 254 and writes config/nvram/<mra>.nvm
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(nv_save_req),
    .ioctl_upload_index(8'd254),
    .ioctl_din(nv_din),
    .ioctl_rd(ioctl_rd),

    .joystick_0(joystick_0),
    .joystick_1(joystick_1),
    .joystick_l_analog_0(joystick_l_analog_0),
    .joystick_l_analog_1(joystick_l_analog_1),
    .ps2_key()
);

// The left analog stick steers too (an Xbox pad's stick is what most
// people hold): past 48/127 of deflection it sets the digital direction,
// OR'ed with the d-pad/hat bits. Y is negative upwards. Bit order is
// MiSTer's: right, left, down, up from bit 0.
function automatic logic [3:0] stick_dirs(input logic [15:0] a);
    logic signed [7:0] x, y;
    x = a[7:0]; y = a[15:8];
    stick_dirs = {y < -8'sd48, y > 8'sd48, x < -8'sd48, x > 8'sd48};
endfunction
wire [15:0] joy0_in = joystick_0[15:0] | {12'd0, stick_dirs(joystick_l_analog_0)};
wire [15:0] joy1_in = joystick_1[15:0] | {12'd0, stick_dirs(joystick_l_analog_1)};

///////////////////////   CLOCKS   ///////////////////////////////
//
// clk_sys = 53.372 MHz = 8 x the F3 pixel clock (26.686 MHz XTAL / 4).
// clk_ram = 97.04 MHz for the SDRAM controller: both outputs are exact off
// one 1067.44 MHz fractional VCO (C=11 and C=20), so clk_sys -- and the
// 58.94 Hz video timing derived from it -- is untouched by adding clk_ram.

wire clk_ram, clk_sys, pll_locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(clk_ram),
    .outclk_1(clk_sys),
    .locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// sys_top holds RESET high for the WHOLE ROM download, so anything that must
// work during or right after the stream (the program bus) resets on
// bus_reset instead -- gating it on `reset` froze it mid-stream on
// Propcycle.
wire bus_reset = status[0] | buttons[1] | ~pll_locked;

// Debug options and the two UART producers are declared HERE, above every
// use: a forward reference at module scope becomes an implicit 1-bit net,
// which would silently truncate uart_mode to one bit and gate the wrong
// producer (the failure class the Raiden II core hit twice).
//   O[3]   Self Test    0 = game video (default), 1 = show the page
//   O[5:4] UART Debug   0 = self-test page (default), 1 = off, 2 = the
//                       Phase 0/1 write-ring dump (rf_write_compare.py).
//                       On by default: the OSD cannot be driven remotely, and
//                       a debug channel that has to be switched on by hand at
//                       the cabinet is not much of a debug channel.
// A released core boots to the GAME -- and now it does so on a card that has
// been used for bring-up, too. The OSD defaults are already Off (CONF_STR
// above, and the note there about which entry comes first), but MiSTer
// persists the status word per core in config/Rayforce.CFG, so a card that
// has ever had Self Test switched on hands the bit straight back to every
// bitstream loaded after it: a brand-new build boots to the diagnostic page
// with nothing whatever wrong with it. That is v1.1's symptom with a
// different cause, and an OSD default cannot fix it, because the OSD default
// is not what a saved config replays.
//
// So both boot-into-a-test-screen bits are ARMED rather than merely
// selected. The value each carries when the game is released -- the end of
// the ROM download, which is where cpu_reset drops -- is treated as
// inherited and ignored; only a deliberate OSD change after that turns the
// thing on, and such a change necessarily takes the bit low first, which is
// what re-arms it. Both regs power up armed, so an inherited page never
// shows, not even during the download.
//
// The UART self-test log is deliberately NOT gated by this: uart_mode is its
// own field, and the whole point of it (see below) is that it needs nobody
// at the cabinet.
logic st_inherit = 1'b1;   // Self Test    (status[3]) came from a saved config
logic sv_inherit = 1'b1;   // Service Mode (status[2]) came from a saved config
logic dl_active_d;
always_ff @(posedge clk_sys) begin
    dl_active_d <= ioctl_download;
    if (dl_active_d && !ioctl_download) begin
        // the game starts now: whatever the bits say at this instant was
        // handed over by the config file, not asked for
        st_inherit <= status[3];
        sv_inherit <= status[2];
    end else begin
        // switched off by hand -> honour every change from here on
        if (!status[3]) st_inherit <= 1'b0;
        if (!status[2]) sv_inherit <= 1'b0;
    end
end

wire       selftest_on = status[3] & ~st_inherit;
wire       service_on  = status[2] & ~sv_inherit;
// UART Debug mode. The OSD is the normal way to pick it -- but on a board
// whose input is dead it is not reachable at ALL: pad input is enumerated
// and ignored, and MiSTer does not replay config/Rayforce.CFG's status word
// into the core (measured 2026-09-02 on build 02205428: byte 0 = 0x20 and
// byte 1 bit 6 written and read back, core still saw uart_mode 0 and flip
// screen off). The MRA's config bytes DO arrive -- the board picks its game
// id, visarea and extend from them -- so index 2 bits [7:6], spare in the
// layout above, override the OSD when non-zero. Zero keeps the OSD in
// charge, and no MRA written before tonight carries an index-2 region at
// all, so every one of them is unaffected. A debug capture is then a
// variant MRA rather than a menu nobody can open.
// The sprite row cap was built to test whether the line-budget overrun was
// what broke the colours. The board answered that on build 01222500: the
// draw ALWAYS finishes its 256 lines (draw_unfinished = 0), so the overrun
// is not the mechanism and the cap has nothing left to prove. Tied off
// rather than deleted -- constant propagation folds every mux behind it
// away, which matters at 98 % ALM, and the RTL stays for the day a real
// workload cap is wanted.
wire [1:0] spr_row_cap = 2'd0;
wire       uart_log_txd, uart_ring_txd;

// Video options (CONF_STR above).
wire [1:0] ar          = status[122:121];
wire [1:0] rotate_sel  = status[7:6];
wire       no_rotate   = (rotate_sel == 2'd2);
// Ray Force is MAME ROT270 but runs with the F3 flipscreen ON (its graphics
// are stored flipped and the chipset draws them flipped), so the raster the
// core outputs is already inverted: rotating it CW puts it upright, and
// that is the default (2026-08-28: CCW was upside down on the HDMI output).
wire       rotate_ccw  = (rotate_sel == 2'd1);
// TIED OFF to pay for the sprite record store (rf_video_spr NREC). fx==1 is
// the framework's Hq2x, and fx also builds the scanline blender; holding it
// at 0 lets Quartus fold both away. These are cosmetic filters on a core
// that was at 4187/4191 LABs and was DROPPING SPRITE ROWS on every boss --
// the trade is not close. status[10:8] is left defined so the OSD entry and
// the saved config keep their meaning if the logic is ever restored.
/* verilator lint_off UNUSED */
wire [2:0] scandoubler_fx_osd = status[10:8];
/* verilator lint_on UNUSED */
wire [2:0] scandoubler_fx = 3'd0;
wire       rate_60     = status[11];
wire       video_rotated;
// Flip Screen (OSD): 180 degrees on the ROTATED output, which is where a
// cabinet's monitor mounting shows up. It acts on screen_rotate's
// framebuffer, so it applies whenever rotation is on; with Rotate = None
// (and on the analog raster, which deliberately stays in raster order)
// there is nothing to flip. Doing it in the renderer instead would desync
// the sprites, which carry their own flip bit from the sprite command word.
wire       flip_screen = status[14];
// Pause When OSD Open (OSD): freeze the game -- both CPUs -- while the menu
// is up, the way a cabinet's pause would.
wire       pause_osd   = status[15];
wire [2:0] cpu_speed   = status[20:18];

// eff_no_rotate, VIDEO_ARX and VIDEO_ARY are assigned after cfg_game is
// decoded, because the orientation is now per game. See there.

// Pause: the J1 "Pause" button (joystick bit 13, either player) toggles a
// hold on the main CPU's clock enable. Video keeps running (the last frame
// stays up), so the self-test page's IRQ-rate rows read FAIL while paused --
// the acknowledges stop with the CPU -- which is what they should say.
logic paused, pause_btn_d;
wire  pause_btn = joystick_0[13] | joystick_1[13];
always_ff @(posedge clk_sys) begin
    pause_btn_d <= pause_btn;
    if (reset) paused <= 1'b0;
    else if (pause_btn && !pause_btn_d) paused <= ~paused;
end
// what actually holds the CPUs: the button's latch, or the OSD being open
wire pause_eff = paused | (pause_osd & OSD_STATUS);

//////////////////////  ROM DOWNLOAD PROOF  //////////////////////
//
// Counts and checksums the ioctl stream exactly as received. The MRA for
// gunlock/rayforce streams 0x00B80000 bytes (11.5 MB); the rolling sum is
// the same rotate-left-1-then-add the Raiden BIST uses, so the value can be
// reproduced offline from the same zip to prove the bytes arrived intact.

reg [31:0] dl_bytes;
reg [31:0] dl_sum;
reg  [7:0] dl_index;
reg        dl_seen;

always @(posedge clk_sys) begin
    if (ioctl_wr && ioctl_index == 8'd0) begin
        // First write of a fresh download resets the accumulators, so a
        // second load does not stack on the first.
        if (ioctl_addr == 0) begin
            dl_bytes <= 32'd2;
            dl_sum   <= {16'd0, ioctl_dout};
        end else begin
            dl_bytes <= dl_bytes + 32'd2;
            dl_sum   <= {dl_sum[30:0], dl_sum[31]} + {16'd0, ioctl_dout};
        end
        dl_seen <= 1'b1;
    end
    if (ioctl_wr) dl_index <= ioctl_index;
end

///////////////////////   SDRAM   ////////////////////////////////
//
// Sorgelig 4-channel controller at clk_ram. Only ch3 is in use: the
// download loader owns it while ioctl_download is high, the CPU's
// line-cached program fetches (rf_prog_bus) own it afterwards. ch1/ch2/ch4
// are parked for the video/sound phases.

// ch1/ch2: the two playfield tile planes, read by rf_video_pipe
wire [26:1] ch1_addr, ch2_addr;
wire [63:0] ch1_dout, ch2_dout;
wire        ch1_req, ch1_ready, ch2_req, ch2_ready;

// The sprite engine's four gfx plane requests (two fetch buses x two
// planes) share ch4 through rf_spr_ch_share (only ch4 is free; see that
// module for why a plain mux would desync the fetch CDC).
wire [26:1] spr_a_lo_addr, spr_a_hi_addr, spr_b_lo_addr, spr_b_hi_addr;
wire [63:0] spr_a_lo_dout, spr_a_hi_dout, spr_b_lo_dout, spr_b_hi_dout;
wire        spr_a_lo_req, spr_a_lo_ready, spr_a_hi_req, spr_a_hi_ready;
wire        spr_b_lo_req, spr_b_lo_ready, spr_b_hi_req, spr_b_hi_ready;
wire [26:1] ch4_addr;
wire [63:0] ch4_dout;
wire        ch4_req, ch4_ready;

// ch5: the sound 68000's program fetch (rf_sound_main's prog_bus)
wire [26:1] ch5_addr;
wire [63:0] ch5_dout;
wire        ch5_req, ch5_ready;
// ch6: the ES5505's sample lines (rf_smp_bus)
wire [26:1] ch6_addr;
wire [63:0] ch6_dout;
wire        ch6_req, ch6_ready;
// ch7: the sprite engine's SECOND fetch bus (see below)
wire [26:1] ch7_addr;
wire [63:0] ch7_dout;
wire        ch7_req, ch7_ready;

// ---- sprite graphics: ONE CHANNEL PER FETCH BUS -------------------------
// The sprite engine runs two fetch buses (A and B) taking alternate records,
// and each record needs two planes, so four plane requests are outstanding
// at once. They used to share ch4 alone, and rf_spr_ch_share holds exactly
// one burst outstanding -- so those four bursts were served strictly one
// after another and a line's draw time came to (bursts x round trip) with
// nothing overlapped at all. Measured in sim/pipe_tb (F3_SPS_LAT, frame
// 2930): the draw time is linear in the fetch latency with a slope of
// exactly one round trip per burst, which is the signature of zero overlap.
//
// On the board that made sprites disappear from the bottom of the screen in
// attract, roughly 40-60 s in: the draw fell behind partway down the frame
// and the ring's run-ahead never recovered, so every line from there to the
// end of the frame drew with whatever had arrived. It is Known problem #1 in
// the README, and it is a latency problem, not a bandwidth one -- the record
// store never dropped a row (SPR REC : DROP stays 0).
//
// A channel per bus lets the two records overlap, which halves it. Measured
// on frame 2930, the frame the board was caught getting wrong: the picture
// stays identical to MAME up to a sprite-fetch round trip of 135 ram clocks
// instead of 70, and at a modelled 90-clock round trip the longest line falls
// from 6607 clocks to 3678 with the late-line count going 305 -> 0 (the
// per-line budget is 3456, but the ring of 8 banks seven spare lines on top
// of it, so a line over budget is not by itself a dropped sprite). The draw
// time is linear in the round trip: 62.1 clocks per clock on one channel,
// 32.3 on two -- the slope halves, which is the overlap doing its job.
//
// ch7 sits immediately after ch4 in the controller's priority chain, so the
// sprite path's standing against the CPU and the sound board is unchanged --
// the only difference is how many of its bursts can be in flight.
rf_spr_ch_share spr_ch_share_a
(
    .clk_ram(clk_ram),
    .a_lo_addr(spr_a_lo_addr), .a_lo_dout(spr_a_lo_dout), .a_lo_req(spr_a_lo_req), .a_lo_ready(spr_a_lo_ready),
    .a_hi_addr(spr_a_hi_addr), .a_hi_dout(spr_a_hi_dout), .a_hi_req(spr_a_hi_req), .a_hi_ready(spr_a_hi_ready),
    .b_lo_addr(26'd0), .b_lo_dout(), .b_lo_req(1'b0), .b_lo_ready(),
    .b_hi_addr(26'd0), .b_hi_dout(), .b_hi_req(1'b0), .b_hi_ready(),
    .ch_addr(ch4_addr), .ch_dout(ch4_dout),
    .ch_req(ch4_req),   .ch_ready(ch4_ready)
);

rf_spr_ch_share spr_ch_share_b
(
    .clk_ram(clk_ram),
    .a_lo_addr(spr_b_lo_addr), .a_lo_dout(spr_b_lo_dout), .a_lo_req(spr_b_lo_req), .a_lo_ready(spr_b_lo_ready),
    .a_hi_addr(spr_b_hi_addr), .a_hi_dout(spr_b_hi_dout), .a_hi_req(spr_b_hi_req), .a_hi_ready(spr_b_hi_ready),
    .b_lo_addr(26'd0), .b_lo_dout(), .b_lo_req(1'b0), .b_lo_ready(),
    .b_hi_addr(26'd0), .b_hi_dout(), .b_hi_req(1'b0), .b_hi_ready(),
    .ch_addr(ch7_addr), .ch_dout(ch7_dout),
    .ch_req(ch7_req),   .ch_ready(ch7_ready)
);

wire [26:1] ch3_addr_pb;                // prog_bus side of the loader mux
wire [63:0] ch3_dout;
wire [15:0] ch3_din_pb;
wire  [1:0] ch3_be_pb;
wire        ch3_req_pb, ch3_rnw_pb, ch3_ready;

// Direct download loader: the FIFO path inside pc_prog_bus dispatched ZERO
// writes during real downloads on Propcycle (mechanism unproven), so the
// proven shape is a dedicated FSM owning ch3 while ioctl_download is high --
// one SDRAM write per ioctl word, ioctl_wait held until the ram-domain done
// toggle comes back. The whole MRA stream is written flat (stream order IS
// the SDRAM map); maincpu words are byte-swapped LE->BE so the 68020 bus
// reads {even, odd}, everything else is stored raw.
reg         ld_req;
reg  [26:1] ld_addr;
reg  [15:0] ld_din;
reg         ld_busy;
/* verilator lint_off PROCASSINIT */
reg         ld_done_t = 1'b0;
/* verilator lint_on PROCASSINIT */
always @(posedge clk_ram) if (ch3_ready && ioctl_download) ld_done_t <= ~ld_done_t;
reg ld_d1, ld_d2, ld_d3;
always @(posedge clk_sys) begin
    ld_d1 <= ld_done_t; ld_d2 <= ld_d1; ld_d3 <= ld_d2;
end
wire ld_done_edge = ld_d2 ^ ld_d3;

wire dl_word = ioctl_wr && ioctl_index == 8'd0;

always @(posedge clk_sys) begin
    if (~pll_locked) begin
        ld_req <= 1'b0; ld_busy <= 1'b0;
    end else begin
        if (dl_word && !ld_busy) begin
            ld_addr <= ioctl_addr[26:1];
            ld_din  <= (ioctl_addr < 27'h200000)
                       ? {ioctl_dout[7:0], ioctl_dout[15:8]}   // LE -> BE
                       : ioctl_dout;
            ld_req  <= 1'b1;
            ld_busy <= 1'b1;
        end else if (ld_busy && ld_done_edge) begin
            ld_req  <= 1'b0;
            ld_busy <= 1'b0;
        end
    end
end

assign ioctl_wait = ld_busy;

sdram sdram
(
    .init(~pll_locked), .clk(clk_ram), .doRefresh(1'b0),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
    .ch1_addr(ch1_addr), .ch1_dout(ch1_dout), .ch1_req(ch1_req), .ch1_ready(ch1_ready),
    .ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_req(ch2_req), .ch2_ready(ch2_ready),
    .ch3_addr(ioctl_download ? ld_addr : ch3_addr_pb),
    .ch3_dout(ch3_dout),
    .ch3_din(ioctl_download ? ld_din : ch3_din_pb),
    .ch3_be(ioctl_download ? 2'b11 : ch3_be_pb),
    .ch3_req(ioctl_download ? ld_req : ch3_req_pb),
    .ch3_rnw(ioctl_download ? 1'b0 : ch3_rnw_pb),
    .ch3_ready(ch3_ready),
    .ch4_addr(ch4_addr), .ch4_dout(ch4_dout), .ch4_req(ch4_req), .ch4_ready(ch4_ready),
    .ch5_addr(ch5_addr), .ch5_dout(ch5_dout), .ch5_req(ch5_req), .ch5_ready(ch5_ready),
    .ch6_addr(ch6_addr), .ch6_dout(ch6_dout), .ch6_req(ch6_req), .ch6_ready(ch6_ready),
    .ch7_addr(ch7_addr), .ch7_dout(ch7_dout), .ch7_req(ch7_req), .ch7_ready(ch7_ready)
);

////////////////////  PROGRAM BUS + READBACK BIST  ///////////////
//
// rf_prog_bus gives the CPU line-cached 16-bit reads of the program ROM in
// SDRAM. Its internal download FIFO is the one Propcycle found dead during
// real streams, so it is bypassed (dl_wr tied off) and the loader above
// does all SDRAM writes.
//
// Readback BIST: after the download, read the FULL 1 MB maincpu region back
// through the REAL fetch path and checksum it (rotl1+add per word, the
// raiden BIST fold); the CPU is held until it finishes. Expected value
// comes from tools/rf_stream_sum.py. Wrong sum = download side; right sum
// with a still-wild CPU = read side. Reading all 1 MB (not a 64 KB window)
// is also the Phase 1 "runs past 0x40000" proof: the spike itself spins
// waiting for a vblank IRQ it never gets (IPL is tied off).

wire [21:1] cpu_prog_addr;
wire        cpu_prog_req;
reg  [18:0] bist_addr;                  // word address, 0 .. 0x7FFFF
reg         bist_req;
reg  [31:0] bist_sum;
reg  [1:0]  bist_st;                    // 0 idle, 1 reading, 2 done
wire        bist_running = (bist_st == 2'd1);
wire        bist_done    = (bist_st == 2'd2);

wire [15:0] prog_data;
wire        prog_valid;

always @(posedge clk_sys) begin
    bist_req <= 1'b0;
    if (reset | ioctl_download | ~dl_seen) begin
        bist_st <= 2'd0; bist_addr <= 19'd0; bist_sum <= 32'd0;
    end else case (bist_st)
        2'd0: begin bist_st <= 2'd1; bist_req <= 1'b1; end
        2'd1: if (prog_valid) begin
            bist_sum <= {bist_sum[30:0], bist_sum[31]} + {16'd0, prog_data};
            if (bist_addr == 19'h7FFFF) bist_st <= 2'd2;
            else begin bist_addr <= bist_addr + 19'd1; bist_req <= 1'b1; end
        end
        default: ;
    endcase
end

rf_prog_bus prog_bus
(
    .clk_cpu(clk_sys), .reset(bus_reset),
    .addr(bist_running ? {2'd0, bist_addr} : cpu_prog_addr),
    .req(bist_running ? bist_req : cpu_prog_req),
    .data(prog_data), .valid(prog_valid),
    .dl_wr(1'b0), .dl_addr(21'd0), .dl_data(16'd0),
    .dl_busy(), .dl_cnt(),
    .clk_ram(clk_ram),
    .ch_addr(ch3_addr_pb), .ch_dout(ch3_dout), .ch_din(ch3_din_pb),
    .ch_be(ch3_be_pb), .ch_req(ch3_req_pb), .ch_rnw(ch3_rnw_pb),
    .ch_ready(ch3_ready)
);

//////////////////////  F3 MAIN BOARD  //////////////////////////
//
// Held in reset until the ROM download has completed and the readback BIST
// has passed through the fetch path, then runs the real boot code from
// SDRAM against the real F3 memory map, with the real vblank/timer
// interrupts. See rf_main.sv.

wire        cpu_reset = reset | ioctl_download | ~dl_seen | ~bist_done;

wire [31:0] wr_count, wr_hash, last_pc;
wire        trap_oor;
wire [10:0] ring_raddr, ring_wptr;
wire [55:0] ring_rdata;
wire        ring_full;

wire [15:0] frame_cnt, irq2_cnt, irq3_cnt;
wire [15:0] pf_wr_cnt, spr_wr_cnt, pal_wr_cnt, line_wr_cnt, txt_wr_cnt;
wire [15:0] pal_wr_hi, pal_wr_lo;   // DIAGNOSTIC split, see rf_main
wire [31:0] cpu_spin;               // {spin reads, tower A wr, tower B wr}
wire [15:0] irq2_rate, irq3_rate;
wire        irq_rate_valid;

// Video-side RAM read ports, owned by rf_video_pipe.
wire [13:0] v_pal_addr, v_pf_addr;
wire [14:0] v_line_addr, v_pivot_addr, v_spr_addr;
wire [11:0] v_text_addr, v_char_addr;
wire [15:0] v_pal_q, v_pf_q, v_line_q, v_text_q, v_char_q, v_pivot_q, v_spr_q;
wire [7:0][15:0] vctrl0, vctrl1;

// audio ring capture (driven at the bottom of the file, declared here
// because the rf_main instance below connects it)
logic        aud_ring_we, aud_armed;
logic [22:0] aud_idx;
logic [55:0] aud_ring_data;

//  Universal Taito F3 SDRAM map (2026-08-28). Sized for the largest game
//  this core targets rather than for one game, so a second title is an MRA
//  and a config byte, not a re-fit:
//
//     byte        size    region
//     0x0000000    2 MB   maincpu      (68020, 4-way byte interleave)
//     0x0200000  512 KB   audiocpu     (68000, 16-bit interleave)
//     0x0280000    4 MB   sprites      (16-bit interleave)
//     0x0680000    2 MB   sprites_hi
//     0x0880000    4 MB   tilemap      (LOAD32_WORD pair)
//     0x0C80000    2 MB   tilemap_hi
//     0x0E80000    8 MB   ensoniq      (up to 4 x 2 MB, plain)
//     0x1680000           = 22.5 MB total
//
//  Ensoniq grew 4 MB -> 8 MB for Puzzle Bobble 3/4, whose sample region is
//  16 MB in MAME against Ray Force's 8. It is the LAST region, so nothing
//  else moved and every MRA written before it still streams 18.5 MB and
//  still means exactly what it meant -- those games simply never address
//  the upper half (see cfg_bankmask).
//
//  Ray Force fills half of it and pads the rest; Elevator Action Returns
//  fills it. Games larger than this (Kaiser Knuckle, Kirameki Star Road at
//  48-49 MB) would need the map extended again.
//
// ------------------------  GAME CONFIG  ------------------------------
//
// The Taito F3 board is one chipset running 35 different games, and MAME's
// per-game differences are small enough to be data rather than RTL: the
// visible-raster crop (four variants), the playfield "extend" bit, and the
// sprite lag. The MRA supplies them as a single byte on ioctl index 1, the
// way MiSTer arcade cores usually carry a board variant:
//
//     <rom index="1"><part>03</part></rom>     (f3, 232 lines)
//
//   bit [1:0]  visarea: 0 = f3_224a (Ray Force), 1 = f3_224b,
//                       2 = f3_224c, 3 = f3
//   bit [2]    NON-extend (1 = eight 32x32 playfields, MAME's extend=0:
//                       Puzzle Bobble 2/3/4, Darius Gaiden, Cleopatra
//                       Fortune, Grid Seeker, Space Invaders '95,
//                       Gekirindan. 0 = four 64x32, which is Ray Force,
//                       Elevator Action Returns and both Bubble Bobble
//                       games.) Note the inverted sense against MAME's own
//                       "extend" naming: a 0 byte has to keep meaning what
//                       every MRA written before this bit went live meant.
//   bit [4:3]  sprite lag in frames (reserved; the engine does 1 today,
//                       MAME does 2 for both of these games)
//
// With no index-1 ROM the byte stays 0, which is Ray Force's configuration,
// so every MRA written before this still means what it meant.
// Cleared at the START of a load and latched during it, so switching to an
// MRA that carries no config byte cannot inherit the previous game's. It
// must NOT be cleared by the OSD's Reset, which does not re-download.
// TWO bytes now, on two ioctl indices. Index 1 is the original byte and its
// meaning is untouched; index 2 is the extension, and because no MRA written
// before today carries an index-2 region it reads as zero for every one of
// them -- which is the default in every field below. Splitting across two
// indices rather than widening index 1 to a 16-bit word is deliberate: a
// one-byte region's padding in the upper half of the ioctl word is not
// something to bet eight shipped MRAs on.
//
// THE WHOLE F3 LIBRARY FITS THIS LAYOUT. All 35 parent sets were tabulated
// from MAME's GAME() lines, its init_ functions and f3_config_table (see
// F3-LIBRARY.md); these are every per-game parameter they need:
//
//   index 1  [1:0]  visarea    0 f3_224a  1 f3_224b  2 f3_224c  3 f3
//                              all four are implemented in rayforce_video
//            [2]    extend     1 asks for NON-extend (inverted, see below)
//            [5],[7:6]         game id, low three bits
//   index 2  [2:0]  game id, high three bits -> 6 bits, 64 ids for 35 sets
//            [4:3]  SPRITE LAG  0/1/2. RESERVED, NOT READ YET: the engine is
//                              structurally lag 2 (double-banked buckets plus
//                              the DDR3 framebuffer). MAME's table wants 2 for
//                              8 sets, 1 for 22 and 0 for 3, so this is the
//                              one per-game parameter the core cannot yet
//                              express -- the field is here so the MRAs can
//                              carry it the day the engine can.
//            [5]    12-BIT PALETTE. RESERVED, NOT READ YET (ridingf, and with
//                              extend=0 arabianm and ringrage).
//            [7:6]  spare
logic [15:0] game_cfg;
logic        hard_reset_d;
always_ff @(posedge clk_sys) begin
    hard_reset_d <= RESET;
    if (RESET && !hard_reset_d) game_cfg <= 16'd0;         // a load begins
    else if (ioctl_wr && ioctl_index == 8'd1) game_cfg[7:0]  <= ioctl_dout[7:0];
    else if (ioctl_wr && ioctl_index == 8'd2) game_cfg[15:8] <= ioctl_dout[7:0];
end
wire [1:0] cfg_vis  = game_cfg[1:0];
// Bit [2] is live from this build, and its POLARITY IS INVERTED from the
// reserved-bit comment above, deliberately. Every MRA written before now
// carries 0 in it, and every game the core has ever run is extend=1, so 0
// has to keep meaning extend=1 or Ray Force and Elevator Action Returns
// both break the moment the bit is read. So the bit asks for the NEW
// behaviour: 1 = non-extend (eight 32x32 playfields), 0 = extend as before.
wire       cfg_extend = ~game_cfg[2];
// The game id is {index2[2:0], index1[5], index1[7:6]} -- six bits, so all 35
// F3 parent sets have one and there is room for the regional variants too. It
// grew in two steps and both preserved every MRA already written: bit 5 became
// the third bit rather than sliding the field to [7:5], and the top three came
// from a new index whose absence reads as zero. Same reasoning as the extend
// bit's inverted sense: a shipped MRA must never change meaning.
wire [5:0] cfg_game = {game_cfg[10:8], game_cfg[5], game_cfg[7:6]};

// ---- ORIENTATION, per game -------------------------------------------
// MiSTer's screen_rotate writes every visible pixel into a DDR3 framebuffer
// and the scaler reads it back a frame later. That frame is the ONLY input
// latency in this core -- rf_main's joystick path is combinational, straight
// from j0/j1 into the CPU's input port with no register in between -- so
// rotating a game that does not need it costs a whole frame for nothing.
//
// Ray Force is vertical and the OSD's Rotate defaults to CW for it, which is
// right for the core's main title and WRONG for the twelve horizontal games
// now running: they were paying that frame, and being displayed sideways at
// a 3:4 aspect into the bargain. A player reported exactly that as input lag
// on Darius Gaiden (2026-09-08), whose MRA says <rotation>horizontal</rotation>.
//
// Orientation is a property of the game, like visarea and extend, so it is
// decoded here from cfg_game rather than left to a setting the player has to
// know to change. The values come from the MRAs themselves, which all carry
// a <rotation> tag; every id below was read out of one. Unlisted ids default
// to vertical, so nothing that ran before this changes behaviour.
//
// This does not take the Rotate option away from anyone: it only forces the
// no-rotate case, which is the one a horizontal game always wants.
logic cfg_horizontal;
always_comb begin
    case (cfg_game)
        //  1 elvactr   2 bublbob2  3 bubblem   4 dariusg   5 pbobble2
        //  8 arkretrn  9 pbobble3 10 pbobble4 13 cleopatr 14 twinqix
        // 15 recalh   16 qtheater 17 popnpop  19 dariusgx
        6'd1,  6'd2,  6'd3,  6'd4,  6'd5,  6'd8,  6'd9,
        6'd10, 6'd13, 6'd14, 6'd15, 6'd16, 6'd17, 6'd19: cfg_horizontal = 1'b1;
        // 0 rayforce  6 gunlock  7 rayforcej 11 gseeker
        // 12 spcinv95 18 gekiridn  -- and anything without an id yet
        default: cfg_horizontal = 1'b0;
    endcase
end

// The self-test page is drawn in raster order and must stay flat, so
// rotation and the vertical aspect are both forced off while it shows.
wire       eff_no_rotate = no_rotate | selftest_on | cfg_horizontal;

assign VIDEO_ARX = (!ar) ? (eff_no_rotate ? 12'd4 : 12'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (eff_no_rotate ? 12'd3 : 12'd4) : 12'd0;

wire [1:0] cfg_uart    = game_cfg[15:14];
wire [1:0] uart_mode   = (cfg_uart != 2'd0) ? cfg_uart : status[5:4];

// What the self test should EXPECT, per game. These are properties of the
// ROM set, not of the core, so they belong here rather than in rf_selftest:
// the download's byte count and checksum, the SDRAM readback of the first
// 1 MB of program ROM, the CPU's write-stream hash after boot, and the fold
// of the first 64 KB of sample ROM. Zero means "not measured for this game
// yet" -- the row then reports what it found and passes once the check has
// run, rather than failing against an expectation nobody has established.
// Compute the ROM-derived ones with tools/rf_stream_sum.py; the write hash
// comes from the MAME write-stream oracle.
logic [31:0] exp_bytes, exp_sum, exp_bist, exp_hash, exp_smp;
always_comb begin
    case (cfg_game)
        6'd0: begin                                    // Ray Force (US)
            exp_bytes = 32'h01280000; exp_sum  = 32'h77E1C279;
            exp_bist  = 32'hD53D7C04; exp_hash = 32'h10620931;
            exp_smp   = 32'hB86C4865;
        end
        6'd1: begin                                    // Elevator Action Returns
            // All five are real expectations now. The first four come from
            // tools/rf_stream_sum.py over the MRA; the write hash comes from
            // tools/oracle_f3writes.lua, and the board already reports
            // exactly it -- so the 68020 executes this game's first 4096 bus
            // writes the same way MAME does.
            exp_bytes = 32'h01280000; exp_sum  = 32'hD041363D;
            exp_bist  = 32'h399D4BCA; exp_hash = 32'h93368F3C;
            exp_smp   = 32'h52DDF5D3;
        end
        // Restored 2026-09-01 with the cfg_game widening. These were
        // commented out when the fitter came up 10 LABs short (Error
        // 170012); compiling the framework's Y/C encoder and ascal's
        // adaptive filter out bought that room back, so they are live arms
        // again rather than an M10K ROM -- which remains the right answer
        // the next time the LAB budget bites.
        6'd2: begin                                    // Bubble Bobble II
            // Measured 2026-08-31 the same way EAR's were, each method first
            // reproduced on a game whose answer was already known: the stream
            // numbers from tools/rf_stream_sum.py over the MRA, the sample
            // fold from the first 64 KB of d90-04 (the same fold gives Ray
            // Force's B86C4865), and the write hash from
            // tools/oracle_f3writes.lua + rf_write_compare.py, which
            // reproduced Ray Force's 10620931 in the same run.
            exp_bytes = 32'h01280000; exp_sum  = 32'hA364D1A1;
            exp_bist  = 32'hBE0F04C3; exp_hash = 32'hA7C4A522;
            exp_smp   = 32'h5597A419;
        end
        6'd3: begin                                    // Bubble Memories
            exp_bytes = 32'h01280000; exp_sum  = 32'hA5923CBE;
            exp_bist  = 32'hC4BD753B; exp_hash = 32'hA81F4977;
            exp_smp   = 32'h9C2DE26F;
        end
        6'd6: begin                                    // Gunlock (World)
            // Gunlock and Ray Force (Japan) differ from Ray Force (US) by
            // exactly ONE program ROM, and shared id 0 until 2026-09-01.
            // That made the ROM CHECKSUM row judge their perfectly good
            // stream against the US set's sum and report FAIL -- on the
            // first boot of an MRA that ships in releases/, not
            // experimental/. Measured with tools/rf_stream_sum.py; the
            // sample fold is Ray Force's B86C4865 because the ensoniq ROMs
            // are the same two chips. The write hash was ASSUMED to differ
            // with the program ROM; measured 2026-09-01 it does not -- all
            // three regions boot through the same F3 code and their first
            // 4096 bus writes hash identically to Ray Force's 10620931.
            // (The same run reproduced Bubble Memories' already-known
            // A81F4977, which is what makes the number trustworthy here.)
            exp_bytes = 32'h01280000; exp_sum  = 32'h20A2DBFE;
            exp_bist  = 32'hD53D7C05; exp_hash = 32'h10620931;
            exp_smp   = 32'hB86C4865;
        end
        6'd7: begin                                    // Ray Force (Japan)
            // exp_hash measured 2026-09-01: identical to Ray Force's and
            // Gunlock's, for the reason given in the Gunlock arm above.
            exp_bytes = 32'h01280000; exp_sum  = 32'h5E17E105;
            exp_bist  = 32'hD53D7C03; exp_hash = 32'h10620931;
            exp_smp   = 32'hB86C4865;
        end
        6'd4: begin                                    // Darius Gaiden
            // Three of the five are measured (2026-09-01) by
            // tools/rf_stream_sum.py over the MRA -- which is itself proof
            // the MRA lays the map out right, since this set fills the
            // 18.5 MB universal map EXACTLY, with no padding in any region.
            // The board reproduced all three on its first load. hash and smp
            // stay zero, so those two rows REPORT what they find rather than
            // judging it, until oracle_f3writes.lua and the rotl1+add fold of
            // the first 64 KB of d87-01 have been run.
            // exp_smp measured 2026-09-01: the rotl1+add fold of the first
            // 64 KB of the ensoniq region, the same fold Rayforce.sv applies.
            // The method was reproduced on all five games whose answer was
            // already known (Ray Force B86C4865, Gunlock the same two chips,
            // EAR 52DDF5D3, Bubble Bobble II 5597A419, Bubble Memories
            // 9C2DE26F) before being trusted here. exp_hash still needs
            // oracle_f3writes.lua, so that row still reports rather than
            // judges.
            // exp_hash measured 2026-09-01 with tools/oracle_f3writes.lua +
            // rf_write_compare.py, which reproduced Ray Force's 10620931 in
            // the same run. The board ALREADY REPORTS exactly this value,
            // so Darius Gaiden's 68020 executes its first 4096 bus writes
            // the way MAME does. All five expectations are now real for
            // this set.
            exp_bytes = 32'h01280000; exp_sum  = 32'hC1917DD8;
            exp_bist  = 32'h7A0AC136; exp_hash = 32'h832D59FE;
            exp_smp   = 32'h71E65420;
        end
        6'd5: begin                                    // Puzzle Bobble 2
            // Measured 2026-09-01. The set has shipped in experimental/ and
            // RENDERS CORRECTLY on hardware since the extend=0 build, but it
            // had no arm at all, so its ROM CHECKSUM and SDRAM BIST rows
            // reported instead of judging -- on a game whose stream numbers
            // fall straight out of tools/rf_stream_sum.py over the MRA.
            // exp_hash measured 2026-09-01 with oracle_f3writes.lua over
            // pbobble2j, the set this MRA names.
            exp_bytes = 32'h01280000; exp_sum  = 32'h3A0DD17A;
            exp_bist  = 32'h8BB19BD5; exp_hash = 32'h93328F3C;
            exp_smp   = 32'h2058055F;
        end
        default: begin                                 // not yet measured
            exp_bytes = 32'h00000000; exp_sum  = 32'h00000000;
            exp_bist  = 32'h00000000; exp_hash = 32'h00000000;
            exp_smp   = 32'h00000000;
        end
    endcase
end

// ---- otisbank mask, per game ----------------------------------------
// The Taito EN board banks the sample ROM with its own register, not the
// ES5505's, and MAME masks what the game writes there with
//
//     m_bankmask = (ensoniq region bytes / 0x200000) - 1
//
// which is a property of the ROM set, so it belongs here beside exp_*. It
// is 3 for every game this core ran before Puzzle Bobble 3 -- an 8 MB
// region, four 1 MB banks -- and 7 for Puzzle Bobble 3 and 4, whose region
// is 16 MB. Arkanoid Returns is the other direction: a 4 MB region masks to
// 1, and without that a voice asking for bank 2 reads padding instead of
// wrapping to bank 0 the way the board does.
//
// Masking here rather than widening unconditionally is what keeps every
// existing game bit-identical: a 3-masked game cannot generate an address
// above 4 MB, so its samples come from exactly the bytes they always did.
logic [2:0] cfg_bankmask;
always_comb begin
    case (cfg_game)
        6'd8:    cfg_bankmask = 3'd1;   // Arkanoid Returns   (4 MB region)
        6'd9:    cfg_bankmask = 3'd7;   // Puzzle Bobble 3   (16 MB region)
        6'd10:   cfg_bankmask = 3'd7;   // Puzzle Bobble 4   (16 MB region)
        6'd13:   cfg_bankmask = 3'd1;   // Cleopatra Fortune  (4 MB region)
        6'd14:   cfg_bankmask = 3'd1;   // Twin Qix           (4 MB region)
        default: cfg_bankmask = 3'd3;   // 8 MB region -- every earlier game
    endcase
end

// ---- 12-BIT PALETTE, per game ---------------------------------------
// Four F3 sets store a palette entry as RRRRGGGGBBBB0000 in the low word
// rather than as 32-bit 0RGB. MAME switches on the GAME to decide
// (taito_f3_v.cpp palette_24bit_w), and its own TODO there says the real
// chip may select it per line through 0x6400 -- unimplemented there too, so
// a per-game flag is exactly as correct as the reference. The MRA carries
// it at index 2 bit [5] as well, for a set that turns up needing it before
// it has an id here; either source turns it on.
//   spcinvdj  Space Invaders DX   D93
//   ridingf   Riding Fight
//   arabianm  Arabian Magic
//   ringrage  Ring Rage
// None of these has a reference dump in this tree, so the bench cannot
// judge them; the 24-bit path is unchanged and IS covered, which is what
// the mix and pipe benches are asked to prove after this change.
logic cfg_pal12_id;
always_comb begin
    case (cfg_game)
        6'd20, 6'd21, 6'd22, 6'd23: cfg_pal12_id = 1'b1;  // reserved for the four
        default:                    cfg_pal12_id = 1'b0;
    endcase
end
wire cfg_pal12 = cfg_pal12_id | game_cfg[13];   // index 2 bit [5]

// ---- SDRAM MAP PROFILE ----------------------------------------------
// Fourteen F3 sets do not fit the 18.5 MB map, and measuring their REAL
// ROM bytes (not MAME's declared region sizes, which overstate it) shows
// what actually blocks them:
//
//   sprites overflows for THIRTEEN of the fourteen; the 4 MB slot is the
//   bottleneck, not total capacity. Kaiser Knuckle and Dan-Ku-Ga want
//   13 MB of it, Kirameki Star Road 12 MB. The largest set in the whole
//   library is Kirameki at 31 MB of real ROM, not the 36-40 MB the
//   declared sizes suggest.
//
// The SDRAM was MEASURED at >= 64 MB on 2026-09-08 by an aliasing probe:
// 1 MB of 0xFF written at byte 32 MB (exactly where ch_addr[25], the tenth
// column bit, turns on) left the program ROM intact, where the same write
// at byte 0 destroyed it. So there is room; only the layout was wrong.
//
// TWO PROFILES rather than one big map, because one big map would re-cut
// all 21 shipped MRAs and every exp_* with them. Profile 0 IS the existing
// map, unchanged to the byte, so every MRA written before today still
// means what it meant. Profile 1 is the 36 MB layout the big sets need.
//
//   region       profile 0 (18.5 MB)      profile 1 (36 MB)
//   maincpu      0x0000000   2 MB         0x0000000   2 MB
//   audiocpu     0x0200000 512 KB         0x0200000   3 MB
//   sprites      0x0280000   4 MB         0x0500000  13 MB
//   sprites_hi   0x0680000   2 MB         0x1200000   2 MB
//   tilemap      0x0880000   4 MB         0x1400000   6 MB
//   tilemap_hi   0x0C80000   2 MB         0x1A00000   2 MB
//   ensoniq      0x0E80000   8 MB         0x1C00000   8 MB
//                          = 22.5 MB                = 36 MB
//
// KNOWN LIMIT: profile 1 gives audiocpu 3 MB for Kirameki Star Road, but
// rf_sound_main maps the sound 68000's C00000-C7FFFF linearly onto a 1 MB
// window and does not implement taito_en's bank register, so only the
// first megabyte is reachable. Every other set here has <= 512 KB of sound
// ROM and is unaffected; Kirameki needs that banking before it will run.
//
// Profile 1 is selected by MRA index 2 bit [4] -- a spare bit -- so a set
// can ask for it without needing a game id here first.
wire cfg_map = game_cfg[12];

// Bases are WORD addresses ([26:1]), i.e. half the byte address above.
wire [26:1] map_tile_lo = cfg_map ? 26'hA00000 : 26'h440000;  // tilemap
wire [26:1] map_tile_hi = cfg_map ? 26'hD00000 : 26'h640000;  // tilemap_hi
wire [26:1] map_sgfx_lo = cfg_map ? 26'h280000 : 26'h140000;  // sprites
wire [26:1] map_sgfx_hi = cfg_map ? 26'h900000 : 26'h340000;  // sprites_hi
wire [26:1] map_smp     = cfg_map ? 26'hE00000 : 26'h740000;  // ensoniq

// ---------------------------  NVRAM  ---------------------------------
//
// The 93C46 settings EEPROM is the game's only persistent store: the
// service-menu settings (and the "bad settings" boot path) live in it, so
// without this every boot starts from defaults. The MRA declares
// <nvram index="254" size="128"/>; MiSTer sends those 128 bytes on ioctl
// index 254 AFTER the ROM regions (the file if it exists, else the MRA's
// default), and reads them back the same way when the core raises
// ioctl_upload_req and the user opens the OSD or picks "Save settings"
// (Main_MiSTer menu.cpp: arcade_nvm_save on MENU_SAVE_CHECK).
//
// 64 words, big-endian in the file: the loader's 16-bit word arrives
// little-endian, so both directions swap the lanes.
wire        hs_pause, hs_ram_we, hs_save_ready;
wire        hs_sh_ok, hs_injected;
wire [15:0] hs_ram_addr, hs_ram_wdata, hs_ram_q;
wire  [1:0] hs_ram_be;
rf_hiscore hiscore (
    .clk(clk_sys), .reset(cpu_reset),
    .game_id(cfg_game), .run(~cpu_reset), .vbl_rise(vbl_rise),
    .ld_wr(hs_ld_wr), .ld_word(ioctl_addr[6:1]), .ld_data(ioctl_dout),
    .sv_word(ioctl_addr[6:1]), .sv_data(hs_sv_data), .ioctl_upload(ioctl_upload),
    .hs_pause(hs_pause), .hs_addr(hs_ram_addr), .hs_wdata(hs_ram_wdata),
    .hs_be(hs_ram_be), .hs_we(hs_ram_we), .hs_q(hs_ram_q),
    .save_ready(hs_save_ready),
    .sh_ok_o(hs_sh_ok), .injected_o(hs_injected)
);
// The 256-byte blob splits: bytes 0-127 the EEPROM, 128-255 the high-score
// snapshot (rf_hiscore). ioctl_addr[7] is the divider, both directions.
wire        nv_wr = ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[7];
wire        hs_ld_wr = ioctl_wr && (ioctl_index == 8'd254) && ioctl_addr[7];
wire  [5:0] nv_addr = ioctl_addr[6:1];
wire [15:0] nv_data = {ioctl_dout[7:0], ioctl_dout[15:8]};
wire [15:0] nv_sv_data;
wire        nv_wrote;
wire [15:0] hs_sv_data;
assign      nv_din  = ioctl_addr[7] ? hs_sv_data
                                    : {nv_sv_data[7:0], nv_sv_data[15:8]};

// Ask for a save once the game has changed a word, and stay asking until
// MiSTer has taken it: hps_io latches the RISING edge, so the request is
// dropped when the upload finishes and a later write raises it again.
logic nv_save_req;
logic ioctl_upload_d;
always_ff @(posedge clk_sys) begin
    ioctl_upload_d <= ioctl_upload;
    if (reset) nv_save_req <= 1'b0;
    else if (nv_wrote || hs_save_ready) nv_save_req <= 1'b1;
    else if (ioctl_upload_d && !ioctl_upload) nv_save_req <= 1'b0;
end

rf_main main
(
    .clk(clk_sys),
    .reset(cpu_reset),
    .prog_addr(cpu_prog_addr), .prog_req(cpu_prog_req),
    .prog_data(prog_data), .prog_valid(prog_valid),

    .vbl_rise(vbl_rise),
    .j0(joy0_in), .j1(joy1_in),
    .pause(pause_eff),
    .test_sw(service_on),
    .nv_wr(nv_wr), .nv_addr(nv_addr), .nv_data(nv_data),
    .hs_pause(hs_pause), .hs_addr(hs_ram_addr), .hs_wdata(hs_ram_wdata),
    .hs_be(hs_ram_be), .hs_we(hs_ram_we), .hs_q(hs_ram_q),
    .nv_sv_addr(ioctl_addr[6:1]), .nv_sv_data(nv_sv_data), .nv_wrote(nv_wrote),

    .ctrl0(vctrl0), .ctrl1(vctrl1),

    .v_pal_addr(v_pal_addr),   .v_pal_q(v_pal_q),
    .v_pf_addr(v_pf_addr),     .v_pf_q(v_pf_q),
    .v_text_addr(v_text_addr), .v_text_q(v_text_q),
    .v_char_addr(v_char_addr), .v_char_q(v_char_q),
    .v_line_addr(v_line_addr), .v_line_q(v_line_q),
    .v_pivot_addr(v_pivot_addr), .v_pivot_q(v_pivot_q),
    .v_spr_addr(v_spr_addr),   .v_spr_q(v_spr_q),

    .wr_count(wr_count), .wr_hash(wr_hash),
    .last_pc(last_pc), .trap_oor(trap_oor),
    .frame_cnt(frame_cnt), .irq2_cnt(irq2_cnt), .irq3_cnt(irq3_cnt),
    .pf_wr_cnt(pf_wr_cnt), .spr_wr_cnt(spr_wr_cnt), .spr_wr_stb(spr_wr_stb),
    .pal_wr_cnt(pal_wr_cnt),
    .pal_wr_hi(pal_wr_hi), .pal_wr_lo(pal_wr_lo), .line_wr_cnt(line_wr_cnt),
    .cpu_speed(cpu_speed), .cpu_spin(cpu_spin),
    .zone_inj(game_cfg[4:3]),          // MRA index 1 bits [4:3]: start zone 2..4
    .txt_wr_cnt(txt_wr_cnt),
    .irq2_rate(irq2_rate), .irq3_rate(irq3_rate),
    .irq_rate_valid(irq_rate_valid),

    .ring_raddr(ring_raddr), .ring_rdata(ring_rdata), .ring_wptr(ring_wptr),
    .ring_full(ring_full),

    .snd_dp_addr(snd_dp_addr), .snd_dp_wdata(snd_dp_wdata), .snd_dp_wren(snd_dp_wren),
    .snd_dp_be(snd_dp_be), .snd_dp_q(snd_dp_q),
    .snd_reset(snd_reset),
    .ring_ext_sel(uart_mode == 2'd3 || uart_mode == 2'd1),
    // Write Ring only: arm on the tower palette copy, see rf_main
    .ring_arm_en(uart_mode == 2'd2),
    .ring_ext_we(uart_mode == 2'd1 ? aud_ring_we : snd_ring_we),
    .ring_ext_data(uart_mode == 2'd1 ? aud_ring_data : snd_ring_data),
    .pivot_wr_cnt(pivot_wr_cnt)
);

////////////////////////  SOUND BOARD  ///////////////////////////
//
// The Taito EN board's 68000 and its map (rf_sound_main), held in reset by
// the main CPU until it releases it. Stage 1 of Phase 3: the chips only
// answer; their register writes go to the write ring (UART Debug = Sound
// Ring) for the comparison against MAME's stream, and to the es_*/bk_*/vl_*
// ports the sampler will take in stage 2. No audio yet.

wire  [9:0] snd_dp_addr;
wire [15:0] snd_dp_wdata, snd_dp_q;
wire        snd_dp_wren;
wire  [1:0] snd_dp_be;
wire        snd_reset, snd_ring_we, snd_running;
wire [55:0] snd_ring_data;
wire [15:0] pivot_wr_cnt, snd_es_wr_cnt;
wire [23:0] snd_pc;

// the sampler's register ports and IRQ vector (declared before the
// instance that drives them -- see the note on implicit nets above)
wire        es_we, bk_we, es_irqv_ack, vl_we, vl_offset;
wire  [7:0] vl_data;
wire  [3:0] es_reg;
wire [15:0] es_data;
wire  [1:0] es_be;
wire  [4:0] bk_voice;
wire  [2:0] bk_data;
wire  [7:0] es_irqv;
wire        es_rd_req, es_rd_valid;
wire  [3:0] es_rd_reg;
wire [15:0] es_rd_data;

rf_sound_main sound
(
    .clk(clk_sys), .reset(cpu_reset), .snd_reset(snd_reset), .pause(pause_eff),
    .clk_ram(clk_ram),
    .ch_addr(ch5_addr), .ch_dout(ch5_dout), .ch_req(ch5_req), .ch_ready(ch5_ready),
    .dp_addr(snd_dp_addr), .dp_wdata(snd_dp_wdata), .dp_wren(snd_dp_wren),
    .dp_be(snd_dp_be), .dp_q(snd_dp_q),
    .es_we(es_we), .es_reg(es_reg), .es_data(es_data), .es_be(es_be),
    .bk_we(bk_we), .bk_voice(bk_voice), .bk_data(bk_data),
    .vl_we(vl_we), .vl_offset(vl_offset), .vl_data(vl_data),
    .esp_halt(),
    .es_irqv(es_irqv), .es_irqv_ack(es_irqv_ack),
    .es_rd_req(es_rd_req), .es_rd_reg(es_rd_reg), .es_rd_data(es_rd_data), .es_rd_valid(es_rd_valid),
    .ring_we(snd_ring_we), .ring_data(snd_ring_data),
    .last_pc(snd_pc), .es_wr_cnt(snd_es_wr_cnt), .running(snd_running)
);

// ---- the ES5505 (Phase 3 stage 2) and its sample fetch on ch6 -----------
wire        sm_req, sm_valid, sm_busy;     // sm_line/sm_valid: from the BIST mux below
wire [22:3] sm_addr;
wire [63:0] sm_line;
wire        es_out_valid;
wire [7:0][19:0] es_out;
wire  [4:0] es_active;
wire [15:0] es_dbg_overrun, es_dbg_miss, es_dbg_wqdrop;

// The sample clock: master 15.238 MHz / (16 x (ACT + 1)), the integer
// division MAME makes, as a fractional divider of clk_sys.
logic        es_tick;
logic [31:0] es_acc;
// the 32 rates as constants (a divider here was a combinational disaster)
logic [31:0] es_rate;
always_comb begin
    case (es_active)
        5'd0: es_rate = 32'd952380;
        5'd1: es_rate = 32'd476190;
        5'd2: es_rate = 32'd317460;
        5'd3: es_rate = 32'd238095;
        5'd4: es_rate = 32'd190476;
        5'd5: es_rate = 32'd158730;
        5'd6: es_rate = 32'd136054;
        5'd7: es_rate = 32'd119047;
        5'd8: es_rate = 32'd105820;
        5'd9: es_rate = 32'd95238;
        5'd10: es_rate = 32'd86580;
        5'd11: es_rate = 32'd79365;
        5'd12: es_rate = 32'd73260;
        5'd13: es_rate = 32'd68027;
        5'd14: es_rate = 32'd63492;
        5'd15: es_rate = 32'd59523;
        5'd16: es_rate = 32'd56022;
        5'd17: es_rate = 32'd52910;
        5'd18: es_rate = 32'd50125;
        5'd19: es_rate = 32'd47619;
        5'd20: es_rate = 32'd45351;
        5'd21: es_rate = 32'd43290;
        5'd22: es_rate = 32'd41407;
        5'd23: es_rate = 32'd39682;
        5'd24: es_rate = 32'd38095;
        5'd25: es_rate = 32'd36630;
        5'd26: es_rate = 32'd35273;
        5'd27: es_rate = 32'd34013;
        5'd28: es_rate = 32'd32840;
        5'd29: es_rate = 32'd31746;
        5'd30: es_rate = 32'd30721;
        5'd31: es_rate = 32'd29761;
        default: es_rate = 32'd29761;
    endcase
end
always_ff @(posedge clk_sys) begin
    es_tick <= 1'b0;
    if (cpu_reset) es_acc <= 32'd0;
    else if (es_acc + es_rate >= 32'd53372000) begin
        es_acc  <= es_acc + es_rate - 32'd53372000;
        es_tick <= 1'b1;
    end else begin
        es_acc  <= es_acc + es_rate;
    end
end

rf_es5505 es5505
(
    .clk(clk_sys), .reset(cpu_reset | snd_reset),
    .es_we(es_we), .es_reg(es_reg), .es_data(es_data), .es_be(es_be),
    .bk_we(bk_we), .bk_voice(bk_voice), .bk_data(bk_data), .bank_mask(cfg_bankmask),
    .sm_req(sm_req), .sm_addr(sm_addr), .sm_line(sm_line), .sm_valid(sm_valid), .sm_busy(sm_busy),
    .tick(es_tick), .out_valid(es_out_valid), .out_ch(es_out), .out_active(es_active),
    .irqv_out(es_irqv), .irqv_ack(es_irqv_ack),
    .rd_req(es_rd_req), .rd_reg(es_rd_reg), .rd_data(es_rd_data), .rd_valid(es_rd_valid),
    .dbg_overrun(es_dbg_overrun), .dbg_miss(es_dbg_miss), .dbg_wqdrop(es_dbg_wqdrop)
);

// Sample-region BIST: right after the main BIST, read the first 64 KB of
// the Ensoniq ROM (bank 0, 8192 lines) back through the REAL sample fetch
// path -- rf_smp_bus, SDRAM ch6, the same line format the sampler reads --
// and fold it as the main BIST does (rotl1 + add per 16-bit word, little
// endian as the loader stores the region). The expected value is computed
// from d66-01 offline (see the note in HANDOFF.md). This is the test the
// first sound build did not have: a wrong sum means the sampler is fed the
// wrong bytes, however exact its arithmetic is.
wire [31:0] SMP_BIST_EXP = exp_smp;
reg  [12:0] smp_bist_line;
reg         smp_bist_req;
reg  [31:0] smp_bist_sum;
reg  [1:0]  smp_bist_st;                // 0 wait, 1 reading, 2 done
wire        smp_bist_running = (smp_bist_st == 2'd1);
wire        smp_bist_done    = (smp_bist_st == 2'd2);
wire        smp_bist_pass    = smp_bist_done &&
                               ((SMP_BIST_EXP == 32'd0) || (smp_bist_sum == SMP_BIST_EXP));
wire [63:0] smp_line_w;
wire        smp_valid_w;
// fold four words of a line in one step: rotl1+add applied word by word
function automatic logic [31:0] fold4(input logic [31:0] s, input logic [63:0] l);
    logic [31:0] t;
    t = {s[30:0], s[31]} + {16'd0, l[15:0]};
    t = {t[30:0], t[31]} + {16'd0, l[31:16]};
    t = {t[30:0], t[31]} + {16'd0, l[47:32]};
    t = {t[30:0], t[31]} + {16'd0, l[63:48]};
    fold4 = t;
endfunction
always @(posedge clk_sys) begin
    smp_bist_req <= 1'b0;
    if (cpu_reset) begin
        smp_bist_st <= 2'd0; smp_bist_line <= 13'd0; smp_bist_sum <= 32'd0;
    end else case (smp_bist_st)
        2'd0: begin smp_bist_st <= 2'd1; smp_bist_req <= 1'b1; end
        2'd1: if (smp_valid_w) begin
            smp_bist_sum <= fold4(smp_bist_sum, smp_line_w);
            if (smp_bist_line == 13'h1FFF) smp_bist_st <= 2'd2;
            else begin smp_bist_line <= smp_bist_line + 13'd1; smp_bist_req <= 1'b1; end
        end
        default: ;
    endcase
end
// the sampler sees the bus only once the BIST has released it
assign sm_line  = smp_line_w;
assign sm_valid = smp_valid_w && !smp_bist_running;

rf_smp_bus smp_bus
(
    .clk_cpu(clk_sys), .reset(cpu_reset),
    .addr(smp_bist_running ? {6'd0, smp_bist_line} : sm_addr),
    .req(smp_bist_running ? smp_bist_req : sm_req),
    .line(smp_line_w), .valid(smp_valid_w), .busy(sm_busy),
    .clk_ram(clk_ram),
    .ch_addr(ch6_addr), .ch_dout(ch6_dout), .ch_req(ch6_req), .ch_ready(ch6_ready),
    .base(map_smp)
);

// Mix: the pump sends pair 0 straight out and pairs 1-3 through the ESP,
// which is a dry sum here (ROADMAP Phase 3, stage 3 is the volume chip);
// four 20-bit pairs summed and scaled to 16 bits, MAME's route gains
// (0.18 x 0.5 x the MB87078 at 0 dB) come to about a >> 6.
logic signed [22:0] mix_l, mix_r;
always_ff @(posedge clk_sys) if (es_out_valid) begin
    mix_l <= 23'($signed(es_out[0])) + 23'($signed(es_out[2])) + 23'($signed(es_out[4])) + 23'($signed(es_out[6]));
    mix_r <= 23'($signed(es_out[1])) + 23'($signed(es_out[3])) + 23'($signed(es_out[5])) + 23'($signed(es_out[7]));
end
logic mix_valid;
always_ff @(posedge clk_sys) mix_valid <= es_out_valid;

// the MB87078 volume control: the game's fades and level, then 16-bit out
wire signed [15:0] snd_l, snd_r;        // MAME's own level, pre-boost
rf_mb87078 mb87078
(
    .clk(clk_sys), .reset(cpu_reset),
    .we(vl_we), .offset(vl_offset), .data(vl_data),
    .in_valid(mix_valid), .in_l(mix_l), .in_r(mix_r),
    .out_l(snd_l), .out_r(snd_r)
);

// ---- AUDIO BOOST -------------------------------------------------------
// The chain above reproduces MAME's gain structure exactly, and MAME's
// gain structure for this board is very quiet. rf_mb87078's 0 dB
// coefficient is 576 against a >>> 15, i.e. 576/32768 -- which is precisely
// taito_en's x3.125 at 0 dB, times MAME's 0.18 route gain, times the
// ES5506 pump's 0.5, times the 20-bit -> 16-bit 1/16. Ray Force then runs
// the chip at -7.5 dB (data 0x30), not 0 dB, so the total is about 1/135.
//
// Measured on the board's own Audio Ring capture (dump/en5/audio_ring_b13.log,
// 17714 samples): peak 693 of 32768 = -33.5 dBFS, rms 232 = -43.0 dBFS. That
// is 25-30 dB below where a MiSTer arcade core normally sits, and it is why
// both games sound almost silent at a normal amplifier setting.
//
// So this is not a defect to correct but a level to choose. The boost is a
// saturating left shift on the finished 16-bit sample, defaulting to 8x
// (+18 dB, peak -15.4 dBFS on that capture); 16x is there for quiet
// amplifiers and 1x reproduces MAME's own level for anyone comparing.
// Saturation means a louder passage than that capture clips gracefully
// rather than wrapping.
wire [1:0] aud_boost = status[17:16];
wire [2:0] aud_sh = (aud_boost == 2'd0) ? 3'd3 :    // 8x  -- the default
                    (aud_boost == 2'd1) ? 3'd0 :    // 1x  -- MAME's level
                    (aud_boost == 2'd2) ? 3'd2 :    // 4x
                                          3'd4;     // 16x

// Written out per side rather than as a function: quartus_map 17.0 is
// unreliable elaborating functions in this design (rf_selftest carries the
// same note, and duplicates a mux for the same reason). Same saturating
// form rf_mb87078 uses on its own output.
wire signed [23:0] aud_wl = 24'($signed(snd_l)) <<< aud_sh;
wire signed [23:0] aud_wr = 24'($signed(snd_r)) <<< aud_sh;
assign AUDIO_L = (aud_wl >  24'sd32767) ?  16'sd32767 :
                 (aud_wl < -24'sd32768) ? -16'sd32768 : aud_wl[15:0];
assign AUDIO_R = (aud_wr >  24'sd32767) ?  16'sd32767 :
                 (aud_wr < -24'sd32768) ? -16'sd32768 : aud_wr[15:0];


rf_uart_dump uart_dump
(
    .clk(clk_sys),
    .reset(cpu_reset | (uart_mode == 2'd0)),
    .ring_wptr(ring_wptr), .ring_full(ring_full),
    .ring_raddr(ring_raddr), .ring_rdata(ring_rdata),
    .wr_hash(wr_hash),
    .txd(uart_ring_txd)
);

////////////////////////   VIDEO   ///////////////////////////////

rayforce_video video
(
    .clk(clk_sys),
    .reset(reset),

    .dl_active(ioctl_download),
    .dl_seen(dl_seen),
    .dl_bytes(dl_bytes),
    .dl_sum(dl_sum),
    .dl_index(dl_index),
    .trap_oor(trap_oor),
    .wr_count(wr_count),
    .wr_hash(wr_hash),
    .last_pc(last_pc),
    .bist_sum(bist_sum),
    .bist_done(bist_done),

    .frame_cnt(frame_cnt),
    .irq2_cnt(irq2_cnt),
    .irq3_cnt(irq3_cnt),
    .pf_wr_cnt(pf_wr_cnt),
    .spr_wr_cnt(spr_wr_cnt),
    .pal_wr_cnt(pal_wr_cnt),
    .line_wr_cnt(line_wr_cnt),

    // the mixer owns the palette port now; the diagnostic page's palette
    // panel is dark, and the page itself is superseded by the self-test
    .v_pal_addr(),
    .v_pal_q(16'd0),

    .vis_mode(cfg_vis),
    .rate_60(rate_60),
    .vbl_rise(vbl_rise),
    .div_o(vid_div), .hcnt_o(vid_hcnt), .vcnt_o(vid_vcnt),

    .ce_pix(ce_pix),
    .r(rgb_r), .g(rgb_g), .b(rgb_b),
    .hblank(hblank), .vblank(vblank),
    .hsync(hsync), .vsync(vsync)
);

wire vbl_rise;
wire [2:0] vid_div;
wire [8:0] vid_hcnt, vid_vcnt;

////////////////////////  VIDEO PIPELINE  ////////////////////////
//
// Line decode -> playfield build (tiles from SDRAM) -> pivot/text -> sprite
// engine (sprite RAM walk + gfx fetch over shared ch4) -> mixer, all one or
// two lines ahead of the beam, into a double-banked output line buffer.
// Every block in it is verified pixel-exact against MAME in Verilator
// (sim/), sprites included; the ch4 sharing runs inside the pipe bench
// (sim/pipe_top.sv) so the arbitration meets the regression too.
//
// flip is tied high because Ray Force sets the flipscreen bit permanently
// (its graphics are stored flipped in ROM); the sprite engine reads its own
// flip from the sprite command word.

wire [23:0] game_rgb;
wire [31:0] vid_dbg_lines, vid_dbg_fetch, vid_dbg_max, vid_dbg_nz, vid_dbg_spr, vid_dbg_rec;
wire [31:0] vid_dbg_sfetch;
wire [31:0] vid_dbg_sprpix;   // DIAGNOSTIC: per-line framebuffer verdict
// INSTRUMENT: the two halves of the shared-DDR3-port question. Every counter
// this core already has sits on the sprite side of that port -- the side that
// WINS arbitration -- which is why they all read clean while the screen is
// visibly wrong under load. See rf_ddr_arb.sv.
wire [15:0] rot_stall_cnt;    // rotation writes that hit a busy port -- the
                              // pixels the UNFIXED path silently lost
wire [15:0] rot_lost_cnt;     // rotation writes dropped by a full FIFO (must be 0)
wire  [7:0] rot_peak_cnt;     // FIFO high-water mark -- says whether FD is right
wire [31:0] vid_dbg_fold;     // {wr_fold, rd_fold} either side of the DDR3 round trip
wire        spr_wr_stb;       // CPU write to sprite RAM (rf_main)
wire [31:0] vid_dbg_tear;     // {writes during the walk, frames affected}
wire [31:0] vid_seq_rec01, vid_seq_rec23, vid_seq_nspr01, vid_seq_nspr23, vid_seq_ovr;
wire [31:0] vid_seq_fold01, vid_seq_fold23, vid_seq_used01, vid_seq_used23;
wire [15:0] spr_short_cnt;    // a line's read came back short (kept wired for
                              // the next investigation; not on the page now)
wire        _unused_spr_short = &{1'b0, spr_short_cnt};
// The rotation instruments stay in the RTL (the FIFO is a real fix for a real
// Avalon violation) but are off the page now that the port is exonerated.
wire        _unused_rot = &{1'b0, rot_stall_cnt, rot_lost_cnt, rot_peak_cnt};
wire [31:0] vid_dbg_mixpix;   // DIAGNOSTIC: the mixer's inputs on a wrong pixel

// ---- the sprite framebuffer's DDR3 port --------------------------------
wire  [7:0] fb_burstcnt;
wire [28:0] fb_addr;
wire [63:0] fb_din, fb_dout;
wire  [7:0] fb_be;
wire        fb_we, fb_rd, fb_busy, fb_dout_ready;
// ...and screen_rotate's, which rf_ddr_arb muxes against it
wire  [7:0] rot_burstcnt;
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
wire        rot_we, rot_busy;

rf_video_pipe vpipe
(
    .clk(clk_sys), .reset(reset), .clk_ram(clk_ram),
    .div(vid_div), .hcnt(vid_hcnt), .vcnt(vid_vcnt),
    .hblank(hblank), .vblank(vblank), .rate_60(rate_60),
    .ctrl0(vctrl0), .ctrl1(vctrl1), .flip(1'b1), .vis_mode(cfg_vis),
    // EXTEND IS LIVE again as of the Puzzle Bobble 2 build: the LABs came
    // from compiling the framework's Y/C encoder and ascal's adaptive
    // filter out (see the VERILOG_MACRO block in Rayforce.qsf), which costs
    // no game behaviour. If a future build runs out of room again, tying
    // this back to 1'b1 folds every extend mux away and is the cheapest
    // ~116 LABs in the design -- at the price of the games below.
    //
    // Previous note, kept because the reasoning still applies:
    // EXTEND WAS TIED OFF, 2026-08-31, and the RTL behind it is kept.
    // extend=0 is implemented and verified end to end -- the model against
    // MAME (Puzzle Bobble 2 frame 1800 pixel-identical) and the RTL against
    // the model (all seven bench suites at baseline pixel counts) -- but it
    // costs ~1158 ALMs / ~116 LABs and the design has no room: three fits in
    // a row died on Error 170012, and the third got WORSE (4321 LABs) after
    // reductions that should have helped, which says fitter variance at this
    // utilisation is larger than anything trimming can buy.
    //
    // Tying it to a constant lets Quartus fold every extend mux away, so the
    // code costs nothing while it waits. Restore `cfg_extend` here once the
    // LAB budget has real headroom -- see PREP-BUBBLE.md for the plan (the
    // expectations ROM, and the record store is the elephant at ~19 % of the
    // device). Nothing else needs changing to bring it back.
    .extend(cfg_extend),
    .line_addr(v_line_addr), .line_q(v_line_q),
    .pf_addr(v_pf_addr),     .pf_q(v_pf_q),
    .pal_addr(v_pal_addr),   .pal_q(v_pal_q),
    .text_addr(v_text_addr), .text_q(v_text_q),
    .char_addr(v_char_addr), .char_q(v_char_q),
    .pivot_addr(v_pivot_addr), .pivot_q(v_pivot_q),
    .ch1_addr(ch1_addr), .ch1_dout(ch1_dout), .ch1_req(ch1_req), .ch1_ready(ch1_ready),
    .ch2_addr(ch2_addr), .ch2_dout(ch2_dout), .ch2_req(ch2_req), .ch2_ready(ch2_ready),
    .spr_addr(v_spr_addr), .spr_q(v_spr_q),
    .spr_a_lo_addr(spr_a_lo_addr), .spr_a_lo_dout(spr_a_lo_dout), .spr_a_lo_req(spr_a_lo_req), .spr_a_lo_ready(spr_a_lo_ready),
    .spr_a_hi_addr(spr_a_hi_addr), .spr_a_hi_dout(spr_a_hi_dout), .spr_a_hi_req(spr_a_hi_req), .spr_a_hi_ready(spr_a_hi_ready),
    .spr_b_lo_addr(spr_b_lo_addr), .spr_b_lo_dout(spr_b_lo_dout), .spr_b_lo_req(spr_b_lo_req), .spr_b_lo_ready(spr_b_lo_ready),
    .spr_b_hi_addr(spr_b_hi_addr), .spr_b_hi_dout(spr_b_hi_dout), .spr_b_hi_req(spr_b_hi_req), .spr_b_hi_ready(spr_b_hi_ready),
    .rgb(game_rgb),
    .dbg_lines(vid_dbg_lines), .dbg_fetch(vid_dbg_fetch), .dbg_max(vid_dbg_max),
    .dbg_nz(vid_dbg_nz), .dbg_spr(vid_dbg_spr), .dbg_rec(vid_dbg_rec),
    .dbg_sfetch(vid_dbg_sfetch),
    .dbg_short(spr_short_cnt), .dbg_fold(vid_dbg_fold),
    .spr_wr_stb(spr_wr_stb), .dbg_tear(vid_dbg_tear),
    .dbg_seq_rec01(vid_seq_rec01), .dbg_seq_rec23(vid_seq_rec23),
    .dbg_seq_nspr01(vid_seq_nspr01), .dbg_seq_nspr23(vid_seq_nspr23), .dbg_seq_ovr(vid_seq_ovr),
    .dbg_seq_fold01(vid_seq_fold01), .dbg_seq_fold23(vid_seq_fold23),
    .dbg_seq_used01(vid_seq_used01), .dbg_seq_used23(vid_seq_used23),
    .dbg_sprpix(vid_dbg_sprpix), .dbg_mixpix(vid_dbg_mixpix), .row_cap(spr_row_cap),
    .pal12(cfg_pal12),
    .tile_base_lo(map_tile_lo), .tile_base_hi(map_tile_hi),
    .sgfx_base_lo(map_sgfx_lo), .sgfx_base_hi(map_sgfx_hi),
    .ddr_burstcnt(fb_burstcnt), .ddr_addr(fb_addr), .ddr_din(fb_din),
    .ddr_be(fb_be), .ddr_we(fb_we), .ddr_rd(fb_rd),
    .ddr_busy(fb_busy), .ddr_dout(fb_dout), .ddr_dout_ready(fb_dout_ready)
);

///////////////////  SELF TEST PAGE + UART DEBUG  ////////////////
//
// The self-test page is the bring-up instrument: a labelled pass/fail list
// instead of a screen of bare hex, drawn from its own ROMs so it still
// renders when the video chipset is half-written. rf_uart_log walks the SAME
// character port, so what comes out of /dev/ttyS1 is the page, character for
// character -- no second copy of the formatting to keep in step.
//
//   O[3]   Self Test    0 = game video (default), 1 = show the page
//   O[5:4] UART Debug   0 = self-test page (default), 1 = off, 2 = the
//                       Phase 0/1 write-ring dump (rf_write_compare.py).
//                       On by default: the OSD cannot be driven remotely, and
//                       a debug channel that has to be switched on by hand at
//                       the cabinet is not much of a debug channel.

wire [23:0] st_rgb;
wire  [4:0] st_urow;
wire  [5:0] st_ucol;
wire  [7:0] st_uchar;

rf_selftest selftest
(
    .clk(clk_sys),
    .div(vid_div), .hcnt(vid_hcnt), .vcnt(vid_vcnt),

    .dl_active(ioctl_download), .dl_seen(dl_seen),
    .game_id(cfg_game),
    .hs_sh_ok(hs_sh_ok), .hs_injected(hs_injected),
    .exp_bytes(exp_bytes), .exp_sum(exp_sum), .exp_bist(exp_bist), .exp_hash(exp_hash),
    .dl_bytes(dl_bytes), .dl_sum(dl_sum),
    .bist_sum(bist_sum), .bist_done(bist_done),
    .wr_count(wr_count), .wr_hash(wr_hash),
    .last_pc(last_pc), .trap_oor(trap_oor),
    .frame_cnt(frame_cnt), .irq2_cnt(irq2_cnt), .irq3_cnt(irq3_cnt),
    .irq2_rate(irq2_rate), .irq3_rate(irq3_rate),
    .irq_rate_valid(irq_rate_valid),
    .pal_wr_cnt(pal_wr_cnt), .pf_wr_cnt(pf_wr_cnt), .spr_wr_cnt(spr_wr_cnt),
    // DIAGNOSTIC BUILD: rows 17-20 (PLAYFIELD / SPRITE / LINE RAM / TEXT AND
    // CHAR, bring-up write-count liveness the working pipe already implies)
    // and row 25 carry the prepass SEQUENCE instruments instead. Restore
    // once the sprite corruption is closed.
    // RECSEQ / NSPRSEQ proved the prepass identical frame to frame on a
    // paused glitch (2026-09-07 evening); rows 17-20 now carry FOLDSEQ and
    // USEDSEQ, which split the DRAW from the MIXER.
    .seq_rec01(vid_seq_fold01), .seq_rec23(vid_seq_fold23),
    .seq_nspr01(vid_seq_used01), .seq_nspr23(vid_seq_used23),
    ._unused_seq(&{1'b0, vid_seq_rec01, vid_seq_rec23, vid_seq_nspr01, vid_seq_nspr23}),
    .pal_wr_hi(pal_wr_hi), .pal_wr_lo(pal_wr_lo),
    .line_wr_cnt(line_wr_cnt), .txt_wr_cnt(txt_wr_cnt),
    .build_hex(`RF_BUILD_HEX),
    .vid_lines(vid_dbg_lines), .vid_fetch(vid_dbg_fetch), .vid_max(vid_dbg_max),
    // DIAGNOSTIC BUILD: row 25 is borrowed from TILE NZ:PF:PAL (a bring-up
    // liveness check the working pipe already implies) and carries
    // SPRFOLD WR:RD instead -- the two folds either side of the sprite
    // framebuffer's DDR3 round trip. ROTSTL:PK:LOST had this row for one
    // build and did its job: 0 stalls across 210 samples of gameplay ruled
    // the shared DDRAM port out entirely. Restore vid_dbg_nz and
    // rf_selftest's row 25 once the sprite corruption is closed.
    .vid_nz(vid_seq_ovr),
    .vid_spr(vid_dbg_spr), .vid_rec(vid_dbg_rec),
    .vid_sfetch(vid_dbg_sfetch),
    .vid_sprpix(vid_dbg_sprpix),   // STALELN:AGE:CNT, see rf_spr_fb
    .snd_diag1({pivot_wr_cnt, snd_pc[15:0]}),
    .snd_diag2({snd_es_wr_cnt, 15'd0, snd_running}),
    .snd_diag3({smp_bist_sum[15:0], es_dbg_overrun[7:0], es_dbg_wqdrop[7:0]}),
    .smp_bist_done(smp_bist_done), .smp_bist_pass(smp_bist_pass),

    .rgb(st_rgb),
    .u_row(st_urow), .u_col(st_ucol), .u_char(st_uchar)
);

rf_uart_log uart_log
(
    .clk(clk_sys),
    .reset(reset),
    .enable(uart_mode == 2'd0),
    .vbl_rise(vbl_rise),
    .row(st_urow), .col(st_ucol), .char_in(st_uchar),
    .txd(uart_log_txd)
);

// Idle high when a producer is not selected, so the HPS UART sees a quiet
// line rather than a break condition.
assign UART_TXD = (uart_mode == 2'd0) ? uart_log_txd : uart_ring_txd;

// Audio Ring (UART Debug = Audio Ring): the first 4096 output samples after
// the sound starts, i.e. AUDIO_L from the first sample whose magnitude
// exceeds 256 once the sound CPU runs, into the write ring as entries
// {lanes 11, address = sample index, data = the 16-bit sample}. 137 ms of
// what the board actually plays, for tools/rf_audio_ring.py to turn into a
// wav and correlate with the model's output for the same moment. Every
// other way of asking "is the sound right" needs an ear in the room.
// Tapped PRE-BOOST, deliberately: this ring exists to prove the board plays
// what the model computes, and tools/rf_audio_match.py reports the amplitude
// ratio against MAME's own mix. Capturing the boosted signal would make that
// ratio the boost setting instead of a verification result.
wire  signed [15:0] aud_l = snd_l;
always_ff @(posedge clk_sys) begin
    aud_ring_we <= 1'b0;
    if (cpu_reset | snd_reset) begin
        aud_armed <= 1'b0; aud_idx <= 23'd0;
    end else if (es_out_valid) begin
        // the index counts every output sample since the sound CPU was
        // released, so a capture is placed on the model's timeline (the
        // model's t = 0 is MAME's reset, ~2 s before the release)
        aud_idx <= aud_idx + 23'd1;
        if (!aud_armed && (aud_l > 16'sd256 || aud_l < -16'sd256)) aud_armed <= 1'b1;
        if (aud_armed || (aud_l > 16'sd256 || aud_l < -16'sd256)) begin
            aud_ring_we   <= 1'b1;
            aud_ring_data <= {2'b11, aud_idx, 15'd0, aud_l};
        end
    end
end

wire       ce_pix;
wire [7:0] rgb_r, rgb_g, rgb_b;
wire       hblank, vblank, hsync, vsync;

wire [7:0] r8, g8, b8;
wire       vga_de, vga_hs, vga_vs;
wire [1:0] vga_sl;

arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
    .clk_video(clk_sys),
    .ce_pix(ce_pix),
    .RGB_in(selftest_on ? st_rgb : game_rgb),
    .HBlank(hblank), .VBlank(vblank),
    .HSync(hsync),  .VSync(vsync),

    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(r8), .VGA_G(g8), .VGA_B(b8),
    .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),
    .VGA_SL(vga_sl),

    .fx(scandoubler_fx),
    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(gamma_bus)
);

assign VGA_R  = r8;
assign VGA_G  = g8;
assign VGA_B  = b8;
assign VGA_HS = vga_hs;
assign VGA_VS = vga_vs;
assign VGA_DE = vga_de;
assign VGA_SL = vga_sl;

// The cabinet monitor is vertical: rotate through the DDR3 framebuffer for
// ordinary displays (the scaler output only; analog VGA stays raster order,
// which is what a rotated-CRT cab wants). flip is the OSD's Flip Screen;
// Ray Force's OWN flipscreen bit is handled inside the renderer, not here.
screen_rotate screen_rotate
(
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(r8), .VGA_G(g8), .VGA_B(b8),
    .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),

    .rotate_ccw(rotate_ccw),
    .no_rotate(eff_no_rotate),
    .flip(flip_screen),
    .video_rotated(video_rotated),

    .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
    .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL), .FB_LL(FB_LL),

    // Through rf_ddr_arb rather than straight at the port: the sprite
    // framebuffer shares it now. screen_rotate's view is unchanged -- it
    // still sees a port that is busy or not, and it still never reads.
    .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(rot_busy),
    .DDRAM_BURSTCNT(rot_burstcnt), .DDRAM_ADDR(rot_addr),
    .DDRAM_BE(rot_be), .DDRAM_WE(rot_we), .DDRAM_RD(),
    .DDRAM_DIN(rot_din)
);

// One DDRAM port, two clients: MiSTer's rotation framebuffer (write only,
// hard video deadline, wins) and the sprite framebuffer (a whole frame of
// slack). DDRAM_CLK is CLK_VIDEO, which this core drives from clk_sys, so
// everything here is in one clock domain.
rf_ddr_arb ddr_arb
(
    .clk(clk_sys),
    .reset(reset),
    .rot_stall(rot_stall_cnt), .rot_lost(rot_lost_cnt), .rot_peak(rot_peak_cnt),
    .r_burstcnt(rot_burstcnt), .r_addr(rot_addr), .r_din(rot_din),
    .r_be(rot_be), .r_we(rot_we), .r_busy(rot_busy),
    .f_burstcnt(fb_burstcnt), .f_addr(fb_addr), .f_din(fb_din),
    .f_be(fb_be), .f_we(fb_we), .f_rd(fb_rd),
    .f_busy(fb_busy), .f_dout(fb_dout), .f_dout_ready(fb_dout_ready),
    .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY)
);

endmodule
