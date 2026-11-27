// ============================================================================
// DEPTH - TITLE / PLAY (ECHO, MAP, SIGHT) / WIN multiplexer + transition wipe
//
// ADR-0008: the block-letter "DEPTH" banner used to be generated
// combinationally from pixel_x/pixel_y and then muxed - all in the same clock
// that drove the output pins.  The banner is now produced by a short pipeline
// that carries the design's common PIPE_STAGES latency, so by the time a pixel
// reaches the final mux everything feeding it is already registered.
// ============================================================================
module render_mux (
    input  wire        clk,
    input  wire        rst,
    input  wire        pix_ce,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire        video_on,
    input  wire [1:0]  game_state,
    input  wire [1:0]  active_form,
    input  wire [4:0]  trans_cnt,
    input  wire [11:0] rgb_2d,        // already PIPE_STAGES deep
    input  wire [11:0] rgb_3d,        // already PIPE_STAGES deep
    input  wire        hud_on,
    input  wire [11:0] hud_rgb,
    output reg  [11:0] vga_rgb
);
    `include "depth_pkg.vh"

    // ---- S1: banner geometry ----------------------------------------------
    wire in_title_box_c = (pixel_x >= 10'd160) && (pixel_x < 10'd480) &&
                          (pixel_y >= 10'd170) && (pixel_y < 10'd310);
    wire title_border_c = in_title_box_c &&
                          ((pixel_x < 10'd166) || (pixel_x >= 10'd474) ||
                           (pixel_y < 10'd176) || (pixel_y >= 10'd304));
    wire press_bar_c    = (pixel_x >= 10'd240) && (pixel_x < 10'd400) &&
                          (pixel_y >= 10'd276) && (pixel_y < 10'd288);
    wire in_text_box_c  = (pixel_x >= 10'd204) && (pixel_x < 10'd436) &&
                          (pixel_y >= 10'd210) && (pixel_y < 10'd260);

    wire [9:0] lx_c = pixel_x - 10'd204;
    wire [9:0] ly_c = pixel_y - 10'd210;
    wire [2:0] char_idx_c = (lx_c < 10'd48)  ? 3'd0 :
                            (lx_c < 10'd96)  ? 3'd1 :
                            (lx_c < 10'd144) ? 3'd2 :
                            (lx_c < 10'd192) ? 3'd3 : 3'd4;
    wire [9:0] char_x0_c  = (char_idx_c == 3'd0) ? 10'd0 :
                            (char_idx_c == 3'd1) ? 10'd48 :
                            (char_idx_c == 3'd2) ? 10'd96 :
                            (char_idx_c == 3'd3) ? 10'd144 : 10'd192;

    reg [9:0] s1_lx, s1_ly;
    reg [2:0] s1_char;
    reg       s1_in_box, s1_border, s1_press, s1_in_text;

    always @(posedge clk) begin
        if (rst) begin
            s1_lx <= 10'd0; s1_ly <= 10'd0; s1_char <= 3'd0;
            s1_in_box <= 1'b0; s1_border <= 1'b0; s1_press <= 1'b0; s1_in_text <= 1'b0;
        end else if (pix_ce) begin
            s1_lx      <= lx_c - char_x0_c;
            s1_ly      <= ly_c;
            s1_char    <= char_idx_c;
            s1_in_box  <= in_title_box_c;
            s1_border  <= title_border_c;
            s1_press   <= press_bar_c;
            s1_in_text <= in_text_box_c;
        end
    end

    // ---- S2: block letters -------------------------------------------------
    wire [5:0] cx = s1_lx[5:0];
    wire [9:0] ly = s1_ly;

    reg text_px_c;
    always @(*) begin
        text_px_c = 1'b0;
        if (s1_in_text && (cx < 6'd36)) begin
            case (s1_char)
                3'd0: text_px_c = (cx < 6'd8) || (ly < 10'd8 && cx < 6'd28) ||
                                  (ly >= 10'd42 && cx < 6'd28) ||
                                  (cx >= 6'd28 && ly >= 10'd8 && ly < 10'd42);          // D
                3'd1: text_px_c = (cx < 6'd8) || (ly < 10'd8) ||
                                  (ly >= 10'd21 && ly < 10'd29 && cx < 6'd28) ||
                                  (ly >= 10'd42);                                        // E
                3'd2: text_px_c = (cx < 6'd8) || (ly < 10'd8) ||
                                  (ly >= 10'd21 && ly < 10'd29) ||
                                  (cx >= 6'd28 && ly < 10'd29);                          // P
                3'd3: text_px_c = (ly < 10'd8) || (cx >= 6'd14 && cx < 6'd22);           // T
                3'd4: text_px_c = (cx < 6'd8) || (cx >= 6'd28) ||
                                  (ly >= 10'd21 && ly < 10'd29);                         // H
                default: text_px_c = 1'b0;
            endcase
        end
    end

    reg s2_text, s2_in_box, s2_border, s2_press;
    always @(posedge clk) begin
        if (rst) begin
            s2_text <= 1'b0; s2_in_box <= 1'b0; s2_border <= 1'b0; s2_press <= 1'b0;
        end else if (pix_ce) begin
            s2_text   <= text_px_c;
            s2_in_box <= s1_in_box;
            s2_border <= s1_border;
            s2_press  <= s1_press;
        end
    end

    // ---- delay to the common renderer latency ------------------------------
    wire       d_text, d_in_box, d_border, d_press, d_video_on;
    wire [9:0] d_py;

    pix_delay #(.W(4), .N(PIPE_STAGES - 2)) u_banner (
        .clk(clk), .rst(rst), .en(pix_ce),
        .d({s2_text, s2_in_box, s2_border, s2_press}),
        .q({d_text, d_in_box, d_border, d_press}));

    pix_delay #(.W(11), .N(PIPE_STAGES)) u_coord (
        .clk(clk), .rst(rst), .en(pix_ce),
        .d({video_on, pixel_y}), .q({d_video_on, d_py}));

    // ---- final mux (combinational; top_depth registers it into the IOBs) ---
    reg [11:0] base_rgb;

    always @(*) begin
        base_rgb = 12'h000;
        if (!d_video_on) begin
            vga_rgb = 12'h000;
        end else begin
            case (game_state)
                GAME_TITLE: begin
                    if (d_border)        base_rgb = 12'h3DF;
                    else if (d_text)     base_rgb = 12'hFFF;
                    else if (d_press)    base_rgb = 12'h4AF;
                    else if (d_in_box)   base_rgb = 12'h112;
                    else                 base_rgb = 12'h001;
                end

                GAME_PLAY: begin
                    case (active_form)
                        FORM_ECHO:  base_rgb = rgb_2d;
                        FORM_MAP:   base_rgb = rgb_2d;
                        FORM_SIGHT: base_rgb = rgb_3d;
                        default:    base_rgb = 12'h000;
                    endcase

                    // Scanline transition wipe when switching forms
                    if ((trans_cnt != 5'd0) && (d_py[3:0] < trans_cnt[3:0]))
                        base_rgb = ~base_rgb;

                    // Persistent HUD sprite always visible in PLAY
                    if (hud_on) base_rgb = hud_rgb;
                end

                GAME_WIN: begin
                    if (d_border)        base_rgb = 12'h4F4;
                    else if (d_text)     base_rgb = 12'h4F4;
                    else if (d_press)    base_rgb = 12'hFF4;
                    else if (d_in_box)   base_rgb = 12'h121;
                    else                 base_rgb = 12'h010;
                end

                default: base_rgb = 12'h000;
            endcase

            vga_rgb = base_rgb;
        end
    end

endmodule
