// ============================================================================
// File Name   : dot_fp32_rz_norm_pack.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-03
// Description : Shared signed fixed-point sum to FP32 round-toward-zero packer.
//               The absolute-value path and leading-sign-count path run in
//               parallel. A correction is applied for negative power-of-two
//               sums where leading-sign count differs from LZD(abs(sum)).
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-06-03  v0.1      LIU YUXUAN  Initial standalone version
// ============================================================================

module dot_fp32_rz_norm_pack #(
    parameter int SUM_W = 33,
    parameter int EXP_W = 10,
    parameter bit CANONICALIZE_ZERO_RESULT = 1'b0
) (
    input  logic signed [SUM_W-1:0] sum_i,
    input  logic signed [EXP_W-1:0] base_exp_i,
    input  logic                    special_vld_i,
    input  logic [31:0]             special_result_i,
    output logic [31:0]             result_o
);

    import dot_prod_pkg::*;

    localparam int SHIFT_W = (SUM_W <= 1) ? 1 : $clog2(SUM_W + 1);

    logic                     sign_bit;
    logic [SUM_W-1:0]         abs_sum;
    logic [SUM_W-1:0]         abs_sum_m1;
    logic [SUM_W-1:0]         sign_folded_sum;
    logic                     abs_sum_is_zero;
    logic                     abs_sum_is_pow2;
    logic                     neg_pow2_sel;
    logic [SHIFT_W-1:0]       lsc_raw;
    logic [SHIFT_W-1:0]       norm_lshift;
    logic [SUM_W-1:0]         norm_sum;
    logic [DOT_FP32_SIG_W-1:0] sig24;
    logic [31:0]              normal_result;
    logic [31:0]              zero_fixed_result;
    integer                   unbiased_exp;
    integer                   msb_idx;

    function automatic logic [SHIFT_W-1:0] leading_zero_count(
        input logic [SUM_W-1:0] value_i
    );
        integer idx;
        begin
            leading_zero_count = SHIFT_W'(SUM_W);
            for (idx = 0; idx < SUM_W; idx = idx + 1) begin
                if (value_i[idx]) begin
                    leading_zero_count = SHIFT_W'(SUM_W - 1 - idx);
                end
            end
        end
    endfunction

    always_comb begin
        sign_bit        = sum_i[SUM_W-1];
        abs_sum         = sign_bit ? $unsigned(-sum_i) : $unsigned(sum_i);
        abs_sum_m1      = abs_sum - {{(SUM_W-1){1'b0}}, 1'b1};
        sign_folded_sum = sum_i ^ {SUM_W{sign_bit}};
        abs_sum_is_zero = (abs_sum == {SUM_W{1'b0}});
        abs_sum_is_pow2 = !abs_sum_is_zero &&
                          ((abs_sum & abs_sum_m1) == {SUM_W{1'b0}});
        neg_pow2_sel    = sign_bit && abs_sum_is_pow2;

        lsc_raw = leading_zero_count(sign_folded_sum);
        if (neg_pow2_sel) begin
            norm_lshift = lsc_raw - SHIFT_W'(1);
        end else begin
            norm_lshift = lsc_raw;
        end

        norm_sum     = abs_sum << norm_lshift;
        sig24        = norm_sum[SUM_W-1 -: DOT_FP32_SIG_W];
        msb_idx      = (SUM_W - 1) - int'(norm_lshift);
        unbiased_exp = $signed({{(32-EXP_W){base_exp_i[EXP_W-1]}}, base_exp_i}) +
                       msb_idx;

        normal_result = abs_sum_is_zero ? 32'h0000_0000 :
                        dot_pack_fp32_fields_rz(sign_bit, unbiased_exp, sig24);

        if (CANONICALIZE_ZERO_RESULT && (normal_result[30:0] == 31'd0)) begin
            zero_fixed_result = 32'h0000_0000;
        end else begin
            zero_fixed_result = normal_result;
        end

        if (special_vld_i) begin
            result_o = special_result_i;
        end else begin
            result_o = zero_fixed_result;
        end
    end

endmodule
