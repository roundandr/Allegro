// ============================================================================
// File Name   : dot_emax_tree.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-10
// Description : Parameterized exponent maximum tree with per-term valid mask.
// ============================================================================

module dot_emax_tree #(
    parameter int EXP_W  = 10,
    parameter int TERM_N = 9,
    parameter logic signed [EXP_W-1:0] DEFAULT_EXP = '0
) (
    input  logic [TERM_N-1:0]       term_vld_i,
    input  logic [TERM_N*EXP_W-1:0] term_exp_flat_i,
    output logic                    emax_vld_o,
    output logic signed [EXP_W-1:0] emax_o
);

    localparam int LEVELS = (TERM_N <= 1) ? 0 : $clog2(TERM_N);
    localparam int PAD_N  = (1 << LEVELS);

    logic                    level0_vld [0:PAD_N-1];
    logic signed [EXP_W-1:0] level0_exp [0:PAD_N-1];

    genvar init_idx;
    generate
        for (init_idx = 0; init_idx < PAD_N; init_idx = init_idx + 1) begin : gen_init
            if (init_idx < TERM_N) begin : gen_real_term
                assign level0_vld[init_idx] = term_vld_i[init_idx];
                assign level0_exp[init_idx] =
                    $signed(term_exp_flat_i[init_idx*EXP_W +: EXP_W]);
            end else begin : gen_pad_term
                assign level0_vld[init_idx] = 1'b0;
                assign level0_exp[init_idx] = DEFAULT_EXP;
            end
        end
    endgenerate

    genvar level_idx;
    genvar node_idx;
    generate
        for (level_idx = 0; level_idx < LEVELS; level_idx = level_idx + 1) begin : gen_level
            localparam int NEXT_N = PAD_N >> (level_idx + 1);
            logic                    level_vld [0:NEXT_N-1];
            logic signed [EXP_W-1:0] level_exp [0:NEXT_N-1];

            for (node_idx = 0; node_idx < (PAD_N >> (level_idx + 1)); node_idx = node_idx + 1) begin : gen_node
                if (level_idx == 0) begin : gen_from_level0
                    assign level_vld[node_idx] =
                        level0_vld[node_idx*2] |
                        level0_vld[node_idx*2+1];
                    assign level_exp[node_idx] =
                        !level0_vld[node_idx*2] ? level0_exp[node_idx*2+1] :
                        !level0_vld[node_idx*2+1] ? level0_exp[node_idx*2] :
                        (level0_exp[node_idx*2+1] > level0_exp[node_idx*2]) ?
                        level0_exp[node_idx*2+1] : level0_exp[node_idx*2];
                end else begin : gen_from_prev_level
                    assign level_vld[node_idx] =
                        gen_level[level_idx-1].level_vld[node_idx*2] |
                        gen_level[level_idx-1].level_vld[node_idx*2+1];
                    assign level_exp[node_idx] =
                        !gen_level[level_idx-1].level_vld[node_idx*2] ?
                        gen_level[level_idx-1].level_exp[node_idx*2+1] :
                        !gen_level[level_idx-1].level_vld[node_idx*2+1] ?
                        gen_level[level_idx-1].level_exp[node_idx*2] :
                        (gen_level[level_idx-1].level_exp[node_idx*2+1] >
                         gen_level[level_idx-1].level_exp[node_idx*2]) ?
                        gen_level[level_idx-1].level_exp[node_idx*2+1] :
                        gen_level[level_idx-1].level_exp[node_idx*2];
                end
            end
        end
    endgenerate

    generate
        if (LEVELS == 0) begin : gen_emax_level0
            assign emax_vld_o = level0_vld[0];
            assign emax_o     = emax_vld_o ? level0_exp[0] : DEFAULT_EXP;
        end else begin : gen_emax_tree
            assign emax_vld_o = gen_level[LEVELS-1].level_vld[0];
            assign emax_o     = emax_vld_o ? gen_level[LEVELS-1].level_exp[0] : DEFAULT_EXP;
        end
    endgenerate

endmodule
