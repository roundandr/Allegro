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
    localparam logic [1:0] MID_FP_MODE_RSVD = MID_FP_MODE_FP16 + 2'd1;
    localparam logic [1:0] SPECIAL_NONE     = 2'd0;
    localparam logic [1:0] SPECIAL_NAN      = 2'd1;
    localparam logic [1:0] SPECIAL_POS_INF  = 2'd2;
    localparam logic [1:0] SPECIAL_NEG_INF  = 2'd3;

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
    localparam int EXP_W                = 9;
    localparam int PROD_SIG_W           = 22;
    localparam int PROD_SIG_FRAC_BITS   = 20;
    localparam int ALIGN_FRAC_BITS      = 25;
    localparam int ALIGN_INT_BITS       = 7;
    localparam int ALIGN_MAG_W          = ALIGN_INT_BITS + ALIGN_FRAC_BITS;
    localparam int ALIGN_TERM_W         = ALIGN_MAG_W + 1;
    localparam int SUM_W                = ALIGN_TERM_W;
    localparam int PROD_ALIGN_PAD_W     = ALIGN_FRAC_BITS - PROD_SIG_FRAC_BITS;
    localparam int C_ALIGN_PAD_W        = ALIGN_FRAC_BITS - FP32_FRAC_W;
    localparam int ACC_L0_TERMS         = NUM_ELEMS + 1;
    localparam int ACC_L1_TERMS         = (ACC_L0_TERMS + 1) / 2;
    localparam int ACC_L2_TERMS         = (ACC_L1_TERMS + 1) / 2;
    localparam int ACC_L3_TERMS         = (ACC_L2_TERMS + 1) / 2;
    localparam int ACC_L4_TERMS         = (ACC_L3_TERMS + 1) / 2;
    localparam int EMAX_L0_TERMS        = NUM_ELEMS + 1;
    localparam int EMAX_L1_TERMS        = (EMAX_L0_TERMS + 1) / 2;
    localparam int EMAX_L2_TERMS        = (EMAX_L1_TERMS + 1) / 2;
    localparam int EMAX_L3_TERMS        = (EMAX_L2_TERMS + 1) / 2;
    localparam int EMAX_L4_TERMS        = (EMAX_L3_TERMS + 1) / 2;
    localparam logic signed [EXP_W-1:0] ALIGN_FRAC_BITS_EXP = 9'sd25;
    localparam logic signed [EXP_W:0]   ALIGN_MAG_W_EXP     = 10'sd32;
    localparam logic signed [EXP_W-1:0] EMAX_MIN_EXP        = {1'b1, {(EXP_W-1){1'b0}}};

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
        logic [1:0]                      special_code;
        logic [NUM_ELEMS-1:0]            prod_sign_flat;
        logic [NUM_ELEMS*PROD_SIG_W-1:0] prod_sig_flat;
        logic [NUM_ELEMS*EXP_W-1:0]      prod_exp_flat;
        logic [NUM_ELEMS-1:0]            prod_zero_flat;
        logic [EMAX_L2_TERMS*EXP_W-1:0]  emax_l2_exp_flat;
        logic                            c_sign;
        logic [FP32_SIG_W-1:0]           c_sig;
        logic signed [EXP_W-1:0]         c_exp;
        logic                            c_zero;
    } stage0_data_t;

    typedef struct packed {
        logic [1:0]                       special_code;
        logic [NUM_ELEMS-1:0]             prod_sign_flat;
        logic [NUM_ELEMS*PROD_SIG_W-1:0]  prod_sig_flat;
        logic [NUM_ELEMS*EXP_W-1:0]       prod_exp_flat;
        logic [NUM_ELEMS-1:0]             prod_zero_flat;
        logic                             c_sign;
        logic [FP32_SIG_W-1:0]            c_sig;
        logic signed [EXP_W-1:0]          c_exp;
        logic                             c_zero;
        logic signed [EXP_W-1:0]          emax;
    } stage1_data_t;

    typedef struct packed {
        logic [1:0]                        special_code;
        logic [NUM_ELEMS*ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [ALIGN_TERM_W-1:0]    c_aligned;
        logic signed [EXP_W-1:0]           base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic [1:0]                   special_code;
        logic                         sum_sign;
        logic [SUM_W-1:0]             sum_abs;
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
    logic [NUM_ELEMS*PROD_SIG_W-1:0]  s0_prod_sig_flat_tmp;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_prod_exp_flat_tmp;
    logic [NUM_ELEMS-1:0]             s0_prod_zero_flat_tmp;
    logic [EMAX_L2_TERMS*EXP_W-1:0]   s0_emax_l2_exp_flat_tmp;

    logic [NUM_ELEMS*EXP_W-1:0]       s0_prod_exp_flat_hold;
    logic [NUM_ELEMS-1:0]             s0_prod_zero_flat_hold;
    logic [EMAX_L2_TERMS*EXP_W-1:0]   s0_emax_l2_exp_flat_hold;

    logic [NUM_ELEMS*EXP_W-1:0]       s1_prod_exp_flat_tmp;

    logic [NUM_ELEMS-1:0]             s1_prod_sign_flat_hold;
    logic [NUM_ELEMS*PROD_SIG_W-1:0]  s1_prod_sig_flat_hold;
    logic [NUM_ELEMS*EXP_W-1:0]       s1_prod_exp_flat_hold;
    logic [NUM_ELEMS-1:0]             s1_prod_zero_flat_hold;

    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_tmp;
    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_hold;

    logic signed [EXP_W-1:0]      emax_l0_exp_tmp [0:EMAX_L0_TERMS-1];
    logic signed [EXP_W-1:0]      emax_l1_exp_tmp [0:EMAX_L1_TERMS-1];
    logic signed [EXP_W-1:0]      emax_l2_exp_tmp [0:EMAX_L2_TERMS-1];
    logic signed [EXP_W-1:0]      emax_l3_exp_tmp [0:EMAX_L3_TERMS-1];
    logic signed [EXP_W-1:0]      emax_l4_exp_tmp [0:EMAX_L4_TERMS-1];

    assign s0_prod_exp_flat_hold     = s0_q.prod_exp_flat;
    assign s0_prod_zero_flat_hold    = s0_q.prod_zero_flat;
    assign s0_emax_l2_exp_flat_hold  = s0_q.emax_l2_exp_flat;
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
                    dec.exp = -9'sd126;
                end else if (bf16_exp_raw == 8'h00) begin
                    dec.sig = {1'b0, bf16_frac_raw, {BF16_SIG_PAD_W{1'b0}}};
                    dec.exp = -9'sd126;
                end else begin
                    dec.sig = {1'b1, bf16_frac_raw, {BF16_SIG_PAD_W{1'b0}}};
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
        logic [FP32_FRAC_W-1:0]  sub_frac;
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
                if (sub_shift >= FP32_SIG_W) begin
                    sub_frac = '0;
                end else begin
                    sub_frac = FP32_FRAC_W'(sig24 >> sub_shift);
                end
                scale_fp32_pow2_rz = {sign, 8'h00, sub_frac};
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

    function automatic logic signed [EXP_W-1:0] emax_max_exp(
        input logic signed [EXP_W-1:0] a_exp_i,
        input logic signed [EXP_W-1:0] b_exp_i
    );
        begin
            if (b_exp_i > a_exp_i) begin
                emax_max_exp = b_exp_i;
            end else begin
                emax_max_exp = a_exp_i;
            end
        end
    endfunction

    function automatic logic [31:0] pack_fp32_rz(
        input logic                    sum_sign_i,
        input logic [SUM_W-1:0]        sum_abs_i,
        input logic signed [EXP_W-1:0] base_exp_i
    );
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
            norm_sum     = '0;
            sig24        = '0;
            frac_field   = '0;
            exp_field    = '0;
            msb_idx      = 0;
            norm_lshift  = 0;
            unbiased_exp = 0;
            shift_sub    = 0;

            if (sum_abs_i != '0) begin
                for (idx = 0; idx < SUM_W; idx = idx + 1) begin
                    if (sum_abs_i[idx]) begin
                        msb_idx = idx;
                    end
                end

                unbiased_exp = $signed({{(32-EXP_W){base_exp_i[EXP_W-1]}}, base_exp_i}) + msb_idx;
                norm_lshift  = (SUM_W - 1) - msb_idx;
                norm_sum     = sum_abs_i << norm_lshift;
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

                pack_fp32_rz = {sum_sign_i, exp_field, frac_field};
            end
        end
    endfunction

    function automatic logic [31:0] pack_special_fp32(
        input logic [1:0] special_code_i
    );
        begin
            case (special_code_i)
                SPECIAL_NAN: begin
                    pack_special_fp32 = 32'h7fff_ffff;
                end
                SPECIAL_POS_INF: begin
                    pack_special_fp32 = 32'h7f80_0000;
                end
                SPECIAL_NEG_INF: begin
                    pack_special_fp32 = 32'hff80_0000;
                end
                default: begin
                    pack_special_fp32 = 32'h0000_0000;
                end
            endcase
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
    logic reserved_mode_tmp;
    always_comb begin
        logic lane_has_inf_tmp;
        logic lane_valid_tmp;
        logic lane_prod_zero_tmp;
        logic lane_prod_emax_vld_tmp;
        logic [PROD_SIG_W-1:0] lane_prod_sig_tmp;
        logic signed [EXP_W-1:0] lane_prod_exp_tmp;

        s0_d = '0;
        s0_prod_sign_flat_tmp = '0;
        s0_prod_sig_flat_tmp  = '0;
        s0_prod_exp_flat_tmp  = '0;
        s0_prod_zero_flat_tmp = '0;
        s0_emax_l2_exp_flat_tmp = '0;

        c_preprocessed_tmp   = scale_fp32_pow2_rz(c_i, scale_input_d_i);
        c_dec_tmp            = decode_fp32(c_preprocessed_tmp);
        reserved_mode_tmp    = (a_mode_i == MID_FP_MODE_RSVD) ||
                                (b_mode_i == MID_FP_MODE_RSVD) ||
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
        lane_prod_sig_tmp    = '0;
        lane_prod_exp_tmp    = '0;

        for (idx0 = 0; idx0 < EMAX_L0_TERMS; idx0 = idx0 + 1) begin
            emax_l0_exp_tmp[idx0] = EMAX_MIN_EXP;
        end
        for (idx0 = 0; idx0 < EMAX_L1_TERMS; idx0 = idx0 + 1) begin
            emax_l1_exp_tmp[idx0] = EMAX_MIN_EXP;
        end
        for (idx0 = 0; idx0 < EMAX_L2_TERMS; idx0 = idx0 + 1) begin
            emax_l2_exp_tmp[idx0] = EMAX_MIN_EXP;
        end

        s0_d.c_sign = c_dec_tmp.sign;
        s0_d.c_sig  = c_dec_tmp.sig;
        s0_d.c_exp  = c_dec_tmp.exp;
        s0_d.c_zero = c_dec_tmp.is_zero;

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            a_dec_tmp = decode_disabled_lane();
            b_dec_tmp = decode_disabled_lane();
            lane_valid_tmp = 1'b0;
            lane_prod_zero_tmp = 1'b0;
            lane_prod_emax_vld_tmp = 1'b0;
            lane_prod_sig_tmp = '0;
            lane_prod_exp_tmp = '0;

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
            s0_prod_sig_flat_tmp[idx0*PROD_SIG_W +: PROD_SIG_W] = lane_prod_sig_tmp;
            s0_prod_exp_flat_tmp[idx0*EXP_W +: EXP_W] = lane_prod_exp_tmp;
            s0_prod_zero_flat_tmp[idx0] = lane_prod_zero_tmp;
            emax_l0_exp_tmp[idx0] = lane_prod_emax_vld_tmp ? lane_prod_exp_tmp
                                                            : EMAX_MIN_EXP;
        end
        emax_l0_exp_tmp[NUM_ELEMS] = c_dec_tmp.exp;

        for (idx0 = 0; idx0 < (EMAX_L1_TERMS-1); idx0 = idx0 + 1) begin
            emax_l1_exp_tmp[idx0] = emax_max_exp(emax_l0_exp_tmp[idx0*2],
                                                 emax_l0_exp_tmp[idx0*2+1]);
        end
        emax_l1_exp_tmp[EMAX_L1_TERMS-1] = emax_l0_exp_tmp[EMAX_L0_TERMS-1];

        for (idx0 = 0; idx0 < (EMAX_L2_TERMS-1); idx0 = idx0 + 1) begin
            emax_l2_exp_tmp[idx0] = emax_max_exp(emax_l1_exp_tmp[idx0*2],
                                                 emax_l1_exp_tmp[idx0*2+1]);
        end
        emax_l2_exp_tmp[EMAX_L2_TERMS-1] = emax_l1_exp_tmp[EMAX_L1_TERMS-1];

        for (idx0 = 0; idx0 < EMAX_L2_TERMS; idx0 = idx0 + 1) begin
            s0_emax_l2_exp_flat_tmp[idx0*EXP_W +: EXP_W] = emax_l2_exp_tmp[idx0];
        end

        s0_d.prod_sign_flat = s0_prod_sign_flat_tmp;
        s0_d.prod_sig_flat  = s0_prod_sig_flat_tmp;
        s0_d.prod_exp_flat  = s0_prod_exp_flat_tmp;
        s0_d.prod_zero_flat = s0_prod_zero_flat_tmp;
        s0_d.emax_l2_exp_flat = s0_emax_l2_exp_flat_tmp;

        if (any_nan_tmp || has_zero_mul_inf_tmp || (has_pos_inf_tmp && has_neg_inf_tmp)) begin
            s0_d.special_code = SPECIAL_NAN;
        end else if (has_pos_inf_tmp) begin
            s0_d.special_code = SPECIAL_POS_INF;
        end else if (has_neg_inf_tmp) begin
            s0_d.special_code = SPECIAL_NEG_INF;
        end else begin
            s0_d.special_code = SPECIAL_NONE;
        end
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

        for (int idx1 = 0; idx1 < NUM_ELEMS; idx1 = idx1 + 1) begin
            s1_prod_exp_flat_tmp[idx1*EXP_W +: EXP_W] =
                s0_prod_zero_flat_hold[idx1] ? '0 :
                s0_prod_exp_flat_hold[idx1*EXP_W +: EXP_W];
        end

        for (int idx1 = 0; idx1 < (EMAX_L3_TERMS-1); idx1 = idx1 + 1) begin
            emax_l3_exp_tmp[idx1] =
                emax_max_exp($signed(s0_emax_l2_exp_flat_hold[(idx1*2)*EXP_W +: EXP_W]),
                             $signed(s0_emax_l2_exp_flat_hold[(idx1*2+1)*EXP_W +: EXP_W]));
        end
        emax_l3_exp_tmp[EMAX_L3_TERMS-1] =
            $signed(s0_emax_l2_exp_flat_hold[(EMAX_L2_TERMS-1)*EXP_W +: EXP_W]);

        emax_l4_exp_tmp[0] = emax_max_exp(emax_l3_exp_tmp[0], emax_l3_exp_tmp[1]);
        emax_l4_exp_tmp[1] = emax_l3_exp_tmp[EMAX_L3_TERMS-1];

        s1_d.prod_exp_flat  = s1_prod_exp_flat_tmp;
        s1_d.emax           = emax_max_exp(emax_l4_exp_tmp[0], emax_l4_exp_tmp[1]);
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

        s2_d.special_code = s1_q.special_code;

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

        s2_d.aligned_prod_flat = s2_aligned_prod_flat_tmp;
    end

    integer idx3;
    logic signed [SUM_W-1:0] sum_l0_tmp [0:ACC_L0_TERMS-1];
    logic signed [SUM_W-1:0] sum_l1_tmp [0:ACC_L1_TERMS-1];
    logic signed [SUM_W-1:0] sum_l2_tmp [0:ACC_L2_TERMS-1];
    logic signed [SUM_W-1:0] sum_l3_tmp [0:ACC_L3_TERMS-1];
    logic signed [SUM_W-1:0] sum_l4_tmp [0:ACC_L4_TERMS-1];
    logic signed [SUM_W-1:0] sum_final_tmp;

    always_comb begin
        s3_d = '0;
        sum_final_tmp = '0;
        s3_d.special_code = s2_q.special_code;
        s3_d.base_exp     = s2_q.base_exp;

        for (idx3 = 0; idx3 < ACC_L0_TERMS; idx3 = idx3 + 1) begin
            sum_l0_tmp[idx3] = '0;
        end
        for (idx3 = 0; idx3 < ACC_L1_TERMS; idx3 = idx3 + 1) begin
            sum_l1_tmp[idx3] = '0;
        end
        for (idx3 = 0; idx3 < ACC_L2_TERMS; idx3 = idx3 + 1) begin
            sum_l2_tmp[idx3] = '0;
        end
        for (idx3 = 0; idx3 < ACC_L3_TERMS; idx3 = idx3 + 1) begin
            sum_l3_tmp[idx3] = '0;
        end
        for (idx3 = 0; idx3 < ACC_L4_TERMS; idx3 = idx3 + 1) begin
            sum_l4_tmp[idx3] = '0;
        end

        sum_l0_tmp[0] = s2_q.c_aligned;
        for (idx3 = 0; idx3 < NUM_ELEMS; idx3 = idx3 + 1) begin
            sum_l0_tmp[idx3+1] =
                $signed(s2_aligned_prod_flat_hold[idx3*ALIGN_TERM_W +: ALIGN_TERM_W]);
        end

        for (idx3 = 0; idx3 < (ACC_L1_TERMS-1); idx3 = idx3 + 1) begin
            sum_l1_tmp[idx3] = sum_l0_tmp[idx3*2] + sum_l0_tmp[idx3*2+1];
        end
        sum_l1_tmp[ACC_L1_TERMS-1] = sum_l0_tmp[ACC_L0_TERMS-1];

        for (idx3 = 0; idx3 < (ACC_L2_TERMS-1); idx3 = idx3 + 1) begin
            sum_l2_tmp[idx3] = sum_l1_tmp[idx3*2] + sum_l1_tmp[idx3*2+1];
        end
        sum_l2_tmp[ACC_L2_TERMS-1] = sum_l1_tmp[ACC_L1_TERMS-1];

        for (idx3 = 0; idx3 < (ACC_L3_TERMS-1); idx3 = idx3 + 1) begin
            sum_l3_tmp[idx3] = sum_l2_tmp[idx3*2] + sum_l2_tmp[idx3*2+1];
        end
        sum_l3_tmp[ACC_L3_TERMS-1] = sum_l2_tmp[ACC_L2_TERMS-1];

        sum_l4_tmp[0] = sum_l3_tmp[0] + sum_l3_tmp[1];
        sum_l4_tmp[1] = sum_l3_tmp[2];

        sum_final_tmp = sum_l4_tmp[0] + sum_l4_tmp[1];
        s3_d.sum_sign = sum_final_tmp[SUM_W-1];
        s3_d.sum_abs  = sum_final_tmp[SUM_W-1] ? $unsigned(-sum_final_tmp)
                                               : $unsigned(sum_final_tmp);
    end

    always_comb begin
        s4_d = '0;
        s4_d.result = (s3_q.special_code != SPECIAL_NONE) ? pack_special_fp32(s3_q.special_code)
                                                          : pack_fp32_rz(s3_q.sum_sign,
                                                                        s3_q.sum_abs,
                                                                        s3_q.base_exp);
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
