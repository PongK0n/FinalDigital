module vga_sync #(
    parameter integer PIX_DIV = 4   // 4 = 25 MHz from 100 MHz (1 = fast sim)
) (
    input  wire       clk,          // 100 MHz
    input  wire       rst,          // Active-high synchronous reset
    output reg        pix_ce,       // 25 MHz 1-cycle clock enable
    output reg  [9:0] pixel_x,      // 0..799
    output reg  [9:0] pixel_y,      // 0..524
    output wire       video_on,     // Active display region (640x480)
    output wire       vga_hs,       // Horizontal sync (active low)
    output wire       vga_vs,       // Vertical sync (active low)
    output reg        vblank_pulse  // 1-cycle pulse at start of vblank (y=480, x=0)
);

    reg [1:0] div_cnt;
    wire      pix_tick = (PIX_DIV <= 1) ? 1'b1 : (div_cnt == 2'd3);

    always @(posedge clk) begin
        if (rst) begin
            div_cnt      <= 2'd0;
            pix_ce       <= 1'b0;
            pixel_x      <= 10'd0;
            pixel_y      <= 10'd0;
            vblank_pulse <= 1'b0;
        end else begin
            div_cnt      <= div_cnt + 2'd1;
            pix_ce       <= pix_tick;
            vblank_pulse <= 1'b0;

            // timing fix: advance on the registered pix_ce (not pix_tick) so every pix_ce-gated
            // register samples pixel data that has been stable for 4 clocks (true multicycle path)
            if (pix_ce) begin
                if (pixel_x == 10'd799) begin
                    pixel_x <= 10'd0;
                    if (pixel_y == 10'd524) begin
                        pixel_y <= 10'd0;
                    end else begin
                        pixel_y <= pixel_y + 10'd1;
                        if (pixel_y == 10'd479) begin
                            vblank_pulse <= 1'b1;
                        end
                    end
                end else begin
                    pixel_x <= pixel_x + 10'd1;
                end
            end
        end
    end

    assign video_on = (pixel_x < 10'd640) && (pixel_y < 10'd480);
    assign vga_hs   = ~((pixel_x >= 10'd656) && (pixel_x < 10'd752));
    assign vga_vs   = ~((pixel_y >= 10'd490) && (pixel_y < 10'd492));

endmodule
