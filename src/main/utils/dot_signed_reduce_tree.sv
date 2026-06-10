// ============================================================================
// File Name   : dot_signed_reduce_tree.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-10
// Description : Parameterized signed fixed-width reduction tree for dot-product
//               accumulation.  Addition keeps fixed-width wraparound semantics.
// ============================================================================

module dot_signed_reduce_tree #(
    parameter int TERM_W = 33,
    parameter int TERM_N = 17
) (
    input  logic [TERM_N*TERM_W-1:0] term_flat_i,
    output logic signed [TERM_W-1:0] sum_o
);

    localparam int LEVELS = (TERM_N <= 1) ? 0 : $clog2(TERM_N);
    localparam int PAD_N  = (1 << LEVELS);

    logic signed [TERM_W-1:0] level0_sum [0:PAD_N-1];

    genvar init_idx;
    generate
        for (init_idx = 0; init_idx < PAD_N; init_idx = init_idx + 1) begin : gen_init
            if (init_idx < TERM_N) begin : gen_real_term
                assign level0_sum[init_idx] =
                    $signed(term_flat_i[init_idx*TERM_W +: TERM_W]);
            end else begin : gen_pad_term
                assign level0_sum[init_idx] = '0;
            end
        end
    endgenerate

    genvar level_idx;
    genvar node_idx;
    generate
        for (level_idx = 0; level_idx < LEVELS; level_idx = level_idx + 1) begin : gen_level
            localparam int NEXT_N = PAD_N >> (level_idx + 1);
            logic signed [TERM_W-1:0] level_sum [0:NEXT_N-1];

            for (node_idx = 0; node_idx < (PAD_N >> (level_idx + 1)); node_idx = node_idx + 1) begin : gen_node
                if (level_idx == 0) begin : gen_from_level0
                    assign level_sum[node_idx] =
                        level0_sum[node_idx*2] +
                        level0_sum[node_idx*2+1];
                end else begin : gen_from_prev_level
                    assign level_sum[node_idx] =
                        gen_level[level_idx-1].level_sum[node_idx*2] +
                        gen_level[level_idx-1].level_sum[node_idx*2+1];
                end
            end
        end
    endgenerate

    generate
        if (LEVELS == 0) begin : gen_sum_level0
            assign sum_o = level0_sum[0];
        end else begin : gen_sum_tree
            assign sum_o = gen_level[LEVELS-1].level_sum[0];
        end
    endgenerate

endmodule
