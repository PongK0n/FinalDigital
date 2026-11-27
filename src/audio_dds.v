// Supports: wall-distance echo ping, drone proximity hum, dimension unlock arpeggio, door win/error tones
module audio_dds #(
    parameter MEM_FILE = "wave_rom.mem",
    parameter integer SIM_CLK_SCALE = 1 // 1 for 100 MHz FPGA, 4 when PIX_DIV=1 in sim
) (
    input  wire        clk,          // 100 MHz
    input  wire        rst,
    input  wire        playing,      // 1 during GAME_PLAY
    input  wire [14:0] dist_front,   // Q5.10 tiles
    input  wire        drone_near,   // 1 if nearest drone < 4.0 tiles
    input  wire        unlock_pulse, // 1-cycle pulse when Lens 1/2 collected
    input  wire        err_pulse,    // 1-cycle pulse on wrong door code
    input  wire        win_pulse,    // 1-cycle pulse on game win
    output wire        aud_pwm,      // Open-drain output for Nexys A7 AUD_PWM
    output wire        aud_sd        // Amplifier enable (1 = active)
);

    reg [7:0] wave_rom [0:63];
    initial begin
        $readmemh(MEM_FILE, wave_rom);
    end

    // Millisecond tick (100,000 cycles @ 100 MHz, scaled for fast sim)
    localparam [16:0] MS_MAX = (100000 / SIM_CLK_SCALE) - 1;
    reg [16:0] ms_div;
    wire       ms_tick = (ms_div == MS_MAX);
    always @(posedge clk) begin
        if (rst)          ms_div <= 17'd0;
        else if (ms_tick) ms_div <= 17'd0;
        else              ms_div <= ms_div + 17'd1;
    end

    // NOTE: tuning words give f_out = tuning * 100e6 / 2^24 (~168 per kHz).
    // They were 1000x too large until this fix, putting every tone between
    // 110 kHz and 1.6 MHz - inaudible, and above the board's audio filter.

    // Ping scheduler (interval & pitch scale with dist_front)
    // f_out = tuning * 100e6 / 2^24 => tuning ~ 168 per kHz
    reg [10:0] ping_timer_ms;
    reg [7:0]  ping_dur_ms;
    reg [9:0]  sfx_ms;
    reg [1:0]  sfx_mode; // 0=none, 1=unlock arpeggio, 2=error buzz, 3=win fanfare

    wire [10:0] ping_interval_ms = (dist_front < 15'd1024) ? 11'd250 :
                                   (dist_front < 15'd2048) ? 11'd450 :
                                   (dist_front < 15'd4096) ? 11'd750 :
                                   (dist_front < 15'd6144) ? 11'd1100 : 11'd1500;

    wire [23:0] ping_tuning = (dist_front < 15'd1024) ? 24'd268 : // ~1600 Hz
                              (dist_front < 15'd2048) ? 24'd201 : // ~1200 Hz
                              (dist_front < 15'd4096) ? 24'd134 : // ~800 Hz
                              (dist_front < 15'd6144) ? 24'd101 : // ~600 Hz
                                                        24'd67;   // ~400 Hz

    always @(posedge clk) begin
        if (rst) begin
            ping_timer_ms <= 11'd0;
            ping_dur_ms   <= 8'd0;
            sfx_ms        <= 10'd0;
            sfx_mode      <= 2'd0;
        end else begin
            if (win_pulse) begin
                sfx_mode <= 2'd3;
                sfx_ms   <= 10'd600;
            end else if (unlock_pulse) begin
                sfx_mode <= 2'd1;
                sfx_ms   <= 10'd360;
            end else if (err_pulse) begin
                sfx_mode <= 2'd2;
                sfx_ms   <= 10'd250;
            end else if (ms_tick && (sfx_ms > 10'd0)) begin
                sfx_ms <= sfx_ms - 10'd1;
                if (sfx_ms == 10'd1) sfx_mode <= 2'd0;
            end

            if (ms_tick) begin
                if (ping_dur_ms > 8'd0)
                    ping_dur_ms <= ping_dur_ms - 8'd1;
                if (playing) begin
                    if (ping_timer_ms >= ping_interval_ms) begin
                        ping_timer_ms <= 11'd0;
                        ping_dur_ms   <= 8'd45;
                    end else begin
                        ping_timer_ms <= ping_timer_ms + 11'd1;
                    end
                end else begin
                    ping_timer_ms <= 11'd0;
                    ping_dur_ms   <= 8'd0;
                end
            end
        end
    end

    reg [23:0] active_tuning;
    reg        tone_enable;
    always @(*) begin
        tone_enable   = 1'b0;
        active_tuning = 24'd0;
        if (sfx_mode == 2'd3) begin
            // Win fanfare (ascending 3 notes)
            tone_enable   = 1'b1;
            active_tuning = (sfx_ms > 10'd400) ? 24'd88  : // ~524 Hz
                            (sfx_ms > 10'd200) ? 24'd111 : // ~660 Hz
                                                 24'd132;  // ~785 Hz
        end else if (sfx_mode == 2'd1) begin
            // Lens unlock arpeggio
            tone_enable   = 1'b1;
            active_tuning = (sfx_ms > 10'd240) ? 24'd74  :
                            (sfx_ms > 10'd120) ? 24'd111 :
                                                 24'd148;
        end else if (sfx_mode == 2'd2) begin
            // Wrong code buzz (~150 Hz)
            tone_enable   = 1'b1;
            active_tuning = 24'd25;
        end else if (playing) begin
            if (ping_dur_ms > 8'd0) begin
                tone_enable   = 1'b1;
                active_tuning = ping_tuning;
            end else if (drone_near) begin
                // Low drone proximity hum (~110 Hz)
                tone_enable   = 1'b1;
                active_tuning = 24'd18;
            end
        end
    end

    wire [23:0] phase_step = (SIM_CLK_SCALE == 4) ? {active_tuning[21:0], 2'b00} : active_tuning;

    reg [23:0] phase_acc;
    reg [7:0]  pwm_cnt;
    always @(posedge clk) begin
        if (rst) begin
            phase_acc <= 24'd0;
            pwm_cnt   <= 8'd0;
        end else begin
            phase_acc <= phase_acc + phase_step;
            pwm_cnt   <= pwm_cnt + 8'd1;
        end
    end

    wire [7:0] sample  = tone_enable ? wave_rom[phase_acc[23:18]] : 8'd128;
    wire       pwm_out = (pwm_cnt < sample);

    assign aud_sd  = 1'b1;
    assign aud_pwm = pwm_out ? 1'bz : 1'b0;

endmodule
