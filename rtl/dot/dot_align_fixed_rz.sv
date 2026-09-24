// ============================================================================
// File Name   : dot_align_fixed_rz.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-10
// Description : Parameterized fixed-point RZ aligner for signed dot-product
//               terms.  Output keeps fixed-width two's-complement semantics.
// ============================================================================

module dot_align_fixed_rz #(
    parameter int MAG_W  = 32,
    parameter int TERM_W = MAG_W + 1,
    parameter int EXP_W  = 10
) (
    input  logic                         term_vld_i,
    input  logic                         term_sign_i,
    input  logic [MAG_W-1:0]             term_mag_i,
    input  logic signed [EXP_W-1:0]      term_exp_i,
    input  logic signed [EXP_W-1:0]      emax_i,
    output logic signed [TERM_W-1:0]     term_o
);

    localparam logic signed [EXP_W:0] ALIGN_LIMIT_EXP = (EXP_W+1)'(MAG_W);

    logic [MAG_W-1:0]             term_mag_shift;
    logic signed [TERM_W-1:0]     aligned_val;
    logic signed [EXP_W:0]        align_shift;
    integer                       shift_i;

    always_comb begin
        term_o         = '0;
        term_mag_shift = '0;
        aligned_val    = '0;
        align_shift    = '0;
        shift_i        = 0;

        if (term_vld_i && (term_mag_i != '0)) begin
            align_shift = $signed({emax_i[EXP_W-1], emax_i}) -
                          $signed({term_exp_i[EXP_W-1], term_exp_i});
            if (align_shift <= '0) begin
                term_mag_shift = term_mag_i;
            end else if (align_shift >= ALIGN_LIMIT_EXP) begin
                term_mag_shift = '0;
            end else begin
                shift_i = int'(align_shift);
                term_mag_shift = term_mag_i >> shift_i;
            end

            aligned_val = $signed({{(TERM_W-MAG_W){1'b0}}, term_mag_shift});
            term_o      = term_sign_i ? -aligned_val : aligned_val;
        end
    end

endmodule
