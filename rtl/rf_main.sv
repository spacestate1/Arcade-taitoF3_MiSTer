//============================================================================
//  Ray Force / Gunlock -- Taito F3 main board
//
//  This replaces rf_cpu_spike. The spike answered one question (does TG68K.C
//  in 020 mode execute this program the way a 68020 does -- yes, write hash
//  0x10620931) with a deliberately fake memory map: everything outside
//  ROM/RAM/palette read back as zero and no interrupt was ever delivered, so
//  the boot code ran to its vblank wait at ~0x4060 and stopped there.
//
//  Phase 2 needs the program actually running, so this is the real map from
//  taito_f3.cpp f3_map, plus the two interrupts and the control port:
//
//    000000-0FFFFF  program ROM, 1 MB, SDRAM via rf_prog_bus (wait-stated)
//    100000-1FFFFF  rest of the mapped ROM window, unpopulated -> 0x0000
//    300000-30007F  sound bankswitch (KIRAMEKI only; ignored, write-only)
//    400000-41FFFF  main RAM 128 KB, mirrored at 420000-43FFFF
//    440000-447FFF  palette RAM 32 KB = 8192 x 24-bit entries
//    4A0000-4A001F  control: inputs, coin counters, EEPROM, watchdog
//    4C0000-4C0003  timer control (gunlock writes 0x0000; ignored)
//    600000-60FFFF  sprite RAM 64 KB
//    610000-617FFF  playfield RAM, the tilemap window (4 x 0x2000, extend)
//    618000-61BFFF  playfield RAM, upper half -- RAM, not used as tilemaps
//    61C000-61DFFF  text RAM 8 KB   (64x64 char codes + palette)
//    61E000-61FFFF  char RAM 8 KB   (256 4bpp 8x8 characters, CPU generated)
//    620000-62FFFF  line RAM 64 KB  (the per-scanline effect engine)
//    630000-63FFFF  pivot RAM 64 KB (512x256 4bpp pixel layer)
//    660000-66001F  video control: playfield scroll, pivot scroll, extend
//    C00000-C007FF  dual-port RAM to the sound 68000 (MB8421)
//    C80000/C80100  sound CPU reset (ignored until Phase 3)
//
//  Interrupts, from taito_f3.cpp:
//    level 2  vblank, HOLD_LINE
//    level 3  10000 68020 cycles (625 us at 16 MHz) after the vblank IRQ.
//             "some signal from video hardware?" -- the vblank handler waits
//             for it, so it must be delivered or the game hangs in vblank.
//  Both are autovectored (68EC020 AVEC), so the CPU fetches its handler from
//  VBR+0x68 / VBR+0x6C. That fetch IS the acknowledge: TG68K.C exposes no
//  IACK strobe, and the vector read is the one bus cycle that can only mean
//  "the exception is being taken". irq2_cnt/irq3_cnt are on the diagnostic
//  screen so a missed acknowledge shows up as a counter running away from
//  the frame count instead of as a mystery hang.
//
//  The write-stream capture from the spike is kept verbatim -- same ring,
//  same rotl1+add fold -- because it is still the regression oracle against
//  MAME's rf_acc.tr. The first 4096 writes are boot clear loops that finish
//  long before the first vblank, so adding real memory and real interrupts
//  must NOT change the hash. If it does, something here is wrong.
//
//  BRAMs are EXPLICIT altsyncram instances (rf_bram*), never inferred
//  arrays: quartus_map 17.0 does not terminate inferring large byte-sliced
//  arrays (Propcycle, 2026-08-10).
//============================================================================

