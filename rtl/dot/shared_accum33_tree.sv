// ============================================================================
// File Name   : shared_accum33_tree.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-03
// Description : Standalone two-stage shared 33-bit accumulation tree experiment.
//               F16TF32 mode taps the first stage after a 17-term reduction.
//               F4F6F8 mode uses the second stage for the final 2-term sum.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-06-03  v0.1      LIU YUXUAN  Initial version
// ============================================================================
module shared_accum33_tree #(
    parameter int TERM_W = 33,
    parameter int TERM_N = 33,
    parameter int META_W = 16
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     in_vld_i,
    output logic                     in_rdy_o,
    input  logic                     mode_i,
    input  logic [TERM_N*TERM_W-1:0] term_flat_i,
    input  logic [META_W-1:0]        meta_i,

    output logic                     f16tf32_out_vld_o,
    input  logic                     f16tf32_out_rdy_i,
    output logic                     f16tf32_sum_sign_o,
    output logic [TERM_W-1:0]        f16tf32_sum_abs_o,
    output logic [META_W-1:0]        f16tf32_meta_o,

    output logic                     f4f6f8_out_vld_o,
    input  logic                     f4f6f8_out_rdy_i,
    output logic signed [TERM_W-1:0] f4f6f8_sum_o,
    output logic [META_W-1:0]        f4f6f8_meta_o
);

    localparam logic MODE_F16TF32    = 1'b0;
    localparam logic MODE_F4F6F8 = 1'b1;

    logic                     in_fire;

    logic                     s0_vld_q;
    logic                     s0_mode_q;
    logic signed [TERM_W-1:0] s0_sum_lo_q;
    logic signed [TERM_W-1:0] s0_sum_hi_q;
    logic                     s0_f16tf32_sum_sign_q;
    logic [TERM_W-1:0]        s0_f16tf32_sum_abs_q;
    logic [META_W-1:0]        s0_meta_q;
    logic                     s0_f16tf32_sel;
    logic                     s0_f4f6f8_sel;
    logic                     s0_out_fire;
    logic                     s0_to_f16tf32_fire;
    logic                     s0_to_s1_fire;
    logic                     s0_in_rdy;

    logic                     s1_vld_q;
    logic signed [TERM_W-1:0] s1_sum_q;
    logic [META_W-1:0]        s1_meta_q;
    logic                     s1_in_rdy;
    logic                     f4f6f8_out_fire;

    logic [17*TERM_W-1:0]     sum_lo_term_flat;
    logic [16*TERM_W-1:0]     sum_hi_term_flat;
    logic signed [TERM_W-1:0] sum_lo_d;
    logic signed [TERM_W-1:0] sum_hi_d;
    logic signed [TERM_W-1:0] s1_sum_d;
    logic                     f16tf32_sum_sign_d;
    logic [TERM_W-1:0]        f16tf32_sum_abs_d;

    genvar term_gen_idx;
    generate
        for (term_gen_idx = 0; term_gen_idx < 17; term_gen_idx = term_gen_idx + 1) begin : gen_sum_lo_terms
            assign sum_lo_term_flat[term_gen_idx*TERM_W +: TERM_W] =
                term_flat_i[term_gen_idx*TERM_W +: TERM_W];
        end
        for (term_gen_idx = 0; term_gen_idx < 16; term_gen_idx = term_gen_idx + 1) begin : gen_sum_hi_terms
            assign sum_hi_term_flat[term_gen_idx*TERM_W +: TERM_W] =
                term_flat_i[(17+term_gen_idx)*TERM_W +: TERM_W];
        end
    endgenerate

    dot_signed_reduce_tree #(
        .TERM_W(TERM_W),
        .TERM_N(17)
    ) u_sum_lo_tree (
        .term_flat_i(sum_lo_term_flat),
        .sum_o      (sum_lo_d)
    );

    dot_signed_reduce_tree #(
        .TERM_W(TERM_W),
        .TERM_N(16)
    ) u_sum_hi_tree (
        .term_flat_i(sum_hi_term_flat),
        .sum_o      (sum_hi_d)
    );

    always_comb begin
        f16tf32_sum_sign_d = sum_lo_d[TERM_W-1];
        f16tf32_sum_abs_d  = sum_lo_d[TERM_W-1] ? $unsigned(-sum_lo_d) :
                                                $unsigned(sum_lo_d);
        s1_sum_d       = s0_sum_lo_q + s0_sum_hi_q;
    end

    assign s0_f16tf32_sel       = s0_vld_q && (s0_mode_q == MODE_F16TF32);
    assign s0_f4f6f8_sel    = s0_vld_q && (s0_mode_q == MODE_F4F6F8);
    assign s1_in_rdy        = !s1_vld_q || f4f6f8_out_fire;
    assign s0_to_f16tf32_fire   = s0_f16tf32_sel && f16tf32_out_rdy_i;
    assign s0_to_s1_fire    = s0_f4f6f8_sel && s1_in_rdy;
    assign s0_out_fire      = s0_to_f16tf32_fire || s0_to_s1_fire;
    assign s0_in_rdy        = !s0_vld_q || s0_out_fire;
    assign in_rdy_o         = s0_in_rdy;
    assign in_fire          = in_vld_i && in_rdy_o;

    assign f16tf32_out_vld_o    = s0_f16tf32_sel;
    assign f16tf32_sum_sign_o   = s0_f16tf32_sum_sign_q;
    assign f16tf32_sum_abs_o    = s0_f16tf32_sum_abs_q;
    assign f16tf32_meta_o       = s0_meta_q;

    assign f4f6f8_out_vld_o = s1_vld_q;
    assign f4f6f8_out_fire  = f4f6f8_out_vld_o && f4f6f8_out_rdy_i;
    assign f4f6f8_sum_o     = s1_sum_q;
    assign f4f6f8_meta_o    = s1_meta_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_vld_q          <= 1'b0;
            s0_mode_q         <= MODE_F16TF32;
            s0_sum_lo_q       <= '0;
            s0_sum_hi_q       <= '0;
            s0_f16tf32_sum_sign_q <= 1'b0;
            s0_f16tf32_sum_abs_q  <= '0;
            s0_meta_q         <= '0;
        end else begin
            if (in_fire) begin
                s0_vld_q          <= 1'b1;
                s0_mode_q         <= mode_i;
                s0_sum_lo_q       <= sum_lo_d;
                s0_sum_hi_q       <= sum_hi_d;
                s0_f16tf32_sum_sign_q <= f16tf32_sum_sign_d;
                s0_f16tf32_sum_abs_q  <= f16tf32_sum_abs_d;
                s0_meta_q         <= meta_i;
            end else if (s0_out_fire) begin
                s0_vld_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_vld_q  <= 1'b0;
            s1_sum_q  <= '0;
            s1_meta_q <= '0;
        end else begin
            if (s0_to_s1_fire) begin
                s1_vld_q  <= 1'b1;
                s1_sum_q  <= s1_sum_d;
                s1_meta_q <= s0_meta_q;
            end else if (f4f6f8_out_fire) begin
                s1_vld_q <= 1'b0;
            end
        end
    end

endmodule
