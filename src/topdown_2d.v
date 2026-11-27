// ============================================================================
// DEPTH - top-down 2D map renderer (FORM 2 - MAP) and short-range FORM 1 ECHO
//
// ADR-0008 rewrite.  Previously this module was one enormous combinational
// cloud: pixel_x/pixel_y -> scatter hash -> tile address -> asynchronous
// 1024-entry map ROM -> colour decision -> render_mux -> output pin, with a
// 768-entry sprite ROM and four 16-bit multiplies hanging off the same path.
//
// Now:
//   * Everything that only changes once per frame (player and drone screen
//     positions, the heading spark, the trig lookups) is computed ONCE during
//     vertical blanking instead of once per pixel.  That removes eight
//     multipliers and two LUT ROMs from the pixel path outright.
//   * What is left is a 5-stage pixel pipeline: address -> memory -> colour,
//     plus two matching delay stages, so this renderer lines up with the
//     raycaster and the HUD.
// Pixel colours are bit-identical to the previous version.
// ============================================================================
module topdown_2d #(
    parameter SIN_FILE    = "sin_lut.mem",
    parameter COS_FILE    = "cos_lut.mem",
    parameter SPRITE_FILE = "hud_sprites.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        pix_ce,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire        video_on,
    input  wire        echo_mode,
    input  wire [14:0] player_x,
    input  wire [14:0] player_y,
    input  wire [7:0]  player_angle,
    input  wire [14:0] drone0_x, drone0_y,
    input  wire [14:0] drone1_x, drone1_y,
    input  wire [14:0] drone2_x, drone2_y,

    // Read port C on tile_map (synchronous: data one clock after address)
    output reg  [4:0]  map_tx,
    output reg  [4:0]  map_ty,
    input  wire [3:0]  map_tile,
    input  wire        map_fog,

    output wire [11:0] rgb_out
);
    `include "depth_pkg.vh"

    localparam [9:0] MAP_X0 = 10'd96;
    localparam [9:0] MAP_X1 = 10'd544; // 96 + 32*14
    localparam [9:0] MAP_Y0 = 10'd16;
    localparam [9:0] MAP_Y1 = 10'd464; // 16 + 32*14

    // =======================================================================
    //  Per-frame constants (latched deep inside vertical blanking, long after
    //  player_state / drone_ctrl have finished their once-per-frame update)
    // =======================================================================
    wire frame_latch = pix_ce && (pixel_y == 10'd500) && (pixel_x == 10'd0);

    wire [9:0] cos_q, sin_q;
    rom_sp #(.AW(8), .DW(10), .MEM_FILE(COS_FILE)) u_cos (.clk(clk), .addr(player_angle), .q(cos_q));
    rom_sp #(.AW(8), .DW(10), .MEM_FILE(SIN_FILE)) u_sin (.clk(clk), .addr(player_angle), .q(sin_q));

    wire signed [15:0] cos_ext = {{6{cos_q[9]}}, cos_q};
    wire signed [15:0] sin_ext = {{6{sin_q[9]}}, sin_q};

    function [9:0] q510_to_px_x;
        input [14:0] qx;
        begin
            q510_to_px_x = MAP_X0 + ({5'd0, qx[14:10]} * 10'd14) + (({4'd0, qx[9:6]} * 10'd14) >> 4);
        end
    endfunction

    function [9:0] q510_to_px_y;
        input [14:0] qy;
        begin
            q510_to_px_y = MAP_Y0 + ({5'd0, qy[14:10]} * 10'd14) + (({4'd0, qy[9:6]} * 10'd14) >> 4);
        end
    endfunction

    reg [10:0] fc_pxh, fc_pyh;                       // player_x/y >> 4 (ECHO world origin)
    reg [9:0]  fc_p_px,  fc_p_py;
    reg [9:0]  fc_dir_px, fc_dir_py;
    reg [9:0]  fc_edir_px, fc_edir_py;
    reg [9:0]  fc_d0x, fc_d0y, fc_d1x, fc_d1y, fc_d2x, fc_d2y;

    always @(posedge clk) begin
        if (rst) begin
            fc_pxh <= 11'd0; fc_pyh <= 11'd0;
            fc_p_px <= 10'd0; fc_p_py <= 10'd0;
            fc_dir_px <= 10'd0; fc_dir_py <= 10'd0;
            fc_edir_px <= 10'd320; fc_edir_py <= 10'd240;
            fc_d0x <= 10'd0; fc_d0y <= 10'd0;
            fc_d1x <= 10'd0; fc_d1y <= 10'd0;
            fc_d2x <= 10'd0; fc_d2y <= 10'd0;
        end else if (frame_latch) begin
            fc_pxh     <= player_x[14:4];
            fc_pyh     <= player_y[14:4];
            fc_p_px    <= q510_to_px_x(player_x);
            fc_p_py    <= q510_to_px_y(player_y);
            fc_dir_px  <= $unsigned($signed({6'd0, q510_to_px_x(player_x)}) + ((cos_ext * 16'sd5)  >>> 8));
            fc_dir_py  <= $unsigned($signed({6'd0, q510_to_px_y(player_y)}) + ((sin_ext * 16'sd5)  >>> 8));
            fc_edir_px <= $unsigned(16'sd320 + ((cos_ext * 16'sd20) >>> 8));
            fc_edir_py <= $unsigned(16'sd240 + ((sin_ext * 16'sd20) >>> 8));
            fc_d0x     <= q510_to_px_x(drone0_x); fc_d0y <= q510_to_px_y(drone0_y);
            fc_d1x     <= q510_to_px_x(drone1_x); fc_d1y <= q510_to_px_y(drone1_y);
            fc_d2x     <= q510_to_px_x(drone2_x); fc_d2y <= q510_to_px_y(drone2_y);
        end
    end

    // =======================================================================
    //  Stage 0 - tile/sub-tile counters tracking pixel_x / pixel_y
    // =======================================================================
    reg [4:0] tx_cnt, ty_cnt;
    reg [3:0] sx_cnt, sy_cnt;

    always @(posedge clk) begin
        if (rst) begin
            tx_cnt <= 5'd0; sx_cnt <= 4'd0;
            ty_cnt <= 5'd0; sy_cnt <= 4'd0;
        end else if (pix_ce) begin
            if (pixel_x == (MAP_X0 - 10'd1)) begin
                tx_cnt <= 5'd0;
                sx_cnt <= 4'd0;
            end else if ((pixel_x >= MAP_X0) && (pixel_x < MAP_X1 - 10'd1)) begin
                if (sx_cnt == 4'd13) begin
                    sx_cnt <= 4'd0;
                    tx_cnt <= tx_cnt + 5'd1;
                end else begin
                    sx_cnt <= sx_cnt + 4'd1;
                end
            end

            if (pixel_x == 10'd799) begin
                if (pixel_y == (MAP_Y0 - 10'd1)) begin
                    ty_cnt <= 5'd0;
                    sy_cnt <= 4'd0;
                end else if ((pixel_y >= MAP_Y0) && (pixel_y < MAP_Y1 - 10'd1)) begin
                    if (sy_cnt == 4'd13) begin
                        sy_cnt <= 4'd0;
                        ty_cnt <= ty_cnt + 5'd1;
                    end else begin
                        sy_cnt <= sy_cnt + 4'd1;
                    end
                end
            end
        end
    end

    // ---- ECHO: player-centred 64 px/tile world coordinates ----------------
    wire signed [12:0] echo_world_x = $signed({2'b00, fc_pxh}) + ($signed({3'b000, pixel_x}) - 13'sd320);
    wire signed [12:0] echo_world_y = $signed({2'b00, fc_pyh}) + ($signed({3'b000, pixel_y}) - 13'sd240);
    wire               echo_oob_c   = (echo_world_x < 13'sd0) || (echo_world_x >= 13'sd2048) ||
                                      (echo_world_y < 13'sd0) || (echo_world_y >= 13'sd2048);
    wire [4:0] echo_tx_c = echo_world_x[10:6];
    wire [4:0] echo_ty_c = echo_world_y[10:6];
    wire [5:0] echo_sx_c = echo_world_x[5:0];
    wire [5:0] echo_sy_c = echo_world_y[5:0];

    // ---- MAP: static frosted scatter + 2x2 mosaic -------------------------
    wire [8:0] m_bx = pixel_x[9:1];
    wire [8:0] m_by = pixel_y[9:1];
    wire [2:0] m_hx = {m_bx[0] ^ m_by[1], m_bx[1] ^ m_by[0], m_bx[2] ^ m_by[2]};
    wire [2:0] m_hy = {m_by[0] ^ m_bx[2], m_by[1] ^ m_bx[0], m_by[2] ^ m_bx[1]};

    function signed [3:0] hash_to_off;
        input [2:0] h;
        begin
            case (h)
                3'd0: hash_to_off = -4'sd3;
                3'd1: hash_to_off = -4'sd2;
                3'd2: hash_to_off = -4'sd1;
                3'd3: hash_to_off =  4'sd0;
                3'd4: hash_to_off =  4'sd0;
                3'd5: hash_to_off =  4'sd1;
                3'd6: hash_to_off =  4'sd2;
                3'd7: hash_to_off =  4'sd3;
            endcase
        end
    endfunction

    wire signed [3:0] scat_jx = hash_to_off(m_hx);
    wire signed [3:0] scat_jy = hash_to_off(m_hy);

    wire signed [5:0] sx_sum = $signed({2'b00, sx_cnt[3:1], 1'b0}) + {{2{scat_jx[3]}}, scat_jx};
    wire signed [5:0] sy_sum = $signed({2'b00, sy_cnt[3:1], 1'b0}) + {{2{scat_jy[3]}}, scat_jy};

    wire [4:0] scat_tx_c = (sx_sum < 6'sd0)   ? ((tx_cnt == 5'd0)  ? 5'd0  : (tx_cnt - 5'd1)) :
                           (sx_sum >= 6'sd14) ? ((tx_cnt == 5'd31) ? 5'd31 : (tx_cnt + 5'd1)) : tx_cnt;
    wire [4:0] scat_ty_c = (sy_sum < 6'sd0)   ? ((ty_cnt == 5'd0)  ? 5'd0  : (ty_cnt - 5'd1)) :
                           (sy_sum >= 6'sd14) ? ((ty_cnt == 5'd31) ? 5'd31 : (ty_cnt + 5'd1)) : ty_cnt;

    wire signed [5:0] sx_wrapped = (sx_sum < 6'sd0)   ? ((tx_cnt == 5'd0)  ? 6'sd0  : (sx_sum + 6'sd14)) :
                                   (sx_sum >= 6'sd14) ? ((tx_cnt == 5'd31) ? 6'sd13 : (sx_sum - 6'sd14)) : sx_sum;
    wire signed [5:0] sy_wrapped = (sy_sum < 6'sd0)   ? ((ty_cnt == 5'd0)  ? 6'sd0  : (sy_sum + 6'sd14)) :
                                   (sy_sum >= 6'sd14) ? ((ty_cnt == 5'd31) ? 6'sd13 : (sy_sum - 6'sd14)) : sy_sum;
    wire [3:0] scat_sx_c = sx_wrapped[3:0];
    wire [3:0] scat_sy_c = sy_wrapped[3:0];

    wire signed [10:0] px_raw = $signed({1'b0, pixel_x[9:1], 1'b0}) + {{7{scat_jx[3]}}, scat_jx};
    wire signed [10:0] py_raw = $signed({1'b0, pixel_y[9:1], 1'b0}) + {{7{scat_jy[3]}}, scat_jy};
    wire [9:0] scat_px_c = (px_raw <  $signed({1'b0, MAP_X0})) ? MAP_X0 :
                           (px_raw >= $signed({1'b0, MAP_X1})) ? (MAP_X1 - 10'd1) : px_raw[9:0];
    wire [9:0] scat_py_c = (py_raw <  $signed({1'b0, MAP_Y0})) ? MAP_Y0 :
                           (py_raw >= $signed({1'b0, MAP_Y1})) ? (MAP_Y1 - 10'd1) : py_raw[9:0];

    wire in_map_c = video_on &&
                    (pixel_x >= MAP_X0) && (pixel_x < MAP_X1) &&
                    (pixel_y >= MAP_Y0) && (pixel_y < MAP_Y1);

    // ---- ECHO sprite + halo geometry --------------------------------------
    wire       in_echo_spr_c = (pixel_x >= 10'd304) && (pixel_x < 10'd336) &&
                               (pixel_y >= 10'd224) && (pixel_y < 10'd256);
    wire [4:0] spr_rx        = pixel_x[4:0] - 5'd16;
    wire [4:0] spr_ry        = pixel_y[4:0];

    wire [9:0] echo_dx_c = (pixel_x >= 10'd320) ? (pixel_x - 10'd320) : (10'd320 - pixel_x);
    wire [9:0] echo_dy_c = (pixel_y >= 10'd240) ? (pixel_y - 10'd240) : (10'd240 - pixel_y);
    wire       echo_box_c = (echo_dx_c <= 10'd96) && (echo_dy_c <= 10'd96);

    function near_dot;
        input [9:0] x, y, cx, cy, r;
        reg [9:0] dx, dy;
        begin
            dx = (x >= cx) ? (x - cx) : (cx - x);
            dy = (y >= cy) ? (y - cy) : (cy - y);
            near_dot = (dx <= r) && (dy <= r);
        end
    endfunction

    // =======================================================================
    //  S1 - addresses + pixel attributes
    // =======================================================================
    reg [9:0] s1_spr_addr;
    reg [5:0] s1_echo_sx, s1_echo_sy;
    reg [3:0] s1_scat_sx, s1_scat_sy;
    reg [9:0] s1_scat_px, s1_scat_py;
    reg [9:0] s1_echo_dx, s1_echo_dy;
    reg [9:0] s1_px, s1_py;
    reg       s1_echo_oob, s1_in_map, s1_in_echo_spr, s1_echo_box;
    reg       s1_m_bx0, s1_m_by0, s1_video_on, s1_echo_mode;

    always @(posedge clk) begin
        if (rst) begin
            map_tx <= 5'd0; map_ty <= 5'd0; s1_spr_addr <= 10'd0;
            s1_echo_sx <= 6'd0; s1_echo_sy <= 6'd0;
            s1_scat_sx <= 4'd0; s1_scat_sy <= 4'd0;
            s1_scat_px <= 10'd0; s1_scat_py <= 10'd0;
            s1_echo_dx <= 10'd0; s1_echo_dy <= 10'd0;
            s1_px <= 10'd0; s1_py <= 10'd0;
            s1_echo_oob <= 1'b0; s1_in_map <= 1'b0; s1_in_echo_spr <= 1'b0;
            s1_echo_box <= 1'b0; s1_m_bx0 <= 1'b0; s1_m_by0 <= 1'b0;
            s1_video_on <= 1'b0; s1_echo_mode <= 1'b0;
        end else if (pix_ce) begin
            map_tx         <= echo_mode ? echo_tx_c : scat_tx_c;
            map_ty         <= echo_mode ? echo_ty_c : scat_ty_c;
            s1_spr_addr    <= {2'd0, spr_ry[4:1], spr_rx[4:1]};
            s1_echo_sx     <= echo_sx_c;
            s1_echo_sy     <= echo_sy_c;
            s1_scat_sx     <= scat_sx_c;
            s1_scat_sy     <= scat_sy_c;
            s1_scat_px     <= scat_px_c;
            s1_scat_py     <= scat_py_c;
            s1_echo_dx     <= echo_dx_c;
            s1_echo_dy     <= echo_dy_c;
            s1_px          <= pixel_x;
            s1_py          <= pixel_y;
            s1_echo_oob    <= echo_oob_c;
            s1_in_map      <= in_map_c;
            s1_in_echo_spr <= in_echo_spr_c;
            s1_echo_box    <= echo_box_c;
            s1_m_bx0       <= m_bx[0];
            s1_m_by0       <= m_by[0];
            s1_video_on    <= video_on;
            s1_echo_mode   <= echo_mode;
        end
    end

    wire [11:0] spr_q;
    rom_sp #(.AW(10), .DW(12), .MEM_FILE(SPRITE_FILE)) u_spr (
        .clk(clk), .addr(s1_spr_addr), .q(spr_q));

    // =======================================================================
    //  S2 - memory results + the comparisons that need scat_px / scat_py
    // =======================================================================
    wire [13:0] echo_dx_sq = {7'd0, s1_echo_dx[6:0]} * {7'd0, s1_echo_dx[6:0]};
    wire [13:0] echo_dy_sq = {7'd0, s1_echo_dy[6:0]} * {7'd0, s1_echo_dy[6:0]};
    wire in_echo_circle_c  = s1_echo_box &&
                             (({1'b0, echo_dx_sq} + {1'b0, echo_dy_sq}) <= 15'd9216);

    wire [9:0]  map_p_dx   = (s1_scat_px >= fc_p_px) ? (s1_scat_px - fc_p_px) : (fc_p_px - s1_scat_px);
    wire [9:0]  map_p_dy   = (s1_scat_py >= fc_p_py) ? (s1_scat_py - fc_p_py) : (fc_p_py - s1_scat_py);
    wire [10:0] map_p_dman = {1'b0, map_p_dx} + {1'b0, map_p_dy};

    wire on_drone_c = near_dot(s1_scat_px, s1_scat_py, fc_d0x, fc_d0y, 10'd3) ||
                      near_dot(s1_scat_px, s1_scat_py, fc_d1x, fc_d1y, 10'd3) ||
                      near_dot(s1_scat_px, s1_scat_py, fc_d2x, fc_d2y, 10'd3);
    wire on_dir_c      = near_dot(s1_scat_px, s1_scat_py, fc_dir_px,  fc_dir_py,  10'd1);
    wire on_echo_dir_c = near_dot(s1_px,      s1_py,      fc_edir_px, fc_edir_py, 10'd2);

    reg  [3:0]  s2_tile;
    reg         s2_fog;
    reg  [11:0] s2_spr;
    reg  [5:0]  s2_echo_sx, s2_echo_sy;
    reg  [3:0]  s2_scat_sx, s2_scat_sy;
    reg         s2_echo_oob, s2_in_map, s2_in_echo_spr, s2_in_circle;
    reg         s2_player_core, s2_player_halo, s2_near_illum;
    reg         s2_on_drone, s2_on_dir, s2_on_echo_dir;
    reg         s2_m_bx0, s2_m_by0, s2_video_on, s2_echo_mode;

    always @(posedge clk) begin
        if (rst) begin
            s2_tile <= 4'd0; s2_fog <= 1'b0; s2_spr <= 12'h000;
            s2_echo_sx <= 6'd0; s2_echo_sy <= 6'd0;
            s2_echo_oob <= 1'b0; s2_in_map <= 1'b0; s2_in_echo_spr <= 1'b0;
            s2_in_circle <= 1'b0; s2_player_core <= 1'b0; s2_player_halo <= 1'b0;
            s2_near_illum <= 1'b0; s2_on_drone <= 1'b0; s2_on_dir <= 1'b0;
            s2_on_echo_dir <= 1'b0; s2_m_bx0 <= 1'b0; s2_m_by0 <= 1'b0;
            s2_video_on <= 1'b0; s2_echo_mode <= 1'b0;
        end else if (pix_ce) begin
            s2_tile        <= map_tile;
            s2_fog         <= map_fog;
            s2_spr         <= spr_q;
            s2_echo_sx     <= s1_echo_sx;
            s2_echo_sy     <= s1_echo_sy;
            s2_scat_sx     <= s1_scat_sx;
            s2_scat_sy     <= s1_scat_sy;
            s2_echo_oob    <= s1_echo_oob;
            s2_in_map      <= s1_in_map;
            s2_in_echo_spr <= s1_in_echo_spr;
            s2_in_circle   <= in_echo_circle_c;
            s2_player_core <= (map_p_dx <= 10'd2) && (map_p_dy <= 10'd2);
            s2_player_halo <= (map_p_dx <= 10'd4) && (map_p_dy <= 10'd4);
            s2_near_illum  <= (map_p_dman <= 11'd45);
            s2_on_drone    <= on_drone_c;
            s2_on_dir      <= on_dir_c;
            s2_on_echo_dir <= on_echo_dir_c;
            s2_m_bx0       <= s1_m_bx0;
            s2_m_by0       <= s1_m_by0;
            s2_video_on    <= s1_video_on;
            s2_echo_mode   <= s1_echo_mode;
        end
    end

    // =======================================================================
    //  S3 - colour decision
    // =======================================================================
    wire on_echo_spr = s2_in_echo_spr && (s2_spr != 12'hF0F);

    reg [11:0] s3_rgb;
    always @(posedge clk) begin
        if (rst) begin
            s3_rgb <= 12'h000;
        end else if (pix_ce) begin
            s3_rgb <= 12'h000;
            if (s2_echo_mode) begin
                if (s2_video_on && s2_in_circle) begin
                    if (s2_on_echo_dir) begin
                        s3_rgb <= 12'hFF4;
                    end else if (on_echo_spr) begin
                        s3_rgb <= s2_spr;
                    end else if (s2_echo_oob) begin
                        s3_rgb <= 12'h000;
                    end else begin
                        case (s2_tile)
                            TILE_EMPTY:     s3_rgb <= (s2_echo_sx == 6'd0 || s2_echo_sy == 6'd0) ? 12'h012 : 12'h001;
                            TILE_WALL,
                            TILE_CODE0, TILE_CODE1, TILE_CODE2, TILE_CODE3,
                            TILE_THIN_WALL: s3_rgb <= (s2_echo_sx == 6'd0 || s2_echo_sx == 6'd63 ||
                                                       s2_echo_sy == 6'd0 || s2_echo_sy == 6'd63) ? 12'h123 : 12'h234;
                            TILE_LENS1:     s3_rgb <= (s2_echo_sx >= 6'd20 && s2_echo_sx <= 6'd43 &&
                                                       s2_echo_sy >= 6'd20 && s2_echo_sy <= 6'd43) ? 12'hB91 : 12'h001;
                            TILE_LENS2:     s3_rgb <= (s2_echo_sx >= 6'd20 && s2_echo_sx <= 6'd43 &&
                                                       s2_echo_sy >= 6'd20 && s2_echo_sy <= 6'd43) ? 12'h1B9 : 12'h001;
                            TILE_JAMMING:   s3_rgb <= (s2_echo_sx[2] ^ s2_echo_sy[2]) ? 12'h200 : 12'h100;
                            TILE_DOOR:      s3_rgb <= (s2_echo_sx == 6'd0 || s2_echo_sx == 6'd63 ||
                                                       s2_echo_sy == 6'd0 || s2_echo_sy == 6'd63) ? 12'h161 : 12'h2B2;
                            default:        s3_rgb <= 12'h001;
                        endcase
                    end
                end
            end else if (s2_in_map) begin
                if (!s2_fog) begin
                    s3_rgb <= 12'h000;
                end else if (s2_on_dir) begin
                    s3_rgb <= 12'hFF4;                       // heading spark
                end else if (s2_player_core) begin
                    s3_rgb <= 12'hFFF;                       // player core
                end else if (s2_player_halo) begin
                    s3_rgb <= 12'h4DF;                       // player halo
                end else if (s2_on_drone) begin
                    s3_rgb <= 12'hF60;                       // drone beacon
                end else begin
                    case (s2_tile)
                        TILE_EMPTY:     s3_rgb <= s2_near_illum ? 12'h024 : 12'h012;
                        TILE_WALL,
                        TILE_CODE0, TILE_CODE1,
                        TILE_CODE2, TILE_CODE3: s3_rgb <= 12'h346;
                        TILE_THIN_WALL: s3_rgb <= ((s2_scat_sx >= 4'd5 && s2_scat_sx <= 4'd8) ||
                                                   (s2_scat_sy >= 4'd5 && s2_scat_sy <= 4'd8)) ? 12'h3AF : 12'h124;
                        TILE_LENS1:     s3_rgb <= ((s2_scat_sx >= 4'd4 && s2_scat_sx <= 4'd9) &&
                                                   (s2_scat_sy >= 4'd4 && s2_scat_sy <= 4'd9)) ? 12'hFD2 : 12'h112;
                        TILE_LENS2:     s3_rgb <= ((s2_scat_sx >= 4'd3 && s2_scat_sx <= 4'd10) &&
                                                   (s2_scat_sy >= 4'd3 && s2_scat_sy <= 4'd10)) ? 12'h3FD : 12'h012;
                        TILE_JAMMING:   s3_rgb <= (s2_m_bx0 ^ s2_m_by0) ? 12'h311 : 12'h100;
                        TILE_DOOR:      s3_rgb <= 12'h3E4;
                        default:        s3_rgb <= 12'h012;
                    endcase
                end
            end else if (s2_video_on) begin
                s3_rgb <= 12'h011;                           // subtle outer frame
            end
        end
    end

    // =======================================================================
    //  S4/S5 - delay to the common renderer latency (PIPE_STAGES)
    // =======================================================================
    pix_delay #(.W(12), .N(PIPE_STAGES - 3)) u_tail (
        .clk(clk), .rst(rst), .en(pix_ce), .d(s3_rgb), .q(rgb_out));

endmodule
