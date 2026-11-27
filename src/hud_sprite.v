// ============================================================================
// DEPTH - persistent 64x64 bottom-right HUD sprite box (16x16 ROM scaled 4x)
//
// ADR-0008: this module used to be purely combinational, with a 768-entry
// asynchronous sprite ROM wired straight from pixel_x/pixel_y to the colour
// mux and on to the output pin.  It is now clocked, reads the sprite from a
// block ROM, and carries the design's common PIPE_STAGES pixel latency.
// ============================================================================
module hud_sprite #(
    parameter MEM_FILE = "hud_sprites.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        pix_ce,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire [1:0]  active_form,   // 0=ECHO, 1=MAP, 2=SIGHT
    input  wire [1:0]  unlocked_tier, // Highest unlocked sprite form (0..2)
    input  wire        in_jamming,
    output wire        hud_on,
    output wire [11:0] hud_rgb
);
    `include "depth_pkg.vh"

    // Box bounds: x in [560..623], y in [400..463] (64x64)
    localparam [9:0] BOX_X0 = 10'd560;
    localparam [9:0] BOX_Y0 = 10'd400;
    localparam [9:0] BOX_W  = 10'd64;

    wire in_box_c = (pixel_x >= BOX_X0) && (pixel_x < BOX_X0 + BOX_W) &&
                    (pixel_y >= BOX_Y0) && (pixel_y < BOX_Y0 + BOX_W);

    wire [5:0] rel_x_c = pixel_x[5:0] - BOX_X0[5:0];
    wire [5:0] rel_y_c = pixel_y[5:0] - BOX_Y0[5:0];
    wire on_border_c = (rel_x_c < 6'd2) || (rel_x_c >= 6'd62) ||
                       (rel_y_c < 6'd2) || (rel_y_c >= 6'd62);

    wire [1:0] sprite_form = (active_form <= 2'd2) ? active_form : unlocked_tier;

    // ---- S1: ROM address + box flags ---------------------------------------
    reg [9:0] s1_addr;
    reg       s1_in_box, s1_on_border, s1_jam;
    reg [1:0] s1_form;

    always @(posedge clk) begin
        if (rst) begin
            s1_addr <= 10'd0; s1_in_box <= 1'b0; s1_on_border <= 1'b0;
            s1_jam <= 1'b0;   s1_form <= 2'd0;
        end else if (pix_ce) begin
            s1_addr      <= {sprite_form, rel_y_c[5:2], rel_x_c[5:2]};
            s1_in_box    <= in_box_c;
            s1_on_border <= on_border_c;
            s1_jam       <= in_jamming;
            s1_form      <= active_form;
        end
    end

    wire [11:0] spr_q;
    rom_sp #(.AW(10), .DW(12), .MEM_FILE(MEM_FILE)) u_spr (
        .clk(clk), .addr(s1_addr), .q(spr_q));

    // ---- S2: latch ROM data ------------------------------------------------
    reg [11:0] s2_pix;
    reg        s2_in_box, s2_on_border, s2_jam;
    reg [1:0]  s2_form;

    always @(posedge clk) begin
        if (rst) begin
            s2_pix <= 12'h000; s2_in_box <= 1'b0; s2_on_border <= 1'b0;
            s2_jam <= 1'b0;    s2_form <= 2'd0;
        end else if (pix_ce) begin
            s2_pix       <= spr_q;
            s2_in_box    <= s1_in_box;
            s2_on_border <= s1_on_border;
            s2_jam       <= s1_jam;
            s2_form      <= s1_form;
        end
    end

    // ---- S3: colour --------------------------------------------------------
    reg [11:0] s3_rgb;
    reg        s3_on;

    always @(posedge clk) begin
        if (rst) begin
            s3_rgb <= 12'h000; s3_on <= 1'b0;
        end else if (pix_ce) begin
            s3_on  <= s2_in_box;
            s3_rgb <= 12'h000;
            if (s2_in_box) begin
                if (s2_on_border) begin
                    s3_rgb <= s2_jam             ? 12'hF22 :
                              (s2_form == 2'd0)  ? 12'hFA2 :
                              (s2_form == 2'd1)  ? 12'h4AF : 12'h4FC;
                end else if (s2_pix != 12'hF0F) begin
                    s3_rgb <= s2_pix;
                end else begin
                    s3_rgb <= 12'h112;           // dark HUD panel backing
                end
            end
        end
    end

    // ---- S4/S5: match the common renderer latency --------------------------
    pix_delay #(.W(13), .N(PIPE_STAGES - 3)) u_tail (
        .clk(clk), .rst(rst), .en(pix_ce),
        .d({s3_on, s3_rgb}), .q({hud_on, hud_rgb}));

endmodule
