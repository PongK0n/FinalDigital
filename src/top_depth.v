// ============================================================================
// DEPTH (CPE222 Group 17) - top level for the Digilent Nexys A7-100T
//
// ADR-0008 video timing contract
// -----------------------------
// Every renderer (topdown_2d, raycaster_3d, hud_sprite) presents the colour
// for pixel N exactly PIPE_STAGES pixel-clock ticks after vga_sync produced
// pixel N.  render_mux adds a combinational mux and the output registers add
// one more tick, so the pins are PIPE_STAGES+1 pixels behind the counters.
// HS, VS and DE are delayed by the SAME amount here, so the monitor sees an
// unchanged 640x480@60 picture - the whole frame simply leaves the chip a few
// pixel-clocks later.
// ============================================================================
module top_depth #(
    // Board defaults.  Simulation overrides these to keep test runs short;
    // nothing else in the design depends on them.
    parameter integer DEBOUNCE_CYCLES = 2000000,  // 20 ms @ 100 MHz
    parameter integer REFRESH_BITS    = 17,       // ~760 Hz 7-seg refresh
    parameter integer PIX_DIV         = 4,        // 25 MHz pixel clock enable
    // 1 = ADR-0009 depth shading + floor/ceiling gradient in SIGHT.
    // 0 = the flat palette of the original build (used by the pixel-level
    //     regression test to prove the pipeline rewrite changed nothing).
    parameter integer DEPTH_SHADING   = 1
) (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN, // Active-low reset button
    input  wire        BTNU, BTNL, BTNR, BTND, BTNC,
    input  wire [15:0] SW,
    output wire [15:0] LED,
    output wire        CA, CB, CC, CD, CE, CF, CG, DP,
    output wire [7:0]  AN,
    output wire [3:0]  VGA_R,
    output wire [3:0]  VGA_G,
    output wire [3:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire        AUD_PWM,
    output wire        AUD_SD
);
    `include "depth_pkg.vh"

    // 0. Reset synchroniser: CPU_RESETN is asynchronous to CLK100MHZ.
    //    Power-up value 2'b11 keeps reset asserted until the chain fills.
    
    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync = 2'b11;
    
    always @(posedge CLK100MHZ) begin
        rst_sync <= {rst_sync[0], ~CPU_RESETN};
    end
    wire rst = rst_sync[1];

    // 1. VGA timing
    wire       pix_ce;
    wire [9:0] pixel_x, pixel_y;
    wire       video_on;
    wire       vblank_pulse;
    wire       vga_hs_raw, vga_vs_raw;

    vga_sync #(.PIX_DIV(PIX_DIV)) u_vga (
        .clk          (CLK100MHZ),
        .rst          (rst),
        .pix_ce       (pix_ce),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        .video_on     (video_on),
        .vga_hs       (vga_hs_raw),
        .vga_vs       (vga_vs_raw),
        .vblank_pulse (vblank_pulse)
    );

    // 2. Debounced inputs
    wire [4:0]  btn_clean;
    wire [15:0] sw_clean;
    wire        btn_c_pulse;
    wire        btn_any_pulse;

    input_debounce #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_deb (
        .clk           (CLK100MHZ),
        .rst           (rst),
        .btn_raw       ({BTNC, BTND, BTNR, BTNL, BTNU}),
        .sw_raw        (SW),
        .btn_clean     (btn_clean),
        .sw_clean      (sw_clean),
        .btn_c_pulse   (btn_c_pulse),
        .btn_any_pulse (btn_any_pulse)
    );

    // Interconnect
    wire [1:0]  game_state;
    wire        game_reset_pulse;
    wire [15:0] secret_bcd, entered_bcd;
    wire [1:0]  door_idx;
    wire        err_pulse, win_pulse;
    wire [3:0]  min_tens, min_ones, sec_tens, sec_ones;

    wire        lens1_collected, lens2_collected, thin_wall_opened;
    wire        collect_lens1, collect_lens2, open_thin_wall;
    wire        in_jamming, near_door;

    wire [14:0] player_x, player_y;
    wire [7:0]  player_angle;
    wire [14:0] drone0_x, drone0_y, drone1_x, drone1_y, drone2_x, drone2_y;
    wire        drone_near, drone_hit;

    wire [1:0]  unlocked_tier, active_form;
    wire [4:0]  trans_cnt;

    wire [4:0]  rd_a_tx, rd_a_ty, rd_b_tx, rd_b_ty, rd_c_tx, rd_c_ty, rd_d_tx, rd_d_ty;
    wire [3:0]  rd_a_tile, rd_b_tile, rd_c_tile, rd_d_tile;
    wire        rd_c_fog;

    wire [14:0] dist_front, dist_left, dist_right, dist_back;

    // 3. Game FSM
    game_fsm u_game (
        .clk             (CLK100MHZ),
        .rst             (rst),
        .vblank_pulse    (vblank_pulse),
        .btn_any_pulse   (btn_any_pulse),
        .btn_c_pulse     (btn_c_pulse),
        .near_door       (near_door),
        .sw_digit        (sw_clean[3:0]),
        .drone_hit_pulse (drone_hit),
        .game_state      (game_state),
        .game_reset_pulse(game_reset_pulse),
        .secret_bcd      (secret_bcd),
        .entered_bcd     (entered_bcd),
        .door_idx        (door_idx),
        .err_pulse       (err_pulse),
        .win_pulse       (win_pulse),
        .min_tens        (min_tens),
        .min_ones        (min_ones),
        .sec_tens        (sec_tens),
        .sec_ones        (sec_ones)
    );

    // 4. World map & fog (block RAM, synchronous read ports)
    tile_map u_map (
        .clk              (CLK100MHZ),
        .rst              (rst),
        .game_reset       (game_reset_pulse),
        .vblank_pulse     (vblank_pulse),
        .player_tx        (player_x[14:10]),
        .player_ty        (player_y[14:10]),
        .collect_lens1    (collect_lens1),
        .collect_lens2    (collect_lens2),
        .open_thin_wall   (open_thin_wall),
        .drone_hit_pulse  (drone_hit),
        .lens1_collected  (lens1_collected),
        .lens2_collected  (lens2_collected),
        .thin_wall_opened (thin_wall_opened),
        .rd_a_tx          (rd_a_tx), .rd_a_ty (rd_a_ty), .rd_a_tile (rd_a_tile),
        .rd_b_tx          (rd_b_tx), .rd_b_ty (rd_b_ty), .rd_b_tile (rd_b_tile),
        .rd_c_tx          (rd_c_tx), .rd_c_ty (rd_c_ty), .rd_c_tile (rd_c_tile),
        .rd_c_fog         (rd_c_fog),
        .rd_d_tx          (rd_d_tx), .rd_d_ty (rd_d_ty), .rd_d_tile (rd_d_tile)
    );

    // 5. Evolution form FSM
    form_fsm u_form (
        .clk             (CLK100MHZ),
        .rst             (rst),
        .game_reset      (game_reset_pulse),
        .vblank_pulse    (vblank_pulse),
        .sw_form_req     (sw_clean[15:14]),
        .lens1_collected (lens1_collected),
        .lens2_collected (lens2_collected),
        .in_jamming      (in_jamming),
        .unlocked_tier   (unlocked_tier),
        .active_form     (active_form),
        .trans_cnt       (trans_cnt)
    );

    // 6. Player state & collision
    player_state u_player (
        .clk              (CLK100MHZ),
        .rst              (rst),
        .game_reset       (game_reset_pulse),
        .playing          (game_state == GAME_PLAY),
        .vblank_pulse     (vblank_pulse),
        .btn_clean        (btn_clean),
        .btn_c_pulse      (btn_c_pulse),
        .active_form      (active_form),
        .lens1_collected  (lens1_collected),
        .lens2_collected  (lens2_collected),
        .thin_wall_opened (thin_wall_opened),
        .drone_hit_pulse  (drone_hit),
        .map_tx           (rd_a_tx),
        .map_ty           (rd_a_ty),
        .map_tile         (rd_a_tile),
        .player_x         (player_x),
        .player_y         (player_y),
        .player_angle     (player_angle),
        .in_jamming       (in_jamming),
        .near_door        (near_door),
        .collect_lens1    (collect_lens1),
        .collect_lens2    (collect_lens2),
        .open_thin_wall   (open_thin_wall)
    );

    // 7. Patrol drones
    drone_ctrl u_drones (
        .clk          (CLK100MHZ),
        .rst          (rst),
        .game_reset   (game_reset_pulse),
        .playing      (game_state == GAME_PLAY),
        .vblank_pulse (vblank_pulse),
        .player_x     (player_x),
        .player_y     (player_y),
        .drone0_x     (drone0_x), .drone0_y (drone0_y),
        .drone1_x     (drone1_x), .drone1_y (drone1_y),
        .drone2_x     (drone2_x), .drone2_y (drone2_y),
        .drone_near   (drone_near),
        .drone_hit    (drone_hit)
    );

    // 8. 1D acoustic sonar (ECHO)
    radar_1d u_radar (
        .clk          (CLK100MHZ),
        .rst          (rst),
        .vblank_pulse (vblank_pulse),
        .player_x     (player_x),
        .player_y     (player_y),
        .player_angle (player_angle),
        .map_tx       (rd_b_tx),
        .map_ty       (rd_b_ty),
        .map_tile     (rd_b_tile),
        .dist_front   (dist_front),
        .dist_left    (dist_left),
        .dist_right   (dist_right),
        .dist_back    (dist_back)
    );

    // 9. 2D map renderer (MAP + ECHO)
    wire [11:0] rgb_2d;
    topdown_2d u_map2d (
        .clk          (CLK100MHZ),
        .rst          (rst),
        .pix_ce       (pix_ce),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        .video_on     (video_on),
        .echo_mode    (active_form == FORM_ECHO),
        .player_x     (player_x),
        .player_y     (player_y),
        .player_angle (player_angle),
        .drone0_x     (drone0_x), .drone0_y (drone0_y),
        .drone1_x     (drone1_x), .drone1_y (drone1_y),
        .drone2_x     (drone2_x), .drone2_y (drone2_y),
        .map_tx       (rd_c_tx),
        .map_ty       (rd_c_ty),
        .map_tile     (rd_c_tile),
        .map_fog      (rd_c_fog),
        .rgb_out      (rgb_2d)
    );

    // 9b. 3D raycaster (SIGHT)
    wire [11:0] rgb_3d;
    raycaster_3d #(.DEPTH_SHADING(DEPTH_SHADING)) u_ray3d (
        .clk          (CLK100MHZ),
        .rst          (rst),
        .vblank_pulse (vblank_pulse),
        .pix_ce       (pix_ce),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        .video_on     (video_on),
        .player_x     (player_x),
        .player_y     (player_y),
        .player_angle (player_angle),
        .secret_bcd   (secret_bcd),
        .map_tx       (rd_d_tx),
        .map_ty       (rd_d_ty),
        .map_tile     (rd_d_tile),
        .rgb_out      (rgb_3d)
    );

    // 10. Persistent HUD sprite (all three forms)
    wire        hud_on;
    wire [11:0] hud_rgb;
    hud_sprite u_hud (
        .clk           (CLK100MHZ),
        .rst           (rst),
        .pix_ce        (pix_ce),
        .pixel_x       (pixel_x),
        .pixel_y       (pixel_y),
        .active_form   (active_form),
        .unlocked_tier (unlocked_tier),
        .in_jamming    (in_jamming),
        .hud_on        (hud_on),
        .hud_rgb       (hud_rgb)
    );

    // 11. Render mux
    wire [11:0] vga_rgb;
    render_mux u_mux (
        .clk         (CLK100MHZ),
        .rst         (rst),
        .pix_ce      (pix_ce),
        .pixel_x     (pixel_x),
        .pixel_y     (pixel_y),
        .video_on    (video_on),
        .game_state  (game_state),
        .active_form (active_form),
        .trans_cnt   (trans_cnt),
        .rgb_2d      (rgb_2d),
        .rgb_3d      (rgb_3d),
        .hud_on      (hud_on),
        .hud_rgb     (hud_rgb),
        .vga_rgb     (vga_rgb)
    );

    // 11b. Sync/blank delayed by the renderer latency, then registered into
    //      the IOBs alongside RGB so nothing combinational reaches a pin.
    wire hs_dly, vs_dly, de_dly;
    pix_delay #(.W(3), .N(PIPE_STAGES), .RSTV(64'b110)) u_sync_dly (
        .clk (CLK100MHZ), .rst (rst), .en (pix_ce),
        .d   ({vga_hs_raw, vga_vs_raw, video_on}),
        .q   ({hs_dly,     vs_dly,     de_dly})
    );

    (* IOB = "TRUE" *) reg [11:0] vga_rgb_q;
    (* IOB = "TRUE" *) reg        vga_hs_q, vga_vs_q;

    always @(posedge CLK100MHZ) begin
        if (rst) begin
            vga_rgb_q <= 12'h000;
            vga_hs_q  <= 1'b1;
            vga_vs_q  <= 1'b1;
        end else if (pix_ce) begin
            vga_rgb_q <= de_dly ? vga_rgb : 12'h000;
            vga_hs_q  <= hs_dly;
            vga_vs_q  <= vs_dly;
        end
    end

    assign VGA_R  = vga_rgb_q[11:8];
    assign VGA_G  = vga_rgb_q[7:4];
    assign VGA_B  = vga_rgb_q[3:0];
    assign VGA_HS = vga_hs_q;
    assign VGA_VS = vga_vs_q;

    // 12. Board telemetry & audio
    led_radar u_led (
        .dist_left  (dist_left),
        .dist_right (dist_right),
        .led        (LED)
    );

    seven_seg_ctrl #(.REFRESH_BITS(REFRESH_BITS)) u_7seg (
        .clk         (CLK100MHZ),
        .rst         (rst),
        .door_mode   (near_door && (game_state == GAME_PLAY)),
        .dist_front  (dist_front),
        .sw_digit    (sw_clean[3:0]),
        .door_idx    (door_idx),
        .entered_bcd (entered_bcd),
        .min_tens    (min_tens),
        .min_ones    (min_ones),
        .sec_tens    (sec_tens),
        .sec_ones    (sec_ones),
        .ca (CA), .cb (CB), .cc (CC), .cd (CD),
        .ce (CE), .cf (CF), .cg (CG), .dp (DP),
        .an          (AN)
    );

    audio_dds #(.SIM_CLK_SCALE((PIX_DIV <= 1) ? 4 : 1)) u_audio (
        .clk          (CLK100MHZ),
        .rst          (rst),
        .playing      (game_state == GAME_PLAY),
        .dist_front   (dist_front),
        .drone_near   (drone_near),
        .unlock_pulse (collect_lens1 | collect_lens2),
        .err_pulse    (err_pulse),
        .win_pulse    (win_pulse),
        .aud_pwm      (AUD_PWM),
        .aud_sd       (AUD_SD)
    );

endmodule
