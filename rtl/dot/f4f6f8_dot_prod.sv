// ============================================================================
// File Name   : f4f6f8_dot_prod.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-22
// Description : 32-element FP4/FP6/FP8/MX low-precision dot-product with FP32
//               accumulate. The datapath follows the 6-stage FDA pipeline
//               defined in doc/F4F6F8_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-22  v0.1      LIU YUXUAN       Initial version
// ============================================================================

module f4f6f8_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    input  logic [2:0]   a_dtype_i,
    input  logic [2:0]   b_dtype_i,
    input  logic         mxfp8_en_i,
    input  logic [7:0]   a_mx_scale_i,
    input  logic [7:0]   b_mx_scale_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);

    import dot_prod_pkg::*;

    typedef struct packed {
        logic                      sign;
        logic [DOT_F4F6F8_FP8_SIG_W-1:0]      sig;
        logic signed [DOT_F4F6F8_LANE_EXP_W-1:0] exp;
        logic                      is_zero;
        logic                      is_inf;
        logic                      is_nan;
    } fp8_dec_t;

    typedef struct packed {
        logic                      sign;
        logic [DOT_F4F6F8_C_SIG_W-1:0]        sig;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0] exp;
        logic                      is_zero;
        logic                      is_inf;
        logic                      is_nan;
    } fp32_dec_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [DOT_F4F6F8_NUM_ELEMS-1:0]           prod_sign_flat;
        logic [DOT_F4F6F8_NUM_ELEMS*(DOT_F4F6F8_ALIGN_TERM_W-1)-1:0] prod_mag_flat;
        logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_PROD_EXP_W-1:0] prod_exp_flat;
        logic [DOT_F4F6F8_NUM_ELEMS-1:0]           prod_zero_flat;
        logic                                      prod_emax_vld;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   prod_emax;
        logic                           c_sign;
        logic [DOT_F4F6F8_ALIGN_TERM_W-2:0]        c_mag;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   c_exp;
        logic                           c_zero;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   mx_scale_exp_sum;
    } stage0_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [DOT_F4F6F8_NUM_ELEMS-1:0]           prod_sign_flat;
        logic [DOT_F4F6F8_NUM_ELEMS*(DOT_F4F6F8_ALIGN_TERM_W-1)-1:0] prod_mag_flat;
        logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_PROD_EXP_W-1:0] prod_exp_flat;
        logic [DOT_F4F6F8_NUM_ELEMS-1:0]           prod_zero_flat;
        logic                           c_sign;
        logic [DOT_F4F6F8_ALIGN_TERM_W-2:0]        c_mag;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   c_exp_prod_domain;
        logic                           c_zero;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   mx_scale_exp_sum;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   emax;
        logic                           emax_vld;
    } stage1_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [DOT_F4F6F8_ALIGN_TERM_W-1:0]    c_aligned;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [DOT_F4F6F8_ACC_PARTIALS*DOT_F4F6F8_SUM_W-1:0]  partial_sum_flat;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   base_exp;
    } stage3_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic signed [DOT_F4F6F8_SUM_W-1:0]        sum;
        logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]   base_exp;
    } stage4_data_t;

    typedef struct packed {
        logic [31:0] result;
    } stage5_data_t;

    stage0_data_t s0_pre_d;
    stage0_data_t s0_d;
    stage1_data_t s1_pre_d;
    stage1_data_t s1_d;
    stage2_data_t s2_d;
    stage3_data_t s3_pre_d;
    stage3_data_t s3_d;
    stage4_data_t s4_d;
    stage5_data_t s5_d;

    stage0_data_t s0_q;
    stage1_data_t s1_q;
    stage2_data_t s2_q;
    stage3_data_t s3_q;
    stage4_data_t s4_q;
    stage5_data_t s5_q;

    logic s0_vld_q;
    logic s1_vld_q;
    logic s2_vld_q;
    logic s3_vld_q;
    logic s4_vld_q;
    logic s5_vld_q;

    logic s1_rdy;
    logic s2_rdy;
    logic s3_rdy;
    logic s4_rdy;
    logic s5_rdy;

    logic [31:0] s5_pack_result;

    logic [DOT_F4F6F8_NUM_ELEMS-1:0]                    s0_prod_sign_flat_tmp;
    logic [DOT_F4F6F8_NUM_ELEMS*(DOT_F4F6F8_ALIGN_TERM_W-1)-1:0]   s0_prod_mag_flat_tmp;
    logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_PROD_EXP_W-1:0]         s0_prod_exp_flat_tmp;
    logic [DOT_F4F6F8_NUM_ELEMS-1:0]                    s0_prod_zero_flat_tmp;
    logic [DOT_F4F6F8_NUM_ELEMS-1:0]                    s0_emax_vld_flat_tmp;
    logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_FULL_EXP_W-1:0] s0_emax_exp_flat_tmp;
    logic                                               s0_prod_emax_vld_tmp;
    logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]            s0_prod_emax_tmp;

    logic [DOT_F4F6F8_NUM_ELEMS-1:0]                    s1_prod_sign_q_flat;
    logic [DOT_F4F6F8_NUM_ELEMS*(DOT_F4F6F8_ALIGN_TERM_W-1)-1:0]   s1_prod_mag_q_flat;
    logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_PROD_EXP_W-1:0]         s1_prod_exp_q_flat;
    logic [DOT_F4F6F8_NUM_ELEMS-1:0]                    s1_prod_zero_q_flat;

    logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_ALIGN_TERM_W-1:0] s2_aligned_prod_flat_tmp;
    logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_ALIGN_TERM_W-1:0] s2_aligned_prod_q_flat;
    logic [DOT_F4F6F8_NUM_ELEMS*DOT_F4F6F8_ALIGN_TERM_W-1:0] s2_prod_aligned_flat;
    logic signed [DOT_F4F6F8_ALIGN_TERM_W-1:0]               s2_c_aligned;
    logic [DOT_F4F6F8_ACC_PARTIALS*DOT_F4F6F8_SUM_W-1:0]     s3_partial_sum_flat_tmp;
    logic [DOT_F4F6F8_ACC_PARTIALS*DOT_F4F6F8_SUM_W-1:0]     s3_partial_sum_q_flat;
    logic [8*DOT_F4F6F8_SUM_W-1:0]                           s3_sum8_term_flat [0:3];
    logic signed [DOT_F4F6F8_SUM_W-1:0]                      s3_sum8_out [0:3];
    logic signed [DOT_F4F6F8_SUM_W-1:0]                      s3_term_tmp [0:DOT_F4F6F8_NUM_ELEMS];
    logic signed [DOT_F4F6F8_SUM_W-1:0]                      s3_partial_sum_tmp [0:DOT_F4F6F8_ACC_PARTIALS-1];
    logic [DOT_F4F6F8_ACC_PARTIALS*DOT_F4F6F8_SUM_W-1:0]     s4_sum_term_flat;
    logic signed [DOT_F4F6F8_SUM_W-1:0]                      s4_sum_tree;

    assign s1_prod_sign_q_flat = s1_q.prod_sign_flat;
    assign s1_prod_mag_q_flat  = s1_q.prod_mag_flat;
    assign s1_prod_exp_q_flat  = s1_q.prod_exp_flat;
    assign s1_prod_zero_q_flat = s1_q.prod_zero_flat;
    assign s2_aligned_prod_q_flat = s2_q.aligned_prod_flat;
    assign s3_partial_sum_q_flat  = s3_q.partial_sum_flat;

    function automatic fp8_dec_t decode_fp8(
        input logic [DOT_F4F6F8_FP8_W-1:0] fp8_i,
        input logic             fp8_format_i
    );
        fp8_dec_t dec;
        logic [2:0] mant_raw;
        begin
            dec      = '0;
            dec.sign = fp8_i[7];

            if (!fp8_format_i) begin
                mant_raw = fp8_i[2:0];

                dec.is_zero = (fp8_i[6:3] == 4'b0000) && (mant_raw == 3'b000);
                dec.is_inf  = 1'b0;
                dec.is_nan  = (fp8_i[6:3] == 4'b1111) && (mant_raw == 3'b111);

                if (dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (dec.is_zero) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (fp8_i[6:3] == 4'b0000) begin
                    dec.sig = {1'b0, mant_raw};
                    dec.exp = -5'sd6;
                end else begin
                    dec.sig = {1'b1, mant_raw};
                    dec.exp = $signed({1'b0, fp8_i[6:3]}) - 5'sd7;
                end
            end else begin
                mant_raw = {1'b0, fp8_i[1:0]};

                dec.is_zero = (fp8_i[6:2] == 5'b00000) && (fp8_i[1:0] == 2'b00);
                dec.is_inf  = (fp8_i[6:2] == 5'b11111) && (fp8_i[1:0] == 2'b00);
                dec.is_nan  = (fp8_i[6:2] == 5'b11111) && (fp8_i[1:0] != 2'b00);

                if (dec.is_inf || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (dec.is_zero) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (fp8_i[6:2] == 5'b00000) begin
                    dec.sig = {1'b0, fp8_i[1:0], 1'b0};
                    dec.exp = -5'sd14;
                end else begin
                    dec.sig = {1'b1, fp8_i[1:0], 1'b0};
                    dec.exp = fp8_i[6:2] - 5'd15;
                end
            end

            return dec;
        end
    endfunction

    function automatic fp8_dec_t decode_fp6(
        input logic [DOT_F4F6F8_FP6_W-1:0] fp6_i,
        input logic             fp6_format_i
    );
        fp8_dec_t dec;
        logic [1:0] exp_e2m3;
        logic [2:0] frac_e2m3;
        logic [2:0] exp_e3m2;
        logic [1:0] frac_e3m2;
        begin
            dec        = '0;
            dec.sign   = fp6_i[5];
            dec.is_inf = 1'b0;
            dec.is_nan = 1'b0;

            if (fp6_format_i == DOT_F4F6F8_FP6_FMT_E3M2) begin
                exp_e3m2  = fp6_i[4:2];
                frac_e3m2 = fp6_i[1:0];

                dec.is_zero = (exp_e3m2 == 3'b000) && (frac_e3m2 == 2'b00);
                if (dec.is_zero) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (exp_e3m2 == 3'b000) begin
                    if (frac_e3m2[1]) begin
                        dec.sig = {1'b1, frac_e3m2[0], 2'b00};
                        dec.exp = -5'sd3;
                    end else begin
                        dec.sig = 4'd8;
                        dec.exp = -5'sd4;
                    end
                end else begin
                    dec.sig = {1'b1, frac_e3m2, 1'b0};
                    dec.exp = $signed({2'd0, exp_e3m2}) - DOT_F4F6F8_FP6_E3M2_BIAS_EXP;
                end
            end else begin
                exp_e2m3  = fp6_i[4:3];
                frac_e2m3 = fp6_i[2:0];

                dec.is_zero = (exp_e2m3 == 2'b00) && (frac_e2m3 == 3'b000);
                if (dec.is_zero) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (exp_e2m3 == 2'b00) begin
                    if (frac_e2m3[2]) begin
                        dec.sig = {1'b1, frac_e2m3[1:0], 1'b0};
                        dec.exp = -5'sd1;
                    end else if (frac_e2m3[1]) begin
                        dec.sig = {1'b1, frac_e2m3[0], 2'b00};
                        dec.exp = -5'sd2;
                    end else begin
                        dec.sig = 4'd8;
                        dec.exp = -5'sd3;
                    end
                end else begin
                    dec.sig = {1'b1, frac_e2m3};
                    dec.exp = $signed({3'd0, exp_e2m3}) - DOT_F4F6F8_FP6_E2M3_BIAS_EXP;
                end
            end

            return dec;
        end
    endfunction

    function automatic fp8_dec_t decode_e2m1(
        input logic [DOT_F4F6F8_FP4_W-1:0] fp4_i
    );
        fp8_dec_t dec;
        logic [2:0] mag_raw;
        begin
            dec        = '0;
            dec.sign   = fp4_i[3];
            dec.is_inf = 1'b0;
            dec.is_nan = 1'b0;
            mag_raw    = fp4_i[2:0];
            dec.is_zero = (mag_raw == 3'd0);

            case (mag_raw)
                3'd0: begin
                    dec.sig = 4'd0;
                    dec.exp = '0;
                end
                3'd1: begin
                    dec.sig = 4'd8;
                    dec.exp = -5'sd1;
                end
                3'd2: begin
                    dec.sig = 4'd8;
                    dec.exp = 5'sd0;
                end
                3'd3: begin
                    dec.sig = 4'd12;
                    dec.exp = 5'sd0;
                end
                3'd4: begin
                    dec.sig = 4'd8;
                    dec.exp = 5'sd1;
                end
                3'd5: begin
                    dec.sig = 4'd12;
                    dec.exp = 5'sd1;
                end
                3'd6: begin
                    dec.sig = 4'd8;
                    dec.exp = 5'sd2;
                end
                default: begin
                    dec.sig = 4'd12;
                    dec.exp = 5'sd2;
                end
            endcase

            return dec;
        end
    endfunction

    function automatic fp32_dec_t decode_fp32(
        input logic [31:0] fp32_i
    );
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
                dec.exp = -10'sd126;
            end else if (exp_raw == 8'h00) begin
                dec.sig = {1'b0, frac_raw};
                dec.exp = -10'sd126;
            end else begin
                dec.sig = {1'b1, frac_raw};
                dec.exp = $signed({2'b00, exp_raw}) - 10'sd127;
            end

            return dec;
        end
    endfunction

    dot_emax_tree #(
        .EXP_W      (DOT_F4F6F8_FULL_EXP_W),
        .TERM_N     (DOT_F4F6F8_NUM_ELEMS),
        .DEFAULT_EXP('0)
    ) u_s0_prod_emax_tree (
        .term_vld_i     (s0_emax_vld_flat_tmp),
        .term_exp_flat_i(s0_emax_exp_flat_tmp),
        .emax_vld_o     (s0_prod_emax_vld_tmp),
        .emax_o         (s0_prod_emax_tmp)
    );

    logic [1:0]                                      s1_emax_vld_flat_tmp;
    logic [2*DOT_F4F6F8_FULL_EXP_W-1:0]             s1_emax_exp_flat_tmp;
    logic                                           s1_emax_vld_tmp;
    logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]        s1_emax_tmp;

    dot_emax_tree #(
        .EXP_W      (DOT_F4F6F8_FULL_EXP_W),
        .TERM_N     (2),
        .DEFAULT_EXP('0)
    ) u_s1_emax_tree (
        .term_vld_i     (s1_emax_vld_flat_tmp),
        .term_exp_flat_i(s1_emax_exp_flat_tmp),
        .emax_vld_o     (s1_emax_vld_tmp),
        .emax_o         (s1_emax_tmp)
    );

    genvar s2_align_idx;
    generate
        for (s2_align_idx = 0; s2_align_idx < DOT_F4F6F8_NUM_ELEMS; s2_align_idx = s2_align_idx + 1) begin : gen_prod_align
            dot_align_fixed_rz #(
                .MAG_W (DOT_F4F6F8_ALIGN_TERM_W-1),
                .TERM_W(DOT_F4F6F8_ALIGN_TERM_W),
                .EXP_W (DOT_F4F6F8_FULL_EXP_W)
            ) u_prod_align (
                .term_vld_i (!s1_prod_zero_q_flat[s2_align_idx]),
                .term_sign_i(s1_prod_sign_q_flat[s2_align_idx]),
                .term_mag_i (s1_prod_mag_q_flat[s2_align_idx*(DOT_F4F6F8_ALIGN_TERM_W-1) +:
                              (DOT_F4F6F8_ALIGN_TERM_W-1)]),
                .term_exp_i ($signed({{(DOT_F4F6F8_FULL_EXP_W-DOT_F4F6F8_PROD_EXP_W){
                              s1_prod_exp_q_flat[s2_align_idx*DOT_F4F6F8_PROD_EXP_W+DOT_F4F6F8_PROD_EXP_W-1]}},
                              s1_prod_exp_q_flat[s2_align_idx*DOT_F4F6F8_PROD_EXP_W +: DOT_F4F6F8_PROD_EXP_W]})),
                .emax_i     (s1_q.emax),
                .term_o     (s2_prod_aligned_flat[s2_align_idx*DOT_F4F6F8_ALIGN_TERM_W +: DOT_F4F6F8_ALIGN_TERM_W])
            );
        end
    endgenerate

    dot_align_fixed_rz #(
        .MAG_W (DOT_F4F6F8_ALIGN_TERM_W-1),
        .TERM_W(DOT_F4F6F8_ALIGN_TERM_W),
        .EXP_W (DOT_F4F6F8_FULL_EXP_W)
    ) u_c_align (
        .term_vld_i (!s1_q.c_zero),
        .term_sign_i(s1_q.c_sign),
        .term_mag_i (s1_q.c_mag),
        .term_exp_i (s1_q.c_exp_prod_domain),
        .emax_i     (s1_q.emax),
        .term_o     (s2_c_aligned)
    );

    genvar s3_part_idx;
    genvar s3_term_idx;
    generate
        for (s3_part_idx = 0; s3_part_idx < 4; s3_part_idx = s3_part_idx + 1) begin : gen_s3_reduce8
            for (s3_term_idx = 0; s3_term_idx < 8; s3_term_idx = s3_term_idx + 1) begin : gen_s3_reduce8_term
                assign s3_sum8_term_flat[s3_part_idx][s3_term_idx*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W] =
                    s3_term_tmp[s3_part_idx*8+s3_term_idx];
            end

            dot_signed_reduce_tree #(
                .TERM_W(DOT_F4F6F8_SUM_W),
                .TERM_N(8)
            ) u_sum8_tree (
                .term_flat_i(s3_sum8_term_flat[s3_part_idx]),
                .sum_o      (s3_sum8_out[s3_part_idx])
            );
        end
    endgenerate

    genvar s4_sum_idx;
    generate
        for (s4_sum_idx = 0; s4_sum_idx < DOT_F4F6F8_ACC_PARTIALS; s4_sum_idx = s4_sum_idx + 1) begin : gen_s4_sum_terms
            assign s4_sum_term_flat[s4_sum_idx*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W] =
                s3_partial_sum_q_flat[s4_sum_idx*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W];
        end
    endgenerate

    dot_signed_reduce_tree #(
        .TERM_W(DOT_F4F6F8_SUM_W),
        .TERM_N(DOT_F4F6F8_ACC_PARTIALS)
    ) u_s4_sum_tree (
        .term_flat_i(s4_sum_term_flat),
        .sum_o      (s4_sum_tree)
    );

    integer idx0;
    fp8_dec_t a_dec_tmp;
    fp8_dec_t b_dec_tmp;
    fp32_dec_t c_dec_tmp;
    logic any_nan_tmp;
    logic has_pos_inf_tmp;
    logic has_neg_inf_tmp;
    logic has_zero_mul_inf_tmp;
    logic lane_has_inf_tmp;
    logic lane_prod_sign_tmp;
    logic [DOT_F4F6F8_PROD_SIG_W-1:0] lane_prod_sig_tmp;
    logic [DOT_F4F6F8_ALIGN_TERM_W-2:0] lane_prod_mag_tmp;
    logic [DOT_F4F6F8_ALIGN_TERM_W-2:0] c_mag_tmp_s0;
    logic mx_scale_nan_tmp;
    logic signed [DOT_F4F6F8_FULL_EXP_W-1:0] mx_scale_exp_sum_tmp;
    logic signed [DOT_F4F6F8_PROD_EXP_W-1:0] lane_prod_exp_tmp;
    always @(*) begin
        s0_pre_d = '0;
        s0_prod_sign_flat_tmp = '0;
        s0_prod_mag_flat_tmp  = '0;
        s0_prod_exp_flat_tmp  = '0;
        s0_prod_zero_flat_tmp = '0;
        s0_emax_vld_flat_tmp = '0;
        s0_emax_exp_flat_tmp = '0;

        c_dec_tmp            = decode_fp32(c_i);
        mx_scale_nan_tmp     = mxfp8_en_i && ((a_mx_scale_i == 8'hff) || (b_mx_scale_i == 8'hff));
        mx_scale_exp_sum_tmp = mxfp8_en_i
                             ? ($signed({{(DOT_F4F6F8_FULL_EXP_W-DOT_F4F6F8_MX_SCALE_W){1'b0}}, a_mx_scale_i})
                              + $signed({{(DOT_F4F6F8_FULL_EXP_W-DOT_F4F6F8_MX_SCALE_W){1'b0}}, b_mx_scale_i})
                              - (DOT_F4F6F8_MX_SCALE_BIAS_EXP + DOT_F4F6F8_MX_SCALE_BIAS_EXP))
                             : '0;
        any_nan_tmp          = c_dec_tmp.is_nan | mx_scale_nan_tmp;
        has_pos_inf_tmp      = c_dec_tmp.is_inf && !c_dec_tmp.sign;
        has_neg_inf_tmp      = c_dec_tmp.is_inf && c_dec_tmp.sign;
        has_zero_mul_inf_tmp = 1'b0;
        lane_prod_sig_tmp    = '0;
        lane_prod_mag_tmp    = '0;
        lane_prod_exp_tmp    = '0;

        s0_pre_d.c_sign = c_dec_tmp.sign;
        s0_pre_d.c_exp  = c_dec_tmp.exp;
        s0_pre_d.c_zero = c_dec_tmp.is_zero;
        s0_pre_d.mx_scale_exp_sum = mx_scale_exp_sum_tmp;
        c_mag_tmp_s0 = {{(DOT_F4F6F8_ALIGN_TERM_W-1-DOT_F4F6F8_C_SIG_W-DOT_F4F6F8_C_ALIGN_PAD_W){1'b0}},
                        c_dec_tmp.sig,
                        {DOT_F4F6F8_C_ALIGN_PAD_W{1'b0}}};
        s0_pre_d.c_mag = c_mag_tmp_s0;

        for (idx0 = 0; idx0 < DOT_F4F6F8_NUM_ELEMS; idx0 = idx0 + 1) begin
            case (a_dtype_i)
                DOT_F4F6F8_DTYPE_E4M3: begin
                    a_dec_tmp = decode_fp8(a_vec_i[idx0*DOT_F4F6F8_FP8_W +: DOT_F4F6F8_FP8_W], 1'b0);
                end
                DOT_F4F6F8_DTYPE_E5M2: begin
                    a_dec_tmp = decode_fp8(a_vec_i[idx0*DOT_F4F6F8_FP8_W +: DOT_F4F6F8_FP8_W], 1'b1);
                end
                DOT_F4F6F8_DTYPE_E2M3: begin
                    a_dec_tmp = decode_fp6(a_vec_i[idx0*DOT_F4F6F8_FP6_W +: DOT_F4F6F8_FP6_W], DOT_F4F6F8_FP6_FMT_E2M3);
                end
                DOT_F4F6F8_DTYPE_E3M2: begin
                    a_dec_tmp = decode_fp6(a_vec_i[idx0*DOT_F4F6F8_FP6_W +: DOT_F4F6F8_FP6_W], DOT_F4F6F8_FP6_FMT_E3M2);
                end
                DOT_F4F6F8_DTYPE_E2M1: begin
                    a_dec_tmp = decode_e2m1(a_vec_i[idx0*DOT_F4F6F8_FP4_W +: DOT_F4F6F8_FP4_W]);
                end
                default: begin
                    a_dec_tmp = decode_fp8(a_vec_i[idx0*DOT_F4F6F8_FP8_W +: DOT_F4F6F8_FP8_W], 1'b0);
                end
            endcase

            case (b_dtype_i)
                DOT_F4F6F8_DTYPE_E4M3: begin
                    b_dec_tmp = decode_fp8(b_vec_i[idx0*DOT_F4F6F8_FP8_W +: DOT_F4F6F8_FP8_W], 1'b0);
                end
                DOT_F4F6F8_DTYPE_E5M2: begin
                    b_dec_tmp = decode_fp8(b_vec_i[idx0*DOT_F4F6F8_FP8_W +: DOT_F4F6F8_FP8_W], 1'b1);
                end
                DOT_F4F6F8_DTYPE_E2M3: begin
                    b_dec_tmp = decode_fp6(b_vec_i[idx0*DOT_F4F6F8_FP6_W +: DOT_F4F6F8_FP6_W], DOT_F4F6F8_FP6_FMT_E2M3);
                end
                DOT_F4F6F8_DTYPE_E3M2: begin
                    b_dec_tmp = decode_fp6(b_vec_i[idx0*DOT_F4F6F8_FP6_W +: DOT_F4F6F8_FP6_W], DOT_F4F6F8_FP6_FMT_E3M2);
                end
                DOT_F4F6F8_DTYPE_E2M1: begin
                    b_dec_tmp = decode_e2m1(b_vec_i[idx0*DOT_F4F6F8_FP4_W +: DOT_F4F6F8_FP4_W]);
                end
                default: begin
                    b_dec_tmp = decode_fp8(b_vec_i[idx0*DOT_F4F6F8_FP8_W +: DOT_F4F6F8_FP8_W], 1'b0);
                end
            endcase

            lane_prod_sign_tmp = a_dec_tmp.sign ^ b_dec_tmp.sign;
            lane_has_inf_tmp   = ((a_dec_tmp.is_inf && !b_dec_tmp.is_zero && !b_dec_tmp.is_nan) ||
                                  (b_dec_tmp.is_inf && !a_dec_tmp.is_zero && !a_dec_tmp.is_nan));

            any_nan_tmp = any_nan_tmp | a_dec_tmp.is_nan | b_dec_tmp.is_nan;
            has_zero_mul_inf_tmp = has_zero_mul_inf_tmp |
                                   ((a_dec_tmp.is_zero && b_dec_tmp.is_inf) ||
                                    (a_dec_tmp.is_inf && b_dec_tmp.is_zero));

            if (lane_has_inf_tmp) begin
                if (lane_prod_sign_tmp) begin
                    has_neg_inf_tmp = 1'b1;
                end else begin
                    has_pos_inf_tmp = 1'b1;
                end
            end

            if (a_dec_tmp.is_nan || b_dec_tmp.is_nan || a_dec_tmp.is_inf || b_dec_tmp.is_inf) begin
                s0_prod_sign_flat_tmp[idx0] = 1'b0;
                s0_prod_mag_flat_tmp[idx0*(DOT_F4F6F8_ALIGN_TERM_W-1) +: (DOT_F4F6F8_ALIGN_TERM_W-1)] = '0;
                s0_prod_exp_flat_tmp[idx0*DOT_F4F6F8_PROD_EXP_W +: DOT_F4F6F8_PROD_EXP_W] = '0;
                s0_prod_zero_flat_tmp[idx0] = 1'b1;
            end else begin
                s0_prod_sign_flat_tmp[idx0] = lane_prod_sign_tmp;
                s0_prod_zero_flat_tmp[idx0] = a_dec_tmp.is_zero || b_dec_tmp.is_zero;
                lane_prod_sig_tmp = a_dec_tmp.sig * b_dec_tmp.sig;
                lane_prod_mag_tmp = {{(DOT_F4F6F8_ALIGN_TERM_W-1-DOT_F4F6F8_PROD_SIG_W-DOT_F4F6F8_PROD_ALIGN_PAD_W){1'b0}},
                                     lane_prod_sig_tmp,
                                     {DOT_F4F6F8_PROD_ALIGN_PAD_W{1'b0}}};
                s0_prod_mag_flat_tmp[idx0*(DOT_F4F6F8_ALIGN_TERM_W-1) +: (DOT_F4F6F8_ALIGN_TERM_W-1)] = lane_prod_mag_tmp;

                if (a_dec_tmp.is_zero || b_dec_tmp.is_zero) begin
                    s0_prod_exp_flat_tmp[idx0*DOT_F4F6F8_PROD_EXP_W +: DOT_F4F6F8_PROD_EXP_W] = '0;
                end else begin
                    lane_prod_exp_tmp = $signed({a_dec_tmp.exp[DOT_F4F6F8_LANE_EXP_W-1], a_dec_tmp.exp})
                                      + $signed({b_dec_tmp.exp[DOT_F4F6F8_LANE_EXP_W-1], b_dec_tmp.exp});
                    s0_prod_exp_flat_tmp[idx0*DOT_F4F6F8_PROD_EXP_W +: DOT_F4F6F8_PROD_EXP_W] = lane_prod_exp_tmp;
                end
            end
        end

        for (idx0 = 0; idx0 < DOT_F4F6F8_NUM_ELEMS; idx0 = idx0 + 1) begin
            s0_emax_vld_flat_tmp[idx0] = !s0_prod_zero_flat_tmp[idx0];
            s0_emax_exp_flat_tmp[idx0*DOT_F4F6F8_FULL_EXP_W +: DOT_F4F6F8_FULL_EXP_W] =
                $signed({{(DOT_F4F6F8_FULL_EXP_W-DOT_F4F6F8_PROD_EXP_W){s0_prod_exp_flat_tmp[idx0*DOT_F4F6F8_PROD_EXP_W+DOT_F4F6F8_PROD_EXP_W-1]}},
                         s0_prod_exp_flat_tmp[idx0*DOT_F4F6F8_PROD_EXP_W +: DOT_F4F6F8_PROD_EXP_W]});
        end

        s0_pre_d.prod_sign_flat = s0_prod_sign_flat_tmp;
        s0_pre_d.prod_mag_flat  = s0_prod_mag_flat_tmp;
        s0_pre_d.prod_exp_flat  = s0_prod_exp_flat_tmp;
        s0_pre_d.prod_zero_flat = s0_prod_zero_flat_tmp;

        if (any_nan_tmp || has_zero_mul_inf_tmp || (has_pos_inf_tmp && has_neg_inf_tmp)) begin
            s0_pre_d.special_vld    = 1'b1;
            s0_pre_d.special_result = dot_pack_special_fp32(DOT_SPECIAL_NAN);
        end else if (has_pos_inf_tmp) begin
            s0_pre_d.special_vld    = 1'b1;
            s0_pre_d.special_result = dot_pack_special_fp32(DOT_SPECIAL_POS_INF);
        end else if (has_neg_inf_tmp) begin
            s0_pre_d.special_vld    = 1'b1;
            s0_pre_d.special_result = dot_pack_special_fp32(DOT_SPECIAL_NEG_INF);
        end else begin
            s0_pre_d.special_vld    = 1'b0;
            s0_pre_d.special_result = dot_pack_special_fp32(DOT_SPECIAL_NONE);
        end
    end

    always @(*) begin
        s0_d               = s0_pre_d;
        s0_d.prod_emax_vld = s0_prod_emax_vld_tmp;
        s0_d.prod_emax     = s0_prod_emax_tmp;
    end

    logic signed [DOT_F4F6F8_FULL_EXP_W-1:0]          c_exp_prod_domain_tmp;

    always @(*) begin
        s1_pre_d = '0;
        s1_emax_vld_flat_tmp = '0;
        s1_emax_exp_flat_tmp = '0;

        s1_pre_d.special_vld    = s0_q.special_vld;
        s1_pre_d.special_result = s0_q.special_result;
        s1_pre_d.prod_sign_flat = s0_q.prod_sign_flat;
        s1_pre_d.prod_mag_flat  = s0_q.prod_mag_flat;
        s1_pre_d.prod_exp_flat  = s0_q.prod_exp_flat;
        s1_pre_d.prod_zero_flat = s0_q.prod_zero_flat;
        s1_pre_d.c_sign         = s0_q.c_sign;
        s1_pre_d.c_mag          = s0_q.c_mag;
        s1_pre_d.c_zero         = s0_q.c_zero;
        s1_pre_d.mx_scale_exp_sum = s0_q.mx_scale_exp_sum;

        c_exp_prod_domain_tmp = s0_q.c_exp - s0_q.mx_scale_exp_sum;
        s1_pre_d.c_exp_prod_domain = c_exp_prod_domain_tmp;

        s1_emax_vld_flat_tmp[0] = s0_q.prod_emax_vld;
        s1_emax_exp_flat_tmp[0*DOT_F4F6F8_FULL_EXP_W +: DOT_F4F6F8_FULL_EXP_W] = s0_q.prod_emax;
        s1_emax_vld_flat_tmp[1] = !s0_q.c_zero;
        s1_emax_exp_flat_tmp[1*DOT_F4F6F8_FULL_EXP_W +: DOT_F4F6F8_FULL_EXP_W] = c_exp_prod_domain_tmp;

    end

    always @(*) begin
        s1_d          = s1_pre_d;
        s1_d.emax     = s1_emax_tmp;
        s1_d.emax_vld = s1_emax_vld_tmp;
    end

    integer idx2;

    always @(*) begin
        s2_d = '0;
        s2_aligned_prod_flat_tmp = '0;
        s2_d.special_vld    = s1_q.special_vld;
        s2_d.special_result = s1_q.special_result;

        if (s1_q.emax_vld) begin
            s2_d.base_exp = s1_q.emax + s1_q.mx_scale_exp_sum - DOT_F4F6F8_ALIGN_FRAC_BITS_EXP;

            for (idx2 = 0; idx2 < DOT_F4F6F8_NUM_ELEMS; idx2 = idx2 + 1) begin
                s2_aligned_prod_flat_tmp[idx2*DOT_F4F6F8_ALIGN_TERM_W +: DOT_F4F6F8_ALIGN_TERM_W] =
                    s2_prod_aligned_flat[idx2*DOT_F4F6F8_ALIGN_TERM_W +: DOT_F4F6F8_ALIGN_TERM_W];
            end

            s2_d.c_aligned = s2_c_aligned;
        end else begin
            s2_d.base_exp = '0;
            s2_d.c_aligned = '0;
        end

        s2_d.aligned_prod_flat = s2_aligned_prod_flat_tmp;
    end

    function automatic logic signed [DOT_F4F6F8_SUM_W-1:0] extend_align_term(
        input logic signed [DOT_F4F6F8_ALIGN_TERM_W-1:0] term_i
    );
        begin
            extend_align_term = $signed({{(DOT_F4F6F8_SUM_W-DOT_F4F6F8_ALIGN_TERM_W){term_i[DOT_F4F6F8_ALIGN_TERM_W-1]}}, term_i});
        end
    endfunction

    integer idx3;
    always @(*) begin
        s3_pre_d = '0;
        s3_pre_d.special_vld    = s2_q.special_vld;
        s3_pre_d.special_result = s2_q.special_result;
        s3_pre_d.base_exp       = s2_q.base_exp;

        for (idx3 = 0; idx3 < DOT_F4F6F8_NUM_ELEMS + 1; idx3 = idx3 + 1) begin
            s3_term_tmp[idx3] = '0;
        end
        s3_term_tmp[0] = extend_align_term(s2_q.c_aligned);
        for (idx3 = 0; idx3 < DOT_F4F6F8_NUM_ELEMS; idx3 = idx3 + 1) begin
            s3_term_tmp[idx3+1] =
                extend_align_term(s2_aligned_prod_q_flat[idx3*DOT_F4F6F8_ALIGN_TERM_W +: DOT_F4F6F8_ALIGN_TERM_W]);
        end

    end

    always @(*) begin
        s3_d = s3_pre_d;
        s3_partial_sum_flat_tmp = '0;
        s3_partial_sum_tmp[0] = s3_sum8_out[0];
        s3_partial_sum_tmp[1] = s3_sum8_out[1];
        s3_partial_sum_tmp[2] = s3_sum8_out[2];
        s3_partial_sum_tmp[3] = s3_sum8_out[3];
        s3_partial_sum_tmp[4] = s3_term_tmp[32];

        s3_partial_sum_flat_tmp[0*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W] = s3_partial_sum_tmp[0];
        s3_partial_sum_flat_tmp[1*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W] = s3_partial_sum_tmp[1];
        s3_partial_sum_flat_tmp[2*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W] = s3_partial_sum_tmp[2];
        s3_partial_sum_flat_tmp[3*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W] = s3_partial_sum_tmp[3];
        s3_partial_sum_flat_tmp[4*DOT_F4F6F8_SUM_W +: DOT_F4F6F8_SUM_W] = s3_partial_sum_tmp[4];
        s3_d.partial_sum_flat = s3_partial_sum_flat_tmp;
    end

    always @(*) begin
        s4_d = '0;
        s4_d.special_vld    = s3_q.special_vld;
        s4_d.special_result = s3_q.special_result;
        s4_d.base_exp       = s3_q.base_exp;
        s4_d.sum            = s4_sum_tree;
    end

    always @(*) begin
        s5_d = '0;
        s5_d.result = s5_pack_result;
    end

    dot_fp32_rz_norm_pack #(
        .SUM_W(DOT_F4F6F8_SUM_W),
        .EXP_W(DOT_F4F6F8_FULL_EXP_W),
        .CANONICALIZE_ZERO_RESULT(1'b0)
    ) u_dot_fp32_rz_norm_pack (
        .sum_i           (s4_q.sum),
        .base_exp_i      (s4_q.base_exp),
        .special_vld_i   (s4_q.special_vld),
        .special_result_i(s4_q.special_result),
        .result_o        (s5_pack_result)
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
        .out_ready(s5_rdy),
        .out_data (s4_q)
    );

    pipeline_reg #(
        .W($bits(stage5_data_t))
    ) u_stage5_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s4_vld_q),
        .in_ready (s5_rdy),
        .in_data  (s5_d),
        .out_valid(s5_vld_q),
        .out_ready(out_rdy_i),
        .out_data (s5_q)
    );

    assign out_vld_o = s5_vld_q;
    assign d_o       = s5_q.result;

endmodule
