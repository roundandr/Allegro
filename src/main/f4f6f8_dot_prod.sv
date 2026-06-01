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
    input  logic [2:0]   a_type_i,
    input  logic [2:0]   b_type_i,
    input  logic         mxfp8_en_i,
    input  logic [7:0]   a_mx_scale_i,
    input  logic [7:0]   b_mx_scale_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);

    localparam int FP8_W            = 8;
    localparam int FP6_W            = 6;
    localparam int FP4_W            = 4;
    localparam int NUM_ELEMS        = 32;
    localparam int FP8_SIG_W        = 4;
    localparam int PROD_SIG_W       = 8;
    localparam int C_SIG_W          = 24;
    localparam int MX_SCALE_W       = 8;
    localparam int PROD_EMAX_PARTS  = 8;
    localparam int LANE_EXP_W       = 5;
    localparam int PROD_EXP_W       = 6;
    localparam int FULL_EXP_W       = 10;
    localparam int ALIGN_FRAC_BITS  = 25;
    localparam int ALIGN_TERM_W     = 28;
    localparam int SUM_W            = 33;
    localparam int ACC_PARTIALS     = 5;
    localparam int PROD_SIG_FRAC_BITS = 6;
    localparam int C_SIG_FRAC_BITS    = 23;
    localparam int PROD_ALIGN_PAD_W   = ALIGN_FRAC_BITS - PROD_SIG_FRAC_BITS;
    localparam int C_ALIGN_PAD_W      = ALIGN_FRAC_BITS - C_SIG_FRAC_BITS;
    localparam logic signed [FULL_EXP_W-1:0] ALIGN_FRAC_BITS_EXP = 10'sd25;
    localparam logic signed [FULL_EXP_W-1:0] MX_SCALE_BIAS_EXP   = 10'sd127;
    localparam logic signed [LANE_EXP_W-1:0] FP6_E2M3_BIAS_EXP   = 5'sd1;
    localparam logic signed [LANE_EXP_W-1:0] FP6_E3M2_BIAS_EXP   = 5'sd3;
    localparam logic signed [FULL_EXP_W:0]   ALIGN_TERM_M1_EXP   = 11'sd27;

    localparam logic FP6_FORMAT_E2M3 = 1'b0;
    localparam logic FP6_FORMAT_E3M2 = 1'b1;
    localparam logic [2:0] F4F6F8_TYPE_E4M3 = 3'd0;
    localparam logic [2:0] F4F6F8_TYPE_E5M2 = 3'd1;
    localparam logic [2:0] F4F6F8_TYPE_E2M3 = 3'd2;
    localparam logic [2:0] F4F6F8_TYPE_E3M2 = 3'd3;
    localparam logic [2:0] F4F6F8_TYPE_E2M1 = 3'd4;

    typedef struct packed {
        logic                      sign;
        logic [FP8_SIG_W-1:0]      sig;
        logic signed [LANE_EXP_W-1:0] exp;
        logic                      is_zero;
        logic                      is_inf;
        logic                      is_nan;
    } fp8_dec_t;

    typedef struct packed {
        logic                      sign;
        logic [C_SIG_W-1:0]        sig;
        logic signed [FULL_EXP_W-1:0] exp;
        logic                      is_zero;
        logic                      is_inf;
        logic                      is_nan;
    } fp32_dec_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS-1:0]           prod_sign_flat;
        logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0] prod_mag_flat;
        logic [NUM_ELEMS*PROD_EXP_W-1:0] prod_exp_flat;
        logic [NUM_ELEMS-1:0]           prod_zero_flat;
        logic [PROD_EMAX_PARTS-1:0]     prod_emax_part_vld_flat;
        logic [PROD_EMAX_PARTS*FULL_EXP_W-1:0] prod_emax_part_exp_flat;
        logic                           c_sign;
        logic [ALIGN_TERM_W-2:0]        c_mag;
        logic signed [FULL_EXP_W-1:0]   c_exp;
        logic                           c_zero;
        logic signed [FULL_EXP_W-1:0]   mx_scale_exp_sum;
    } stage0_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS-1:0]           prod_sign_flat;
        logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0] prod_mag_flat;
        logic [NUM_ELEMS*PROD_EXP_W-1:0] prod_exp_flat;
        logic [NUM_ELEMS-1:0]           prod_zero_flat;
        logic                           c_sign;
        logic [ALIGN_TERM_W-2:0]        c_mag;
        logic signed [FULL_EXP_W-1:0]   c_exp_prod_domain;
        logic                           c_zero;
        logic signed [FULL_EXP_W-1:0]   mx_scale_exp_sum;
        logic signed [FULL_EXP_W-1:0]   emax;
        logic                           emax_vld;
    } stage1_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [NUM_ELEMS*ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [ALIGN_TERM_W-1:0]    c_aligned;
        logic signed [FULL_EXP_W-1:0]   base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic [ACC_PARTIALS*SUM_W-1:0]  partial_sum_flat;
        logic signed [FULL_EXP_W-1:0]   base_exp;
    } stage3_data_t;

    typedef struct packed {
        logic                           special_vld;
        logic [31:0]                    special_result;
        logic signed [SUM_W-1:0]        sum;
        logic signed [FULL_EXP_W-1:0]   base_exp;
    } stage4_data_t;

    typedef struct packed {
        logic [31:0] result;
    } stage5_data_t;

    stage0_data_t s0_d;
    stage1_data_t s1_d;
    stage2_data_t s2_d;
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

    logic [NUM_ELEMS-1:0]                    s0_prod_sign_flat_tmp;
    logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0]   s0_prod_mag_flat_tmp;
    logic [NUM_ELEMS*PROD_EXP_W-1:0]         s0_prod_exp_flat_tmp;
    logic [NUM_ELEMS-1:0]                    s0_prod_zero_flat_tmp;
    logic [PROD_EMAX_PARTS-1:0]              s0_prod_emax_part_vld_flat_tmp;
    logic [PROD_EMAX_PARTS*FULL_EXP_W-1:0]   s0_prod_emax_part_exp_flat_tmp;

    logic [PROD_EMAX_PARTS-1:0]              s0_prod_emax_part_vld_q_flat;
    logic [PROD_EMAX_PARTS*FULL_EXP_W-1:0]   s0_prod_emax_part_exp_q_flat;

    logic [NUM_ELEMS-1:0]                    s1_prod_sign_q_flat;
    logic [NUM_ELEMS*(ALIGN_TERM_W-1)-1:0]   s1_prod_mag_q_flat;
    logic [NUM_ELEMS*PROD_EXP_W-1:0]         s1_prod_exp_q_flat;
    logic [NUM_ELEMS-1:0]                    s1_prod_zero_q_flat;

    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_flat_tmp;
    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s2_aligned_prod_q_flat;
    logic [ACC_PARTIALS*SUM_W-1:0]     s3_partial_sum_flat_tmp;
    logic [ACC_PARTIALS*SUM_W-1:0]     s3_partial_sum_q_flat;

    assign s0_prod_emax_part_vld_q_flat = s0_q.prod_emax_part_vld_flat;
    assign s0_prod_emax_part_exp_q_flat = s0_q.prod_emax_part_exp_flat;
    assign s1_prod_sign_q_flat = s1_q.prod_sign_flat;
    assign s1_prod_mag_q_flat  = s1_q.prod_mag_flat;
    assign s1_prod_exp_q_flat  = s1_q.prod_exp_flat;
    assign s1_prod_zero_q_flat = s1_q.prod_zero_flat;
    assign s2_aligned_prod_q_flat = s2_q.aligned_prod_flat;
    assign s3_partial_sum_q_flat  = s3_q.partial_sum_flat;

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
        input logic [FP6_W-1:0] fp6_i,
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

            if (fp6_format_i == FP6_FORMAT_E3M2) begin
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
                    dec.exp = $signed({2'd0, exp_e3m2}) - FP6_E3M2_BIAS_EXP;
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
                    dec.exp = $signed({3'd0, exp_e2m3}) - FP6_E2M3_BIAS_EXP;
                end
            end

            return dec;
        end
    endfunction

    function automatic fp8_dec_t decode_e2m1(
        input logic [FP4_W-1:0] fp4_i
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

    function automatic logic signed [ALIGN_TERM_W-1:0] align_fixed_rz(
        input logic                      term_vld_i,
        input logic                      term_sign_i,
        input logic [ALIGN_TERM_W-2:0]   term_mag_i,
        input logic signed [FULL_EXP_W-1:0] term_exp_i,
        input logic signed [FULL_EXP_W-1:0] emax_i
    );
        logic [ALIGN_TERM_W-2:0] term_mag_shift;
        logic signed [ALIGN_TERM_W-1:0] aligned_val;
        logic signed [FULL_EXP_W:0] align_shift;
        integer shift_i;
        begin
            if (!term_vld_i) begin
                align_fixed_rz = '0;
            end else begin
                align_shift = $signed({emax_i[FULL_EXP_W-1], emax_i})
                            - $signed({term_exp_i[FULL_EXP_W-1], term_exp_i});
                if (align_shift <= 0) begin
                    term_mag_shift = term_mag_i;
                end else if (align_shift >= ALIGN_TERM_M1_EXP) begin
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
        input logic signed [FULL_EXP_W-1:0] base_exp_i
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
                for (idx = 0; idx < SUM_W; idx = idx + 1) begin
                    if (abs_sum[idx]) begin
                        msb_idx = idx;
                    end
                end

                unbiased_exp = $signed({{(32-FULL_EXP_W){base_exp_i[FULL_EXP_W-1]}}, base_exp_i}) + msb_idx;
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

    function automatic logic emax_pick_vld(
        input logic a_vld_i,
        input logic b_vld_i
    );
        begin
            emax_pick_vld = a_vld_i | b_vld_i;
        end
    endfunction

    function automatic logic signed [FULL_EXP_W-1:0] emax_pick_exp(
        input logic                         a_vld_i,
        input logic signed [FULL_EXP_W-1:0] a_exp_i,
        input logic                         b_vld_i,
        input logic signed [FULL_EXP_W-1:0] b_exp_i
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
    logic signed [FULL_EXP_W-1:0] mx_scale_exp_sum_tmp;
    logic signed [PROD_EXP_W-1:0] lane_prod_exp_tmp;
    logic                                  s0_emax_l0_vld_tmp [0:31];
    logic signed [FULL_EXP_W-1:0]          s0_emax_l0_exp_tmp [0:31];
    logic                                  s0_emax_l1_vld_tmp [0:15];
    logic signed [FULL_EXP_W-1:0]          s0_emax_l1_exp_tmp [0:15];
    logic                                  s0_emax_l2_vld_tmp [0:PROD_EMAX_PARTS-1];
    logic signed [FULL_EXP_W-1:0]          s0_emax_l2_exp_tmp [0:PROD_EMAX_PARTS-1];

    always @(*) begin
        s0_d = '0;
        s0_prod_sign_flat_tmp = '0;
        s0_prod_mag_flat_tmp  = '0;
        s0_prod_exp_flat_tmp  = '0;
        s0_prod_zero_flat_tmp = '0;
        s0_prod_emax_part_vld_flat_tmp = '0;
        s0_prod_emax_part_exp_flat_tmp = '0;

        c_dec_tmp            = decode_fp32(c_i);
        mx_scale_nan_tmp     = mxfp8_en_i && ((a_mx_scale_i == 8'hff) || (b_mx_scale_i == 8'hff));
        mx_scale_exp_sum_tmp = mxfp8_en_i
                             ? ($signed({{(FULL_EXP_W-MX_SCALE_W){1'b0}}, a_mx_scale_i})
                              + $signed({{(FULL_EXP_W-MX_SCALE_W){1'b0}}, b_mx_scale_i})
                              - (MX_SCALE_BIAS_EXP + MX_SCALE_BIAS_EXP))
                             : '0;
        any_nan_tmp          = c_dec_tmp.is_nan | mx_scale_nan_tmp;
        has_pos_inf_tmp      = c_dec_tmp.is_inf && !c_dec_tmp.sign;
        has_neg_inf_tmp      = c_dec_tmp.is_inf && c_dec_tmp.sign;
        has_zero_mul_inf_tmp = 1'b0;
        lane_prod_sig_tmp    = '0;
        lane_prod_mag_tmp    = '0;
        lane_prod_exp_tmp    = '0;

        s0_d.c_sign = c_dec_tmp.sign;
        s0_d.c_exp  = c_dec_tmp.exp;
        s0_d.c_zero = c_dec_tmp.is_zero;
        s0_d.mx_scale_exp_sum = mx_scale_exp_sum_tmp;
        c_mag_tmp_s0 = {{(ALIGN_TERM_W-1-C_SIG_W-C_ALIGN_PAD_W){1'b0}},
                        c_dec_tmp.sig,
                        {C_ALIGN_PAD_W{1'b0}}};
        s0_d.c_mag = c_mag_tmp_s0;

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            case (a_type_i)
                F4F6F8_TYPE_E4M3: begin
                    a_dec_tmp = decode_fp8(a_vec_i[idx0*FP8_W +: FP8_W], 1'b0);
                end
                F4F6F8_TYPE_E5M2: begin
                    a_dec_tmp = decode_fp8(a_vec_i[idx0*FP8_W +: FP8_W], 1'b1);
                end
                F4F6F8_TYPE_E2M3: begin
                    a_dec_tmp = decode_fp6(a_vec_i[idx0*FP6_W +: FP6_W], FP6_FORMAT_E2M3);
                end
                F4F6F8_TYPE_E3M2: begin
                    a_dec_tmp = decode_fp6(a_vec_i[idx0*FP6_W +: FP6_W], FP6_FORMAT_E3M2);
                end
                F4F6F8_TYPE_E2M1: begin
                    a_dec_tmp = decode_e2m1(a_vec_i[idx0*FP4_W +: FP4_W]);
                end
                default: begin
                    a_dec_tmp = decode_fp8(a_vec_i[idx0*FP8_W +: FP8_W], 1'b0);
                end
            endcase

            case (b_type_i)
                F4F6F8_TYPE_E4M3: begin
                    b_dec_tmp = decode_fp8(b_vec_i[idx0*FP8_W +: FP8_W], 1'b0);
                end
                F4F6F8_TYPE_E5M2: begin
                    b_dec_tmp = decode_fp8(b_vec_i[idx0*FP8_W +: FP8_W], 1'b1);
                end
                F4F6F8_TYPE_E2M3: begin
                    b_dec_tmp = decode_fp6(b_vec_i[idx0*FP6_W +: FP6_W], FP6_FORMAT_E2M3);
                end
                F4F6F8_TYPE_E3M2: begin
                    b_dec_tmp = decode_fp6(b_vec_i[idx0*FP6_W +: FP6_W], FP6_FORMAT_E3M2);
                end
                F4F6F8_TYPE_E2M1: begin
                    b_dec_tmp = decode_e2m1(b_vec_i[idx0*FP4_W +: FP4_W]);
                end
                default: begin
                    b_dec_tmp = decode_fp8(b_vec_i[idx0*FP8_W +: FP8_W], 1'b0);
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
                s0_prod_mag_flat_tmp[idx0*(ALIGN_TERM_W-1) +: (ALIGN_TERM_W-1)] = '0;
                s0_prod_exp_flat_tmp[idx0*PROD_EXP_W +: PROD_EXP_W] = '0;
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
                    s0_prod_exp_flat_tmp[idx0*PROD_EXP_W +: PROD_EXP_W] = '0;
                end else begin
                    lane_prod_exp_tmp = $signed({a_dec_tmp.exp[LANE_EXP_W-1], a_dec_tmp.exp})
                                      + $signed({b_dec_tmp.exp[LANE_EXP_W-1], b_dec_tmp.exp});
                    s0_prod_exp_flat_tmp[idx0*PROD_EXP_W +: PROD_EXP_W] = lane_prod_exp_tmp;
                end
            end
        end

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            s0_emax_l0_vld_tmp[idx0] = !s0_prod_zero_flat_tmp[idx0];
            s0_emax_l0_exp_tmp[idx0] =
                $signed({{(FULL_EXP_W-PROD_EXP_W){s0_prod_exp_flat_tmp[idx0*PROD_EXP_W+PROD_EXP_W-1]}},
                         s0_prod_exp_flat_tmp[idx0*PROD_EXP_W +: PROD_EXP_W]});
        end

        for (idx0 = 0; idx0 < 16; idx0 = idx0 + 1) begin
            s0_emax_l1_vld_tmp[idx0] = emax_pick_vld(s0_emax_l0_vld_tmp[idx0*2],
                                                      s0_emax_l0_vld_tmp[idx0*2+1]);
            s0_emax_l1_exp_tmp[idx0] = emax_pick_exp(s0_emax_l0_vld_tmp[idx0*2],
                                                      s0_emax_l0_exp_tmp[idx0*2],
                                                      s0_emax_l0_vld_tmp[idx0*2+1],
                                                      s0_emax_l0_exp_tmp[idx0*2+1]);
        end

        for (idx0 = 0; idx0 < PROD_EMAX_PARTS; idx0 = idx0 + 1) begin
            s0_emax_l2_vld_tmp[idx0] = emax_pick_vld(s0_emax_l1_vld_tmp[idx0*2],
                                                      s0_emax_l1_vld_tmp[idx0*2+1]);
            s0_emax_l2_exp_tmp[idx0] = emax_pick_exp(s0_emax_l1_vld_tmp[idx0*2],
                                                      s0_emax_l1_exp_tmp[idx0*2],
                                                      s0_emax_l1_vld_tmp[idx0*2+1],
                                                      s0_emax_l1_exp_tmp[idx0*2+1]);
            s0_prod_emax_part_vld_flat_tmp[idx0] = s0_emax_l2_vld_tmp[idx0];
            s0_prod_emax_part_exp_flat_tmp[idx0*FULL_EXP_W +: FULL_EXP_W] = s0_emax_l2_exp_tmp[idx0];
        end

        s0_d.prod_sign_flat = s0_prod_sign_flat_tmp;
        s0_d.prod_mag_flat  = s0_prod_mag_flat_tmp;
        s0_d.prod_exp_flat  = s0_prod_exp_flat_tmp;
        s0_d.prod_zero_flat = s0_prod_zero_flat_tmp;
        s0_d.prod_emax_part_vld_flat = s0_prod_emax_part_vld_flat_tmp;
        s0_d.prod_emax_part_exp_flat = s0_prod_emax_part_exp_flat_tmp;

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
    logic                                  s1_emax_l0_vld_tmp [0:PROD_EMAX_PARTS];
    logic signed [FULL_EXP_W-1:0]          s1_emax_l0_exp_tmp [0:PROD_EMAX_PARTS];
    logic                                  s1_emax_l1_vld_tmp [0:4];
    logic signed [FULL_EXP_W-1:0]          s1_emax_l1_exp_tmp [0:4];
    logic                                  s1_emax_l2_vld_tmp [0:2];
    logic signed [FULL_EXP_W-1:0]          s1_emax_l2_exp_tmp [0:2];
    logic                                  s1_emax_l3_vld_tmp [0:1];
    logic signed [FULL_EXP_W-1:0]          s1_emax_l3_exp_tmp [0:1];
    logic                                  emax_result_vld_tmp;
    logic signed [FULL_EXP_W-1:0]          emax_result_exp_tmp;
    logic signed [FULL_EXP_W-1:0]          c_exp_prod_domain_tmp;

    always @(*) begin
        s1_d = '0;
        emax_result_vld_tmp  = 1'b0;
        emax_result_exp_tmp  = '0;

        s1_d.special_vld    = s0_q.special_vld;
        s1_d.special_result = s0_q.special_result;
        s1_d.prod_sign_flat = s0_q.prod_sign_flat;
        s1_d.prod_mag_flat  = s0_q.prod_mag_flat;
        s1_d.prod_exp_flat  = s0_q.prod_exp_flat;
        s1_d.prod_zero_flat = s0_q.prod_zero_flat;
        s1_d.c_sign         = s0_q.c_sign;
        s1_d.c_mag          = s0_q.c_mag;
        s1_d.c_zero         = s0_q.c_zero;
        s1_d.mx_scale_exp_sum = s0_q.mx_scale_exp_sum;

        c_exp_prod_domain_tmp = s0_q.c_exp - s0_q.mx_scale_exp_sum;
        s1_d.c_exp_prod_domain = c_exp_prod_domain_tmp;

        for (idx1 = 0; idx1 < PROD_EMAX_PARTS; idx1 = idx1 + 1) begin
            s1_emax_l0_vld_tmp[idx1] = s0_prod_emax_part_vld_q_flat[idx1];
            s1_emax_l0_exp_tmp[idx1] =
                $signed(s0_prod_emax_part_exp_q_flat[idx1*FULL_EXP_W +: FULL_EXP_W]);
        end

        s1_emax_l0_vld_tmp[PROD_EMAX_PARTS] = !s0_q.c_zero;
        s1_emax_l0_exp_tmp[PROD_EMAX_PARTS] = c_exp_prod_domain_tmp;

        for (idx1 = 0; idx1 < 4; idx1 = idx1 + 1) begin
            s1_emax_l1_vld_tmp[idx1] = emax_pick_vld(s1_emax_l0_vld_tmp[idx1*2],
                                                      s1_emax_l0_vld_tmp[idx1*2+1]);
            s1_emax_l1_exp_tmp[idx1] = emax_pick_exp(s1_emax_l0_vld_tmp[idx1*2],
                                                      s1_emax_l0_exp_tmp[idx1*2],
                                                      s1_emax_l0_vld_tmp[idx1*2+1],
                                                      s1_emax_l0_exp_tmp[idx1*2+1]);
        end
        s1_emax_l1_vld_tmp[4] = s1_emax_l0_vld_tmp[PROD_EMAX_PARTS];
        s1_emax_l1_exp_tmp[4] = s1_emax_l0_exp_tmp[PROD_EMAX_PARTS];

        for (idx1 = 0; idx1 < 2; idx1 = idx1 + 1) begin
            s1_emax_l2_vld_tmp[idx1] = emax_pick_vld(s1_emax_l1_vld_tmp[idx1*2],
                                                      s1_emax_l1_vld_tmp[idx1*2+1]);
            s1_emax_l2_exp_tmp[idx1] = emax_pick_exp(s1_emax_l1_vld_tmp[idx1*2],
                                                      s1_emax_l1_exp_tmp[idx1*2],
                                                      s1_emax_l1_vld_tmp[idx1*2+1],
                                                      s1_emax_l1_exp_tmp[idx1*2+1]);
        end
        s1_emax_l2_vld_tmp[2] = s1_emax_l1_vld_tmp[4];
        s1_emax_l2_exp_tmp[2] = s1_emax_l1_exp_tmp[4];

        s1_emax_l3_vld_tmp[0] = emax_pick_vld(s1_emax_l2_vld_tmp[0],
                                               s1_emax_l2_vld_tmp[1]);
        s1_emax_l3_exp_tmp[0] = emax_pick_exp(s1_emax_l2_vld_tmp[0],
                                               s1_emax_l2_exp_tmp[0],
                                               s1_emax_l2_vld_tmp[1],
                                               s1_emax_l2_exp_tmp[1]);
        s1_emax_l3_vld_tmp[1] = s1_emax_l2_vld_tmp[2];
        s1_emax_l3_exp_tmp[1] = s1_emax_l2_exp_tmp[2];

        emax_result_vld_tmp = emax_pick_vld(s1_emax_l3_vld_tmp[0],
                                            s1_emax_l3_vld_tmp[1]);
        emax_result_exp_tmp = emax_pick_exp(s1_emax_l3_vld_tmp[0],
                                            s1_emax_l3_exp_tmp[0],
                                            s1_emax_l3_vld_tmp[1],
                                            s1_emax_l3_exp_tmp[1]);

        s1_d.emax          = emax_result_exp_tmp;
        s1_d.emax_vld      = emax_result_vld_tmp;
    end

    integer idx2;
    logic signed [FULL_EXP_W-1:0] prod_exp_s2_tmp;

    always @(*) begin
        s2_d = '0;
        s2_aligned_prod_flat_tmp = '0;
        prod_exp_s2_tmp = '0;
        s2_d.special_vld    = s1_q.special_vld;
        s2_d.special_result = s1_q.special_result;

        if (s1_q.emax_vld) begin
            s2_d.base_exp = s1_q.emax + s1_q.mx_scale_exp_sum - ALIGN_FRAC_BITS_EXP;

            for (idx2 = 0; idx2 < NUM_ELEMS; idx2 = idx2 + 1) begin
                prod_exp_s2_tmp =
                    $signed({{(FULL_EXP_W-PROD_EXP_W){s1_prod_exp_q_flat[idx2*PROD_EXP_W+PROD_EXP_W-1]}},
                             s1_prod_exp_q_flat[idx2*PROD_EXP_W +: PROD_EXP_W]});
                s2_aligned_prod_flat_tmp[idx2*ALIGN_TERM_W +: ALIGN_TERM_W] =
                    align_fixed_rz(!s1_prod_zero_q_flat[idx2],
                                   s1_prod_sign_q_flat[idx2],
                                   s1_prod_mag_q_flat[idx2*(ALIGN_TERM_W-1) +: (ALIGN_TERM_W-1)],
                                   prod_exp_s2_tmp, s1_q.emax);
            end

            s2_d.c_aligned = align_fixed_rz(!s1_q.c_zero,
                                            s1_q.c_sign,
                                            s1_q.c_mag,
                                            s1_q.c_exp_prod_domain,
                                            s1_q.emax);
        end else begin
            s2_d.base_exp = '0;
            s2_d.c_aligned = '0;
        end

        s2_d.aligned_prod_flat = s2_aligned_prod_flat_tmp;
    end

    function automatic logic signed [SUM_W-1:0] extend_align_term(
        input logic signed [ALIGN_TERM_W-1:0] term_i
    );
        begin
            extend_align_term = $signed({{(SUM_W-ALIGN_TERM_W){term_i[ALIGN_TERM_W-1]}}, term_i});
        end
    endfunction

    function automatic logic signed [SUM_W-1:0] sum8_terms(
        input logic signed [SUM_W-1:0] term0_i,
        input logic signed [SUM_W-1:0] term1_i,
        input logic signed [SUM_W-1:0] term2_i,
        input logic signed [SUM_W-1:0] term3_i,
        input logic signed [SUM_W-1:0] term4_i,
        input logic signed [SUM_W-1:0] term5_i,
        input logic signed [SUM_W-1:0] term6_i,
        input logic signed [SUM_W-1:0] term7_i
    );
        logic signed [SUM_W-1:0] sum_l1_0;
        logic signed [SUM_W-1:0] sum_l1_1;
        logic signed [SUM_W-1:0] sum_l1_2;
        logic signed [SUM_W-1:0] sum_l1_3;
        logic signed [SUM_W-1:0] sum_l2_0;
        logic signed [SUM_W-1:0] sum_l2_1;
        begin
            sum_l1_0  = term0_i + term1_i;
            sum_l1_1  = term2_i + term3_i;
            sum_l1_2  = term4_i + term5_i;
            sum_l1_3  = term6_i + term7_i;
            sum_l2_0  = sum_l1_0 + sum_l1_1;
            sum_l2_1  = sum_l1_2 + sum_l1_3;
            sum8_terms = sum_l2_0 + sum_l2_1;
        end
    endfunction

    integer idx3;
    logic signed [SUM_W-1:0] s3_term_tmp        [0:NUM_ELEMS];
    logic signed [SUM_W-1:0] s3_partial_sum_tmp [0:ACC_PARTIALS-1];
    logic signed [SUM_W-1:0] s4_partial_sum_tmp [0:ACC_PARTIALS-1];
    logic signed [SUM_W-1:0] s4_sum01_tmp;
    logic signed [SUM_W-1:0] s4_sum23_tmp;

    always @(*) begin
        s3_d = '0;
        s3_partial_sum_flat_tmp = '0;
        s3_d.special_vld    = s2_q.special_vld;
        s3_d.special_result = s2_q.special_result;
        s3_d.base_exp       = s2_q.base_exp;

        for (idx3 = 0; idx3 < NUM_ELEMS + 1; idx3 = idx3 + 1) begin
            s3_term_tmp[idx3] = '0;
        end
        for (idx3 = 0; idx3 < ACC_PARTIALS; idx3 = idx3 + 1) begin
            s3_partial_sum_tmp[idx3] = '0;
        end

        s3_term_tmp[0] = extend_align_term(s2_q.c_aligned);
        for (idx3 = 0; idx3 < NUM_ELEMS; idx3 = idx3 + 1) begin
            s3_term_tmp[idx3+1] =
                extend_align_term(s2_aligned_prod_q_flat[idx3*ALIGN_TERM_W +: ALIGN_TERM_W]);
        end

        s3_partial_sum_tmp[0] = sum8_terms(s3_term_tmp[0],  s3_term_tmp[1],
                                           s3_term_tmp[2],  s3_term_tmp[3],
                                           s3_term_tmp[4],  s3_term_tmp[5],
                                           s3_term_tmp[6],  s3_term_tmp[7]);
        s3_partial_sum_tmp[1] = sum8_terms(s3_term_tmp[8],  s3_term_tmp[9],
                                           s3_term_tmp[10], s3_term_tmp[11],
                                           s3_term_tmp[12], s3_term_tmp[13],
                                           s3_term_tmp[14], s3_term_tmp[15]);
        s3_partial_sum_tmp[2] = sum8_terms(s3_term_tmp[16], s3_term_tmp[17],
                                           s3_term_tmp[18], s3_term_tmp[19],
                                           s3_term_tmp[20], s3_term_tmp[21],
                                           s3_term_tmp[22], s3_term_tmp[23]);
        s3_partial_sum_tmp[3] = sum8_terms(s3_term_tmp[24], s3_term_tmp[25],
                                           s3_term_tmp[26], s3_term_tmp[27],
                                           s3_term_tmp[28], s3_term_tmp[29],
                                           s3_term_tmp[30], s3_term_tmp[31]);
        s3_partial_sum_tmp[4] = s3_term_tmp[32];

        s3_partial_sum_flat_tmp[0*SUM_W +: SUM_W] = s3_partial_sum_tmp[0];
        s3_partial_sum_flat_tmp[1*SUM_W +: SUM_W] = s3_partial_sum_tmp[1];
        s3_partial_sum_flat_tmp[2*SUM_W +: SUM_W] = s3_partial_sum_tmp[2];
        s3_partial_sum_flat_tmp[3*SUM_W +: SUM_W] = s3_partial_sum_tmp[3];
        s3_partial_sum_flat_tmp[4*SUM_W +: SUM_W] = s3_partial_sum_tmp[4];
        s3_d.partial_sum_flat = s3_partial_sum_flat_tmp;
    end

    always @(*) begin
        s4_d = '0;
        s4_sum01_tmp = '0;
        s4_sum23_tmp = '0;
        s4_partial_sum_tmp[0] = $signed(s3_partial_sum_q_flat[0*SUM_W +: SUM_W]);
        s4_partial_sum_tmp[1] = $signed(s3_partial_sum_q_flat[1*SUM_W +: SUM_W]);
        s4_partial_sum_tmp[2] = $signed(s3_partial_sum_q_flat[2*SUM_W +: SUM_W]);
        s4_partial_sum_tmp[3] = $signed(s3_partial_sum_q_flat[3*SUM_W +: SUM_W]);
        s4_partial_sum_tmp[4] = $signed(s3_partial_sum_q_flat[4*SUM_W +: SUM_W]);

        s4_d.special_vld    = s3_q.special_vld;
        s4_d.special_result = s3_q.special_result;
        s4_d.base_exp       = s3_q.base_exp;

        s4_sum01_tmp = s4_partial_sum_tmp[0] + s4_partial_sum_tmp[1];
        s4_sum23_tmp = s4_partial_sum_tmp[2] + s4_partial_sum_tmp[3];
        s4_d.sum     = (s4_sum01_tmp + s4_sum23_tmp) + s4_partial_sum_tmp[4];
    end

    always @(*) begin
        s5_d = '0;
        if (s4_q.special_vld) begin
            s5_d.result = s4_q.special_result;
        end else begin
            s5_d.result = pack_fp32_rz(s4_q.sum, s4_q.base_exp);
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
