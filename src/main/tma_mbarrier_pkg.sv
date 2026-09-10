// ============================================================================
// File Name   : tma_mbarrier_pkg.sv
// Date        : 2026-08-27
// Description : Public constants for the patent-inspired TMA/mbarrier model.
//
// This package describes an independently designed research interface.  It is
// not an NVIDIA ISA encoding and is not intended to be cycle accurate to a
// proprietary implementation.
// ============================================================================

package tma_mbarrier_pkg;
    localparam int unsigned TMA_DESC_W = 1024;
    localparam int unsigned TMA_DIMS   = 5;

    // TMA command opcodes.
    localparam logic [2:0] TMA_OP_LOAD_TENSOR  = 3'd0;
    localparam logic [2:0] TMA_OP_STORE_TENSOR = 3'd1;
    localparam logic [2:0] TMA_OP_LOAD_LINEAR  = 3'd2;
    localparam logic [2:0] TMA_OP_STORE_LINEAR = 3'd3;
    localparam logic [2:0] TMA_OP_DESC_INV     = 3'd4;

    // mbarrier command opcodes.  Transaction completion is an internal source
    // and therefore is not exposed as a software command.
    localparam logic [2:0] MBAR_OP_INIT              = 3'd0;
    localparam logic [2:0] MBAR_OP_ARRIVE            = 3'd1;
    localparam logic [2:0] MBAR_OP_EXPECT_TX         = 3'd2;
    localparam logic [2:0] MBAR_OP_ARRIVE_EXPECT_TX  = 3'd3;
    localparam logic [2:0] MBAR_OP_TRY_WAIT          = 3'd4;

    // Common status values.
    localparam logic [7:0] TMA_STATUS_OK             = 8'h00;
    localparam logic [7:0] TMA_STATUS_BAD_OPCODE     = 8'h20;
    localparam logic [7:0] TMA_STATUS_BAD_DESC_ALIGN = 8'h21;
    localparam logic [7:0] TMA_STATUS_BAD_DESC       = 8'h22;
    localparam logic [7:0] TMA_STATUS_BAD_DIM        = 8'h23;
    localparam logic [7:0] TMA_STATUS_BAD_ELEM       = 8'h24;
    localparam logic [7:0] TMA_STATUS_BAD_SMEM_ALIGN = 8'h25;
    localparam logic [7:0] TMA_STATUS_ADDR_OVERFLOW  = 8'h26;
    localparam logic [7:0] TMA_STATUS_GMEM           = 8'h30;
    localparam logic [7:0] TMA_STATUS_SMEM           = 8'h31;
    localparam logic [7:0] TMA_STATUS_MBARRIER       = 8'h32;
    localparam logic [7:0] TMA_STATUS_INTERNAL       = 8'h3f;

    localparam logic [7:0] MBAR_STATUS_OK            = 8'h00;
    localparam logic [7:0] MBAR_STATUS_BAD_OPCODE    = 8'h40;
    localparam logic [7:0] MBAR_STATUS_UNINITIALIZED = 8'h41;
    localparam logic [7:0] MBAR_STATUS_LOCKED        = 8'h42;
    localparam logic [7:0] MBAR_STATUS_OVERFLOW      = 8'h43;
    localparam logic [7:0] MBAR_STATUS_BAD_ARRIVE    = 8'h44;
    localparam logic [7:0] MBAR_STATUS_MEMORY        = 8'h45;
    localparam logic [7:0] MBAR_STATUS_BAD_PHASE     = 8'h46;
    localparam logic [7:0] MBAR_STATUS_BAD_ALIGN     = 8'h47;
    localparam logic [7:0] MBAR_STATUS_INTERNAL      = 8'h4f;

    // 128-byte descriptor layout.  Multi-byte fields are little-endian when
    // represented in memory.  Unused high bits are reserved and must be zero.
    localparam int unsigned DESC_VERSION_LSB       = 0;
    localparam int unsigned DESC_DIMS_M1_LSB       = 8;
    localparam int unsigned DESC_ELEM_LOG2_LSB     = 11;
    localparam int unsigned DESC_GMEM_BASE_LSB     = 16;
    localparam int unsigned DESC_TENSOR_SIZE_LSB   = 80;
    localparam int unsigned DESC_TENSOR_STRIDE_LSB = 240;
    localparam int unsigned DESC_BOX_SIZE_LSB      = 560;
    localparam int unsigned DESC_TRAV_STRIDE_LSB   = 640;

    // 256-bit memory-backed barrier layout.
    localparam int unsigned BAR_STATE_VALID_BIT     = 0;
    localparam int unsigned BAR_STATE_PHASE_BIT     = 1;
    localparam int unsigned BAR_STATE_LOCK_BIT      = 2;
    localparam int unsigned BAR_STATE_EXPECTED_LSB  = 3;
    localparam int unsigned BAR_STATE_REMAINING_LSB = 19;
    localparam int unsigned BAR_STATE_TX_BAL_LSB    = 35;
endpackage
