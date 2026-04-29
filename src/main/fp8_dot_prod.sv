// ============================================================================
// File Name   : fp8_dot_prod.sv
// Author      : Codex
// Date        : 2026-04-22
// Description : 32-element FP8/MXFP8 dot-product with FP32 accumulate. The
//               datapath follows the 5-stage FDA pipeline defined in
//               doc/FP8_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-22  v0.1      Codex       Initial version
// ============================================================================

module fp8_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    input  logic         fp8_format_i,
    input  logic         mxfp8_en_i,
    input  logic [7:0]   a_mx_scale_i,
    input  logic [7:0]   b_mx_scale_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);

    localparam int FP8_W            = 8;
    localparam int NUM_ELEMS        = 32;
    localparam int FP8_SIG_W        = 4;
    localparam int PROD_SIG_W       = 8;
    localparam int C_SIG_W          = 24;
    localparam int MX_SCALE_W       = 8;
    localparam int EXP_W            = 10;
    localparam int ALIGN_FRAC_BITS  = 25;
    localparam int ALIGN_TERM_W     = 28;
    localparam int SUM_W            = 35;
    localparam int FP8_SIG_FRAC_BITS = 3;
    localparam int PROD_SIG_FRAC_BITS = 6;
    localparam int C_SIG_FRAC_BITS    = 23;
    localparam int PROD_ALIGN_PAD_W   = ALIGN_FRAC_BITS - PROD_SIG_FRAC_BITS;
    localparam int C_ALIGN_PAD_W      = ALIGN_FRAC_BITS - C_SIG_FRAC_BITS;
    localparam logic signed [EXP_W-1:0] ALIGN_FRAC_BITS_EXP = 10'sd25;
    localparam logic signed [EXP_W-1:0] MX_SCALE_BIAS_EXP = 10'sd127;

    typedef struct packed {
        logic                      sign;
        logic [FP8_SIG_W-1:0]      sig;
        logic signed [EXP_W-1:0]   exp;
        logic                      is_zero;
        logic                      is_inf;
        logic                      is_nan;
    } fp8_dec_t;

    typedef struct packed {
        logic                      sign;
        logic [C_SIG_W-1:0]        sig;
        logic signed [EXP_W-1:0]   exp;
        logic                      is_zero;
        logic                      is_inf;
        logic                      is_nan;
    } fp32_dec_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS-1:0]           prod_sign_flat;
        logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0] prod_mag_flat;
        logic [NUM_ELEMS*EXP_W-1:0]     prod_exp_flat;
        logic [NUM_ELEMS-1:0]           prod_zero_flat;
        logic                           c_sign;
        logic [ALIGN_TERM_W-2:0]        c_mag;
        logic signed [EXP_W-1:0]        c_exp;
        logic                           c_zero;
    } stage0_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS-1:0]           prod_sign_flat;
        logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0] prod_mag_flat;
        logic [NUM_ELEMS*EXP_W-1:0]     prod_exp_flat;
        logic [NUM_ELEMS-1:0]           prod_zero_flat;
        logic                           c_sign;
        logic [ALIGN_TERM_W-2:0]        c_mag;
        logic signed [EXP_W-1:0]        c_exp;
        logic                           c_zero;
        logic signed [EXP_W-1:0]        emax;
        logic                           emax_vld;
    } stage1_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS*ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [ALIGN_TERM_W-1:0]    c_aligned;
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

    logic [NUM_ELEMS-1:0]                    s0_prod_sign_flat_tmp;
    logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0]   s0_prod_mag_flat_tmp;
    logic [NUM_ELEMS*EXP_W-1:0]              s0_prod_exp_flat_tmp;
    logic [NUM_ELEMS-1:0]                    s0_prod_zero_flat_tmp;

    logic [NUM_ELEMS-1:0]                    s0_prod_sign_q_flat;
    logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0]   s0_prod_mag_q_flat;
    logic [NUM_ELEMS*EXP_W-1:0]              s0_prod_exp_q_flat;
    logic [NUM_ELEMS-1:0]                    s0_prod_zero_q_flat;

    logic [NUM_ELEMS-1:0]                    s1_prod_sign_q_flat;
    logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0]   s1_prod_mag_q_flat;
    logic [NUM_ELEMS*EXP_W-1:0]              s1_prod_exp_q_flat;
    logic [NUM_ELEMS-1:0]                    s1_prod_zero_q_flat;

    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_tmp;
    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_q_flat;

    assign s0_prod_sign_q_flat = s0_q.prod_sign_flat;
    assign s0_prod_mag_q_flat  = s0_q.prod_mag_flat;
    assign s0_prod_exp_q_flat  = s0_q.prod_exp_flat;
    assign s0_prod_zero_q_flat = s0_q.prod_zero_flat;
    assign s1_prod_sign_q_flat = s1_q.prod_sign_flat;
    assign s1_prod_mag_q_flat  = s1_q.prod_mag_flat;
    assign s1_prod_exp_q_flat  = s1_q.prod_exp_flat;
    assign s1_prod_zero_q_flat = s1_q.prod_zero_flat;
    assign s2_aligned_prod_q_flat = s2_q.aligned_prod_flat;

    function automatic fp8_dec_t decode_fp8(
        input logic [FP8_W-1:0] fp8_i,
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

                if (dec.is_zero || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (fp8_i[6:3] == 4'b0000) begin
                    dec.sig = {1'b0, mant_raw};
                    dec.exp = -10'sd6;
                end else begin
                    dec.sig = {1'b1, mant_raw};
                    dec.exp = $signed({6'd0, fp8_i[6:3]}) - 10'sd7;
                end
            end else begin
                mant_raw = {1'b0, fp8_i[1:0]};

                dec.is_zero = (fp8_i[6:2] == 5'b00000) && (fp8_i[1:0] == 2'b00);
                dec.is_inf  = (fp8_i[6:2] == 5'b11111) && (fp8_i[1:0] == 2'b00);
                dec.is_nan  = (fp8_i[6:2] == 5'b11111) && (fp8_i[1:0] != 2'b00);

                if (dec.is_zero || dec.is_inf || dec.is_nan) begin
                    dec.sig = '0;
                    dec.exp = '0;
                end else if (fp8_i[6:2] == 5'b00000) begin
                    dec.sig = {1'b0, fp8_i[1:0], 1'b0};
                    dec.exp = -10'sd14;
                end else begin
                    dec.sig = {1'b1, fp8_i[1:0], 1'b0};
                    dec.exp = $signed({5'd0, fp8_i[6:2]}) - 10'sd15;
                end
            end

            return dec;
        end
    endfunction

    function automatic fp32_dec_t decode_fp32(
        input logic [31:0] fp32_i
    );
        fp32_dec_t dec;
        logic [7:0] exp_raw;
        logic [22:0] frac_raw;
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
                dec.exp = $signed({2'b00, exp_raw}) - 10'sd127;
            end

            return dec;
        end
    endfunction

    function automatic logic signed [EXP_W-1:0] decode_e8m0_exp(
        input logic [MX_SCALE_W-1:0] scale_i
    );
        begin
            decode_e8m0_exp = $signed({2'b00, scale_i}) - MX_SCALE_BIAS_EXP;
        end
    endfunction

    function automatic logic signed [ALIGN_TERM_W-1:0] align_fixed_rz(
        input logic                      term_sign_i,
        input logic [ALIGN_TERM_W-2:0]   term_mag_i,
        input logic signed [EXP_W-1:0]   term_exp_i,
        input logic signed [EXP_W-1:0]   emax_i
    );
        logic [ALIGN_TERM_W-2:0] term_mag_shift;
        logic signed [ALIGN_TERM_W-1:0] aligned_val;
        logic signed [EXP_W:0] align_shift;
        integer shift_i;
        begin
            if (term_mag_i == '0) begin
                align_fixed_rz = '0;
            end else begin
                align_shift = $signed({emax_i[EXP_W-1], emax_i})
                            - $signed({term_exp_i[EXP_W-1], term_exp_i});
                if (align_shift <= 0) begin
                    term_mag_shift = term_mag_i;
                end else if (align_shift >= (ALIGN_TERM_W-1)) begin
                    term_mag_shift = '0;
                end else begin
                    shift_i = align_shift;
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
            sign_bit = sum_i[SUM_W-1];

            if (sum_i == '0) begin
                pack_fp32_rz = 32'h0000_0000;
            end else begin
                if (sign_bit) begin
                    abs_sum = -sum_i;
                end else begin
                    abs_sum = sum_i;
                end

                msb_idx = 0;
                for (idx = SUM_W-1; idx >= 0; idx = idx - 1) begin
                    if (abs_sum[idx]) begin
                        msb_idx = idx;
                        idx = -1;
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
                    exp_field  = unbiased_exp + 127;
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
    fp8_dec_t a_dec_tmp;
    fp8_dec_t b_dec_tmp;
    fp32_dec_t c_dec_tmp;
    logic any_nan_tmp;
    logic has_pos_inf_tmp;
    logic has_neg_inf_tmp;
    logic has_zero_mul_inf_tmp;
    logic lane_has_inf_tmp;
    logic lane_prod_sign_tmp;
    logic [PROD_SIG_W-1:0] lane_prod_sig_tmp;
    logic [ALIGN_TERM_W-2:0] lane_prod_mag_tmp;
    logic [ALIGN_TERM_W-2:0] c_mag_tmp_s0;
    logic mx_scale_nan_tmp;
    logic signed [EXP_W-1:0] mx_scale_exp_sum_tmp;

    always @(*) begin
        s0_d = '0;
        s0_prod_sign_flat_tmp = '0;
        s0_prod_mag_flat_tmp  = '0;
        s0_prod_exp_flat_tmp  = '0;
        s0_prod_zero_flat_tmp = '0;

        c_dec_tmp            = decode_fp32(c_i);
        mx_scale_nan_tmp     = mxfp8_en_i && ((a_mx_scale_i == 8'hff) || (b_mx_scale_i == 8'hff));
        mx_scale_exp_sum_tmp = mxfp8_en_i
                             ? (decode_e8m0_exp(a_mx_scale_i) + decode_e8m0_exp(b_mx_scale_i))
                             : '0;
        any_nan_tmp          = c_dec_tmp.is_nan | mx_scale_nan_tmp;
        has_pos_inf_tmp      = c_dec_tmp.is_inf && !c_dec_tmp.sign;
        has_neg_inf_tmp      = c_dec_tmp.is_inf && c_dec_tmp.sign;
        has_zero_mul_inf_tmp = 1'b0;

        s0_d.c_sign = c_dec_tmp.sign;
        s0_d.c_exp  = c_dec_tmp.exp;
        s0_d.c_zero = c_dec_tmp.is_zero;
        c_mag_tmp_s0 = {{(ALIGN_TERM_W-1-C_SIG_W-C_ALIGN_PAD_W){1'b0}},
                        c_dec_tmp.sig,
                        {C_ALIGN_PAD_W{1'b0}}};
        s0_d.c_mag = c_mag_tmp_s0;

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            a_dec_tmp = decode_fp8(a_vec_i[idx0*FP8_W +: FP8_W], fp8_format_i);
            b_dec_tmp = decode_fp8(b_vec_i[idx0*FP8_W +: FP8_W], fp8_format_i);

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
                s0_prod_mag_flat_tmp[idx0*(ALIGN_TERM_W-1) +: (ALIGN_TERM_W-1)] = '0;
                s0_prod_exp_flat_tmp[idx0*EXP_W +: EXP_W] = '0;
                s0_prod_zero_flat_tmp[idx0] = 1'b1;
            end else begin
                s0_prod_sign_flat_tmp[idx0] = lane_prod_sign_tmp;
                s0_prod_zero_flat_tmp[idx0] = a_dec_tmp.is_zero || b_dec_tmp.is_zero;
                lane_prod_sig_tmp = a_dec_tmp.sig * b_dec_tmp.sig;
                lane_prod_mag_tmp = {{(ALIGN_TERM_W-1-PROD_SIG_W-PROD_ALIGN_PAD_W){1'b0}},
                                     lane_prod_sig_tmp,
                                     {PROD_ALIGN_PAD_W{1'b0}}};
                s0_prod_mag_flat_tmp[idx0*(ALIGN_TERM_W-1) +: (ALIGN_TERM_W-1)] = lane_prod_mag_tmp;

                if (a_dec_tmp.is_zero || b_dec_tmp.is_zero) begin
                    s0_prod_exp_flat_tmp[idx0*EXP_W +: EXP_W] = '0;
                end else begin
                    s0_prod_exp_flat_tmp[idx0*EXP_W +: EXP_W] =
                        a_dec_tmp.exp + b_dec_tmp.exp + mx_scale_exp_sum_tmp;
                end
            end
        end

        s0_d.prod_sign_flat = s0_prod_sign_flat_tmp;
        s0_d.prod_mag_flat  = s0_prod_mag_flat_tmp;
        s0_d.prod_exp_flat  = s0_prod_exp_flat_tmp;
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
    logic signed [EXP_W-1:0] prod_exp_s1_tmp;
    logic signed [EXP_W-1:0] emax_tmp;
    logic                    emax_vld_tmp;

    always @(*) begin
        s1_d = '0;
        s1_d.special_vld    = s0_q.special_vld;
        s1_d.special_result = s0_q.special_result;
        s1_d.prod_sign_flat = s0_q.prod_sign_flat;
        s1_d.prod_mag_flat  = s0_q.prod_mag_flat;
        s1_d.prod_exp_flat  = s0_q.prod_exp_flat;
        s1_d.prod_zero_flat = s0_q.prod_zero_flat;
        s1_d.c_sign         = s0_q.c_sign;
        s1_d.c_mag          = s0_q.c_mag;
        s1_d.c_exp          = s0_q.c_exp;
        s1_d.c_zero         = s0_q.c_zero;

        emax_tmp     = '0;
        emax_vld_tmp = 1'b0;

        if (!s0_q.c_zero) begin
            emax_tmp     = s0_q.c_exp;
            emax_vld_tmp = 1'b1;
        end

        for (idx1 = 0; idx1 < NUM_ELEMS; idx1 = idx1 + 1) begin
            if (!s0_prod_zero_q_flat[idx1]) begin
                prod_exp_s1_tmp = $signed(s0_prod_exp_q_flat[idx1*EXP_W +: EXP_W]);
                if (!emax_vld_tmp || (prod_exp_s1_tmp > emax_tmp)) begin
                    emax_tmp     = prod_exp_s1_tmp;
                    emax_vld_tmp = 1'b1;
                end
            end
        end

        s1_d.emax     = emax_tmp;
        s1_d.emax_vld = emax_vld_tmp;
    end

    integer idx2;
    logic signed [EXP_W-1:0]   prod_exp_s2_tmp;

    always @(*) begin
        s2_d = '0;
        s2_aligned_prod_flat_tmp = '0;
        s2_d.special_vld    = s1_q.special_vld;
        s2_d.special_result = s1_q.special_result;

        if (s1_q.emax_vld) begin
            s2_d.base_exp = s1_q.emax - ALIGN_FRAC_BITS_EXP;

            for (idx2 = 0; idx2 < NUM_ELEMS; idx2 = idx2 + 1) begin
                if (!s1_prod_zero_q_flat[idx2]) begin
                    prod_exp_s2_tmp = $signed(s1_prod_exp_q_flat[idx2*EXP_W +: EXP_W]);
                    s2_aligned_prod_flat_tmp[idx2*ALIGN_TERM_W +: ALIGN_TERM_W] =
                        align_fixed_rz(s1_prod_sign_q_flat[idx2],
                                       s1_prod_mag_q_flat[idx2*(ALIGN_TERM_W-1) +: (ALIGN_TERM_W-1)],
                                       prod_exp_s2_tmp, s1_q.emax);
                end
            end

            if (s1_q.c_zero) begin
                s2_d.c_aligned = '0;
            end else begin
                s2_d.c_aligned = align_fixed_rz(s1_q.c_sign, s1_q.c_mag,
                                                s1_q.c_exp, s1_q.emax);
            end
        end else begin
            s2_d.base_exp = '0;
            s2_d.c_aligned = '0;
        end

        s2_d.aligned_prod_flat = s2_aligned_prod_flat_tmp;
    end

    integer idx3;
    logic signed [SUM_W-1:0] sum_acc_tmp;

    always @(*) begin
        s3_d = '0;
        s3_d.special_vld    = s2_q.special_vld;
        s3_d.special_result = s2_q.special_result;
        s3_d.base_exp       = s2_q.base_exp;

        sum_acc_tmp = $signed({{(SUM_W-ALIGN_TERM_W){s2_q.c_aligned[ALIGN_TERM_W-1]}}, s2_q.c_aligned});
        for (idx3 = 0; idx3 < NUM_ELEMS; idx3 = idx3 + 1) begin
            sum_acc_tmp = sum_acc_tmp
                        + $signed({{(SUM_W-ALIGN_TERM_W){s2_aligned_prod_q_flat[idx3*ALIGN_TERM_W + ALIGN_TERM_W-1]}},
                                   s2_aligned_prod_q_flat[idx3*ALIGN_TERM_W +: ALIGN_TERM_W]});
        end
        s3_d.sum = sum_acc_tmp;
    end

    always @(*) begin
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
