// ============================================================================
// File Name   : dot_prod_pkg.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-02
// Description : Shared dot-product constants and conservative helper
//               functions for synthesizable dot-product RTL.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-06-02  v0.1      LIU YUXUAN       Initial version
// ============================================================================

package dot_prod_pkg;
    localparam int DOT_FP32_W      = 32;
    localparam int DOT_FP32_EXP_W  = 8;
    localparam int DOT_FP32_FRAC_W = 23;
    localparam int DOT_FP32_SIG_W  = 24;

    localparam logic [1:0] DOT_SPECIAL_NONE    = 2'd0;
    localparam logic [1:0] DOT_SPECIAL_NAN     = 2'd1;
    localparam logic [1:0] DOT_SPECIAL_POS_INF = 2'd2;
    localparam logic [1:0] DOT_SPECIAL_NEG_INF = 2'd3;

    localparam logic [1:0] DOT_F16TF32_DTYPE_TF32 = 2'd0;
    localparam logic [1:0] DOT_F16TF32_DTYPE_BF16 = 2'd1;
    localparam logic [1:0] DOT_F16TF32_DTYPE_FP16 = 2'd2;
    localparam logic [1:0] DOT_F16TF32_DTYPE_RSVD = DOT_F16TF32_DTYPE_FP16 + 2'd1;

    localparam int DOT_F16TF32_FP16_W             = 16;
    localparam int DOT_F16TF32_NUM_ELEMS          = 16;
    localparam int DOT_F16TF32_TF32_NUM_ELEMS     = 8;
    localparam int DOT_F16TF32_SIG_W              = 11;
    localparam int DOT_F16TF32_FP16_EXP_W         = 5;
    localparam int DOT_F16TF32_FP16_FRAC_W        = 10;
    localparam int DOT_F16TF32_BF16_EXP_W         = 8;
    localparam int DOT_F16TF32_BF16_FRAC_W        = 7;
    localparam int DOT_F16TF32_TF32_FRAC_W        = 10;
    localparam int DOT_F16TF32_BF16_SIG_PAD_W     = DOT_F16TF32_FP16_FRAC_W - DOT_F16TF32_BF16_FRAC_W;
    localparam int DOT_F16TF32_EXP_W              = 9;
    localparam int DOT_F16TF32_PROD_SIG_W         = 22;
    localparam int DOT_F16TF32_PROD_SIG_FRAC_BITS = 20;
    localparam int DOT_F16TF32_ALIGN_FRAC_BITS    = 25;
    localparam int DOT_F16TF32_ALIGN_INT_BITS     = 7;
    localparam int DOT_F16TF32_ALIGN_MAG_W        = DOT_F16TF32_ALIGN_INT_BITS + DOT_F16TF32_ALIGN_FRAC_BITS;
    localparam int DOT_F16TF32_ALIGN_TERM_W       = DOT_F16TF32_ALIGN_MAG_W + 1;
    localparam int DOT_F16TF32_SUM_W              = DOT_F16TF32_ALIGN_TERM_W;
    localparam int DOT_F16TF32_PROD_ALIGN_PAD_W   = DOT_F16TF32_ALIGN_FRAC_BITS - DOT_F16TF32_PROD_SIG_FRAC_BITS;
    localparam int DOT_F16TF32_C_ALIGN_PAD_W      = DOT_F16TF32_ALIGN_FRAC_BITS - DOT_FP32_FRAC_W;
    localparam int DOT_F16TF32_ACC_L0_TERMS       = DOT_F16TF32_NUM_ELEMS + 1;
    localparam int DOT_F16TF32_ACC_L1_TERMS       = (DOT_F16TF32_ACC_L0_TERMS + 1) / 2;
    localparam int DOT_F16TF32_ACC_L2_TERMS       = (DOT_F16TF32_ACC_L1_TERMS + 1) / 2;
    localparam int DOT_F16TF32_ACC_L3_TERMS       = (DOT_F16TF32_ACC_L2_TERMS + 1) / 2;
    localparam int DOT_F16TF32_ACC_L4_TERMS       = (DOT_F16TF32_ACC_L3_TERMS + 1) / 2;
    localparam int DOT_F16TF32_EMAX_L0_TERMS      = DOT_F16TF32_NUM_ELEMS + 1;
    localparam int DOT_F16TF32_EMAX_L1_TERMS      = (DOT_F16TF32_EMAX_L0_TERMS + 1) / 2;
    localparam int DOT_F16TF32_EMAX_L2_TERMS      = (DOT_F16TF32_EMAX_L1_TERMS + 1) / 2;
    localparam int DOT_F16TF32_EMAX_L3_TERMS      = (DOT_F16TF32_EMAX_L2_TERMS + 1) / 2;
    localparam int DOT_F16TF32_EMAX_L4_TERMS      = (DOT_F16TF32_EMAX_L3_TERMS + 1) / 2;
    localparam logic signed [DOT_F16TF32_EXP_W-1:0] DOT_F16TF32_ALIGN_FRAC_BITS_EXP = 9'sd25;
    localparam logic signed [DOT_F16TF32_EXP_W:0]   DOT_F16TF32_ALIGN_MAG_W_EXP     = 10'sd32;
    localparam logic signed [DOT_F16TF32_EXP_W-1:0] DOT_F16TF32_EMAX_MIN_EXP        =
        {1'b1, {(DOT_F16TF32_EXP_W-1){1'b0}}};

    localparam int DOT_F4F6F8_FP8_W              = 8;
    localparam int DOT_F4F6F8_FP6_W              = 6;
    localparam int DOT_F4F6F8_FP4_W              = 4;
    localparam int DOT_F4F6F8_NUM_ELEMS          = 32;
    localparam int DOT_F4F6F8_FP8_SIG_W          = 4;
    localparam int DOT_F4F6F8_PROD_SIG_W         = 8;
    localparam int DOT_F4F6F8_C_SIG_W            = DOT_FP32_SIG_W;
    localparam int DOT_F4F6F8_MX_SCALE_W         = 8;
    localparam int DOT_F4F6F8_PROD_EMAX_PARTS    = 8;
    localparam int DOT_F4F6F8_LANE_EXP_W         = 5;
    localparam int DOT_F4F6F8_PROD_EXP_W         = 6;
    localparam int DOT_F4F6F8_FULL_EXP_W         = 10;
    localparam int DOT_F4F6F8_ALIGN_FRAC_BITS    = 25;
    localparam int DOT_F4F6F8_ALIGN_TERM_W       = 28;
    localparam int DOT_F4F6F8_SUM_W              = 33;
    localparam int DOT_F4F6F8_ACC_PARTIALS       = 5;
    localparam int DOT_F4F6F8_PROD_SIG_FRAC_BITS = 6;
    localparam int DOT_F4F6F8_C_SIG_FRAC_BITS    = DOT_FP32_FRAC_W;
    localparam int DOT_F4F6F8_PROD_ALIGN_PAD_W   = DOT_F4F6F8_ALIGN_FRAC_BITS -
                                                   DOT_F4F6F8_PROD_SIG_FRAC_BITS;
    localparam int DOT_F4F6F8_C_ALIGN_PAD_W      = DOT_F4F6F8_ALIGN_FRAC_BITS -
                                                   DOT_F4F6F8_C_SIG_FRAC_BITS;
    localparam logic signed [DOT_F4F6F8_FULL_EXP_W-1:0] DOT_F4F6F8_ALIGN_FRAC_BITS_EXP = 10'sd25;
    localparam logic signed [DOT_F4F6F8_FULL_EXP_W-1:0] DOT_F4F6F8_MX_SCALE_BIAS_EXP   = 10'sd127;
    localparam logic signed [DOT_F4F6F8_LANE_EXP_W-1:0] DOT_F4F6F8_FP6_E2M3_BIAS_EXP   = 5'sd1;
    localparam logic signed [DOT_F4F6F8_LANE_EXP_W-1:0] DOT_F4F6F8_FP6_E3M2_BIAS_EXP   = 5'sd3;
    localparam logic signed [DOT_F4F6F8_FULL_EXP_W:0]   DOT_F4F6F8_ALIGN_TERM_M1_EXP   = 11'sd27;
    localparam logic DOT_F4F6F8_FP6_FMT_E2M3 = 1'b0;
    localparam logic DOT_F4F6F8_FP6_FMT_E3M2 = 1'b1;
    localparam logic [2:0] DOT_F4F6F8_DTYPE_E4M3 = 3'd0;
    localparam logic [2:0] DOT_F4F6F8_DTYPE_E5M2 = 3'd1;
    localparam logic [2:0] DOT_F4F6F8_DTYPE_E2M3 = 3'd2;
    localparam logic [2:0] DOT_F4F6F8_DTYPE_E3M2 = 3'd3;
    localparam logic [2:0] DOT_F4F6F8_DTYPE_E2M1 = 3'd4;

    localparam int DOT_INT8_ELEM_W           = 8;
    localparam int DOT_INT8_NUM_ELEMS        = 32;
    localparam int DOT_INT8_OP_W             = 9;
    localparam int DOT_INT8_PROD_W           = 18;
    localparam int DOT_INT8_PSUM_W           = 22;
    localparam int DOT_INT8_SUM_W            = 33;
    localparam int DOT_INT8_REDUCE_L1_GROUPS = 16;
    localparam int DOT_INT8_REDUCE_L2_GROUPS = 8;
    localparam int DOT_INT8_REDUCE_L3_GROUPS = 4;
    localparam int DOT_INT8_REDUCE_L4_GROUPS = 2;
    localparam int DOT_INT8_STAGE0_W         = DOT_INT8_NUM_ELEMS*DOT_INT8_PROD_W + 32 + 1;
    localparam int DOT_INT8_STAGE1_W         = DOT_INT8_PSUM_W + 32 + 1;
    localparam int DOT_INT8_STAGE3_W         = 32 + 1;
    localparam logic signed [DOT_INT8_SUM_W-1:0] DOT_INT8_INT32_MAX_EXT = 33'sh0_7fff_ffff;
    localparam logic signed [DOT_INT8_SUM_W-1:0] DOT_INT8_INT32_MIN_EXT = 33'sh1_8000_0000;

    localparam int DOT_FP4_W                  = 4;
    localparam int DOT_FP4_NUM_ELEMS          = 64;
    localparam int DOT_FP4_BLOCK_SIZE         = 16;
    localparam int DOT_FP4_NUM_BLOCKS         = 4;
    localparam logic [1:0] DOT_FP4_MODE_NVFP4    = 2'd0;
    localparam logic [1:0] DOT_FP4_MODE_MXFP4    = 2'd1;
    localparam logic [1:0] DOT_FP4_MODE_FP4      = 2'd2;
    localparam logic [1:0] DOT_FP4_MODE_MXFP4_4X = 2'd3;
    localparam int DOT_FP4_SCALE_W            = 8;
    localparam int DOT_FP4_PROD_W             = 9;
    localparam int DOT_FP4_SIGMA_W            = 13;
    localparam int DOT_FP4_SF_SIG_W           = 4;
    localparam int DOT_FP4_SF_EXP_W           = 9;
    localparam int DOT_FP4_SF_SIG_PROD_W      = 8;
    localparam int DOT_FP4_SF_EXP_SUM_W       = 10;
    localparam int DOT_FP4_GAMMA_SIG_W        = 20;
    localparam int DOT_FP4_C_SIG_W            = DOT_FP32_SIG_W;
    localparam int DOT_FP4_C_EXP_W            = 10;
    localparam int DOT_FP4_EXP_DIFF_W         = DOT_FP4_C_EXP_W + 1;
    localparam int DOT_FP4_ALIGN_FRAC_W       = 35;
    localparam int DOT_FP4_ALIGN_INT_W        = 11;
    localparam int DOT_FP4_ALIGN_MAG_W        = DOT_FP4_ALIGN_FRAC_W + DOT_FP4_ALIGN_INT_W;
    localparam int DOT_FP4_ALIGN_TERM_W       = DOT_FP4_ALIGN_MAG_W + 1;
    localparam int DOT_FP4_ALIGN_SHIFT_W      = $clog2(DOT_FP4_ALIGN_MAG_W + 1);
    localparam int DOT_FP4_SUM_W              = DOT_FP4_ALIGN_TERM_W + 2;
    localparam logic signed [DOT_FP4_C_EXP_W-1:0] DOT_FP4_DOT_EXP           = -10'sd2;
    localparam logic signed [DOT_FP4_C_EXP_W-1:0] DOT_FP4_ALIGN_FRAC_EXP    = 10'sd35;
    localparam logic signed [DOT_FP4_C_EXP_W-1:0] DOT_FP4_GAMMA_NORM_EXP    = 10'sd8;
    localparam logic signed [DOT_FP4_C_EXP_W-1:0] DOT_FP4_EMAX_REL_BIAS_EXP =
        DOT_FP4_DOT_EXP + DOT_FP4_GAMMA_NORM_EXP;
    localparam logic signed [DOT_FP4_C_EXP_W-1:0] DOT_FP4_C_NORM_EXP        = 10'sd23;
    localparam logic signed [DOT_FP4_C_EXP_W-1:0] DOT_FP4_C_REL_NORM_EXP    =
        DOT_FP4_C_NORM_EXP - DOT_FP4_EMAX_REL_BIAS_EXP;
    localparam int DOT_FP4_GAMMA_ALIGN_LSHIFT_W = DOT_FP4_ALIGN_FRAC_W -
                                                  int'(DOT_FP4_GAMMA_NORM_EXP);
    localparam int DOT_FP4_C_ALIGN_LSHIFT_W     = DOT_FP4_ALIGN_FRAC_W -
                                                  int'(DOT_FP4_C_NORM_EXP);
    localparam int DOT_FP4_C_ALIGN_PAD_W        = DOT_FP4_ALIGN_MAG_W -
                                                  DOT_FP4_C_SIG_W -
                                                  DOT_FP4_C_ALIGN_LSHIFT_W;

    localparam int DOT_FP32_CLS_W        = 35;
    localparam int DOT_FP32_CLS_SIGN_BIT = 34;
    localparam int DOT_FP32_CLS_EXP_MSB  = 33;
    localparam int DOT_FP32_CLS_FRAC_MSB = 25;
    localparam int DOT_FP32_CLS_ZERO_BIT = 2;
    localparam int DOT_FP32_CLS_INF_BIT  = 1;
    localparam int DOT_FP32_CLS_NAN_BIT  = 0;

    function automatic logic [DOT_FP32_CLS_W-1:0] dot_fp32_classify(
        input logic [DOT_FP32_W-1:0] fp32_i
    );
        logic                         sign;
        logic [DOT_FP32_EXP_W-1:0]    exp_raw;
        logic [DOT_FP32_FRAC_W-1:0]   frac_raw;
        logic                         is_zero;
        logic                         is_inf;
        logic                         is_nan;
        begin
            sign     = fp32_i[DOT_FP32_W-1];
            exp_raw  = fp32_i[DOT_FP32_W-2 -: DOT_FP32_EXP_W];
            frac_raw = fp32_i[DOT_FP32_FRAC_W-1:0];
            is_zero  = (exp_raw == {DOT_FP32_EXP_W{1'b0}}) &&
                       (frac_raw == {DOT_FP32_FRAC_W{1'b0}});
            is_inf   = (exp_raw == {DOT_FP32_EXP_W{1'b1}}) &&
                       (frac_raw == {DOT_FP32_FRAC_W{1'b0}});
            is_nan   = (exp_raw == {DOT_FP32_EXP_W{1'b1}}) &&
                       (frac_raw != {DOT_FP32_FRAC_W{1'b0}});
            dot_fp32_classify = {sign, exp_raw, frac_raw, is_zero, is_inf, is_nan};
        end
    endfunction

    function automatic logic [DOT_FP32_W-1:0] dot_pack_special_fp32(
        input logic [1:0] special_code_i
    );
        begin
            case (special_code_i)
                DOT_SPECIAL_NAN: begin
                    dot_pack_special_fp32 = 32'h7fff_ffff;
                end
                DOT_SPECIAL_POS_INF: begin
                    dot_pack_special_fp32 = 32'h7f80_0000;
                end
                DOT_SPECIAL_NEG_INF: begin
                    dot_pack_special_fp32 = 32'hff80_0000;
                end
                default: begin
                    dot_pack_special_fp32 = 32'h0000_0000;
                end
            endcase
        end
    endfunction

    function automatic logic [DOT_FP32_W-1:0] dot_pack_fp32_fields_rz(
        input logic                         sign_i,
        input integer                       unbiased_exp_i,
        input logic [DOT_FP32_SIG_W-1:0]    sig24_i
    );
        logic [DOT_FP32_SIG_W-1:0]  sig24;
        logic [DOT_FP32_FRAC_W-1:0] frac_field;
        logic [DOT_FP32_EXP_W-1:0]  exp_field;
        integer                     shift_sub;
        begin
            sig24       = sig24_i;
            frac_field  = '0;
            exp_field   = '0;
            shift_sub   = 0;

            if (unbiased_exp_i > 127) begin
                exp_field  = 8'hff;
                frac_field = 23'h0;
            end else if (unbiased_exp_i >= -126) begin
                exp_field  = 8'(unbiased_exp_i + 127);
                frac_field = sig24[DOT_FP32_FRAC_W-1:0];
            end else if (unbiased_exp_i < -149) begin
                exp_field  = 8'h00;
                frac_field = 23'h0;
            end else begin
                shift_sub  = -126 - unbiased_exp_i;
                sig24      = sig24 >> shift_sub;
                exp_field  = 8'h00;
                frac_field = sig24[DOT_FP32_FRAC_W-1:0];
            end

            dot_pack_fp32_fields_rz = {sign_i, exp_field, frac_field};
        end
    endfunction
endpackage
