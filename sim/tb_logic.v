// ===========================================================================
// DEPTH - game-logic regression testbench (no frame capture).
// Runs with PIX_DIV=1 so a frame is 4x cheaper to simulate; all game logic is
// driven by vblank_pulse, so player movement, collision, sonar, drones and the
// game FSM behave exactly as they do on the board.
// Dumps a per-frame state digest that golden and refactored builds must match.
// ===========================================================================
`timescale 1ns/1ps

module tb_logic;
    reg CLK100MHZ = 1'b0;
    always #5 CLK100MHZ = ~CLK100MHZ;

    reg        CPU_RESETN = 1'b0;
    reg        BTNU=0, BTNL=0, BTNR=0, BTND=0, BTNC=0;
    reg [15:0] SW = 16'h0000;

    wire [15:0] LED;
    wire        CA,CB,CC,CD,CE,CF,CG,DP;
    wire [7:0]  AN;
    wire [3:0]  VGA_R, VGA_G, VGA_B;
    wire        VGA_HS, VGA_VS, AUD_PWM, AUD_SD;

    top_depth #(
        .DEBOUNCE_CYCLES (50),
        .REFRESH_BITS    (8),
        .PIX_DIV         (1)
    ) dut (
        .CLK100MHZ(CLK100MHZ), .CPU_RESETN(CPU_RESETN),
        .BTNU(BTNU), .BTNL(BTNL), .BTNR(BTNR), .BTND(BTND), .BTNC(BTNC),
        .SW(SW), .LED(LED),
        .CA(CA),.CB(CB),.CC(CC),.CD(CD),.CE(CE),.CF(CF),.CG(CG),.DP(DP),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .AUD_PWM(AUD_PWM), .AUD_SD(AUD_SD)
    );

    integer fd, frame;

    task log_frame;
        begin
            $fwrite(fd,
                "f=%0d st=%0d form=%0d px=%0d py=%0d pa=%0d df=%0d dl=%0d dr=%0d db=%0d LED=%04h jam=%0d door=%0d l1=%0d l2=%0d thin=%0d d0=%0d,%0d d1=%0d,%0d d2=%0d,%0d t=%0d%0d:%0d%0d\n",
                frame, dut.game_state, dut.active_form,
                dut.u_player.player_x, dut.u_player.player_y, dut.u_player.player_angle,
                dut.dist_front, dut.dist_left, dut.dist_right, dut.dist_back,
                LED, dut.in_jamming, dut.near_door,
                dut.u_map.lens1_collected, dut.u_map.lens2_collected, dut.u_map.thin_wall_opened,
                dut.drone0_x, dut.drone0_y, dut.drone1_x, dut.drone1_y, dut.drone2_x, dut.drone2_y,
                dut.min_tens, dut.min_ones, dut.sec_tens, dut.sec_ones);
        end
    endtask

    task wait_frames;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge dut.vblank_pulse);
                frame = frame + 1;
                log_frame;
            end
        end
    endtask

    initial begin
        fd    = $fopen("out_logic.txt", "w");
        frame = 0;
        repeat (20) @(posedge CLK100MHZ);
        CPU_RESETN = 1'b1;
        repeat (400) @(posedge CLK100MHZ);

        wait_frames(3);                 // TITLE

        BTNC = 1; wait_frames(2); BTNC = 0;   // start the game
        wait_frames(3);

        BTNU = 1; wait_frames(14); BTNU = 0;  // walk forward into the corridor
        wait_frames(2);

        BTNR = 1; wait_frames(10); BTNR = 0;  // turn right
        wait_frames(2);

        BTNU = 1; wait_frames(16); BTNU = 0;  // walk again (hits a wall -> slide)
        wait_frames(2);

        BTNL = 1; wait_frames(8);  BTNL = 0;  // turn left
        BTND = 1; wait_frames(10); BTND = 0;  // back up
        wait_frames(3);

        SW = 16'h4000;                        // request MAP without the lens
        wait_frames(4);
        SW = 16'h8000;                        // request SIGHT without the lens
        wait_frames(4);
        SW = 16'h0000;
        wait_frames(3);

        $fclose(fd);
        $display("[TB] logic regression done (%0d frames)", frame);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("[TB] TIMEOUT");
        $finish;
    end
endmodule
