//============================================================================
//  Sprite list walker -- the RTL of get_sprite_info (f3_render.py).
//
//  Once per frame (in vblank) this walks sprite RAM and streams out the
//  sprites to be drawn: their screen position (signed .8 fixed), per-block
//  zoom scale, tile code, palette, flips and priority group. It is pure
//  logic over sprite RAM -- no graphics, no framebuffer -- so it is checked
//  entry-for-entry against the model (sim/spr_tb.cpp) before anything reads
//  a sprite pixel.
//
//  The list is a small program: 8 words per entry, a bank bit and a jump
//  command that let it branch and switch halves of the 64 KB RAM, "multi"
//  blocks that reuse the previous block's position/zoom, and per-axis scroll
//  modes that fold in two levels of global offset. All of that is the F3
//  sprite chip, reproduced from MAME via the model. Two accumulators (Axis
//  x/y) carry the position and zoom state across entries within a frame.
//
//  Sprites are at most 16 source pixels, scaled DOWN only (block_scale =
//  0x100 - zoom, 1..256 in .8), so each covers at most 16 screen lines --
//  which is what lets the line builder downstream avoid a full framebuffer.
//
//  The walk is entirely sequential (each entry's jump/bank/globals depend on
//  the last), so it cannot be parallelised; it is run once in vblank into a
//  list the per-line builder then reads many times.
//============================================================================

