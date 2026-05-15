// ============================================================================
// File Name   : fp16_dot_prod.sv
// Author      : Codex
// Date        : 2026-04-26
// Description : 16-element FP16/BF16 dot-product with FP32 accumulate. The
//               datapath follows the F=25 FDA pipeline defined in
//               doc/FP16_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-26  v0.1      Codex       Initial version
//   2026-04-28  v0.2      Codex       Add BF16 input mode
// ============================================================================

module fp16_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic         fmt_is_bf16_i,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);

    localparam int FP16_W               = 16;
    localparam int NUM_ELEMS            = 16;
    localparam int FP16_SIG_W           = 11;
    localparam int FP16_EXP_W           = 5;
    localparam int FP16_FRAC_W          = 10;
    localparam int BF16_EXP_W           = 8;
    localparam int BF16_FRAC_W          = 7;
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
        logic                    sign;
        logic [FP16_SIG_W-1:0]   sig;
        logic signed [EXP_W-1:0] exp;
        logic                    is_zero;
        logic                    is_inf;
        logic                    is_nan;
    } fp16_bf16_dec_t;

    typedef struct packed {
        logic                    sign;
        logic [FP32_SIG_W-1:0]   sig;
        logic signed [EXP_W-1:0] exp;
        logic                    is_zero;
        logic                    is_inf;
        logic                    is_nan;
    } fp32_dec_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS-1:0]           prod_sign_flat;
        logic [NUM_ELEMS*FP16_SIG_W-1:0] a_sig_flat;
        logic [NUM_ELEMS*FP16_SIG_W-1:0] b_sig_flat;
        logic [NUM_ELEMS*EXP_W-1:0]     a_exp_flat;
        logic [NUM_ELEMS*EXP_W-1:0]     b_exp_flat;
        logic [NUM_ELEMS-1:0]           prod_zero_flat;
        logic                           c_sign;
        logic [FP32_SIG_W-1:0]          c_sig;
        logic signed [EXP_W-1:0]        c_exp;
        logic                           c_zero;
    } stage0_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS-1:0]           prod_sign_flat;
        logic [NUM_ELEMS*PROD_SIG_W-1:0] prod_sig_flat;
        logic [NUM_ELEMS*EXP_W-1:0]     prod_exp_flat;
        logic [NUM_ELEMS-1:0]           prod_zero_flat;
        logic                           c_sign;
        logic [FP32_SIG_W-1:0]          c_sig;
        logic signed [EXP_W-1:0]        c_exp;
        logic                           c_zero;
    } stage1_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS*ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [ALIGN_TERM_W-1:0] c_aligned;
        logic signed [EXP_W-1:0]        base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic signed [SUM_W-1:0]        sum;
        logic signed [EXP_W-1:0]        base_exp;
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
    logic [NUM_ELEMS*FP16_SIG_W-1:0]  s0_a_sig_flat_tmp;
    logic [NUM_ELEMS*FP16_SIG_W-1:0]  s0_b_sig_flat_tmp;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_a_exp_flat_tmp;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_b_exp_flat_tmp;
    logic [NUM_ELEMS-1:0]             s0_prod_zero_flat_tmp;

    logic [NUM_ELEMS-1:0]             s0_prod_sign_flat_hold;
    logic [NUM_ELEMS*FP16_SIG_W-1:0]  s0_a_sig_flat_hold;
    logic [NUM_ELEMS*FP16_SIG_W-1:0]  s0_b_sig_flat_hold;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_a_exp_flat_hold;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_b_exp_flat_hold;
    logic [NUM_ELEMS-1:0]             s0_prod_zero_flat_hold;

    logic [NUM_ELEMS-1:0]             s1_prod_sign_flat_tmp;
    logic [NUM_ELEMS*PROD_SIG_W-1:0]  s1_prod_sig_flat_tmp;
    logic [NUM_ELEMS*EXP_W-1:0]       s1_prod_exp_flat_tmp;

    logic [NUM_ELEMS-1:0]             s1_prod_sign_flat_hold;
    logic [NUM_ELEMS*PROD_SIG_W-1:0]  s1_prod_sig_flat_hold;
    logic [NUM_ELEMS*EXP_W-1:0]       s1_prod_exp_flat_hold;
    logic [NUM_ELEMS-1:0]             s1_prod_zero_flat_hold;

    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_tmp;
    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_hold;

    assign s0_prod_sign_flat_hold  = s0_q.prod_sign_flat;
    assign s0_a_sig_flat_hold      = s0_q.a_sig_flat;
    assign s0_b_sig_flat_hold      = s0_q.b_sig_flat;
    assign s0_a_exp_flat_hold      = s0_q.a_exp_flat;
    assign s0_b_exp_flat_hold      = s0_q.b_exp_flat;
    assign s0_prod_zero_flat_hold  = s0_q.prod_zero_flat;
    assign s1_prod_sign_flat_hold  = s1_q.prod_sign_flat;
    assign s1_prod_sig_flat_hold   = s1_q.prod_sig_flat;
    assign s1_prod_exp_flat_hold   = s1_q.prod_exp_flat;
    assign s1_prod_zero_flat_hold  = s1_q.prod_zero_flat;
    assign s2_aligned_prod_flat_hold = s2_q.aligned_prod_flat;

    function automatic fp16_bf16_dec_t decode_fp16_bf16(
        input logic               fmt_is_bf16,
        input logic [FP16_W-1:0]  fp16_bf16_i
    );
        fp16_bf16_dec_t dec;
        logic [FP16_EXP_W-1:0]  exp_raw;
        logic [FP16_FRAC_W-1:0] frac_raw;
        logic [BF16_EXP_W-1:0]  bf16_exp_raw;
        logic [BF16_FRAC_W-1:0] bf16_frac_raw;
        begin
            dec      = '0;
            dec.sign = fp16_bf16_i[15];
            exp_raw  = fp16_bf16_i[14:10];
            frac_raw = fp16_bf16_i[9:0];
            bf16_exp_raw  = fp16_bf16_i[14:7];
            bf16_frac_raw = fp16_bf16_i[6:0];

            if (fmt_is_bf16) begin
                dec.is_zero = (bf16_exp_raw == 8'h00) && (bf16_frac_raw == 7'h00);
                dec.is_inf  = (bf16_exp_raw == 8'hff) && (bf16_frac_raw == 7'h00);
                dec.is_nan  = (bf16_exp_raw == 8'hff) && (bf16_frac_raw != 7'h00);

                if (dec.is_zero || dec.is_inf || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
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

                if (dec.is_zero || dec.is_inf || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
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

    function automatic fp32_dec_t decode_fp32(input logic [31:0] fp32_i);
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

            if (dec.is_zero || dec.is_inf || dec.is_nan) begin
                dec.sig = '0;
                dec.exp = '0;
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

    function automatic logic signed [ALIGN_TERM_W-1:0] align_fixed_rz(
        input logic                         term_sign_i,
        input logic [ALIGN_MAG_W-1:0]       term_mag_i,
        input logic signed [EXP_W-1:0]      term_exp_i,
        input logic signed [EXP_W-1:0]      emax_i
    );
        logic [ALIGN_MAG_W-1:0]       term_mag_shift;
        logic signed [ALIGN_TERM_W-1:0] aligned_val;
        logic signed [EXP_W:0]        align_shift;
        integer                       shift_i;
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

    function automatic logic [31:0] pack_fp32_rz(
        input logic signed [SUM_W-1:0] sum_i,
        input logic signed [EXP_W-1:0] base_exp_i
    );
        logic             sign_bit;
        logic [SUM_W-1:0] abs_sum;
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
                sig24        = 24'((abs_sum << norm_lshift) >> (SUM_W - 24));

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
    fp16_bf16_dec_t a_dec_tmp;
    fp16_bf16_dec_t b_dec_tmp;
    fp32_dec_t c_dec_tmp;
    logic any_nan_tmp;
    logic has_pos_inf_tmp;
    logic has_neg_inf_tmp;
    logic has_zero_mul_inf_tmp;
    logic lane_has_inf_tmp;
    logic lane_prod_sign_tmp;

    always_comb begin
        s0_d = '0;
        s0_prod_sign_flat_tmp = '0;
        s0_a_sig_flat_tmp     = '0;
        s0_b_sig_flat_tmp     = '0;
        s0_a_exp_flat_tmp     = '0;
        s0_b_exp_flat_tmp     = '0;
        s0_prod_zero_flat_tmp = '0;

        c_dec_tmp            = decode_fp32(c_i);
        any_nan_tmp          = c_dec_tmp.is_nan;
        has_pos_inf_tmp      = c_dec_tmp.is_inf && !c_dec_tmp.sign;
        has_neg_inf_tmp      = c_dec_tmp.is_inf && c_dec_tmp.sign;
        has_zero_mul_inf_tmp = 1'b0;

        s0_d.c_sign = c_dec_tmp.sign;
        s0_d.c_sig  = c_dec_tmp.sig;
        s0_d.c_exp  = c_dec_tmp.exp;
        s0_d.c_zero = c_dec_tmp.is_zero;

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            a_dec_tmp = decode_fp16_bf16(fmt_is_bf16_i, a_vec_i[idx0*FP16_W +: FP16_W]);
            b_dec_tmp = decode_fp16_bf16(fmt_is_bf16_i, b_vec_i[idx0*FP16_W +: FP16_W]);

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

            s0_prod_sign_flat_tmp[idx0] = lane_prod_sign_tmp;
            s0_a_sig_flat_tmp[idx0*FP16_SIG_W +: FP16_SIG_W] = a_dec_tmp.sig;
            s0_b_sig_flat_tmp[idx0*FP16_SIG_W +: FP16_SIG_W] = b_dec_tmp.sig;
            s0_a_exp_flat_tmp[idx0*EXP_W +: EXP_W] = a_dec_tmp.exp;
            s0_b_exp_flat_tmp[idx0*EXP_W +: EXP_W] = b_dec_tmp.exp;
            s0_prod_zero_flat_tmp[idx0] = a_dec_tmp.is_zero || b_dec_tmp.is_zero ||
                                          a_dec_tmp.is_inf  || b_dec_tmp.is_inf  ||
                                          a_dec_tmp.is_nan  || b_dec_tmp.is_nan;
        end

        s0_d.prod_sign_flat = s0_prod_sign_flat_tmp;
        s0_d.a_sig_flat     = s0_a_sig_flat_tmp;
        s0_d.b_sig_flat     = s0_b_sig_flat_tmp;
        s0_d.a_exp_flat     = s0_a_exp_flat_tmp;
        s0_d.b_exp_flat     = s0_b_exp_flat_tmp;
        s0_d.prod_zero_flat = s0_prod_zero_flat_tmp;

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

    integer idx1;
    logic [FP16_SIG_W-1:0]       a_sig_s1_tmp;
    logic [FP16_SIG_W-1:0]       b_sig_s1_tmp;
    logic signed [EXP_W-1:0]     a_exp_s1_tmp;
    logic signed [EXP_W-1:0]     b_exp_s1_tmp;
    logic [PROD_SIG_W-1:0]       prod_sig_s1_tmp;
    logic signed [EXP_W-1:0]     prod_exp_s1_tmp;

    always_comb begin
        s1_d = '0;
        s1_prod_sign_flat_tmp = '0;
        s1_prod_sig_flat_tmp  = '0;
        s1_prod_exp_flat_tmp  = '0;

        s1_d.special_vld    = s0_q.special_vld;
        s1_d.special_result = s0_q.special_result;
        s1_d.prod_zero_flat = s0_q.prod_zero_flat;
        s1_d.c_sign         = s0_q.c_sign;
        s1_d.c_sig          = s0_q.c_sig;
        s1_d.c_exp          = s0_q.c_exp;
        s1_d.c_zero         = s0_q.c_zero;

        for (idx1 = 0; idx1 < NUM_ELEMS; idx1 = idx1 + 1) begin
            a_sig_s1_tmp = s0_a_sig_flat_hold[idx1*FP16_SIG_W +: FP16_SIG_W];
            b_sig_s1_tmp = s0_b_sig_flat_hold[idx1*FP16_SIG_W +: FP16_SIG_W];
            a_exp_s1_tmp = $signed(s0_a_exp_flat_hold[idx1*EXP_W +: EXP_W]);
            b_exp_s1_tmp = $signed(s0_b_exp_flat_hold[idx1*EXP_W +: EXP_W]);

            prod_sig_s1_tmp = a_sig_s1_tmp * b_sig_s1_tmp;
            prod_exp_s1_tmp = a_exp_s1_tmp + b_exp_s1_tmp;

            s1_prod_sign_flat_tmp[idx1] = s0_prod_sign_flat_hold[idx1];
            s1_prod_sig_flat_tmp[idx1*PROD_SIG_W +: PROD_SIG_W] = prod_sig_s1_tmp;
            s1_prod_exp_flat_tmp[idx1*EXP_W +: EXP_W] = s0_prod_zero_flat_hold[idx1] ? '0 : prod_exp_s1_tmp;
        end

        s1_d.prod_sign_flat = s1_prod_sign_flat_tmp;
        s1_d.prod_sig_flat  = s1_prod_sig_flat_tmp;
        s1_d.prod_exp_flat  = s1_prod_exp_flat_tmp;
    end

    integer idx2;
    logic signed [EXP_W-1:0] emax_tmp;
    logic                    emax_vld_tmp;
    logic signed [EXP_W-1:0] prod_exp_s2_tmp;
    logic [PROD_SIG_W-1:0]   prod_sig_s2_tmp;
    logic [ALIGN_MAG_W-1:0]  prod_mag_s2_tmp;
    logic [ALIGN_MAG_W-1:0]  c_mag_s2_tmp;

    always_comb begin
        s2_d = '0;
        s2_aligned_prod_flat_tmp = '0;
        emax_tmp     = '0;
        emax_vld_tmp = 1'b0;
        prod_exp_s2_tmp = '0;
        prod_sig_s2_tmp = '0;
        prod_mag_s2_tmp = '0;
        c_mag_s2_tmp    = '0;

        s2_d.special_vld    = s1_q.special_vld;
        s2_d.special_result = s1_q.special_result;

        if (!s1_q.c_zero) begin
            emax_tmp     = s1_q.c_exp;
            emax_vld_tmp = 1'b1;
        end

        for (idx2 = 0; idx2 < NUM_ELEMS; idx2 = idx2 + 1) begin
            if (!s1_prod_zero_flat_hold[idx2]) begin
                prod_exp_s2_tmp = $signed(s1_prod_exp_flat_hold[idx2*EXP_W +: EXP_W]);
                if (!emax_vld_tmp || (prod_exp_s2_tmp > emax_tmp)) begin
                    emax_tmp     = prod_exp_s2_tmp;
                    emax_vld_tmp = 1'b1;
                end
            end
        end

        if (emax_vld_tmp) begin
            s2_d.base_exp = emax_tmp - ALIGN_FRAC_BITS_EXP;

            for (idx2 = 0; idx2 < NUM_ELEMS; idx2 = idx2 + 1) begin
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
                                       emax_tmp);
                end
            end

            if (!s1_q.c_zero) begin
                c_mag_s2_tmp = {{(ALIGN_MAG_W-FP32_SIG_W-C_ALIGN_PAD_W){1'b0}},
                                s1_q.c_sig,
                                {C_ALIGN_PAD_W{1'b0}}};
                s2_d.c_aligned = align_fixed_rz(s1_q.c_sign, c_mag_s2_tmp, s1_q.c_exp, emax_tmp);
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
        if (s3_q.special_vld) begin
            s4_d.result = s3_q.special_result;
        end else begin
            s4_d.result = pack_fp32_rz(s3_q.sum, s3_q.base_exp);
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
    assign d_o       = s4_q.result;

endmodule

module fp16_dot16_fda_f25 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [15:0] a_in [16],
    input  logic [15:0] b_in [16],
    input  logic [31:0] c_in,
    output logic        out_valid,
    output logic [31:0] d_out
);

    logic [255:0] a_vec;
    logic [255:0] b_vec;
    logic         in_ready_unused;

    integer idx_pack;

    always_comb begin
        a_vec = '0;
        b_vec = '0;
        for (idx_pack = 0; idx_pack < 16; idx_pack = idx_pack + 1) begin
            a_vec[idx_pack*16 +: 16] = a_in[idx_pack];
            b_vec[idx_pack*16 +: 16] = b_in[idx_pack];
        end
    end

    fp16_dot_prod u_fp16_dot_prod (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_vld_i     (in_valid),
        .in_rdy_o     (in_ready_unused),
        .fmt_is_bf16_i(1'b0),
        .a_vec_i      (a_vec),
        .b_vec_i      (b_vec),
        .c_i          (c_in),
        .out_vld_o    (out_valid),
        .out_rdy_i    (1'b1),
        .d_o          (d_out)
    );

endmodule

module bf16_dot16_fda_f25 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [15:0] a_in [16],
    input  logic [15:0] b_in [16],
    input  logic [31:0] c_in,
    output logic        out_valid,
    output logic [31:0] d_out
);

    logic [255:0] a_vec;
    logic [255:0] b_vec;
    logic         in_ready_unused;

    integer idx_pack;

    always_comb begin
        a_vec = '0;
        b_vec = '0;
        for (idx_pack = 0; idx_pack < 16; idx_pack = idx_pack + 1) begin
            a_vec[idx_pack*16 +: 16] = a_in[idx_pack];
            b_vec[idx_pack*16 +: 16] = b_in[idx_pack];
        end
    end

    fp16_dot_prod u_bf16_dot_prod (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_vld_i     (in_valid),
        .in_rdy_o     (in_ready_unused),
        .fmt_is_bf16_i(1'b1),
        .a_vec_i      (a_vec),
        .b_vec_i      (b_vec),
        .c_i          (c_in),
        .out_vld_o    (out_valid),
        .out_rdy_i    (1'b1),
        .d_o          (d_out)
    );

endmodule
