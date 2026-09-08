//============================================================================
//  Bench for rf_video_spr -- the per-line sprite builder vs the model's fb.
//
//  Loads frame F-2's sprite RAM and the sprite gfx regions, runs the prepass
//  (walk + expand), then builds each screen line and compares its line buffer
//  and row-usage against the model's framebuffer (sim/gen_spr_fb_ref.py).
//
//    ./obj_dir/sprlinetb <dump_dir> <frame> <ref> [frame2] [ref2]
//
//  With frame2/ref2 it then swaps in THAT frame's sprite RAM and checks the
//  same way. That is the ghost regression: the line buffer is never cleared,
//  so a frame whose sprites moved or went away must not show the previous
//  frame's pixels. Run it with a busy frame followed by a near-empty one.
//============================================================================
#include "Vrf_video_spr.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

static std::vector<uint8_t> mem;                 // flat gfx map (byte)
static std::vector<uint16_t> sram;               // sprite RAM (be16)

static std::vector<uint8_t> load(const std::string& p) {
    FILE* f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) exit(2);
    fclose(f);
    return v;
}
static uint16_t rd16(uint32_t wa) {
    uint32_t b = wa * 2;
    return (b + 1 < mem.size()) ? (mem[b] | (mem[b + 1] << 8)) : 0;
}
struct Chan {
    int prev = 0, delay = -1, ready = 0; uint32_t addr = 0; uint64_t dout = 0;
    void tick(int req, uint32_t a, int lat) {
        ready = 0;
        if (req && !prev) { delay = lat; addr = a; }
        prev = req;
        if (delay > 0) delay--;
        else if (delay == 0) {
            delay = -1; uint64_t d = 0;
            for (int k = 0; k < 4; k++) d |= (uint64_t)rd16(addr + k) << (16 * k);
            dout = d; ready = 1;
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string dir = argc > 1 ? argv[1] : "../dump";
    int frame = argc > 2 ? atoi(argv[2]) : 1800;
    const char* refp = argc > 3 ? argv[3] : "spr_fb_ref.txt";

    char pre[64]; snprintf(pre, sizeof pre, "/f3_%05d_spriteram.bin", frame - 2);
    { auto b = load(dir + pre); sram.resize(b.size() / 2);
      for (size_t i = 0; i < sram.size(); i++) sram[i] = (b[2 * i] << 8) | b[2 * i + 1]; }

    mem.assign(0x1280000, 0);
    struct { const char* n; uint32_t off; } regs[] = {
        {"rgn_sprites.bin", 0x280000}, {"rgn_sprites_hi.bin", 0x680000}};
    for (auto& r : regs) { auto v = load(dir + "/" + r.n); memcpy(&mem[r.off], v.data(), v.size()); }

    // reference: fb[sy][46..365] and per-line usage
    std::vector<std::vector<int>> fb(256);
    std::vector<int> used(256, 0);
    { FILE* f = fopen(refp, "r"); if (!f) { fprintf(stderr, "cannot open %s\n", refp); return 2; }
      char* ln = nullptr; size_t cap = 0;
      while (getline(&ln, &cap, f) > 0) {
          if (ln[0] == '#') continue;
          std::istringstream ss(ln); std::string tag; int sy, u;
          ss >> tag >> sy >> u; used[sy] = u; int v;
          while (ss >> v) fb[sy].push_back(v);
      }
      free(ln); fclose(f); }

    Vrf_video_spr* t = new Vrf_video_spr;
    Chan alo, ahi, blo, bhi;             // two fetch buses x two planes
    uint32_t ra_spr = 0;
    long long cyc = 0;

    auto step = [&]() {
        // two ram half-cycles, one skipped in eleven (incommensurate domains)
        for (int r = 0; r < 2; r++) {
            if ((cyc * 2 + r) % 11 == 0) continue;
            alo.tick(t->ch_a_lo_req, t->ch_a_lo_addr, 14);
            ahi.tick(t->ch_a_hi_req, t->ch_a_hi_addr, 9);
            blo.tick(t->ch_b_lo_req, t->ch_b_lo_addr, 14);
            bhi.tick(t->ch_b_hi_req, t->ch_b_hi_addr, 9);
            t->ch_a_lo_dout = alo.dout; t->ch_a_lo_ready = alo.ready;
            t->ch_a_hi_dout = ahi.dout; t->ch_a_hi_ready = ahi.ready;
            t->ch_b_lo_dout = blo.dout; t->ch_b_lo_ready = blo.ready;
            t->ch_b_hi_dout = bhi.dout; t->ch_b_hi_ready = bhi.ready;
            t->clk_ram = 1; t->eval(); t->clk_ram = 0; t->eval();
        }
        t->spr_q = ra_spr < sram.size() ? sram[ra_spr] : 0;
        uint32_t na = t->spr_addr;
        t->clk = 1; t->eval();
        ra_spr = na;
        t->clk = 0; t->eval();
        cyc++;
    };

    // F3 visarea, same encoding as rf_video_spr_list: 0 f3_224a (Ray
    // Force), 3 f3 (Elevator Action Returns). The cull bounds follow it.
    t->vis_mode = getenv("F3_VISMODE") ? atoi(getenv("F3_VISMODE")) : 0;
    // SDRAM map profile 0 -- the layout every dumped reference was made with.
    // These are PORTS since the core gained a second map profile; leaving them
    // at their default 0 makes every sprite fetch read address 0 and draw
    // nothing, which is exactly how this bench started failing.
    t->gfx_base_lo = 0x140000;   // sprites    byte 0x280000
    t->gfx_base_hi = 0x340000;   // sprites_hi byte 0x680000
    t->reset = 1; t->frame_start = 0;
    t->fb_addr = 0; t->rd_line = 0;
    // Parked from the start. The draw is no longer chased by the mixer, so
    // left free it publishes line 0 within a few hundred cycles and is two
    // hundred lines further on before check() starts looking -- the bench has
    // to OWN the handover, not observe it.
    t->fb_busy = 1;
    for (int i = 0; i < 6; i++) step();
    t->reset = 0;

    // prepass. The bucket store is double banked: frame_start publishes the
    // bank just built to the draw side and starts a fresh prepass, so with
    // static sprite RAM two cycles are needed before the read bank is filled.
    for (int c = 0; c < 2; c++) {
        t->frame_start = 1; step(); t->frame_start = 0;
        long g = 0; while (t->prepass_busy && g++ < 20000000) step();
        for (int i = 0; i < 4; i++) step();
    }

    int bad = 0, ubad = 0, shown = 0;
    auto load_ref = [&](const char* path) {
        for (auto& v : fb) v.clear();
        std::fill(used.begin(), used.end(), 0);
        FILE* f = fopen(path, "r"); if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
        char* ln = nullptr; size_t cap = 0;
        while (getline(&ln, &cap, f) > 0) {
            if (ln[0] == '#') continue;
            std::istringstream ss(ln); std::string tag; int sy, u;
            ss >> tag >> sy >> u; used[sy] = u; int v;
            while (ss >> v) fb[sy].push_back(v);
        }
        free(ln); fclose(f);
    };
    auto check = [&](int fno) {
    for (int sy = 0; sy < 256; sy++) {
        // The draw is no longer chased by the mixer -- it fills one of two
        // banks and PUBLISHES each finished line on fb_req, which is what
        // rf_spr_fb streams to DDR3. So catch the line as it is handed over
        // rather than reading a ring that no longer holds it: raising fb_busy
        // the moment fb_req fires parks the draw at the NEXT handover, which
        // is exactly what stops dbank flipping and keeps this line's bank
        // readable on fb_addr/fb_q. That makes this bench a test of the
        // handover protocol as well as of the pixels.
        // release the handover for exactly one line, then park again
        t->fb_busy = 0;
        long gl = 0;
        // step FIRST: fb_req is a one-cycle pulse and the previous line's may
        // still be asserted on the cycle this loop is entered, which would
        // exit immediately and read the previous line's number
        do { step(); } while (!t->fb_req && gl++ < 4000000);
        t->fb_busy = 1;
        if (t->fb_line != sy) { printf("  line out of order: got %d want %d\n",
                                       (int)t->fb_line, sy); bad++; }
        for (int i = 0; i < 2; i++) step();

        // read the line buffer for the line just published
        std::vector<int> got(320, 0);
        for (int x = 0; x < 320; x++) {
            t->fb_addr = x; step();            // present address
            step();                            // data valid next cycle
            got[x] = t->fb_q & 0x1FFF;
        }
        t->fb_busy = 0;
        if ((int)fb[sy].size() == 320) {
            for (int x = 0; x < 320; x++) if (got[x] != fb[sy][x]) {
                bad++;
                if (shown++ < 10)
                    printf("  sy=%d x=%d rtl=%04x ref=%04x\n", sy, x + 46, got[x], fb[sy][x]);
            }
        }
        if ((t->fb_used & 0xF) != (used[sy] & 0xF)) {
            ubad++;
            if (ubad <= 6) printf("  sy=%d used rtl=%x ref=%x\n", sy, t->fb_used & 0xF, used[sy] & 0xF);
        }
    }
    printf("frame %d: %d pixel diffs, %d used-flag diffs (%lld cyc)\n", fno, bad, ubad, cyc);
    };
    check(frame);

    // ---- second frame: the ghost regression -----------------------------
    if (argc > 5) {
        int frame2 = atoi(argv[4]);
        char pre2[64]; snprintf(pre2, sizeof pre2, "/f3_%05d_spriteram.bin", frame2 - 2);
        { auto b = load(dir + pre2); sram.assign(b.size() / 2, 0);
          for (size_t i = 0; i < sram.size(); i++) sram[i] = (b[2 * i] << 8) | b[2 * i + 1]; }
        load_ref(argv[5]);
        // two prepass cycles: the first builds the new list into the write
        // bank (the draw still has the old one), the second publishes it
        t->rd_line = 0;
        for (int c = 0; c < 2; c++) {
            t->frame_start = 1; step(); t->frame_start = 0;
            long g = 0; while (t->prepass_busy && g++ < 20000000) step();
            // Let the draw free-run through the frame: check() leaves the
            // handover PARKED (fb_busy high) after its last line, so leaving
            // it parked here stalls the draw at line 0 and lines_done never
            // moves -- the catch-up below would spin out its guard and the
            // next check() would then see no handover at all.
            t->fb_busy = 0;
            long gd = 0; while (t->lines_done < 256 && gd++ < 20000000) step();
            t->fb_busy = 1;
            t->rd_line = 0;
            for (int i = 0; i < 4; i++) step();
        }
        // Those runs drew the whole frame -- which is the point, the ghost
        // test needs the new frame laid over the old one -- but they also
        // leave nxt at 256 with nothing left to publish. check() walks
        // handovers, so start ONE more frame with the handover already parked:
        // the draw then fills line 0, stops at D_DONE, and waits for check().
        t->frame_start = 1; step(); t->frame_start = 0;
        { long g = 0; while (t->prepass_busy && g++ < 20000000) step(); }
        for (int i = 0; i < 4; i++) step();
        int before = bad;
        check(frame2);
        if (bad > before)
            printf("  (frame %d after frame %d: %d wrong pixels -- stale sprite pixels from the\n"
                   "   previous frame, i.e. the line buffer's tag does not distinguish frames)\n",
                   frame2, frame, bad - before);
    }
    if (!bad && !ubad) printf("SPRITE LINES OK\n");
    delete t;
    return (bad || ubad) ? 1 : 0;
}
