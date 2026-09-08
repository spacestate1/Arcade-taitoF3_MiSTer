//============================================================================
//  End-to-end bench: line decode + playfield build + SDRAM tile fetch +
//  mixer, against the MAME-identical frame. Sprite and pivot samples come
//  from sim/gen_mix_ref.py (the model) until those layers have RTL.
//
//    ./obj_dir/mixtb <dump_dir> <frame> <ref> <out>
//============================================================================
#include "Vmix_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

static std::vector<uint8_t> mem;
static std::vector<uint16_t> lram, pram, palram;

static std::vector<uint8_t> load(const std::string& p) {
    FILE* f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) exit(2);
    fclose(f);
    return v;
}
static std::vector<uint16_t> be16(const std::vector<uint8_t>& b) {
    std::vector<uint16_t> v(b.size() / 2);
    for (size_t i = 0; i < v.size(); i++) v[i] = (b[2 * i] << 8) | b[2 * i + 1];
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

struct RefLine { int pv_used = 0, sp_used = 0; std::vector<int> pv, sp; std::vector<uint32_t> rgb; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string dir = argc > 1 ? argv[1] : "../dump";
    int frame = argc > 2 ? atoi(argv[2]) : 1800;
    const char* refp = argc > 3 ? argv[3] : "mix_ref.txt";
    const char* outp = argc > 4 ? argv[4] : "mix_out.txt";

    char pre[64]; snprintf(pre, sizeof pre, "/f3_%05d_", frame);
    mem.assign(0x1280000, 0);
    struct { const char* n; uint32_t off; } regs[] = {
        {"rgn_tilemap.bin", 0x880000}, {"rgn_tilemap_hi.bin", 0xC80000}};
    for (auto& r : regs) { auto v = load(dir + "/" + r.n); memcpy(&mem[r.off], v.data(), v.size()); }
    lram   = be16(load(dir + pre + "line_ram.bin"));
    pram   = be16(load(dir + pre + "pf_ram.bin"));
    palram = be16(load(dir + pre + "paletteram.bin"));

    uint16_t ctrl[16] = {0};
    { FILE* f = fopen((dir + pre + "ctrl.txt").c_str(), "r");
      int i; unsigned v; while (f && fscanf(f, "%d %x", &i, &v) == 2) ctrl[i] = v; if (f) fclose(f); }

    // reference: sprite / pivot samples and expected rgb per line
    std::vector<RefLine> ref(256);
    {
        FILE* f = fopen(refp, "r");
        if (!f) { fprintf(stderr, "cannot open %s\n", refp); return 2; }
        char* buf = nullptr; size_t cap = 0; int cur = -1;
        while (getline(&buf, &cap, f) > 0) {
            std::istringstream ss(buf);
            std::string tag; ss >> tag;
            if (tag == "L") { ss >> cur >> ref[cur].pv_used >> ref[cur].sp_used; }
            else if (tag == "PV") { int v; while (ss >> v) ref[cur].pv.push_back(v); }
            else if (tag == "SP") { int v; while (ss >> v) ref[cur].sp.push_back(v); }
            else if (tag == "RGB") { std::string h; while (ss >> h) ref[cur].rgb.push_back(strtoul(h.c_str(), 0, 16)); }
        }
        free(buf); fclose(f);
    }

    Vmix_top* t = new Vmix_top;
    Chan lo, hi;
    uint32_t ra_l = 0, ra_p = 0, ra_c = 0;
    long long cyc = 0;
    int cur_sy = 0;

    auto step = [&]() {
        for (int r = 0; r < 2; r++) {
            if ((cyc * 2 + r) % 11 == 0) continue;
            lo.tick(t->ch_lo_req, t->ch_lo_addr, 14);
            hi.tick(t->ch_hi_req, t->ch_hi_addr, 9);
            t->ch_lo_dout = lo.dout; t->ch_lo_ready = lo.ready;
            t->ch_hi_dout = hi.dout; t->ch_hi_ready = hi.ready;
            t->clk_ram = 1; t->eval(); t->clk_ram = 0; t->eval();
        }
        // sprite / pivot samples for the pixel being sampled, zero latency
        int x = t->smp_x;
        const RefLine& L = ref[cur_sy];
        t->sp_color  = (x < (int)L.sp.size()) ? L.sp[x] : 0;
        t->pv_color  = (x < (int)L.pv.size()) ? (L.pv[x] & 0x1FFF) : 0;
        t->pv_opaque = (x < (int)L.pv.size()) ? ((L.pv[x] >> 13) & 1) : 0;
        t->sp_used   = L.sp_used;
        t->pv_used   = L.pv_used;

        // registered-address BRAM: q is mem[address presented last cycle]
        t->lr_q  = ra_l < lram.size()   ? lram[ra_l]   : 0;
        t->pf_q  = ra_p < pram.size()   ? pram[ra_p]   : 0;
        t->pal_q = ra_c < palram.size() ? palram[ra_c] : 0;
        uint32_t nl = t->lr_addr, np = t->pf_addr, nc = t->pal_addr;
        t->clk = 1; t->eval();
        ra_l = nl; ra_p = np; ra_c = nc;
        t->clk = 0; t->eval();
        cyc++;
    };

    t->reset = 1; t->frame_start = 0; t->line_start = 0; t->mix_start = 0;
    // Flipscreen is the GAME's bit (sprite command word 5 bit 13), not a
    // constant: Ray Force sets it permanently, Elevator Action Returns
    // never does. It selects the line-RAM walk direction below, so a
    // wrong value makes every line read the wrong control words.
    const int flip = getenv("F3_FLIP") ? atoi(getenv("F3_FLIP")) : 1;
    t->flip = flip; t->extend = 1;
    // F3_PAL12=1 exercises the 12-bit palette path (Space Invaders DX,
    // Riding Fight, Arabian Magic, Ring Rage). No reference frames exist
    // for those games, so this is a LIVENESS check: the output must
    // change, and change in the documented way.
    t->pal12 = getenv("F3_PAL12") ? atoi(getenv("F3_PAL12")) : 0;
    for (int w = 0; w < 4; w++) t->ctrl0[w] = ctrl[2 * w] | ((uint32_t)ctrl[2 * w + 1] << 16);
    for (int i = 0; i < 8; i++) step();
    t->reset = 0; step();
    t->frame_start = 1; step(); t->frame_start = 0; step();

    FILE* out = fopen(outp, "w");
    fprintf(out, "# frame %d\n", frame);
    long long worst_mix = 0, total_mix = 0;
    int bad = 0, total = 0, shown = 0;
    for (int sy = 0; sy < 256; sy++) {
        cur_sy = sy;
        t->screen_y = sy; t->lr_y = flip ? (255 - sy) : sy;
        t->line_start = 1; step(); t->line_start = 0;
        long long c = 0;
        while (t->busy && c < 100000) { step(); c++; }

        std::vector<uint32_t> px(320, 0xFFFFFFFF);
        t->mix_start = 1; step(); t->mix_start = 0;
        c = 0;
        while (t->mix_busy && c < 100000) {
            step(); c++;
            if (t->out_valid && t->out_x < 320) px[t->out_x] = t->out_rgb;
        }
        if (c > worst_mix) worst_mix = c;
        total_mix += c;

        if (!ref[sy].rgb.empty()) {
            fprintf(out, "%d", sy);
            for (int x = 0; x < 320; x++) fprintf(out, " %06x", px[x]);
            fprintf(out, "\n");
            for (int x = 0; x < 320; x++) {
                total++;
                if (px[x] != ref[sy].rgb[x]) {
                    bad++;
                    if (shown < 6) {
                        printf("  sy=%d x=%d: rtl %06x ref %06x\n", sy, x, px[x], ref[sy].rgb[x]);
                        shown++;
                    }
                }
            }
        }
    }
    fclose(out);
    printf("mixer: mean %lld / worst %lld clocks per line\n", total_mix / 256, worst_mix);
    printf("%d/%d visible pixels identical to MAME\n", total - bad, total);
    return bad ? 1 : 0;
}