module rf_main
(
    input  logic        clk,             // 53.372 MHz
    input  logic        reset,

    // pivot store in SDRAM (rf_pivot_bus client). The pivot RAM is 64 KB on
    // the F3 and will not fit in block RAM here; see rf_pivot_bus.sv.
    input  logic        clk_ram,
    output logic [26:1] piv_ch_addr,
    output logic [15:0] piv_ch_din,
    output logic  [1:0] piv_ch_be,
    output logic        piv_ch_rnw,
    output logic        piv_ch_req,
    input  logic        piv_ch_ready,
    input  logic [63:0] piv_ch_dout,

    // program ROM read port (rf_prog_bus client, line-cached SDRAM fetch)
    output logic [21:1] prog_addr,
    output logic        prog_req,
    input  logic [15:0] prog_data,
    input  logic        prog_valid,

    // raster interface: one clk pulse on the first line of vblank
    input  logic        vbl_rise,

    // player inputs, MiSTer joystick words (active high)
    //   [0]=right [1]=left [2]=down [3]=up, buttons from [4],
    //   Start=[10] Coin=[11] Service=[12]
    input  logic [15:0] j0,
    input  logic        pause,          // hold the CPU (MiSTer Pause button)
    // rf_hiscore borrows the CPU's RAM port while hs_pause holds clkena --
    // the same freeze the OSD Pause uses, a few microseconds at a time
    input  logic        hs_pause,
    input  logic [15:0] hs_addr,
    input  logic [15:0] hs_wdata,
    input  logic  [1:0] hs_be,
    input  logic        hs_we,
    output logic [15:0] hs_q,
    input  logic [15:0] j1,
    input  logic        test_sw,        // cabinet TEST switch (OSD toggle)

    // ---- NVRAM: the settings EEPROM, loaded from and saved to the SD card
    // through hps_io's ioctl index 254 (see Rayforce.sv)
    input  logic        nv_wr,
    input  logic  [5:0] nv_addr,
    input  logic [15:0] nv_data,
    input  logic  [5:0] nv_sv_addr,
    output logic [15:0] nv_sv_data,
    output logic        nv_wrote,

    // ---- video side ----------------------------------------------------
    // Playfield / pivot / sprite scroll and the 1024x512 "extend" bit.
    // ctrl0 = 0x660000-0F (words 0-7), ctrl1 = 0x660010-1F (words 8-15).
    output logic [7:0][15:0] ctrl0,
    output logic [7:0][15:0] ctrl1,

    // Read ports into the video RAMs. Every one is the B side of a true
    // dual-port BRAM; the CPU owns the A side. Address in, data out one
    // clock later, held until the address changes.
    input  logic [13:0] v_pal_addr,   output logic [15:0] v_pal_q,
    input  logic [13:0] v_pf_addr,    output logic [15:0] v_pf_q,
    input  logic [11:0] v_text_addr,  output logic [15:0] v_text_q,
    input  logic [11:0] v_char_addr,  output logic [15:0] v_char_q,
    input  logic [14:0] v_line_addr,  output logic [15:0] v_line_q,
    input  logic [14:0] v_pivot_addr, output logic [15:0] v_pivot_q,
    input  logic [14:0] v_spr_addr,   output logic [15:0] v_spr_q,

    // ---- instrumentation -------------------------------------------------
    output logic [31:0] wr_count,
    output logic [31:0] wr_hash,
    output logic [31:0] last_pc,
    output logic        trap_oor,
    output logic [15:0] frame_cnt,
    output logic [15:0] irq2_cnt,
    output logic [15:0] irq3_cnt,
    output logic [15:0] pf_wr_cnt,
    output logic [15:0] spr_wr_cnt,
    // TEARING INSTRUMENT: the raw strobe, so the video side can count the
    // writes that land WHILE the sprite list walk is reading the same RAM.
    // The walk starts at frame_start and streams for as long as it takes,
    // with no snapshot and no interlock -- so a CPU write during it makes the
    // walk see part of the old list and part of the new one. Neither MAME
    // (which reads sprite RAM atomically) nor the bench (which feeds it a
    // static snapshot) can ever produce that, which is why the picture is
    // right in both and wrong on the board.
    output logic        spr_wr_stb,
    output logic [15:0] pal_wr_cnt,
    // DIAGNOSTIC: palette writes split at entry 0x1000 (CPU address bit 14).
    // Darius Gaiden's level-load rewrites both halves in one burst; on the
    // board the lower half lands (the sky is right) and the upper half's
    // burst-only entries keep their title-screen values, while the same
    // upper half accepts the ~83 writes/frame the game animates
    // continuously. These counters split the one open question: does the
    // CPU ISSUE the upper-half burst at level entry. A ~2000 jump at the
    // transition with the colours staying stale means the writes are being
    // lost in the core; no jump means the CPU took a different path.
    output logic [15:0] pal_wr_hi,
    output logic [15:0] pal_wr_lo,
    input  logic  [2:0] cpu_speed,      // OSD throttle, 0 = core as built
    // ZONE INJECTOR (Ray Force). 0 = off. 1..3 = start the game at zone
    // 2..4. Ray Force's new-game init (ROM 0x004810) stores the constant 1
    // into the zone word at 0x402312 and the stage loader consumes it in
    // the SAME frame, so nothing that writes RAM once a frame can change
    // it -- proved in MAME: holding the byte every frame did nothing,
    // substituting the value AT that store loaded zone 2 (44 % of pixels
    // differ from a zone-1 frame at the same instant). So this is a
    // bus-level swap: when the CPU writes 0x0001 to that word, the RAM
    // sees {8'h00, zone}. Zone clears write 2, 3, 4... and pass untouched;
    // GAME OVER -> new game writes 1 -> substituted again. Reaching a
    // boss on demand is the point: the worst sprite corruption is at the
    // zone 2 boss and no bench reproduces it. Carried on MRA index 1
    // bits [4:3], which were spare (Rayforce.sv GAME CONFIG).
    input  logic  [1:0] zone_inj,
    output logic [31:0] cpu_spin,       // {spin reads, tower A writes, tower B writes}
    output logic [15:0] line_wr_cnt,
    output logic [15:0] txt_wr_cnt,
    // Interrupt acknowledges in the last 64 frames. A running game takes
    // exactly one vblank interrupt per frame, so 64 here is the pass
    // condition -- a raw counter cannot tell "acknowledged every frame" from
    // "acknowledged twice on half of them".
    output logic [15:0] irq2_rate,
    output logic [15:0] irq3_rate,
    output logic        irq_rate_valid,

    // ---- sound board (Phase 3) -------------------------------------------
    // the MB8421's other side, driven by rf_sound_main
    input  logic  [9:0] snd_dp_addr,
    input  logic [15:0] snd_dp_wdata,
    input  logic        snd_dp_wren,
    input  logic  [1:0] snd_dp_be,
    output logic [15:0] snd_dp_q,
    // C80100 asserts the sound CPU's reset, C80000 releases it; held from
    // boot (taito_f3.cpp machine_reset asserts it)
    output logic        snd_reset,
    // when ring_ext_sel, the write ring records ring_ext_* (the sound
    // CPU's chip writes) instead of this CPU's writes
    input  logic        ring_ext_sel,
    // TRIGGERED CAPTURE (Write Ring mode only). The ring is circular, so it
    // always holds the last 2048 writes -- but the UART needs ~2.5 s to read
    // 2048 entries out and this CPU refills the ring far faster than that,
    // so a live read-out is TORN: the head of the dump and its tail come
    // from different moments and the pass cannot be compared against MAME's
    // stream. With this high the ring instead ARMS on the first write into
    // Darius Gaiden's tower palette blocks, records exactly one ring-full
    // from that instant, and stops -- a coherent 2048-write window around
    // the event, which is what a comparison needs. Low restores the circular
    // behaviour every other mode relies on, bit for bit.
    input  logic        ring_arm_en,
    input  logic        ring_ext_we,
    input  logic [55:0] ring_ext_data,
    // pivot RAM is a stub (Ray Force only ever CLEARS it -- one 64 KB
    // write of zeros at boot, and all 30 dumped frames are zero -- and its
    // 64 M10Ks are the sound RAM's); this counts non-zero writes to it so
    // that assumption is checked on every run
    output logic [15:0] pivot_wr_cnt,
    // KIRAMEKI's sound-ROM bank index, for rf_sound_main's 0xC20000 window
    output logic  [2:0] snd_bank_o,
    // low until the game writes 0x300000; only Kirameki ever does
    output logic        snd_bank_en_o,

    // write-ring dump port (UART side)
    input  logic [10:0] ring_raddr,
    output logic [55:0] ring_rdata,
    output logic [10:0] ring_wptr,
    output logic        ring_full
);

    // ---- CPU -------------------------------------------------------------
    logic        clkena;
    logic [31:0] cpu_addr;
    logic [15:0] cpu_din, cpu_dout;
    logic        nWr, nUDS, nLDS;
    logic [1:0]  busstate;              // 00 fetch, 10 read, 11 write, 01 none
    logic [31:0] vbr;
    logic  [2:0] ipl;

    // Wait-state engine, unchanged from the spike (it is the validated part):
    // BRAM and register targets are 2-cycle ops; a ROM access issues one
    // prog_bus request and holds clkena low until the data returns.
    // THE BOOT-BUG RULE: `a` is sampled ONLY while clkena is low -- once
    // clkena pulses, addr_out already belongs to the next operation.
    logic        rom_wait;
    logic        prog_valid_lat;
    logic [15:0] prog_data_lat;

    // ---- CPU speed throttle ---------------------------------------------
    // The F3's 68020 runs at 16.67 MHz. This core clocks TG68K from clk_sys
    // with a clock enable and TG68K is not cycle-accurate, so the effective
    // speed is whatever the enable rate and the wait states happen to make.
    // Darius Gaiden is sensitive to it -- see the speedometer at the bottom
    // of this file for why and for the number to aim at. Setting 0 is the
    // core exactly as it was built before this knob existed, so every other
    // game is untouched until someone selects otherwise.
    logic [7:0] thr_acc;
    logic       thr_go;
    // MEASURED 2026-09-08: Darius Gaiden's vblank spin loop runs 600 times a
    // frame here where real hardware runs it 764 -- this CPU does 79 % of the
    // work the real one does in the same window. The enable rate is not the
    // reason it is slow: `!clkena` in the guard below caps enables at every
    // OTHER clk_sys cycle, i.e. 26.7 MHz against the real board's 16 MHz, so
    // we are already faster in enables and still behind in work. TG68K simply
    // takes more cycles per instruction than a 68020, and the header above
    // has always said so.
    //
    // Settings 1-3 therefore go FASTER than the as-built rate by lifting that
    // every-other-cycle cap, so the deficit can be measured out rather than
    // guessed at. 1.27x is the ratio 764/600 needs if the loop scales
    // linearly with enables -- it may not, because instruction fetches wait
    // on rom_wait regardless of the enable rate, so the right setting is
    // whichever one makes the SPIN row read 764. That row is on the self-test
    // page (see the speedometer at the bottom of this file).
    //
    // Setting 0 is UNCHANGED from every build before this one: inc 128 makes
    // thr_go fire on alternate cycles, which is exactly what `!clkena` alone
    // produced. Nothing moves until someone selects otherwise.
    wire  [7:0] thr_inc = (cpu_speed == 3'd0) ? 8'd128 :   // as built
                          (cpu_speed == 3'd1) ? 8'd163 :   // x1.27 -- target
                          (cpu_speed == 3'd2) ? 8'd192 :   // x1.50
                          (cpu_speed == 3'd3) ? 8'd255 :   // x2.00, the cap
                          (cpu_speed == 3'd4) ? 8'd120 :   // 94 %
                          (cpu_speed == 3'd5) ? 8'd113 :   // 88 %
                          (cpu_speed == 3'd6) ? 8'd96  :   // 75 %
                                                8'd64;     // 50 %
    // 1-3 lift the every-other-cycle cap; everything else keeps it
    wire        cpu_fast = (cpu_speed >= 3'd1) && (cpu_speed <= 3'd3);

    always_ff @(posedge clk) begin
        if (reset) begin
            thr_acc <= 8'd0;
            thr_go  <= 1'b1;
        end else begin
            {thr_go, thr_acc} <= {1'b0, thr_acc} + {1'b0, thr_inc};
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            clkena    <= 1'b0;
            rom_wait  <= 1'b0;
            prog_req  <= 1'b0;
        end else begin
            prog_req <= 1'b0;
            clkena   <= 1'b0;

            if (rom_wait) begin
                if (prog_valid_lat) begin
                    rom_wait <= 1'b0;
                    clkena   <= 1'b1;
                end
            end else if ((cpu_fast || !clkena) && !pause && !hs_pause && thr_go
                         && !piv_busy) begin
                // pause: no further clock enables, so the CPU freezes between
                // bus cycles (a ROM fetch in flight still completes above)
                if (sel_rom && (busstate == 2'b00 || busstate == 2'b10)) begin
                    prog_addr <= a[21:1];
                    prog_req  <= 1'b1;
                    rom_wait  <= 1'b1;
                end else begin
                    clkena <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset || clkena) prog_valid_lat <= 1'b0;
        else if (prog_valid) begin
            prog_valid_lat <= 1'b1;
            prog_data_lat  <= prog_data;
        end
    end

    TG68KdotC_Kernel #(
        .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
        .MUL_Mode(2), .DIV_Mode(2), .BitField(2),
        .BarrelShifter(1), .MUL_Hardware(1)
    ) cpu (
        .clk(clk),
        .nReset(~(reset | wd_rst)),
        .clkena_in(clkena),
        .data_in(cpu_din),
        .IPL(ipl),
        .IPL_autovector(1'b1),          // 68EC020 AVEC: vector = 0x18 | level
        .berr(1'b0),
        .CPU(2'b11),                    // 68020 mode
        .addr_out(cpu_addr),
        .data_write(cpu_dout),
        .nWr(nWr),
        .nUDS(nUDS),
        .nLDS(nLDS),
        .busstate(busstate),
        .longword(),
        .nResetOut(),
        .FC(),
        .clr_berr(),
        .skipFetch(),
        .regin_out(),
        .CACR_out(),
        .VBR_out(vbr)
    );

    // ---- address decode --------------------------------------------------
    wire [23:0] a = cpu_addr[23:0];

    // The program ROM window is the full 2 MB the F3 map gives it: Ray Force
    // populates 1 MB and the MRA pads the rest with zeros, which reads the
    // same as the unpopulated window did. Elevator Action Returns fills it.
    wire sel_rom   = (a[23:21] == 3'b000);                          // 000000-1FFFFF
    wire sel_romhi = 1'b0;                                          // (folded into sel_rom)
    wire sel_ram   = (a[23:18] == 6'b010000);                       // 400000-43FFFF (+mirror)
    wire sel_pal   = (a[23:15] == 9'b010001000);                    // 440000-447FFF
    wire sel_ctrl  = (a[23:16] == 8'h4A);
    wire sel_spr   = (a[23:16] == 8'h60);                           // 600000-60FFFF
    assign spr_wr_stb = cpu_wr && sel_spr && clkena;
    wire sel_61    = (a[23:16] == 8'h61);
    wire sel_pf    = sel_61 && !a[15];                              // 610000-617FFF
    wire sel_pfx   = sel_61 && (a[15:14] == 2'b10);                 // 618000-61BFFF
    wire sel_text  = sel_61 && (a[15:13] == 3'b110);                // 61C000-61DFFF
    wire sel_char  = sel_61 && (a[15:13] == 3'b111);                // 61E000-61FFFF
    wire sel_line  = (a[23:16] == 8'h62);                           // 620000-62FFFF
    wire sel_pivot = (a[23:16] == 8'h63);                           // 630000-63FFFF
    wire sel_vctrl = (a[23:16] == 8'h66) && (a[15:5] == 11'd0);     // 660000-66001F
    // 300000-30007F, the sound-ROM bankswitch. KIRAMEKI STAR ROAD ONLY: it is
    // the only F3 game that banks its sound ROM, and MAME's handler is
    // guarded by `if (m_game == KIRAMEKI)` with every other game logging
    // "Sound bankswitch in unsupported game". Write-only.
    wire sel_sndbank = (a[23:16] == 8'h30) && (a[15:7] == 9'd0);
    wire sel_dpram = (a[23:11] == 13'b1100000000000);               // C00000-C007FF

    wire cpu_wr = !nWr && (busstate == 2'b11) && clkena;
    wire [1:0] be = {~nUDS, ~nLDS};

    // ---- interrupts ------------------------------------------------------
    // 625 us after the vblank IRQ, in clk_sys ticks: 10000 cycles of a 16 MHz
    // 68020 = 625.0 us; 625 us x 53.372 MHz = 33358.
    localparam int INT3_DELAY = 33358;

    logic        irq2, irq3;
    logic [15:0] int3_tmr;

    // The autovector handler fetch is the acknowledge (see the header note).
    //
    // KNOWN LIMITATION: any data READ of VBR+0x68 / +0x6C while the IRQ is
    // pending also counts. The one place that happens is the boot ROM
    // checksum, which sweeps the vector table while interrupts are masked --
    // it drops a pending IRQ2 the game was not going to service anyway, and
    // is where the constant 380-frame offset between frame_cnt and irq2_cnt
    // comes from. Once the game is running nothing reads the vector table as
    // data, and the hardware acknowledge rate is exactly one per frame.
    wire vec_rd = clkena && (busstate == 2'b10);
    wire ack2   = irq2 && vec_rd && (a == (vbr[23:0] + 24'h68));
    wire ack3   = irq3 && vec_rd && (a == (vbr[23:0] + 24'h6C));

    always_ff @(posedge clk) begin
        if (reset) begin
            irq2 <= 1'b0; irq3 <= 1'b0; int3_tmr <= 16'd0;
            frame_cnt <= 16'd0; irq2_cnt <= 16'd0; irq3_cnt <= 16'd0;
        end else begin
            if (vbl_rise) begin
                irq2      <= 1'b1;
                int3_tmr  <= INT3_DELAY[15:0];
                frame_cnt <= frame_cnt + 16'd1;
            end else if (int3_tmr != 16'd0) begin
                int3_tmr <= int3_tmr - 16'd1;
                if (int3_tmr == 16'd1) irq3 <= 1'b1;
            end
            if (ack2) begin irq2 <= 1'b0; irq2_cnt <= irq2_cnt + 16'd1; end
            if (ack3) begin irq3 <= 1'b0; irq3_cnt <= irq3_cnt + 16'd1; end
        end
    end

    // ---- watchdog (TC0640FIO) -------------------------------------------
    // The F3 has one, MAME configures it (WATCHDOG_TIMER in taito_f3.cpp) and
    // the games USE it: Elevator Action Returns' boot deliberately runs into
    // a `BRA.S *` with interrupts masked (ORI #$0700,SR at 0x01014C) and
    // relies on the watchdog to reboot the board out of it. Traced in MAME:
    // it sits at PC 0x01016E for about two seconds, resets, re-runs POST and
    // then reaches its main loop. Without a watchdog this core simply hung
    // there forever, which is exactly what it did until 2026-08-29.
    //
    // Kicked by any write to 0x4A0000. Three seconds of silence resets the
    // 68020 only -- not the core, not SDRAM, not the loaded ROM.
    //
    // Held off while `pause` is asserted: the OSD pause freezes the CPU, so
    // it cannot kick, and a watchdog that fired then would reboot the game
    // every time someone paused it.
    localparam int WD_FRAMES = 180;             // ~3 s at 58.94 Hz
    logic        wd_kick;
    logic  [7:0] wd_cnt;
    logic  [3:0] wd_hold;                       // reset pulse width
    wire         wd_rst = |wd_hold;

    always_ff @(posedge clk) begin
        if (reset) begin
            wd_cnt <= 8'd0; wd_hold <= 4'd0;
        end else begin
            if (wd_hold != 4'd0) wd_hold <= wd_hold - 4'd1;
            if (wd_kick || pause) wd_cnt <= 8'd0;
            else if (vbl_rise) begin
                if (wd_cnt >= WD_FRAMES[7:0]) begin
                    wd_cnt  <= 8'd0;
                    wd_hold <= 4'hF;            // pulse the CPU reset
                end else wd_cnt <= wd_cnt + 8'd1;
            end
        end
    end

    // Acknowledge rate over a 64-frame window.
    logic  [5:0] rate_win;
    logic [15:0] i2_mark, i3_mark;

    always_ff @(posedge clk) begin
        if (reset) begin
            rate_win <= 6'd0; i2_mark <= 16'd0; i3_mark <= 16'd0;
            irq2_rate <= 16'd0; irq3_rate <= 16'd0; irq_rate_valid <= 1'b0;
        end else if (vbl_rise) begin
            rate_win <= rate_win + 6'd1;
            if (rate_win == 6'd63) begin
                irq2_rate <= irq2_cnt - i2_mark;
                irq3_rate <= irq3_cnt - i3_mark;
                i2_mark   <= irq2_cnt;
                i3_mark   <= irq3_cnt;
                irq_rate_valid <= 1'b1;
            end
        end
    end

    // IPL is active low on this core; level 3 wins over level 2.
    always_comb begin
        if      (irq3) ipl = 3'b100;    // ~3
        else if (irq2) ipl = 3'b101;    // ~2
        else           ipl = 3'b111;
    end

    // ---- control port 0x4A0000 ------------------------------------------
    logic [15:0] coin_word0, coin_word1;
    logic        ee_cs, ee_sk, ee_di;
    wire         ee_do;

    rf_eeprom_93c46 eeprom
    (
        .clk(clk), .reset(reset),
        .cs(ee_cs), .sk(ee_sk), .di(ee_di), .do_out(ee_do),
        .ld_wr(nv_wr), .ld_addr(nv_addr), .ld_data(nv_data),
        .sv_addr(nv_sv_addr), .sv_data(nv_sv_data), .wrote(nv_wrote)
    );

    // EEPROMIN: bit0 EEPROM data out, bit1 TEST switch (active low),
    // bits 4-7 coin inputs (active low), the rest pulled high.
    wire [7:0] ee_in = {2'b11, ~j1[11], ~j0[11], 2'b11, ~test_sw, ee_do};

    // IN.0 low word, all active low.
    //  15..12 start 4/3/2/1   11..8 service 3/2/1, tilt
    //   7.. 4 P2 buttons 4..1  3..0 P1 buttons 4..1
    wire [15:0] in0_lo = { 1'b1, 1'b1, ~j1[10], ~j0[10],
                           1'b1, 1'b1, ~(j0[12] | j1[12]), 1'b1,
                           ~j1[7], ~j1[6], ~j1[5], ~j1[4],
                           ~j0[7], ~j0[6], ~j0[5], ~j0[4] };

    // IN.1 low word: joysticks, active low, bit order up/down/left/right from
    // bit 0 up. MiSTer's joystick word is right/left/down/up from bit 0, so
    // the nibbles are reversed here. Bits 8-15 must read high.
    wire [15:0] in1_lo = { 8'hFF,
                           ~j1[0], ~j1[1], ~j1[2], ~j1[3],
                           ~j0[0], ~j0[1], ~j0[2], ~j0[3] };

    logic [15:0] ctrl_q;
    always_comb begin
        case (a[4:1])
            4'h0: ctrl_q = {ee_in, ee_in};      // IN.0 high word (EEPROM byte x2)
            4'h1: ctrl_q = in0_lo;              // IN.0 low  word
            4'h2: ctrl_q = coin_word0;          // IN.1 high word
            4'h3: ctrl_q = in1_lo;              // IN.1 low  word
            4'h4: ctrl_q = 16'hFFFF;            // IN.2 analog, high word
            4'h5: ctrl_q = 16'h0000;            // IN.2 analog, no dial fitted
            4'h6: ctrl_q = 16'hFFFF;            // IN.3 analog, high word
            4'h7: ctrl_q = 16'h0000;            // IN.3 analog
            4'h8: ctrl_q = 16'hFFFF;            // IN.4 P3/P4 buttons
            4'h9: ctrl_q = 16'hFFFF;
            4'hA: ctrl_q = coin_word1;          // IN.5 high word
            4'hB: ctrl_q = 16'hFFFF;            // IN.5 P3/P4 joysticks
            default: ctrl_q = 16'hFFFF;
        endcase
    end

    always_ff @(posedge clk) begin
        wd_kick <= 1'b0;
        if (reset) begin
            coin_word0 <= 16'd0; coin_word1 <= 16'd0;
            {ee_cs, ee_sk, ee_di} <= 3'b000;
        end else if (cpu_wr && sel_ctrl) begin
            case (a[4:1])
                4'h2: coin_word0 <= cpu_dout;               // 4A0004, upper half
                4'hA: coin_word1 <= cpu_dout;               // 4A0014, upper half
                4'h9: if (!nLDS) begin                      // 4A0012 low byte
                    ee_di <= cpu_dout[2];
                    ee_sk <= cpu_dout[3];
                    ee_cs <= cpu_dout[4];
                end
                4'h0: wd_kick <= 1'b1;                      // 4A0000 watchdog
                default: ;
            endcase
        end
    end

    // ---- video control registers 0x660000 -------------------------------
    // Held in unpacked arrays and flattened onto the packed output ports:
    // a variable index into an unpacked array of vectors is the shape
    // Quartus handles best, and the ports stay plain vectors.
    logic [15:0] c0 [0:7];
    logic [15:0] c1 [0:7];
    integer ci;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_vctrl
            assign ctrl0[gi] = c0[gi];
            assign ctrl1[gi] = c1[gi];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) begin
            for (ci = 0; ci < 8; ci = ci + 1) begin
                c0[ci] <= 16'd0;
                c1[ci] <= 16'd0;
            end
        end else if (cpu_wr && sel_vctrl) begin
            if (!a[4]) begin
                if (be[1]) c0[a[3:1]][15:8] <= cpu_dout[15:8];
                if (be[0]) c0[a[3:1]][7:0]  <= cpu_dout[7:0];
            end else begin
                if (be[1]) c1[a[3:1]][15:8] <= cpu_dout[15:8];
                if (be[0]) c1[a[3:1]][7:0]  <= cpu_dout[7:0];
            end
        end
    end

    // ---- memories --------------------------------------------------------
    wire [15:0] ram_q, pal_q, spr_q, pf_q, pfx_q, text_q, char_q,
                line_q, pivot_q, dpram_q;

    // Each CPU write fires ONCE, on the clock-enable cycle. busstate stays
    // 2'b11 for both cycles of a 2-cycle bus op, so without a qualifier the
    // write is performed twice; the one that commits at the end of the
    // clock-enable cycle is the one carrying valid address and data, which
    // build 28154550 established the hard way -- qualifying with !clkena
    // instead (rf_sound_main's rule, which does not transfer: different
    // TG68K mode and speed divider) broke Ray Force outright.
    //
    // The control and video-control registers are left unqualified: writing
    // the same value twice to a latch is idempotent, and the EEPROM lines
    // hang off those, so they are not worth disturbing.

    // CPU-only memories: simple dual port is enough.
    // While rf_hiscore holds hs_pause the CPU's clkena is suppressed, so it
    // neither writes (wren needs clkena) nor latches a read -- the mux is
    // invisible to it. hs_q shares the read port; the CPU's combinational
    // raddr is re-presented the cycle the mux drops back.
    rf_bram_be #(.AW(16)) u_ram (
        .clk(clk),
        .waddr(hs_pause ? hs_addr : a[16:1]),
        .wdata(hs_pause ? hs_wdata : (zone_hit ? {8'h00, 6'd0, zone_inj} + 16'd1 : cpu_dout)),
        .wren(hs_pause ? hs_we : (cpu_wr && sel_ram && clkena)),
        .be(hs_pause ? hs_be : be),
        .raddr(hs_pause ? hs_addr : a[16:1]), .q(ram_q));
    assign hs_q = ram_q;

    rf_bram_be #(.AW(13)) u_pfx (
        .clk(clk), .waddr(a[13:1]), .wdata(cpu_dout),
        .wren(cpu_wr && sel_pfx && clkena), .be(be), .raddr(a[13:1]), .q(pfx_q));

    // MB8421: this CPU on port A, the sound CPU on port B (byte lanes)
    rf_bram_tdp #(.AW(10)) u_dpram (
        .clk(clk),
        .a_addr(a[10:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_dpram && clkena),
        .a_be(be), .a_q(dpram_q),
        .b_addr(snd_dp_addr), .b_wdata(snd_dp_wdata), .b_wren(snd_dp_wren),
        .b_be(snd_dp_be), .b_q(snd_dp_q));

    // sound CPU reset, from the two write-only addresses
    wire sel_sndrst_on  = (a[23:8] == 16'hC801);
    wire sel_sndrst_off = (a[23:8] == 16'hC800);
    always_ff @(posedge clk) begin
        if (reset) snd_reset <= 1'b1;
        else if (cpu_wr && clkena) begin
            if (sel_sndrst_on)  snd_reset <= 1'b1;
            if (sel_sndrst_off) snd_reset <= 1'b0;
        end
    end

    // Video-visible memories: true dual port, CPU on A, renderer on B.
    rf_bram_tdp #(.AW(14)) u_pal (
        .clk(clk),
        .a_addr(a[14:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_pal && clkena),
        .a_be(be), .a_q(pal_q),
        .b_addr(v_pal_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_pal_q));

    rf_bram_tdp #(.AW(15)) u_spr (
        .clk(clk),
        .a_addr(a[15:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_spr && clkena),
        .a_be(be), .a_q(spr_q),
        .b_addr(v_spr_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_spr_q));

    rf_bram_tdp #(.AW(14)) u_pf (
        .clk(clk),
        .a_addr(a[14:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_pf && clkena),
        .a_be(be), .a_q(pf_q),
        .b_addr(v_pf_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_pf_q));

    rf_bram_tdp #(.AW(12)) u_text (
        .clk(clk),
        .a_addr(a[12:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_text && clkena),
        .a_be(be), .a_q(text_q),
        .b_addr(v_text_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_text_q));

    rf_bram_tdp #(.AW(12)) u_char (
        .clk(clk),
        .a_addr(a[12:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_char && clkena),
        .a_be(be), .a_q(char_q),
        .b_addr(v_char_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_char_q));

    rf_bram_tdp #(.AW(15)) u_line (
        .clk(clk),
        .a_addr(a[15:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_line && clkena),
        .a_be(be), .a_q(line_q),
        .b_addr(v_line_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_line_q));

    // ---- pivot (pixel-layer) RAM ----------------------------------------
    // 8 KB of real RAM, MIRRORED eight times across the 64 KB window, not the
    // 64 KB the board has. Why both halves of that sentence:
    //
    //  - It must be REAL, because Elevator Action Returns' power-on self test
    //    walks every RAM on the board writing FFFF/AAAA/5555/0000 and reading
    //    each location straight back. Against the old read-as-zero stub it
    //    wrote FFFF to 0x630000, read 0, and stopped in its error handler --
    //    which is exactly where that game sat until this was fixed
    //    (2026-08-29; the circular write ring is what finally showed it).
    //
    //  - It is MIRRORED because 64 KB is 51 M10Ks and the device has 20 left.
    //    The test verifies each location immediately after writing it, so an
    //    aliased window passes: nothing is written, then re-read later, at an
    //    address that has since been overwritten through the alias. A test
    //    that filled the region and verified afterwards WOULD fail, and this
    //    comment is here so that is the first thing checked if it ever does.
    //
    // Ray Force is unaffected either way: it only ever clears this RAM, which
    // is what `pivot_wr_cnt` (the PIVOT WR self-test row) counts and proves
    // on every run.
    // Port A is UNCHANGED: the CPU's read-back path, still 8 KB, still
    // aliasing above that exactly as it always has. Port B is now unused --
    // the video reads the full 64 KB store through rf_pivot_bus instead.
    rf_bram_tdp #(.AW(12)) u_pivot (
        .clk(clk),
        .a_addr(a[12:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_pivot && clkena),
        .a_be(be), .a_q(pivot_q),
        .b_addr(12'd0), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q());

    // The row being displayed is implied by the address the video asks for
    // (addr[8:4] = ys[7:3]), so nothing in rf_video_pivot has to change and
    // the pipe bench is untouched.
    wire piv_busy;
    rf_pivot_bus u_pivot_bus (
        .reset    (reset),
        .clk_sys  (clk),
        .cpu_addr (a[15:1]),
        .cpu_din  (cpu_dout),
        .cpu_be   (be),
        .cpu_wr   (cpu_wr && sel_pivot && clkena),
        .cpu_busy (piv_busy),
        .row      (v_pivot_addr[8:4]),
        .v_addr   (v_pivot_addr),
        .v_q      (v_pivot_q),
        .clk_ram  (clk_ram),
        .ch_addr  (piv_ch_addr),
        .ch_din   (piv_ch_din),
        .ch_be    (piv_ch_be),
        .ch_rnw   (piv_ch_rnw),
        .ch_req   (piv_ch_req),
        .ch_ready (piv_ch_ready),
        .ch_dout  (piv_ch_dout));

    // ---- read mux --------------------------------------------------------
    // Registered one cycle to line up with the BRAM output, exactly like the
    // spike: the address is presented while clkena is low, the RAM registers
    // it, and the CPU samples data_in on the clkena pulse a cycle later.
    localparam [3:0] SRC_ROM=0, SRC_RAM=1, SRC_PAL=2, SRC_SPR=3, SRC_PF=4,
                     SRC_PFX=5, SRC_TEXT=6, SRC_CHAR=7, SRC_LINE=8,
                     SRC_PIVOT=9, SRC_DPRAM=10, SRC_CTRL=11, SRC_VCTRL=12,
                     SRC_ZERO=13;

    logic [3:0]  src;
    logic [3:0]  src_q;
    logic [15:0] ctrl_hold, vctrl_hold;

    always_comb begin
        if      (sel_rom)   src = SRC_ROM;
        else if (sel_ram)   src = SRC_RAM;
        else if (sel_pal)   src = SRC_PAL;
        else if (sel_spr)   src = SRC_SPR;
        else if (sel_pf)    src = SRC_PF;
        else if (sel_pfx)   src = SRC_PFX;
        else if (sel_text)  src = SRC_TEXT;
        else if (sel_char)  src = SRC_CHAR;
        else if (sel_line)  src = SRC_LINE;
        else if (sel_pivot) src = SRC_PIVOT;
        else if (sel_dpram) src = SRC_DPRAM;
        else if (sel_ctrl)  src = SRC_CTRL;
        else if (sel_vctrl) src = SRC_VCTRL;
        else                src = SRC_ZERO;   // romhi and everything unmapped
    end

    always_ff @(posedge clk) begin
        src_q      <= src;
        ctrl_hold  <= ctrl_q;
        vctrl_hold <= a[4] ? c1[a[3:1]] : c0[a[3:1]];
    end

    always_comb begin
        case (src_q)
            SRC_ROM:   cpu_din = prog_data_lat;
            SRC_RAM:   cpu_din = ram_q;
            SRC_PAL:   cpu_din = pal_q;
            SRC_SPR:   cpu_din = spr_q;
            SRC_PF:    cpu_din = pf_q;
            SRC_PFX:   cpu_din = pfx_q;
            SRC_TEXT:  cpu_din = text_q;
            SRC_CHAR:  cpu_din = char_q;
            SRC_LINE:  cpu_din = line_q;
            SRC_PIVOT: cpu_din = pivot_q;
            SRC_DPRAM: cpu_din = dpram_q;
            SRC_CTRL:  cpu_din = ctrl_hold;
            SRC_VCTRL: cpu_din = vctrl_hold;
            default:   cpu_din = 16'h0000;
        endcase
    end

    // ---- write-stream capture (unchanged -- the MAME oracle) -------------
    // The main write ring used to FREEZE at the 4096th write, which was right
    // for Phase 0/1 (capture the boot stream, compare with MAME) and is now
    // actively misleading: the WRITE HASH row already covers those 4096, and
    // a frozen ring looks exactly like a stopped CPU. Chasing Elevator Action
    // Returns, that cost a wrong conclusion -- the ring had simply hit its
    // freeze while the CPU ran on. It is circular now, so a capture always
    // shows the LAST 2048 writes, which is what you want when a game has
    // parked somewhere and you need to know what it did just before.
    // ...but the write COUNT and HASH must still stop at 4096: that pair is
    // the Phase 1 proof, compared against a fixed number from MAME, and a
    // hash that keeps folding is just a moving target. So the freeze stays
    // on the counters and comes off the ring -- two things that used to be
    // one signal (and letting the ring un-freeze the hash cost one build
    // and a FAIL on Ray Force's WRITE HASH row to notice).
    wire wr_frozen = wr_count[12];               // 4096 reached: counters stop
    // 512 entries now (was 2048, was 4096): 56 x 512 is ~3 M10Ks against 11,
    // and the room went to the sprite record store and the tile-row cache
    // (RESOURCES.md). 512 writes is still the whole of a triggered capture
    // window and more than any UART comparison has needed.
    localparam int RING_AW = 9;
    wire ring_wrapped = |wr_count[31:RING_AW];   // more than the ring holds
    assign ring_full = ring_ext_sel ? snd_frozen : ring_wrapped;

    wire bus_write = clkena && (busstate == 2'b11) && !nWr;   // every write
    wire do_write  = bus_write && !wr_frozen;                 // counted ones

    wire [15:0] wdat = {nUDS ? 8'h00 : cpu_dout[15:8],
                        nLDS ? 8'h00 : cpu_dout[7:0]};

    wire [31:0] f0 = {wr_hash[30:0], wr_hash[31]} + {16'd0, a[15:0]};
    wire [31:0] f1 = {f0[30:0], f0[31]} + {16'd0, a[23:16], 6'd0, ~nUDS, ~nLDS};
    wire [31:0] f2 = {f1[30:0], f1[31]} + {16'd0, wdat};

    // the ring records this CPU's writes, or the sound CPU's chip writes
    // (ring_ext_*) when the UART option selects the sound ring; the write
    // count and hash (the Phase 1 proof) always follow this CPU
    // The sound ring freezes on ITS Nth entry (the init sequence, which is
    // deterministic and so the best thing to compare), not the main CPU's,
    // which passed that count during boot long before the sound CPU ran.
    //
    // N was 4096 against a 512-entry ring, so the ring wrapped eight times
    // and what survived was writes 3584..4095 -- a deterministic window, but
    // NOT the start. Comparing it against MAME's stream from reset needs an
    // alignment search, and that search saturates: Riding Fight (silent on
    // the board) scored 58 and Grid Seeker (working) scored 59, so the
    // comparison could not tell a broken game from a working one. Freezing
    // at 512 makes the ring hold writes 0..511 -- the same entries MAME's
    // stream opens with, comparable head-to-head with no alignment at all,
    // which is what finding the FIRST divergence actually requires.
    logic [9:0]  snd_wr_count;
    wire         snd_frozen = snd_wr_count[9];
    always_ff @(posedge clk) begin
        if (reset) snd_wr_count <= 10'd0;
        else if (ring_ext_sel && ring_ext_we && !snd_frozen) snd_wr_count <= snd_wr_count + 10'd1;
    end
    // ---- triggered capture (see ring_arm_en) -----------------------------
    // twr_a / twr_b are the tower palette blocks, declared with the region
    // counters below. Arming on the FIRST such write and freezing one
    // ring-full later brackets the palette copy itself. Both flops stay 0
    // when ring_arm_en is low, so ring_adv below is then exactly what it
    // was before this existed.
    logic ring_armed, ring_frz;
    // Arm LATE, not on the first such write. Measured on build 02205428:
    // twr_a_cnt / twr_b_cnt both reach 0xFF within a minute, so these writes
    // are CONTINUOUS rather than a one-off level-entry copy -- an earlier
    // 14-second capture that showed them parked at 160/216 was simply too
    // short a window, and reading it as "frozen" was wrong. Arming on the
    // first write therefore brackets the TITLE screen, which is exactly the
    // moment whose palette we are not interested in. Waiting for the counter
    // to pass 0xC0 puts the 2048-write window well inside attract play.
    wire  ring_trig = ring_arm_en && !ring_armed
                      && (twr_a || twr_b) && (twr_a_cnt > 8'hC0);
    always_ff @(posedge clk) begin
        if (reset) begin
            ring_armed <= 1'b0;
            ring_frz   <= 1'b0;
        end else if (ring_trig) begin
            ring_armed <= 1'b1;          // wptr is reset to 0 below, so the
            ring_frz   <= 1'b0;          // dump starts at the trigger
        end else if (ring_armed && !ring_frz && ring_raw_adv
                     && ring_wptr == 11'((1 << RING_AW) - 1)) begin
            ring_frz   <= 1'b1;          // one full lap recorded: hold it
        end
    end

    wire        ring_raw_adv = ring_ext_sel ? (ring_ext_we && !snd_frozen) : bus_write;
    wire        ring_adv     = ring_raw_adv && !ring_frz;
    wire [55:0] ring_wdat = ring_ext_sel ? ring_ext_data
                                         : {~nUDS, ~nLDS, a[23:1], 15'd0, wdat};

    always_ff @(posedge clk) begin
        if (reset) begin
            wr_count <= 32'd0;
            wr_hash  <= 32'd0;
            ring_wptr<= 11'd0;
        end else begin
            if (ring_trig)     ring_wptr <= 11'd0;
            else if (ring_adv) ring_wptr <= (ring_wptr + 11'd1) & 11'((1 << RING_AW) - 1);
            if (do_write) begin
                wr_count  <= wr_count + 32'd1;
                wr_hash   <= f2;
            end
        end
    end

    // 2048 entries, not 4096: a 56-bit x 4096 ring is 24 M10Ks -- more than
    // the whole sprite line-buffer ring -- for a debug feature, and M10K is
    // the binding resource on this device (539 of 553 in B13). Halving it
    // frees 12 and still holds a 2048-write comparison against MAME and a
    // 69 ms audio capture, both far more than any check has needed.
    rf_bram #(.WIDTH(56), .AW(RING_AW)) u_ring (
        .clk(clk),
        .waddr(ring_wptr[RING_AW-1:0]),
        .wdata(ring_wdat),
        .wren(ring_adv),
        .raddr(ring_raddr[RING_AW-1:0]), .q(ring_rdata)
    );

    // ---- per-region write counters --------------------------------------
    // These are the "is the game actually rendering" readout: a running
    // program rewrites playfield and sprite RAM every frame, a hung one
    // does not. They saturate rather than wrap so a stall is visible.
    always_ff @(posedge clk) begin
        if (reset) begin
            pf_wr_cnt <= 0; spr_wr_cnt <= 0; pal_wr_cnt <= 0; line_wr_cnt <= 0;
            pal_wr_hi <= 0; pal_wr_lo <= 0;
            txt_wr_cnt <= 0; pivot_wr_cnt <= 0;
        end else if (cpu_wr) begin
            // the game clears pivot RAM at boot (32768 word writes of zero,
            // seen on build 27230527); a zero written to the zero stub is
            // nothing, so only NON-ZERO writes count against the assumption
            if (sel_pivot && cpu_dout != 16'd0 && pivot_wr_cnt != 16'hFFFF) pivot_wr_cnt <= pivot_wr_cnt + 16'd1;
            if (sel_pf   && pf_wr_cnt   != 16'hFFFF) pf_wr_cnt   <= pf_wr_cnt   + 16'd1;
            if (sel_spr  && spr_wr_cnt  != 16'hFFFF) spr_wr_cnt  <= spr_wr_cnt  + 16'd1;
            if (sel_pal  && pal_wr_cnt  != 16'hFFFF) pal_wr_cnt  <= pal_wr_cnt  + 16'd1;
            if (sel_pal  &&  a[14]) pal_wr_hi <= pal_wr_hi + 16'd1;    // free-running,
            if (sel_pal  && !a[14]) pal_wr_lo <= pal_wr_lo + 16'd1;    // wrap is fine
            if (sel_line && line_wr_cnt != 16'hFFFF) line_wr_cnt <= line_wr_cnt + 16'd1;
            if ((sel_text || sel_char) && txt_wr_cnt != 16'hFFFF)
                txt_wr_cnt <= txt_wr_cnt + 16'd1;
        end
    end

    // ---- CPU speedometer: the game's own spin loop -----------------------
    // Darius Gaiden's vblank handler (ROM 0x1A34) raises a flag and then
    // SPINS on work RAM 0x4022B3 with a 1024-iteration dbne budget until
    // IRQ3 (ROM 0x1A54) releases it; only then does it run the frame
    // handler. Every iteration is one read of that byte, so counting those
    // reads between the vblank IRQ and the IRQ3 acknowledge measures this
    // core's 68020 against the clock the game actually cares about.
    //
    // MEASURED IN MAME: 764 reads, min 761 max 765, identical in attract and
    // in game. That is the target. A count near 1024 means the spin times
    // out and the frame handler starts early; a much lower count means the
    // CPU is slow. Either way the frame's work lands in a different place,
    // and this game cannot absorb that: on the Zone A entry frame it makes
    // 39 palette-copy requests into a 32-entry queue and the enqueue routine
    // DISCARDS the excess in silence (ROM 0x167C: cmpi.w #$20,d2 / bge, no
    // retry, no error). Which three requests lose is decided by where the
    // frame boundary falls -- and on hardware the losers are the Zone A
    // tower blocks, which is why they keep their title-screen gold.
    //
    // The row reads in ATTRACT MODE, so the core can be tuned against it
    // without anyone playing to the level.
    localparam logic [22:0] SPIN_ADDR = 23'h201159;     // work RAM 0x4022B2/B3
    wire spin_hit = clkena && (busstate == 2'b10) && sel_ram
                    && (a[23:1] == SPIN_ADDR);
    logic [15:0] spin_cnt;

    // Did the tower palette blocks ever reach palette RAM at all? Entries
    // 0x1164-0x1177 and 0x1021-0x103B are the stale ranges measured on the
    // board, and the per-frame colour animation does not touch them -- so a
    // single write here means the copy ran, and zero means the request was
    // dropped before it ever became a write.
    wire [12:0] pal_entry = a[14:2];
    wire twr_a = cpu_wr && sel_pal && (pal_entry >= 13'h1164) && (pal_entry <= 13'h1177);
    wire twr_b = cpu_wr && sel_pal && (pal_entry >= 13'h1021) && (pal_entry <= 13'h103B);
    logic [7:0] twr_a_cnt, twr_b_cnt;

    always_ff @(posedge clk) begin
        if (reset) begin
            spin_cnt  <= 16'd0;
            twr_a_cnt <= 8'd0;
            twr_b_cnt <= 8'd0;
            cpu_spin  <= 32'd0;
        end else begin
            if (vbl_rise)      spin_cnt <= 16'd0;
            else if (spin_hit) spin_cnt <= spin_cnt + 16'd1;
            if (ack3) cpu_spin[31:16] <= spin_cnt;

            if (twr_a && twr_a_cnt != 8'hFF) twr_a_cnt <= twr_a_cnt + 8'd1;
            if (twr_b && twr_b_cnt != 8'hFF) twr_b_cnt <= twr_b_cnt + 8'd1;
            cpu_spin[15:8] <= twr_a_cnt;
            cpu_spin[7:0]  <= twr_b_cnt;
        end
    end

    // ---- KIRAMEKI sound-ROM bank -----------------------------------------
    // taito_f3.cpp sound_bankswitch_w, verbatim:
    //
    //     idx = (offset << 1) & 0x1e;  if (ACCESSING_BITS_0_15) idx += 1;
    //     if (idx >= 8) idx -= 8;      m_taito_en->set_bank(1, idx);
    //
    // `offset` is a LONGWORD index, so offset<<1 is a[6:1] shifted -- and
    // masking with 0x1e keeps four bits. Only set_bank(1, ...) is ever
    // called, i.e. only cpubank2, the 0xC20000 window; banks 1 and 3 keep the
    // linear mapping this core already gives them. The wrap at 8 makes the
    // index three bits.
    logic [2:0] snd_bank;
    // Belt and braces after the no-sound regression: the C20000 window uses
    // the ordinary linear mapping until the game has actually WRITTEN the
    // bank register. Only Kirameki Star Road ever does. So no other game can
    // be affected by this path at all, whatever the reset value happens to
    // be -- which is the property that was missing when it shipped broken.
    logic       snd_bank_set;
    always_ff @(posedge clk) begin
        // RESETS TO 1, NOT 0. MAME sets the three sound-CPU windows with
        // set_entry(i % max) for i = 0,1,2, so cpubank2 -- the C20000 window
        // this index drives -- starts on ENTRY 1. Resetting it to 0 pointed
        // that window at entry 0, so the sound 68000 executed the wrong
        // 128 KB in EVERY game and no game had sound. Reported from a board
        // 2026-09-08 against build 08154107: "installed the 20260908 version,
        // however I didn't get any sound, reverted and got the sound back".
        if (reset) begin snd_bank <= 3'd1; snd_bank_set <= 1'b0; end
        else if (cpu_wr && sel_sndbank && clkena) begin
            // a[6:2] is the longword offset; <<1 then &0x1e is a[5:2],0.
            // The low half being written adds one, exactly as ACCESSING_BITS_0_15.
            snd_bank     <= {a[4:2], 1'b0} + {2'd0, be[0]};
            snd_bank_set <= 1'b1;
        end
    end
    assign snd_bank_o = snd_bank;
    assign snd_bank_en_o = snd_bank_set;

    // ---- zone injector: the one write it intercepts -----------------------
    // 0x402312 (and its 128 KB mirror at 0x422312) is word 0x1189 of the RAM
    // port; a 16-bit store of 0x0001 with both bytes enabled is the init.
    wire zone_hit = (zone_inj != 2'd0) && cpu_wr && sel_ram && (be == 2'b11)
                    && (a[16:1] == 16'h1189) && (cpu_dout == 16'h0001);

    // ---- fetch monitor ---------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            last_pc  <= 32'd0;
            trap_oor <= 1'b0;
        end else if (clkena && busstate == 2'b00) begin
            last_pc <= cpu_addr;
            if (!sel_rom && !sel_ram) trap_oor <= 1'b1;
        end
    end

endmodule
