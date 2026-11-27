module drone_ctrl (
    input  wire        clk,
    input  wire        rst,
    input  wire        game_reset,
    input  wire        playing,
    input  wire        vblank_pulse,
    input  wire [14:0] player_x,    // Q5.10
    input  wire [14:0] player_y,    // Q5.10
    output reg  [14:0] drone0_x, drone0_y,
    output reg  [14:0] drone1_x, drone1_y,
    output reg  [14:0] drone2_x, drone2_y,
    output wire        drone_near,  // < 4.0 tiles -> audio hum
    output reg         drone_hit    // 1-cycle pulse on collision (with cooldown)
);

    localparam [14:0] SPEED        = 15'd36;    // ~2.1 tiles/sec @ 60Hz
    localparam [14:0] HIT_RAD      = 15'd420;   // ~0.41 tile AABB half-width
    localparam [14:0] NEAR_RAD     = 15'd4096;  // 4.0 tiles

    // Patrol bounds (verified open corridors in 3x3 ASCII_MAP)
    // Drone 0: Hall E Row 12 (y=12.5), x in [12.5 .. 19.5]
    // Drone 1: Hall E Row 16 (y=16.5), x in [12.5 .. 19.5]
    // Drone 2: Pre-H approach Row 26 (y=26.5), x in [11.5 .. 13.5]
    reg dir0, dir1, dir2;
    reg [6:0] invuln_frames;

    function [14:0] abs_diff;
        input [14:0] a, b;
        begin
            abs_diff = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    wire [14:0] dx0 = abs_diff(player_x, drone0_x);
    wire [14:0] dy0 = abs_diff(player_y, drone0_y);
    wire [14:0] dx1 = abs_diff(player_x, drone1_x);
    wire [14:0] dy1 = abs_diff(player_y, drone1_y);
    wire [14:0] dx2 = abs_diff(player_x, drone2_x);
    wire [14:0] dy2 = abs_diff(player_y, drone2_y);

    wire hit_any  = ((dx0 < HIT_RAD)  && (dy0 < HIT_RAD))  ||
                    ((dx1 < HIT_RAD)  && (dy1 < HIT_RAD))  ||
                    ((dx2 < HIT_RAD)  && (dy2 < HIT_RAD));

    assign drone_near = ((dx0 < NEAR_RAD) && (dy0 < NEAR_RAD)) ||
                        ((dx1 < NEAR_RAD) && (dy1 < NEAR_RAD)) ||
                        ((dx2 < NEAR_RAD) && (dy2 < NEAR_RAD));

    always @(posedge clk) begin
        if (rst || game_reset) begin
            drone0_x      <= 15'd12800; // 12.5
            drone0_y      <= 15'd12800; // 12.5
            drone1_x      <= 15'd19968; // 19.5
            drone1_y      <= 15'd16896; // 16.5
            drone2_x      <= 15'd11776; // 11.5
            drone2_y      <= 15'd27136; // 26.5
            dir0          <= 1'b1;
            dir1          <= 1'b0;
            dir2          <= 1'b1;
            invuln_frames <= 7'd0;
            drone_hit     <= 1'b0;
        end else begin
            drone_hit <= 1'b0;
            if (playing && vblank_pulse) begin
                // Update Drone 0
                if (dir0) begin
                    if (drone0_x >= 15'd19968) dir0 <= 1'b0; // 19.5
                    else drone0_x <= drone0_x + SPEED;
                end else begin
                    if (drone0_x <= 15'd12800) dir0 <= 1'b1; // 12.5
                    else drone0_x <= drone0_x - SPEED;
                end

                // Update Drone 1
                if (dir1) begin
                    if (drone1_x >= 15'd19968) dir1 <= 1'b0; // 19.5
                    else drone1_x <= drone1_x + SPEED;
                end else begin
                    if (drone1_x <= 15'd12800) dir1 <= 1'b1; // 12.5
                    else drone1_x <= drone1_x - SPEED;
                end

                // Update Drone 2
                if (dir2) begin
                    if (drone2_x >= 15'd13824) dir2 <= 1'b0; // 13.5
                    else drone2_x <= drone2_x + SPEED;
                end else begin
                    if (drone2_x <= 15'd11776) dir2 <= 1'b1; // 11.5
                    else drone2_x <= drone2_x - SPEED;
                end

                // Collision & post-hit invulnerability cooldown (~2 seconds)
                if (invuln_frames > 7'd0) begin
                    invuln_frames <= invuln_frames - 7'd1;
                end else if (hit_any) begin
                    drone_hit     <= 1'b1;
                    invuln_frames <= 7'd120;
                end
            end
        end
    end

endmodule
