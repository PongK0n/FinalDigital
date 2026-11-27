// ============================================================================
// DEPTH - reusable RTL primitives (ADR-0008)
//
// Every large memory in DEPTH used to be read *asynchronously*, which turns a
// 1024-deep table into a ~5-level LUT mux sitting in the middle of a 100 MHz
// path.  These primitives give the same tables a registered (synchronous) read
// port, which Vivado maps onto block RAM and which costs one clock of latency
// instead of several nanoseconds of combinational delay.
// ============================================================================

// ---------------------------------------------------------------------------
// rom_dp : dual-port synchronous ROM, initialised from a .mem file.
//          Two independent registered read ports -> one block RAM.
// ---------------------------------------------------------------------------
module rom_dp #(
    parameter integer AW       = 10,
    parameter integer DW       = 4,
    parameter         MEM_FILE = ""
) (
    input  wire                 clk,
    input  wire [AW-1:0]        addr_a,
    output reg  [DW-1:0]        q_a,
    input  wire [AW-1:0]        addr_b,
    output reg  [DW-1:0]        q_b
);
    (* rom_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
        if (MEM_FILE != "") $readmemh(MEM_FILE, mem);
        q_a = {DW{1'b0}};
        q_b = {DW{1'b0}};
    end

    always @(posedge clk) begin
        q_a <= mem[addr_a];
        q_b <= mem[addr_b];
    end
endmodule


// ---------------------------------------------------------------------------
// rom_sp : single-port synchronous ROM, initialised from a .mem file.
// ---------------------------------------------------------------------------
module rom_sp #(
    parameter integer AW       = 8,
    parameter integer DW       = 10,
    parameter         MEM_FILE = ""
) (
    input  wire          clk,
    input  wire [AW-1:0] addr,
    output reg  [DW-1:0] q
);
    (* rom_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
        if (MEM_FILE != "") $readmemh(MEM_FILE, mem);
        q = {DW{1'b0}};
    end

    always @(posedge clk) q <= mem[addr];
endmodule


// ---------------------------------------------------------------------------
// ram_sdp : simple dual-port RAM (one write port, one registered read port).
//           Used for the fog bitmap and the raycaster column buffer.
//           INIT_VAL becomes a real block-RAM INIT string on Xilinx, so the
//           contents are already valid at power-up - no clear pass needed.
// ---------------------------------------------------------------------------
module ram_sdp #(
    parameter integer AW       = 8,
    parameter integer DW       = 18,
    parameter integer DEPTH    = 0,          // 0 = full 2**AW
    parameter [63:0]  INIT_VAL = 64'd0
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] q
);
    localparam integer N = (DEPTH == 0) ? (1<<AW) : DEPTH;

    (* ram_style = "block" *) reg [DW-1:0] mem [0:N-1];

    integer i;
    initial begin
        for (i = 0; i < N; i = i + 1) mem[i] = INIT_VAL[DW-1:0];
        q = INIT_VAL[DW-1:0];
    end

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        q <= mem[raddr];
    end
endmodule


// ---------------------------------------------------------------------------
// pix_delay : N-deep, W-wide shift register clocked by the pixel enable.
//             Used to carry pixel attributes (and the VGA syncs) alongside the
//             renderer pipelines so everything stays on the same pixel.
// ---------------------------------------------------------------------------
module pix_delay #(
    parameter integer W     = 1,
    parameter integer N     = 1,
    parameter [63:0]  RSTV  = 64'd0
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    generate
        if (N == 0) begin : g_passthru
            assign q = d;
        end else begin : g_pipe
            reg [W-1:0] sr [0:N-1];
            integer i;
            always @(posedge clk) begin
                if (rst) begin
                    for (i = 0; i < N; i = i + 1) sr[i] <= RSTV[W-1:0];
                end else if (en) begin
                    sr[0] <= d;
                    for (i = 1; i < N; i = i + 1) sr[i] <= sr[i-1];
                end
            end
            assign q = sr[N-1];
        end
    endgenerate
endmodule
