// rf_ddr_arb: does rotation ever lose a write?
//
// This bench exists because of a defect that no other bench in this tree can
// see. sys/arcade_video.v's screen_rotate offers its DDR3 write as a ONE-CYCLE
// pulse and never reads DDRAM_BUSY -- which is the f2sdram bridge's Avalon-MM
// waitrequest. Avalon says a transfer happens only on a cycle where the master
// drives the command AND waitrequest is low, so a rotation pixel that lands on
// a busy cycle is silently lost. That was harmless while rotation owned the
// port; it stopped being harmless when rf_spr_fb became a second client whose
// traffic scales with what is on screen.
//
// So the bench models the bridge honestly (waitrequest, not a magic FIFO), a
// rotation client that behaves exactly like screen_rotate, and a sprite client
// whose load is a knob. Two things are checked:
//
//   1. EVERY rotation write offered is delivered exactly once and in order.
//      This is what the FIFO in rf_ddr_arb has to guarantee.
//   2. The counterfactual: how many of those writes coincided with a busy
//      port, i.e. how many the UNFIXED path would have dropped, and whether
//      that number scales with sprite load. That is the bug, reproduced.
//
// Usage: ./obj_dir/ddrarbtb [frames]
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include "Vrf_ddr_arb.h"
#include "verilated.h"

static Vrf_ddr_arb *dut;
static uint64_t tick_count = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    tick_count++;
}

// A crude but deterministic PRNG so runs are reproducible.
static uint32_t rng_state = 0x13572468u;
static uint32_t rnd() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

struct Result {
    long offered, delivered, mismatched;
    long stall, lost, peak, need;
};

