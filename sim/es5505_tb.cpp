// ES5505 bench: drive rf_es5505 with the captured register stream and diff
// its 8-channel output against the Python model's raw output, sample by
// sample.
//
//   ./obj_dir/es5505tb dump/en3/en_writes.txt rom.bin model.raw [nsamples] [latency]
//
// ESR lines in the stream (oracle_en_dump.lua's read tap) are replayed as
// host reads through rd_req/rd_reg and the answer is checked against what
// MAME returned, at the same point in the write stream.
//
// The model generates sample k after applying every write with time <=
// k / rate; this bench queues the same writes before pulsing tick for
// sample k, so both apply them on the same boundary. rom.bin is the
// Ensoniq bytes in ES5505 word order (es5505_model.py --dump-rom).
#include "Vrf_es5505.h"
#include "Vrf_es5505___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

struct Wr { double t; int isbk; int reg; int data; int mask; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: es5505tb writes.txt rom.bin model.raw [nsamples] [latency]\n"); return 2; }
    long nsamp = argc > 4 ? atol(argv[4]) : 100000;
    int lat = argc > 5 ? atoi(argv[5]) : 20;

    std::vector<Wr> wr;
    { FILE* f = fopen(argv[1], "r"); if (!f) { perror(argv[1]); return 2; }
      char tag[8]; long frame; unsigned addr, data, mask; double t;
      char line[256];
      while (fgets(line, sizeof line, f)) {
          if (sscanf(line, "%ld %7s %x %x %x %lf", &frame, tag, &addr, &data, &mask, &t) < 6) continue;
          if (!strcmp(tag, "ES")) wr.push_back({t, 0, (int)((addr - 0x200000) >> 1), (int)data, (int)mask});
          else if (!strcmp(tag, "BK")) wr.push_back({t, 1, (int)(((addr - 0x300000) >> 1) & 31), (int)data, (int)mask});
          else if (!strcmp(tag, "ESR")) wr.push_back({t, 2, (int)((addr - 0x200000) >> 1), (int)data, (int)mask});
      }
      fclose(f); }
    std::vector<unsigned char> rom;
    { FILE* f = fopen(argv[2], "rb"); if (!f) { perror(argv[2]); return 2; }
      fseek(f, 0, SEEK_END); rom.resize(ftell(f)); fseek(f, 0, SEEK_SET);
      if (fread(rom.data(), 1, rom.size(), f) != rom.size()) return 2; fclose(f); }
    FILE* ref = fopen(argv[3], "rb"); if (!ref) { perror(argv[3]); return 2; }

    Vrf_es5505* t = new Vrf_es5505;
    long cyc = 0;
    int sm_delay = -1; unsigned sm_a = 0;
    auto step = [&]() {
        // behavioural sample memory: one line, `lat` cycles after the request
        t->sm_valid = 0; t->sm_busy = (sm_delay >= 0);
        if (t->sm_req && sm_delay < 0) { sm_delay = lat; sm_a = t->sm_addr; }
        else if (sm_delay > 0) sm_delay--;
        else if (sm_delay == 0) {
            unsigned base = (sm_a << 3) & 0x3fffff;    // {bank, addr[19:3]} bytes
            unsigned long long line = 0;
            for (int k = 0; k < 8; k++) line |= (unsigned long long)(base + k < rom.size() ? rom[base + k] : 0) << (8 * k);
            t->sm_line = line; t->sm_valid = 1; sm_delay = -1; t->sm_busy = 0;
        }
        t->clk = 1; t->eval(); t->clk = 0; t->eval();
        t->es_we = 0; t->bk_we = 0; t->tick = 0;
        cyc++;
    };

    t->bank_mask = 3;   // Ray Force: 8 MB ensoniq region -> MAME m_bankmask 3

    t->reset = 1; t->tick = 0; t->es_we = 0; t->bk_we = 0; t->sm_valid = 0; t->sm_busy = 0; t->rd_req = 0; t->rd_reg = 0;
    for (int i = 0; i < 8; i++) step();
    t->reset = 0;
    for (int i = 0; i < 40; i++) step();

