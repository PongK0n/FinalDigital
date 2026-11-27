// ============================================================================
// DEPTH - 4-ray acoustic sonar (front / left / right / back), run in vblank
//
// ADR-0008: tile_map read port B is now synchronous, so the march became a
// two-phase loop (present address -> evaluate tile).  Worst case is
// 4 rays x 128 steps x 2 = ~1030 clocks, against a ~144,000-clock vertical
// blanking window, so the sonar still finishes long before the frame starts.
// Distances produced are bit-identical to the previous version.
// ============================================================================
module radar_1d #(
    parameter SIN_FILE = "sin_lut.mem",
    parameter COS_FILE = "cos_lut.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        vblank_pulse,
    input  wire [14:0] player_x,      // Q5.10
    input  wire [14:0] player_y,      // Q5.10
    input  wire [7:0]  player_angle,  // 0..255

    // Read port B on tile_map (synchronous)
    output wire [4:0]  map_tx,
    output wire [4:0]  map_ty,
    input  wire [3:0]  map_tile,

    output reg  [14:0] dist_front,    // Q5.10
    output reg  [14:0] dist_left,
    output reg  [14:0] dist_right,
    output reg  [14:0] dist_back
);
    `include "depth_pkg.vh"

    function is_wall;
        input [3:0] t;
        begin
            is_wall = (t == TILE_WALL) || (t == TILE_THIN_WALL) || (t == TILE_DOOR) || t[3];
        end
    endfunction

    localparam [2:0] S_IDLE = 3'd0, S_HOLD = 3'd1, S_LOAD = 3'd2,
                     S_WAIT = 3'd3, S_EVAL = 3'd4;

    reg [2:0]  state;
    // Pose snapshot (ADR-0009).  The sonar starts on the same vblank pulse
    // that makes player_state recompute the position, so without this the
    // four rays could be cast from two different player positions within one
    // frame - the left/right distances then disagreed with the front one.
    reg [14:0] rp_x, rp_y;
    reg [7:0]  rp_a;
    reg [6:0]  hold_cnt;
    reg [1:0]  ray_idx;     // 0=front, 1=left(-64), 2=right(+64), 3=back(+128)
    reg [7:0]  march_step;  // 0..127 (each step = 0.125 tile = 128 Q5.10 units)
    reg [15:0] rx, ry;      // Q6.10 unsigned (bit 15 detects out-of-bounds)

    wire [7:0] ray_angle = (ray_idx == 2'd0) ? rp_a :
                           (ray_idx == 2'd1) ? (rp_a - 8'd64) :
                           (ray_idx == 2'd2) ? (rp_a + 8'd64) :
                                               (rp_a + 8'd128);

    // Registered trig reads (block ROM) - settled during S_LOAD/S_WAIT.
    wire [9:0] cos_q, sin_q;
    rom_sp #(.AW(8), .DW(10), .MEM_FILE(COS_FILE)) u_cos (.clk(clk), .addr(ray_angle), .q(cos_q));
    rom_sp #(.AW(8), .DW(10), .MEM_FILE(SIN_FILE)) u_sin (.clk(clk), .addr(ray_angle), .q(sin_q));

    wire signed [9:0] cos_v = $signed(cos_q);
    wire signed [9:0] sin_v = $signed(sin_q);
    // Step size = 0.125 tile => cos_v (Q1.8, 256 = 1.0) / 2 = 128 in Q5.10
    wire signed [15:0] step_dx = $signed({{6{cos_v[9]}}, cos_v}) >>> 1;
    wire signed [15:0] step_dy = $signed({{6{sin_v[9]}}, sin_v}) >>> 1;

    assign map_tx = rx[14:10];
    assign map_ty = ry[14:10];

    wire [14:0] cur_dist = {march_step[6:0], 7'd0}; // march_step * 128

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            ray_idx    <= 2'd0;
            march_step <= 8'd0;
            rx         <= 16'd0;
            ry         <= 16'd0;
            rp_x       <= 15'd0;
            rp_y       <= 15'd0;
            rp_a       <= 8'd0;
            hold_cnt   <= 7'd0;
            dist_front <= 15'd8192;
            dist_left  <= 15'd8192;
            dist_right <= 15'd8192;
            dist_back  <= 15'd8192;
        end else begin
            case (state)
                S_IDLE: begin
                    if (vblank_pulse) begin
                        hold_cnt <= 7'd64;
                        state    <= S_HOLD;
                    end
                end

                // Let player_state finish this frame's move (~16 clocks),
                // then freeze the pose all four rays are cast from.
                S_HOLD: begin
                    if (hold_cnt == 7'd0) begin
                        rp_x    <= player_x;
                        rp_y    <= player_y;
                        rp_a    <= player_angle;
                        ray_idx <= 2'd0;
                        state   <= S_LOAD;
                    end else begin
                        hold_cnt <= hold_cnt - 7'd1;
                    end
                end

                // Reload the ray origin; trig ROM output settles here.
                S_LOAD: begin
                    march_step <= 8'd0;
                    rx         <= {1'b0, rp_x};
                    ry         <= {1'b0, rp_y};
                    state      <= S_WAIT;
                end

                // Address (rx,ry) is on the tile ROM this cycle; data next cycle.
                S_WAIT: state <= S_EVAL;

                S_EVAL: begin
                    if (rx[15] || ry[15] || is_wall(map_tile) || (march_step == 8'd127)) begin
                        case (ray_idx)
                            2'd0: dist_front <= cur_dist;
                            2'd1: dist_left  <= cur_dist;
                            2'd2: dist_right <= cur_dist;
                            2'd3: dist_back  <= cur_dist;
                        endcase
                        if (ray_idx == 2'd3) begin
                            state <= S_IDLE;
                        end else begin
                            ray_idx <= ray_idx + 2'd1;
                            state   <= S_LOAD;
                        end
                    end else begin
                        rx         <= $unsigned($signed(rx) + step_dx);
                        ry         <= $unsigned($signed(ry) + step_dy);
                        march_step <= march_step + 8'd1;
                        state      <= S_WAIT;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
