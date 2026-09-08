//============================================================================
//  Bench for rf_spr_gfx_bus -- SPRITE tile fetch out of SDRAM.
//
//  Two clock domains, a behavioural SDRAM serving the real gfx regions at
//  their map offsets, and every fetched tile row written out for comparison
//  against tools/f3_gfx.py by sim/check_gfx.py.
//
//  Why compare against f3_gfx.py rather than against hand-worked expected
//  values: that decoder is what makes tools/f3_render.py reproduce MAME's
//  frames pixel-exact, so it is the authority on this byte order. Tile gfx
//  byte order has already cost this project one afternoon once (the character
//  generator, see HANDOFF.md), and reasoning about it a second time was not
//  going to be more reliable than checking it.
//
//  Requires the gfx region dumps:
//      F3DUMP_REGIONS=1 F3DUMP_FRAMES=1 F3DUMP_DIR=dump mame rayforce ...
//  See "How to run the video oracle" in HANDOFF.md.
//============================================================================
#include "Vrf_spr_gfx_bus.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static std::vector<uint8_t> mem;

static std::vector<uint8_t> load(const char* p) {
    FILE* f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) exit(2);
    fclose(f);
    return v;
}

// The download loader stores every non-maincpu region RAW, and ioctl_dout[7:0]
// is the even byte of the MRA stream (proven by the download checksum), so a
// region byte n lands in SDRAM word n>>1 at bits [8*(n&1) +: 8].
static uint16_t rd16(uint32_t wordaddr) {
    uint32_t b = wordaddr * 2;
    if (b + 1 >= mem.size()) return 0;
    return mem[b] | (mem[b + 1] << 8);
}

// One controller channel: level request, edge-detected, N cycles later a
// one-cycle ready with the four-word burst. Latencies are arbitrary and
// deliberately different per channel -- the point is to exercise the CDC and
// the "wait for both" join, not to model SDRAM timing.
struct Chan {
    int prev = 0, delay = -1, ready = 0;
    uint32_t addr = 0;
    uint64_t dout = 0;
    void tick(int req, uint32_t a, int latency) {
        ready = 0;
        if (req && !prev) { delay = latency; addr = a; }
        prev = req;
        if (delay > 0) delay--;
        else if (delay == 0) {
            delay = -1;
            uint64_t d = 0;
            for (int k = 0; k < 4; k++) d |= (uint64_t)rd16(addr + k) << (16 * k);
            dout = d;
            ready = 1;
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* dir = argc > 1 ? argv[1] : "dump";
    const char* outp = argc > 2 ? argv[2] : "fetched.txt";

    mem.assign(0x1280000, 0);
    struct { const char* n; uint32_t off; } regs[] = {
        {"rgn_sprites.bin",    0x280000}, {"rgn_sprites_hi.bin", 0x680000},
        {"rgn_tilemap.bin",    0x880000}, {"rgn_tilemap_hi.bin", 0xC80000}};
    char p[512];
    for (auto& r : regs) {
        snprintf(p, sizeof p, "%s/%s", dir, r.n);
        auto v = load(p);
        memcpy(&mem[r.off], v.data(), v.size());
    }

    Vrf_spr_gfx_bus* t = new Vrf_spr_gfx_bus;
    // SDRAM map profile 0 -- see gfx_tb.cpp
    t->base_lo = 0x140000;   // sprites    byte 0x280000
    t->base_hi = 0x340000;   // sprites_hi byte 0x680000
    Chan lo, hi;

    struct Case { int code, row; };
    std::vector<Case> cases;
    for (int c = 0; c < 24; c++)
        for (int r = 0; r < 16; r++) cases.push_back({0x200 + c, r});
    for (int c = 0; c < 200; c++)
        cases.push_back({(c * 7919) & 0x3FFF, (c * 5) & 15});

    FILE* out = fopen(outp, "w");
    t->reset = 1;
    t->req = 0;

    size_t idx = 0;
    int state = 0;
    long long cyc = 0, issued_at = 0, tot_lat = 0, worst = 0;

    while (idx < cases.size() && cyc < 4000000) {
        cyc++;
        // cpu edge every other tick; the ram clock skips one tick in eleven so
        // the two domains stay incommensurate rather than locking to 2:1
        const int cpu_edge = (cyc % 2) == 0;
        const int ram_edge = (cyc % 11) != 0;

        if (ram_edge) {
            lo.tick(t->ch_lo_req, t->ch_lo_addr, 14);
            hi.tick(t->ch_hi_req, t->ch_hi_addr, 9);
            t->ch_lo_dout = lo.dout; t->ch_lo_ready = lo.ready;
            t->ch_hi_dout = hi.dout; t->ch_hi_ready = hi.ready;
            t->clk_ram = 1; t->eval();
            t->clk_ram = 0; t->eval();
        }
        if (cpu_edge) {
            if (cyc > 200) t->reset = 0;
            if (state == 0 && !t->reset) {
                t->code = cases[idx].code;
                t->row  = cases[idx].row;
                t->req  = 1;
                issued_at = cyc;
                state = 1;
            } else if (state == 1) {
                t->req = 0;
                state = 2;
            }
            t->clk_cpu = 1; t->eval();
            t->clk_cpu = 0; t->eval();

            if (state == 2 && t->valid) {
                long long lat = (cyc - issued_at) / 2;
                tot_lat += lat;
                if (lat > worst) worst = lat;
                fprintf(out, "%d %d", cases[idx].code, cases[idx].row);
                for (int k = 0; k < 16; k++) {
                    // 96 bits arrive as three uint32; a 6-bit field straddles
                    // the word boundary from k=5 on, so read a 64-bit window
                    unsigned bit = 6u * k, w = bit / 32, sh = bit % 32;
                    uint64_t win = (uint64_t)t->pix[w];
                    if (w + 1 < 3) win |= (uint64_t)t->pix[w + 1] << 32;
                    fprintf(out, " %u", (unsigned)((win >> sh) & 0x3F));
                }
                fprintf(out, "\n");
                idx++;
                state = 0;
            }
        }
    }
    fclose(out);
    printf("fetched %zu/%zu tile rows, mean latency %lld cpu clk, worst %lld\n",
           idx, cases.size(), idx ? tot_lat / (long long)idx : 0, worst);
    return idx == cases.size() ? 0 : 1;
}
