// ===========================================================================
// VGA frame-capture testbench for DEPTH.
// Acts like a monitor: locks to VGA_HS / VGA_VS edges only, so any whole-pixel
// pipeline latency added inside the design is invisible here (syncs move too).
// Writes 640x480 PPM files; used to prove golden-vs-refactor pixel equality.
// ===========================================================================
`timescale 1ns/1ps

module tb_capture;

    reg CLK100MHZ = 1'b0;
    always #5 CLK100MHZ = ~CLK100MHZ;          // 100 MHz

    reg        CPU_RESETN = 1'b0;
    reg        BTNU=0, BTNL=0, BTNR=0, BTND=0, BTNC=0;
    reg [15:0] SW = 16'h0000;

    wire [15:0] LED;
    wire        CA,CB,CC,CD,CE,CF,CG,DP;
    wire [7:0]  AN;
    wire [3:0]  VGA_R, VGA_G, VGA_B;
    wire        VGA_HS, VGA_VS, AUD_PWM, AUD_SD;

    top_depth #(
        .DEBOUNCE_CYCLES (`DEBOUNCE_CYCLES),
        .REFRESH_BITS    (8),
        .PIX_DIV         (4)
    ) dut (
        .CLK100MHZ(CLK100MHZ), .CPU_RESETN(CPU_RESETN),
        .BTNU(BTNU), .BTNL(BTNL), .BTNR(BTNR), .BTND(BTND), .BTNC(BTNC),
        .SW(SW), .LED(LED),
        .CA(CA),.CB(CB),.CC(CC),.CD(CD),.CE(CE),.CF(CF),.CG(CG),.DP(DP),.AN(AN),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .AUD_PWM(AUD_PWM), .AUD_SD(AUD_SD)
    );

    // ---------------- monitor-style capture --------------------------------
    localparam H_ACTIVE = 640, V_ACTIVE = 480;
    localparam H_BACK   = 48;   // pixels from HS rising edge to first active pixel
    localparam V_BACK   = 33;   // lines  from VS rising edge to first active line

    reg [11:0] frame [0:H_ACTIVE*V_ACTIVE-1];

    reg        hs_d = 1'b1, vs_d = 1'b1;
    integer    line_no  = -1;    // lines since VS rising edge
    integer    pix_no   = -1;    // pixel ticks since HS rising edge
    integer    captured = 0;
    reg        armed    = 1'b0;

    // Pixel strobe: the design updates its output registers on pix_ce.
    wire pix_strobe = dut.pix_ce;

    always @(posedge CLK100MHZ) begin
        if (pix_strobe) begin
            // --- VS rising edge: new frame
            if (VGA_VS && !vs_d) begin
                line_no = 0;
                pix_no  = -1;
            end
            // --- HS rising edge: new line
            else if (VGA_HS && !hs_d) begin
                if (line_no >= 0) line_no = line_no + 1;
                pix_no = 0;
            end
            else if (pix_no >= 0) begin
                pix_no = pix_no + 1;
            end

            if (armed && line_no >= V_BACK && line_no < V_BACK + V_ACTIVE &&
                pix_no >= H_BACK && pix_no < H_BACK + H_ACTIVE) begin
                frame[(line_no - V_BACK) * H_ACTIVE + (pix_no - H_BACK)]
                      = {VGA_R, VGA_G, VGA_B};
                captured = captured + 1;
            end

            hs_d <= VGA_HS;
            vs_d <= VGA_VS;
        end
    end

    // Wait for the start of a fresh frame, capture it whole, write PPM.
    task grab_frame;
        input [8*64-1:0] fname;
        integer fd, i, r, g, b;
        begin
            @(negedge VGA_VS);          // enter vertical sync
            captured = 0;
            armed    = 1'b1;
            @(posedge VGA_VS);          // frame starts here
            @(negedge VGA_VS);          // whole visible frame now captured
            armed = 1'b0;
            fd = $fopen(fname, "w");
            $fwrite(fd, "P3\n%0d %0d\n255\n", H_ACTIVE, V_ACTIVE);
            for (i = 0; i < H_ACTIVE*V_ACTIVE; i = i + 1) begin
                r = frame[i][11:8]; g = frame[i][7:4]; b = frame[i][3:0];
                $fwrite(fd, "%0d %0d %0d\n", r*17, g*17, b*17);
            end
            $fclose(fd);
            $display("[TB] wrote %0s  (%0d px sampled)", fname, captured);
        end
    endtask

    task press;                          // one clean button press
        input [2:0] which;               // 0=U 1=L 2=R 3=D 4=C
        integer k;
        begin
            case (which)
                3'd0: BTNU = 1; 3'd1: BTNL = 1; 3'd2: BTNR = 1;
                3'd3: BTND = 1; default: BTNC = 1;
            endcase
            for (k = 0; k < `PRESS_CYCLES; k = k + 1) @(posedge CLK100MHZ);
            BTNU=0; BTNL=0; BTNR=0; BTND=0; BTNC=0;
            for (k = 0; k < `PRESS_CYCLES; k = k + 1) @(posedge CLK100MHZ);
        end
    endtask

    task hold;                           // hold a button for N frames
        input [2:0] which;
        input integer frames;
        integer k;
        begin
            case (which)
                3'd0: BTNU = 1; 3'd1: BTNL = 1; 3'd2: BTNR = 1;
                3'd3: BTND = 1; default: BTNC = 1;
            endcase
            for (k = 0; k < frames; k = k + 1) @(posedge dut.vblank_pulse);
            BTNU=0; BTNL=0; BTNR=0; BTND=0; BTNC=0;
        end
    endtask

    // Place the player without walking there (stable public interface).
    task place;
        input [14:0] px, py;
        input [7:0]  pa;
        begin
            dut.u_player.player_x     = px;
            dut.u_player.player_y     = py;
            dut.u_player.player_angle = pa;
        end
    endtask

    task give_lenses;
        input l1, l2;
        begin
            dut.u_map.lens1_collected = l1;
            dut.u_map.lens2_collected = l2;
        end
    endtask

    integer f;
    initial begin
        repeat (20) @(posedge CLK100MHZ);
        CPU_RESETN = 1'b1;
        repeat (200) @(posedge CLK100MHZ);

        // ---- A: TITLE ------------------------------------------------
        grab_frame("out_A_title.ppm");

        // ---- B: PLAY / ECHO at spawn ---------------------------------
        press(3'd4);
        repeat (3) @(posedge dut.vblank_pulse);
        grab_frame("out_B_echo.ppm");

        // ---- C: PLAY / MAP -------------------------------------------
        SW = 16'h4000;                       // SW15:14 = 01
        give_lenses(1'b1, 1'b0);
        place(15'd12800, 15'd12800, 8'd32);  // tile 12.5,12.5 facing NE
        repeat (6) @(posedge dut.vblank_pulse);
        grab_frame("out_C_map.ppm");

        // ---- D: PLAY / SIGHT -----------------------------------------
        SW = 16'h8000;                       // SW15:14 = 10
        give_lenses(1'b1, 1'b1);
        place(15'd2560, 15'd4608, 8'd0);     // spawn, facing East
        repeat (6) @(posedge dut.vblank_pulse);
        grab_frame("out_D_sight.ppm");

        // ---- E: SIGHT, different pose --------------------------------
        place(15'd13312, 15'd12800, 8'd96);
        repeat (6) @(posedge dut.vblank_pulse);
        grab_frame("out_E_sight2.ppm");

        // ---- F: SIGHT near the code wall / door ----------------------
        place(15'd19968, 15'd30208, 8'd200);
        repeat (6) @(posedge dut.vblank_pulse);
        grab_frame("out_F_sight3.ppm");

        // ---- G: ECHO after walking (exercises collision + radar) -----
        SW = 16'h0000;
        give_lenses(1'b0, 1'b0);
        place(15'd2560, 15'd4608, 8'd0);
        hold(3'd0, 20);                      // walk forward 20 frames
        repeat (4) @(posedge dut.vblank_pulse);
        grab_frame("out_G_echo_walk.ppm");

        // ---- state digest: catches logic drift the pixels may hide ---
        f = $fopen("out_state.txt", "w");
        $fwrite(f, "player_x=%0d\nplayer_y=%0d\nplayer_angle=%0d\n",
                dut.u_player.player_x, dut.u_player.player_y, dut.u_player.player_angle);
        $fwrite(f, "dist_front=%0d\ndist_left=%0d\ndist_right=%0d\ndist_back=%0d\n",
                dut.dist_front, dut.dist_left, dut.dist_right, dut.dist_back);
        $fwrite(f, "LED=%04h\ngame_state=%0d\nactive_form=%0d\n",
                LED, dut.game_state, dut.active_form);
        $fwrite(f, "drone0=%0d,%0d drone1=%0d,%0d drone2=%0d,%0d\n",
                dut.drone0_x, dut.drone0_y, dut.drone1_x, dut.drone1_y,
                dut.drone2_x, dut.drone2_y);
        $fclose(f);

        $display("[TB] done");
        $finish;
    end

    // safety stop
    initial begin
        #4_000_000_000;
        $display("[TB] TIMEOUT");
        $finish;
    end

endmodule
