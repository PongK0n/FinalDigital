module form_fsm (
    input  wire       clk,
    input  wire       rst,
    input  wire       game_reset,
    input  wire       vblank_pulse,
    input  wire [1:0] sw_form_req,      // SW15:SW14
    input  wire       lens1_collected,
    input  wire       lens2_collected,
    input  wire       in_jamming,
    output wire [1:0] unlocked_tier,    // 0=ECHO, 1=MAP, 2=SIGHT
    output reg  [1:0] active_form,
    output reg  [4:0] trans_cnt         // Non-zero during form switch transition
);
    `include "depth_pkg.vh"

    assign unlocked_tier = lens2_collected ? FORM_SIGHT :
                           lens1_collected ? FORM_MAP   : FORM_ECHO;

    reg [1:0] desired_form;
    always @(*) begin
        if (in_jamming) begin
            desired_form = FORM_ECHO;
        end else begin
            case (sw_form_req)
                2'b00:   desired_form = FORM_ECHO;
                2'b01:   desired_form = lens1_collected ? FORM_MAP : FORM_ECHO;
                2'b10:   desired_form = lens2_collected ? FORM_SIGHT :
                                        lens1_collected ? FORM_MAP   : FORM_ECHO;
                default: desired_form = unlocked_tier;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst || game_reset) begin
            active_form <= FORM_ECHO;
            trans_cnt   <= 5'd0;
        end else begin
            if (desired_form != active_form) begin
                active_form <= desired_form;
                trans_cnt   <= 5'd16; // ~0.26s transition wipe
            end else if (vblank_pulse && (trans_cnt > 5'd0)) begin
                trans_cnt <= trans_cnt - 5'd1;
            end
        end
    end

endmodule
