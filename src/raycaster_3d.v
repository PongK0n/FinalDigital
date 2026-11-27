// ============================================================================
// DEPTH - 3D DDA raycaster (FORM 3 - SIGHT) + 4-tile code-wall rendering
//
// ADR-0008 rewrite.  Two separate problems were fixed here:
//
//  1. RAYCAST PHASE (runs during vblank).  The DDA march used to read the tile
//     map asynchronously, so one clock contained: position adder -> 1024:1 ROM
//     mux -> tile decode -> next-state logic.  It is now a two-phase loop
//     (present address / evaluate tile) against the synchronous map, and the
//     perpendicular-distance maths is a clean 4-stage chain
//     (cos -> multiply -> clamp -> 1/d lookup).
//     Worst case 160 cols x 160 steps x 2 = ~52k clocks inside a 144k vblank.
//
//  2. SCANOUT PHASE (runs during the visible frame).  Reading the column
//     buffer used to be a 160:1 mux over 1440 flip-flops, followed - in the
//     SAME clock - by the wall-height subtraction, the 7-way texture-row
//     comparison (with three constant multiplies), the font ROM and the colour
//     decision.  The buffer is now a block RAM and the work is spread over a
//     5-stage pixel pipeline; every renderer in the design uses the same depth
//     so the picture stays aligned.
//
// Column buffer word: {far, tex_u[2:0], side, tile[3:0], half_h[8:0]}
// ============================================================================
module raycaster_3d #(
    // 1 = distance shading + floor/ceiling gradient (ADR-0009).
    // 0 = the flat palette of the original build, bit for bit.
    parameter integer DEPTH_SHADING = 1,
    parameter SIN_FILE = "sin_lut.mem",
    parameter COS_FILE = "cos_lut.mem",
    parameter INV_FILE = "inv_lut.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        vblank_pulse,
    input  wire        pix_ce,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire        video_on,
    input  wire [14:0] player_x,     // Q5.10
    input  wire [14:0] player_y,     // Q5.10
    input  wire [7:0]  player_angle, // 0..255
    input  wire [15:0] secret_bcd,   // 4 BCD digits

    // Tile map read port D (synchronous)
    output wire [4:0]  map_tx,
    output wire [4:0]  map_ty,
    input  wire [3:0]  map_tile,

    output reg  [11:0] rgb_out
);
    `include "depth_pkg.vh"

    // =======================================================================
    //  RAYCAST PHASE
    // =======================================================================
    localparam [3:0] RC_IDLE  = 4'd0,
                     RC_HOLD  = 4'd10,  // let player/drone FSMs finish first
                     RC_SETUP = 4'd1,   // trig ROM settles for this column
                     RC_INIT  = 4'd2,
                     RC_WAIT  = 4'd3,   // map address presented
                     RC_MARCH = 4'd4,   // map tile valid
                     RC_C1    = 4'd5,   // multiply by cos(delta)
                     RC_C2    = 4'd6,   // clamp / shift
                     RC_C3    = 4'd7,   // 1/d ROM lookup
                     RC_CALC  = 4'd8,   // write column buffer
                     RC_NEXT  = 4'd9;

    reg [3:0]  rc_state;
    reg [7:0]  col_idx;       // 0..159
    reg [7:0]  step_cnt;      // 0..160
    reg [14:0] rx, ry;
    reg signed [14:0] step_dx, step_dy;
    reg [7:0]  cur_ray_angle;
    // Pose snapshot: taken once per frame so every column is cast from the
    // same viewpoint.  Previously each column re-read player_x/_y/_angle while
    // player_state was still updating them, which sheared the first columns of
    // the frame whenever the player was moving.
    reg [14:0] ray_px, ray_py;
    reg [7:0]  ray_pa;
    reg [6:0]  rc_hold;
    reg [3:0]  hit_tile;
    reg        hit_side;
    reg [2:0]  hit_tex_u;

    // Angle offset: (col - 80) * 69 >>> 8  (~ +/-30 deg FOV)
    wire signed [8:0]  col_signed = $signed({1'b0, col_idx}) - 9'sd80;
    wire signed [16:0] ang_prod   = col_signed * 9'sd69;
    wire [7:0]         ray_angle  = ray_pa + ang_prod[15:8];

    // Fisheye correction angle
    wire [7:0] delta_ang = cur_ray_angle - ray_pa;

    // --- trig ROMs: port A tracks the ray angle, port B the fisheye delta ---
    wire [9:0] cos_ray_q, cos_del_q, sin_ray_q, sin_unused_q;

    rom_dp #(.AW(8), .DW(10), .MEM_FILE(COS_FILE)) u_cos (
        .clk(clk), .addr_a(ray_angle), .q_a(cos_ray_q),
                   .addr_b(delta_ang), .q_b(cos_del_q));
    rom_dp #(.AW(8), .DW(10), .MEM_FILE(SIN_FILE)) u_sin (
        .clk(clk), .addr_a(ray_angle), .q_a(sin_ray_q),
                   .addr_b(8'd0),      .q_b(sin_unused_q));

    wire signed [9:0] cos_ray = $signed(cos_ray_q);
    wire signed [9:0] sin_ray = $signed(sin_ray_q);
    wire signed [9:0] cos_del = $signed(cos_del_q);

    wire signed [14:0] next_rx_w = $signed({1'b0, rx}) + step_dx;
    wire signed [14:0] next_ry_w = $signed({1'b0, ry}) + step_dy;
    wire [14:0] next_rx = next_rx_w[14:0];
    wire [14:0] next_ry = next_ry_w[14:0];

    assign map_tx = next_rx[14:10];
    assign map_ty = next_ry[14:10];

    wire is_solid_tile = (map_tile == TILE_WALL)      ||
                         (map_tile == TILE_THIN_WALL) ||
                         (map_tile == TILE_DOOR)      ||
                         (map_tile >= TILE_CODE0);

    // Perpendicular distance pipeline
    reg  signed [25:0] prod_r;
    reg  [14:0]        perp_r;
    wire [14:0] raw_dist = {step_cnt[7:0], 6'd0};   // step_cnt * 64
    wire [8:0]  inv_idx  = (perp_r[14:6] == 9'd0) ? 9'd1 : perp_r[14:6];

    wire [8:0] inv_q;
    rom_sp #(.AW(9), .DW(9), .MEM_FILE(INV_FILE)) u_inv (
        .clk(clk), .addr(inv_idx), .q(inv_q));

    // --- column buffer: simple dual-port block RAM -------------------------
    localparam [17:0] COL_DEFAULT = {1'b1, 3'd0, 1'b0, TILE_WALL, 9'd40};

    reg         col_we;
    reg  [7:0]  col_waddr;
    reg  [17:0] col_wdata;
    wire [7:0]  col_raddr;
    wire [17:0] col_q;

    ram_sdp #(.AW(8), .DW(18), .DEPTH(0), .INIT_VAL({46'd0, COL_DEFAULT})) u_colbuf (
        .clk(clk), .we(col_we), .waddr(col_waddr), .wdata(col_wdata),
        .raddr(col_raddr), .q(col_q)
    );

    always @(posedge clk) begin
        if (rst) begin
            rc_state      <= RC_IDLE;
            col_idx       <= 8'd0;
            step_cnt      <= 8'd0;
            rx            <= 15'd0;
            ry            <= 15'd0;
            step_dx       <= 15'sd0;
            step_dy       <= 15'sd0;
            cur_ray_angle <= 8'd0;
            hit_tile      <= TILE_WALL;
            hit_side      <= 1'b0;
            hit_tex_u     <= 3'd0;
            ray_px        <= 15'd0;
            ray_py        <= 15'd0;
            ray_pa        <= 8'd0;
            rc_hold       <= 7'd0;
            prod_r        <= 26'sd0;
            perp_r        <= 15'd0;
            col_we        <= 1'b0;
            col_waddr     <= 8'd0;
            col_wdata     <= COL_DEFAULT;
        end else begin
            col_we <= 1'b0;

            case (rc_state)
                RC_IDLE: begin
                    if (vblank_pulse) begin
                        rc_hold  <= 7'd64;
                        rc_state <= RC_HOLD;
                    end
                end

                // Wait out player_state / drone_ctrl (~16 clocks) so the pose
                // snapshot below is this frame's final position.
                RC_HOLD: begin
                    if (rc_hold == 7'd0) begin
                        ray_px   <= player_x;
                        ray_py   <= player_y;
                        ray_pa   <= player_angle;
                        col_idx  <= 8'd0;
                        rc_state <= RC_SETUP;
                    end else begin
                        rc_hold <= rc_hold - 7'd1;
                    end
                end

                // One idle clock so the trig ROM output matches this column.
                RC_SETUP: rc_state <= RC_INIT;

                RC_INIT: begin
                    rx            <= ray_px;
                    ry            <= ray_py;
                    step_cnt      <= 8'd1;
                    cur_ray_angle <= ray_angle;
                    step_dx       <= $signed({{5{cos_ray[9]}}, cos_ray}) >>> 2; // 64 = 1/16 tile
                    step_dy       <= $signed({{5{sin_ray[9]}}, sin_ray}) >>> 2;
                    hit_tile      <= TILE_WALL;
                    hit_side      <= 1'b0;
                    hit_tex_u     <= 3'd0;
                    rc_state      <= RC_WAIT;
                end

                // map_tx/map_ty track (next_rx,next_ry); tile arrives next clock.
                RC_WAIT: rc_state <= RC_MARCH;

                RC_MARCH: begin
                    if (is_solid_tile || (step_cnt >= 8'd160)) begin
                        hit_tile <= is_solid_tile ? map_tile : TILE_WALL;
                        if (next_rx[14:10] != rx[14:10]) begin
                            hit_side  <= 1'b0;
                            hit_tex_u <= (step_dx < 0) ? (3'd7 - next_ry[9:7]) : next_ry[9:7];
                        end else begin
                            hit_side  <= 1'b1;
                            hit_tex_u <= (step_dy > 0) ? (3'd7 - next_rx[9:7]) : next_rx[9:7];
                        end
                        rc_state <= RC_C1;
                    end else begin
                        rx       <= next_rx;
                        ry       <= next_ry;
                        step_cnt <= step_cnt + 8'd1;
                        rc_state <= RC_WAIT;
                    end
                end

                RC_C1: begin
                    prod_r   <= $signed({1'b0, raw_dist}) * cos_del;
                    rc_state <= RC_C2;
                end

                RC_C2: begin
                    perp_r   <= (prod_r > 0) ? prod_r[22:8] : 15'd64;
                    rc_state <= RC_C3;
                end

                // inv_idx presented to the 1/d ROM; data valid next clock.
                RC_C3: rc_state <= RC_CALC;

                RC_CALC: begin
                    col_we    <= 1'b1;
                    col_waddr <= col_idx;
                    col_wdata <= {(perp_r >= 15'd3584), hit_tex_u, hit_side, hit_tile, inv_q};
                    rc_state  <= RC_NEXT;
                end

                RC_NEXT: begin
                    if (col_idx >= 8'd159) begin
                        rc_state <= RC_IDLE;
                    end else begin
                        col_idx  <= col_idx + 8'd1;
                        rc_state <= RC_SETUP;
                    end
                end

                default: rc_state <= RC_IDLE;
            endcase
        end
    end

    // =======================================================================
    //  SCANOUT PHASE - 5-stage pixel pipeline
    // =======================================================================

    // 8x8 digit font ROM (0..9) for the code walls
    function [7:0] digit_font_row;
        input [3:0] digit;
        input [2:0] row;
        begin
            case (digit)
                4'd0: case (row)
                    3'd0: digit_font_row = 8'b00111100;
                    3'd1: digit_font_row = 8'b01100110;
                    3'd2: digit_font_row = 8'b01101110;
                    3'd3: digit_font_row = 8'b01110110;
                    3'd4: digit_font_row = 8'b01100110;
                    3'd5: digit_font_row = 8'b01100110;
                    3'd6: digit_font_row = 8'b00111100;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd1: case (row)
                    3'd0: digit_font_row = 8'b00011000;
                    3'd1: digit_font_row = 8'b00111000;
                    3'd2: digit_font_row = 8'b00011000;
                    3'd3: digit_font_row = 8'b00011000;
                    3'd4: digit_font_row = 8'b00011000;
                    3'd5: digit_font_row = 8'b00011000;
                    3'd6: digit_font_row = 8'b01111110;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd2: case (row)
                    3'd0: digit_font_row = 8'b00111100;
                    3'd1: digit_font_row = 8'b01100110;
                    3'd2: digit_font_row = 8'b00000110;
                    3'd3: digit_font_row = 8'b00011100;
                    3'd4: digit_font_row = 8'b00110000;
                    3'd5: digit_font_row = 8'b01100000;
                    3'd6: digit_font_row = 8'b01111110;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd3: case (row)
                    3'd0: digit_font_row = 8'b00111100;
                    3'd1: digit_font_row = 8'b01100110;
                    3'd2: digit_font_row = 8'b00000110;
                    3'd3: digit_font_row = 8'b00011100;
                    3'd4: digit_font_row = 8'b00000110;
                    3'd5: digit_font_row = 8'b01100110;
                    3'd6: digit_font_row = 8'b00111100;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd4: case (row)
                    3'd0: digit_font_row = 8'b00001100;
                    3'd1: digit_font_row = 8'b00011100;
                    3'd2: digit_font_row = 8'b00101100;
                    3'd3: digit_font_row = 8'b01001100;
                    3'd4: digit_font_row = 8'b01111110;
                    3'd5: digit_font_row = 8'b00001100;
                    3'd6: digit_font_row = 8'b00001100;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd5: case (row)
                    3'd0: digit_font_row = 8'b01111110;
                    3'd1: digit_font_row = 8'b01100000;
                    3'd2: digit_font_row = 8'b01111100;
                    3'd3: digit_font_row = 8'b00000110;
                    3'd4: digit_font_row = 8'b00000110;
                    3'd5: digit_font_row = 8'b01100110;
                    3'd6: digit_font_row = 8'b00111100;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd6: case (row)
                    3'd0: digit_font_row = 8'b00111100;
                    3'd1: digit_font_row = 8'b01100000;
                    3'd2: digit_font_row = 8'b01111100;
                    3'd3: digit_font_row = 8'b01100110;
                    3'd4: digit_font_row = 8'b01100110;
                    3'd5: digit_font_row = 8'b01100110;
                    3'd6: digit_font_row = 8'b00111100;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd7: case (row)
                    3'd0: digit_font_row = 8'b01111110;
                    3'd1: digit_font_row = 8'b00000110;
                    3'd2: digit_font_row = 8'b00001100;
                    3'd3: digit_font_row = 8'b00011000;
                    3'd4: digit_font_row = 8'b00110000;
                    3'd5: digit_font_row = 8'b00110000;
                    3'd6: digit_font_row = 8'b00110000;
                    default: digit_font_row = 8'b00000000;
                endcase
                4'd8: case (row)
                    3'd0: digit_font_row = 8'b00111100;
                    3'd1: digit_font_row = 8'b01100110;
                    3'd2: digit_font_row = 8'b01100110;
                    3'd3: digit_font_row = 8'b00111100;
                    3'd4: digit_font_row = 8'b01100110;
                    3'd5: digit_font_row = 8'b01100110;
                    3'd6: digit_font_row = 8'b00111100;
                    default: digit_font_row = 8'b00000000;
                endcase
                default: case (row) // 9
                    3'd0: digit_font_row = 8'b00111100;
                    3'd1: digit_font_row = 8'b01100110;
                    3'd2: digit_font_row = 8'b01100110;
                    3'd3: digit_font_row = 8'b00111110;
                    3'd4: digit_font_row = 8'b00000110;
                    3'd5: digit_font_row = 8'b00000110;
                    3'd6: digit_font_row = 8'b00111100;
                    default: digit_font_row = 8'b00000000;
                endcase
            endcase
        end
    endfunction

    // ---- S1: column address ------------------------------------------------
    reg [7:0] s1_col;
    always @(posedge clk) begin
        if (rst)          s1_col <= 8'd0;
        else if (pix_ce)  s1_col <= pixel_x[9:2];      // 0..159
    end
    assign col_raddr = s1_col;

    // pixel_y / video_on travel alongside the pipeline
    wire [9:0] py_s2, px_s2;
    wire       von_s4;
    pix_delay #(.W(10), .N(2)) u_dly_py  (.clk(clk), .rst(rst), .en(pix_ce), .d(pixel_y),  .q(py_s2));
    pix_delay #(.W(10), .N(2)) u_dly_px  (.clk(clk), .rst(rst), .en(pix_ce), .d(pixel_x),  .q(px_s2));
    pix_delay #(.W(1),  .N(4)) u_dly_von (.clk(clk), .rst(rst), .en(pix_ce), .d(video_on), .q(von_s4));

    // ---- S2: latch the column buffer word ----------------------------------
    reg [17:0] s2_col;
    always @(posedge clk) begin
        if (rst)         s2_col <= COL_DEFAULT;
        else if (pix_ce) s2_col <= col_q;
    end

    wire [8:0] d_half_h = s2_col[8:0];
    wire [3:0] d_tile   = s2_col[12:9];
    wire       d_side   = s2_col[13];
    wire [2:0] d_tex_u  = s2_col[16:14];
    wire       d_far    = s2_col[17];

    wire [9:0] y_top   = 10'd240 - {1'b0, d_half_h};
    wire [9:0] y_bot   = 10'd240 + {1'b0, d_half_h};
    wire       in_wall = (py_s2 >= y_top) && (py_s2 < y_bot);

    wire [3:0] code_digit = (d_tile == TILE_CODE0) ? secret_bcd[15:12] :
                            (d_tile == TILE_CODE1) ? secret_bcd[11:8]  :
                            (d_tile == TILE_CODE2) ? secret_bcd[7:4]   :
                                                     secret_bcd[3:0];

    // ---- S3: wall geometry -------------------------------------------------
    reg  [9:0] s3_rel_y;
    reg  [8:0] s3_half_h;
    reg  [3:0] s3_tile, s3_digit;
    reg        s3_side, s3_far, s3_in_wall;
    reg  [2:0] s3_tex_u;
    reg  [9:0] s3_py;
    reg        s3_px0;

    always @(posedge clk) begin
        if (rst) begin
            s3_rel_y <= 10'd0; s3_half_h <= 9'd40; s3_tile <= TILE_WALL;
            s3_digit <= 4'd0;  s3_side <= 1'b0;    s3_far  <= 1'b1;
            s3_in_wall <= 1'b0; s3_tex_u <= 3'd0;  s3_py   <= 10'd0;
            s3_px0 <= 1'b0;
        end else if (pix_ce) begin
            s3_px0     <= px_s2[0];
            s3_rel_y   <= py_s2 - y_top;
            s3_half_h  <= d_half_h;
            s3_tile    <= d_tile;
            s3_digit   <= code_digit;
            s3_side    <= d_side;
            s3_far     <= d_far;
            s3_in_wall <= in_wall;
            s3_tex_u   <= d_tex_u;
            s3_py      <= py_s2;
        end
    end

    // ---- S4: texture row (rel_y * 4 / half_h, no divider) ------------------
    wire [11:0] rel_y_x4 = {s3_rel_y, 2'b00};
    wire [11:0] h1 = {3'd0, s3_half_h};
    wire [11:0] h2 = {2'd0, s3_half_h, 1'b0};
    wire [11:0] h4 = {1'b0, s3_half_h, 2'b00};
    wire [11:0] h3 = h1 + h2;
    wire [11:0] h5 = h4 + h1;
    wire [11:0] h6 = h4 + h2;
    wire [11:0] h7 = h4 + h3;

    wire [2:0] tex_v_c = (rel_y_x4 < h1) ? 3'd0 :
                         (rel_y_x4 < h2) ? 3'd1 :
                         (rel_y_x4 < h3) ? 3'd2 :
                         (rel_y_x4 < h4) ? 3'd3 :
                         (rel_y_x4 < h5) ? 3'd4 :
                         (rel_y_x4 < h6) ? 3'd5 :
                         (rel_y_x4 < h7) ? 3'd6 : 3'd7;

    reg [2:0] s4_tex_v, s4_tex_u;
    reg [3:0] s4_tile, s4_digit;
    reg       s4_side, s4_far, s4_in_wall;
    reg [9:0] s4_py;
    reg       s4_px0;
    reg [1:0] s4_shade;

    // Distance shading level straight from the wall height: a tall column is
    // a near wall.  half_h 112 ~ 1.4 tiles, 56 ~ 2.9 tiles, 30 ~ 5.3 tiles.
    wire [1:0] shade_c = (s3_half_h >= 9'd112) ? 2'd0 :
                         (s3_half_h >= 9'd56)  ? 2'd1 :
                         (s3_half_h >= 9'd30)  ? 2'd2 : 2'd3;

    always @(posedge clk) begin
        if (rst) begin
            s4_tex_v <= 3'd0; s4_tex_u <= 3'd0; s4_tile <= TILE_WALL;
            s4_digit <= 4'd0; s4_side  <= 1'b0; s4_far  <= 1'b1;
            s4_in_wall <= 1'b0; s4_py  <= 10'd0; s4_shade <= 2'd0; s4_px0 <= 1'b0;
        end else if (pix_ce) begin
            s4_shade   <= shade_c;
            s4_px0     <= s3_px0;
            s4_tex_v   <= tex_v_c;
            s4_tex_u   <= s3_tex_u;
            s4_tile    <= s3_tile;
            s4_digit   <= s3_digit;
            s4_side    <= s3_side;
            s4_far     <= s3_far;
            s4_in_wall <= s3_in_wall;
            s4_py      <= s3_py;
        end
    end

    // ---- S5: font + colour -------------------------------------------------
    wire [7:0] font_bits = digit_font_row(s4_digit, s4_tex_v);
    wire       font_on   = font_bits[3'd7 - s4_tex_u];

    // Floor / ceiling depth gradient.
    // Band 0 is the horizon, band 7 the top of the screen (or the player's
    // feet).  A 2x2 ordered dither mixes each band with the next one over its
    // second half, which hides the hard steps a 4-bit-per-channel palette
    // would otherwise show.
    wire [7:0] horiz_d  = (s4_py < 10'd240) ? (10'd239 - s4_py) : (s4_py - 10'd240);
    wire       dith     = s4_px0 ^ s4_py[0];
    wire [2:0] band_raw = horiz_d[7:5];
    wire [2:0] band     = (horiz_d[4] & dith & (band_raw != 3'd7)) ? (band_raw + 3'd1) : band_raw;

    function [11:0] ceiling_rgb;
        input [2:0] b;
        begin
            case (b)
                3'd0: ceiling_rgb = 12'h223;
                3'd1: ceiling_rgb = 12'h122;
                3'd2: ceiling_rgb = 12'h112;
                3'd3: ceiling_rgb = 12'h112;
                3'd4: ceiling_rgb = 12'h011;
                3'd5: ceiling_rgb = 12'h011;
                3'd6: ceiling_rgb = 12'h001;
                default: ceiling_rgb = 12'h001;
            endcase
        end
    endfunction

    function [11:0] floor_rgb;
        input [2:0] b;
        begin
            case (b)
                3'd0: floor_rgb = 12'h122;
                3'd1: floor_rgb = 12'h222;
                3'd2: floor_rgb = 12'h222;
                3'd3: floor_rgb = 12'h233;
                3'd4: floor_rgb = 12'h333;
                3'd5: floor_rgb = 12'h333;
                3'd6: floor_rgb = 12'h344;
                default: floor_rgb = 12'h445;
            endcase
        end
    endfunction

    reg [11:0] s5_rgb;
    reg [1:0]  s5_shade;
    reg        s5_on;

    always @(posedge clk) begin
        if (rst) begin
            s5_rgb <= 12'h000; s5_shade <= 2'd0; s5_on <= 1'b0;
        end else if (pix_ce) begin
            s5_on    <= von_s4;
            s5_shade <= 2'd0;
            if (!von_s4) begin
                s5_rgb <= 12'h000;
            end else if (!s4_in_wall) begin
                if (DEPTH_SHADING != 0)
                    s5_rgb <= (s4_py < 10'd240) ? ceiling_rgb(band)
                                                : floor_rgb(band);
                else
                    s5_rgb <= (s4_py < 10'd240) ? 12'h112 : 12'h222;
            end else begin
                s5_shade <= s4_shade;
                case (s4_tile)
                    TILE_THIN_WALL: s5_rgb <= s4_side ? 12'h626 : 12'h838;
                    TILE_DOOR:      s5_rgb <= s4_side ? 12'hA71 : 12'hEA2;
                    TILE_CODE0,
                    TILE_CODE1,
                    TILE_CODE2,
                    TILE_CODE3: begin
                        if (s4_far) begin
                            s5_rgb <= (s4_tex_u[0] ^ s4_tex_v[0]) ? 12'h466 : 12'h233;
                        end else begin
                            s5_rgb <= font_on ? 12'h0FF : 12'h123;
                        end
                    end
                    default: begin // TILE_WALL
                        if (s4_tex_v == 3'd0 || s4_tex_v == 3'd7)
                            s5_rgb <= 12'h134;
                        else
                            s5_rgb <= s4_side ? 12'h268 : 12'h38B;
                    end
                endcase
            end
        end
    end

    // ---- S6: distance attenuation -----------------------------------------
    // Per 4-bit channel, using shifts and one add - no multiplier, no DSP.
    //   level 0 = x1      level 1 = x3/4
    //   level 2 = x5/8    level 3 = x3/8
    function [3:0] atten;
        input [3:0] c;
        input [1:0] lvl;
        begin
            case (lvl)
                2'd0: atten = c;
                2'd1: atten = c - (c >> 2);
                2'd2: atten = (c >> 1) + (c >> 3);
                default: atten = (c >> 1) - (c >> 3);
            endcase
        end
    endfunction

    wire [11:0] shaded_rgb = {atten(s5_rgb[11:8], s5_shade),
                              atten(s5_rgb[7:4],  s5_shade),
                              atten(s5_rgb[3:0],  s5_shade)};

    always @(posedge clk) begin
        if (rst)         rgb_out <= 12'h000;
        else if (pix_ce) rgb_out <= (DEPTH_SHADING != 0) ? shaded_rgb : s5_rgb;
    end

endmodule
