// ============================================================================
// DEPTH - 32x32 maze world state (ADR-0008 rewrite)
//
// What changed vs. the first board export, and why:
//   * The 1024-entry tile ROM used to be read ASYNCHRONOUSLY on four ports at
//     once.  Each read was a 1024:1 LUT mux (~5 logic levels) sitting inside a
//     100 MHz path, and it was duplicated four times.  It is now two dual-port
//     block ROMs with REGISTERED outputs: 2 x RAMB18 instead of ~250 LUTs, and
//     the combinational depth drops to a single 4-bit decode.
//   * fog_bitmap used to be 1024 flip-flops read through a 1024:1 mux.  It is
//     now a block RAM with a registered read port and a small write engine.
//
// Read-port contract (ALL FOUR PORTS):  present the address on cycle N, the
// tile (and fog) are valid on cycle N+1.
// ============================================================================
module tile_map #(
    parameter MEM_FILE = "tile_map.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        game_reset,       // Reset world on new game (TITLE -> PLAY)
    input  wire        vblank_pulse,     // Reveal fog around player each frame
    input  wire [4:0]  player_tx,
    input  wire [4:0]  player_ty,
    input  wire        collect_lens1,
    input  wire        collect_lens2,
    input  wire        open_thin_wall,
    input  wire        drone_hit_pulse,  // ADR-0003: respawn top lens & reset fog

    output reg         lens1_collected,
    output reg         lens2_collected,
    output reg         thin_wall_opened,

    // Four concurrent SYNCHRONOUS read ports (data valid one clock after addr)
    input  wire [4:0]  rd_a_tx,
    input  wire [4:0]  rd_a_ty,
    output wire [3:0]  rd_a_tile,

    input  wire [4:0]  rd_b_tx,
    input  wire [4:0]  rd_b_ty,
    output wire [3:0]  rd_b_tile,

    input  wire [4:0]  rd_c_tx,
    input  wire [4:0]  rd_c_ty,
    output wire [3:0]  rd_c_tile,
    output wire        rd_c_fog,

    input  wire [4:0]  rd_d_tx,
    input  wire [4:0]  rd_d_ty,
    output wire [3:0]  rd_d_tile
);
    `include "depth_pkg.vh"

    // ---------------- tile ROM: 2 dual-port block ROMs = 4 read ports -------
    wire [3:0] raw_a, raw_b, raw_c, raw_d;

    rom_dp #(.AW(10), .DW(4), .MEM_FILE(MEM_FILE)) u_rom_ab (
        .clk(clk),
        .addr_a({rd_a_ty, rd_a_tx}), .q_a(raw_a),
        .addr_b({rd_b_ty, rd_b_tx}), .q_b(raw_b)
    );

    rom_dp #(.AW(10), .DW(4), .MEM_FILE(MEM_FILE)) u_rom_cd (
        .clk(clk),
        .addr_a({rd_c_ty, rd_c_tx}), .q_a(raw_c),
        .addr_b({rd_d_ty, rd_d_tx}), .q_b(raw_d)
    );

    // Dynamic overlay (lens pickups / opened thin wall) applied AFTER the
    // register: 4-bit compare only, one logic level.
    function [3:0] effective_tile;
        input [3:0] raw_t;
        input       l1_done;
        input       l2_done;
        input       thin_open;
        begin
            if      (raw_t == TILE_THIN_WALL && thin_open) effective_tile = TILE_EMPTY;
            else if (raw_t == TILE_LENS1     && l1_done)   effective_tile = TILE_EMPTY;
            else if (raw_t == TILE_LENS2     && l2_done)   effective_tile = TILE_EMPTY;
            else                                           effective_tile = raw_t;
        end
    endfunction

    assign rd_a_tile = effective_tile(raw_a, lens1_collected, lens2_collected, thin_wall_opened);
    assign rd_b_tile = effective_tile(raw_b, lens1_collected, lens2_collected, thin_wall_opened);
    assign rd_c_tile = effective_tile(raw_c, lens1_collected, lens2_collected, thin_wall_opened);
    assign rd_d_tile = effective_tile(raw_d, lens1_collected, lens2_collected, thin_wall_opened);

    // ---------------- fog bitmap: block RAM + write engine ------------------
    // Clear  : 1024 cycles (reset / new game / drone hit)
    // Reveal : 25 cycles, a 5x5 square around the player, started by vblank.
    // Both run deep inside the vertical blanking interval (~144k clocks), so
    // the visible frame never sees a half-finished update.
    localparam [1:0] FOG_IDLE = 2'd0, FOG_CLEAR = 2'd1, FOG_REVEAL = 2'd2;

    reg [1:0]  fog_st;
    reg [9:0]  fog_clr_idx;
    reg [2:0]  rev_ix, rev_iy;    // 0..4 each (5x5 reveal square)
    reg        fog_we;
    reg [9:0]  fog_waddr;
    reg        fog_wdata;

    ram_sdp #(.AW(10), .DW(1), .INIT_VAL(64'd0)) u_fog (
        .clk(clk), .we(fog_we), .waddr(fog_waddr), .wdata(fog_wdata),
        .raddr({rd_c_ty, rd_c_tx}), .q(rd_c_fog)
    );

    // 5x5 offsets from two small counters (no divider, no modulo)
    wire signed [3:0] rev_dx = $signed({1'b0, rev_ix}) - 4'sd2;
    wire signed [3:0] rev_dy = $signed({1'b0, rev_iy}) - 4'sd2;
    wire signed [6:0] rev_tx = $signed({2'b00, player_tx}) + rev_dx;
    wire signed [6:0] rev_ty = $signed({2'b00, player_ty}) + rev_dy;
    wire              rev_ok = (rev_tx >= 7'sd0) && (rev_tx < 7'sd32) &&
                               (rev_ty >= 7'sd0) && (rev_ty < 7'sd32);

    always @(posedge clk) begin
        if (rst) begin
            lens1_collected  <= 1'b0;
            lens2_collected  <= 1'b0;
            thin_wall_opened <= 1'b0;
            fog_st           <= FOG_CLEAR;
            fog_clr_idx      <= 10'd0;
            rev_ix           <= 3'd0;
            rev_iy           <= 3'd0;
            fog_we           <= 1'b0;
            fog_waddr        <= 10'd0;
            fog_wdata        <= 1'b0;
        end else begin
            fog_we <= 1'b0;

            // ---- world flags (unchanged behaviour) ----
            if (game_reset) begin
                lens1_collected  <= 1'b0;
                lens2_collected  <= 1'b0;
                thin_wall_opened <= 1'b0;
            end else begin
                if (collect_lens1)  lens1_collected  <= 1'b1;
                if (collect_lens2)  lens2_collected  <= 1'b1;
                if (open_thin_wall) thin_wall_opened <= 1'b1;

                if (drone_hit_pulse) begin
                    // ADR-0003: downgrade the highest lens (respawns on the map)
                    if (lens2_collected)      lens2_collected <= 1'b0;
                    else if (lens1_collected) lens1_collected <= 1'b0;
                end
            end

            // ---- fog write engine ----
            if (game_reset || drone_hit_pulse) begin
                fog_st      <= FOG_CLEAR;
                fog_clr_idx <= 10'd0;
            end else begin
                case (fog_st)
                    FOG_CLEAR: begin
                        fog_we      <= 1'b1;
                        fog_waddr   <= fog_clr_idx;
                        fog_wdata   <= 1'b0;
                        fog_clr_idx <= fog_clr_idx + 10'd1;
                        if (fog_clr_idx == 10'd1023) fog_st <= FOG_IDLE;
                    end

                    FOG_REVEAL: begin
                        fog_we    <= rev_ok;
                        fog_waddr <= {rev_ty[4:0], rev_tx[4:0]};
                        fog_wdata <= 1'b1;
                        if (rev_ix == 3'd4) begin
                            rev_ix <= 3'd0;
                            if (rev_iy == 3'd4) fog_st <= FOG_IDLE;
                            else                rev_iy <= rev_iy + 3'd1;
                        end else begin
                            rev_ix <= rev_ix + 3'd1;
                        end
                    end

                    default: begin // FOG_IDLE
                        if (vblank_pulse) begin
                            fog_st <= FOG_REVEAL;
                            rev_ix <= 3'd0;
                            rev_iy <= 3'd0;
                        end
                    end
                endcase
            end
        end
    end

endmodule
