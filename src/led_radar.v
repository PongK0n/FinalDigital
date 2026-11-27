// Closer wall lights up more LEDs symmetrically from the outer edges inward.
module led_radar (
    input  wire [14:0] dist_left,   // Q5.10 tiles
    input  wire [14:0] dist_right,  // Q5.10 tiles
    output reg  [15:0] led
);

    function [7:0] dist_to_bar_msb;
        input [14:0] d;
        begin
            if      (d < 15'd768)  dist_to_bar_msb = 8'b1111_1111; // < 0.75 tile
            else if (d < 15'd1280) dist_to_bar_msb = 8'b1111_1110; // < 1.25
            else if (d < 15'd2048) dist_to_bar_msb = 8'b1111_1100; // < 2.0
            else if (d < 15'd3072) dist_to_bar_msb = 8'b1111_1000; // < 3.0
            else if (d < 15'd4096) dist_to_bar_msb = 8'b1111_0000; // < 4.0
            else if (d < 15'd6144) dist_to_bar_msb = 8'b1110_0000; // < 6.0
            else if (d < 15'd8192) dist_to_bar_msb = 8'b1100_0000; // < 8.0
            else                   dist_to_bar_msb = 8'b1000_0000; // >= 8.0
        end
    endfunction

    wire [7:0] left_bar  = dist_to_bar_msb(dist_left);
    wire [7:0] right_raw = dist_to_bar_msb(dist_right);

    always @(*) begin
        led[15:8] = left_bar;
        // Mirror right bar outward from LED[0]
        led[7:0]  = {
            right_raw[0], right_raw[1], right_raw[2], right_raw[3],
            right_raw[4], right_raw[5], right_raw[6], right_raw[7]
        };
    end

endmodule
