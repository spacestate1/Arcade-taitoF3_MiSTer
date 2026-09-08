//============================================================================
//  Layer mixer -- priority, clipping and the F3 blending circuit.
//
//  Port of scanline_draw / calc_clip / mix_line / render_line from
//  tools/f3_render.py (which is MAME's taito_f3_v.cpp, verified pixel-exact
//  against MAME's own frames). sim/mix_tb.cpp runs this end to end -- real
//  line decode, real playfield build, real SDRAM tile fetch, this mixer --
//  and diffs the output against the MAME-identical frame (make -C sim mix).
//
//  Nine layers take part in every pixel: four playfields, the four sprite
//  priority groups (one sprite sample, claimed by whichever group its colour
//  bits 11:10 name) and the pivot/text layer. Per line they are sorted by
//  priority, descending, with a STABLE sort from the base order
//      pivot, sp0, pf0, sp3, pf3, sp2, pf2, sp1, pf1
//  and processed in that order. The tie order is not academic: Ray Force has
//  equal-priority layers on most lines, and the first of a tie wins the
//  source slot while the rest fall into the destination path as "conflicts".
//
//  The blending circuit keeps two candidates per pixel, a source and a
//  destination, each with a palette index, a contribution (0-8 = 0.0-1.0)
//  and a priority, and every layer either takes the source slot (pushing the
//  old source down only if it was opaque), takes the destination slot, or is
//  discarded. The rules are in mix_line and reproduced here verbatim,
//  including the two that look like bugs: a layer cannot blend against the
//  same blend mode as the current source, and a destination-slot tie
//  produces palette entry 0.
//
//  Shape: a nine-stage pipeline, one layer per stage, cfg[k] being the
//  layer in sorted slot k for this line. A pixel enters every four clocks
//  because that is what the palette read costs afterwards -- two 24-bit
//  entries out of a 16-bit port is four reads -- and the chain is idle
//  three clocks in four, which is fine: ~1300 clocks a line against 3456,
//  running concurrently with the next line's playfield build.
//
//  Clipping: per pixel, per layer, against the four planes with the normal
//  / inverted / inverse-mode bits. This equals MAME's calc_clip for any
//  single plane and for combinations of normal planes. MAME's handling of
//  several INVERTED planes at once produces duplicate ranges that re-run
//  the layer over the same pixels (which changes destination-tie results);
//  that is not reproduced. Ray Force never enables a clip plane at all, so
//  none of this has dump coverage -- stated so nobody mistakes it for
//  verified.
//============================================================================

