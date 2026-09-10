// ============================================================================
// File Name   : blackwell_pkg.sv
// Description : Constants shared by the Blackwell-style baseline RTL.
// ============================================================================

package blackwell_pkg;
    localparam logic [2:0] BW_CMD_TMA_REQ       = 3'd0;
    localparam logic [2:0] BW_CMD_MMA           = 3'd1;
    localparam logic [2:0] BW_CMD_COMMIT        = 3'd2;
    localparam logic [2:0] BW_CMD_WAIT          = 3'd3;
    localparam logic [2:0] BW_CMD_STORE         = 3'd4;
    localparam logic [2:0] BW_CMD_MBARRIER_WAIT = 3'd5;

    localparam logic [7:0] BW_STATUS_OK             = 8'h00;
    localparam logic [7:0] BW_STATUS_SMEM_READ      = 8'h10;
    localparam logic [7:0] BW_STATUS_SMEM_WRITE     = 8'h11;
    localparam logic [7:0] BW_STATUS_TC             = 8'h12;
    localparam logic [7:0] BW_STATUS_TMEM           = 8'h13;
    localparam logic [7:0] BW_STATUS_TMA            = 8'h14;
    localparam logic [7:0] BW_STATUS_BAD_OPCODE     = 8'h20;
    localparam logic [7:0] BW_STATUS_BAD_ALIGNMENT  = 8'h21;

    localparam int unsigned BW_TILE_M = 64;
    localparam int unsigned BW_TILE_N = 8;
    localparam int unsigned BW_TILE_K = 16;
    localparam int unsigned BW_SMEM_BEAT_W = 256;
endpackage