module rf_video_spr_list
(
    input  logic        clk,
    input  logic        reset,

    // which F3 visarea this game uses -- the cull below rejects sprites
    // that fall outside it, so a window narrower than the game's real one
    // silently loses the top and bottom lines (Elevator Action Returns
    // shows 232 lines where Ray Force shows 224).
    input  logic  [1:0] vis_mode,

    input  logic        start,          // pulse: begin a walk (in vblank)
    input  logic        start_bank,     // engine bank entering the frame (0)
    output logic        busy,
    output logic        done,           // one pulse when the walk finishes

    // frame-global engine state, valid from `done` until the next `start`
    output logic        o_flip,
    output logic  [1:0] o_extra,        // extra colour planes (0-3)
    // 6 BITS, not 5. MAME's pen mask is (extra_planes << 4) | 0x0F with
    // extra_planes 0..3, so it reaches 0x3F -- and F3 sprite graphics are
    // 6bpp, 64 pens. At 5 bits the expression below silently lost its top
    // bit: extra=2 produced 0x0F instead of 0x2F and extra=3 produced 0x1F
    // instead of 0x3F, masking away the two upper colour planes. Every
    // frame dumped in this tree uses extra 0 or 1, which fit, so no bench
    // covers it and no shipped game has shown it.
    output logic  [5:0] o_penmask,      // (extra<<4)|0x0F, up to 0x3F

    // sprite RAM read port (B side of the CPU's sprite BRAM)
    output logic [14:0] spr_addr,
    input  logic [15:0] spr_q,

    // one sprite per `s_valid`
    output logic        s_valid,
    output logic signed [17:0] s_tx,    // screen x, .8 fixed
    output logic signed [17:0] s_ty,    // screen y, .8 fixed
    output logic        [8:0]  s_sx,    // block scale x, 1..256 (.8)
    output logic        [8:0]  s_sy,    // block scale y
    output logic       [16:0]  s_code,  // tile number
    output logic        [7:0]  s_color,
    output logic               s_fx,
    output logic               s_fy,
    output logic        [1:0]  s_pri
);
    // visible-area cull bounds, .8 fixed (VIS_X0/1 = 46/365 for every game).
    // The vertical pair follows vis_mode, matching rayforce_video's crop and
    // f3_render.py's _VIS table:
    //   0 f3_224a 31..254   1 f3_224b 32..255
    //   2 f3_224c 24..247   3 f3      24..255
    localparam signed [31:0] X0 = 32'sd11776, X1 = 32'sd93440;   // 46<<8, 365<<8
    wire [8:0] vy0 = (vis_mode == 2'd0) ? 9'd31 :
                     (vis_mode == 2'd1) ? 9'd32 : 9'd24;
    wire [8:0] vy1 = (vis_mode == 2'd0) ? 9'd254 :
                     (vis_mode == 2'd2) ? 9'd247 : 9'd255;
    wire signed [31:0] Y0 = $signed({23'd0, vy0}) <<< 8;
    wire signed [31:0] Y1 = $signed({23'd0, vy1}) <<< 8;

    // ---- engine state ----------------------------------------------------
    logic [9:0]  offs;
    logic [10:0] next_offs, total;   // 11-bit so the 1024 limit and offs+1
                                     // overflow compare correctly
    logic        bank, flip, trails, multi;
    logic [1:0]  extra;
    logic [7:0]  color;

    // Axis accumulators (x and y)
    logic signed [31:0] x_pos, x_bpos, y_pos, y_bpos;
    logic        [8:0]  x_bsc, y_bsc;
    logic signed [15:0] x_glob, x_sub, y_glob, y_sub;

    assign o_flip    = flip;
    assign o_extra   = extra;
    assign o_penmask = {extra, 4'h0} | 6'h0F;

    // ---- the 8 words of the current entry --------------------------------
    logic [15:0] w [0:7];
    logic [3:0]  rk;                     // read counter 0..8

    // decoded fields of the current entry
    wire        is_cmd   = w[3][15];
    wire [7:0]  scont    = w[4][15:8];
    wire        lock     = scont[2];
    wire [3:0]  scroll   = w[2][15:12];
    wire [15:0] zooms    = w[1];
    wire [11:0] xposw    = w[2][11:0];
    wire [11:0] yposw    = w[3][11:0];
    wire [16:0] tile     = {w[5][0], w[0]};
    wire        jump     = w[6][15];
    wire [9:0]  jump_to  = w[6][9:0];
    wire        fx_raw   = scont[0];
    wire        fy_raw   = scont[1];
    wire [1:0]  xbctrl   = scont[7:6];
    wire [1:0]  ybctrl   = scont[5:4];

    // flipscreen effective for THIS entry: a command word sets it before the
    // entry's own position/flip are computed, so a command that also draws
    // uses the new value (matches the model's ordering).
    wire        flip_eff = is_cmd ? w[5][13] : flip;

    // ---- one Axis update, as a function of the entry ---------------------
    // returns {pos, bpos, bsc} given the axis' persistent glob/sub/bpos/pos/bsc
    // NB glob/sub are updated separately below (they can change every entry).
    function automatic logic signed [15:0] axis_np
            (input logic [11:0] posw, input logic signed [15:0] g,
             input logic signed [15:0] s);
        logic signed [15:0] np;
        np = {{4{posw[11]}}, posw};                 // sext(posw,12)
        if (!scroll[3]) begin
            np = np + g;                            // s16 wrap is implicit at 16b
            if (!scroll[2]) np = np + s;
        end
        return np;
    endfunction

    // ---- streaming outputs -----------------------------------------------
    logic signed [31:0] tx, ty;
    logic [8:0]         bsx, bsy;

    typedef enum logic [2:0] {L_IDLE, L_READ, L_PROC, L_NEXT} lst_t;
    lst_t st;

    assign busy = (st != L_IDLE);
    assign spr_addr = {bank, 1'b0, offs, rk[2:0]};

    always_ff @(posedge clk) begin
        s_valid <= 1'b0;
        done    <= 1'b0;

        if (reset) begin
            st <= L_IDLE;
        end else case (st)
            L_IDLE: if (start) begin
                offs   <= 10'd0;  total <= 11'd0;
                bank   <= start_bank;
                flip   <= 1'b0;   extra <= 2'd0;   trails <= 1'b0;
                multi  <= 1'b0;   color <= 8'd0;
                x_pos  <= '0; x_bpos <= '0; x_bsc <= 9'd256; x_glob <= '0; x_sub <= '0;
                y_pos  <= '0; y_bpos <= '0; y_bsc <= 9'd256; y_glob <= '0; y_sub <= '0;
                rk     <= 4'd0;
                st     <= L_READ;
            end

            // read the 8 words: address presented for rk, data one clock later
            L_READ: begin
                if (rk >= 4'd1 && rk <= 4'd8) w[rk - 4'd1] <= spr_q;
                if (rk == 4'd8) st <= L_PROC;
                else rk <= rk + 4'd1;
            end

            // process one entry: command, globals, both Axis updates, emit
            L_PROC: begin
                // ---- special command word ---- (applied even on a self-jump)
                if (is_cmd) begin
                    flip   <= w[5][13];
                    extra  <= w[5][9:8];
                    trails <= w[5][1];
                    bank   <= w[5][0];
                end

                // A jump to this same entry terminates the list right here:
                // the command above has taken effect, but nothing is emitted
                // and the accumulators are not advanced (matches the model's
                // `if new_offs == offs: break`).
                if (jump && jump_to == offs) begin
                    done <= 1'b1; st <= L_IDLE;
                end else begin

                // ---- jump / next offs ----
                next_offs <= jump ? {1'b0, jump_to} : ({1'b0, offs} + 11'd1);

                // ---- palette (unless locked) ----
                if (!lock) color <= w[4][7:0];

                // ---- Axis x ----
                begin
                    logic signed [15:0] np;
                    logic signed [31:0] npos, nbpos;
                    logic [8:0]         nbsc;
                    if (scroll[0]) x_sub  <= {{4{xposw[11]}}, xposw};
                    if (scroll[1]) x_glob <= {{4{xposw[11]}}, xposw};
                    np = axis_np(xposw, (scroll[1] ? {{4{xposw[11]}},xposw} : x_glob),
                                        (scroll[0] ? {{4{xposw[11]}},xposw} : x_sub));
                    nbpos = x_bpos; nbsc = x_bsc; npos = x_pos;
                    case (xbctrl)
                        2'd0: begin
                            if (!multi) begin nbpos = {{8{np[15]}}, np, 8'd0};
                                              nbsc  = 9'd256 - {1'b0, zooms[7:0]}; end
                            npos = nbpos;
                        end
                        2'd2: npos = nbpos;
                        2'd3: npos = x_pos + $signed({23'd0, x_bsc} <<< 4);
                        default: ;
                    endcase
                    x_bpos <= nbpos; x_bsc <= nbsc; x_pos <= npos;
                    bsx <= nbsc;
                    tx  <= flip_eff ? (32'sd131072 - $signed({23'd0, nbsc} <<< 4) - npos) : npos;
                end

                // ---- Axis y ----
                begin
                    logic signed [15:0] np;
                    logic signed [31:0] npos, nbpos;
                    logic [8:0]         nbsc;
                    if (scroll[0]) y_sub  <= {{4{yposw[11]}}, yposw};
                    if (scroll[1]) y_glob <= {{4{yposw[11]}}, yposw};
                    np = axis_np(yposw, (scroll[1] ? {{4{yposw[11]}},yposw} : y_glob),
                                        (scroll[0] ? {{4{yposw[11]}},yposw} : y_sub));
                    nbpos = y_bpos; nbsc = y_bsc; npos = y_pos;
                    case (ybctrl)
                        2'd0: begin
                            if (!multi) begin nbpos = {{8{np[15]}}, np, 8'd0};
                                              nbsc  = 9'd256 - {1'b0, zooms[15:8]}; end
                            npos = nbpos;
                        end
                        2'd2: npos = nbpos;
                        2'd3: npos = y_pos + $signed({23'd0, y_bsc} <<< 4);
                        default: ;
                    endcase
                    y_bpos <= nbpos; y_bsc <= nbsc; y_pos <= npos;
                    bsy <= nbsc;
                    ty  <= flip_eff ? (32'sd65536 - $signed({23'd0, nbsc} <<< 4) - npos) : npos;
                end

                // multi for the NEXT entry
                multi <= scont[3];
                st    <= L_NEXT;
                end
            end

            // emit (if drawable) and advance, or finish
            L_NEXT: begin
                // cull: off-screen or blank tile. fx/fy/flip/color latched in
                // L_PROC's registers are stable here (single entry in flight).
                if (tile != 17'd0 &&
                    !((tx + $signed({23'd0, bsx} <<< 4)) <= X0) && !(tx > X1) &&
                    !((ty + $signed({23'd0, bsy} <<< 4)) <= Y0) && !(ty > Y1)) begin
                    s_valid <= 1'b1;
                    s_tx    <= tx[17:0];
                    s_ty    <= ty[17:0];
                    s_sx    <= bsx;
                    s_sy    <= bsy;
                    s_code  <= tile;
                    s_color <= color;
                    s_fx    <= flip_eff ? ~fx_raw : fx_raw;
                    s_fy    <= flip_eff ? ~fy_raw : fy_raw;
                    s_pri   <= color[7:6];
                end

                total <= total + 11'd1;
                if (next_offs >= 11'd1024 || (total + 11'd1) >= 11'd1024) begin
                    done <= 1'b1; st <= L_IDLE;
                end else begin
                    offs <= next_offs[9:0];
                    rk   <= 4'd0;
                    st   <= L_READ;
                end
            end

            default: st <= L_IDLE;
        endcase
    end

endmodule
