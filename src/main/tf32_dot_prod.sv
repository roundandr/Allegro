// ============================================================================
// File Name   : tf32_dot_prod.sv
// Author      : Codex
// Date        : 2026-04-28
// Description : 8-element TF32 dot-product with FP32 accumulate. The datapath
//               follows the F=25 FDA pipeline defined in doc/TF32_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-28  v0.1      Codex       Initial version
// ============================================================================

module tf32_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o
);

    localparam int FP32_W               = 32;
    localparam int NUM_ELEMS            = 8;
    localparam int TF32_SIG_W           = 11;
    localparam int TF32_FRAC_W          = 10;
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
        logic                     sign;
        logic [TF32_SIG_W-1:0]    sig;
        logic signed [EXP_W-1:0]  exp;
        logic                     is_zero;
        logic                     is_inf;
        logic                     is_nan;
    } tf32_dec_t;

    typedef struct packed {
        logic                     sign;
        logic [FP32_SIG_W-1:0]    sig;
        logic signed [EXP_W-1:0]  exp;
        logic                     is_zero;
        logic                     is_inf;
        logic                     is_nan;
    } fp32_dec_t;

    typedef struct packed {
        logic                            special_vld;
        logic [31:0]                     special_result;
        logic [NUM_ELEMS-1:0]            prod_sign_flat;
        logic [NUM_ELEMS*PROD_SIG_W-1:0] prod_sig_flat;
        logic [NUM_ELEMS*EXP_W-1:0]      prod_exp_flat;
        logic [NUM_ELEMS-1:0]            prod_zero_flat;
        logic                            c_sign;
        logic [FP32_SIG_W-1:0]           c_sig;
        logic signed [EXP_W-1:0]         c_exp;
        logic                            c_zero;
        logic                            emax_vld;
        logic signed [EXP_W-1:0]         emax;
        logic signed [EXP_W-1:0]         base_exp;
    } stage0_data_t;

    typedef struct packed {
        logic                             special_vld;
        logic [31:0]                      special_result;
        logic [NUM_ELEMS*ALIGN_TERM_W-1:0] aligned_prod_flat;
        logic signed [ALIGN_TERM_W-1:0]   c_aligned;
        logic signed [EXP_W-1:0]          base_exp;
    } stage1_data_t;

    typedef struct packed {
        logic                      special_vld;
        logic [31:0]               special_result;
        logic signed [SUM_W-1:0]   sum;
        logic signed [EXP_W-1:0]   base_exp;
    } stage2_data_t;

    typedef struct packed {
        logic [31:0] result;
    } stage3_data_t;

    stage0_data_t s0_d;
    stage1_data_t s1_d;
    stage2_data_t s2_d;
    stage3_data_t s3_d;

    stage0_data_t s0_q;
    stage1_data_t s1_q;
    stage2_data_t s2_q;
    stage3_data_t s3_q;

    logic s0_vld_q;
    logic s1_vld_q;
    logic s2_vld_q;
    logic s3_vld_q;

    logic s1_rdy;
    logic s2_rdy;
    logic s3_rdy;

    logic [NUM_ELEMS-1:0]             s0_prod_sign_flat_hold;
    logic [NUM_ELEMS*PROD_SIG_W-1:0]  s0_prod_sig_flat_hold;
    logic [NUM_ELEMS*EXP_W-1:0]       s0_prod_exp_flat_hold;
    logic [NUM_ELEMS-1:0]             s0_prod_zero_flat_hold;
    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s1_aligned_prod_flat_tmp;
    logic [NUM_ELEMS*ALIGN_TERM_W-1:0] s1_aligned_prod_flat_hold;

    assign s0_prod_sign_flat_hold    = s0_q.prod_sign_flat;
    assign s0_prod_sig_flat_hold     = s0_q.prod_sig_flat;
    assign s0_prod_exp_flat_hold     = s0_q.prod_exp_flat;
    assign s0_prod_zero_flat_hold    = s0_q.prod_zero_flat;
    assign s1_aligned_prod_flat_hold = s1_q.aligned_prod_flat;

    function automatic tf32_dec_t decode_tf32_from_fp32(input logic [FP32_W-1:0] fp32_i);
        tf32_dec_t dec;
        logic [FP32_EXP_W-1:0]   exp_raw;
        logic [FP32_FRAC_W-1:0]  frac_raw;
        logic [TF32_FRAC_W-1:0]  tf32_frac;
        begin
            dec       = '0;
            dec.sign  = fp32_i[31];
            exp_raw   = fp32_i[30:23];
            frac_raw  = fp32_i[22:0];
            tf32_frac = fp32_i[22:13];

            dec.is_zero = (exp_raw == 8'h00) && (tf32_frac == 10'h000);
            dec.is_inf  = (exp_raw == 8'hff) && (frac_raw == 23'h0);
            dec.is_nan  = (exp_raw == 8'hff) && (frac_raw != 23'h0);

            if (dec.is_zero || dec.is_inf || dec.is_nan) begin
                dec.sig = '0;
                dec.exp = '0;
            end else if (exp_raw == 8'h00) begin
                dec.sig = {1'b0, tf32_frac};
                dec.exp = -10'sd126;
            end else begin
                dec.sig = {1'b1, tf32_frac};
                dec.exp = $signed({2'd0, exp_raw}) - 10'sd127;
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

    function automatic logic [ALIGN_MAG_W-1:0] align_mag_rz(
        input logic [ALIGN_MAG_W-1:0]      term_mag_i,
        input logic signed [EXP_W-1:0]     term_exp_i,
        input logic signed [EXP_W-1:0]     emax_i
    );
        logic signed [EXP_W:0] align_shift;
        integer                shift_i;
        begin
            align_mag_rz = '0;
            align_shift  = '0;
            shift_i      = 0;

            if (term_mag_i != '0) begin
                align_shift = $signed({emax_i[EXP_W-1], emax_i})
                            - $signed({term_exp_i[EXP_W-1], term_exp_i});
                if (align_shift <= 0) begin
                    align_mag_rz = term_mag_i;
                end else if (align_shift >= ALIGN_MAG_W_EXP) begin
                    align_mag_rz = '0;
                end else begin
                    shift_i = int'(align_shift);
                    align_mag_rz = term_mag_i >> shift_i;
                end
            end
        end
    endfunction

    function automatic logic signed [ALIGN_TERM_W-1:0] signed_from_mag(
        input logic                         sign_i,
        input logic [ALIGN_MAG_W-1:0]       mag_i
    );
        logic signed [ALIGN_TERM_W-1:0] signed_mag;
        begin
            signed_mag = $signed({1'b0, mag_i});
            signed_from_mag = sign_i ? -signed_mag : signed_mag;
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
    tf32_dec_t a_dec_tmp;
    tf32_dec_t b_dec_tmp;
    fp32_dec_t c_dec_tmp;
    logic any_nan_tmp;
    logic has_pos_inf_tmp;
    logic has_neg_inf_tmp;
    logic has_zero_mul_inf_tmp;
    logic lane_has_inf_tmp;
    logic lane_prod_sign_tmp;
    logic lane_prod_zero_tmp;
    logic [PROD_SIG_W-1:0] prod_sig_s0_tmp;
    logic signed [EXP_W-1:0] prod_exp_s0_tmp;
    logic signed [EXP_W-1:0] emax_s0_tmp;
    logic emax_vld_s0_tmp;
    logic [NUM_ELEMS-1:0] prod_sign_flat_s0_tmp;
    logic [NUM_ELEMS*PROD_SIG_W-1:0] prod_sig_flat_s0_tmp;
    logic [NUM_ELEMS*EXP_W-1:0] prod_exp_flat_s0_tmp;
    logic [NUM_ELEMS-1:0] prod_zero_flat_s0_tmp;

    always_comb begin
        s0_d = '0;

        c_dec_tmp            = decode_fp32(c_i);
        any_nan_tmp          = c_dec_tmp.is_nan;
        has_pos_inf_tmp      = c_dec_tmp.is_inf && !c_dec_tmp.sign;
        has_neg_inf_tmp      = c_dec_tmp.is_inf && c_dec_tmp.sign;
        has_zero_mul_inf_tmp = 1'b0;
        emax_s0_tmp          = '0;
        emax_vld_s0_tmp      = 1'b0;
        prod_sign_flat_s0_tmp = '0;
        prod_sig_flat_s0_tmp  = '0;
        prod_exp_flat_s0_tmp  = '0;
        prod_zero_flat_s0_tmp = '0;

        s0_d.c_sign = c_dec_tmp.sign;
        s0_d.c_sig  = c_dec_tmp.sig;
        s0_d.c_exp  = c_dec_tmp.exp;
        s0_d.c_zero = c_dec_tmp.is_zero;

        if (!c_dec_tmp.is_zero && !c_dec_tmp.is_inf && !c_dec_tmp.is_nan) begin
            emax_s0_tmp     = c_dec_tmp.exp;
            emax_vld_s0_tmp = 1'b1;
        end

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            a_dec_tmp = decode_tf32_from_fp32(a_vec_i[idx0*FP32_W +: FP32_W]);
            b_dec_tmp = decode_tf32_from_fp32(b_vec_i[idx0*FP32_W +: FP32_W]);

            lane_prod_sign_tmp = a_dec_tmp.sign ^ b_dec_tmp.sign;
            lane_prod_zero_tmp = a_dec_tmp.is_zero || b_dec_tmp.is_zero ||
                                 a_dec_tmp.is_inf  || b_dec_tmp.is_inf  ||
                                 a_dec_tmp.is_nan  || b_dec_tmp.is_nan;
            lane_has_inf_tmp   = ((a_dec_tmp.is_inf && !b_dec_tmp.is_zero && !b_dec_tmp.is_nan) ||
                                  (b_dec_tmp.is_inf && !a_dec_tmp.is_zero && !a_dec_tmp.is_nan));
            prod_sig_s0_tmp    = a_dec_tmp.sig * b_dec_tmp.sig;
            prod_exp_s0_tmp    = a_dec_tmp.exp + b_dec_tmp.exp;

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

            prod_sign_flat_s0_tmp[idx0] = lane_prod_sign_tmp;
            prod_sig_flat_s0_tmp[idx0*PROD_SIG_W +: PROD_SIG_W] = prod_sig_s0_tmp;
            prod_exp_flat_s0_tmp[idx0*EXP_W +: EXP_W] = lane_prod_zero_tmp ? '0 : prod_exp_s0_tmp;
            prod_zero_flat_s0_tmp[idx0] = lane_prod_zero_tmp;

            if (!lane_prod_zero_tmp) begin
                if (!emax_vld_s0_tmp || (prod_exp_s0_tmp > emax_s0_tmp)) begin
                    emax_s0_tmp     = prod_exp_s0_tmp;
                    emax_vld_s0_tmp = 1'b1;
                end
            end
        end

        s0_d.prod_sign_flat = prod_sign_flat_s0_tmp;
        s0_d.prod_sig_flat  = prod_sig_flat_s0_tmp;
        s0_d.prod_exp_flat  = prod_exp_flat_s0_tmp;
        s0_d.prod_zero_flat = prod_zero_flat_s0_tmp;
        s0_d.emax_vld = emax_vld_s0_tmp;
        s0_d.emax     = emax_s0_tmp;
        s0_d.base_exp = emax_s0_tmp - ALIGN_FRAC_BITS_EXP;

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
    logic [PROD_SIG_W-1:0]   prod_sig_s1_tmp;
    logic [ALIGN_MAG_W-1:0]  prod_mag_s1_tmp;
    logic [ALIGN_MAG_W-1:0]  prod_aligned_mag_s1_tmp;
    logic [ALIGN_MAG_W-1:0]  c_mag_s1_tmp;
    logic [ALIGN_MAG_W-1:0]  c_aligned_mag_s1_tmp;

    always_comb begin
        s1_d = '0;
        s1_aligned_prod_flat_tmp = '0;
        prod_exp_s1_tmp = '0;
        prod_sig_s1_tmp = '0;
        prod_mag_s1_tmp = '0;
        prod_aligned_mag_s1_tmp = '0;
        c_mag_s1_tmp = '0;
        c_aligned_mag_s1_tmp = '0;

        s1_d.special_vld    = s0_q.special_vld;
        s1_d.special_result = s0_q.special_result;
        s1_d.base_exp       = s0_q.base_exp;

        if (s0_q.emax_vld) begin
            for (idx1 = 0; idx1 < NUM_ELEMS; idx1 = idx1 + 1) begin
                if (!s0_prod_zero_flat_hold[idx1]) begin
                    prod_sig_s1_tmp = s0_prod_sig_flat_hold[idx1*PROD_SIG_W +: PROD_SIG_W];
                    prod_exp_s1_tmp = $signed(s0_prod_exp_flat_hold[idx1*EXP_W +: EXP_W]);
                    prod_mag_s1_tmp = {{(ALIGN_MAG_W-PROD_SIG_W-PROD_ALIGN_PAD_W){1'b0}},
                                       prod_sig_s1_tmp,
                                       {PROD_ALIGN_PAD_W{1'b0}}};
                    prod_aligned_mag_s1_tmp = align_mag_rz(prod_mag_s1_tmp, prod_exp_s1_tmp, s0_q.emax);
                    s1_aligned_prod_flat_tmp[idx1*ALIGN_TERM_W +: ALIGN_TERM_W] =
                        signed_from_mag(s0_prod_sign_flat_hold[idx1], prod_aligned_mag_s1_tmp);
                end
            end

            if (!s0_q.c_zero) begin
                c_mag_s1_tmp = {{(ALIGN_MAG_W-FP32_SIG_W-C_ALIGN_PAD_W){1'b0}},
                                s0_q.c_sig,
                                {C_ALIGN_PAD_W{1'b0}}};
                c_aligned_mag_s1_tmp = align_mag_rz(c_mag_s1_tmp, s0_q.c_exp, s0_q.emax);
                s1_d.c_aligned = signed_from_mag(s0_q.c_sign, c_aligned_mag_s1_tmp);
            end
        end

        s1_d.aligned_prod_flat = s1_aligned_prod_flat_tmp;
    end

    integer idx2;
    logic signed [SUM_W-1:0] sum_acc_tmp;

    always_comb begin
        s2_d = '0;
        s2_d.special_vld    = s1_q.special_vld;
        s2_d.special_result = s1_q.special_result;
        s2_d.base_exp       = s1_q.base_exp;

        sum_acc_tmp = s1_q.c_aligned;
        for (idx2 = 0; idx2 < NUM_ELEMS; idx2 = idx2 + 1) begin
            sum_acc_tmp = sum_acc_tmp
                        + $signed(s1_aligned_prod_flat_hold[idx2*ALIGN_TERM_W +: ALIGN_TERM_W]);
        end
        s2_d.sum = sum_acc_tmp;
    end

    always_comb begin
        s3_d = '0;
        if (s2_q.special_vld) begin
            s3_d.result = s2_q.special_result;
        end else begin
            s3_d.result = pack_fp32_rz(s2_q.sum, s2_q.base_exp);
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
        .out_ready(out_rdy_i),
        .out_data (s3_q)
    );

    assign out_vld_o = s3_vld_q;
    assign d_o       = s3_q.result;

endmodule

module tf32_dot8_fda_f25 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [31:0] a_in [8],
    input  logic [31:0] b_in [8],
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
        for (idx_pack = 0; idx_pack < 8; idx_pack = idx_pack + 1) begin
            a_vec[idx_pack*32 +: 32] = a_in[idx_pack];
            b_vec[idx_pack*32 +: 32] = b_in[idx_pack];
        end
    end

    tf32_dot_prod u_tf32_dot_prod (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_vld_i (in_valid),
        .in_rdy_o (in_ready_unused),
        .a_vec_i  (a_vec),
        .b_vec_i  (b_vec),
        .c_i      (c_in),
        .out_vld_o(out_valid),
        .out_rdy_i(1'b1),
        .d_o      (d_out)
    );

endmodule
