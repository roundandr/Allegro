// ============================================================================
// File Name   : fp4_dot_prod.sv
// Author      : Codex
// Date        : 2026-04-22
// Description : 64-element NVFP4 dot-product with UE4M3 block scaling and
//               FP32 accumulate. The datapath follows the 5-stage pipeline
//               defined in doc/FP4_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-22  v0.1      Codex       Initial version
// ============================================================================

module fp4_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [255:0] a_fp4_i,
    input  logic [255:0] b_fp4_i,
    input  logic [31:0]  a_sf_i,
    input  logic [31:0]  b_sf_i,
    input  logic [31:0]  c_fp32_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_fp32_o
);

    localparam int FP4_W         = 4;
    localparam int NUM_ELEMS      = 64;
    localparam int BLOCK_SIZE     = 16;
    localparam int NUM_BLOCKS     = 4;
    localparam int SCALE_W        = 8;
    localparam int FP4_PROD_W     = 9;
    localparam int SIGMA_W        = 13;
    localparam int SF_SIG_W       = 4;
    localparam int SF_EXP_W       = 5;
    localparam int SF_SIG_PROD_W  = 8;
    localparam int SF_EXP_SUM_W   = 6;
    localparam int GAMMA_SIG_W    = 20;
    localparam int GAMMA_EXP_W    = 6;
    localparam int C_SIG_W        = 24;
    localparam int C_EXP_W        = 9;
    localparam int ACC_FRAC_BITS  = 35;
    localparam int ALIGN_W        = C_SIG_W + ACC_FRAC_BITS;
    localparam int SUM_W          = ALIGN_W + 3;
    localparam logic signed [C_EXP_W-1:0] ACC_FRAC_BITS_EXP = ACC_FRAC_BITS;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic [NUM_ELEMS*FP4_PROD_W-1:0] prod_flat;
        logic [NUM_BLOCKS*SF_SIG_W-1:0]  a_sf_sig_flat;
        logic [NUM_BLOCKS*SF_SIG_W-1:0]  b_sf_sig_flat;
        logic [NUM_BLOCKS*SF_EXP_W-1:0]  a_sf_exp_flat;
        logic [NUM_BLOCKS*SF_EXP_W-1:0]  b_sf_exp_flat;
        logic                    c_sign;
        logic [C_SIG_W-1:0]      c_sig;
        logic signed [C_EXP_W-1:0] c_exp;
    } stage0_data_t;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic [NUM_BLOCKS*SIGMA_W-1:0]       sigma_flat;
        logic [NUM_BLOCKS*SF_SIG_PROD_W-1:0] sf_sig_prod_flat;
        logic [NUM_BLOCKS*SF_EXP_SUM_W-1:0]  sf_exp_sum_flat;
        logic                    c_sign;
        logic [C_SIG_W-1:0]      c_sig;
        logic signed [C_EXP_W-1:0] c_exp;
    } stage1_data_t;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic [NUM_BLOCKS*ALIGN_W-1:0] gamma_aligned_flat;
        logic signed [ALIGN_W-1:0] c_aligned;
        logic signed [C_EXP_W-1:0] emax;
    } stage2_data_t;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic signed [SUM_W-1:0] sum;
        logic signed [C_EXP_W-1:0] base_exp;
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

    logic s0_rdy;
    logic s1_rdy;
    logic s2_rdy;
    logic s3_rdy;
    logic s4_rdy;

    logic [NUM_ELEMS*FP4_PROD_W-1:0] s0_prod_flat_tmp;
    logic [NUM_BLOCKS*SF_SIG_W-1:0]  s0_a_sf_sig_flat_tmp;
    logic [NUM_BLOCKS*SF_SIG_W-1:0]  s0_b_sf_sig_flat_tmp;
    logic [NUM_BLOCKS*SF_EXP_W-1:0]  s0_a_sf_exp_flat_tmp;
    logic [NUM_BLOCKS*SF_EXP_W-1:0]  s0_b_sf_exp_flat_tmp;

    logic [NUM_ELEMS*FP4_PROD_W-1:0] s0_prod_flat_hold;
    logic [NUM_BLOCKS*SF_SIG_W-1:0]  s0_a_sf_sig_flat_hold;
    logic [NUM_BLOCKS*SF_SIG_W-1:0]  s0_b_sf_sig_flat_hold;
    logic [NUM_BLOCKS*SF_EXP_W-1:0]  s0_a_sf_exp_flat_hold;
    logic [NUM_BLOCKS*SF_EXP_W-1:0]  s0_b_sf_exp_flat_hold;

    logic [NUM_BLOCKS*SIGMA_W-1:0]       s1_sigma_flat_tmp;
    logic [NUM_BLOCKS*SF_SIG_PROD_W-1:0] s1_sf_sig_prod_flat_tmp;
    logic [NUM_BLOCKS*SF_EXP_SUM_W-1:0]  s1_sf_exp_sum_flat_tmp;

    logic [NUM_BLOCKS*SIGMA_W-1:0]       s1_sigma_flat_hold;
    logic [NUM_BLOCKS*SF_SIG_PROD_W-1:0] s1_sf_sig_prod_flat_hold;
    logic [NUM_BLOCKS*SF_EXP_SUM_W-1:0]  s1_sf_exp_sum_flat_hold;

    logic [NUM_BLOCKS*ALIGN_W-1:0] s2_gamma_aligned_flat_tmp;
    logic [NUM_BLOCKS*ALIGN_W-1:0] s2_gamma_aligned_flat_hold;

    assign s0_prod_flat_hold     = s0_q.prod_flat;
    assign s0_a_sf_sig_flat_hold = s0_q.a_sf_sig_flat;
    assign s0_b_sf_sig_flat_hold = s0_q.b_sf_sig_flat;
    assign s0_a_sf_exp_flat_hold = s0_q.a_sf_exp_flat;
    assign s0_b_sf_exp_flat_hold = s0_q.b_sf_exp_flat;
    assign s1_sigma_flat_hold       = s1_q.sigma_flat;
    assign s1_sf_sig_prod_flat_hold = s1_q.sf_sig_prod_flat;
    assign s1_sf_exp_sum_flat_hold  = s1_q.sf_exp_sum_flat;
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

    function automatic logic signed [FP4_PROD_W-1:0] fp4_product(
        input logic [FP4_W-1:0] a_i,
        input logic [FP4_W-1:0] b_i
    );
        logic [3:0] a_mag2;
        logic [3:0] b_mag2;
        logic [7:0] prod_mag;
        logic       prod_sign;
        logic signed [FP4_PROD_W-1:0] prod_signed;
        begin
            a_mag2    = fp4_mag2(a_i[2:0]);
            b_mag2    = fp4_mag2(b_i[2:0]);
            prod_mag  = a_mag2 * b_mag2;
            prod_sign = a_i[3] ^ b_i[3];
            prod_signed = $signed({1'b0, prod_mag});
            fp4_product = prod_sign ? -prod_signed : prod_signed;
        end
    endfunction

    function automatic logic [10:0] decode_scale(input logic [SCALE_W-1:0] scale_i);
        logic [7:0] scale_eff;
        logic [3:0] exp_raw;
        logic [2:0] mant_raw;
        logic       is_nan;
        logic       is_zero;
        logic [3:0] sig;
        logic signed [SF_EXP_W-1:0] exp;
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
                exp = -5'sd9;
            end else begin
                sig = {1'b1, mant_raw};
                exp = $signed({1'b0, exp_raw}) - 5'sd10;
            end

            decode_scale = {is_nan, is_zero, sig, exp};
        end
    endfunction

    function automatic logic [36:0] decode_c(input logic [31:0] c_i);
        logic       sign;
        logic [7:0] exp_raw;
        logic [22:0] frac_raw;
        logic       is_zero;
        logic       is_nan;
        logic       is_inf;
        logic [23:0] sig;
        logic signed [C_EXP_W-1:0] exp;
        begin
            sign    = c_i[31];
            exp_raw = c_i[30:23];
            frac_raw = c_i[22:0];
            is_zero = (exp_raw == 8'h00) && (frac_raw == 23'h0);
            is_nan  = (exp_raw == 8'hff) && (frac_raw != 23'h0);
            is_inf  = (exp_raw == 8'hff) && (frac_raw == 23'h0);

            if (is_zero) begin
                sig = '0;
                exp = '0;
            end else if (exp_raw == 8'h00) begin
                sig = {1'b0, frac_raw};
                exp = -9'sd149;
            end else begin
                sig = {1'b1, frac_raw};
                exp = $signed({1'b0, exp_raw}) - 9'sd150;
            end

            decode_c = {sign, is_zero, is_nan, is_inf, sig, exp};
        end
    endfunction

    function automatic logic signed [ALIGN_W-1:0] align_fixed_rz(
        input logic signed [ALIGN_W-1:0] term_i,
        input integer shift_i
    );
        logic term_sign;
        logic [ALIGN_W-1:0] term_mag;
        logic [ALIGN_W-1:0] term_mag_shift;
        logic signed [ALIGN_W-1:0] aligned_val;
        begin
            term_sign = term_i[ALIGN_W-1];
            if (term_sign) begin
                term_mag = -term_i;
            end else begin
                term_mag = term_i;
            end

            if (shift_i >= 0) begin
                if (shift_i >= ALIGN_W) begin
                    term_mag_shift = '0;
                end else begin
                    term_mag_shift = term_mag << shift_i;
                end
            end else begin
                if ((-shift_i) >= ALIGN_W) begin
                    term_mag_shift = '0;
                end else begin
                    term_mag_shift = term_mag >> (-shift_i);
                end
            end

            aligned_val = $signed(term_mag_shift);
            align_fixed_rz = term_sign ? -aligned_val : aligned_val;
        end
    endfunction

    function automatic logic [31:0] pack_fp32_rz(
        input logic signed [SUM_W-1:0] sum_i,
        input logic signed [C_EXP_W-1:0] base_exp_i
    );
        logic        sign_bit;
        logic [SUM_W-1:0] abs_sum;
        logic [63:0] mag64;
        logic [63:0] sig64;
        logic [23:0] sig24;
        logic [22:0] frac_field;
        logic [7:0]  exp_field;
        integer      msb_idx;
        integer      unbiased_exp;
        integer      shift_sub;
        integer      i;
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
                mag64 = {{(64-SUM_W){1'b0}}, abs_sum};

                msb_idx = 0;
                for (i = SUM_W-1; i >= 0; i = i - 1) begin
                    if (mag64[i]) begin
                        msb_idx = i;
                        i = -1;
                    end
                end

                unbiased_exp = $signed({{(32-C_EXP_W){base_exp_i[C_EXP_W-1]}}, base_exp_i}) + msb_idx;

                if (msb_idx >= 23) begin
                    sig64 = mag64 >> (msb_idx - 23);
                end else begin
                    sig64 = mag64 << (23 - msb_idx);
                end

                sig24 = sig64[23:0];

                if (unbiased_exp > 127) begin
                    exp_field   = 8'hff;
                    frac_field  = 23'h0;
                end else if (unbiased_exp >= -126) begin
                    exp_field   = unbiased_exp + 127;
                    frac_field  = sig24[22:0];
                end else if (unbiased_exp < -149) begin
                    exp_field   = 8'h00;
                    frac_field  = 23'h0;
                end else begin
                    shift_sub   = -126 - unbiased_exp;
                    sig24       = sig24 >> shift_sub;
                    exp_field   = 8'h00;
                    frac_field  = sig24[22:0];
                end

                pack_fp32_rz = {sign_bit, exp_field, frac_field};
            end
        end
    endfunction

    integer idx0;
    integer g0;
    integer g1;
    integer g2;
    integer g3;
    integer g4;
    integer k1;
    logic [10:0] scale_dec_a;
    logic [10:0] scale_dec_b;
    logic [36:0] c_dec;
    logic        any_scale_nan;

    always_comb begin
        s0_d = '0;
        any_scale_nan = 1'b0;
        s0_prod_flat_tmp     = '0;
        s0_a_sf_sig_flat_tmp = '0;
        s0_b_sf_sig_flat_tmp = '0;
        s0_a_sf_exp_flat_tmp = '0;
        s0_b_sf_exp_flat_tmp = '0;

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            s0_prod_flat_tmp[idx0*FP4_PROD_W +: FP4_PROD_W] =
                fp4_product(a_fp4_i[idx0*FP4_W +: FP4_W], b_fp4_i[idx0*FP4_W +: FP4_W]);
        end

        for (g0 = 0; g0 < NUM_BLOCKS; g0 = g0 + 1) begin
            scale_dec_a = decode_scale(a_sf_i[g0*SCALE_W +: SCALE_W]);
            scale_dec_b = decode_scale(b_sf_i[g0*SCALE_W +: SCALE_W]);
            s0_a_sf_sig_flat_tmp[g0*SF_SIG_W +: SF_SIG_W] = scale_dec_a[8:5];
            s0_b_sf_sig_flat_tmp[g0*SF_SIG_W +: SF_SIG_W] = scale_dec_b[8:5];
            s0_a_sf_exp_flat_tmp[g0*SF_EXP_W +: SF_EXP_W] = scale_dec_a[4:0];
            s0_b_sf_exp_flat_tmp[g0*SF_EXP_W +: SF_EXP_W] = scale_dec_b[4:0];
            any_scale_nan = any_scale_nan | scale_dec_a[10] | scale_dec_b[10];
        end

        s0_d.prod_flat     = s0_prod_flat_tmp;
        s0_d.a_sf_sig_flat = s0_a_sf_sig_flat_tmp;
        s0_d.b_sf_sig_flat = s0_b_sf_sig_flat_tmp;
        s0_d.a_sf_exp_flat = s0_a_sf_exp_flat_tmp;
        s0_d.b_sf_exp_flat = s0_b_sf_exp_flat_tmp;

        c_dec         = decode_c(c_fp32_i);
        s0_d.c_sign   = c_dec[36];
        s0_d.c_sig    = c_dec[32:9];
        s0_d.c_exp    = $signed(c_dec[8:0]);

        if (any_scale_nan || c_dec[34]) begin
            s0_d.special_valid  = 1'b1;
            s0_d.special_result = 32'h7fff_ffff;
        end else if (c_dec[33]) begin
            s0_d.special_valid  = 1'b1;
            s0_d.special_result = c_fp32_i;
        end else begin
            s0_d.special_valid  = 1'b0;
            s0_d.special_result = 32'h0000_0000;
        end
    end

    logic signed [SIGMA_W-1:0] sigma_tmp;
    logic signed [15:0] sigma_acc;
    logic signed [SF_EXP_W-1:0] a_sf_exp_tmp;
    logic signed [SF_EXP_W-1:0] b_sf_exp_tmp;
    logic signed [FP4_PROD_W-1:0] prod_s0_tmp;

    always_comb begin
        s1_d = '0;
        s1_sigma_flat_tmp       = '0;
        s1_sf_sig_prod_flat_tmp = '0;
        s1_sf_exp_sum_flat_tmp  = '0;
        s1_d.special_valid  = s0_q.special_valid;
        s1_d.special_result = s0_q.special_result;
        s1_d.c_sign         = s0_q.c_sign;
        s1_d.c_sig          = s0_q.c_sig;
        s1_d.c_exp          = s0_q.c_exp;

        for (g1 = 0; g1 < NUM_BLOCKS; g1 = g1 + 1) begin
            sigma_acc = '0;
            for (k1 = 0; k1 < BLOCK_SIZE; k1 = k1 + 1) begin
                prod_s0_tmp = $signed(s0_prod_flat_hold[(g1*BLOCK_SIZE+k1)*FP4_PROD_W +: FP4_PROD_W]);
                sigma_acc = sigma_acc
                          + $signed({{(16-FP4_PROD_W){prod_s0_tmp[FP4_PROD_W-1]}}, prod_s0_tmp});
            end
            sigma_tmp = sigma_acc[SIGMA_W-1:0];
            s1_sigma_flat_tmp[g1*SIGMA_W +: SIGMA_W] = sigma_tmp;
            s1_sf_sig_prod_flat_tmp[g1*SF_SIG_PROD_W +: SF_SIG_PROD_W] =
                s0_a_sf_sig_flat_hold[g1*SF_SIG_W +: SF_SIG_W]
              * s0_b_sf_sig_flat_hold[g1*SF_SIG_W +: SF_SIG_W];

            a_sf_exp_tmp = $signed(s0_a_sf_exp_flat_hold[g1*SF_EXP_W +: SF_EXP_W]);
            b_sf_exp_tmp = $signed(s0_b_sf_exp_flat_hold[g1*SF_EXP_W +: SF_EXP_W]);
            s1_sf_exp_sum_flat_tmp[g1*SF_EXP_SUM_W +: SF_EXP_SUM_W] = a_sf_exp_tmp + b_sf_exp_tmp;
        end

        s1_d.sigma_flat       = s1_sigma_flat_tmp;
        s1_d.sf_sig_prod_flat = s1_sf_sig_prod_flat_tmp;
        s1_d.sf_exp_sum_flat  = s1_sf_exp_sum_flat_tmp;
    end

    logic signed [GAMMA_SIG_W-1:0] gamma_sig_tmp;
    logic signed [SIGMA_W-1:0]     sigma_s1_tmp;
    logic signed [SF_EXP_SUM_W-1:0] sf_exp_sum_tmp;
    logic signed [C_EXP_W-1:0]     gamma_exp_ext;
    logic signed [C_EXP_W-1:0]     emax_tmp;
    logic signed [ALIGN_W-1:0]     gamma_term_ext;
    logic signed [ALIGN_W-1:0]     c_term_ext;
    integer                        shift_tmp;

    always_comb begin
        s2_d = '0;
        s2_gamma_aligned_flat_tmp = '0;
        s2_d.special_valid  = s1_q.special_valid;
        s2_d.special_result = s1_q.special_result;

        emax_tmp = s1_q.c_exp;
        for (g2 = 0; g2 < NUM_BLOCKS; g2 = g2 + 1) begin
            sf_exp_sum_tmp = $signed(s1_sf_exp_sum_flat_hold[g2*SF_EXP_SUM_W +: SF_EXP_SUM_W]);
            gamma_exp_ext  = $signed({{(C_EXP_W-SF_EXP_SUM_W){sf_exp_sum_tmp[SF_EXP_SUM_W-1]}}, sf_exp_sum_tmp})
                           - 9'sd2;
            if (gamma_exp_ext > emax_tmp) begin
                emax_tmp = gamma_exp_ext;
            end
        end
        s2_d.emax = emax_tmp;

        for (g3 = 0; g3 < NUM_BLOCKS; g3 = g3 + 1) begin
            sigma_s1_tmp = $signed(s1_sigma_flat_hold[g3*SIGMA_W +: SIGMA_W]);
            gamma_sig_tmp = sigma_s1_tmp
                          * $signed({1'b0, s1_sf_sig_prod_flat_hold[g3*SF_SIG_PROD_W +: SF_SIG_PROD_W]});
            sf_exp_sum_tmp = $signed(s1_sf_exp_sum_flat_hold[g3*SF_EXP_SUM_W +: SF_EXP_SUM_W]);
            gamma_exp_ext  = $signed({{(C_EXP_W-SF_EXP_SUM_W){sf_exp_sum_tmp[SF_EXP_SUM_W-1]}}, sf_exp_sum_tmp})
                           - 9'sd2;
            shift_tmp      = ACC_FRAC_BITS
                           + $signed({{(32-C_EXP_W){gamma_exp_ext[C_EXP_W-1]}}, gamma_exp_ext})
                           - $signed({{(32-C_EXP_W){emax_tmp[C_EXP_W-1]}}, emax_tmp});
            gamma_term_ext = $signed({{(ALIGN_W-GAMMA_SIG_W){gamma_sig_tmp[GAMMA_SIG_W-1]}}, gamma_sig_tmp});
            s2_gamma_aligned_flat_tmp[g3*ALIGN_W +: ALIGN_W] = align_fixed_rz(gamma_term_ext, shift_tmp);
        end
        s2_d.gamma_aligned_flat = s2_gamma_aligned_flat_tmp;

        c_term_ext = $signed({{(ALIGN_W-C_SIG_W){1'b0}}, s1_q.c_sig});
        if (s1_q.c_sign) begin
            c_term_ext = -c_term_ext;
        end
        shift_tmp = ACC_FRAC_BITS
                  + $signed({{(32-C_EXP_W){s1_q.c_exp[C_EXP_W-1]}}, s1_q.c_exp})
                  - $signed({{(32-C_EXP_W){emax_tmp[C_EXP_W-1]}}, emax_tmp});
        s2_d.c_aligned = align_fixed_rz(c_term_ext, shift_tmp);
    end

    logic signed [SUM_W-1:0] sum_acc;

    always_comb begin
        s3_d = '0;
        s3_d.special_valid  = s2_q.special_valid;
        s3_d.special_result = s2_q.special_result;
        s3_d.base_exp       = s2_q.emax - ACC_FRAC_BITS_EXP;

        sum_acc = $signed({{(SUM_W-ALIGN_W){s2_q.c_aligned[ALIGN_W-1]}}, s2_q.c_aligned});
        for (g4 = 0; g4 < NUM_BLOCKS; g4 = g4 + 1) begin
            sum_acc = sum_acc
                    + $signed({{(SUM_W-ALIGN_W){s2_gamma_aligned_flat_hold[g4*ALIGN_W + ALIGN_W-1]}},
                               s2_gamma_aligned_flat_hold[g4*ALIGN_W +: ALIGN_W]});
        end
        s3_d.sum = sum_acc;
    end

    always_comb begin
        s4_d = '0;
        if (s3_q.special_valid) begin
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
    assign d_fp32_o  = s4_q.result;

endmodule