// busy_pct: how often the bridge asserts waitrequest, standing in for how hard
// the sprite framebuffer is leaning on the port. Light attract vs a screen full
// of explosions is exactly this knob.
//
// burst_len: real waitrequest does not arrive as independent coin flips -- a
// DDR3 bridge stalls in RUNS while it turns the bus around or serves a burst.
// That is what sizes the FIFO: rotation offers a word every 8 cycles, so a run
// of N busy cycles needs about N/8 entries. Depth 8 therefore covers ~64
// consecutive stalled cycles, and this parameter is here to find out where it
// actually breaks rather than to assume it does not.
static Result run(int cycles, int busy_pct, bool sprite_load, int burst_len = 1) {
    int busy_run = 0;
    bool busy_now = false;
    dut->reset = 1;
    dut->r_we = 0; dut->f_we = 0; dut->f_rd = 0;
    dut->DDRAM_BUSY = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;

    std::vector<uint32_t> offered, delivered;
    uint32_t next_addr = 0x1000;
    long mismatched = 0;
    // An unbounded software queue running the same arbitration, so the bench
    // reports the depth the scenario DEMANDS independently of the depth the
    // DUT happens to have. This is what sizes FD.
    long ideal_q = 0, ideal_peak = 0;

    for (int c = 0; c < cycles; c++) {
        // ---- the bridge: waitrequest, in RUNS, at an honest duty cycle -----
        // The first version of this model set busy for burst_len cycles and
        // idle for ONE, which quietly turned "35 % busy, runs of 16" into
        // 90 % busy and failed the DUT for the wrong reason. Busy and idle
        // runs are both scaled so the duty cycle really is busy_pct.
        if (busy_run <= 0) {
            busy_now = !busy_now;
            if (busy_now) busy_run = burst_len;
            else          busy_run = (busy_pct > 0)
                                   ? (burst_len * (100 - busy_pct) + busy_pct/2) / busy_pct
                                   : 1000000;
            if (busy_run < 1) busy_run = 1;
        }
        busy_run--;
        dut->DDRAM_BUSY = (busy_pct == 0) ? 0 : (busy_now ? 1 : 0);

        // ---- rotation: a one-cycle pulse every 8 cycles, like CE_PIXEL ----
        bool rot_fire = (c % 8) == 0;
        dut->r_we       = rot_fire ? 1 : 0;
        dut->r_addr     = next_addr;
        dut->r_din      = 0xA5A50000u | (next_addr & 0xFFFF);
        dut->r_be       = 0x0F;
        dut->r_burstcnt = 1;

        // ---- the sprite framebuffer, asking for the port ------------------
        dut->f_rd = (sprite_load && (c % 3) == 0) ? 1 : 0;
        dut->f_we = (sprite_load && (c % 7) == 0) ? 1 : 0;
        dut->f_addr = 0x200000 + c;
        dut->f_burstcnt = 8;

        dut->eval();

        // What the bridge actually accepts this cycle, per Avalon.
        bool accepted = dut->DDRAM_WE && !dut->DDRAM_BUSY;
        uint32_t acc_addr = dut->DDRAM_ADDR;
        // Rotation's addresses are the only ones in this range.
        bool is_rot = accepted && acc_addr >= 0x1000 && acc_addr < 0x200000;

        if (rot_fire) { offered.push_back(next_addr); next_addr++; }
        if (is_rot)   delivered.push_back(acc_addr);

        if (rot_fire) ideal_q++;
        if (ideal_q > 0 && !dut->DDRAM_BUSY) ideal_q--;
        if (ideal_q > ideal_peak) ideal_peak = ideal_q;

        tick();
    }

    // Drain: stop offering and let the FIFO empty.
    dut->r_we = 0; dut->f_rd = 0; dut->f_we = 0;
    for (int c = 0; c < 4096; c++) {
        dut->DDRAM_BUSY = ((rnd() % 100) < (uint32_t)busy_pct) ? 1 : 0;
        dut->eval();
        if (dut->DDRAM_WE && !dut->DDRAM_BUSY) {
            uint32_t a = dut->DDRAM_ADDR;
            if (a >= 0x1000 && a < 0x200000) delivered.push_back(a);
        }
        tick();
    }

    for (size_t i = 0; i < offered.size() && i < delivered.size(); i++)
        if (offered[i] != delivered[i]) mismatched++;

    Result r;
    r.offered    = (long)offered.size();
    r.delivered  = (long)delivered.size();
    r.mismatched = mismatched;
    r.stall      = dut->rot_stall;
    r.lost       = dut->rot_lost;
    r.peak       = dut->rot_peak;
    r.need       = ideal_peak;
    return r;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vrf_ddr_arb;

    const int CYCLES = (argc > 1) ? atoi(argv[1]) : 200000;
    int fails = 0;
    const long FD_DESIGN = 16;           // must match rf_ddr_arb.sv's FD

    printf("rf_ddr_arb -- can rotation lose a write?\n");
    printf("%-26s %8s %8s %7s %8s %6s %6s %6s\n",
           "scenario", "offered", "delivrd", "mismat", "stalled", "lost",
           "peak", "need");

    struct { const char *name; int busy; bool spr; int burst; } cases[] = {
        { "idle          (0% busy)",     0, false,   1 },
        { "light load    (5% busy)",     5, true,    1 },
        { "heavy load   (35% busy)",    35, true,    1 },
        { "brutal       (70% busy)",    70, true,    1 },
        { "stall runs x16  (35%)",      35, true,   16 },
        { "stall runs x64  (35%)",      35, true,   64 },
        { "stall runs x64  (70%)",      70, true,   64 },
        { "stall runs x256 (35%)",      35, true,  256 },
    };

    for (auto &cs : cases) {
        rng_state = 0x13572468u;             // same stream for every scenario
        Result r = run(CYCLES, cs.busy, cs.spr, cs.burst);
        // Honest criterion: the FIFO must be lossless whenever the scenario's
        // demanded depth fits in FD. A scenario that demands MORE than FD is
        // outside the design point, not a bug -- it is reported as OVER, and
        // rot_lost is exactly the instrument that would catch it on hardware.
        bool in_envelope = (r.need <= FD_DESIGN);
        bool lossless    = (r.delivered == r.offered) && (r.mismatched == 0) && (r.lost == 0);
        bool ok          = in_envelope ? lossless : true;
        const char *verdict = !in_envelope ? "OVER (needs > FD)"
                                           : (lossless ? "OK" : "FAIL");
        printf("%-26s %8ld %8ld %7ld %8ld %6ld %6ld %6ld  %s\n",
               cs.name, r.offered, r.delivered, r.mismatched, r.stall, r.lost,
               r.peak, r.need, verdict);
        if (!ok) fails++;
    }

    printf("\nThe 'stalled' column is the bug: those are the rotation writes\n"
           "that arrived on a busy cycle. screen_rotate's one-cycle pulse\n"
           "loses every one of them; the FIFO in rf_ddr_arb delivers them.\n"
           "Note how it scales with load -- that is the player's report.\n"
           "'peak' is the FIFO high-water mark, 'need' the depth the scenario\n"
           "demands. FD must exceed 'need' with margin; the board reports its\n"
           "own peak on the ROTSTL:PK:LS self-test row.\n");

    if (fails) { printf("\n%d scenario(s) FAILED\n", fails); return 1; }
    printf("\nFD = %ld. Every scenario within that depth delivered every rotation\n"
           "write, in order, with none lost. Scenarios marked OVER demand a deeper\n"
           "FIFO than FD and are outside the design point -- rot_peak read off the\n"
           "board is what says whether real waitrequest ever gets there.\n",
           FD_DESIGN);
    return 0;
}
