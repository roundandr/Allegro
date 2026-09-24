package tcgen05_mma_pkg;
    localparam logic [1:0] TCGEN05_OP_MMA   = 2'd0;
    localparam logic [1:0] TCGEN05_OP_SP    = 2'd1;
    localparam logic [1:0] TCGEN05_OP_WS    = 2'd2;
    localparam logic [1:0] TCGEN05_OP_WS_SP = 2'd3;

    localparam logic [3:0] TCGEN05_KIND_F16       = 4'd0;
    localparam logic [3:0] TCGEN05_KIND_TF32      = 4'd1;
    localparam logic [3:0] TCGEN05_KIND_F8F6F4    = 4'd2;
    localparam logic [3:0] TCGEN05_KIND_I8        = 4'd3;
    localparam logic [3:0] TCGEN05_KIND_MXF8F6F4  = 4'd4;
    localparam logic [3:0] TCGEN05_KIND_MXF4      = 4'd5;
    localparam logic [3:0] TCGEN05_KIND_MXF4NVF4  = 4'd6;

    localparam logic [3:0] TCGEN05_TYPE_F32   = 4'd0;
    localparam logic [3:0] TCGEN05_TYPE_F16   = 4'd1;
    localparam logic [3:0] TCGEN05_TYPE_BF16  = 4'd2;
    localparam logic [3:0] TCGEN05_TYPE_TF32  = 4'd3;
    localparam logic [3:0] TCGEN05_TYPE_E4M3  = 4'd4;
    localparam logic [3:0] TCGEN05_TYPE_E5M2  = 4'd5;
    localparam logic [3:0] TCGEN05_TYPE_E2M3  = 4'd6;
    localparam logic [3:0] TCGEN05_TYPE_E3M2  = 4'd7;
    localparam logic [3:0] TCGEN05_TYPE_E2M1  = 4'd8;
    localparam logic [3:0] TCGEN05_TYPE_S8    = 4'd9;
    localparam logic [3:0] TCGEN05_TYPE_U8    = 4'd10;
    localparam logic [3:0] TCGEN05_TYPE_S32   = 4'd11;

    localparam logic [2:0] TCGEN05_SCALE_NONE    = 3'd0;
    localparam logic [2:0] TCGEN05_SCALE_UE8M0   = 3'd1;
    localparam logic [2:0] TCGEN05_SCALE_UE4M3   = 3'd2;

    localparam logic [2:0] TCGEN05_SCALE_VEC_NONE    = 3'd0;
    localparam logic [2:0] TCGEN05_SCALE_VEC_1X      = 3'd1;
    localparam logic [2:0] TCGEN05_SCALE_VEC_2X      = 3'd2;
    localparam logic [2:0] TCGEN05_SCALE_VEC_4X      = 3'd3;
    localparam logic [2:0] TCGEN05_SCALE_VEC_BLOCK16 = 3'd4;
    localparam logic [2:0] TCGEN05_SCALE_VEC_BLOCK32 = 3'd5;

    localparam logic [7:0] TCGEN05_STATUS_OK                  = 8'h00;
    localparam logic [7:0] TCGEN05_STATUS_UNSUPPORTED         = 8'h01;
    localparam logic [7:0] TCGEN05_STATUS_INVALID_SPARSE_META = 8'h02;
    localparam logic [7:0] TCGEN05_STATUS_INT_OVERFLOW        = 8'h04;
endpackage
