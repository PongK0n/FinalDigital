// ============================================================================
// DEPTH - player kinematics, wall-sliding collision and BTNC interaction
//
// ADR-0008 changes (behaviour-preserving):
//   * tile_map read port A is now SYNCHRONOUS, so the collision walk is
//     re-timed: address is presented one state earlier and the tile is tested
//     one state later.  The same four corners are tested in the same order and
//     the player ends up at exactly the same coordinate as before.
//   * sin/cos are block ROMs with a registered output instead of an async LUT
//     mux feeding the 15-bit position adders.
//   The whole walk still finishes in ~16 clocks, inside a 1.68 M-clock frame.
// ============================================================================
module player_state #(
    parameter SIN_FILE = "sin_lut.mem",
    parameter COS_FILE = "cos_lut.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        game_reset,
    input  wire        playing,
    input  wire        vblank_pulse,
    input  wire [4:0]  btn_clean,       // {BTNC, BTND, BTNR, BTNL, BTNU}
    input  wire        btn_c_pulse,
    input  wire [1:0]  active_form,
    input  wire        lens1_collected,
    input  wire        lens2_collected,
    input  wire        thin_wall_opened,
    input  wire        drone_hit_pulse,

    // Read port A on tile_map (synchronous: tile valid one clock after addr)
    output reg  [4:0]  map_tx,
    output reg  [4:0]  map_ty,
    input  wire [3:0]  map_tile,

    output reg  [14:0] player_x,        // Q5.10
    output reg  [14:0] player_y,        // Q5.10
    output reg  [7:0]  player_angle,    // 0..255
    output reg         in_jamming,
    output wire        near_door,
    output reg         collect_lens1,
    output reg         collect_lens2,
    output reg         open_thin_wall
);
    `include "depth_pkg.vh"

    localparam [14:0] RADIUS = 15'd240; // ~0.23 tile half-width

    // ---- trig: registered block ROM reads ---------------------------------
    wire [9:0] cos_q, sin_q;
    rom_sp #(.AW(8), .DW(10), .MEM_FILE(COS_FILE)) u_cos (.clk(clk), .addr(player_angle), .q(cos_q));
    rom_sp #(.AW(8), .DW(10), .MEM_FILE(SIN_FILE)) u_sin (.clk(clk), .addr(player_angle), .q(sin_q));

    wire signed [9:0] cos_v = $signed(cos_q);
    wire signed [9:0] sin_v = $signed(sin_q);
    // Speed ~0.125 tiles/frame (7.5 tiles/sec @ 60 Hz): cos_v / 2
    wire signed [14:0] step_dx = $signed({{5{cos_v[9]}}, cos_v}) >>> 1;
    wire signed [14:0] step_dy = $signed({{5{sin_v[9]}}, sin_v}) >>> 1;

    function is_solid;
        input [3:0] t;
        begin
            is_solid = (t == TILE_WALL) || (t == TILE_THIN_WALL) || (t == TILE_DOOR) || t[3];
        end
    endfunction

    function [14:0] abs_diff;
        input [14:0] a, b;
        begin
            abs_diff = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    // Landmark centers in Q5.10
    localparam [14:0] L1_CX   = {LENS1_TX, 10'd512};
    localparam [14:0] L1_CY   = {LENS1_TY, 10'd512};
    localparam [14:0] L2_CX   = {LENS2_TX, 10'd512};
    localparam [14:0] L2_CY   = {LENS2_TY, 10'd512};
    localparam [14:0] THIN_CX = {THIN_TX,  10'd512};
    localparam [14:0] THIN_CY = {THIN_TY,  10'd512};
    localparam [14:0] DOOR_CX = {DOOR_TX,  10'd512};
    localparam [14:0] DOOR_CY = {DOOR_TY,  10'd512};

    wire near_lens1 = (abs_diff(player_x, L1_CX)   < 15'd768)  && (abs_diff(player_y, L1_CY)   < 15'd768);
    wire near_lens2 = (abs_diff(player_x, L2_CX)   < 15'd768)  && (abs_diff(player_y, L2_CY)   < 15'd768);
    wire near_thin  = (abs_diff(player_x, THIN_CX) < 15'd1280) && (abs_diff(player_y, THIN_CY) < 15'd1280);
    assign near_door = (abs_diff(player_x, DOOR_CX) < 15'd1280) && (abs_diff(player_y, DOOR_CY) < 15'd1280);

    // ---- collision / movement walk ----------------------------------------
    reg [3:0]  step;
    reg [14:0] cand_x, cand_y;
    reg        x_blocked, y_blocked;

    wire btn_u = btn_clean[0];
    wire btn_l = btn_clean[1];
    wire btn_r = btn_clean[2];
    wire btn_d = btn_clean[3];

    wire [14:0] xm  = (player_x > RADIUS) ? (player_x - RADIUS) : 15'd0;
    wire [14:0] xp  = player_x + RADIUS;
    wire [14:0] ym  = (player_y > RADIUS) ? (player_y - RADIUS) : 15'd0;
    wire [14:0] yp  = player_y + RADIUS;
    wire [14:0] cxm = (cand_x > RADIUS) ? (cand_x - RADIUS) : 15'd0;
    wire [14:0] cxp = cand_x + RADIUS;
    wire [14:0] cym = (cand_y > RADIUS) ? (cand_y - RADIUS) : 15'd0;
    wire [14:0] cyp = cand_y + RADIUS;

    task set_addr;
        input [14:0] ax, ay;
        begin
            map_tx <= ax[14:10];
            map_ty <= ay[14:10];
        end
    endtask

    always @(posedge clk) begin
        if (rst || game_reset) begin
            player_x       <= SPAWN_X;
            player_y       <= SPAWN_Y;
            player_angle   <= SPAWN_ANGLE;
            in_jamming     <= 1'b0;
            collect_lens1  <= 1'b0;
            collect_lens2  <= 1'b0;
            open_thin_wall <= 1'b0;
            step           <= 4'd0;
            map_tx         <= SPAWN_X[14:10];
            map_ty         <= SPAWN_Y[14:10];
            cand_x         <= SPAWN_X;
            cand_y         <= SPAWN_Y;
            x_blocked      <= 1'b0;
            y_blocked      <= 1'b0;
        end else begin
            collect_lens1  <= 1'b0;
            collect_lens2  <= 1'b0;
            open_thin_wall <= 1'b0;

            if (playing) begin
                if (near_lens1 && !lens1_collected && !collect_lens1)
                    collect_lens1 <= 1'b1;
                if (near_lens2 && !lens2_collected && !collect_lens2)
                    collect_lens2 <= 1'b1;
                if (btn_c_pulse && near_thin && !thin_wall_opened && (active_form == FORM_MAP))
                    open_thin_wall <= 1'b1;
            end

            if (drone_hit_pulse) begin
                player_x     <= SPAWN_X;
                player_y     <= SPAWN_Y;
                player_angle <= SPAWN_ANGLE;
                in_jamming   <= 1'b0;
                step         <= 4'd0;
            end else if (playing) begin
                case (step)
                    // ---- frame start: rotate + propose a move -------------
                    4'd0: begin
                        if (vblank_pulse) begin
                            if (btn_l && !btn_r)      player_angle <= player_angle - 8'd3;
                            else if (btn_r && !btn_l) player_angle <= player_angle + 8'd3;

                            if (btn_u && !btn_d) begin
                                cand_x <= $unsigned($signed({1'b0, player_x}) + $signed({step_dx[14], step_dx}));
                                cand_y <= $unsigned($signed({1'b0, player_y}) + $signed({step_dy[14], step_dy}));
                            end else if (btn_d && !btn_u) begin
                                cand_x <= $unsigned($signed({1'b0, player_x}) - $signed({step_dx[14], step_dx}));
                                cand_y <= $unsigned($signed({1'b0, player_y}) - $signed({step_dy[14], step_dy}));
                            end else begin
                                cand_x <= player_x;
                                cand_y <= player_y;
                            end
                            x_blocked <= 1'b0;
                            y_blocked <= 1'b0;
                            step      <= 4'd1;
                        end
                    end

                    // ---- X move: 4 corners, addresses run 2 states ahead ---
                    4'd1: begin set_addr(cxm, ym); step <= 4'd2; end
                    4'd2: begin set_addr(cxp, ym); step <= 4'd3; end
                    4'd3: begin                                   // tile(cxm,ym)
                        if (is_solid(map_tile)) x_blocked <= 1'b1;
                        set_addr(cxm, yp); step <= 4'd4;
                    end
                    4'd4: begin                                   // tile(cxp,ym)
                        if (is_solid(map_tile)) x_blocked <= 1'b1;
                        set_addr(cxp, yp); step <= 4'd5;
                    end
                    4'd5: begin                                   // tile(cxm,yp)
                        if (is_solid(map_tile)) x_blocked <= 1'b1;
                        step <= 4'd6;
                    end
                    4'd6: begin                                   // tile(cxp,yp)
                        if (!x_blocked && !is_solid(map_tile))
                            player_x <= cand_x;
                        step <= 4'd7;
                    end

                    // ---- Y move: 4 corners against the updated player_x ----
                    4'd7: begin set_addr(xm, cym); step <= 4'd8; end
                    4'd8: begin set_addr(xp, cym); step <= 4'd9; end
                    4'd9: begin
                        if (is_solid(map_tile)) y_blocked <= 1'b1;
                        set_addr(xm, cyp); step <= 4'd10;
                    end
                    4'd10: begin
                        if (is_solid(map_tile)) y_blocked <= 1'b1;
                        set_addr(xp, cyp); step <= 4'd11;
                    end
                    4'd11: begin
                        if (is_solid(map_tile)) y_blocked <= 1'b1;
                        step <= 4'd12;
                    end
                    4'd12: begin
                        if (!y_blocked && !is_solid(map_tile))
                            player_y <= cand_y;
                        step <= 4'd13;
                    end

                    // ---- sample the tile under the player (JAMMING_ZONE) ---
                    4'd13: begin set_addr(player_x, player_y); step <= 4'd14; end
                    4'd14: begin step <= 4'd15; end
                    4'd15: begin
                        in_jamming <= (map_tile == TILE_JAMMING);
                        step       <= 4'd0;
                    end

                    default: step <= 4'd0;
                endcase
            end
        end
    end

endmodule