module rf_video_mix
(
    input  logic        clk,
    input  logic        reset,

    input  logic        line_start,
    output logic        busy,

    // ---- per-line configuration, from rf_video_line, sampled at line_start
    input  logic [3:0][8:0]  clip_l,
    input  logic [3:0][8:0]  clip_r,
    input  logic [3:0][3:0]  blend,
    input  logic [15:0]      bg_palette,
    input  logic [15:0]      pivot_mix,
    input  logic             pivot_bsel,
    input  logic [3:0][15:0] sp_mix,
    input  logic [3:0]       sp_bsel,
    input  logic [3:0][15:0] pf_pal_add,
    input  logic [3:0][15:0] pf_mix,

    // ---- playfield samples (rf_video_pf read side) ----------------------
    output logic        pf_rd_start,
    output logic        pf_rd_step,
    input  logic [3:0][15:0] pf_q,     // {bsel, pal_code[8:0], pen[5:0]}
    input  logic [3:0]       pf_used,

    // ---- sprite and pivot samples ----------------------------------------
    // x_req pulses with x_req_x when a pixel is requested; its samples must
    // be on sp_color / pv_* two clocks later -- the same latency as the
    // playfield buffers. smp_x names the pixel being sampled right now.
    output logic        x_req,
    output logic  [8:0] x_req_x,
    output logic  [8:0] smp_x,
    input  logic [15:0] sp_color,      // sprite line buffer, 0 = none
    input  logic  [3:0] sp_used,       // row usage per priority group
    input  logic [15:0] pv_color,
    input  logic        pv_opaque,
    input  logic        pv_used,

    // ---- palette RAM (B side of the CPU's palette BRAM) -----------------
    output logic [13:0] pal_addr,
    input  logic [15:0] pal_q,

    // 12-BIT PALETTE, per game. Most F3 games store a palette entry as a
    // 32-bit 0RGB read here as two words: word 0's low byte is R, word 1
    // carries G and B. Four sets (Space Invaders DX, Riding Fight, Arabian
    // Magic, Ring Rage) instead pack all three into the LOW word as
    //
    //     .... .... .... ....  RRRR GGGG BBBB ....
    //
    // and MAME scales each nibble by 16 (taito_f3_v.cpp palette_24bit_w),
    // which is exactly {nibble, 4'd0}. MAME selects this by GAME rather than
    // by register -- its own comment there wonders whether the real chip
    // picks it per line through 0x6400, but it does not implement that, so
    // following the per-game flag matches the reference exactly.
    input  logic        pal12,

    // ---- output ------------------------------------------------------------
    output logic        out_valid,
    output logic  [8:0] out_x,
    output logic [23:0] out_rgb,

    // the screen line being composed -- only the pixel probe below wants it,
    // the mixer itself works one line at a time and never needs to know which
    input  logic  [7:0] line_y,

    // ---- DIAGNOSTIC: what the mixer USED on a wrong pixel ----------------
    // Darius Gaiden's big Zone A tower sprites come out red. Everything
    // upstream has been cleared by measurement: the sprite list is exact,
    // the draw finishes, and the sprite framebuffer hands this region of the
    // screen back byte-for-byte as it was written -- so the palette INDEX
    // arriving here is right and the RGB leaving is not.
    //
    // The wrong pixels have a signature: G and B both come out 0x03, which
    // is this game's black and, not coincidentally, the GGBB word of palette
    // entry 0. The red channel meanwhile still varies with the tower's
    // shading. This latches the mixer's own inputs for such a pixel:
    //
    //   {x[8:0], y[7:0], src_pal[12:0], src_blend==8, dst_blend==0}
    //
    // The COORDINATE is the point: an earlier packing reported the output
    // green/blue instead, and a reading could not be pinned to a pixel, so
    // it could not be compared against MAME. With (x,y) the board's own
    // screenshot supplies the output colour and a MAME dump supplies the
    // correct index and colour for the same pixel. One reading then splits
    // three ways: src_pal matches MAME's and the pixel is opaque but wrong
    // -> the palette read; src_pal differs -> the pen/graphics upstream;
    // not opaque -> the blend weights from the line-RAM decode. The two
    // flag bits compress the weights to the only question that matters
    // here, since MAME renders this scene 100 % opaque.
    output logic [31:0] dbg_pix
);

    localparam int H_START = 46;
    localparam int NL = 9;

    // kinds: 0-3 playfield, 4-7 sprite group, 8 pivot
    localparam logic [3:0] K_PF0 = 4'd0, K_SP0 = 4'd4, K_PV = 4'd8;

    // ---- per-line configuration ------------------------------------------
    logic [3:0]  c_kind  [0:NL-1];
    logic [3:0]  c_prio  [0:NL-1];
    logic [1:0]  c_bm    [0:NL-1];
    logic        c_en    [0:NL-1];
    logic        c_bsel  [0:NL-1];
    logic [15:0] c_padd  [0:NL-1];
    logic [3:0]  c_cnorm [0:NL-1];     // planes applied as "inside"
    logic [3:0]  c_cinv  [0:NL-1];     // planes applied as "outside"
    logic [3:0][3:0]  l_blend;
    logic [15:0]      l_bg;
    logic signed [10:0] l_cl [0:3];    // clip_l - 1
    logic signed [10:0] l_cr [0:3];    // clip_r - 2
    logic             l_cok [0:3];     // cl <= cr

    // base order and the stable sort by priority
    localparam logic [3:0] BASE_KIND [0:8] = '{4'd8, 4'd4, 4'd0, 4'd7, 4'd3, 4'd6, 4'd2, 4'd5, 4'd1};

    logic [15:0] b_mix  [0:NL-1];
    logic [3:0]  b_prio [0:NL-1];
    logic        b_en   [0:NL-1];
    logic        b_bsel [0:NL-1];
    logic [15:0] b_padd [0:NL-1];
    logic [3:0]  b_rank [0:NL-1];
    logic [3:0]  k;                    // loop scratch, kept at module scope:
                                       // Quartus 17 rejects declarations
                                       // inside unnamed blocks

    always_comb begin
        for (int i = 0; i < NL; i = i + 1) begin
            k = BASE_KIND[i];
            if (k < 4)       b_mix[i] = pf_mix[k[1:0]];
            else if (k < 8)  b_mix[i] = sp_mix[k[1:0]];
            else             b_mix[i] = pivot_mix;
            b_prio[i] = b_mix[i][3:0];
            // layer_enable: bit 13, and the blend mode that means "off"
            // differs -- 3 for tilemaps and the pivot, 0 for sprites -- then
            // MAME's row-usage test on top
            if (k < 4)       b_en[i] = b_mix[i][13] && (b_mix[i][15:14] != 2'b11) && pf_used[k[1:0]];
            else if (k < 8)  b_en[i] = b_mix[i][13] && (b_mix[i][15:14] != 2'b00) && sp_used[k[1:0]];
            else             b_en[i] = b_mix[i][13] && (b_mix[i][15:14] != 2'b11) && pv_used;
            b_bsel[i] = (k < 4) ? 1'b0 : (k < 8) ? sp_bsel[k[1:0]] : pivot_bsel;
            b_padd[i] = (k < 4) ? pf_pal_add[k[1:0]] : 16'd0;
        end
        // rank = layers strictly above me + earlier layers equal to me
        for (int i = 0; i < NL; i = i + 1) begin
            b_rank[i] = 4'd0;
            for (int j = 0; j < NL; j = j + 1)
                if ((b_prio[j] > b_prio[i]) || (j < i && b_prio[j] == b_prio[i]))
                    b_rank[i] = b_rank[i] + 4'd1;
        end
    end

    // ---- pixel pipeline --------------------------------------------------
    // state carried through the nine stages
    typedef struct packed {
        logic [15:0] src_pal;
        logic [15:0] dst_pal;
        logic  [3:0] src_blend;
        logic  [3:0] dst_blend;
        logic  [3:0] src_prio;
        logic  [3:0] dst_prio;
        logic  [2:0] src_bm;           // 3'b1xx = no source yet (MAME's 0xff)
    } mst_t;

    typedef struct packed {
        logic [3:0][15:0] pf;
        logic [15:0] sp;
        logic [15:0] pv;
        logic        pv_op;
        logic  [8:0] x;
    } mdat_t;

    logic  v   [0:NL];
    mst_t  st  [0:NL];
    mdat_t dat [0:NL];

    // stage k: layer cfg[k] applied to the pixel in slot k
    genvar g;
    generate
        for (g = 0; g < NL; g = g + 1) begin : g_stage
            // sample for this layer
            logic [15:0] color, pal;
            logic        active, opaque, sel;
            logic [3:0]  kind;
            logic [1:0]  bm;
            logic        vis;
            logic signed [10:0] ax;
            logic [15:0] q;                // playfield sample scratch
            mst_t s, n;

            always_comb begin
                kind = c_kind[g];
                bm   = c_bm[g];
                s    = st[g];
                ax   = 11'(signed'({2'b00, dat[g].x})) + 11'sd46;

                // clip planes
                vis = 1'b1;
                for (int i = 0; i < 4; i = i + 1) begin
                    if (c_cnorm[g][i])
                        vis = vis & l_cok[i] & (ax >= l_cl[i]) & (ax < l_cr[i]);
                    else if (c_cinv[g][i] && l_cok[i])
                        vis = vis & ((ax < l_cl[i]) | (ax >= l_cr[i]));
                end

                // the sample, by layer kind
                q = dat[g].pf[kind[1:0]];
                if (kind < 4) begin
                    color  = {3'b000, q[14:6], 4'b0000} | {10'd0, q[5:0]};
                    opaque = (q[5:0] != 6'd0);        // tilemap flags & 0xf0
                    active = 1'b1;
                    sel    = q[15];
                    pal    = color + c_padd[g];
                end else if (kind < 8) begin
                    color  = dat[g].sp;
                    opaque = 1'b1;
                    active = (color[11:10] == kind[1:0]); // sprite group
                    sel    = c_bsel[g];
                    pal    = color;
                end else begin
                    color  = dat[g].pv;
                    opaque = dat[g].pv_op;
                    active = 1'b1;
                    sel    = c_bsel[g];
                    pal    = color;
                end

                // ---- mix_line, one layer ----
                n = s;
                if (c_en[g] && vis && !(s.src_bm == {1'b0, bm}) && active && opaque
                    && color != 16'd0) begin
                    if (c_prio[g] > s.src_prio) begin
                        case (bm)
                        2'b01: begin                       // normal blend
                            if (l_blend[{1'b1, sel}] != 4'd0) begin
                                n.src_blend = l_blend[{1'b1, sel}];
                                n.src_pal   = pal;
                                n.src_bm    = {1'b0, bm};
                                n.src_prio  = c_prio[g];
                            end
                        end
                        2'b10: begin                       // reverse blend
                            if (l_blend[{1'b0, sel}] != 4'd0) begin
                                n.src_blend = l_blend[{1'b0, sel}];
                                n.src_pal   = pal;
                                n.src_bm    = {1'b0, bm};
                                n.src_prio  = c_prio[g];
                            end
                        end
                        default: begin                     // opaque
                            if ((l_blend[{1'b0, sel}] + l_blend[{1'b1, sel}]) != 5'd0) begin
                                n.src_blend = l_blend[{1'b1, sel}];
                                n.dst_blend = l_blend[{1'b0, sel}];
                                n.dst_prio  = c_prio[g];
                                n.dst_pal   = pal;
                                n.src_pal   = pal;
                                n.src_bm    = {1'b0, bm};
                                n.src_prio  = c_prio[g];
                            end
                        end
                        endcase
                    end else if (c_prio[g] >= s.dst_prio) begin
                        // destination slot; a priority tie is a colour-line
                        // conflict on the real chip and yields entry 0
                        n.dst_pal   = (c_prio[g] != s.dst_prio) ? pal : 16'd0;
                        n.dst_prio  = c_prio[g];
                        n.dst_blend = (s.src_bm == 3'b001) ? l_blend[{1'b0, sel}]
                                                           : l_blend[{1'b1, sel}];
                    end
                end
            end

            always_ff @(posedge clk) begin
                v[g + 1]   <= v[g];
                st[g + 1]  <= n;
                dat[g + 1] <= dat[g];
            end
        end
    endgenerate

    // ---- sequencing ------------------------------------------------------
    typedef enum logic [2:0] { S_IDLE, S_RDS, S_CFG, S_RUN, S_DRAIN } st_t;
    st_t   seq;
    logic [8:0] px;
    logic [1:0] ph;
    logic [4:0] drain;

    assign busy    = (seq != S_IDLE);
    assign smp_x   = px;
    assign x_req_x = px;

    always_ff @(posedge clk) begin
        pf_rd_start <= 1'b0;
        pf_rd_step  <= 1'b0;
        x_req       <= 1'b0;
        v[0]        <= 1'b0;

        if (reset) begin
            seq <= S_IDLE;
        end else case (seq)
            S_IDLE: if (line_start) begin
                pf_rd_start <= 1'b1;               // bank swap, x = 0
                seq <= S_RDS;
            end

            // rd_start is seen by rf_video_pf this clock; rd_used is valid next
            S_RDS: seq <= S_CFG;

            // latch the line configuration in sorted order
            S_CFG: begin
                for (int i = 0; i < NL; i = i + 1)
                    for (int j = 0; j < NL; j = j + 1)
                        if (b_rank[j] == 4'(i)) begin
                            c_kind[i]  <= BASE_KIND[j];
                            c_prio[i]  <= b_prio[j];
                            c_bm[i]    <= b_mix[j][15:14];
                            c_en[i]    <= b_en[j];
                            c_bsel[i]  <= b_bsel[j];
                            c_padd[i]  <= b_padd[j];
                            // inverse mode bit 12 decides which set is which
                            c_cnorm[i] <= b_mix[j][12] ? (b_mix[j][11:8] & ~b_mix[j][7:4])
                                                       : (b_mix[j][11:8] &  b_mix[j][7:4]);
                            c_cinv[i]  <= b_mix[j][12] ? (b_mix[j][11:8] &  b_mix[j][7:4])
                                                       : (b_mix[j][11:8] & ~b_mix[j][7:4]);
                        end
                l_blend <= blend;
                l_bg    <= bg_palette;
                for (int i = 0; i < 4; i = i + 1) begin
                    l_cl[i]  <= 11'(signed'({2'b00, clip_l[i]})) - 11'sd1;
                    l_cr[i]  <= 11'(signed'({2'b00, clip_r[i]})) - 11'sd2;
                    l_cok[i] <= (11'(signed'({2'b00, clip_l[i]})) - 11'sd1)
                             <= (11'(signed'({2'b00, clip_r[i]})) - 11'sd2);
                end
                px  <= 9'd0;
                ph  <= 2'd0;
                seq <= S_RUN;
            end

            // four clocks per pixel: request at phase 0, samples land two
            // clocks later, capture at the end of phase 3
            S_RUN: begin
                ph <= ph + 2'd1;
                if (ph == 2'd0 && px != 9'd0) begin
                    pf_rd_step <= 1'b1;
                    x_req      <= 1'b1;
                end
                if (ph == 2'd3) begin
                    v[0]   <= 1'b1;
                    // packed structs loaded by concatenation in declaration
                    // order (named assignment patterns are another Quartus
                    // 17 hazard): {pf, sp, pv, pv_op, x} and
                    // {src_pal, dst_pal, src_blend, dst_blend, src_prio,
                    //  dst_prio, src_bm}
                    dat[0] <= {pf_q, sp_color, pv_color, pv_opaque, px};
                    st[0]  <= {16'd0, l_bg, 4'd0, 4'd8, 4'd0, 4'd0, 3'b111};
                    if (px == 9'd319) begin
                        drain <= 5'd24;
                        seq   <= S_DRAIN;
                    end else
                        px <= px + 9'd1;
                end
            end

            S_DRAIN: begin
                drain <= drain - 5'd1;
                if (drain == 5'd0) seq <= S_IDLE;
            end

            default: seq <= S_IDLE;
        endcase
    end

    // ---- palette lookup and the blend arithmetic ------------------------
    // Entry e is two 16-bit words: {e,0} = 00RR, {e,1} = GGBB. Four reads
    // per pixel, one per clock, data one clock behind the address.
    logic [15:0] p_src, p_dst;
    logic  [3:0] p_sb, p_db, q_sb, q_db;
    logic [15:0] q_src;                 // DIAGNOSTIC copies, see dbg_pix
    logic  [7:0] q_y;
    logic  [8:0] p_x, q_x;
    logic        v9_1, v9_2, v9_3, v9_4, v9_5, v9_6;
    logic  [7:0] sr, sg, sb, dr, dg, db;
    // Addresses go out on clocks 1-4 after v9 (registered, so presented on
    // 1-4), the RAM registers each and answers the clock after, so the four
    // words are sampled on clocks 2-5 and the blend runs on 6. Pixels arrive
    // every four clocks, so p_* is overwritten by the next pixel on clock 4:
    // the q_* copies taken on that same edge carry this pixel's weights and
    // x tag through to clock 6.

    wire v9 = v[NL];

    always_ff @(posedge clk) begin
        v9_1 <= v9; v9_2 <= v9_1; v9_3 <= v9_2; v9_4 <= v9_3; v9_5 <= v9_4; v9_6 <= v9_5;

        if (v9) begin
            p_src <= st[NL].src_pal;
            p_dst <= st[NL].dst_pal;
            p_sb  <= st[NL].src_blend;
            p_db  <= st[NL].dst_blend;
            p_x   <= dat[NL].x;
        end

        if      (v9)   pal_addr <= {st[NL].src_pal[12:0], 1'b0};
        else if (v9_1) pal_addr <= {p_src[12:0], 1'b1};
        else if (v9_2) pal_addr <= {p_dst[12:0], 1'b0};
        else if (v9_3) pal_addr <= {p_dst[12:0], 1'b1};

        if (v9_2) sr <= pal_q[7:0];
        // In 12-bit mode all three components live in THIS word, so the
        // R written at v9_2 is overwritten here a cycle later. Writing it
        // twice rather than muxing v9_2 keeps the 24-bit path untouched.
        if (v9_3) begin
            if (pal12) begin
                sr <= {pal_q[15:12], 4'd0};
                sg <= {pal_q[11:8],  4'd0};
                sb <= {pal_q[7:4],   4'd0};
            end else begin
                sg <= pal_q[15:8]; sb <= pal_q[7:0];
            end
        end
        if (v9_4) begin dr <= pal_q[7:0]; q_sb <= p_sb; q_db <= p_db; q_x <= p_x;
                        q_src <= p_src; q_y <= line_y; end
        if (v9_5) begin
            if (pal12) begin
                dr <= {pal_q[15:12], 4'd0};
                dg <= {pal_q[11:8],  4'd0};
                db <= {pal_q[7:4],   4'd0};
            end else begin
                dg <= pal_q[15:8]; db <= pal_q[7:0];
            end
        end
    end

    // source * src_blend + dest * dst_blend, fixed 3-bit contributions
    // (8 = 1.0), then >> 3 and saturate -- render_line
    function automatic logic [7:0] chan(input logic [7:0] s, input logic [3:0] sw,
                                        input logic [7:0] d, input logic [3:0] dw);
        logic [12:0] acc;
        acc  = ({5'd0, s} * {9'd0, sw}) + ({5'd0, d} * {9'd0, dw});
        acc  = acc >> 3;
        chan = (acc > 13'd255) ? 8'hFF : acc[7:0];
    endfunction

    wire [7:0] o_r = chan(sr, q_sb, dr, q_db);
    wire [7:0] o_g = chan(sg, q_sb, dg, q_db);
    wire [7:0] o_b = chan(sb, q_sb, db, q_db);

    always_ff @(posedge clk) begin
        out_valid <= v9_6;
        if (v9_6) begin
            out_x   <= q_x;
            out_rgb <= {o_r, o_g, o_b};
            // DIAGNOSTIC: a sprite-sourced pixel (sprite palette is 0x1000
            // and up) whose green and blue have both collapsed to 0x03.
            if (q_src[12])
                dbg_pix <= {q_x, q_y, q_src[12:0], (q_sb == 4'd8), (q_db == 4'd0)};
        end
    end

endmodule
