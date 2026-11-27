// Game-logic regression: scripted button sequence, per-frame state digest.
#include <cstdio>
#include "Vtop_depth.h"
#include "Vtop_depth___024root.h"
#include "verilated.h"

static Vtop_depth* dut; static Vtop_depth___024root* R;
static int prev_vb = 0, frame = 0; static FILE* fd;

static void step() { dut->CLK100MHZ=0; dut->eval(); dut->CLK100MHZ=1; dut->eval(); }

#define T(x) R->top_depth__DOT__##x

static void logf_() {
    fprintf(fd,"f=%d st=%d form=%d px=%d py=%d pa=%d df=%d dl=%d dr=%d db=%d "
               "LED=%04x jam=%d door=%d l1=%d l2=%d thin=%d "
               "d0=%d,%d d1=%d,%d d2=%d,%d t=%d%d:%d%d seg=%d%d%d%d%d%d%d%d an=%02x\n",
        frame, T(game_state), T(active_form),
        R->top_depth__DOT__u_player__DOT__player_x,
        R->top_depth__DOT__u_player__DOT__player_y,
        R->top_depth__DOT__u_player__DOT__player_angle,
        T(dist_front), T(dist_left), T(dist_right), T(dist_back),
        dut->LED, T(in_jamming), T(near_door),
        R->top_depth__DOT__u_map__DOT__lens1_collected,
        R->top_depth__DOT__u_map__DOT__lens2_collected,
        R->top_depth__DOT__u_map__DOT__thin_wall_opened,
        T(drone0_x),T(drone0_y),T(drone1_x),T(drone1_y),T(drone2_x),T(drone2_y),
        T(min_tens),T(min_ones),T(sec_tens),T(sec_ones),
        dut->CA,dut->CB,dut->CC,dut->CD,dut->CE,dut->CF,dut->CG,dut->DP,dut->AN);
}

static void frames(int n) {
    for (int i=0;i<n;i++){
        while (true){ step(); int v=T(vblank_pulse); if(v&&!prev_vb){prev_vb=v;break;} prev_vb=v; }
        frame++; logf_();
    }
}
static void hold(int w,int n){
    switch(w){case 0:dut->BTNU=1;break;case 1:dut->BTNL=1;break;case 2:dut->BTNR=1;break;
              case 3:dut->BTND=1;break;default:dut->BTNC=1;}
    frames(n);
    dut->BTNU=dut->BTNL=dut->BTNR=dut->BTND=dut->BTNC=0;
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vtop_depth; R=dut->rootp;
    fd=fopen("out_logic.txt","w");
    dut->CPU_RESETN=0; dut->BTNU=dut->BTNL=dut->BTNR=dut->BTND=dut->BTNC=0; dut->SW=0;
    for(int i=0;i<40;i++) step();
    dut->CPU_RESETN=1; for(int i=0;i<400;i++) step();

    frames(3);            // TITLE
    hold(4,3);            // BTNC -> PLAY
    frames(3);
    hold(0,16);           // walk forward
    frames(2);
    hold(2,10);           // turn right
    frames(2);
    hold(0,18);           // walk into a wall -> slide
    frames(2);
    hold(1,8);            // turn left
    hold(3,10);           // back up
    frames(3);
    dut->SW=0x4000; frames(4);   // request MAP without the lens
    dut->SW=0x8000; frames(4);   // request SIGHT without the lens
    dut->SW=0x0000; frames(3);
    hold(0,25);           // walk on
    frames(4);
    fclose(fd);
    fprintf(stderr,"[log] %d frames\n",frame);
    dut->final(); delete dut; return 0;
}
