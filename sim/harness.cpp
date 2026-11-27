// ===========================================================================
// Verilator harness for DEPTH: behaves like a VGA monitor (locks to HS/VS
// only), so any whole-pixel pipeline latency inside the design is invisible.
// Writes 640x480 PPM frames plus a state digest.
// ===========================================================================
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vtop_depth.h"
#include "Vtop_depth___024root.h"
#include "verilated.h"

static Vtop_depth* dut;
static Vtop_depth___024root* R;

static const int H_ACT = 640, V_ACT = 480, H_BACK = 48, V_BACK = 33;
static std::vector<unsigned short> frame(H_ACT * V_ACT, 0);

static int  line_no = -1, pix_no = -1;
static int  hs_d = 1, vs_d = 1;
static bool armed = false;
static long sampled = 0;

static void tick_capture() {
    if (!R->top_depth__DOT__pix_ce) return;
    int hs = dut->VGA_HS, vs = dut->VGA_VS;
    if (vs && !vs_d)       { line_no = 0; pix_no = -1; }
    else if (hs && !hs_d)  { if (line_no >= 0) line_no++; pix_no = 0; }
    else if (pix_no >= 0)  { pix_no++; }

    if (armed && line_no >= V_BACK && line_no < V_BACK + V_ACT &&
        pix_no >= H_BACK && pix_no < H_BACK + H_ACT) {
        frame[(line_no - V_BACK) * H_ACT + (pix_no - H_BACK)] =
            (dut->VGA_R << 8) | (dut->VGA_G << 4) | dut->VGA_B;
        sampled++;
    }
    hs_d = hs; vs_d = vs;
}

static void step() {                    // one full 100 MHz clock
    dut->CLK100MHZ = 0; dut->eval();
    dut->CLK100MHZ = 1; dut->eval();
    tick_capture();
}

static int prev_vblank = 0;
static void wait_vblank(int n) {
    for (int i = 0; i < n; i++) {
        while (true) {
            step();
            int v = R->top_depth__DOT__vblank_pulse;
            if (v && !prev_vblank) { prev_vblank = v; break; }
            prev_vblank = v;
        }
    }
}

static void wait_vs_edge(int want) {    // want=0 -> falling, 1 -> rising
    int prev = dut->VGA_VS;
    while (true) {
        step();
        int cur = dut->VGA_VS;
        if (want == 0 && !cur && prev) return;
        if (want == 1 &&  cur && !prev) return;
        prev = cur;
    }
}

static void grab(const char* name) {
    wait_vs_edge(0);
    sampled = 0; armed = true;
    wait_vs_edge(1);
    wait_vs_edge(0);
    armed = false;
    FILE* f = fopen(name, "w");
    fprintf(f, "P3\n%d %d\n255\n", H_ACT, V_ACT);
    for (size_t i = 0; i < frame.size(); i++) {
        int v = frame[i];
        fprintf(f, "%d %d %d\n", ((v >> 8) & 15) * 17, ((v >> 4) & 15) * 17, (v & 15) * 17);
    }
    fclose(f);
    fprintf(stderr, "[harness] %s (%ld px)\n", name, sampled);
}

static void press_frames(int which, int frames) {
    switch (which) {
        case 0: dut->BTNU = 1; break; case 1: dut->BTNL = 1; break;
        case 2: dut->BTNR = 1; break; case 3: dut->BTND = 1; break;
        default: dut->BTNC = 1;
    }
    wait_vblank(frames);
    dut->BTNU = dut->BTNL = dut->BTNR = dut->BTND = dut->BTNC = 0;
}

static void place(int px, int py, int pa) {
    R->top_depth__DOT__u_player__DOT__player_x     = px;
    R->top_depth__DOT__u_player__DOT__player_y     = py;
    R->top_depth__DOT__u_player__DOT__player_angle = pa;
}
static void lenses(int l1, int l2) {
    R->top_depth__DOT__u_map__DOT__lens1_collected = l1;
    R->top_depth__DOT__u_map__DOT__lens2_collected = l2;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtop_depth;
    R   = dut->rootp;

    dut->CPU_RESETN = 0;
    dut->BTNU = dut->BTNL = dut->BTNR = dut->BTND = dut->BTNC = 0;
    dut->SW = 0;
    for (int i = 0; i < 40; i++) step();
    dut->CPU_RESETN = 1;
    for (int i = 0; i < 400; i++) step();

    grab("out_A_title.ppm");

    press_frames(4, 2);                     // BTNC -> start
    wait_vblank(3);
    grab("out_B_echo.ppm");

    dut->SW = 0x4000;  lenses(1, 0);
    place(12800, 12800, 32);
    wait_vblank(6);
    grab("out_C_map.ppm");

    dut->SW = 0x8000;  lenses(1, 1);
    place(2560, 4608, 0);
    wait_vblank(6);
    grab("out_D_sight.ppm");

    place(13312, 12800, 96);
    wait_vblank(6);
    grab("out_E_sight2.ppm");

    place(19968, 30208, 200);
    wait_vblank(6);
    grab("out_F_sight3.ppm");

    dut->SW = 0x0000;  lenses(0, 0);
    place(2560, 4608, 0);
    press_frames(0, 20);                    // walk forward
    wait_vblank(4);
    grab("out_G_echo_walk.ppm");

    // settled SIGHT views (no transition wipe) for visual review
    dut->SW = 0x8000;  lenses(1, 1);
    place(2560, 4608, 0);
    wait_vblank(24);
    grab("out_H_sight_clean.ppm");

    place(13312, 12800, 96);
    wait_vblank(4);
    grab("out_I_sight_clean2.ppm");

    dut->SW = 0x4000;
    place(12800, 14848, 32);
    wait_vblank(24);
    grab("out_J_map_clean.ppm");

    FILE* f = fopen("out_state.txt", "w");
    fprintf(f, "player_x=%d\nplayer_y=%d\nplayer_angle=%d\n",
            R->top_depth__DOT__u_player__DOT__player_x,
            R->top_depth__DOT__u_player__DOT__player_y,
            R->top_depth__DOT__u_player__DOT__player_angle);
    fprintf(f, "LED=%04x\n", dut->LED);
    fclose(f);

    dut->final();
    delete dut;
    fprintf(stderr, "[harness] done\n");
    return 0;
}
