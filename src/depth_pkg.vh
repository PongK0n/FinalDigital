// ============================================================================
// DEPTH (CPE222 Group 17) - shared constants
// Included inside module bodies for strict Verilog-2001 compatibility
// across iverilog, Verilator and Vivado.
// ============================================================================

// 4-bit Tile Types
localparam [3:0] TILE_EMPTY     = 4'h0;
localparam [3:0] TILE_WALL      = 4'h1;
localparam [3:0] TILE_THIN_WALL = 4'h2;
localparam [3:0] TILE_LENS1     = 4'h3;
localparam [3:0] TILE_LENS2     = 4'h4;
localparam [3:0] TILE_JAMMING   = 4'h5;
localparam [3:0] TILE_DOOR      = 4'h6;
localparam [3:0] TILE_CODE0     = 4'h8;
localparam [3:0] TILE_CODE1     = 4'h9;
localparam [3:0] TILE_CODE2     = 4'hA;
localparam [3:0] TILE_CODE3     = 4'hB;

// 3 Evolution Forms
localparam [1:0] FORM_ECHO      = 2'd0;
localparam [1:0] FORM_MAP       = 2'd1;
localparam [1:0] FORM_SIGHT     = 2'd2;

// Game FSM States
localparam [1:0] GAME_TITLE     = 2'd0;
localparam [1:0] GAME_PLAY      = 2'd1;
localparam [1:0] GAME_WIN       = 2'd2;

// Fixed Map Landmarks (match scripts/gen_assets.py ASCII_MAP)
localparam [14:0] SPAWN_X       = 15'd2560;  // tile 2.5
localparam [14:0] SPAWN_Y       = 15'd4608;  // tile 4.5
localparam [7:0]  SPAWN_ANGLE   = 8'd0;      // facing East

localparam [4:0] LENS1_TX       = 5'd26;
localparam [4:0] LENS1_TY       = 5'd6;
localparam [4:0] LENS2_TX       = 5'd26;
localparam [4:0] LENS2_TY       = 5'd24;
localparam [4:0] THIN_TX        = 5'd26;
localparam [4:0] THIN_TY        = 5'd20;
localparam [4:0] DOOR_TX        = 5'd19;
localparam [4:0] DOOR_TY        = 5'd30;

// ---------------------------------------------------------------------------
// Video pipeline depth (ADR-0008).
// Every renderer presents its RGB exactly PIPE_STAGES pix_ce ticks after the
// pixel_x/pixel_y it belongs to; top_depth delays HS/VS/DE by the same amount,
// so the picture on the monitor is unchanged.
// ---------------------------------------------------------------------------
localparam integer PIPE_STAGES  = 6;
