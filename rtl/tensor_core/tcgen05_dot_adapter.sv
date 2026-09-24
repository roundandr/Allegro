// ============================================================================
// File Name   : tcgen05_dot_adapter.sv
// Description : Scalar-dot adapter for Blackwell TCGen05 MMA semantic testing.
//               It maps one TCGen05 tile row/column dot onto the existing dot
//               units. It does not model TMEM allocation, TMA, commit/wait, or
//               tensor-core scheduling.
// ============================================================================

module tcgen05_dot_adapter #(
    parameter int unsigned INFLIGHT = 32,
    parameter int unsigned TAG_W = 16
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic [TAG_W-1:0] tag_i,
    output logic [TAG_W-1:0] tag_o,
    input  logic         in_vld_i,
    output logic         in_rdy_o,

    input  logic [1:0]   op_i,
    input  logic [3:0]   kind_i,
    input  logic [3:0]   d_type_i,
    input  logic [3:0]   a_type_i,
    input  logic [3:0]   b_type_i,
    input  logic [2:0]   scale_type_i,
    input  logic [2:0]   scale_vec_i,
    input  logic         cta_group_i,
    input  logic         enable_input_d_i,
    input  logic [3:0]   scale_input_d_i,

    input  logic [255:0] a_vec_i,
    input  logic [511:0] b_vec_i,
    input  logic [127:0] sparse_meta_i,
    input  logic [31:0]  c_i,
    input  logic [31:0]  a_sf_i,
    input  logic [31:0]  b_sf_i,

    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o,
    output logic [7:0]   status_o
);
    import tcgen05_mma_pkg::*;
    import dot_prod_pkg::*;

    localparam logic [1:0] CORE_NONE  = 2'd0;
    localparam logic [1:0] CORE_F16TF32 = 2'd1;
    localparam logic [1:0] CORE_F4F6F8  = 2'd2;
    localparam logic [1:0] CORE_INT8  = 2'd3;
    localparam logic [1:0] CORE_FP4   = 2'd0;

    localparam int unsigned PTR_W = (INFLIGHT <= 1) ? 1 : $clog2(INFLIGHT);
    localparam int unsigned COUNT_W = $clog2(INFLIGHT + 1);
    typedef struct packed {
        logic [1:0] core;
        logic fp4;
        logic [3:0] dtype;
        logic [7:0] error;
        logic [TAG_W-1:0] tag;
    } request_meta_t;
    request_meta_t meta_q [0:INFLIGHT-1];
    request_meta_t head;
    logic [PTR_W-1:0] rd_q, wr_q;
    logic [COUNT_W-1:0] count_q;
    logic retire_fire;
    assign head = meta_q[rd_q];
    assign tag_o = head.tag;

    logic sparse_req;
    logic sparse_meta_valid;
    logic unsupported_req;
    logic invalid_sparse_meta;
    logic err_path;
    logic issue_fire;

    logic f16tf32_supported;
    logic f4f6f8_supported;
    logic int8_supported;
    logic fp4_supported;

    logic f16tf32_sel;
    logic f4f6f8_sel;
    logic int8_sel;
    logic fp4_sel;

    logic [1:0] selected_core;
    logic       selected_is_fp4;
    logic [1:0] f16tf32_a_dtype;
    logic [1:0] f16tf32_b_dtype;
    logic [2:0] f4f6f8_a_dtype;
    logic [2:0] f4f6f8_b_dtype;
    logic       f4f6f8_mx_en;
    logic [1:0] fp4_mode;

    logic [255:0] b_f16tf32_core;
    logic [255:0] b_tf32_core;
    logic [255:0] b_fp16_core;
    logic [255:0] b_8b_core;
    logic [255:0] b_6b_core;
    logic [255:0] b_4b_core;
    logic [255:0] b_fp4_core;
    logic [255:0] f4f6f8_b_vec;

    logic [31:0] c_core;

    logic f16tf32_in_rdy;
    logic f4f6f8_in_rdy;
    logic int8_in_rdy;
    logic fp4_in_rdy;

    logic f16tf32_in_vld;
    logic f4f6f8_in_vld;
    logic int8_in_vld;
    logic fp4_in_vld;
    logic int8_a_unsigned;
    logic int8_b_unsigned;

    logic f16tf32_out_vld;
    logic f4f6f8_out_vld;
    logic int8_out_vld;
    logic fp4_out_vld;

    logic f16tf32_out_rdy;
    logic f4f6f8_out_rdy;
    logic int8_out_rdy;
    logic fp4_out_rdy;

    logic [31:0] f16tf32_d;
    logic [31:0] f4f6f8_d;
    logic [31:0] int8_d;
    logic [31:0] fp4_d;
    logic        int8_overflow;

    function automatic logic [3:0] popcount4(input logic [3:0] value_i);
        integer bit_idx;
        begin
            popcount4 = 4'd0;
            for (bit_idx = 0; bit_idx < 4; bit_idx = bit_idx + 1) begin
                popcount4 = popcount4 + {3'd0, value_i[bit_idx]};
            end
        end
    endfunction

    function automatic logic [3:0] popcount8(input logic [7:0] value_i);
        integer bit_idx;
        begin
            popcount8 = 4'd0;
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                popcount8 = popcount8 + {3'd0, value_i[bit_idx]};
            end
        end
    endfunction

    function automatic logic meta_2to4_valid(
        input logic [127:0] meta_i,
        input integer       groups_i
    );
        integer group_idx;
        begin
            meta_2to4_valid = 1'b1;
            for (group_idx = 0; group_idx < groups_i; group_idx = group_idx + 1) begin
                if (popcount4(meta_i[group_idx*4 +: 4]) != 4'd2) begin
                    meta_2to4_valid = 1'b0;
                end
            end
        end
    endfunction

    function automatic logic meta_4to8_valid(input logic [127:0] meta_i);
        integer group_idx;
        begin
            meta_4to8_valid = 1'b1;
            for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin
                if (popcount8(meta_i[group_idx*8 +: 8]) != 4'd4) begin
                    meta_4to8_valid = 1'b0;
                end
            end
        end
    endfunction

    function automatic logic [255:0] select_b_2to4_32(
        input logic [511:0] b_i,
        input logic [127:0] meta_i
    );
        integer group_idx;
        integer lane_idx;
        integer sel_idx;
        begin
            select_b_2to4_32 = '0;
            for (group_idx = 0; group_idx < 4; group_idx = group_idx + 1) begin
                sel_idx = 0;
                for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                    if (meta_i[group_idx*4 + lane_idx]) begin
                        if (sel_idx < 2) begin
                            select_b_2to4_32[(group_idx*2+sel_idx)*32 +: 32] =
                                b_i[(group_idx*4+lane_idx)*32 +: 32];
                        end
                        sel_idx = sel_idx + 1;
                    end
                end
            end
        end
    endfunction

    function automatic logic [255:0] select_b_2to4_16(
        input logic [511:0] b_i,
        input logic [127:0] meta_i
    );
        integer group_idx;
        integer lane_idx;
        integer sel_idx;
        begin
            select_b_2to4_16 = '0;
            for (group_idx = 0; group_idx < 8; group_idx = group_idx + 1) begin
                sel_idx = 0;
                for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                    if (meta_i[group_idx*4 + lane_idx]) begin
                        if (sel_idx < 2) begin
                            select_b_2to4_16[(group_idx*2+sel_idx)*16 +: 16] =
                                b_i[(group_idx*4+lane_idx)*16 +: 16];
                        end
                        sel_idx = sel_idx + 1;
                    end
                end
            end
        end
    endfunction

    function automatic logic [255:0] select_b_2to4_8(
        input logic [511:0] b_i,
        input logic [127:0] meta_i
    );
        integer group_idx;
        integer lane_idx;
        integer sel_idx;
        begin
            select_b_2to4_8 = '0;
            for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin
                sel_idx = 0;
                for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                    if (meta_i[group_idx*4 + lane_idx]) begin
                        if (sel_idx < 2) begin
                            select_b_2to4_8[(group_idx*2+sel_idx)*8 +: 8] =
                                b_i[(group_idx*4+lane_idx)*8 +: 8];
                        end
                        sel_idx = sel_idx + 1;
                    end
                end
            end
        end
    endfunction

    function automatic logic [255:0] select_b_2to4_6(
        input logic [511:0] b_i,
        input logic [127:0] meta_i
    );
        integer group_idx;
        integer lane_idx;
        integer sel_idx;
        begin
            select_b_2to4_6 = '0;
            for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin
                sel_idx = 0;
                for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                    if (meta_i[group_idx*4 + lane_idx]) begin
                        if (sel_idx < 2) begin
                            select_b_2to4_6[(group_idx*2+sel_idx)*6 +: 6] =
                                b_i[(group_idx*4+lane_idx)*6 +: 6];
                        end
                        sel_idx = sel_idx + 1;
                    end
                end
            end
        end
    endfunction

    function automatic logic [255:0] select_b_2to4_4(
        input logic [511:0] b_i,
        input logic [127:0] meta_i
    );
        integer group_idx;
        integer lane_idx;
        integer sel_idx;
        begin
            select_b_2to4_4 = '0;
            for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin
                sel_idx = 0;
                for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                    if (meta_i[group_idx*4 + lane_idx]) begin
                        if (sel_idx < 2) begin
                            select_b_2to4_4[(group_idx*2+sel_idx)*4 +: 4] =
                                b_i[(group_idx*4+lane_idx)*4 +: 4];
                        end
                        sel_idx = sel_idx + 1;
                    end
                end
            end
        end
    endfunction

    function automatic logic [255:0] select_b_4to8_4(
        input logic [511:0] b_i,
        input logic [127:0] meta_i
    );
        integer group_idx;
        integer lane_idx;
        integer sel_idx;
        begin
            select_b_4to8_4 = '0;
            for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin
                sel_idx = 0;
                for (lane_idx = 0; lane_idx < 8; lane_idx = lane_idx + 1) begin
                    if (meta_i[group_idx*8 + lane_idx]) begin
                        if (sel_idx < 4) begin
                            select_b_4to8_4[(group_idx*4+sel_idx)*4 +: 4] =
                                b_i[(group_idx*8+lane_idx)*4 +: 4];
                        end
                        sel_idx = sel_idx + 1;
                    end
                end
            end
        end
    endfunction

    function automatic logic [31:0] round_shift_rne_32(
        input logic [31:0] value_i,
        input integer      shift_i
    );
        logic [31:0] trunc;
        logic        guard;
        logic        sticky;
        logic [63:0] sticky_mask;
        begin
            if (shift_i <= 0) begin
                round_shift_rne_32 = value_i << (-shift_i);
            end else if (shift_i >= 32) begin
                round_shift_rne_32 = '0;
            end else begin
                trunc = value_i >> shift_i;
                guard = value_i[shift_i-1];
                if (shift_i > 1) begin
                    sticky_mask = (64'd1 << (shift_i - 1)) - 64'd1;
                    sticky = (({32'd0, value_i} & sticky_mask) != 64'd0);
                end else begin
                    sticky = 1'b0;
                end
                round_shift_rne_32 = trunc + (guard && (sticky || trunc[0]));
            end
        end
    endfunction

    function automatic logic [15:0] fp32_to_fp16_rne(
        input logic [31:0] fp32_i
    );
        logic sign;
        logic [7:0] exp_raw;
        logic [22:0] frac_raw;
        logic [23:0] mant24;
        logic [31:0] rounded;
        integer unbiased_exp;
        integer half_exp;
        integer sub_shift;
        begin
            sign = fp32_i[31];
            exp_raw = fp32_i[30:23];
            frac_raw = fp32_i[22:0];
            mant24 = {1'b1, frac_raw};
            unbiased_exp = int'(exp_raw) - 127;
            half_exp = unbiased_exp + 15;
            sub_shift = 0;
            rounded = '0;
            fp32_to_fp16_rne = {sign, 15'h0000};

            if (exp_raw == 8'hff) begin
                if (frac_raw != 23'h0) begin
                    fp32_to_fp16_rne = 16'h7fff;
                end else begin
                    fp32_to_fp16_rne = {sign, 5'h1f, 10'h000};
                end
            end else if (exp_raw == 8'h00 && frac_raw == 23'h0) begin
                fp32_to_fp16_rne = {sign, 15'h0000};
            end else if (half_exp >= 31) begin
                fp32_to_fp16_rne = {sign, 5'h1f, 10'h000};
            end else if (half_exp <= 0) begin
                if (half_exp < -10) begin
                    fp32_to_fp16_rne = {sign, 15'h0000};
                end else begin
                    sub_shift = 14 - half_exp;
                    rounded = round_shift_rne_32({8'd0, mant24}, sub_shift);
                    if (rounded[10]) begin
                        fp32_to_fp16_rne = {sign, 5'd1, 10'h000};
                    end else begin
                        fp32_to_fp16_rne = {sign, 5'd0, rounded[9:0]};
                    end
                end
            end else begin
                rounded = round_shift_rne_32({8'd0, mant24}, 13);
                if (rounded[11]) begin
                    half_exp = half_exp + 1;
                    if (half_exp >= 31) begin
                        fp32_to_fp16_rne = {sign, 5'h1f, 10'h000};
                    end else begin
                        fp32_to_fp16_rne = {sign, 5'(half_exp), 10'h000};
                    end
                end else begin
                    fp32_to_fp16_rne = {sign, 5'(half_exp), rounded[9:0]};
                end
            end
        end
    endfunction

    assign sparse_req = (op_i == TCGEN05_OP_SP) || (op_i == TCGEN05_OP_WS_SP);

    always_comb begin
        sparse_meta_valid = 1'b1;
        if (sparse_req) begin
            if ((kind_i == TCGEN05_KIND_MXF4) || (kind_i == TCGEN05_KIND_MXF4NVF4)) begin
                sparse_meta_valid = meta_4to8_valid(sparse_meta_i);
            end else if (kind_i == TCGEN05_KIND_TF32) begin
                sparse_meta_valid = meta_2to4_valid(sparse_meta_i, 4);
            end else if (kind_i == TCGEN05_KIND_F16) begin
                sparse_meta_valid = meta_2to4_valid(sparse_meta_i, 8);
            end else begin
                sparse_meta_valid = meta_2to4_valid(sparse_meta_i, 16);
            end
        end
    end

    assign f16tf32_supported =
        ((kind_i == TCGEN05_KIND_TF32) &&
         (scale_type_i == TCGEN05_SCALE_NONE) &&
         (scale_vec_i == TCGEN05_SCALE_VEC_NONE) &&
         (d_type_i == TCGEN05_TYPE_F32) &&
         (a_type_i == TCGEN05_TYPE_TF32) &&
         (b_type_i == TCGEN05_TYPE_TF32)) ||
        ((kind_i == TCGEN05_KIND_F16) &&
         (scale_type_i == TCGEN05_SCALE_NONE) &&
         (scale_vec_i == TCGEN05_SCALE_VEC_NONE) &&
         (((d_type_i == TCGEN05_TYPE_F16) &&
           (a_type_i == TCGEN05_TYPE_F16) &&
           (b_type_i == TCGEN05_TYPE_F16)) ||
          ((d_type_i == TCGEN05_TYPE_F32) &&
           ((a_type_i == TCGEN05_TYPE_F16) || (a_type_i == TCGEN05_TYPE_BF16)) &&
           ((b_type_i == TCGEN05_TYPE_F16) || (b_type_i == TCGEN05_TYPE_BF16)))));

    assign f4f6f8_supported =
        (((kind_i == TCGEN05_KIND_F8F6F4) &&
          (scale_type_i == TCGEN05_SCALE_NONE) &&
          (scale_vec_i == TCGEN05_SCALE_VEC_NONE) &&
          ((d_type_i == TCGEN05_TYPE_F32) || (d_type_i == TCGEN05_TYPE_F16)) &&
          ((a_type_i == TCGEN05_TYPE_E4M3) ||
           (a_type_i == TCGEN05_TYPE_E5M2) ||
           (a_type_i == TCGEN05_TYPE_E2M3) ||
           (a_type_i == TCGEN05_TYPE_E3M2) ||
           (a_type_i == TCGEN05_TYPE_E2M1)) &&
          ((b_type_i == TCGEN05_TYPE_E4M3) ||
           (b_type_i == TCGEN05_TYPE_E5M2) ||
           (b_type_i == TCGEN05_TYPE_E2M3) ||
           (b_type_i == TCGEN05_TYPE_E3M2) ||
           (b_type_i == TCGEN05_TYPE_E2M1))) ||
         ((kind_i == TCGEN05_KIND_MXF8F6F4) &&
          (d_type_i == TCGEN05_TYPE_F32) &&
          (scale_type_i == TCGEN05_SCALE_UE8M0) &&
          ((scale_vec_i == TCGEN05_SCALE_VEC_1X) ||
           (scale_vec_i == TCGEN05_SCALE_VEC_BLOCK32)) &&
          ((a_type_i == TCGEN05_TYPE_E4M3) ||
           (a_type_i == TCGEN05_TYPE_E5M2) ||
           (a_type_i == TCGEN05_TYPE_E2M3) ||
           (a_type_i == TCGEN05_TYPE_E3M2) ||
           (a_type_i == TCGEN05_TYPE_E2M1)) &&
          ((b_type_i == TCGEN05_TYPE_E4M3) ||
           (b_type_i == TCGEN05_TYPE_E5M2) ||
           (b_type_i == TCGEN05_TYPE_E2M3) ||
           (b_type_i == TCGEN05_TYPE_E3M2) ||
           (b_type_i == TCGEN05_TYPE_E2M1))));

    assign int8_supported =
        (kind_i == TCGEN05_KIND_I8) &&
        (scale_type_i == TCGEN05_SCALE_NONE) &&
        (scale_vec_i == TCGEN05_SCALE_VEC_NONE) &&
        (d_type_i == TCGEN05_TYPE_S32) &&
        ((a_type_i == TCGEN05_TYPE_S8) || (a_type_i == TCGEN05_TYPE_U8)) &&
        ((b_type_i == TCGEN05_TYPE_S8) || (b_type_i == TCGEN05_TYPE_U8));

    assign fp4_supported =
        ((kind_i == TCGEN05_KIND_MXF4) &&
         (d_type_i == TCGEN05_TYPE_F32) &&
         (a_type_i == TCGEN05_TYPE_E2M1) &&
         (b_type_i == TCGEN05_TYPE_E2M1) &&
         (scale_type_i == TCGEN05_SCALE_UE8M0) &&
         ((scale_vec_i == TCGEN05_SCALE_VEC_2X) ||
          (scale_vec_i == TCGEN05_SCALE_VEC_BLOCK32))) ||
        ((kind_i == TCGEN05_KIND_MXF4NVF4) &&
         (d_type_i == TCGEN05_TYPE_F32) &&
         (a_type_i == TCGEN05_TYPE_E2M1) &&
         (b_type_i == TCGEN05_TYPE_E2M1) &&
         (((scale_type_i == TCGEN05_SCALE_UE8M0) &&
           ((scale_vec_i == TCGEN05_SCALE_VEC_2X) ||
            (scale_vec_i == TCGEN05_SCALE_VEC_4X) ||
            (scale_vec_i == TCGEN05_SCALE_VEC_BLOCK16) ||
            (scale_vec_i == TCGEN05_SCALE_VEC_BLOCK32))) ||
          ((scale_type_i == TCGEN05_SCALE_UE4M3) &&
           ((scale_vec_i == TCGEN05_SCALE_VEC_4X) ||
            (scale_vec_i == TCGEN05_SCALE_VEC_BLOCK16)))));

    assign unsupported_req = !(f16tf32_supported || f4f6f8_supported || int8_supported || fp4_supported);
    assign invalid_sparse_meta = sparse_req && !sparse_meta_valid;
    assign err_path = unsupported_req || invalid_sparse_meta;

    assign f16tf32_sel = f16tf32_supported && !err_path;
    assign f4f6f8_sel = f4f6f8_supported && !err_path;
    assign int8_sel = int8_supported && !err_path;
    assign fp4_sel = fp4_supported && !err_path;

    always_comb begin
        selected_core = CORE_NONE;
        selected_is_fp4 = 1'b0;
        if (f16tf32_sel) begin
            selected_core = CORE_F16TF32;
        end else if (f4f6f8_sel) begin
            selected_core = CORE_F4F6F8;
        end else if (int8_sel) begin
            selected_core = CORE_INT8;
        end else if (fp4_sel) begin
            selected_core = CORE_FP4;
            selected_is_fp4 = 1'b1;
        end
    end

    assign b_tf32_core   = sparse_req ? select_b_2to4_32(b_vec_i, sparse_meta_i) : b_vec_i[255:0];
    assign b_fp16_core   = sparse_req ? select_b_2to4_16(b_vec_i, sparse_meta_i) : b_vec_i[255:0];
    assign b_f16tf32_core = (kind_i == TCGEN05_KIND_TF32) ? b_tf32_core : b_fp16_core;
    assign b_8b_core     = sparse_req ? select_b_2to4_8(b_vec_i, sparse_meta_i)  : b_vec_i[255:0];
    assign b_6b_core     = sparse_req ? select_b_2to4_6(b_vec_i, sparse_meta_i)  : b_vec_i[255:0];
    assign b_4b_core     = sparse_req ? select_b_2to4_4(b_vec_i, sparse_meta_i)  : b_vec_i[255:0];
    assign b_fp4_core    = sparse_req ? select_b_4to8_4(b_vec_i, sparse_meta_i) : b_vec_i[255:0];
    assign f4f6f8_b_vec  = (b_type_i == TCGEN05_TYPE_E2M1) ? b_4b_core :
                           (((b_type_i == TCGEN05_TYPE_E2M3) ||
                             (b_type_i == TCGEN05_TYPE_E3M2)) ? b_6b_core : b_8b_core);

    assign f16tf32_a_dtype = (kind_i == TCGEN05_KIND_TF32) ? DOT_F16TF32_DTYPE_TF32 :
                           ((a_type_i == TCGEN05_TYPE_BF16) ? DOT_F16TF32_DTYPE_BF16 :
                                                              DOT_F16TF32_DTYPE_FP16);
    assign f16tf32_b_dtype = (kind_i == TCGEN05_KIND_TF32) ? DOT_F16TF32_DTYPE_TF32 :
                           ((b_type_i == TCGEN05_TYPE_BF16) ? DOT_F16TF32_DTYPE_BF16 :
                                                              DOT_F16TF32_DTYPE_FP16);

    always_comb begin
        f4f6f8_a_dtype = DOT_F4F6F8_DTYPE_E4M3;
        case (a_type_i)
            TCGEN05_TYPE_E5M2: f4f6f8_a_dtype = DOT_F4F6F8_DTYPE_E5M2;
            TCGEN05_TYPE_E2M3: f4f6f8_a_dtype = DOT_F4F6F8_DTYPE_E2M3;
            TCGEN05_TYPE_E3M2: f4f6f8_a_dtype = DOT_F4F6F8_DTYPE_E3M2;
            TCGEN05_TYPE_E2M1: f4f6f8_a_dtype = DOT_F4F6F8_DTYPE_E2M1;
            default:           f4f6f8_a_dtype = DOT_F4F6F8_DTYPE_E4M3;
        endcase
    end

    always_comb begin
        f4f6f8_b_dtype = DOT_F4F6F8_DTYPE_E4M3;
        case (b_type_i)
            TCGEN05_TYPE_E5M2: f4f6f8_b_dtype = DOT_F4F6F8_DTYPE_E5M2;
            TCGEN05_TYPE_E2M3: f4f6f8_b_dtype = DOT_F4F6F8_DTYPE_E2M3;
            TCGEN05_TYPE_E3M2: f4f6f8_b_dtype = DOT_F4F6F8_DTYPE_E3M2;
            TCGEN05_TYPE_E2M1: f4f6f8_b_dtype = DOT_F4F6F8_DTYPE_E2M1;
            default:           f4f6f8_b_dtype = DOT_F4F6F8_DTYPE_E4M3;
        endcase
    end

    assign f4f6f8_mx_en = (kind_i == TCGEN05_KIND_MXF8F6F4);

    assign fp4_mode = (scale_type_i == TCGEN05_SCALE_UE4M3) ? DOT_FP4_MODE_NVFP4 :
                      (((scale_type_i == TCGEN05_SCALE_UE8M0) &&
                        ((scale_vec_i == TCGEN05_SCALE_VEC_4X) ||
                         (scale_vec_i == TCGEN05_SCALE_VEC_BLOCK16))) ? DOT_FP4_MODE_MXFP4_4X :
                       ((scale_type_i == TCGEN05_SCALE_UE8M0) ? DOT_FP4_MODE_MXFP4 :
                                                                DOT_FP4_MODE_FP4));

    assign c_core = enable_input_d_i ? c_i : 32'h0000_0000;

    assign in_rdy_o = ((count_q < COUNT_W'(INFLIGHT)) || retire_fire) &&
                      (err_path ||
                       (f16tf32_sel && f16tf32_in_rdy) ||
                       (f4f6f8_sel && f4f6f8_in_rdy) ||
                       (int8_sel && int8_in_rdy) ||
                       (fp4_sel && fp4_in_rdy));

    assign issue_fire = in_vld_i && in_rdy_o;

    assign f16tf32_in_vld = issue_fire && f16tf32_sel;
    assign f4f6f8_in_vld   = issue_fire && f4f6f8_sel;
    assign int8_in_vld   = issue_fire && int8_sel;
    assign fp4_in_vld    = issue_fire && fp4_sel;
    assign int8_a_unsigned = (a_type_i == TCGEN05_TYPE_U8);
    assign int8_b_unsigned = (b_type_i == TCGEN05_TYPE_U8);

    f16tf32_dot_prod u_f16tf32_dot_prod (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_vld_i (f16tf32_in_vld),
        .in_rdy_o (f16tf32_in_rdy),
        .a_dtype_i (f16tf32_a_dtype),
        .b_dtype_i (f16tf32_b_dtype),
        .a_vec_i  (a_vec_i),
        .b_vec_i  (b_f16tf32_core),
        .c_i      (c_core),
        .scale_input_d_i(scale_input_d_i),
        .out_vld_o(f16tf32_out_vld),
        .out_rdy_i(f16tf32_out_rdy),
        .d_o      (f16tf32_d)
    );

    f4f6f8_dot_prod u_f4f6f8_dot_prod (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_vld_i    (f4f6f8_in_vld),
        .in_rdy_o    (f4f6f8_in_rdy),
        .a_vec_i     (a_vec_i),
        .b_vec_i     (f4f6f8_b_vec),
        .c_i         (c_core),
        .a_dtype_i    (f4f6f8_a_dtype),
        .b_dtype_i    (f4f6f8_b_dtype),
        .mxfp8_en_i  (f4f6f8_mx_en),
        .a_mx_scale_i(a_sf_i[7:0]),
        .b_mx_scale_i(b_sf_i[7:0]),
        .out_vld_o   (f4f6f8_out_vld),
        .out_rdy_i   (f4f6f8_out_rdy),
        .d_o         (f4f6f8_d)
    );

    int8_dot_prod u_int8_dot_prod (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_vld_i    (int8_in_vld),
        .in_rdy_o    (int8_in_rdy),
        .a_vec_i     (a_vec_i),
        .b_vec_i     (b_8b_core),
        .c_i         (c_core),
        .a_unsigned_i(int8_a_unsigned),
        .b_unsigned_i(int8_b_unsigned),
        .sat_en_i    (1'b0),
        .out_vld_o   (int8_out_vld),
        .out_rdy_i   (int8_out_rdy),
        .d_o         (int8_d),
        .overflow_o  (int8_overflow)
    );

    fp4_dot_prod u_fp4_dot_prod (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_vld_i  (fp4_in_vld),
        .in_rdy_o  (fp4_in_rdy),
        .a_fp4_i   (a_vec_i),
        .b_fp4_i   (b_fp4_core),
        .fp4_mode_i(fp4_mode),
        .a_sf_i    (a_sf_i),
        .b_sf_i    (b_sf_i),
        .c_fp32_i  (c_core),
        .out_vld_o (fp4_out_vld),
        .out_rdy_i (fp4_out_rdy),
        .d_fp32_o  (fp4_d)
    );

    // Each arithmetic pipeline preserves its own order. This issue-order FIFO
    // selects the matching result and metadata even when core latencies differ.
    // Non-head cores retain their results using their native elastic pipelines.
    assign f16tf32_out_rdy = out_rdy_i && (count_q != 0) && head.error == 0 &&
        head.core == CORE_F16TF32 && !head.fp4;
    assign f4f6f8_out_rdy = out_rdy_i && (count_q != 0) && head.error == 0 &&
        head.core == CORE_F4F6F8;
    assign int8_out_rdy = out_rdy_i && (count_q != 0) && head.error == 0 &&
        head.core == CORE_INT8;
    assign fp4_out_rdy = out_rdy_i && (count_q != 0) && head.error == 0 && head.fp4;

    always_comb begin
        out_vld_o = 1'b0;
        d_o = '0;
        status_o = head.error;
        if (count_q != 0) begin
            if (head.error != 0) out_vld_o = 1'b1;
            else if (head.fp4) begin
                out_vld_o = fp4_out_vld;
                d_o = fp4_d;
            end else case (head.core)
                CORE_F16TF32: begin
                    out_vld_o = f16tf32_out_vld;
                    d_o = (head.dtype == TCGEN05_TYPE_F16) ?
                        {16'd0, fp32_to_fp16_rne(f16tf32_d)} : f16tf32_d;
                end
                CORE_F4F6F8: begin
                    out_vld_o = f4f6f8_out_vld;
                    d_o = (head.dtype == TCGEN05_TYPE_F16) ?
                        {16'd0, fp32_to_fp16_rne(f4f6f8_d)} : f4f6f8_d;
                end
                CORE_INT8: begin
                    out_vld_o = int8_out_vld;
                    d_o = int8_d;
                    status_o = int8_overflow ? TCGEN05_STATUS_INT_OVERFLOW : TCGEN05_STATUS_OK;
                end
                default: begin end
            endcase
        end
    end
    assign retire_fire = out_vld_o && out_rdy_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_q <= '0;
            wr_q <= '0;
            count_q <= '0;
        end else begin
            case ({issue_fire, retire_fire})
                2'b10: count_q <= count_q + COUNT_W'(1);
                2'b01: count_q <= count_q - COUNT_W'(1);
                default: begin end
            endcase
            if (issue_fire) begin
                meta_q[wr_q].core <= selected_core;
                meta_q[wr_q].fp4 <= selected_is_fp4;
                meta_q[wr_q].dtype <= d_type_i;
                meta_q[wr_q].tag <= tag_i;
                meta_q[wr_q].error <= invalid_sparse_meta ? TCGEN05_STATUS_INVALID_SPARSE_META :
                    (unsupported_req ? TCGEN05_STATUS_UNSUPPORTED : TCGEN05_STATUS_OK);
                wr_q <= (wr_q == PTR_W'(INFLIGHT-1)) ? '0 : wr_q + PTR_W'(1);
            end
            if (retire_fire) rd_q <= (rd_q == PTR_W'(INFLIGHT-1)) ? '0 : rd_q + PTR_W'(1);
        end
    end
    initial begin
        if (INFLIGHT < 1 || TAG_W < 1) $error("Invalid adapter queue parameters");
    end
endmodule
