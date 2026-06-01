// ============================================================================
// File Name   : int8_dot_prod.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-27
// Description : 32-element INT8 dot-product with INT32 accumulate. The datapath
//               follows the 3-stage pipeline defined in doc/INT8_DotProd.md.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-27  v0.1      LIU YUXUAN       Initial version
// ============================================================================

module int8_dot_prod (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    input  logic         a_unsigned_i,
    input  logic         b_unsigned_i,
    input  logic         sat_en_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o,
    output logic         overflow_o
);

    localparam int ELEM_W    = 8;
    localparam int NUM_ELEMS = 32;
    localparam int OP_W      = 9;
    localparam int PROD_W    = 18;
    localparam int PSUM_W    = 22;
    localparam int SUM_W     = 33;
    localparam int REDUCE_L1_GROUPS = 16;
    localparam int REDUCE_L2_GROUPS = 8;
    localparam int REDUCE_L3_GROUPS = 4;
    localparam int REDUCE_L4_GROUPS = 2;
    localparam int STAGE0_W = NUM_ELEMS*PROD_W + 32 + 1;
    localparam int STAGE1_W = PSUM_W + 32 + 1;
    localparam int STAGE3_W = 32 + 1;

    localparam logic signed [SUM_W-1:0] INT32_MAX_EXT = 33'sh0_7fff_ffff;
    localparam logic signed [SUM_W-1:0] INT32_MIN_EXT = 33'sh1_8000_0000;

    typedef struct packed {
        logic signed [NUM_ELEMS*PROD_W-1:0] prod_flat;
        logic [31:0]                        c;
        logic                               sat_en;
    } stage0_data_t;

    typedef struct packed {
        logic signed [PSUM_W-1:0] psum;
        logic [31:0]              c;
        logic                     sat_en;
    } stage1_data_t;

    typedef struct packed {
        logic [31:0] result;
        logic        overflow;
    } stage3_data_t;

    stage0_data_t s0_d;
    stage1_data_t s1_d;
    stage3_data_t s3_d;

    stage0_data_t s0_q;
    stage1_data_t s1_q;
    stage3_data_t s3_q;

    logic s0_vld_q;
    logic s1_vld_q;
    logic s3_vld_q;

    logic s1_rdy;
    logic s3_rdy;

    logic signed [NUM_ELEMS*PROD_W-1:0] s0_prod_flat_tmp;
    logic signed [REDUCE_L1_GROUPS*PSUM_W-1:0] s1_sum_l1_flat_tmp;
    logic signed [REDUCE_L2_GROUPS*PSUM_W-1:0] s1_sum_l2_flat_tmp;
    logic signed [REDUCE_L3_GROUPS*PSUM_W-1:0] s1_sum_l3_flat_tmp;
    logic signed [REDUCE_L4_GROUPS*PSUM_W-1:0] s1_sum_l4_flat_tmp;
    logic signed [PSUM_W-1:0] s1_reduce_sum_tmp;

    function automatic logic signed [PROD_W-1:0] int8_product(
        input logic [ELEM_W-1:0] a_i,
        input logic [ELEM_W-1:0] b_i,
        input logic              a_is_unsigned_i,
        input logic              b_is_unsigned_i
    );
        logic signed [OP_W-1:0] a_ext;
        logic signed [OP_W-1:0] b_ext;
        begin
            if (a_is_unsigned_i) begin
                a_ext = $signed({1'b0, a_i});
            end else begin
                a_ext = $signed({a_i[ELEM_W-1], a_i});
            end

            if (b_is_unsigned_i) begin
                b_ext = $signed({1'b0, b_i});
            end else begin
                b_ext = $signed({b_i[ELEM_W-1], b_i});
            end

            int8_product = a_ext * b_ext;
        end
    endfunction

    function automatic logic signed [PSUM_W-1:0] product_to_psum(
        input logic signed [PROD_W-1:0] product_i
    );
        begin
            product_to_psum = $signed({{(PSUM_W-PROD_W){product_i[PROD_W-1]}},
                                      product_i});
        end
    endfunction

    function automatic logic [31:0] pack_int32(
        input logic [31:0]             wrap_result_i,
        input logic                    saturate_en_i,
        input logic                    pos_overflow_i,
        input logic                    neg_overflow_i
    );
        begin
            if (saturate_en_i && pos_overflow_i) begin
                pack_int32 = 32'h7fff_ffff;
            end else if (saturate_en_i && neg_overflow_i) begin
                pack_int32 = 32'h8000_0000;
            end else begin
                pack_int32 = wrap_result_i;
            end
        end
    endfunction

    genvar prod_idx;
    generate
        for (prod_idx = 0; prod_idx < NUM_ELEMS; prod_idx = prod_idx + 1) begin : gen_s0_product
            assign s0_prod_flat_tmp[prod_idx*PROD_W +: PROD_W] =
                int8_product(a_vec_i[prod_idx*ELEM_W +: ELEM_W],
                             b_vec_i[prod_idx*ELEM_W +: ELEM_W],
                             a_unsigned_i,
                             b_unsigned_i);
        end
    endgenerate

    always_comb begin
        s0_d = '0;

        s0_d.prod_flat = s0_prod_flat_tmp;
        s0_d.c         = c_i;
        s0_d.sat_en    = sat_en_i;
    end

    genvar red1_idx;
    genvar red2_idx;
    genvar red3_idx;
    genvar red4_idx;
    generate
        for (red1_idx = 0; red1_idx < REDUCE_L1_GROUPS; red1_idx = red1_idx + 1) begin : gen_reduce_l1
            assign s1_sum_l1_flat_tmp[red1_idx*PSUM_W +: PSUM_W] =
                product_to_psum($signed(s0_q.prod_flat[(2*red1_idx)*PROD_W +: PROD_W])) +
                product_to_psum($signed(s0_q.prod_flat[(2*red1_idx+1)*PROD_W +: PROD_W]));
        end

        for (red2_idx = 0; red2_idx < REDUCE_L2_GROUPS; red2_idx = red2_idx + 1) begin : gen_reduce_l2
            assign s1_sum_l2_flat_tmp[red2_idx*PSUM_W +: PSUM_W] =
                $signed(s1_sum_l1_flat_tmp[(2*red2_idx)*PSUM_W +: PSUM_W]) +
                $signed(s1_sum_l1_flat_tmp[(2*red2_idx+1)*PSUM_W +: PSUM_W]);
        end

        for (red3_idx = 0; red3_idx < REDUCE_L3_GROUPS; red3_idx = red3_idx + 1) begin : gen_reduce_l3
            assign s1_sum_l3_flat_tmp[red3_idx*PSUM_W +: PSUM_W] =
                $signed(s1_sum_l2_flat_tmp[(2*red3_idx)*PSUM_W +: PSUM_W]) +
                $signed(s1_sum_l2_flat_tmp[(2*red3_idx+1)*PSUM_W +: PSUM_W]);
        end

        for (red4_idx = 0; red4_idx < REDUCE_L4_GROUPS; red4_idx = red4_idx + 1) begin : gen_reduce_l4
            assign s1_sum_l4_flat_tmp[red4_idx*PSUM_W +: PSUM_W] =
                $signed(s1_sum_l3_flat_tmp[(2*red4_idx)*PSUM_W +: PSUM_W]) +
                $signed(s1_sum_l3_flat_tmp[(2*red4_idx+1)*PSUM_W +: PSUM_W]);
        end
    endgenerate

    assign s1_reduce_sum_tmp = $signed(s1_sum_l4_flat_tmp[0*PSUM_W +: PSUM_W]) +
                               $signed(s1_sum_l4_flat_tmp[1*PSUM_W +: PSUM_W]);

    always_comb begin
        s1_d = '0;
        s1_d.psum   = s1_reduce_sum_tmp;
        s1_d.c      = s0_q.c;
        s1_d.sat_en = s0_q.sat_en;
    end

    logic signed [SUM_W-1:0] c_ext_s3;
    logic signed [SUM_W-1:0] psum_ext_s3;
    logic signed [SUM_W-1:0] sum_s3;
    logic                    pos_overflow_s3;
    logic                    neg_overflow_s3;

    always_comb begin
        s3_d = '0;

        c_ext_s3    = $signed({s1_q.c[31], s1_q.c});
        psum_ext_s3 = $signed({{(SUM_W-PSUM_W){s1_q.psum[PSUM_W-1]}}, s1_q.psum});
        sum_s3      = c_ext_s3 + psum_ext_s3;

        pos_overflow_s3 = sum_s3 > INT32_MAX_EXT;
        neg_overflow_s3 = sum_s3 < INT32_MIN_EXT;

        s3_d.result   = pack_int32(sum_s3[31:0], s1_q.sat_en,
                                   pos_overflow_s3, neg_overflow_s3);
        s3_d.overflow = pos_overflow_s3 | neg_overflow_s3;
    end

    pipeline_reg #(
        .W(STAGE0_W)
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
        .W(STAGE1_W)
    ) u_stage1_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s0_vld_q),
        .in_ready (s1_rdy),
        .in_data  (s1_d),
        .out_valid(s1_vld_q),
        .out_ready(s3_rdy),
        .out_data (s1_q)
    );

    pipeline_reg #(
        .W(STAGE3_W)
    ) u_stage3_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (s1_vld_q),
        .in_ready (s3_rdy),
        .in_data  (s3_d),
        .out_valid(s3_vld_q),
        .out_ready(out_rdy_i),
        .out_data (s3_q)
    );

    assign out_vld_o  = s3_vld_q;
    assign d_o        = s3_q.result;
    assign overflow_o = s3_q.overflow;

endmodule
