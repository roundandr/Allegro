// ============================================================================
// File Name   : fp4_dot_prod.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-22
// Description : 64-element FP4 dot-product with NVFP4, MXFP4 block32,
//               MXFP4 block16, or unscaled FP4 mode and FP32 accumulate. The
//               datapath follows the 5-stage pipeline defined in doc/FP4_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-22  v0.1      LIU YUXUAN       Initial version
//   2026-04-28  v0.2      LIU YUXUAN       Add MXFP4 and unscaled FP4 modes
//   2026-05-22  v0.3      LIU YUXUAN       Add MXFP4 block16 scale mode
// ============================================================================

module fp4_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [255:0] a_fp4_i,
    input  logic [255:0] b_fp4_i,
    input  logic [1:0]   fp4_mode_i,
    input  logic [31:0]  a_sf_i,
    input  logic [31:0]  b_sf_i,
    input  logic [31:0]  c_fp32_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_fp32_o
);

    import dot_prod_pkg::*;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_SIGMA_W-1:0]   sigma_flat;
        logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_SF_SIG_PROD_W-1:0] sf_sig_prod_flat;
        logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_C_EXP_W-1:0]   gamma_rel_exp_flat;
        logic                    c_sign;
        logic [DOT_FP4_C_SIG_W-1:0]      c_sig;
        logic signed [DOT_FP4_C_EXP_W-1:0] c_rel_exp;
    } stage0_data_t;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic [DOT_FP4_NUM_BLOCKS-1:0]              gamma_sign_flat;
        logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_GAMMA_SIG_W-1:0]  gamma_mag_flat;
        logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_C_EXP_W-1:0]      gamma_rel_exp_flat;
        logic                    c_sign;
        logic [DOT_FP4_C_SIG_W-1:0]      c_mag;
        logic signed [DOT_FP4_C_EXP_W-1:0] c_rel_exp;
        logic signed [DOT_FP4_C_EXP_W-1:0] emax;
    } stage1_data_t;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_ALIGN_TERM_W-1:0] gamma_aligned_flat;
        logic signed [DOT_FP4_ALIGN_TERM_W-1:0] c_aligned;
        logic signed [DOT_FP4_C_EXP_W-1:0] base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic                    sum_sign;
        logic [DOT_FP4_SUM_W-1:0]        abs_sum;
        logic signed [DOT_FP4_C_EXP_W-1:0] base_exp;
    } stage3_data_t;

    typedef struct packed {
        logic [31:0] result;
    } stage4_data_t;

    stage0_data_t s0_d;
    stage1_data_t s1_d;
    stage2_data_t s2_d;
    stage3_data_t s3_d;
    stage4_data_t s4_d;

    stage0_data_t s0_q;
    stage1_data_t s1_q;
    stage2_data_t s2_q;
    stage3_data_t s3_q;
    stage4_data_t s4_q;

    logic s0_vld_q;
    logic s1_vld_q;
    logic s2_vld_q;
    logic s3_vld_q;
    logic s4_vld_q;

    logic s1_rdy;
    logic s2_rdy;
    logic s3_rdy;
    logic s4_rdy;

    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_SIGMA_W-1:0]   s0_sigma_flat_tmp;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_SF_SIG_PROD_W-1:0] s0_sf_sig_prod_flat_tmp;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_C_EXP_W-1:0]   s0_gamma_rel_exp_flat_tmp;

    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_SIGMA_W-1:0]   s0_sigma_flat_hold;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_SF_SIG_PROD_W-1:0] s0_sf_sig_prod_flat_hold;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_C_EXP_W-1:0]   s0_gamma_rel_exp_flat_hold;

    logic [DOT_FP4_NUM_BLOCKS-1:0]              s1_gamma_sign_flat_tmp;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_GAMMA_SIG_W-1:0]  s1_gamma_mag_flat_tmp;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_C_EXP_W-1:0]      s1_gamma_rel_exp_flat_tmp;

    logic [DOT_FP4_NUM_BLOCKS-1:0]              s1_gamma_sign_flat_hold;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_GAMMA_SIG_W-1:0]  s1_gamma_mag_flat_hold;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_C_EXP_W-1:0]      s1_gamma_rel_exp_flat_hold;

    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_ALIGN_TERM_W-1:0] s2_gamma_aligned_flat_tmp;
    logic [DOT_FP4_NUM_BLOCKS*DOT_FP4_ALIGN_TERM_W-1:0] s2_gamma_aligned_flat_hold;

    assign s0_sigma_flat_hold    = s0_q.sigma_flat;
    assign s0_sf_sig_prod_flat_hold = s0_q.sf_sig_prod_flat;
    assign s0_gamma_rel_exp_flat_hold = s0_q.gamma_rel_exp_flat;
    assign s1_gamma_sign_flat_hold = s1_q.gamma_sign_flat;
    assign s1_gamma_mag_flat_hold  = s1_q.gamma_mag_flat;
    assign s1_gamma_rel_exp_flat_hold  = s1_q.gamma_rel_exp_flat;
    assign s2_gamma_aligned_flat_hold = s2_q.gamma_aligned_flat;

    function automatic logic [3:0] fp4_mag2(input logic [2:0] code_i);
        begin
            case (code_i)
                3'd0: fp4_mag2 = 4'd0;
                3'd1: fp4_mag2 = 4'd1;
                3'd2: fp4_mag2 = 4'd2;
                3'd3: fp4_mag2 = 4'd3;
                3'd4: fp4_mag2 = 4'd4;
                3'd5: fp4_mag2 = 4'd6;
                3'd6: fp4_mag2 = 4'd8;
                default: fp4_mag2 = 4'd12;
            endcase
        end
    endfunction

    function automatic logic signed [DOT_FP4_PROD_W-1:0] fp4_product(
        input logic [DOT_FP4_W-1:0] a_i,
        input logic [DOT_FP4_W-1:0] b_i
    );
        logic [3:0] a_mag2;
        logic [3:0] b_mag2;
        logic [7:0] prod_mag;
        logic       prod_sign;
        logic signed [DOT_FP4_PROD_W-1:0] prod_signed;
        begin
            a_mag2    = fp4_mag2(a_i[2:0]);
            b_mag2    = fp4_mag2(b_i[2:0]);
            prod_mag  = a_mag2 * b_mag2;
            prod_sign = a_i[3] ^ b_i[3];
            prod_signed = $signed({1'b0, prod_mag});
            fp4_product = prod_sign ? -prod_signed : prod_signed;
        end
    endfunction

    function automatic logic [DOT_FP4_SF_EXP_W+4:0] decode_ue4m3_scale(input logic [DOT_FP4_SCALE_W-1:0] scale_i);
        logic [7:0] scale_eff;
        logic [3:0] exp_raw;
        logic [2:0] mant_raw;
        logic       is_nan;
        logic       is_zero;
        logic [3:0] sig;
        logic signed [DOT_FP4_SF_EXP_W-1:0] exp;
        begin
            scale_eff = {1'b0, scale_i[6:0]};
            exp_raw   = scale_eff[6:3];
            mant_raw  = scale_eff[2:0];

            is_nan  = (scale_eff[6:0] == 7'b111_1111);
            is_zero = (exp_raw == 4'b0000) && (mant_raw == 3'b000);

            if (is_zero) begin
                sig = 4'd0;
                exp = '0;
            end else if (exp_raw == 4'b0000) begin
                sig = {1'b0, mant_raw};
                exp = -9'sd9;
            end else begin
                sig = {1'b1, mant_raw};
                exp = $signed({{(DOT_FP4_SF_EXP_W-4){1'b0}}, exp_raw}) - 9'sd10;
            end

            decode_ue4m3_scale = {is_nan, sig, exp};
        end
    endfunction

    function automatic logic [DOT_FP4_SF_EXP_W+4:0] decode_e8m0_scale(input logic [DOT_FP4_SCALE_W-1:0] scale_i);
        logic       is_nan;
        logic [3:0] sig;
        logic signed [DOT_FP4_SF_EXP_W-1:0] exp;
        begin
            is_nan  = (scale_i == 8'hff);
            sig     = 4'd8;
            exp     = $signed({1'b0, scale_i}) - 9'sd130;
            decode_e8m0_scale = {is_nan, sig, exp};
        end
    endfunction

    function automatic logic [DOT_FP4_SF_EXP_W+4:0] make_unit_scale();
        logic       is_nan;
        logic [3:0] sig;
        logic signed [DOT_FP4_SF_EXP_W-1:0] exp;
        begin
            is_nan = 1'b0;
            sig = 4'd8;
            exp = -9'sd3;
            make_unit_scale = {is_nan, sig, exp};
        end
    endfunction

    function automatic logic [37:0] decode_c(input logic [31:0] c_i);
        logic [DOT_FP32_CLS_W-1:0]  cls;
        logic [DOT_FP32_EXP_W-1:0]  exp_raw;
        logic [DOT_FP32_FRAC_W-1:0] frac_raw;
        logic [DOT_FP4_C_SIG_W-1:0] sig;
        logic signed [DOT_FP4_C_EXP_W-1:0] exp;
        begin
            cls = dot_fp32_classify(c_i);
            exp_raw  = cls[DOT_FP32_CLS_EXP_MSB -: DOT_FP32_EXP_W];
            frac_raw = cls[DOT_FP32_CLS_FRAC_MSB -: DOT_FP32_FRAC_W];

            if (cls[DOT_FP32_CLS_ZERO_BIT]) begin
                sig = '0;
                exp = '0;
            end else if (exp_raw == 8'h00) begin
                sig = {1'b0, frac_raw};
                exp = -10'sd149;
            end else begin
                sig = {1'b1, frac_raw};
                exp = $signed({1'b0, exp_raw}) - 10'sd150;
            end

            decode_c = {cls[DOT_FP32_CLS_SIGN_BIT],
                        cls[DOT_FP32_CLS_ZERO_BIT],
                        cls[DOT_FP32_CLS_NAN_BIT],
                        cls[DOT_FP32_CLS_INF_BIT],
                        sig,
                        exp};
        end
    endfunction

    function automatic logic signed [DOT_FP4_ALIGN_TERM_W-1:0] align_fixed_rz(
        input logic                           term_sign_i,
        input logic [DOT_FP4_ALIGN_MAG_W-1:0]         term_mag_i,
        input logic signed [DOT_FP4_C_EXP_W-1:0]      term_exp_i,
        input logic signed [DOT_FP4_C_EXP_W-1:0]      emax_i
    );
        logic [DOT_FP4_ALIGN_MAG_W-1:0] aligned_mag;
        logic signed [DOT_FP4_ALIGN_TERM_W-1:0] aligned_val;
        logic signed [DOT_FP4_EXP_DIFF_W-1:0] align_shift;
        logic [DOT_FP4_ALIGN_SHIFT_W-1:0] shift_amt;
        begin
            if (term_mag_i == '0) begin
                align_fixed_rz = '0;
            end else begin
                // term_mag_i is already wired into the 35-fractional-bit
                // accumulator domain. Alignment after emax search is RZ
                // right shift by emax - normalized_exp.
                align_shift = $signed({{(DOT_FP4_EXP_DIFF_W-DOT_FP4_C_EXP_W){emax_i[DOT_FP4_C_EXP_W-1]}}, emax_i})
                            - $signed({{(DOT_FP4_EXP_DIFF_W-DOT_FP4_C_EXP_W){term_exp_i[DOT_FP4_C_EXP_W-1]}},
                                      term_exp_i});

                if (align_shift <= $signed({DOT_FP4_EXP_DIFF_W{1'b0}})) begin
                    aligned_mag = term_mag_i;
                end else if (align_shift >= $signed(DOT_FP4_EXP_DIFF_W'(DOT_FP4_ALIGN_MAG_W))) begin
                    aligned_mag = '0;
                end else begin
                    shift_amt = align_shift[DOT_FP4_ALIGN_SHIFT_W-1:0];
                    aligned_mag = term_mag_i >> shift_amt;
                end

                aligned_val = $signed({1'b0, aligned_mag});
                align_fixed_rz = term_sign_i ? -aligned_val : aligned_val;
            end
        end
    endfunction

    function automatic logic [31:0] pack_fp32_rz(
        input logic                    sum_sign_i,
        input logic [DOT_FP4_SUM_W-1:0]        abs_sum_i,
        input logic signed [DOT_FP4_C_EXP_W-1:0] base_exp_i
    );
        logic [DOT_FP4_SUM_W-1:0] norm_sum;
        logic [23:0]      sig24;
        integer           msb_idx;
        integer           norm_lshift;
        integer           unbiased_exp;
        integer           i;
        begin
            if (abs_sum_i == '0) begin
                pack_fp32_rz = 32'h0000_0000;
            end else begin
                msb_idx = 0;
                for (i = 0; i < DOT_FP4_SUM_W; i = i + 1) begin
                    if (abs_sum_i[i]) begin
                        msb_idx = i;
                    end
                end

                unbiased_exp = int'($signed(base_exp_i)) + msb_idx;
                norm_lshift  = (DOT_FP4_SUM_W - 1) - msb_idx;
                norm_sum     = abs_sum_i << norm_lshift;
                sig24        = norm_sum[DOT_FP4_SUM_W-1 -: 24];
                pack_fp32_rz = dot_pack_fp32_fields_rz(sum_sign_i, unbiased_exp, sig24);

                if (pack_fp32_rz[30:0] == 31'd0) begin
                    pack_fp32_rz = 32'h0000_0000;
                end
            end
        end
    endfunction

    integer g0;
    integer g1;
    integer g3;
    integer g4;
    integer k0;
    logic [DOT_FP4_SF_EXP_W+4:0] scale_dec_a;
    logic [DOT_FP4_SF_EXP_W+4:0] scale_dec_b;
    logic [37:0]         c_dec;
    logic        any_scale_nan;
    logic signed [DOT_FP4_SIGMA_W-1:0]    sigma_acc_s0;
    logic signed [DOT_FP4_PROD_W-1:0] fp4_prod_tmp_s0;
    logic signed [DOT_FP4_SF_EXP_W-1:0]   a_sf_exp_tmp_s0;
    logic signed [DOT_FP4_SF_EXP_W-1:0]   b_sf_exp_tmp_s0;
    logic signed [DOT_FP4_SF_EXP_SUM_W-1:0] sf_exp_sum_tmp_s0;
    logic signed [DOT_FP4_C_EXP_W-1:0]    gamma_rel_exp_tmp_s0;
    logic signed [DOT_FP4_C_EXP_W-1:0]    c_rel_exp_s0_tmp;
    logic                         c_emax_vld_s0;

    always_comb begin
        s0_d = '0;
        any_scale_nan = 1'b0;
        s0_sigma_flat_tmp    = '0;
        s0_sf_sig_prod_flat_tmp = '0;
        s0_gamma_rel_exp_flat_tmp = '0;
        sigma_acc_s0         = '0;
        fp4_prod_tmp_s0      = '0;
        a_sf_exp_tmp_s0      = '0;
        b_sf_exp_tmp_s0      = '0;
        sf_exp_sum_tmp_s0    = '0;
        gamma_rel_exp_tmp_s0 = '0;
        c_rel_exp_s0_tmp     = '0;
        c_emax_vld_s0        = 1'b0;

        for (g0 = 0; g0 < DOT_FP4_NUM_BLOCKS; g0 = g0 + 1) begin
            sigma_acc_s0 = '0;
            for (k0 = 0; k0 < DOT_FP4_BLOCK_SIZE; k0 = k0 + 1) begin
                fp4_prod_tmp_s0 =
                    fp4_product(a_fp4_i[(g0*DOT_FP4_BLOCK_SIZE+k0)*DOT_FP4_W +: DOT_FP4_W],
                                b_fp4_i[(g0*DOT_FP4_BLOCK_SIZE+k0)*DOT_FP4_W +: DOT_FP4_W]);
                sigma_acc_s0 = sigma_acc_s0
                              + $signed({{(DOT_FP4_SIGMA_W-DOT_FP4_PROD_W){fp4_prod_tmp_s0[DOT_FP4_PROD_W-1]}},
                                         fp4_prod_tmp_s0});
            end
            s0_sigma_flat_tmp[g0*DOT_FP4_SIGMA_W +: DOT_FP4_SIGMA_W] = sigma_acc_s0;

            case (fp4_mode_i)
                DOT_FP4_MODE_MXFP4: begin
                    scale_dec_a = decode_e8m0_scale(a_sf_i[(g0 >> 1)*DOT_FP4_SCALE_W +: DOT_FP4_SCALE_W]);
                    scale_dec_b = decode_e8m0_scale(b_sf_i[(g0 >> 1)*DOT_FP4_SCALE_W +: DOT_FP4_SCALE_W]);
                end
                DOT_FP4_MODE_MXFP4_4X: begin
                    scale_dec_a = decode_e8m0_scale(a_sf_i[g0*DOT_FP4_SCALE_W +: DOT_FP4_SCALE_W]);
                    scale_dec_b = decode_e8m0_scale(b_sf_i[g0*DOT_FP4_SCALE_W +: DOT_FP4_SCALE_W]);
                end
                DOT_FP4_MODE_FP4: begin
                    scale_dec_a = make_unit_scale();
                    scale_dec_b = make_unit_scale();
                end
                default: begin
                    scale_dec_a = decode_ue4m3_scale(a_sf_i[g0*DOT_FP4_SCALE_W +: DOT_FP4_SCALE_W]);
                    scale_dec_b = decode_ue4m3_scale(b_sf_i[g0*DOT_FP4_SCALE_W +: DOT_FP4_SCALE_W]);
                end
            endcase
            s0_sf_sig_prod_flat_tmp[g0*DOT_FP4_SF_SIG_PROD_W +: DOT_FP4_SF_SIG_PROD_W] =
                scale_dec_a[DOT_FP4_SF_EXP_W+3:DOT_FP4_SF_EXP_W] * scale_dec_b[DOT_FP4_SF_EXP_W+3:DOT_FP4_SF_EXP_W];
            a_sf_exp_tmp_s0 = $signed(scale_dec_a[DOT_FP4_SF_EXP_W-1:0]);
            b_sf_exp_tmp_s0 = $signed(scale_dec_b[DOT_FP4_SF_EXP_W-1:0]);
            sf_exp_sum_tmp_s0 = a_sf_exp_tmp_s0 + b_sf_exp_tmp_s0;
            gamma_rel_exp_tmp_s0 = $signed(sf_exp_sum_tmp_s0);
            s0_gamma_rel_exp_flat_tmp[g0*DOT_FP4_C_EXP_W +: DOT_FP4_C_EXP_W] = gamma_rel_exp_tmp_s0;
            any_scale_nan = any_scale_nan | scale_dec_a[DOT_FP4_SF_EXP_W+4] | scale_dec_b[DOT_FP4_SF_EXP_W+4];
        end

        c_dec = decode_c(c_fp32_i);
        c_emax_vld_s0 = (c_dec[33:10] != '0);
        if (c_emax_vld_s0) begin
            c_rel_exp_s0_tmp = $signed(c_dec[9:0]) + DOT_FP4_C_REL_NORM_EXP;
        end

        s0_d.sigma_flat    = s0_sigma_flat_tmp;
        s0_d.sf_sig_prod_flat = s0_sf_sig_prod_flat_tmp;
        s0_d.gamma_rel_exp_flat = s0_gamma_rel_exp_flat_tmp;

        s0_d.c_sign   = c_dec[37];
        s0_d.c_sig    = c_dec[33:10];
        s0_d.c_rel_exp = c_rel_exp_s0_tmp;

        if (any_scale_nan || c_dec[35]) begin
            s0_d.special_valid  = 1'b1;
            s0_d.special_result = dot_pack_special_fp32(DOT_SPECIAL_NAN);
        end else if (c_dec[34]) begin
            s0_d.special_valid  = 1'b1;
            s0_d.special_result = c_fp32_i;
        end else begin
            s0_d.special_valid  = 1'b0;
            s0_d.special_result = dot_pack_special_fp32(DOT_SPECIAL_NONE);
        end
    end

    logic signed [DOT_FP4_SIGMA_W-1:0]      sigma_tmp;
    logic [DOT_FP4_SF_SIG_PROD_W-1:0]       sf_sig_prod_tmp;
    logic signed [DOT_FP4_GAMMA_SIG_W-1:0]  gamma_sig_tmp_s1;
    logic signed [DOT_FP4_C_EXP_W-1:0]      gamma_rel_exp_tmp_s1;
    logic                           gamma_sign_tmp_s1;
    logic [DOT_FP4_GAMMA_SIG_W-1:0]         gamma_abs_tmp_s1;
    logic [DOT_FP4_GAMMA_SIG_W-1:0]         gamma_mag_tmp_s1;
    logic signed [DOT_FP4_C_EXP_W-1:0]      gamma_emax_l0_exp_s1 [0:3];
    logic signed [DOT_FP4_C_EXP_W-1:0]      gamma_emax_l1_exp_s1 [0:1];
    logic signed [DOT_FP4_C_EXP_W-1:0]      gamma_emax_s1;
    logic                           c_emax_vld_s1;

    always_comb begin
        s1_d = '0;
        s1_gamma_sign_flat_tmp = '0;
        s1_gamma_mag_flat_tmp  = '0;
        s1_gamma_rel_exp_flat_tmp  = '0;
        s1_d.special_valid  = s0_q.special_valid;
        s1_d.special_result = s0_q.special_result;
        s1_d.c_sign         = s0_q.c_sign;
        s1_d.c_mag          = s0_q.c_sig;
        s1_d.c_rel_exp      = s0_q.c_rel_exp;
        sigma_tmp           = '0;
        sf_sig_prod_tmp     = '0;
        gamma_sig_tmp_s1    = '0;
        gamma_rel_exp_tmp_s1 = '0;
        gamma_sign_tmp_s1   = 1'b0;
        gamma_abs_tmp_s1    = '0;
        gamma_mag_tmp_s1    = '0;
        gamma_emax_l0_exp_s1[0] = '0;
        gamma_emax_l0_exp_s1[1] = '0;
        gamma_emax_l0_exp_s1[2] = '0;
        gamma_emax_l0_exp_s1[3] = '0;
        gamma_emax_l1_exp_s1[0] = '0;
        gamma_emax_l1_exp_s1[1] = '0;
        gamma_emax_s1           = '0;
        c_emax_vld_s1           = 1'b0;
        for (g1 = 0; g1 < DOT_FP4_NUM_BLOCKS; g1 = g1 + 1) begin
            sigma_tmp = $signed(s0_sigma_flat_hold[g1*DOT_FP4_SIGMA_W +: DOT_FP4_SIGMA_W]);
            sf_sig_prod_tmp =
                s0_sf_sig_prod_flat_hold[g1*DOT_FP4_SF_SIG_PROD_W +: DOT_FP4_SF_SIG_PROD_W];

            gamma_sig_tmp_s1 = sigma_tmp * $signed({1'b0, sf_sig_prod_tmp});
            gamma_rel_exp_tmp_s1 = $signed(s0_gamma_rel_exp_flat_hold[g1*DOT_FP4_C_EXP_W +: DOT_FP4_C_EXP_W]);
            gamma_sign_tmp_s1 = gamma_sig_tmp_s1[DOT_FP4_GAMMA_SIG_W-1];
            if (gamma_sign_tmp_s1) begin
                gamma_abs_tmp_s1 = -gamma_sig_tmp_s1;
            end else begin
                gamma_abs_tmp_s1 = gamma_sig_tmp_s1;
            end
            gamma_mag_tmp_s1 = gamma_abs_tmp_s1;

            s1_gamma_sign_flat_tmp[g1] = gamma_sign_tmp_s1;
            s1_gamma_mag_flat_tmp[g1*DOT_FP4_GAMMA_SIG_W +: DOT_FP4_GAMMA_SIG_W] = gamma_mag_tmp_s1;
            s1_gamma_rel_exp_flat_tmp[g1*DOT_FP4_C_EXP_W +: DOT_FP4_C_EXP_W] = gamma_rel_exp_tmp_s1;
            gamma_emax_l0_exp_s1[g1] = gamma_rel_exp_tmp_s1;
        end

        gamma_emax_l1_exp_s1[0] =
            (gamma_emax_l0_exp_s1[1] > gamma_emax_l0_exp_s1[0])
          ? gamma_emax_l0_exp_s1[1] : gamma_emax_l0_exp_s1[0];
        gamma_emax_l1_exp_s1[1] =
            (gamma_emax_l0_exp_s1[3] > gamma_emax_l0_exp_s1[2])
          ? gamma_emax_l0_exp_s1[3] : gamma_emax_l0_exp_s1[2];
        gamma_emax_s1 =
            (gamma_emax_l1_exp_s1[1] > gamma_emax_l1_exp_s1[0])
          ? gamma_emax_l1_exp_s1[1] : gamma_emax_l1_exp_s1[0];
        c_emax_vld_s1 = (s0_q.c_sig != '0);
        s1_d.emax = (c_emax_vld_s1 && (s0_q.c_rel_exp > gamma_emax_s1))
                  ? s0_q.c_rel_exp : gamma_emax_s1;

        s1_d.gamma_sign_flat = s1_gamma_sign_flat_tmp;
        s1_d.gamma_mag_flat  = s1_gamma_mag_flat_tmp;
        s1_d.gamma_rel_exp_flat  = s1_gamma_rel_exp_flat_tmp;
    end

    logic signed [DOT_FP4_C_EXP_W-1:0] gamma_rel_exp_ext;
    logic [DOT_FP4_ALIGN_MAG_W-1:0]    gamma_align_mag_tmp;
    logic [DOT_FP4_ALIGN_MAG_W-1:0]    c_align_mag_tmp;

    always_comb begin
        s2_d = '0;
        s2_gamma_aligned_flat_tmp = '0;
        s2_d.special_valid  = s1_q.special_valid;
        s2_d.special_result = s1_q.special_result;
        gamma_rel_exp_ext   = '0;
        gamma_align_mag_tmp = '0;
        c_align_mag_tmp     = '0;

        // GDFS Step 5 alignment uses the gamma-relative emax registered in S1.
        s2_d.base_exp = s1_q.emax + DOT_FP4_EMAX_REL_BIAS_EXP - DOT_FP4_ALIGN_FRAC_EXP;

        for (g3 = 0; g3 < DOT_FP4_NUM_BLOCKS; g3 = g3 + 1) begin
            gamma_rel_exp_ext = $signed(s1_gamma_rel_exp_flat_hold[g3*DOT_FP4_C_EXP_W +: DOT_FP4_C_EXP_W]);
            gamma_align_mag_tmp =
                {s1_gamma_mag_flat_hold[g3*DOT_FP4_GAMMA_SIG_W +: (DOT_FP4_GAMMA_SIG_W-1)],
                 {DOT_FP4_GAMMA_ALIGN_LSHIFT_W{1'b0}}};
            s2_gamma_aligned_flat_tmp[g3*DOT_FP4_ALIGN_TERM_W +: DOT_FP4_ALIGN_TERM_W] =
                align_fixed_rz(s1_gamma_sign_flat_hold[g3],
                               gamma_align_mag_tmp,
                               gamma_rel_exp_ext,
                               s1_q.emax);
        end
        s2_d.gamma_aligned_flat = s2_gamma_aligned_flat_tmp;

        c_align_mag_tmp = {{DOT_FP4_C_ALIGN_PAD_W{1'b0}}, s1_q.c_mag, {DOT_FP4_C_ALIGN_LSHIFT_W{1'b0}}};
        s2_d.c_aligned = align_fixed_rz(s1_q.c_sign, c_align_mag_tmp, s1_q.c_rel_exp, s1_q.emax);
    end

    logic signed [DOT_FP4_SUM_W-1:0] sum_acc;
    logic [DOT_FP4_SUM_W-1:0]        sum_abs_s3_tmp;

    always_comb begin
        s3_d = '0;
        s3_d.special_valid  = s2_q.special_valid;
        s3_d.special_result = s2_q.special_result;
        s3_d.base_exp       = s2_q.base_exp;
        sum_abs_s3_tmp      = '0;

        sum_acc = $signed({{(DOT_FP4_SUM_W-DOT_FP4_ALIGN_TERM_W){s2_q.c_aligned[DOT_FP4_ALIGN_TERM_W-1]}}, s2_q.c_aligned});
        for (g4 = 0; g4 < DOT_FP4_NUM_BLOCKS; g4 = g4 + 1) begin
            sum_acc = sum_acc
                    + $signed({{(DOT_FP4_SUM_W-DOT_FP4_ALIGN_TERM_W){s2_gamma_aligned_flat_hold[g4*DOT_FP4_ALIGN_TERM_W + DOT_FP4_ALIGN_TERM_W-1]}},
                               s2_gamma_aligned_flat_hold[g4*DOT_FP4_ALIGN_TERM_W +: DOT_FP4_ALIGN_TERM_W]});
        end
        if (sum_acc[DOT_FP4_SUM_W-1]) begin
            sum_abs_s3_tmp = $unsigned(-sum_acc);
        end else begin
            sum_abs_s3_tmp = $unsigned(sum_acc);
        end
        s3_d.sum_sign = sum_acc[DOT_FP4_SUM_W-1];
        s3_d.abs_sum  = sum_abs_s3_tmp;
    end

    always_comb begin
        s4_d = '0;
        if (s3_q.special_valid) begin
            s4_d.result = s3_q.special_result;
        end else begin
            s4_d.result = pack_fp32_rz(s3_q.sum_sign, s3_q.abs_sum, s3_q.base_exp);
        end
    end

    pipeline_reg #(
        .W($bits(stage0_data_t))
    ) u_stage0_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_vld_i),
        .in_ready (in_rdy_o),
        .in_data  (s0_d),
        .out_valid(s0_vld_q),
        .out_ready(s1_rdy),
        .out_data (s0_q)
    );

    pipeline_reg #(
        .W($bits(stage1_data_t))
    ) u_stage1_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s0_vld_q),
        .in_ready (s1_rdy),
        .in_data  (s1_d),
        .out_valid(s1_vld_q),
        .out_ready(s2_rdy),
        .out_data (s1_q)
    );

    pipeline_reg #(
        .W($bits(stage2_data_t))
    ) u_stage2_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s1_vld_q),
        .in_ready (s2_rdy),
        .in_data  (s2_d),
        .out_valid(s2_vld_q),
        .out_ready(s3_rdy),
        .out_data (s2_q)
    );

    pipeline_reg #(
        .W($bits(stage3_data_t))
    ) u_stage3_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s2_vld_q),
        .in_ready (s3_rdy),
        .in_data  (s3_d),
        .out_valid(s3_vld_q),
        .out_ready(s4_rdy),
        .out_data (s3_q)
    );

    pipeline_reg #(
        .W($bits(stage4_data_t))
    ) u_stage4_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s3_vld_q),
        .in_ready (s4_rdy),
        .in_data  (s4_d),
        .out_valid(s4_vld_q),
        .out_ready(out_rdy_i),
        .out_data (s4_q)
    );

    assign out_vld_o = s4_vld_q;
    assign d_fp32_o  = s4_q.result;

endmodule
