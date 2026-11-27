// Left 4 digits (7..4): front wall distance (XX.X) OR 4-digit passcode entry slots when at EXIT_DOOR
// Right 4 digits (3..0): elapsed timer MM:SS
module seven_seg_ctrl #(
    parameter integer REFRESH_BITS = 17  // ~760 Hz refresh @ 100 MHz
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        door_mode,     // 1 when player is near EXIT_DOOR
    input  wire [14:0] dist_front,    // Q5.10 tiles
    input  wire [3:0]  sw_digit,      // SW3..SW0 live digit preview
    input  wire [1:0]  door_idx,      // 0..3 current passcode slot
    input  wire [15:0] entered_bcd,   // 4 x 4-bit entered digits
    input  wire [3:0]  min_tens,
    input  wire [3:0]  min_ones,
    input  wire [3:0]  sec_tens,
    input  wire [3:0]  sec_ones,
    output reg         ca, cb, cc, cd, ce, cf, cg, dp,
    output reg  [7:0]  an
);

    localparam [4:0] CHAR_BLANK = 5'd16;
    localparam [4:0] CHAR_DASH  = 5'd17;
    localparam [4:0] CHAR_ERR   = 5'd14; // 'E'

    reg [REFRESH_BITS-1:0] refresh_cnt;
    wire [2:0] digit_sel = refresh_cnt[REFRESH_BITS-1 : REFRESH_BITS-3];

    always @(posedge clk) begin
        if (rst) refresh_cnt <= {REFRESH_BITS{1'b0}};
        else     refresh_cnt <= refresh_cnt + {{(REFRESH_BITS-1){1'b0}}, 1'b1};
    end

    // Convert dist_front (Q5.10 -> 0..31.9) to 3 digits: tens, ones, tenths
    wire [4:0] dist_int   = dist_front[14:10];
    wire [3:0] dist_tenth = (dist_front[9:0] * 10) >> 10;
    wire [3:0] dist_tens  = (dist_int >= 5'd30) ? 4'd3 :
                            (dist_int >= 5'd20) ? 4'd2 :
                            (dist_int >= 5'd10) ? 4'd1 : 4'd0;
    wire [3:0] dist_ones  = dist_int - (dist_tens * 5'd10);

    function [4:0] door_slot_char;
        input [1:0] slot;
        input [1:0] cur_idx;
        input [3:0] live_sw;
        input [3:0] saved_val;
        begin
            if (slot < cur_idx)
                door_slot_char = {1'b0, saved_val};
            else if (slot == cur_idx)
                door_slot_char = (live_sw <= 4'd9) ? {1'b0, live_sw} : CHAR_ERR;
            else
                door_slot_char = CHAR_DASH;
        end
    endfunction

    reg [4:0] cur_char;
    reg       cur_dp_on;

    always @(*) begin
        cur_dp_on = 1'b0;
        case (digit_sel)
            3'd7: cur_char = door_mode ? door_slot_char(2'd0, door_idx, sw_digit, entered_bcd[15:12]) : CHAR_BLANK;
            3'd6: cur_char = door_mode ? door_slot_char(2'd1, door_idx, sw_digit, entered_bcd[11:8])  : {1'b0, dist_tens};
            3'd5: begin
                cur_char  = door_mode ? door_slot_char(2'd2, door_idx, sw_digit, entered_bcd[7:4]) : {1'b0, dist_ones};
                cur_dp_on = ~door_mode;
            end
            3'd4: cur_char = door_mode ? door_slot_char(2'd3, door_idx, sw_digit, entered_bcd[3:0])   : {1'b0, dist_tenth};
            3'd3: cur_char = {1'b0, min_tens};
            3'd2: begin
                cur_char  = {1'b0, min_ones};
                cur_dp_on = 1'b1;
            end
            3'd1: cur_char = {1'b0, sec_tens};
            3'd0: cur_char = {1'b0, sec_ones};
        endcase
    end

    reg [6:0] seg_active_low;
    always @(*) begin
        case (cur_char)
            5'd0:       seg_active_low = 7'b0000001; // 0 (ca..cg)
            5'd1:       seg_active_low = 7'b1001111; // 1
            5'd2:       seg_active_low = 7'b0010010; // 2
            5'd3:       seg_active_low = 7'b0000110; // 3
            5'd4:       seg_active_low = 7'b1001100; // 4
            5'd5:       seg_active_low = 7'b0100100; // 5
            5'd6:       seg_active_low = 7'b0100000; // 6
            5'd7:       seg_active_low = 7'b0001111; // 7
            5'd8:       seg_active_low = 7'b0000000; // 8
            5'd9:       seg_active_low = 7'b0000100; // 9
            5'd14:      seg_active_low = 7'b0110000; // E
            CHAR_DASH:  seg_active_low = 7'b1111110; // -
            default:    seg_active_low = 7'b1111111; // blank
        endcase
        {ca, cb, cc, cd, ce, cf, cg} = seg_active_low;
        dp = ~cur_dp_on;
        an = ~(8'b0000_0001 << digit_sel);
    end

endmodule
