module input_debounce #(
    parameter integer DEBOUNCE_CYCLES = 2000000  // 20 ms @ 100 MHz (override to smaller in sim)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [4:0]  btn_raw,       // {BTNC, BTND, BTNR, BTNL, BTNU}
    input  wire [15:0] sw_raw,
    output reg  [4:0]  btn_clean,
    output reg  [15:0] sw_clean,
    output wire        btn_c_pulse,   // 1-cycle rising edge pulse for BTNC
    output wire        btn_any_pulse  // 1-cycle rising edge pulse for any button (TITLE -> PLAY)
);

    localparam integer W = 21;

    reg [W-1:0] btn_cnt [0:4];
    reg [W-1:0] sw_cnt  [0:15];

    reg [4:0]  btn_sync0, btn_sync1;
    reg [15:0] sw_sync0,  sw_sync1;
    reg [4:0]  btn_prev;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            btn_sync0 <= 5'd0;
            btn_sync1 <= 5'd0;
            sw_sync0  <= 16'd0;
            sw_sync1  <= 16'd0;
            btn_clean <= 5'd0;
            sw_clean  <= 16'd0;
            btn_prev  <= 5'd0;
            for (i = 0; i < 5; i = i + 1)  btn_cnt[i] <= {W{1'b0}};
            for (i = 0; i < 16; i = i + 1) sw_cnt[i]  <= {W{1'b0}};
        end else begin
            btn_sync0 <= btn_raw;
            btn_sync1 <= btn_sync0;
            sw_sync0  <= sw_raw;
            sw_sync1  <= sw_sync0;
            btn_prev  <= btn_clean;

            for (i = 0; i < 5; i = i + 1) begin
                if (btn_sync1[i] == btn_clean[i]) begin
                    btn_cnt[i] <= {W{1'b0}};
                end else if (btn_cnt[i] >= DEBOUNCE_CYCLES - 1) begin
                    btn_clean[i] <= btn_sync1[i];
                    btn_cnt[i]   <= {W{1'b0}};
                end else begin
                    btn_cnt[i] <= btn_cnt[i] + {{(W-1){1'b0}}, 1'b1};
                end
            end

            for (i = 0; i < 16; i = i + 1) begin
                if (sw_sync1[i] == sw_clean[i]) begin
                    sw_cnt[i] <= {W{1'b0}};
                end else if (sw_cnt[i] >= DEBOUNCE_CYCLES - 1) begin
                    sw_clean[i] <= sw_sync1[i];
                    sw_cnt[i]   <= {W{1'b0}};
                end else begin
                    sw_cnt[i] <= sw_cnt[i] + {{(W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    assign btn_c_pulse   = btn_clean[4] & ~btn_prev[4];
    assign btn_any_pulse = |(btn_clean & ~btn_prev);

endmodule
