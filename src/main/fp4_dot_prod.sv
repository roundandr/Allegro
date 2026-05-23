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

    localparam int FP4_W         = 4;
    localparam int NUM_ELEMS      = 64;
    localparam int BLOCK_SIZE     = 16;
    localparam int NUM_BLOCKS     = 4;
    localparam logic [1:0] FP4_MODE_NVFP4     = 2'd0;
    localparam logic [1:0] FP4_MODE_MXFP4     = 2'd1;
    localparam logic [1:0] FP4_MODE_FP4       = 2'd2;
    localparam logic [1:0] FP4_MODE_MXFP4_4X  = 2'd3;
    localparam int SCALE_W        = 8;
    localparam int FP4_PROD_W     = 9;
    localparam int SIGMA_W        = 13;
    localparam int SF_SIG_W       = 4;
    localparam int SF_EXP_W       = 9;
    localparam int SF_SIG_PROD_W  = 8;
    localparam int SF_EXP_SUM_W   = 10;
    localparam int GAMMA_SIG_W    = 20;
    localparam int C_SIG_W        = 24;
    localparam int C_EXP_W        = 10;
    localparam int EXP_DIFF_W     = C_EXP_W + 1;
    // GDFS aligns raw significands into a 35-fractional-bit accumulator domain.
    localparam int ALIGN_FRAC_W   = 35;
    localparam int ALIGN_INT_W    = 11;
    localparam int ALIGN_MAG_W    = ALIGN_FRAC_W + ALIGN_INT_W;
    localparam int ALIGN_TERM_W   = ALIGN_MAG_W + 1;
    localparam int ALIGN_SHIFT_W  = $clog2(ALIGN_MAG_W + 1);
    localparam int SUM_W          = ALIGN_TERM_W + 3;
    localparam int PACK_SIG_W     = 24;
    localparam int PACK_LOD_GRP_W = 10;
    localparam int PACK_LOD_GRP_N = (SUM_W + PACK_LOD_GRP_W - 1) / PACK_LOD_GRP_W;
    localparam logic signed [C_EXP_W-1:0] FP4_DOT_EXP = -10'sd2;
    localparam logic signed [C_EXP_W-1:0] ALIGN_FRAC_EXP = ALIGN_FRAC_W;
    localparam logic signed [C_EXP_W-1:0] GAMMA_NORM_EXP = 10'sd8;
    localparam logic signed [C_EXP_W-1:0] C_NORM_EXP     = 10'sd23;
    localparam int GAMMA_ALIGN_LSHIFT_W = ALIGN_FRAC_W - GAMMA_NORM_EXP;
    localparam int C_ALIGN_LSHIFT_W     = ALIGN_FRAC_W - C_NORM_EXP;
    localparam int C_ALIGN_PAD_W        = ALIGN_MAG_W - C_SIG_W - C_ALIGN_LSHIFT_W;

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
        logic [NUM_BLOCKS-1:0]              gamma_sign_flat;
        logic [NUM_BLOCKS*GAMMA_SIG_W-1:0]  gamma_mag_flat;
        logic [NUM_BLOCKS*C_EXP_W-1:0]      gamma_exp_flat;
        logic                    c_sign;
        logic [C_SIG_W-1:0]      c_mag;
        logic signed [C_EXP_W-1:0] c_exp;
        logic signed [C_EXP_W-1:0] emax;
    } stage1_data_t;

    typedef struct packed {
        logic                    special_valid;
        logic [31:0]             special_result;
        logic [NUM_BLOCKS*ALIGN_TERM_W-1:0] gamma_aligned_flat;
        logic signed [ALIGN_TERM_W-1:0] c_aligned;
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

    logic [NUM_BLOCKS-1:0]              s1_gamma_sign_flat_tmp;
    logic [NUM_BLOCKS*GAMMA_SIG_W-1:0]  s1_gamma_mag_flat_tmp;
    logic [NUM_BLOCKS*C_EXP_W-1:0]      s1_gamma_exp_flat_tmp;

    logic [NUM_BLOCKS-1:0]              s1_gamma_sign_flat_hold;
    logic [NUM_BLOCKS*GAMMA_SIG_W-1:0]  s1_gamma_mag_flat_hold;
    logic [NUM_BLOCKS*C_EXP_W-1:0]      s1_gamma_exp_flat_hold;

    logic [NUM_BLOCKS*ALIGN_TERM_W-1:0] s2_gamma_aligned_flat_tmp;
    logic [NUM_BLOCKS*ALIGN_TERM_W-1:0] s2_gamma_aligned_flat_hold;

    assign s0_prod_flat_hold     = s0_q.prod_flat;
    assign s0_a_sf_sig_flat_hold = s0_q.a_sf_sig_flat;
    assign s0_b_sf_sig_flat_hold = s0_q.b_sf_sig_flat;
    assign s0_a_sf_exp_flat_hold = s0_q.a_sf_exp_flat;
    assign s0_b_sf_exp_flat_hold = s0_q.b_sf_exp_flat;
    assign s1_gamma_sign_flat_hold = s1_q.gamma_sign_flat;
    assign s1_gamma_mag_flat_hold  = s1_q.gamma_mag_flat;
    assign s1_gamma_exp_flat_hold  = s1_q.gamma_exp_flat;
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

    function automatic logic [SF_EXP_W+4:0] decode_ue4m3_scale(input logic [SCALE_W-1:0] scale_i);
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
                exp = -9'sd9;
            end else begin
                sig = {1'b1, mant_raw};
                exp = $signed({{(SF_EXP_W-4){1'b0}}, exp_raw}) - 9'sd10;
            end

            decode_ue4m3_scale = {is_nan, sig, exp};
        end
    endfunction

    function automatic logic [SF_EXP_W+4:0] decode_e8m0_scale(input logic [SCALE_W-1:0] scale_i);
        logic       is_nan;
        logic [3:0] sig;
        logic signed [SF_EXP_W-1:0] exp;
        begin
            is_nan  = (scale_i == 8'hff);
            sig     = 4'd8;
            exp     = $signed({1'b0, scale_i}) - 9'sd130;
            decode_e8m0_scale = {is_nan, sig, exp};
        end
    endfunction

    function automatic logic [SF_EXP_W+4:0] make_unit_scale();
        logic       is_nan;
        logic [3:0] sig;
        logic signed [SF_EXP_W-1:0] exp;
        begin
            is_nan = 1'b0;
            sig = 4'd8;
            exp = -9'sd3;
            make_unit_scale = {is_nan, sig, exp};
        end
    endfunction

    function automatic logic [37:0] decode_c(input logic [31:0] c_i);
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
                exp = -10'sd149;
            end else begin
                sig = {1'b1, frac_raw};
                exp = $signed({1'b0, exp_raw}) - 10'sd150;
            end

            decode_c = {sign, is_zero, is_nan, is_inf, sig, exp};
        end
    endfunction

    function automatic logic signed [ALIGN_TERM_W-1:0] align_fixed_rz(
        input logic                           term_sign_i,
        input logic [ALIGN_MAG_W-1:0]         term_mag_i,
        input logic signed [C_EXP_W-1:0]      term_exp_i,
        input logic signed [C_EXP_W-1:0]      emax_i
    );
        logic [ALIGN_MAG_W-1:0] aligned_mag;
        logic signed [ALIGN_TERM_W-1:0] aligned_val;
        logic signed [EXP_DIFF_W-1:0] align_shift;
        logic [ALIGN_SHIFT_W-1:0] shift_amt;
        begin
            if (term_mag_i == '0) begin
                align_fixed_rz = '0;
            end else begin
                // term_mag_i is already wired into the 35-fractional-bit
                // accumulator domain. Alignment after emax search is RZ
                // right shift by emax - normalized_exp.
                align_shift = $signed({{(EXP_DIFF_W-C_EXP_W){emax_i[C_EXP_W-1]}}, emax_i})
                            - $signed({{(EXP_DIFF_W-C_EXP_W){term_exp_i[C_EXP_W-1]}},
                                      term_exp_i});

                if (align_shift <= $signed({EXP_DIFF_W{1'b0}})) begin
                    aligned_mag = term_mag_i;
                end else if (align_shift >= $signed(EXP_DIFF_W'(ALIGN_MAG_W))) begin
                    aligned_mag = '0;
                end else begin
                    shift_amt = align_shift[ALIGN_SHIFT_W-1:0];
                    aligned_mag = term_mag_i >> shift_amt;
                end

                aligned_val = $signed({1'b0, aligned_mag});
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

    function automatic logic signed [C_EXP_W-1:0] emax_pick_exp(
        input logic                      a_vld_i,
        input logic signed [C_EXP_W-1:0] a_exp_i,
        input logic                      b_vld_i,
        input logic signed [C_EXP_W-1:0] b_exp_i
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

    function automatic integer pack_msb_idx(input logic [SUM_W-1:0] abs_sum_i);
        integer grp_idx;
        integer bit_idx;
        integer sum_idx;
        integer grp_msb_idx;
        logic   grp_vld;
        begin
            pack_msb_idx = 0;

            for (grp_idx = 0; grp_idx < PACK_LOD_GRP_N; grp_idx = grp_idx + 1) begin
                grp_vld     = 1'b0;
                grp_msb_idx = 0;

                for (bit_idx = 0; bit_idx < PACK_LOD_GRP_W; bit_idx = bit_idx + 1) begin
                    sum_idx = grp_idx * PACK_LOD_GRP_W + bit_idx;
                    if (sum_idx < SUM_W) begin
                        if (abs_sum_i[sum_idx]) begin
                            grp_vld     = 1'b1;
                            grp_msb_idx = bit_idx;
                        end
                    end
                end

                if (grp_vld) begin
                    pack_msb_idx = grp_idx * PACK_LOD_GRP_W + grp_msb_idx;
                end
            end
        end
    endfunction

    function automatic logic [PACK_SIG_W-1:0] pack_sig24_from_abs(
        input logic [SUM_W-1:0] abs_sum_i,
        input integer           msb_idx_i
    );
        integer sig_idx;
        integer sum_idx;
        begin
            pack_sig24_from_abs = '0;

            for (sig_idx = 0; sig_idx < PACK_SIG_W; sig_idx = sig_idx + 1) begin
                sum_idx = msb_idx_i - (PACK_SIG_W - 1 - sig_idx);
                if (sum_idx >= 0) begin
                    pack_sig24_from_abs[sig_idx] = abs_sum_i[sum_idx];
                end
            end
        end
    endfunction

    function automatic logic [31:0] pack_fp32_rz(
        input logic signed [SUM_W-1:0] sum_i,
        input logic signed [C_EXP_W-1:0] base_exp_i
    );
        logic             sign_bit;
        logic [SUM_W-1:0] abs_sum;
        logic [23:0]      sig24;
        logic [22:0]      frac_field;
        logic [7:0]       exp_field;
        integer           msb_idx;
        integer           unbiased_exp;
        integer           shift_sub;
        begin
            pack_fp32_rz = 32'h0000_0000;
            sign_bit     = sum_i[SUM_W-1];
            abs_sum      = '0;
            sig24        = '0;
            frac_field   = '0;
            exp_field    = '0;
            unbiased_exp = 0;
            msb_idx      = 0;
            shift_sub    = 0;

            if (sum_i != '0) begin
                if (sign_bit) begin
                    abs_sum = -sum_i;
                end else begin
                    abs_sum = sum_i;
                end

                msb_idx      = pack_msb_idx(abs_sum);
                unbiased_exp = base_exp_i + msb_idx;
                sig24        = pack_sig24_from_abs(abs_sum, msb_idx);

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
    integer g3;
    integer g4;
    integer k1;
    logic [SF_EXP_W+4:0] scale_dec_a;
    logic [SF_EXP_W+4:0] scale_dec_b;
    logic [37:0]         c_dec;
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
            case (fp4_mode_i)
                FP4_MODE_MXFP4: begin
                    scale_dec_a = decode_e8m0_scale(a_sf_i[(g0 >> 1)*SCALE_W +: SCALE_W]);
                    scale_dec_b = decode_e8m0_scale(b_sf_i[(g0 >> 1)*SCALE_W +: SCALE_W]);
                end
                FP4_MODE_MXFP4_4X: begin
                    scale_dec_a = decode_e8m0_scale(a_sf_i[g0*SCALE_W +: SCALE_W]);
                    scale_dec_b = decode_e8m0_scale(b_sf_i[g0*SCALE_W +: SCALE_W]);
                end
                FP4_MODE_FP4: begin
                    scale_dec_a = make_unit_scale();
                    scale_dec_b = make_unit_scale();
                end
                default: begin
                    scale_dec_a = decode_ue4m3_scale(a_sf_i[g0*SCALE_W +: SCALE_W]);
                    scale_dec_b = decode_ue4m3_scale(b_sf_i[g0*SCALE_W +: SCALE_W]);
                end
            endcase
            s0_a_sf_sig_flat_tmp[g0*SF_SIG_W +: SF_SIG_W] = scale_dec_a[SF_EXP_W+3:SF_EXP_W];
            s0_b_sf_sig_flat_tmp[g0*SF_SIG_W +: SF_SIG_W] = scale_dec_b[SF_EXP_W+3:SF_EXP_W];
            s0_a_sf_exp_flat_tmp[g0*SF_EXP_W +: SF_EXP_W] = scale_dec_a[SF_EXP_W-1:0];
            s0_b_sf_exp_flat_tmp[g0*SF_EXP_W +: SF_EXP_W] = scale_dec_b[SF_EXP_W-1:0];
            any_scale_nan = any_scale_nan | scale_dec_a[SF_EXP_W+4] | scale_dec_b[SF_EXP_W+4];
        end

        s0_d.prod_flat     = s0_prod_flat_tmp;
        s0_d.a_sf_sig_flat = s0_a_sf_sig_flat_tmp;
        s0_d.b_sf_sig_flat = s0_b_sf_sig_flat_tmp;
        s0_d.a_sf_exp_flat = s0_a_sf_exp_flat_tmp;
        s0_d.b_sf_exp_flat = s0_b_sf_exp_flat_tmp;

        c_dec         = decode_c(c_fp32_i);
        s0_d.c_sign   = c_dec[37];
        s0_d.c_sig    = c_dec[33:10];
        s0_d.c_exp    = $signed(c_dec[9:0]);

        if (any_scale_nan || c_dec[35]) begin
            s0_d.special_valid  = 1'b1;
            s0_d.special_result = 32'h7fff_ffff;
        end else if (c_dec[34]) begin
            s0_d.special_valid  = 1'b1;
            s0_d.special_result = c_fp32_i;
        end else begin
            s0_d.special_valid  = 1'b0;
            s0_d.special_result = 32'h0000_0000;
        end
    end

    logic signed [SIGMA_W-1:0]      sigma_tmp;
    logic signed [15:0]             sigma_acc;
    logic signed [SF_EXP_W-1:0]     a_sf_exp_tmp;
    logic signed [SF_EXP_W-1:0]     b_sf_exp_tmp;
    logic signed [FP4_PROD_W-1:0]   prod_s0_tmp;
    logic [SF_SIG_PROD_W-1:0]       sf_sig_prod_tmp;
    logic signed [SF_EXP_SUM_W-1:0] sf_exp_sum_tmp_s1;
    logic signed [GAMMA_SIG_W-1:0]  gamma_sig_tmp_s1;
    logic signed [C_EXP_W-1:0]      gamma_exp_tmp_s1;
    logic signed [C_EXP_W-1:0]      gamma_norm_exp_s1_tmp;
    logic signed [C_EXP_W-1:0]      c_norm_exp_s1_tmp;
    logic                           gamma_sign_tmp_s1;
    logic [GAMMA_SIG_W-1:0]         gamma_abs_tmp_s1;
    logic [GAMMA_SIG_W-1:0]         gamma_mag_tmp_s1;
    logic                           emax_l0_vld_tmp [0:4];
    logic signed [C_EXP_W-1:0]      emax_l0_exp_tmp [0:4];
    logic                           emax_l1_vld_tmp [0:2];
    logic signed [C_EXP_W-1:0]      emax_l1_exp_tmp [0:2];
    logic                           emax_l2_vld_tmp [0:1];
    logic signed [C_EXP_W-1:0]      emax_l2_exp_tmp [0:1];

    always_comb begin
        s1_d = '0;
        s1_gamma_sign_flat_tmp = '0;
        s1_gamma_mag_flat_tmp  = '0;
        s1_gamma_exp_flat_tmp  = '0;
        s1_d.special_valid  = s0_q.special_valid;
        s1_d.special_result = s0_q.special_result;
        s1_d.c_sign         = s0_q.c_sign;
        sigma_tmp           = '0;
        sigma_acc           = '0;
        a_sf_exp_tmp        = '0;
        b_sf_exp_tmp        = '0;
        prod_s0_tmp         = '0;
        sf_sig_prod_tmp     = '0;
        sf_exp_sum_tmp_s1   = '0;
        gamma_sig_tmp_s1    = '0;
        gamma_exp_tmp_s1    = '0;
        gamma_norm_exp_s1_tmp = '0;
        c_norm_exp_s1_tmp   = '0;
        gamma_sign_tmp_s1   = 1'b0;
        gamma_abs_tmp_s1    = '0;
        gamma_mag_tmp_s1    = '0;
        if (s0_q.c_sig == '0) begin
            s1_d.c_exp = '0;
            s1_d.c_mag = '0;
        end else begin
            s1_d.c_exp       = s0_q.c_exp;
            s1_d.c_mag       = s0_q.c_sig;
        end

        for (g1 = 0; g1 < NUM_BLOCKS; g1 = g1 + 1) begin
            sigma_acc = '0;
            for (k1 = 0; k1 < BLOCK_SIZE; k1 = k1 + 1) begin
                prod_s0_tmp = $signed(s0_prod_flat_hold[(g1*BLOCK_SIZE+k1)*FP4_PROD_W +: FP4_PROD_W]);
                sigma_acc = sigma_acc
                          + $signed({{(16-FP4_PROD_W){prod_s0_tmp[FP4_PROD_W-1]}}, prod_s0_tmp});
            end
            sigma_tmp = sigma_acc[SIGMA_W-1:0];
            sf_sig_prod_tmp =
                s0_a_sf_sig_flat_hold[g1*SF_SIG_W +: SF_SIG_W]
              * s0_b_sf_sig_flat_hold[g1*SF_SIG_W +: SF_SIG_W];
            a_sf_exp_tmp = $signed(s0_a_sf_exp_flat_hold[g1*SF_EXP_W +: SF_EXP_W]);
            b_sf_exp_tmp = $signed(s0_b_sf_exp_flat_hold[g1*SF_EXP_W +: SF_EXP_W]);
            sf_exp_sum_tmp_s1 = a_sf_exp_tmp + b_sf_exp_tmp;

            gamma_sig_tmp_s1 = sigma_tmp * $signed({1'b0, sf_sig_prod_tmp});
            gamma_exp_tmp_s1 = $signed(sf_exp_sum_tmp_s1) + FP4_DOT_EXP;
            gamma_norm_exp_s1_tmp = gamma_exp_tmp_s1 + GAMMA_NORM_EXP;
            gamma_sign_tmp_s1 = gamma_sig_tmp_s1[GAMMA_SIG_W-1];
            if (gamma_sig_tmp_s1 == '0) begin
                gamma_mag_tmp_s1 = '0;
            end else begin
                if (gamma_sign_tmp_s1) begin
                    gamma_abs_tmp_s1 = -gamma_sig_tmp_s1;
                end else begin
                    gamma_abs_tmp_s1 = gamma_sig_tmp_s1;
                end
                gamma_mag_tmp_s1 = gamma_abs_tmp_s1;
            end

            s1_gamma_sign_flat_tmp[g1] = gamma_sign_tmp_s1;
            s1_gamma_mag_flat_tmp[g1*GAMMA_SIG_W +: GAMMA_SIG_W] = gamma_mag_tmp_s1;
            s1_gamma_exp_flat_tmp[g1*C_EXP_W +: C_EXP_W] = gamma_exp_tmp_s1;
            emax_l0_vld_tmp[g1] = 1'b1;
            emax_l0_exp_tmp[g1] = gamma_norm_exp_s1_tmp;
        end

        if (s0_q.c_sig == '0) begin
            emax_l0_vld_tmp[4] = 1'b0;
            emax_l0_exp_tmp[4] = '0;
        end else begin
            c_norm_exp_s1_tmp = s0_q.c_exp + C_NORM_EXP;
            emax_l0_vld_tmp[4] = 1'b1;
            emax_l0_exp_tmp[4] = c_norm_exp_s1_tmp;
        end

        for (g1 = 0; g1 < 2; g1 = g1 + 1) begin
            emax_l1_vld_tmp[g1] = emax_pick_vld(emax_l0_vld_tmp[g1*2],
                                                emax_l0_vld_tmp[g1*2+1]);
            emax_l1_exp_tmp[g1] = emax_pick_exp(emax_l0_vld_tmp[g1*2],
                                                emax_l0_exp_tmp[g1*2],
                                                emax_l0_vld_tmp[g1*2+1],
                                                emax_l0_exp_tmp[g1*2+1]);
        end
        emax_l1_vld_tmp[2] = emax_l0_vld_tmp[4];
        emax_l1_exp_tmp[2] = emax_l0_exp_tmp[4];

        emax_l2_vld_tmp[0] = emax_pick_vld(emax_l1_vld_tmp[0], emax_l1_vld_tmp[1]);
        emax_l2_exp_tmp[0] = emax_pick_exp(emax_l1_vld_tmp[0], emax_l1_exp_tmp[0],
                                           emax_l1_vld_tmp[1], emax_l1_exp_tmp[1]);
        emax_l2_vld_tmp[1] = emax_l1_vld_tmp[2];
        emax_l2_exp_tmp[1] = emax_l1_exp_tmp[2];

        s1_d.gamma_sign_flat = s1_gamma_sign_flat_tmp;
        s1_d.gamma_mag_flat  = s1_gamma_mag_flat_tmp;
        s1_d.gamma_exp_flat  = s1_gamma_exp_flat_tmp;
        s1_d.emax = emax_pick_exp(emax_l2_vld_tmp[0], emax_l2_exp_tmp[0],
                                  emax_l2_vld_tmp[1], emax_l2_exp_tmp[1]);
    end

    logic signed [C_EXP_W-1:0] gamma_exp_ext;
    logic [ALIGN_MAG_W-1:0]    gamma_align_mag_tmp;
    logic [ALIGN_MAG_W-1:0]    c_align_mag_tmp;

    always_comb begin
        s2_d = '0;
        s2_gamma_aligned_flat_tmp = '0;
        s2_d.special_valid  = s1_q.special_valid;
        s2_d.special_result = s1_q.special_result;
        gamma_exp_ext       = '0;
        gamma_align_mag_tmp = '0;
        c_align_mag_tmp     = '0;

        // GDFS Step 5 alignment uses the normalized emax registered in S1.
        s2_d.emax = s1_q.emax;

        for (g3 = 0; g3 < NUM_BLOCKS; g3 = g3 + 1) begin
            gamma_exp_ext = $signed(s1_gamma_exp_flat_hold[g3*C_EXP_W +: C_EXP_W]);
            gamma_align_mag_tmp =
                {s1_gamma_mag_flat_hold[g3*GAMMA_SIG_W +: (GAMMA_SIG_W-1)],
                 {GAMMA_ALIGN_LSHIFT_W{1'b0}}};
            s2_gamma_aligned_flat_tmp[g3*ALIGN_TERM_W +: ALIGN_TERM_W] =
                align_fixed_rz(s1_gamma_sign_flat_hold[g3],
                               gamma_align_mag_tmp,
                               gamma_exp_ext + GAMMA_NORM_EXP,
                               s1_q.emax);
        end
        s2_d.gamma_aligned_flat = s2_gamma_aligned_flat_tmp;

        c_align_mag_tmp = {{C_ALIGN_PAD_W{1'b0}}, s1_q.c_mag, {C_ALIGN_LSHIFT_W{1'b0}}};
        s2_d.c_aligned = align_fixed_rz(s1_q.c_sign, c_align_mag_tmp, s1_q.c_exp + C_NORM_EXP, s1_q.emax);
    end

    logic signed [SUM_W-1:0] sum_acc;

    always_comb begin
        s3_d = '0;
        s3_d.special_valid  = s2_q.special_valid;
        s3_d.special_result = s2_q.special_result;
        s3_d.base_exp       = s2_q.emax - ALIGN_FRAC_EXP;

        sum_acc = $signed({{(SUM_W-ALIGN_TERM_W){s2_q.c_aligned[ALIGN_TERM_W-1]}}, s2_q.c_aligned});
        for (g4 = 0; g4 < NUM_BLOCKS; g4 = g4 + 1) begin
            sum_acc = sum_acc
                    + $signed({{(SUM_W-ALIGN_TERM_W){s2_gamma_aligned_flat_hold[g4*ALIGN_TERM_W + ALIGN_TERM_W-1]}},
                               s2_gamma_aligned_flat_hold[g4*ALIGN_TERM_W +: ALIGN_TERM_W]});
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