    // MAME's (and the model's) sample rate is an INTEGER division of the
    // master clock; the bench must accumulate time with the same value or
    // the write boundaries drift from the model's by a sample every ~30 ms
    const long MASTER = 30476180 / 2;
    double tm = 0.0;
    size_t wi = 0;
    long bad = 0, shown = 0, done = 0, nrd = 0, badrd = 0, shownrd = 0;
    for (long k = 0; k < nsamp; k++) {
        // writes due before this sample
        while (wi < wr.size() && wr[wi].t <= tm) {
            const Wr& w = wr[wi++];
            if (w.isbk == 2) {
                // a host read: hold rd_req until the sampler answers, compare
                t->rd_req = 1; t->rd_reg = w.reg;
                long g = 0; while (!t->rd_valid && g++ < 200000) step();
                nrd++;
                if (!t->rd_valid) { printf("read %ld (t=%.6f reg %x): no answer\n", nrd, w.t, w.reg); return 1; }
                int got = t->rd_data & w.mask, want = w.data & w.mask;
                if (got != want) {
                    badrd++;
                    if (shownrd < 12) { printf("read %ld t=%.6f page %02x reg %x: rtl %04x mame %04x (mask %04x)\n", nrd, w.t, t->rootp->rf_es5505__DOT__page, w.reg, got, want, w.mask); shownrd++; }
                }
                t->rd_req = 0; step();
                continue;
            }
            if (w.isbk) { t->bk_we = 1; t->bk_voice = w.reg; t->bk_data = w.data & 7; }
            // the RTL masks with bank_mask now (MAME's m_bankmask), so hand it
            // three raw bits and let it do the masking -- that is the path
            // Puzzle Bobble 3/4 need, tested here against Ray Force's data
            else { t->es_we = 1; t->es_reg = w.reg; t->es_data = w.data; t->es_be = ((w.mask & 0xff00) ? 2 : 0) | ((w.mask & 0xff) ? 1 : 0); }
            step();
        }
        t->tick = 1; step();
        long g = 0; while (!t->out_valid && g++ < 100000) step();
        if (!t->out_valid) { printf("sample %ld: no output\n", k); return 1; }
        int32_t r8[8];
        if (fread(r8, 4, 8, ref) != 8) { printf("reference ended at sample %ld\n", k); break; }
        done++;
        for (int c = 0; c < 8; c++) {
            // out_ch is a packed [7:0][19:0]: 160 bits in 32-bit words
            uint32_t v = 0;
            for (int b = 0; b < 20; b++) { int i = 20 * c + b; v |= ((t->out_ch[i >> 5] >> (i & 31)) & 1u) << b; }
            int32_t got = (int32_t)(v << 12) >> 12;               // 20-bit signed
            if (got != r8[c]) {
                bad++;
                if (shown < 12) { printf("sample %ld ch%d: rtl %d ref %d\n", k, c, got, r8[c]); shown++; }
                if (bad == 1) {
                    // the RTL's voice file at the first divergence
                    printf("  rtl page %02x active %d; running voices:\n", t->rootp->rf_es5505__DOT__page, t->rootp->rf_es5505__DOT__active);
                    for (int v = 0; v < 32; v++) {
                        auto& w = t->rootp->rf_es5505__DOT__vf[v];   // VlWide<10> of 313 bits
                        auto bits = [&](int hi, int lo) { uint64_t r = 0; for (int i = lo; i <= hi; i++) r |= (uint64_t)((w[i >> 5] >> (i & 31)) & 1u) << (i - lo); return r; };
                        uint64_t ctrl = bits(310, 295);
                        if ((ctrl & 3) == 0 || v == 31)
                            printf("   v%2d ctrl %04llx fc %04llx start %llu end %llu accum %llu lvol %llu rvol %llu bank %llu k1 %04llx k2 %04llx\n",
                                   v, ctrl, bits(294, 279), bits(278, 250) >> 9, bits(249, 221) >> 9, bits(220, 192) >> 9,
                                   bits(159, 152), bits(151, 144), bits(312, 311), bits(175, 160), bits(191, 176));
                    }
                }
            }
        }
        int act = t->out_active;
        tm += 1.0 / (double)(MASTER / (16 * (act + 1)));
    }
    printf("%ld samples, %ld channel values differ (overruns %u, line fetches %u, queue drops %u, %ld cycles); %ld host reads, %ld wrong\n",
           done, bad, t->dbg_overrun, t->dbg_miss, t->dbg_wqdrop, cyc, nrd, badrd);
    if (!bad && !badrd) printf("ES5505 OK\n");
    return (bad || badrd) ? 1 : 0;
}
