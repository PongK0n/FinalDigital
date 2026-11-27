// Manages 16-bit LFSR 4-digit BCD passcode, MM:SS elapsed timer (+10s penalty), and door entry
module game_fsm (
    input  wire        clk,
    input  wire        rst,
    input  wire        vblank_pulse,
    input  wire        btn_any_pulse,
    input  wire        btn_c_pulse,
    input  wire        near_door,
    input  wire [3:0]  sw_digit,
    input  wire        drone_hit_pulse,

    output reg  [1:0]  game_state,
    output reg         game_reset_pulse, // 1-cycle reset to world/player when TITLE -> PLAY
    output reg  [15:0] secret_bcd,       // 4 BCD digits from LFSR
    output reg  [15:0] entered_bcd,
    output reg  [1:0]  door_idx,
    output reg         err_pulse,
    output reg         win_pulse,
    output reg  [3:0]  min_tens,
    output reg  [3:0]  min_ones,
    output reg  [3:0]  sec_tens,
    output reg  [3:0]  sec_ones
);
    `include "depth_pkg.vh"

    // 16-bit Galois LFSR running continuously in TITLE
    reg [15:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    function [3:0] mod10_4bit;
        input [3:0] v;
        begin
            mod10_4bit = (v >= 4'd10) ? (v - 4'd10) : v;
        end
    endfunction

    reg [5:0] frame_cnt; // 60 frames = 1 second

    task add_seconds;
        input [3:0] add_s; // 1 or 10
        begin
            if (add_s == 4'd10) begin
                if (sec_tens < 4'd5) begin
                    sec_tens <= sec_tens + 4'd1;
                end else begin
                    sec_tens <= 4'd0;
                    if (min_ones < 4'd9) begin
                        min_ones <= min_ones + 4'd1;
                    end else begin
                        min_ones <= 4'd0;
                        if (min_tens < 4'd9) min_tens <= min_tens + 4'd1;
                    end
                end
            end else begin
                if (sec_ones < 4'd9) begin
                    sec_ones <= sec_ones + 4'd1;
                end else begin
                    sec_ones <= 4'd0;
                    if (sec_tens < 4'd5) begin
                        sec_tens <= sec_tens + 4'd1;
                    end else begin
                        sec_tens <= 4'd0;
                        if (min_ones < 4'd9) begin
                            min_ones <= min_ones + 4'd1;
                        end else begin
                            min_ones <= 4'd0;
                            if (min_tens < 4'd9) min_tens <= min_tens + 4'd1;
                        end
                    end
                end
            end
        end
    endtask

    wire [15:0] cand_entered =
        (door_idx == 2'd0) ? {sw_digit, entered_bcd[11:0]} :
        (door_idx == 2'd1) ? {entered_bcd[15:12], sw_digit, entered_bcd[7:0]} :
        (door_idx == 2'd2) ? {entered_bcd[15:8], sw_digit, entered_bcd[3:0]} :
                             {entered_bcd[15:4], sw_digit};

    always @(posedge clk) begin
        if (rst) begin
            game_state       <= GAME_TITLE;
            game_reset_pulse <= 1'b0;
            secret_bcd       <= 16'h7319;
            entered_bcd      <= 16'h0000;
            door_idx         <= 2'd0;
            err_pulse        <= 1'b0;
            win_pulse        <= 1'b0;
            frame_cnt        <= 6'd0;
            min_tens         <= 4'd0;
            min_ones         <= 4'd0;
            sec_tens         <= 4'd0;
            sec_ones         <= 4'd0;
        end else begin
            game_reset_pulse <= 1'b0;
            err_pulse        <= 1'b0;
            win_pulse        <= 1'b0;

            case (game_state)
                GAME_TITLE: begin
                    if (btn_any_pulse) begin
                        secret_bcd <= {
                            mod10_4bit(lfsr[15:12]),
                            mod10_4bit(lfsr[11:8]),
                            mod10_4bit(lfsr[7:4]),
                            mod10_4bit(lfsr[3:0])
                        };
                        entered_bcd      <= 16'h0000;
                        door_idx         <= 2'd0;
                        frame_cnt        <= 6'd0;
                        min_tens         <= 4'd0;
                        min_ones         <= 4'd0;
                        sec_tens         <= 4'd0;
                        sec_ones         <= 4'd0;
                        game_reset_pulse <= 1'b1;
                        game_state       <= GAME_PLAY;
                    end
                end

                GAME_PLAY: begin
                    // Timer counting
                    if (drone_hit_pulse) begin
                        add_seconds(4'd10);
                    end else if (vblank_pulse) begin
                        if (frame_cnt == 6'd59) begin
                            frame_cnt <= 6'd0;
                            add_seconds(4'd1);
                        end else begin
                            frame_cnt <= frame_cnt + 6'd1;
                        end
                    end

                    // Door passcode entry
                    if (near_door && btn_c_pulse) begin
                        if (sw_digit <= 4'd9) begin
                            entered_bcd <= cand_entered;
                            if (door_idx == 2'd3) begin
                                if (cand_entered == secret_bcd) begin
                                    game_state <= GAME_WIN;
                                    win_pulse  <= 1'b1;
                                end else begin
                                    door_idx  <= 2'd0;
                                    err_pulse <= 1'b1;
                                end
                            end else begin
                                door_idx <= door_idx + 2'd1;
                            end
                        end else begin
                            err_pulse <= 1'b1;
                        end
                    end
                end

                GAME_WIN: begin
                    if (btn_any_pulse) begin
                        game_state <= GAME_TITLE;
                    end
                end

                default: game_state <= GAME_TITLE;
            endcase
        end
    end

endmodule
