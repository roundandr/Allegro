// ============================================================================
// File Name   : int8_dot_prod.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-27
// Description : 32-element INT8 dot-product with INT32 accumulate. The datapath
//               follows the 4-stage pipeline defined in doc/INT8_DotProd.md.
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
    localparam int PROD_W    = 18;
    localparam int PSUM_W    = 22;
    localparam int SUM_W     = 33;
    localparam int S1_GROUPS = 8;

    localparam logic signed [SUM_W-1:0] INT32_MAX_EXT = 33'sh0_7fff_ffff;
    localparam logic signed [SUM_W-1:0] INT32_MIN_EXT = 33'sh1_8000_0000;

    typedef struct packed {
        logic signed [NUM_ELEMS*PROD_W-1:0] prod_flat;
        logic [31:0]                        c;
        logic                               sat_en;
    } stage0_data_t;

    typedef struct packed {
        logic signed [S1_GROUPS*PSUM_W-1:0] partial_flat;
        logic [31:0]                        c;
        logic                               sat_en;
    } stage1_data_t;

    typedef struct packed {
        logic signed [PSUM_W-1:0] psum;
        logic [31:0]              c;
        logic                     sat_en;
    } stage2_data_t;

    typedef struct packed {
        logic [31:0] result;
        logic        overflow;
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

    logic signed [NUM_ELEMS*PROD_W-1:0] s0_prod_flat_tmp;
    logic signed [S1_GROUPS*PSUM_W-1:0] s1_partial_flat_tmp;

    function automatic logic signed [PROD_W-1:0] int8_product(
        input logic [ELEM_W-1:0] a_i,
        input logic [ELEM_W-1:0] b_i,
        input logic              a_is_unsigned_i,
        input logic              b_is_unsigned_i
    );
        logic signed [PROD_W-1:0] a_ext;
        logic signed [PROD_W-1:0] b_ext;
        begin
            if (a_is_unsigned_i) begin
                a_ext = $signed({10'b0, a_i});
            end else begin
                a_ext = $signed({{10{a_i[ELEM_W-1]}}, a_i});
            end

            if (b_is_unsigned_i) begin
                b_ext = $signed({10'b0, b_i});
            end else begin
                b_ext = $signed({{10{b_i[ELEM_W-1]}}, b_i});
            end

            int8_product = a_ext * b_ext;
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

    function automatic logic signed [PSUM_W-1:0] csa_sum3_psum(
        input logic signed [PSUM_W-1:0] a_i,
        input logic signed [PSUM_W-1:0] b_i,
        input logic signed [PSUM_W-1:0] z_i
    );
        begin
            csa_sum3_psum = $signed(a_i ^ b_i ^ z_i);
        end
    endfunction

    function automatic logic signed [PSUM_W-1:0] csa_carry3_psum(
        input logic signed [PSUM_W-1:0] a_i,
        input logic signed [PSUM_W-1:0] b_i,
        input logic signed [PSUM_W-1:0] z_i
    );
        logic [PSUM_W-1:0] carry_bits;
        begin
            carry_bits = (a_i & b_i) | (a_i & z_i) | (b_i & z_i);
            csa_carry3_psum = $signed({carry_bits[PSUM_W-2:0], 1'b0});
        end
    endfunction

    function automatic logic signed [PSUM_W-1:0] partial4_sum(
        input logic signed [PROD_W-1:0] prod0_i,
        input logic signed [PROD_W-1:0] prod1_i,
        input logic signed [PROD_W-1:0] prod2_i,
        input logic signed [PROD_W-1:0] prod3_i
    );
        logic signed [PSUM_W-1:0] prod0_ext;
        logic signed [PSUM_W-1:0] prod1_ext;
        logic signed [PSUM_W-1:0] prod2_ext;
        logic signed [PSUM_W-1:0] prod3_ext;
        logic signed [PSUM_W-1:0] csa_l0_sum;
        logic signed [PSUM_W-1:0] csa_l0_carry;
        logic signed [PSUM_W-1:0] csa_l1_sum;
        logic signed [PSUM_W-1:0] csa_l1_carry;
        begin
            prod0_ext = $signed({{(PSUM_W-PROD_W){prod0_i[PROD_W-1]}}, prod0_i});
            prod1_ext = $signed({{(PSUM_W-PROD_W){prod1_i[PROD_W-1]}}, prod1_i});
            prod2_ext = $signed({{(PSUM_W-PROD_W){prod2_i[PROD_W-1]}}, prod2_i});
            prod3_ext = $signed({{(PSUM_W-PROD_W){prod3_i[PROD_W-1]}}, prod3_i});
            csa_l0_sum   = csa_sum3_psum(prod0_ext, prod1_ext, prod2_ext);
            csa_l0_carry = csa_carry3_psum(prod0_ext, prod1_ext, prod2_ext);
            csa_l1_sum   = csa_sum3_psum(csa_l0_sum, csa_l0_carry, prod3_ext);
            csa_l1_carry = csa_carry3_psum(csa_l0_sum, csa_l0_carry, prod3_ext);
            partial4_sum = csa_l1_sum + csa_l1_carry;
        end
    endfunction

    integer idx0;

    always_comb begin
        s0_d = '0;
        s0_prod_flat_tmp = '0;

        for (idx0 = 0; idx0 < NUM_ELEMS; idx0 = idx0 + 1) begin
            s0_prod_flat_tmp[idx0*PROD_W +: PROD_W] =
                int8_product(a_vec_i[idx0*ELEM_W +: ELEM_W],
                             b_vec_i[idx0*ELEM_W +: ELEM_W],
                             a_unsigned_i,
                             b_unsigned_i);
        end

        s0_d.prod_flat = s0_prod_flat_tmp;
        s0_d.c         = c_i;
        s0_d.sat_en    = sat_en_i;
    end

    always_comb begin
        s1_d = '0;
        s1_partial_flat_tmp = '0;

        s1_partial_flat_tmp[0*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[0*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[1*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[2*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[3*PROD_W +: PROD_W]));
        s1_partial_flat_tmp[1*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[4*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[5*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[6*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[7*PROD_W +: PROD_W]));
        s1_partial_flat_tmp[2*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[8*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[9*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[10*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[11*PROD_W +: PROD_W]));
        s1_partial_flat_tmp[3*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[12*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[13*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[14*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[15*PROD_W +: PROD_W]));
        s1_partial_flat_tmp[4*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[16*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[17*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[18*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[19*PROD_W +: PROD_W]));
        s1_partial_flat_tmp[5*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[20*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[21*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[22*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[23*PROD_W +: PROD_W]));
        s1_partial_flat_tmp[6*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[24*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[25*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[26*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[27*PROD_W +: PROD_W]));
        s1_partial_flat_tmp[7*PSUM_W +: PSUM_W] =
            partial4_sum($signed(s0_q.prod_flat[28*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[29*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[30*PROD_W +: PROD_W]),
                         $signed(s0_q.prod_flat[31*PROD_W +: PROD_W]));

        s1_d.partial_flat = s1_partial_flat_tmp;
        s1_d.c            = s0_q.c;
        s1_d.sat_en       = s0_q.sat_en;
    end

    logic signed [PSUM_W-1:0] partial_s2_tmp0;
    logic signed [PSUM_W-1:0] partial_s2_tmp1;
    logic signed [PSUM_W-1:0] partial_s2_tmp2;
    logic signed [PSUM_W-1:0] partial_s2_tmp3;
    logic signed [PSUM_W-1:0] partial_s2_tmp4;
    logic signed [PSUM_W-1:0] partial_s2_tmp5;
    logic signed [PSUM_W-1:0] partial_s2_tmp6;
    logic signed [PSUM_W-1:0] partial_s2_tmp7;
    logic signed [PSUM_W-1:0] psum_s2_csa_l0_tmp0;
    logic signed [PSUM_W-1:0] psum_s2_csa_l0_tmp1;
    logic signed [PSUM_W-1:0] psum_s2_csa_l0_tmp2;
    logic signed [PSUM_W-1:0] psum_s2_csa_l0_tmp3;
    logic signed [PSUM_W-1:0] psum_s2_csa_l0_tmp4;
    logic signed [PSUM_W-1:0] psum_s2_csa_l0_tmp5;
    logic signed [PSUM_W-1:0] psum_s2_csa_l1_tmp0;
    logic signed [PSUM_W-1:0] psum_s2_csa_l1_tmp1;
    logic signed [PSUM_W-1:0] psum_s2_csa_l1_tmp2;
    logic signed [PSUM_W-1:0] psum_s2_csa_l1_tmp3;
    logic signed [PSUM_W-1:0] psum_s2_csa_l2_tmp0;
    logic signed [PSUM_W-1:0] psum_s2_csa_l2_tmp1;
    logic signed [PSUM_W-1:0] psum_s2_csa_l2_tmp2;
    logic signed [PSUM_W-1:0] psum_s2_csa_l3_tmp0;
    logic signed [PSUM_W-1:0] psum_s2_csa_l3_tmp1;
    logic signed [PSUM_W-1:0] psum_s2_tmp;

    always_comb begin
        s2_d = '0;

        partial_s2_tmp0 = $signed(s1_q.partial_flat[0*PSUM_W +: PSUM_W]);
        partial_s2_tmp1 = $signed(s1_q.partial_flat[1*PSUM_W +: PSUM_W]);
        partial_s2_tmp2 = $signed(s1_q.partial_flat[2*PSUM_W +: PSUM_W]);
        partial_s2_tmp3 = $signed(s1_q.partial_flat[3*PSUM_W +: PSUM_W]);
        partial_s2_tmp4 = $signed(s1_q.partial_flat[4*PSUM_W +: PSUM_W]);
        partial_s2_tmp5 = $signed(s1_q.partial_flat[5*PSUM_W +: PSUM_W]);
        partial_s2_tmp6 = $signed(s1_q.partial_flat[6*PSUM_W +: PSUM_W]);
        partial_s2_tmp7 = $signed(s1_q.partial_flat[7*PSUM_W +: PSUM_W]);
        psum_s2_csa_l0_tmp0 = csa_sum3_psum(partial_s2_tmp0, partial_s2_tmp1, partial_s2_tmp2);
        psum_s2_csa_l0_tmp1 = csa_carry3_psum(partial_s2_tmp0, partial_s2_tmp1, partial_s2_tmp2);
        psum_s2_csa_l0_tmp2 = csa_sum3_psum(partial_s2_tmp3, partial_s2_tmp4, partial_s2_tmp5);
        psum_s2_csa_l0_tmp3 = csa_carry3_psum(partial_s2_tmp3, partial_s2_tmp4, partial_s2_tmp5);
        psum_s2_csa_l0_tmp4 = partial_s2_tmp6;
        psum_s2_csa_l0_tmp5 = partial_s2_tmp7;
        psum_s2_csa_l1_tmp0 =
            csa_sum3_psum(psum_s2_csa_l0_tmp0, psum_s2_csa_l0_tmp1, psum_s2_csa_l0_tmp2);
        psum_s2_csa_l1_tmp1 =
            csa_carry3_psum(psum_s2_csa_l0_tmp0, psum_s2_csa_l0_tmp1, psum_s2_csa_l0_tmp2);
        psum_s2_csa_l1_tmp2 =
            csa_sum3_psum(psum_s2_csa_l0_tmp3, psum_s2_csa_l0_tmp4, psum_s2_csa_l0_tmp5);
        psum_s2_csa_l1_tmp3 =
            csa_carry3_psum(psum_s2_csa_l0_tmp3, psum_s2_csa_l0_tmp4, psum_s2_csa_l0_tmp5);
        psum_s2_csa_l2_tmp0 =
            csa_sum3_psum(psum_s2_csa_l1_tmp0, psum_s2_csa_l1_tmp1, psum_s2_csa_l1_tmp2);
        psum_s2_csa_l2_tmp1 =
            csa_carry3_psum(psum_s2_csa_l1_tmp0, psum_s2_csa_l1_tmp1, psum_s2_csa_l1_tmp2);
        psum_s2_csa_l2_tmp2 = psum_s2_csa_l1_tmp3;
        psum_s2_csa_l3_tmp0 =
            csa_sum3_psum(psum_s2_csa_l2_tmp0, psum_s2_csa_l2_tmp1, psum_s2_csa_l2_tmp2);
        psum_s2_csa_l3_tmp1 =
            csa_carry3_psum(psum_s2_csa_l2_tmp0, psum_s2_csa_l2_tmp1, psum_s2_csa_l2_tmp2);
        psum_s2_tmp = psum_s2_csa_l3_tmp0 + psum_s2_csa_l3_tmp1;

        s2_d.psum   = psum_s2_tmp;
        s2_d.c      = s1_q.c;
        s2_d.sat_en = s1_q.sat_en;
    end

    logic signed [SUM_W-1:0] c_ext_s3;
    logic signed [SUM_W-1:0] psum_ext_s3;
    logic signed [SUM_W-1:0] sum_s3;
    logic                    pos_overflow_s3;
    logic                    neg_overflow_s3;

    always_comb begin
        s3_d = '0;

        c_ext_s3    = $signed({s2_q.c[31], s2_q.c});
        psum_ext_s3 = $signed({{(SUM_W-PSUM_W){s2_q.psum[PSUM_W-1]}}, s2_q.psum});
        sum_s3      = c_ext_s3 + psum_ext_s3;

        pos_overflow_s3 = sum_s3 > INT32_MAX_EXT;
        neg_overflow_s3 = sum_s3 < INT32_MIN_EXT;

        s3_d.result   = pack_int32(sum_s3[31:0], s2_q.sat_en,
                                   pos_overflow_s3, neg_overflow_s3);
        s3_d.overflow = pos_overflow_s3 | neg_overflow_s3;
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

    assign out_vld_o  = s3_vld_q;
    assign d_o        = s3_q.result;
    assign overflow_o = s3_q.overflow;

endmodule
