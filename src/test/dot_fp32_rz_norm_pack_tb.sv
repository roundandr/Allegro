// ============================================================================
// File Name   : dot_fp32_rz_norm_pack_tb.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-03
// Description : Directed/random self-checking testbench for
//               dot_fp32_rz_norm_pack.
// ============================================================================

`timescale 1ns/1ps

module dot_fp32_rz_norm_pack_tb;

    import dot_prod_pkg::*;

    localparam int SUM33_W = 33;
    localparam int SUM50_W = DOT_FP4_SUM_W;
    localparam int EXP10_W = 10;

    logic signed [SUM33_W-1:0] sum33_i;
    logic signed [EXP10_W-1:0] base_exp33_i;
    logic                      special_vld_i;
    logic [31:0]               special_result_i;
    logic [31:0]               result33_o;
    logic [31:0]               result33_canon_o;

    logic signed [SUM50_W-1:0] sum50_i;
    logic signed [EXP10_W-1:0] base_exp50_i;
    logic [31:0]               result50_o;

    int                        check_cnt;
    int                        correction_cnt33;
    int                        correction_cnt50;

    dot_fp32_rz_norm_pack #(
        .SUM_W(SUM33_W),
        .EXP_W(EXP10_W),
        .CANONICALIZE_ZERO_RESULT(1'b0)
    ) dut33 (
        .sum_i           (sum33_i),
        .base_exp_i      (base_exp33_i),
        .special_vld_i   (special_vld_i),
        .special_result_i(special_result_i),
        .result_o        (result33_o)
    );

    dot_fp32_rz_norm_pack #(
        .SUM_W(SUM33_W),
        .EXP_W(EXP10_W),
        .CANONICALIZE_ZERO_RESULT(1'b1)
    ) dut33_canon (
        .sum_i           (sum33_i),
        .base_exp_i      (base_exp33_i),
        .special_vld_i   (special_vld_i),
        .special_result_i(special_result_i),
        .result_o        (result33_canon_o)
    );

    dot_fp32_rz_norm_pack #(
        .SUM_W(SUM50_W),
        .EXP_W(EXP10_W),
        .CANONICALIZE_ZERO_RESULT(1'b1)
    ) dut50 (
        .sum_i           (sum50_i),
        .base_exp_i      (base_exp50_i),
        .special_vld_i   (special_vld_i),
        .special_result_i(special_result_i),
        .result_o        (result50_o)
    );

    function automatic logic [31:0] ref_pack33(
        input logic signed [SUM33_W-1:0] sum_i,
        input logic signed [EXP10_W-1:0] base_exp_i,
        input logic                      canonicalize_i,
        input logic                      special_vld,
        input logic [31:0]               special_result
    );
        logic                         sign_bit;
        logic [SUM33_W-1:0]           abs_sum;
        logic [SUM33_W-1:0]           norm_sum;
        logic [DOT_FP32_SIG_W-1:0]    sig24;
        logic [31:0]                  normal_result;
        integer                       msb_idx;
        integer                       norm_lshift;
        integer                       unbiased_exp;
        integer                       idx;
        begin
            if (special_vld) begin
                ref_pack33 = special_result;
            end else if (sum_i == '0) begin
                ref_pack33 = 32'h0000_0000;
            end else begin
                sign_bit = sum_i[SUM33_W-1];
                abs_sum  = sign_bit ? $unsigned(-sum_i) : $unsigned(sum_i);
                msb_idx  = 0;
                for (idx = 0; idx < SUM33_W; idx = idx + 1) begin
                    if (abs_sum[idx]) begin
                        msb_idx = idx;
                    end
                end
                norm_lshift  = (SUM33_W - 1) - msb_idx;
                norm_sum     = abs_sum << norm_lshift;
                sig24        = norm_sum[SUM33_W-1 -: DOT_FP32_SIG_W];
                unbiased_exp = $signed({{(32-EXP10_W){base_exp_i[EXP10_W-1]}}, base_exp_i}) +
                               msb_idx;
                normal_result = dot_pack_fp32_fields_rz(sign_bit, unbiased_exp, sig24);
                if (canonicalize_i && (normal_result[30:0] == 31'd0)) begin
                    ref_pack33 = 32'h0000_0000;
                end else begin
                    ref_pack33 = normal_result;
                end
            end
        end
    endfunction

    function automatic logic [31:0] ref_pack50(
        input logic signed [SUM50_W-1:0] sum_i,
        input logic signed [EXP10_W-1:0] base_exp_i,
        input logic                      canonicalize_i,
        input logic                      special_vld,
        input logic [31:0]               special_result
    );
        logic                         sign_bit;
        logic [SUM50_W-1:0]           abs_sum;
        logic [SUM50_W-1:0]           norm_sum;
        logic [DOT_FP32_SIG_W-1:0]    sig24;
        logic [31:0]                  normal_result;
        integer                       msb_idx;
        integer                       norm_lshift;
        integer                       unbiased_exp;
        integer                       idx;
        begin
            if (special_vld) begin
                ref_pack50 = special_result;
            end else if (sum_i == '0) begin
                ref_pack50 = 32'h0000_0000;
            end else begin
                sign_bit = sum_i[SUM50_W-1];
                abs_sum  = sign_bit ? $unsigned(-sum_i) : $unsigned(sum_i);
                msb_idx  = 0;
                for (idx = 0; idx < SUM50_W; idx = idx + 1) begin
                    if (abs_sum[idx]) begin
                        msb_idx = idx;
                    end
                end
                norm_lshift  = (SUM50_W - 1) - msb_idx;
                norm_sum     = abs_sum << norm_lshift;
                sig24        = norm_sum[SUM50_W-1 -: DOT_FP32_SIG_W];
                unbiased_exp = $signed({{(32-EXP10_W){base_exp_i[EXP10_W-1]}}, base_exp_i}) +
                               msb_idx;
                normal_result = dot_pack_fp32_fields_rz(sign_bit, unbiased_exp, sig24);
                if (canonicalize_i && (normal_result[30:0] == 31'd0)) begin
                    ref_pack50 = 32'h0000_0000;
                end else begin
                    ref_pack50 = normal_result;
                end
            end
        end
    endfunction

    function automatic int lzc33(input logic [SUM33_W-1:0] value_i);
        integer idx;
        begin
            lzc33 = SUM33_W;
            for (idx = 0; idx < SUM33_W; idx = idx + 1) begin
                if (value_i[idx]) begin
                    lzc33 = SUM33_W - 1 - idx;
                end
            end
        end
    endfunction

    function automatic int lzc50(input logic [SUM50_W-1:0] value_i);
        integer idx;
        begin
            lzc50 = SUM50_W;
            for (idx = 0; idx < SUM50_W; idx = idx + 1) begin
                if (value_i[idx]) begin
                    lzc50 = SUM50_W - 1 - idx;
                end
            end
        end
    endfunction

    function automatic int exact_shift33(input logic signed [SUM33_W-1:0] sum_i);
        logic [SUM33_W-1:0] abs_sum;
        integer             msb_idx;
        integer             idx;
        begin
            abs_sum = sum_i[SUM33_W-1] ? $unsigned(-sum_i) : $unsigned(sum_i);
            msb_idx = 0;
            for (idx = 0; idx < SUM33_W; idx = idx + 1) begin
                if (abs_sum[idx]) begin
                    msb_idx = idx;
                end
            end
            exact_shift33 = (sum_i == '0) ? SUM33_W : (SUM33_W - 1 - msb_idx);
        end
    endfunction

    function automatic int exact_shift50(input logic signed [SUM50_W-1:0] sum_i);
        logic [SUM50_W-1:0] abs_sum;
        integer             msb_idx;
        integer             idx;
        begin
            abs_sum = sum_i[SUM50_W-1] ? $unsigned(-sum_i) : $unsigned(sum_i);
            msb_idx = 0;
            for (idx = 0; idx < SUM50_W; idx = idx + 1) begin
                if (abs_sum[idx]) begin
                    msb_idx = idx;
                end
            end
            exact_shift50 = (sum_i == '0) ? SUM50_W : (SUM50_W - 1 - msb_idx);
        end
    endfunction

    function automatic logic signed [SUM33_W-1:0] make_neg_pow2_33(input int bit_idx);
        logic signed [SUM33_W-1:0] value;
        begin
            value = '0;
            value[bit_idx] = 1'b1;
            if (bit_idx < SUM33_W - 1) begin
                value = -value;
            end
            make_neg_pow2_33 = value;
        end
    endfunction

    function automatic logic signed [SUM50_W-1:0] make_neg_pow2_50(input int bit_idx);
        logic signed [SUM50_W-1:0] value;
        begin
            value = '0;
            value[bit_idx] = 1'b1;
            if (bit_idx < SUM50_W - 1) begin
                value = -value;
            end
            make_neg_pow2_50 = value;
        end
    endfunction

    task automatic check33(
        input logic signed [SUM33_W-1:0] sum,
        input logic signed [EXP10_W-1:0] base_exp
    );
        logic [31:0] exp_raw;
        logic [31:0] exp_canon;
        int          raw_lsc;
        int          ref_shift;
        begin
            sum33_i            = sum;
            base_exp33_i       = base_exp;
            special_vld_i      = 1'b0;
            special_result_i   = 32'h0000_0000;
            #1;

            exp_raw   = ref_pack33(sum, base_exp, 1'b0, 1'b0, 32'h0000_0000);
            exp_canon = ref_pack33(sum, base_exp, 1'b1, 1'b0, 32'h0000_0000);

            if (result33_o !== exp_raw) begin
                $fatal(1, "33-bit pack mismatch: sum=0x%0h exp=%0d got=0x%08x expected=0x%08x",
                       sum, base_exp, result33_o, exp_raw);
            end
            if (result33_canon_o !== exp_canon) begin
                $fatal(1, "33-bit canonical pack mismatch: sum=0x%0h exp=%0d got=0x%08x expected=0x%08x",
                       sum, base_exp, result33_canon_o, exp_canon);
            end

            raw_lsc   = lzc33(sum ^ {SUM33_W{sum[SUM33_W-1]}});
            ref_shift = exact_shift33(sum);
            if ((sum != '0) && sum[SUM33_W-1] && (raw_lsc != ref_shift)) begin
                if (raw_lsc != ref_shift + 1) begin
                    $fatal(1, "Unexpected 33-bit LSC delta: sum=0x%0h raw_lsc=%0d ref_shift=%0d",
                           sum, raw_lsc, ref_shift);
                end
                correction_cnt33++;
            end
            check_cnt++;
        end
    endtask

    task automatic check50(
        input logic signed [SUM50_W-1:0] sum,
        input logic signed [EXP10_W-1:0] base_exp
    );
        logic [31:0] exp_canon;
        int          raw_lsc;
        int          ref_shift;
        begin
            sum50_i            = sum;
            base_exp50_i       = base_exp;
            special_vld_i      = 1'b0;
            special_result_i   = 32'h0000_0000;
            #1;

            exp_canon = ref_pack50(sum, base_exp, 1'b1, 1'b0, 32'h0000_0000);

            if (result50_o !== exp_canon) begin
                $fatal(1, "50-bit pack mismatch: sum=0x%0h exp=%0d got=0x%08x expected=0x%08x",
                       sum, base_exp, result50_o, exp_canon);
            end

            raw_lsc   = lzc50(sum ^ {SUM50_W{sum[SUM50_W-1]}});
            ref_shift = exact_shift50(sum);
            if ((sum != '0) && sum[SUM50_W-1] && (raw_lsc != ref_shift)) begin
                if (raw_lsc != ref_shift + 1) begin
                    $fatal(1, "Unexpected 50-bit LSC delta: sum=0x%0h raw_lsc=%0d ref_shift=%0d",
                           sum, raw_lsc, ref_shift);
                end
                correction_cnt50++;
            end
            check_cnt++;
        end
    endtask

    task automatic check_special;
        begin
            sum33_i          = 33'sd123;
            base_exp33_i     = 10'sd0;
            sum50_i          = 50'sd456;
            base_exp50_i     = 10'sd0;
            special_vld_i    = 1'b1;
            special_result_i = 32'h7fff_ffff;
            #1;
            if (result33_o !== 32'h7fff_ffff ||
                result33_canon_o !== 32'h7fff_ffff ||
                result50_o !== 32'h7fff_ffff) begin
                $fatal(1, "Special result bypass mismatch");
            end
            special_vld_i    = 1'b0;
            special_result_i = 32'h0000_0000;
            check_cnt++;
        end
    endtask

    logic signed [SUM33_W-1:0] rand33;
    logic signed [SUM50_W-1:0] rand50;
    logic signed [EXP10_W-1:0] rand_exp;
    logic [63:0]               rand_bits64;
    int                        idx;

    initial begin
        sum33_i          = '0;
        base_exp33_i     = '0;
        sum50_i          = '0;
        base_exp50_i     = '0;
        special_vld_i    = 1'b0;
        special_result_i = 32'h0000_0000;
        check_cnt        = 0;
        correction_cnt33 = 0;
        correction_cnt50 = 0;

        check_special();

        check33(33'sd0,  10'sd0);
        check33(33'sd1,  10'sd0);
        check33(-33'sd1, 10'sd0);
        check33(33'sd7,  10'sd12);
        check33(-33'sd7, -10'sd3);
        check33(33'sh0_7fff_ffff, 10'sd0);
        check33(33'sh1_0000_0000, 10'sd0);
        check33(-33'sd1, -10'sd200);

        for (idx = 0; idx < SUM33_W; idx = idx + 1) begin
            check33(make_neg_pow2_33(idx), 10'sd0);
        end
        for (idx = 0; idx < SUM33_W - 1; idx = idx + 1) begin
            check33(33'sd1 <<< idx, 10'sd0);
        end

        check50(50'sd0,  10'sd0);
        check50(50'sd1,  10'sd0);
        check50(-50'sd1, 10'sd0);
        check50(50'sh1_ffff_ffff_ffff, 10'sd0);
        check50(50'sh2_0000_0000_0000, 10'sd0);
        check50(-50'sd1, -10'sd200);

        for (idx = 0; idx < SUM50_W; idx = idx + 1) begin
            check50(make_neg_pow2_50(idx), 10'sd0);
        end
        for (idx = 0; idx < SUM50_W - 1; idx = idx + 1) begin
            check50(50'sd1 <<< idx, 10'sd0);
        end

        for (idx = 0; idx < 2000; idx = idx + 1) begin
            rand_bits64 = {$urandom(), $urandom()};
            rand33      = rand_bits64[SUM33_W-1:0];
            rand_bits64 = {$urandom(), $urandom()};
            rand50      = rand_bits64[SUM50_W-1:0];
            rand_exp    = 10'($urandom_range(0, 511));
            check33(rand33, rand_exp);
            check33(-rand33, rand_exp);
            check50(rand50, rand_exp);
            check50(-rand50, rand_exp);
        end

        if (correction_cnt33 < SUM33_W || correction_cnt50 < SUM50_W) begin
            $fatal(1, "LSC correction was not sufficiently exercised: corr33=%0d corr50=%0d",
                   correction_cnt33, correction_cnt50);
        end

        $display("dot_fp32_rz_norm_pack_tb PASS checks=%0d corr33=%0d corr50=%0d",
                 check_cnt, correction_cnt33, correction_cnt50);
        $finish;
    end

endmodule
