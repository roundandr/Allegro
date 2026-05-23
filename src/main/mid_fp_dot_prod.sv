// ============================================================================
// File Name   : mid_fp_dot_prod.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-29
// Description : Shared TF32/BF16/FP16 dot-product with FP32 accumulate. The
//               datapath follows the F=25 FDA pipeline defined in
//               doc/MID_FP_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-29  v0.1      LIU YUXUAN       Initial version
//   2026-05-22  v0.2      LIU YUXUAN       Add scale-input-d C operand preprocess
// ============================================================================

module mid_fp_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [1:0]   a_mode_i,
    input  logic [1:0]   b_mode_i,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    input  logic [3:0]   scale_input_d_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);

    localparam logic [1:0] MID_FP_MODE_TF32 = 2'd0;
    localparam logic [1:0] MID_FP_MODE_BF16 = 2'd1;
    localparam logic [1:0] MID_FP_MODE_FP16 = 2'd2;

    localparam int FP16_W               = 16;
    localparam int FP32_W               = 32;
    localparam int NUM_ELEMS            = 16;
    localparam int TF32_NUM_ELEMS       = 8;
    localparam int SIG_W                = 11;
    localparam int FP16_EXP_W           = 5;
    localparam int FP16_FRAC_W          = 10;
    localparam int BF16_EXP_W           = 8;
    localparam int BF16_FRAC_W          = 7;
    localparam int TF32_FRAC_W          = 10;
    localparam int BF16_SIG_PAD_W       = FP16_FRAC_W - BF16_FRAC_W;
    localparam int FP32_SIG_W           = 24;
    localparam int FP32_EXP_W           = 8;
    localparam int FP32_FRAC_W          = 23;
    localparam int EXP_W                = 10;
    localparam int PROD_SIG_W           = 22;
    localparam int PROD_SIG_FRAC_BITS   = 20;
    localparam int ALIGN_FRAC_BITS      = 25;
    localparam int ALIGN_INT_BITS       = 7;
    localparam int ALIGN_MAG_W          = ALIGN_INT_BITS + ALIGN_FRAC_BITS;
    localparam int ALIGN_TERM_W         = ALIGN_MAG_W + 1;
    localparam int SUM_W                = ALIGN_TERM_W;
    localparam int PROD_ALIGN_PAD_W     = ALIGN_FRAC_BITS - PROD_SIG_FRAC_BITS;
    localparam int C_ALIGN_PAD_W        = ALIGN_FRAC_BITS - FP32_FRAC_W;
    localparam logic signed [EXP_W-1:0] ALIGN_FRAC_BITS_EXP = 10'sd25;
    localparam logic signed [EXP_W:0]   ALIGN_MAG_W_EXP     = 11'sd32;

    typedef struct packed {
        logic                    valid;
        logic                    sign;
        logic [SIG_W-1:0]        sig;
        logic signed [EXP_W-1:0] exp;
        logic                    is_zero;
        logic                    is_inf;
        logic                    is_nan;
    } mid_fp_dec_t;

    typedef struct packed {
        logic                    sign;
        logic [FP32_SIG_W-1:0]   sig;
        logic signed [EXP_W-1:0] exp;
        logic                    is_zero;
        logic                    is_inf;
        logic                    is_nan;
    } fp32_dec_t;

    typedef struct packed {
        logic                            special_vld;
        logic [31:0]                     special_result;
        logic [NUM_ELEMS-1:0]            prod_sign_flat;
        logic [NUM_ELEMS*SIG_W-1:0]      a_sig_flat;
        logic [NUM_ELEMS*SIG_W-1:0]      b_sig_flat;
        logic [NUM_ELEMS*EXP_W-1:0]      prod_exp_flat;
        logic [NUM_ELEMS-1:0]            prod_zero_flat;
        logic                            c_sign;
        logic [FP32_SIG_W-1:0]           c_sig;
        logic signed [EXP_W-1:0]         c_exp;
        logic                            c_zero;
        logic signed [EXP_W-1:0]         emax;
        logic                            emax_vld;
    } stage0_data_t;

    typedef struct packed {
        logic                             special_vld;
        logic [31:0]                      special_result;
        logic [NUM_ELEMS-1:0]             prod_sign_flat;
        logic [NUM_ELEMS*PROD_SIG_W-1:0]  prod_sig_flat;
        logic [NUM_ELEMS*EXP_W-1:0]       prod_exp_flat;
        logic [NUM_ELEMS-1:0]             prod_zero_flat;
        logic                             c_sign;
        logic [FP32_SIG_W-1:0]            c_sig;
        logic signed [EXP_W-1:0]          c_exp;
        logic                             c_zero;
        logic signed [EXP_W-1:0]          emax;
        logic                             emax_vld;
    } stage1_data_t;

    typedef struct packed {
        logic                              special_vld;
        logic [31:0]                       special_result;
        logic [NUM_ELEMS*ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [ALIGN_TERM_W-1:0]    c_aligned;
        logic signed [EXP_W-1:0]           base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic                         special_vld;
        logic [31:0]                  special_result;
        logic signed [SUM_W-1:0]      sum;
        logic signed [EXP_W-1:0]      base_exp;
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

    logic [NUM_ELEMS-1:0]             s0_prod_sign_flat_tmp;
    logic [NUM_ELEMS*SIG_W-1:0]       s0_a_sig_flat_tmp;
    logic [NUM_ELEMS*SIG_W-1:0]       s0_b_sig_flat_tmp;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_prod_exp_flat_tmp;
    logic [NUM_ELEMS-1:0]             s0_prod_zero_flat_tmp;

    logic [NUM_ELEMS-1:0]             s0_prod_sign_flat_hold;
    logic [NUM_ELEMS*SIG_W-1:0]       s0_a_sig_flat_hold;
    logic [NUM_ELEMS*SIG_W-1:0]       s0_b_sig_flat_hold;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_prod_exp_flat_hold;
    logic [NUM_ELEMS-1:0]             s0_prod_zero_flat_hold;

    logic [NUM_ELEMS-1:0]             s1_prod_sign_flat_tmp;
    logic [NUM_ELEMS*PROD_SIG_W-1:0]  s1_prod_sig_flat_tmp;

    logic [NUM_ELEMS-1:0]             s1_prod_sign_flat_hold;
    logic [NUM_ELEMS*PROD_SIG_W-1:0]  s1_prod_sig_flat_hold;
    logic [NUM_ELEMS*EXP_W-1:0]       s1_prod_exp_flat_hold;
    logic [NUM_ELEMS-1:0]             s1_prod_zero_flat_hold;

    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_tmp;
    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_hold;

    assign s0_prod_sign_flat_hold    = s0_q.prod_sign_flat;
    assign s0_a_sig_flat_hold        = s0_q.a_sig_flat;
    assign s0_b_sig_flat_hold        = s0_q.b_sig_flat;
    assign s0_prod_exp_flat_hold     = s0_q.prod_exp_flat;
    assign s0_prod_zero_flat_hold    = s0_q.prod_zero_flat;
    assign s1_prod_sign_flat_hold    = s1_q.prod_sign_flat;
    assign s1_prod_sig_flat_hold     = s1_q.prod_sig_flat;
    assign s1_prod_exp_flat_hold     = s1_q.prod_exp_flat;
    assign s1_prod_zero_flat_hold    = s1_q.prod_zero_flat;
    assign s2_aligned_prod_flat_hold = s2_q.aligned_prod_flat;

    function automatic mid_fp_dec_t decode_disabled_lane;
        mid_fp_dec_t dec;
        begin
            dec         = '0;
            dec.valid   = 1'b0;
            dec.is_zero = 1'b1;
            return dec;
        end
    endfunction

    function automatic mid_fp_dec_t decode_tf32_from_fp32(
        input logic lane_valid_i,
        input logic [FP32_W-1:0] fp32_i
    );
        mid_fp_dec_t dec;
        logic [FP32_EXP_W-1:0]   exp_raw;
        logic [FP32_FRAC_W-1:0]  frac_raw;
        logic [TF32_FRAC_W-1:0]  tf32_frac;
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
                    dec.exp = -10'sd126;
                end else if (exp_raw == 8'h00) begin
                    dec.sig = {1'b0, tf32_frac};
                    dec.exp = -10'sd126;
                end else begin
                    dec.sig = {1'b1, tf32_frac};
                    dec.exp = $signed({2'd0, exp_raw}) - 10'sd127;
                end
            end

            return dec;
        end
    endfunction

    function automatic mid_fp_dec_t decode_fp16_bf16(
        input logic              is_bf16_i,
        input logic [FP16_W-1:0] fp16_bf16_i
    );
        mid_fp_dec_t dec;
        logic [FP16_EXP_W-1:0]  exp_raw;
        logic [FP16_FRAC_W-1:0] frac_raw;
        logic [BF16_EXP_W-1:0]  bf16_exp_raw;
        logic [BF16_FRAC_W-1:0] bf16_frac_raw;
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
                    dec.exp = -10'sd126;
                end else if (bf16_exp_raw == 8'h00) begin
                    dec.sig = {1'b0, bf16_frac_raw, {BF16_SIG_PAD_W{1'b0}}};
                    dec.exp = -10'sd126;
                end else begin
                    dec.sig = {1'b1, bf16_frac_raw, {BF16_SIG_PAD_W{1'b0}}};
                    dec.exp = $signed({2'd0, bf16_exp_raw}) - 10'sd127;
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
                    dec.exp = -10'sd126;
                end else if (exp_raw == 5'h00) begin
                    dec.sig = {1'b0, frac_raw};
                    dec.exp = -10'sd14;
                end else begin
                    dec.sig = {1'b1, frac_raw};
                    dec.exp = $signed({5'd0, exp_raw}) - 10'sd15;
                end
            end

            return dec;
        end
    endfunction

    function automatic fp32_dec_t decode_fp32(input logic [FP32_W-1:0] fp32_i);
        fp32_dec_t dec;
        logic [FP32_EXP_W-1:0]  exp_raw;
        logic [FP32_FRAC_W-1:0] frac_raw;
        begin
            dec      = '0;
            dec.sign = fp32_i[31];
            exp_raw  = fp32_i[30:23];
            frac_raw = fp32_i[22:0];

            dec.is_zero = (exp_raw == 8'h00) && (frac_raw == 23'h0);
            dec.is_inf  = (exp_raw == 8'hff) && (frac_raw == 23'h0);
            dec.is_nan  = (exp_raw == 8'hff) && (frac_raw != 23'h0);

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
                dec.exp = $signed({2'd0, exp_raw}) - 10'sd127;
            end

            return dec;
        end
    endfunction

    function automatic logic [FP32_W-1:0] scale_fp32_pow2_rz(
        input logic [FP32_W-1:0] value_i,
        input logic [3:0]        shift_i
    );
        logic                    sign;
        logic [FP32_EXP_W-1:0]   exp_raw;
        logic [FP32_FRAC_W-1:0]  frac_raw;
        logic [FP32_SIG_W-1:0]   sig24;
        integer                  new_exp;
        integer                  sub_shift;
        logic [FP32_SIG_W-1:0]   sub_sig;
        begin
            sign      = value_i[31];
            exp_raw   = value_i[30:23];
            frac_raw  = value_i[22:0];
            sig24     = {1'b1, frac_raw};
            new_exp   = int'(exp_raw) - int'(shift_i);
            sub_shift = 0;
            sub_sig   = '0;
            scale_fp32_pow2_rz = value_i;

            if ((shift_i == 4'd0) || (exp_raw == 8'hff) || (value_i[30:0] == 31'd0)) begin
                scale_fp32_pow2_rz = value_i;
            end else if (exp_raw == 8'h00) begin
                scale_fp32_pow2_rz = {sign, 8'h00, frac_raw >> shift_i};
            end else if (new_exp > 0) begin
                scale_fp32_pow2_rz = {sign, 8'(new_exp), frac_raw};
            end else begin
                sub_shift = int'(shift_i) + 1 - int'(exp_raw);
                if (sub_shift >= FP32_SIG_W) begin
                    sub_sig = '0;
                end else begin
                    sub_sig = sig24 >> sub_shift;
                end
                scale_fp32_pow2_rz = {sign, 8'h00, sub_sig[FP32_FRAC_W-1:0]};
            end
        end
    endfunction

    function automatic logic signed [ALIGN_TERM_W-1:0] align_fixed_rz(
        input logic                         term_sign_i,
        input logic [ALIGN_MAG_W-1:0]       term_mag_i,
        input logic signed [EXP_W-1:0]      term_exp_i,
        input logic signed [EXP_W-1:0]      emax_i
    );
        logic [ALIGN_MAG_W-1:0]         term_mag_shift;
        logic signed [ALIGN_TERM_W-1:0] aligned_val;
        logic signed [EXP_W:0]          align_shift;
        integer                         shift_i;
        begin
            align_fixed_rz = '0;
            term_mag_shift = '0;
            aligned_val    = '0;
            align_shift    = '0;
            shift_i        = 0;

            if (term_mag_i != '0) begin
                align_shift = $signed({emax_i[EXP_W-1], emax_i})
                            - $signed({term_exp_i[EXP_W-1], term_exp_i});
                if (align_shift <= 0) begin
                    term_mag_shift = term_mag_i;
                end else if (align_shift >= ALIGN_MAG_W_EXP) begin
                    term_mag_shift = '0;
                end else begin
                    shift_i = int'(align_shift);
                    term_mag_shift = term_mag_i >> shift_i;
                end

                aligned_val = $signed({1'b0, term_mag_shift});
                align_fixed_rz = term_sign_i ? -aligned_val : aligned_val;
            end
        end
    endfunction

    function automatic logic emax_pick_vld(
        input logic a_vld_i,
        input logic b_vld_i
    );
        begin
            emax_pick_vld = a_vld_i | b_vld_i;
        end
    endfunction

    function automatic logic signed [EXP_W-1:0] emax_pick_exp(
        input logic                    a_vld_i,
        input logic signed [EXP_W-1:0] a_exp_i,
        input logic                    b_vld_i,
        input logic signed [EXP_W-1:0] b_exp_i
    );
        begin
            if (!a_vld_i) begin
                emax_pick_exp = b_exp_i;
            end else if (!b_vld_i) begin
                emax_pick_exp = a_exp_i;
            end else if (b_exp_i > a_exp_i) begin
                emax_pick_exp = b_exp_i;
            end else begin
                emax_pick_exp = a_exp_i;
            end
        end
    endfunction

    function automatic logic [31:0] pack_fp32_rz(
        input logic signed [SUM_W-1:0] sum_i,
        input logic signed [EXP_W-1:0] base_exp_i
    );
        logic             sign_bit;
        logic [SUM_W-1:0] abs_sum;
        logic [SUM_W-1:0] norm_sum;
        logic [23:0]      sig24;
        logic [22:0]      frac_field;
        logic [7:0]       exp_field;
        integer           msb_idx;
        integer           norm_lshift;
        integer           unbiased_exp;
        integer           shift_sub;
        integer           idx;
        begin
            pack_fp32_rz = 32'h0000_0000;
            sign_bit     = sum_i[SUM_W-1];
            abs_sum      = '0;
            norm_sum     = '0;
            sig24        = '0;
            frac_field   = '0;
            exp_field    = '0;
            msb_idx      = 0;
            norm_lshift  = 0;
            unbiased_exp = 0;
            shift_sub    = 0;

            if (sum_i != '0) begin
                if (sign_bit) begin
                    abs_sum = -sum_i;
                end else begin
                    abs_sum = sum_i;
                end

                for (idx = 0; idx < SUM_W; idx = idx + 1) begin
                    if (abs_sum[idx]) begin
                        msb_idx = idx;
                    end
                end

                unbiased_exp = $signed({{(32-EXP_W){base_exp_i[EXP_W-1]}}, base_exp_i}) + msb_idx;
                norm_lshift  = (SUM_W - 1) - msb_idx;
                norm_sum     = abs_sum << norm_lshift;
                sig24        = norm_sum[SUM_W-1 -: 24];

                if (unbiased_exp > 127) begin
                    exp_field  = 8'hff;
                    frac_field = 23'h0;
                end else if (unbiased_exp >= -126) begin
                    exp_field  = 8'(unbiased_exp + 127);
                    frac_field = sig24[22:0];
                end else if (unbiased_exp < -149) begin
                    exp_field  = 8'h00;
                    frac_field = 23'h0;
                end else begin
                    shift_sub  = -126 - unbiased_exp;
                    sig24      = sig24 >> shift_sub;
                    exp_field  = 8'h00;
                    frac_field = sig24[22:0];
                end

                pack_fp32_rz = {sign_bit, exp_field, frac_field};
            end
        end
    endfunction

    integer idx0;
    mid_fp_dec_t a_dec_tmp;
    mid_fp_dec_t b_dec_tmp;
    fp32_dec_t c_dec_tmp;
    logic [FP32_W-1:0] c_preprocessed_tmp;
    logic any_nan_tmp;
    logic has_pos_inf_tmp;
    logic has_neg_inf_tmp;
    logic has_zero_mul_inf_tmp;
    logic lane_prod_sign_tmp;
    logic lane_prod_zero_tmp;
    logic lane_prod_emax_vld_tmp;
    logic signed [EXP_W-1:0] prod_exp_s0_tmp;
    logic reserved_mode_tmp;
    logic                         emax_s0_l0_vld_tmp [0:16];
    logic signed [EXP_W-1:0]      emax_s0_l0_exp_tmp [0:16];
    logic                         emax_s0_l1_vld_tmp [0:8];
    logic signed [EXP_W-1:0]      emax_s0_l1_exp_tmp [0:8];
    logic                         emax_s0_l2_vld_tmp [0:4];
    logic signed [EXP_W-1:0]      emax_s0_l2_exp_tmp [0:4];
    logic                         emax_s0_l3_vld_tmp [0:2];
    logic signed [EXP_W-1:0]      emax_s0_l3_exp_tmp [0:2];
    logic                         emax_s0_l4_vld_tmp [0:1];
    logic signed [EXP_W-1:0]      emax_s0_l4_exp_tmp [0:1];
    always_comb begin
        logic lane_has_inf_tmp;
        logic lane_valid_tmp;

        s0_d = '0;
        s0_prod_sign_flat_tmp = '0;
        s0_a_sig_flat_tmp     = '0;
        s0_b_sig_flat_tmp     = '0;
        s0_prod_exp_flat_tmp  = '0;
        s0_prod_zero_flat_tmp = '0;

        c_preprocessed_tmp   = scale_fp32_pow2_rz(c_i, scale_input_d_i);
        c_dec_tmp            = decode_fp32(c_preprocessed_tmp);
        reserved_mode_tmp    = (a_mode_i == 2'd3) ||
                                (b_mode_i == 2'd3) ||
                                ((a_mode_i == MID_FP_MODE_TF32) !=
                                 (b_mode_i == MID_FP_MODE_TF32));
        any_nan_tmp          = c_dec_tmp.is_nan || reserved_mode_tmp;
        has_pos_inf_tmp      = c_dec_tmp.is_inf && !c_dec_tmp.sign;
        has_neg_inf_tmp      = c_dec_tmp.is_inf && c_dec_tmp.sign;
        has_zero_mul_inf_tmp = 1'b0;
        lane_has_inf_tmp     = 1'b0;
        lane_valid_tmp       = 1'b0;
        lane_prod_sign_tmp   = 1'b0;
        lane_prod_zero_tmp   = 1'b0;
        lane_prod_emax_vld_tmp = 1'b0;
        prod_exp_s0_tmp      = '0;

        s0_d.c_sign = c_dec_tmp.sign;
        s0_d.c_sig  = c_dec_tmp.sig;
        s0_d.c_exp  = c_dec_tmp.exp;
        s0_d.c_zero = c_dec_tmp.is_zero;

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            a_dec_tmp = decode_disabled_lane();
            b_dec_tmp = decode_disabled_lane();
            lane_valid_tmp = 1'b0;

            if (!reserved_mode_tmp &&
                (a_mode_i == MID_FP_MODE_TF32) &&
                (b_mode_i == MID_FP_MODE_TF32)) begin
                lane_valid_tmp = (idx0 < TF32_NUM_ELEMS);
                if (lane_valid_tmp) begin
                    a_dec_tmp = decode_tf32_from_fp32(1'b1, a_vec_i[idx0*FP32_W +: FP32_W]);
                    b_dec_tmp = decode_tf32_from_fp32(1'b1, b_vec_i[idx0*FP32_W +: FP32_W]);
                end
            end else if (!reserved_mode_tmp) begin
                a_dec_tmp = decode_fp16_bf16(a_mode_i == MID_FP_MODE_BF16,
                                             a_vec_i[idx0*FP16_W +: FP16_W]);
                b_dec_tmp = decode_fp16_bf16(b_mode_i == MID_FP_MODE_BF16,
                                             b_vec_i[idx0*FP16_W +: FP16_W]);
            end

            lane_prod_sign_tmp = a_dec_tmp.sign ^ b_dec_tmp.sign;
            prod_exp_s0_tmp    = a_dec_tmp.exp + b_dec_tmp.exp;
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
            s0_a_sig_flat_tmp[idx0*SIG_W +: SIG_W] = a_dec_tmp.sig;
            s0_b_sig_flat_tmp[idx0*SIG_W +: SIG_W] = b_dec_tmp.sig;
            s0_prod_exp_flat_tmp[idx0*EXP_W +: EXP_W] = lane_prod_zero_tmp ? '0 : prod_exp_s0_tmp;
            s0_prod_zero_flat_tmp[idx0] = lane_prod_zero_tmp;
            emax_s0_l0_vld_tmp[idx0] = lane_prod_emax_vld_tmp;
            emax_s0_l0_exp_tmp[idx0] = prod_exp_s0_tmp;
        end
        emax_s0_l0_vld_tmp[16] = 1'b1;
        emax_s0_l0_exp_tmp[16] = c_dec_tmp.exp;

        for (int idx0_l1 = 0; idx0_l1 < 8; idx0_l1 = idx0_l1 + 1) begin
            emax_s0_l1_vld_tmp[idx0_l1] =
                emax_pick_vld(emax_s0_l0_vld_tmp[idx0_l1*2],
                              emax_s0_l0_vld_tmp[idx0_l1*2+1]);
            emax_s0_l1_exp_tmp[idx0_l1] =
                emax_pick_exp(emax_s0_l0_vld_tmp[idx0_l1*2],
                              emax_s0_l0_exp_tmp[idx0_l1*2],
                              emax_s0_l0_vld_tmp[idx0_l1*2+1],
                              emax_s0_l0_exp_tmp[idx0_l1*2+1]);
        end
        emax_s0_l1_vld_tmp[8] = emax_s0_l0_vld_tmp[16];
        emax_s0_l1_exp_tmp[8] = emax_s0_l0_exp_tmp[16];

        for (int idx0_l2 = 0; idx0_l2 < 4; idx0_l2 = idx0_l2 + 1) begin
            emax_s0_l2_vld_tmp[idx0_l2] =
                emax_pick_vld(emax_s0_l1_vld_tmp[idx0_l2*2],
                              emax_s0_l1_vld_tmp[idx0_l2*2+1]);
            emax_s0_l2_exp_tmp[idx0_l2] =
                emax_pick_exp(emax_s0_l1_vld_tmp[idx0_l2*2],
                              emax_s0_l1_exp_tmp[idx0_l2*2],
                              emax_s0_l1_vld_tmp[idx0_l2*2+1],
                              emax_s0_l1_exp_tmp[idx0_l2*2+1]);
        end
        emax_s0_l2_vld_tmp[4] = emax_s0_l1_vld_tmp[8];
        emax_s0_l2_exp_tmp[4] = emax_s0_l1_exp_tmp[8];

        for (int idx0_l3 = 0; idx0_l3 < 2; idx0_l3 = idx0_l3 + 1) begin
            emax_s0_l3_vld_tmp[idx0_l3] =
                emax_pick_vld(emax_s0_l2_vld_tmp[idx0_l3*2],
                              emax_s0_l2_vld_tmp[idx0_l3*2+1]);
            emax_s0_l3_exp_tmp[idx0_l3] =
                emax_pick_exp(emax_s0_l2_vld_tmp[idx0_l3*2],
                              emax_s0_l2_exp_tmp[idx0_l3*2],
                              emax_s0_l2_vld_tmp[idx0_l3*2+1],
                              emax_s0_l2_exp_tmp[idx0_l3*2+1]);
        end
        emax_s0_l3_vld_tmp[2] = emax_s0_l2_vld_tmp[4];
        emax_s0_l3_exp_tmp[2] = emax_s0_l2_exp_tmp[4];

        emax_s0_l4_vld_tmp[0] = emax_pick_vld(emax_s0_l3_vld_tmp[0],
                                              emax_s0_l3_vld_tmp[1]);
        emax_s0_l4_exp_tmp[0] = emax_pick_exp(emax_s0_l3_vld_tmp[0],
                                              emax_s0_l3_exp_tmp[0],
                                              emax_s0_l3_vld_tmp[1],
                                              emax_s0_l3_exp_tmp[1]);
        emax_s0_l4_vld_tmp[1] = emax_s0_l3_vld_tmp[2];
        emax_s0_l4_exp_tmp[1] = emax_s0_l3_exp_tmp[2];

        s0_d.prod_sign_flat = s0_prod_sign_flat_tmp;
        s0_d.a_sig_flat     = s0_a_sig_flat_tmp;
        s0_d.b_sig_flat     = s0_b_sig_flat_tmp;
        s0_d.prod_exp_flat  = s0_prod_exp_flat_tmp;
        s0_d.prod_zero_flat = s0_prod_zero_flat_tmp;
        s0_d.emax_vld       = emax_pick_vld(emax_s0_l4_vld_tmp[0],
                                            emax_s0_l4_vld_tmp[1]);
        s0_d.emax           = emax_pick_exp(emax_s0_l4_vld_tmp[0],
                                           emax_s0_l4_exp_tmp[0],
                                           emax_s0_l4_vld_tmp[1],
                                           emax_s0_l4_exp_tmp[1]);

        if (any_nan_tmp || has_zero_mul_inf_tmp || (has_pos_inf_tmp && has_neg_inf_tmp)) begin
            s0_d.special_vld    = 1'b1;
            s0_d.special_result = 32'h7fff_ffff;
        end else if (has_pos_inf_tmp) begin
            s0_d.special_vld    = 1'b1;
            s0_d.special_result = 32'h7f80_0000;
        end else if (has_neg_inf_tmp) begin
            s0_d.special_vld    = 1'b1;
            s0_d.special_result = 32'hff80_0000;
        end else begin
            s0_d.special_vld    = 1'b0;
            s0_d.special_result = 32'h0000_0000;
        end
    end

    logic [SIG_W-1:0]             a_sig_s1_tmp;
    logic [SIG_W-1:0]             b_sig_s1_tmp;
    logic [PROD_SIG_W-1:0]        prod_sig_s1_tmp;
    always_comb begin
        s1_d = '0;
        s1_prod_sign_flat_tmp = '0;
        s1_prod_sig_flat_tmp  = '0;

        s1_d.special_vld    = s0_q.special_vld;
        s1_d.special_result = s0_q.special_result;
        s1_d.prod_zero_flat = s0_q.prod_zero_flat;
        s1_d.c_sign         = s0_q.c_sign;
        s1_d.c_sig          = s0_q.c_sig;
        s1_d.c_exp          = s0_q.c_exp;
        s1_d.c_zero         = s0_q.c_zero;
        s1_d.prod_exp_flat  = s0_prod_exp_flat_hold;
        s1_d.emax_vld       = s0_q.emax_vld;
        s1_d.emax           = s0_q.emax;

        for (int idx1 = 0; idx1 < NUM_ELEMS; idx1 = idx1 + 1) begin
            a_sig_s1_tmp = s0_a_sig_flat_hold[idx1*SIG_W +: SIG_W];
            b_sig_s1_tmp = s0_b_sig_flat_hold[idx1*SIG_W +: SIG_W];
            prod_sig_s1_tmp = a_sig_s1_tmp * b_sig_s1_tmp;

            s1_prod_sign_flat_tmp[idx1] = s0_prod_sign_flat_hold[idx1];
            s1_prod_sig_flat_tmp[idx1*PROD_SIG_W +: PROD_SIG_W] = prod_sig_s1_tmp;
        end

        s1_d.prod_sign_flat = s1_prod_sign_flat_tmp;
        s1_d.prod_sig_flat  = s1_prod_sig_flat_tmp;
    end
    logic signed [EXP_W-1:0] prod_exp_s2_tmp;
    logic [PROD_SIG_W-1:0]   prod_sig_s2_tmp;
    logic [ALIGN_MAG_W-1:0]  prod_mag_s2_tmp;
    logic [ALIGN_MAG_W-1:0]  c_mag_s2_tmp;
    always_comb begin
        s2_d = '0;
        s2_aligned_prod_flat_tmp = '0;
        prod_exp_s2_tmp = '0;
        prod_sig_s2_tmp = '0;
        prod_mag_s2_tmp = '0;
        c_mag_s2_tmp    = '0;

        s2_d.special_vld    = s1_q.special_vld;
        s2_d.special_result = s1_q.special_result;

        if (s1_q.emax_vld) begin
            s2_d.base_exp = s1_q.emax - ALIGN_FRAC_BITS_EXP;

            for (int idx2 = 0; idx2 < NUM_ELEMS; idx2 = idx2 + 1) begin
                if (!s1_prod_zero_flat_hold[idx2]) begin
                    prod_sig_s2_tmp = s1_prod_sig_flat_hold[idx2*PROD_SIG_W +: PROD_SIG_W];
                    prod_exp_s2_tmp = $signed(s1_prod_exp_flat_hold[idx2*EXP_W +: EXP_W]);
                    prod_mag_s2_tmp = {{(ALIGN_MAG_W-PROD_SIG_W-PROD_ALIGN_PAD_W){1'b0}},
                                       prod_sig_s2_tmp,
                                       {PROD_ALIGN_PAD_W{1'b0}}};
                    s2_aligned_prod_flat_tmp[idx2*ALIGN_TERM_W +: ALIGN_TERM_W] =
                        align_fixed_rz(s1_prod_sign_flat_hold[idx2],
                                       prod_mag_s2_tmp,
                                       prod_exp_s2_tmp,
                                       s1_q.emax);
                end
            end

            if (!s1_q.c_zero) begin
                c_mag_s2_tmp = {{(ALIGN_MAG_W-FP32_SIG_W-C_ALIGN_PAD_W){1'b0}},
                                s1_q.c_sig,
                                {C_ALIGN_PAD_W{1'b0}}};
                s2_d.c_aligned = align_fixed_rz(s1_q.c_sign, c_mag_s2_tmp, s1_q.c_exp, s1_q.emax);
            end
        end

        s2_d.aligned_prod_flat = s2_aligned_prod_flat_tmp;
    end

    integer idx3;
    logic signed [SUM_W-1:0] sum_acc_tmp;

    always_comb begin
        s3_d = '0;
        s3_d.special_vld    = s2_q.special_vld;
        s3_d.special_result = s2_q.special_result;
        s3_d.base_exp       = s2_q.base_exp;

        sum_acc_tmp = s2_q.c_aligned;
        for (idx3 = 0; idx3 < NUM_ELEMS; idx3 = idx3 + 1) begin
            sum_acc_tmp = sum_acc_tmp
                        + $signed(s2_aligned_prod_flat_hold[idx3*ALIGN_TERM_W +: ALIGN_TERM_W]);
        end
        s3_d.sum = sum_acc_tmp;
    end

    always_comb begin
        s4_d = '0;
        s4_d.result = s3_q.special_vld ? s3_q.special_result
                                       : pack_fp32_rz(s3_q.sum, s3_q.base_exp);
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
    assign d_o       = s4_q.result;

endmodule
