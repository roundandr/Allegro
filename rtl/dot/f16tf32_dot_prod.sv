// ============================================================================
// File Name   : f16tf32_dot_prod.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-29
// Description : Shared TF32/BF16/FP16 dot-product with FP32 accumulate. The
//               datapath follows the F=25 FDA pipeline defined in
//               doc/F16TF32_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-29  v0.1      LIU YUXUAN       Initial version
//   2026-05-22  v0.2      LIU YUXUAN       Add scale-input-d C operand preprocess
// ============================================================================

module f16tf32_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [1:0]   a_dtype_i,
    input  logic [1:0]   b_dtype_i,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    input  logic [3:0]   scale_input_d_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);

    import dot_prod_pkg::*;

    typedef struct packed {
        logic                    valid;
        logic                    sign;
        logic [DOT_F16TF32_SIG_W-1:0]        sig;
        logic signed [DOT_F16TF32_EXP_W-1:0] exp;
        logic                    is_zero;
        logic                    is_inf;
        logic                    is_nan;
    } f16tf32_dec_t;

    typedef struct packed {
        logic                    sign;
        logic [DOT_FP32_SIG_W-1:0]   sig;
        logic signed [DOT_F16TF32_EXP_W-1:0] exp;
        logic                    is_zero;
        logic                    is_inf;
        logic                    is_nan;
    } fp32_dec_t;

    typedef struct packed {
        logic [1:0]                      special_code;
        logic [DOT_F16TF32_NUM_ELEMS-1:0]            prod_sign_flat;
        logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_PROD_SIG_W-1:0] prod_sig_flat;
        logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_EXP_W-1:0]      prod_exp_flat;
        logic [DOT_F16TF32_NUM_ELEMS-1:0]            prod_zero_flat;
        logic signed [DOT_F16TF32_EXP_W-1:0]         emax;
        logic                            c_sign;
        logic [DOT_FP32_SIG_W-1:0]           c_sig;
        logic signed [DOT_F16TF32_EXP_W-1:0]         c_exp;
        logic                            c_zero;
    } stage0_data_t;

    typedef struct packed {
        logic [1:0]                       special_code;
        logic [DOT_F16TF32_NUM_ELEMS-1:0]             prod_sign_flat;
        logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_PROD_SIG_W-1:0]  prod_sig_flat;
        logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_EXP_W-1:0]       prod_exp_flat;
        logic [DOT_F16TF32_NUM_ELEMS-1:0]             prod_zero_flat;
        logic                             c_sign;
        logic [DOT_FP32_SIG_W-1:0]            c_sig;
        logic signed [DOT_F16TF32_EXP_W-1:0]          c_exp;
        logic                             c_zero;
        logic signed [DOT_F16TF32_EXP_W-1:0]          emax;
    } stage1_data_t;

    typedef struct packed {
        logic [1:0]                        special_code;
        logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [DOT_F16TF32_ALIGN_TERM_W-1:0]    c_aligned;
        logic signed [DOT_F16TF32_EXP_W-1:0]           base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic [1:0]                   special_code;
        logic signed [DOT_F16TF32_SUM_W-1:0]      sum;
        logic signed [DOT_F16TF32_EXP_W-1:0]      base_exp;
    } stage3_data_t;

    typedef struct packed {
        logic [31:0] result;
    } stage4_data_t;

    stage0_data_t s0_pre_d;
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

    logic        s4_pack_special_vld;
    logic [31:0] s4_pack_special_result;
    logic [31:0] s4_pack_result;

    logic [DOT_F16TF32_NUM_ELEMS-1:0]             s0_prod_sign_flat_tmp;
    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_PROD_SIG_W-1:0]  s0_prod_sig_flat_tmp;
    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_EXP_W-1:0]       s0_prod_exp_flat_tmp;
    logic [DOT_F16TF32_NUM_ELEMS-1:0]             s0_prod_zero_flat_tmp;
    logic [DOT_F16TF32_EMAX_L0_TERMS-1:0]                    s0_emax_vld_flat_tmp;
    logic [DOT_F16TF32_EMAX_L0_TERMS*DOT_F16TF32_EXP_W-1:0]  s0_emax_exp_flat_tmp;
    logic                                                    s0_emax_vld_tmp;
    logic signed [DOT_F16TF32_EXP_W-1:0]                     s0_emax_tmp;

    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_EXP_W-1:0]      s0_prod_exp_flat_hold;
    logic [DOT_F16TF32_NUM_ELEMS-1:0]                        s0_prod_zero_flat_hold;

    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_EXP_W-1:0]       s1_prod_exp_flat_tmp;

    logic [DOT_F16TF32_NUM_ELEMS-1:0]             s1_prod_sign_flat_hold;
    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_PROD_SIG_W-1:0]  s1_prod_sig_flat_hold;
    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_EXP_W-1:0]       s1_prod_exp_flat_hold;
    logic [DOT_F16TF32_NUM_ELEMS-1:0]             s1_prod_zero_flat_hold;

    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_ALIGN_TERM_W-1:0] s2_aligned_prod_flat_tmp;
    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_ALIGN_TERM_W-1:0] s2_aligned_prod_flat_hold;
    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_ALIGN_MAG_W-1:0]  s2_prod_mag_flat;
    logic [DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_ALIGN_TERM_W-1:0] s2_prod_aligned_flat;
    logic [DOT_F16TF32_ALIGN_MAG_W-1:0]                        s2_c_mag;
    logic signed [DOT_F16TF32_ALIGN_TERM_W-1:0]                s2_c_aligned;
    logic [DOT_F16TF32_ACC_L0_TERMS*DOT_F16TF32_SUM_W-1:0]     s3_sum_term_flat;
    logic signed [DOT_F16TF32_SUM_W-1:0]                       s3_sum_tree;

    assign s0_prod_exp_flat_hold     = s0_q.prod_exp_flat;
    assign s0_prod_zero_flat_hold    = s0_q.prod_zero_flat;
    assign s1_prod_sign_flat_hold    = s1_q.prod_sign_flat;
    assign s1_prod_sig_flat_hold     = s1_q.prod_sig_flat;
    assign s1_prod_exp_flat_hold     = s1_q.prod_exp_flat;
    assign s1_prod_zero_flat_hold    = s1_q.prod_zero_flat;
    assign s2_aligned_prod_flat_hold = s2_q.aligned_prod_flat;

    function automatic f16tf32_dec_t decode_disabled_lane;
        f16tf32_dec_t dec;
        begin
            dec         = '0;
            dec.valid   = 1'b0;
            dec.is_zero = 1'b1;
            return dec;
        end
    endfunction

    function automatic f16tf32_dec_t decode_tf32_from_fp32(
        input logic lane_valid_i,
        input logic [DOT_FP32_W-1:0] fp32_i
    );
        f16tf32_dec_t dec;
        logic [DOT_FP32_EXP_W-1:0]   exp_raw;
        logic [DOT_FP32_FRAC_W-1:0]  frac_raw;
        logic [DOT_F16TF32_TF32_FRAC_W-1:0]  tf32_frac;
        begin
            dec = decode_disabled_lane();

            if (lane_valid_i) begin
                dec       = '0;
                dec.valid = 1'b1;
                dec.sign  = fp32_i[31];
                exp_raw   = fp32_i[30:23];
                frac_raw  = fp32_i[22:0];
                tf32_frac = fp32_i[22:13];

                dec.is_zero = (exp_raw == 8'h00) && (tf32_frac == 10'h000);
                dec.is_inf  = (exp_raw == 8'hff) && (frac_raw == 23'h0);
                dec.is_nan  = (exp_raw == 8'hff) && (frac_raw != 23'h0);

                if (dec.is_inf || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (dec.is_zero) begin
                    dec.sig = '0;
                    dec.exp = -9'sd126;
                end else if (exp_raw == 8'h00) begin
                    dec.sig = {1'b0, tf32_frac};
                    dec.exp = -9'sd126;
                end else begin
                    dec.sig = {1'b1, tf32_frac};
                    dec.exp = $signed({1'd0, exp_raw}) - 9'sd127;
                end
            end

            return dec;
        end
    endfunction

    function automatic f16tf32_dec_t decode_fp16_bf16(
        input logic              is_bf16_i,
        input logic [DOT_F16TF32_FP16_W-1:0] fp16_bf16_i
    );
        f16tf32_dec_t dec;
        logic [DOT_F16TF32_FP16_EXP_W-1:0]  exp_raw;
        logic [DOT_F16TF32_FP16_FRAC_W-1:0] frac_raw;
        logic [DOT_F16TF32_BF16_EXP_W-1:0]  bf16_exp_raw;
        logic [DOT_F16TF32_BF16_FRAC_W-1:0] bf16_frac_raw;
        begin
            dec       = '0;
            dec.valid = 1'b1;
            dec.sign  = fp16_bf16_i[15];
            exp_raw   = fp16_bf16_i[14:10];
            frac_raw  = fp16_bf16_i[9:0];
            bf16_exp_raw  = fp16_bf16_i[14:7];
            bf16_frac_raw = fp16_bf16_i[6:0];

            if (is_bf16_i) begin
                dec.is_zero = (bf16_exp_raw == 8'h00) && (bf16_frac_raw == 7'h00);
                dec.is_inf  = (bf16_exp_raw == 8'hff) && (bf16_frac_raw == 7'h00);
                dec.is_nan  = (bf16_exp_raw == 8'hff) && (bf16_frac_raw != 7'h00);

                if (dec.is_inf || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (dec.is_zero) begin
                    dec.sig = '0;
                    dec.exp = -9'sd126;
                end else if (bf16_exp_raw == 8'h00) begin
                    dec.sig = {1'b0, bf16_frac_raw, {DOT_F16TF32_BF16_SIG_PAD_W{1'b0}}};
                    dec.exp = -9'sd126;
                end else begin
                    dec.sig = {1'b1, bf16_frac_raw, {DOT_F16TF32_BF16_SIG_PAD_W{1'b0}}};
                    dec.exp = $signed({1'd0, bf16_exp_raw}) - 9'sd127;
                end
            end else begin
                dec.is_zero = (exp_raw == 5'h00) && (frac_raw == 10'h000);
                dec.is_inf  = (exp_raw == 5'h1f) && (frac_raw == 10'h000);
                dec.is_nan  = (exp_raw == 5'h1f) && (frac_raw != 10'h000);

                if (dec.is_inf || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (dec.is_zero) begin
                    dec.sig = '0;
                    dec.exp = -9'sd126;
                end else if (exp_raw == 5'h00) begin
                    dec.sig = {1'b0, frac_raw};
                    dec.exp = -9'sd14;
                end else begin
                    dec.sig = {1'b1, frac_raw};
                    dec.exp = $signed({4'd0, exp_raw}) - 9'sd15;
                end
            end

            return dec;
        end
    endfunction

    function automatic fp32_dec_t decode_fp32(input logic [DOT_FP32_W-1:0] fp32_i);
        fp32_dec_t dec;
        logic [DOT_FP32_CLS_W-1:0]  cls;
        logic [DOT_FP32_EXP_W-1:0]  exp_raw;
        logic [DOT_FP32_FRAC_W-1:0] frac_raw;
        begin
            dec      = '0;
            cls      = dot_fp32_classify(fp32_i);
            exp_raw  = cls[DOT_FP32_CLS_EXP_MSB -: DOT_FP32_EXP_W];
            frac_raw = cls[DOT_FP32_CLS_FRAC_MSB -: DOT_FP32_FRAC_W];

            dec.sign    = cls[DOT_FP32_CLS_SIGN_BIT];
            dec.is_zero = cls[DOT_FP32_CLS_ZERO_BIT];
            dec.is_inf  = cls[DOT_FP32_CLS_INF_BIT];
            dec.is_nan  = cls[DOT_FP32_CLS_NAN_BIT];

            if (dec.is_inf || dec.is_nan) begin
                dec.sig = '0;
                dec.exp = '0;
            end else if (dec.is_zero) begin
                dec.sig = '0;
                dec.exp = -9'sd126;
            end else if (exp_raw == 8'h00) begin
                dec.sig = {1'b0, frac_raw};
                dec.exp = -9'sd126;
            end else begin
                dec.sig = {1'b1, frac_raw};
                dec.exp = $signed({1'd0, exp_raw}) - 9'sd127;
            end

            return dec;
        end
    endfunction

    function automatic logic [DOT_FP32_W-1:0] scale_fp32_pow2_rz(
        input logic [DOT_FP32_W-1:0] value_i,
        input logic [3:0]        shift_i
    );
        logic                    sign;
        logic [DOT_FP32_EXP_W-1:0]   exp_raw;
        logic [DOT_FP32_FRAC_W-1:0]  frac_raw;
        logic [DOT_FP32_SIG_W-1:0]   sig24;
        integer                  new_exp;
        integer                  sub_shift;
        logic [DOT_FP32_FRAC_W-1:0]  sub_frac;
        begin
            sign      = value_i[31];
            exp_raw   = value_i[30:23];
            frac_raw  = value_i[22:0];
            sig24     = {1'b1, frac_raw};
            new_exp   = int'(exp_raw) - int'(shift_i);
            sub_shift = 0;
            sub_frac  = '0;
            scale_fp32_pow2_rz = value_i;

            if ((shift_i == 4'd0) || (exp_raw == 8'hff) || (value_i[30:0] == 31'd0)) begin
                scale_fp32_pow2_rz = value_i;
            end else if (exp_raw == 8'h00) begin
                scale_fp32_pow2_rz = {sign, 8'h00, frac_raw >> shift_i};
            end else if (new_exp > 0) begin
                scale_fp32_pow2_rz = {sign, 8'(new_exp), frac_raw};
            end else begin
                sub_shift = int'(shift_i) + 1 - int'(exp_raw);
                if (sub_shift >= DOT_FP32_SIG_W) begin
                    sub_frac = '0;
                end else begin
                    sub_frac = DOT_FP32_FRAC_W'(sig24 >> sub_shift);
                end
                scale_fp32_pow2_rz = {sign, 8'h00, sub_frac};
            end
        end
    endfunction

    dot_emax_tree #(
        .EXP_W      (DOT_F16TF32_EXP_W),
        .TERM_N     (DOT_F16TF32_EMAX_L0_TERMS),
        .DEFAULT_EXP(DOT_F16TF32_EMAX_MIN_EXP)
    ) u_s0_emax_tree (
        .term_vld_i     (s0_emax_vld_flat_tmp),
        .term_exp_flat_i(s0_emax_exp_flat_tmp),
        .emax_vld_o     (s0_emax_vld_tmp),
        .emax_o         (s0_emax_tmp)
    );

    genvar s2_align_idx;
    generate
        for (s2_align_idx = 0; s2_align_idx < DOT_F16TF32_NUM_ELEMS; s2_align_idx = s2_align_idx + 1) begin : gen_prod_align
            assign s2_prod_mag_flat[s2_align_idx*DOT_F16TF32_ALIGN_MAG_W +: DOT_F16TF32_ALIGN_MAG_W] =
                {{(DOT_F16TF32_ALIGN_MAG_W-DOT_F16TF32_PROD_SIG_W-DOT_F16TF32_PROD_ALIGN_PAD_W){1'b0}},
                 s1_prod_sig_flat_hold[s2_align_idx*DOT_F16TF32_PROD_SIG_W +: DOT_F16TF32_PROD_SIG_W],
                 {DOT_F16TF32_PROD_ALIGN_PAD_W{1'b0}}};

            dot_align_fixed_rz #(
                .MAG_W (DOT_F16TF32_ALIGN_MAG_W),
                .TERM_W(DOT_F16TF32_ALIGN_TERM_W),
                .EXP_W (DOT_F16TF32_EXP_W)
            ) u_prod_align (
                .term_vld_i (!s1_prod_zero_flat_hold[s2_align_idx]),
                .term_sign_i(s1_prod_sign_flat_hold[s2_align_idx]),
                .term_mag_i (s2_prod_mag_flat[s2_align_idx*DOT_F16TF32_ALIGN_MAG_W +: DOT_F16TF32_ALIGN_MAG_W]),
                .term_exp_i ($signed(s1_prod_exp_flat_hold[s2_align_idx*DOT_F16TF32_EXP_W +: DOT_F16TF32_EXP_W])),
                .emax_i     (s1_q.emax),
                .term_o     (s2_prod_aligned_flat[s2_align_idx*DOT_F16TF32_ALIGN_TERM_W +: DOT_F16TF32_ALIGN_TERM_W])
            );
        end
    endgenerate

    assign s2_c_mag = {{(DOT_F16TF32_ALIGN_MAG_W-DOT_FP32_SIG_W-DOT_F16TF32_C_ALIGN_PAD_W){1'b0}},
                       s1_q.c_sig,
                       {DOT_F16TF32_C_ALIGN_PAD_W{1'b0}}};

    dot_align_fixed_rz #(
        .MAG_W (DOT_F16TF32_ALIGN_MAG_W),
        .TERM_W(DOT_F16TF32_ALIGN_TERM_W),
        .EXP_W (DOT_F16TF32_EXP_W)
    ) u_c_align (
        .term_vld_i (!s1_q.c_zero),
        .term_sign_i(s1_q.c_sign),
        .term_mag_i (s2_c_mag),
        .term_exp_i (s1_q.c_exp),
        .emax_i     (s1_q.emax),
        .term_o     (s2_c_aligned)
    );

    genvar s3_sum_idx;
    generate
        assign s3_sum_term_flat[0*DOT_F16TF32_SUM_W +: DOT_F16TF32_SUM_W] =
            s2_q.c_aligned;
        for (s3_sum_idx = 0; s3_sum_idx < DOT_F16TF32_NUM_ELEMS; s3_sum_idx = s3_sum_idx + 1) begin : gen_s3_sum_terms
            assign s3_sum_term_flat[(s3_sum_idx+1)*DOT_F16TF32_SUM_W +: DOT_F16TF32_SUM_W] =
                s2_aligned_prod_flat_hold[s3_sum_idx*DOT_F16TF32_ALIGN_TERM_W +: DOT_F16TF32_ALIGN_TERM_W];
        end
    endgenerate

    dot_signed_reduce_tree #(
        .TERM_W(DOT_F16TF32_SUM_W),
        .TERM_N(DOT_F16TF32_ACC_L0_TERMS)
    ) u_s3_sum_tree (
        .term_flat_i(s3_sum_term_flat),
        .sum_o      (s3_sum_tree)
    );

    integer idx0;
    f16tf32_dec_t a_dec_tmp;
    f16tf32_dec_t b_dec_tmp;
    fp32_dec_t c_dec_tmp;
    logic [DOT_FP32_W-1:0] c_preprocessed_tmp;
    logic any_nan_tmp;
    logic has_pos_inf_tmp;
    logic has_neg_inf_tmp;
    logic has_zero_mul_inf_tmp;
    logic lane_prod_sign_tmp;
    logic reserved_dtype_tmp;
    always_comb begin
        logic lane_has_inf_tmp;
        logic lane_valid_tmp;
        logic lane_prod_zero_tmp;
        logic lane_prod_emax_vld_tmp;
        logic [DOT_F16TF32_PROD_SIG_W-1:0] lane_prod_sig_tmp;
        logic signed [DOT_F16TF32_EXP_W-1:0] lane_prod_exp_tmp;

        s0_pre_d = '0;
        s0_prod_sign_flat_tmp = '0;
        s0_prod_sig_flat_tmp  = '0;
        s0_prod_exp_flat_tmp  = '0;
        s0_prod_zero_flat_tmp = '0;
        s0_emax_vld_flat_tmp  = '0;
        s0_emax_exp_flat_tmp  = '0;

        c_preprocessed_tmp   = scale_fp32_pow2_rz(c_i, scale_input_d_i);
        c_dec_tmp            = decode_fp32(c_preprocessed_tmp);
        reserved_dtype_tmp    = (a_dtype_i == DOT_F16TF32_DTYPE_RSVD) ||
                                (b_dtype_i == DOT_F16TF32_DTYPE_RSVD) ||
                                ((a_dtype_i == DOT_F16TF32_DTYPE_TF32) !=
                                 (b_dtype_i == DOT_F16TF32_DTYPE_TF32));
        any_nan_tmp          = c_dec_tmp.is_nan || reserved_dtype_tmp;
        has_pos_inf_tmp      = c_dec_tmp.is_inf && !c_dec_tmp.sign;
        has_neg_inf_tmp      = c_dec_tmp.is_inf && c_dec_tmp.sign;
        has_zero_mul_inf_tmp = 1'b0;
        lane_has_inf_tmp     = 1'b0;
        lane_valid_tmp       = 1'b0;
        lane_prod_sign_tmp   = 1'b0;
        lane_prod_zero_tmp   = 1'b0;
        lane_prod_emax_vld_tmp = 1'b0;
        lane_prod_sig_tmp    = '0;
        lane_prod_exp_tmp    = '0;

        s0_pre_d.c_sign = c_dec_tmp.sign;
        s0_pre_d.c_sig  = c_dec_tmp.sig;
        s0_pre_d.c_exp  = c_dec_tmp.exp;
        s0_pre_d.c_zero = c_dec_tmp.is_zero;

        for (idx0 = 0; idx0 < DOT_F16TF32_NUM_ELEMS; idx0 = idx0 + 1) begin
            a_dec_tmp = decode_disabled_lane();
            b_dec_tmp = decode_disabled_lane();
            lane_valid_tmp = 1'b0;
            lane_prod_zero_tmp = 1'b0;
            lane_prod_emax_vld_tmp = 1'b0;
            lane_prod_sig_tmp = '0;
            lane_prod_exp_tmp = '0;

            if (!reserved_dtype_tmp &&
                (a_dtype_i == DOT_F16TF32_DTYPE_TF32) &&
                (b_dtype_i == DOT_F16TF32_DTYPE_TF32)) begin
                lane_valid_tmp = (idx0 < DOT_F16TF32_TF32_NUM_ELEMS);
                if (lane_valid_tmp) begin
                    a_dec_tmp = decode_tf32_from_fp32(1'b1, a_vec_i[idx0*DOT_FP32_W +: DOT_FP32_W]);
                    b_dec_tmp = decode_tf32_from_fp32(1'b1, b_vec_i[idx0*DOT_FP32_W +: DOT_FP32_W]);
                end
            end else if (!reserved_dtype_tmp) begin
                a_dec_tmp = decode_fp16_bf16(a_dtype_i == DOT_F16TF32_DTYPE_BF16,
                                             a_vec_i[idx0*DOT_F16TF32_FP16_W +: DOT_F16TF32_FP16_W]);
                b_dec_tmp = decode_fp16_bf16(b_dtype_i == DOT_F16TF32_DTYPE_BF16,
                                             b_vec_i[idx0*DOT_F16TF32_FP16_W +: DOT_F16TF32_FP16_W]);
            end

            lane_prod_sign_tmp = a_dec_tmp.sign ^ b_dec_tmp.sign;
            lane_prod_sig_tmp  = a_dec_tmp.sig * b_dec_tmp.sig;
            lane_prod_exp_tmp  = a_dec_tmp.exp + b_dec_tmp.exp;
            lane_has_inf_tmp   = a_dec_tmp.valid && b_dec_tmp.valid &&
                                  ((a_dec_tmp.is_inf && !b_dec_tmp.is_zero && !b_dec_tmp.is_nan) ||
                                   (b_dec_tmp.is_inf && !a_dec_tmp.is_zero && !a_dec_tmp.is_nan));
            lane_prod_zero_tmp = (!a_dec_tmp.valid) || (!b_dec_tmp.valid) ||
                                 a_dec_tmp.is_zero || b_dec_tmp.is_zero ||
                                 a_dec_tmp.is_inf  || b_dec_tmp.is_inf  ||
                                 a_dec_tmp.is_nan  || b_dec_tmp.is_nan;
            lane_prod_emax_vld_tmp = a_dec_tmp.valid && b_dec_tmp.valid &&
                                      !a_dec_tmp.is_inf && !b_dec_tmp.is_inf &&
                                      !a_dec_tmp.is_nan && !b_dec_tmp.is_nan;

            any_nan_tmp = any_nan_tmp ||
                          (a_dec_tmp.valid && a_dec_tmp.is_nan) ||
                          (b_dec_tmp.valid && b_dec_tmp.is_nan);
            has_zero_mul_inf_tmp = has_zero_mul_inf_tmp ||
                                   (a_dec_tmp.valid && b_dec_tmp.valid &&
                                    ((a_dec_tmp.is_zero && b_dec_tmp.is_inf) ||
                                     (a_dec_tmp.is_inf && b_dec_tmp.is_zero)));
            has_neg_inf_tmp = has_neg_inf_tmp || (lane_has_inf_tmp && lane_prod_sign_tmp);
            has_pos_inf_tmp = has_pos_inf_tmp || (lane_has_inf_tmp && !lane_prod_sign_tmp);

            s0_prod_sign_flat_tmp[idx0] = lane_prod_sign_tmp;
            s0_prod_sig_flat_tmp[idx0*DOT_F16TF32_PROD_SIG_W +: DOT_F16TF32_PROD_SIG_W] = lane_prod_sig_tmp;
            s0_prod_exp_flat_tmp[idx0*DOT_F16TF32_EXP_W +: DOT_F16TF32_EXP_W] = lane_prod_exp_tmp;
            s0_prod_zero_flat_tmp[idx0] = lane_prod_zero_tmp;
            s0_emax_vld_flat_tmp[idx0] = lane_prod_emax_vld_tmp;
            s0_emax_exp_flat_tmp[idx0*DOT_F16TF32_EXP_W +: DOT_F16TF32_EXP_W] = lane_prod_exp_tmp;
        end
        s0_emax_vld_flat_tmp[DOT_F16TF32_NUM_ELEMS] = 1'b1;
        s0_emax_exp_flat_tmp[DOT_F16TF32_NUM_ELEMS*DOT_F16TF32_EXP_W +: DOT_F16TF32_EXP_W] =
            c_dec_tmp.exp;

        s0_pre_d.prod_sign_flat = s0_prod_sign_flat_tmp;
        s0_pre_d.prod_sig_flat  = s0_prod_sig_flat_tmp;
        s0_pre_d.prod_exp_flat  = s0_prod_exp_flat_tmp;
        s0_pre_d.prod_zero_flat = s0_prod_zero_flat_tmp;

        if (any_nan_tmp || has_zero_mul_inf_tmp || (has_pos_inf_tmp && has_neg_inf_tmp)) begin
            s0_pre_d.special_code = DOT_SPECIAL_NAN;
        end else if (has_pos_inf_tmp) begin
            s0_pre_d.special_code = DOT_SPECIAL_POS_INF;
        end else if (has_neg_inf_tmp) begin
            s0_pre_d.special_code = DOT_SPECIAL_NEG_INF;
        end else begin
            s0_pre_d.special_code = DOT_SPECIAL_NONE;
        end
    end

    always_comb begin
        s0_d      = s0_pre_d;
        s0_d.emax = s0_emax_vld_tmp ? s0_emax_tmp : DOT_F16TF32_EMAX_MIN_EXP;
    end

    always_comb begin
        s1_d = '0;
        s1_prod_exp_flat_tmp = '0;

        s1_d.special_code   = s0_q.special_code;
        s1_d.prod_sign_flat = s0_q.prod_sign_flat;
        s1_d.prod_sig_flat  = s0_q.prod_sig_flat;
        s1_d.prod_zero_flat = s0_q.prod_zero_flat;
        s1_d.c_sign         = s0_q.c_sign;
        s1_d.c_sig          = s0_q.c_sig;
        s1_d.c_exp          = s0_q.c_exp;
        s1_d.c_zero         = s0_q.c_zero;

        for (int idx1 = 0; idx1 < DOT_F16TF32_NUM_ELEMS; idx1 = idx1 + 1) begin
            s1_prod_exp_flat_tmp[idx1*DOT_F16TF32_EXP_W +: DOT_F16TF32_EXP_W] =
                s0_prod_zero_flat_hold[idx1] ? '0 :
                s0_prod_exp_flat_hold[idx1*DOT_F16TF32_EXP_W +: DOT_F16TF32_EXP_W];
        end

        s1_d.prod_exp_flat  = s1_prod_exp_flat_tmp;
        s1_d.emax           = s0_q.emax;
    end
    always_comb begin
        s2_d = '0;
        s2_aligned_prod_flat_tmp = '0;

        s2_d.special_code = s1_q.special_code;

        s2_d.base_exp = s1_q.emax - DOT_F16TF32_ALIGN_FRAC_BITS_EXP;

        for (int idx2 = 0; idx2 < DOT_F16TF32_NUM_ELEMS; idx2 = idx2 + 1) begin
            s2_aligned_prod_flat_tmp[idx2*DOT_F16TF32_ALIGN_TERM_W +: DOT_F16TF32_ALIGN_TERM_W] =
                s2_prod_aligned_flat[idx2*DOT_F16TF32_ALIGN_TERM_W +: DOT_F16TF32_ALIGN_TERM_W];
        end

        s2_d.c_aligned = s2_c_aligned;

        s2_d.aligned_prod_flat = s2_aligned_prod_flat_tmp;
    end

    always_comb begin
        s3_d = '0;
        s3_d.special_code = s2_q.special_code;
        s3_d.base_exp     = s2_q.base_exp;
        s3_d.sum      = s3_sum_tree;
    end

    always_comb begin
        s4_d = '0;
        s4_d.result = s4_pack_result;
    end

    assign s4_pack_special_vld    = (s3_q.special_code != DOT_SPECIAL_NONE);
    assign s4_pack_special_result = dot_pack_special_fp32(s3_q.special_code);

    dot_fp32_rz_norm_pack #(
        .SUM_W(DOT_F16TF32_SUM_W),
        .EXP_W(DOT_F16TF32_EXP_W),
        .CANONICALIZE_ZERO_RESULT(1'b0)
    ) u_dot_fp32_rz_norm_pack (
        .sum_i           (s3_q.sum),
        .base_exp_i      (s3_q.base_exp),
        .special_vld_i   (s4_pack_special_vld),
        .special_result_i(s4_pack_special_result),
        .result_o        (s4_pack_result)
    );

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
    assign d_o       = s4_q.result;

endmodule
