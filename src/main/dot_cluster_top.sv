// ============================================================================
// File Name   : dot_cluster_top.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-29
// Description : Multi-precision dot-product cluster wrapper with B-side
//               structured sparse operand selection and dtype dispatch.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-29  v0.1      LIU YUXUAN       Initial version
// ============================================================================

module dot_cluster_top #(
    parameter int TAG_W = 8
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              in_vld_i,
    output logic              in_rdy_o,
    input  logic [3:0]        req_dtype_i,
    input  logic              req_sparse_en_i,
    input  logic [255:0]      req_a_packed_i,
    input  logic [511:0]      req_b_packed_i,
    input  logic [127:0]      req_meta_i,
    input  logic [31:0]       req_c_i,
    input  logic [TAG_W-1:0]  req_tag_i,

    input  logic              req_mxfp8_en_i,
    input  logic [7:0]        req_a_mx_scale_i,
    input  logic [7:0]        req_b_mx_scale_i,
    input  logic              req_a_unsigned_i,
    input  logic              req_b_unsigned_i,
    input  logic              req_int_sat_en_i,
    input  logic [1:0]        req_fp4_mode_i,
    input  logic [31:0]       req_a_sf_i,
    input  logic [31:0]       req_b_sf_i,

    output logic              out_vld_o,
    input  logic              out_rdy_i,
    output logic [31:0]       out_d_o,
    output logic [7:0]        out_status_o,
    output logic [TAG_W-1:0]  out_tag_o
);

    import dot_prod_pkg::*;

    localparam logic [3:0] DTYPE_TF32    = 4'd0;
    localparam logic [3:0] DTYPE_BF16    = 4'd1;
    localparam logic [3:0] DTYPE_FP16    = 4'd2;
    localparam logic [3:0] DTYPE_FP8_E4M3 = 4'd3;
    localparam logic [3:0] DTYPE_FP8_E5M2 = 4'd4;
    localparam logic [3:0] DTYPE_INT8    = 4'd5;
    localparam logic [3:0] DTYPE_FP4     = 4'd6;
    localparam logic [3:0] DTYPE_FP6_E3M2 = 4'd7;
    localparam logic [3:0] DTYPE_FP6_E2M3 = 4'd8;

    // Share groups represent physical arithmetic datapath ownership.
    // TF32/BF16/FP16 share the F16TF32 16-lane 11x11 datapath.
    localparam logic [2:0] SHARE_GROUP_NONE  = 3'd0;
    localparam logic [2:0] SHARE_GROUP_F16TF32 = 3'd1;
    localparam logic [2:0] SHARE_GROUP_F4F6F8  = 3'd2;
    localparam logic [2:0] SHARE_GROUP_INT8  = 3'd3;
    localparam logic [2:0] SHARE_GROUP_FP4   = 3'd4;

    localparam logic [7:0] STATUS_OK                  = 8'h00;
    localparam logic [7:0] STATUS_INVALID_SPARSE_META = 8'h01;
    localparam logic [7:0] STATUS_UNSUPPORTED_DTYPE   = 8'h02;
    localparam logic [7:0] STATUS_INT_OVERFLOW        = 8'h04;

    localparam int RSP_META_W = TAG_W + 8;

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

    function automatic logic supported_dtype(input logic [3:0] dtype_i);
        begin
            case (dtype_i)
                DTYPE_TF32,
                DTYPE_BF16,
                DTYPE_FP16,
                DTYPE_FP8_E4M3,
                DTYPE_FP8_E5M2,
                DTYPE_FP6_E3M2,
                DTYPE_FP6_E2M3,
                DTYPE_INT8,
                DTYPE_FP4: supported_dtype = 1'b1;
                default:   supported_dtype = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [2:0] dtype_share_group(input logic [3:0] dtype_i);
        begin
            case (dtype_i)
                DTYPE_TF32,
                DTYPE_BF16,
                DTYPE_FP16: dtype_share_group = SHARE_GROUP_F16TF32;
                DTYPE_FP8_E4M3,
                DTYPE_FP8_E5M2,
                DTYPE_FP6_E3M2,
                DTYPE_FP6_E2M3: dtype_share_group = SHARE_GROUP_F4F6F8;
                DTYPE_INT8:     dtype_share_group = SHARE_GROUP_INT8;
                DTYPE_FP4:      dtype_share_group = SHARE_GROUP_FP4;
                default:        dtype_share_group = SHARE_GROUP_NONE;
            endcase
        end
    endfunction

    function automatic logic meta_valid_by_dtype(
        input logic [3:0]   dtype_i,
        input logic [127:0] meta_i
    );
        begin
            case (dtype_i)
                DTYPE_TF32: meta_valid_by_dtype = meta_2to4_valid(meta_i, 4);
                DTYPE_BF16,
                DTYPE_FP16: meta_valid_by_dtype = meta_2to4_valid(meta_i, 8);
                DTYPE_FP8_E4M3,
                DTYPE_FP8_E5M2,
                DTYPE_FP6_E3M2,
                DTYPE_FP6_E2M3,
                DTYPE_INT8: meta_valid_by_dtype = meta_2to4_valid(meta_i, 16);
                DTYPE_FP4:  meta_valid_by_dtype = meta_4to8_valid(meta_i);
                default:    meta_valid_by_dtype = 1'b0;
            endcase
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

    typedef struct packed {
        logic [3:0]        dtype;
        logic              sparse_en;
        logic [255:0]      a_packed;
        logic [511:0]      b_packed;
        logic [127:0]      meta;
        logic [31:0]       c;
        logic [TAG_W-1:0]  tag;
        logic              mxfp8_en;
        logic [7:0]        a_mx_scale;
        logic [7:0]        b_mx_scale;
        logic              a_unsigned;
        logic              b_unsigned;
        logic              int_sat_en;
        logic [1:0]        fp4_mode;
        logic [31:0]       a_sf;
        logic [31:0]       b_sf;
    } ingress_payload_t;

    typedef struct packed {
        logic              err_path;
        logic [7:0]        status;
        logic [2:0]        share_group;
        logic              f16tf32_sel;
        logic              f4f6f8_sel;
        logic              int8_sel;
        logic              fp4_sel;
        logic [1:0]        f16tf32_dtype;
        logic [2:0]        f4f6f8_dtype;
        logic [255:0]      a_vec;
        logic [255:0]      b_vec;
        logic [31:0]       c;
        logic [TAG_W-1:0]  tag;
        logic              mxfp8_en;
        logic [7:0]        a_mx_scale;
        logic [7:0]        b_mx_scale;
        logic              a_unsigned;
        logic              b_unsigned;
        logic              int_sat_en;
        logic [1:0]        fp4_mode;
        logic [31:0]       a_sf;
        logic [31:0]       b_sf;
    } issue_payload_t;

    ingress_payload_t ingress_payload_q;
    issue_payload_t   issue_payload_q;
    issue_payload_t   issue_payload_d;

    logic        ingress_vld_q;
    logic        ingress_rdy;
    logic        ingress_fire;
    logic        ingress_to_issue_fire;
    logic        issue_vld_q;
    logic        issue_in_rdy;
    logic        issue_load_fire;
    logic        issue_out_rdy;
    logic        issue_out_fire;

    logic        ingress_req_supported;
    logic        ingress_req_meta_valid;
    logic        ingress_invalid_sparse_meta;
    logic        ingress_unsupported_dtype;
    logic        ingress_err_path;
    logic [2:0]  ingress_req_share_group;
    logic [2:0]  active_share_group_q;
    logic [7:0]  outstanding_q;
    logic        share_group_allow;

    logic [255:0] ingress_b_tf32_core;
    logic [255:0] ingress_b_fp16_core;
    logic [255:0] ingress_b_f16tf32_core;
    logic [255:0] ingress_b_8b_lane_core;
    logic [255:0] ingress_b_fp6_core;
    logic [255:0] ingress_b_fp4_core;

    logic ingress_tf32_sel;
    logic ingress_fp16_sel;
    logic ingress_f16tf32_sel;
    logic ingress_f4f6f8_sel;
    logic ingress_fp6_sel;
    logic ingress_int8_sel;
    logic ingress_fp4_sel;
    logic [1:0] ingress_f16tf32_dtype;
    logic [2:0] ingress_f4f6f8_dtype;

    logic shared_fp_in_rdy;
    logic int8_in_rdy;
    logic fp4_in_rdy;

    logic int8_meta_in_rdy;
    logic fp4_meta_in_rdy;

    logic selected_core_rdy;
    logic core_req_fire;
    logic err_can_accept;
    logic err_out_rdy;
    logic err_out_fire;

    logic shared_fp_in_vld;
    logic shared_fp_mode;
    logic int8_in_vld;
    logic fp4_in_vld;

    logic shared_fp_out_vld;
    logic int8_out_vld;
    logic fp4_out_vld;

    logic shared_fp_out_rdy;
    logic int8_out_rdy;
    logic fp4_out_rdy;

    logic [31:0] shared_fp_d;
    logic [31:0] int8_d;
    logic [31:0] fp4_d;
    logic        int8_overflow;

    logic int8_meta_vld;
    logic fp4_meta_vld;
    logic [RSP_META_W-1:0] shared_fp_meta;
    logic [RSP_META_W-1:0] int8_meta;
    logic [RSP_META_W-1:0] fp4_meta;
    logic [RSP_META_W-1:0] req_rsp_meta;

    logic err_vld_q;
    logic [31:0] err_d_q;
    logic [7:0] err_status_q;
    logic [TAG_W-1:0] err_tag_q;

    logic arb_err_sel;
    logic arb_shared_fp_sel;
    logic arb_int8_sel;
    logic arb_fp4_sel;

    logic [7:0] outstanding_nxt;
    logic core_rsp_fire;

    assign ingress_fire          = in_vld_i && in_rdy_o;
    assign ingress_to_issue_fire = ingress_vld_q && issue_in_rdy;
    assign issue_load_fire       = ingress_to_issue_fire;
    assign issue_in_rdy          = !issue_vld_q || issue_out_fire;
    assign issue_out_fire        = issue_vld_q && issue_out_rdy;
    assign ingress_rdy           = !ingress_vld_q || ingress_to_issue_fire;
    assign in_rdy_o              = ingress_rdy;

    assign ingress_req_supported       = supported_dtype(ingress_payload_q.dtype);
    assign ingress_req_meta_valid      = (!ingress_payload_q.sparse_en) ||
                                         meta_valid_by_dtype(ingress_payload_q.dtype,
                                                             ingress_payload_q.meta);
    assign ingress_invalid_sparse_meta = ingress_payload_q.sparse_en &&
                                         ingress_req_supported &&
                                         !ingress_req_meta_valid;
    assign ingress_unsupported_dtype   = !ingress_req_supported;
    assign ingress_err_path            = ingress_unsupported_dtype ||
                                         ingress_invalid_sparse_meta;
    assign ingress_req_share_group     = dtype_share_group(ingress_payload_q.dtype);

    assign ingress_b_tf32_core    = ingress_payload_q.sparse_en ?
                                    select_b_2to4_32(ingress_payload_q.b_packed,
                                                     ingress_payload_q.meta) :
                                    ingress_payload_q.b_packed[255:0];
    assign ingress_b_fp16_core    = ingress_payload_q.sparse_en ?
                                    select_b_2to4_16(ingress_payload_q.b_packed,
                                                     ingress_payload_q.meta) :
                                    ingress_payload_q.b_packed[255:0];
    assign ingress_b_f16tf32_core  = ingress_tf32_sel ? ingress_b_tf32_core :
                                                       ingress_b_fp16_core;
    assign ingress_b_8b_lane_core = ingress_payload_q.sparse_en ?
                                    select_b_2to4_8(ingress_payload_q.b_packed,
                                                    ingress_payload_q.meta) :
                                    ingress_payload_q.b_packed[255:0];
    assign ingress_b_fp6_core     = ingress_payload_q.sparse_en ?
                                    select_b_2to4_6(ingress_payload_q.b_packed,
                                                    ingress_payload_q.meta) :
                                    ingress_payload_q.b_packed[255:0];
    assign ingress_b_fp4_core     = ingress_payload_q.sparse_en ?
                                    select_b_4to8_4(ingress_payload_q.b_packed,
                                                    ingress_payload_q.meta) :
                                    ingress_payload_q.b_packed[255:0];

    assign ingress_tf32_sel     = (ingress_payload_q.dtype == DTYPE_TF32);
    assign ingress_fp16_sel     = (ingress_payload_q.dtype == DTYPE_FP16) ||
                                  (ingress_payload_q.dtype == DTYPE_BF16);
    assign ingress_f16tf32_sel   = ingress_tf32_sel || ingress_fp16_sel;
    assign ingress_fp6_sel      = (ingress_payload_q.dtype == DTYPE_FP6_E3M2) ||
                                  (ingress_payload_q.dtype == DTYPE_FP6_E2M3);
    assign ingress_f4f6f8_sel   = (ingress_payload_q.dtype == DTYPE_FP8_E4M3) ||
                                  (ingress_payload_q.dtype == DTYPE_FP8_E5M2) ||
                                  ingress_fp6_sel;
    assign ingress_int8_sel     = (ingress_payload_q.dtype == DTYPE_INT8);
    assign ingress_fp4_sel      = (ingress_payload_q.dtype == DTYPE_FP4);
    assign ingress_f16tf32_dtype = ingress_tf32_sel ? DOT_F16TF32_DTYPE_TF32 :
                                  ((ingress_payload_q.dtype == DTYPE_BF16) ?
                                   DOT_F16TF32_DTYPE_BF16 : DOT_F16TF32_DTYPE_FP16);
    assign ingress_f4f6f8_dtype = (ingress_payload_q.dtype == DTYPE_FP8_E5M2) ?
                                  DOT_F4F6F8_DTYPE_E5M2 :
                                  (ingress_payload_q.dtype == DTYPE_FP6_E2M3) ?
                                  DOT_F4F6F8_DTYPE_E2M3 :
                                  (ingress_payload_q.dtype == DTYPE_FP6_E3M2) ?
                                  DOT_F4F6F8_DTYPE_E3M2 :
                                  DOT_F4F6F8_DTYPE_E4M3;

    always_comb begin
        issue_payload_d = '0;

        issue_payload_d.err_path      = ingress_err_path;
        issue_payload_d.status        = ingress_unsupported_dtype ? STATUS_UNSUPPORTED_DTYPE :
                                        (ingress_invalid_sparse_meta ?
                                         STATUS_INVALID_SPARSE_META : STATUS_OK);
        issue_payload_d.share_group   = ingress_req_share_group;
        issue_payload_d.f16tf32_sel    = ingress_f16tf32_sel && !ingress_err_path;
        issue_payload_d.f4f6f8_sel    = ingress_f4f6f8_sel && !ingress_err_path;
        issue_payload_d.int8_sel      = ingress_int8_sel && !ingress_err_path;
        issue_payload_d.fp4_sel       = ingress_fp4_sel && !ingress_err_path;
        issue_payload_d.f16tf32_dtype  = ingress_f16tf32_dtype;
        issue_payload_d.f4f6f8_dtype  = ingress_f4f6f8_dtype;
        issue_payload_d.a_vec         = ingress_payload_q.a_packed;
        issue_payload_d.c             = ingress_payload_q.c;
        issue_payload_d.tag           = ingress_payload_q.tag;
        issue_payload_d.mxfp8_en      = ingress_payload_q.mxfp8_en;
        issue_payload_d.a_mx_scale    = ingress_payload_q.a_mx_scale;
        issue_payload_d.b_mx_scale    = ingress_payload_q.b_mx_scale;
        issue_payload_d.a_unsigned    = ingress_payload_q.a_unsigned;
        issue_payload_d.b_unsigned    = ingress_payload_q.b_unsigned;
        issue_payload_d.int_sat_en    = ingress_payload_q.int_sat_en;
        issue_payload_d.fp4_mode      = ingress_payload_q.fp4_mode;
        issue_payload_d.a_sf          = ingress_payload_q.a_sf;
        issue_payload_d.b_sf          = ingress_payload_q.b_sf;

        if (ingress_f16tf32_sel) begin
            issue_payload_d.b_vec = ingress_b_f16tf32_core;
        end else if (ingress_f4f6f8_sel) begin
            issue_payload_d.b_vec = ingress_fp6_sel ? ingress_b_fp6_core :
                                                     ingress_b_8b_lane_core;
        end else if (ingress_int8_sel) begin
            issue_payload_d.b_vec = ingress_b_8b_lane_core;
        end else if (ingress_fp4_sel) begin
            issue_payload_d.b_vec = ingress_b_fp4_core;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ingress_vld_q     <= 1'b0;
            ingress_payload_q <= '0;
        end else begin
            if (ingress_fire) begin
                ingress_vld_q                  <= 1'b1;
                ingress_payload_q.dtype        <= req_dtype_i;
                ingress_payload_q.sparse_en    <= req_sparse_en_i;
                ingress_payload_q.a_packed     <= req_a_packed_i;
                ingress_payload_q.b_packed     <= req_b_packed_i;
                ingress_payload_q.meta         <= req_meta_i;
                ingress_payload_q.c            <= req_c_i;
                ingress_payload_q.tag          <= req_tag_i;
                ingress_payload_q.mxfp8_en     <= req_mxfp8_en_i;
                ingress_payload_q.a_mx_scale   <= req_a_mx_scale_i;
                ingress_payload_q.b_mx_scale   <= req_b_mx_scale_i;
                ingress_payload_q.a_unsigned   <= req_a_unsigned_i;
                ingress_payload_q.b_unsigned   <= req_b_unsigned_i;
                ingress_payload_q.int_sat_en   <= req_int_sat_en_i;
                ingress_payload_q.fp4_mode     <= req_fp4_mode_i;
                ingress_payload_q.a_sf         <= req_a_sf_i;
                ingress_payload_q.b_sf         <= req_b_sf_i;
            end else if (ingress_to_issue_fire) begin
                ingress_vld_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_vld_q     <= 1'b0;
            issue_payload_q <= '0;
        end else begin
            if (issue_load_fire) begin
                issue_vld_q     <= 1'b1;
                issue_payload_q <= issue_payload_d;
            end else if (issue_out_fire) begin
                issue_vld_q <= 1'b0;
            end
        end
    end

    assign share_group_allow = (outstanding_q == 8'd0) ||
                               (issue_payload_q.share_group == active_share_group_q);

    always_comb begin
        selected_core_rdy = 1'b0;
        if (issue_payload_q.f16tf32_sel || issue_payload_q.f4f6f8_sel) begin
            selected_core_rdy = shared_fp_in_rdy;
        end else if (issue_payload_q.int8_sel) begin
            selected_core_rdy = int8_in_rdy && int8_meta_in_rdy;
        end else if (issue_payload_q.fp4_sel) begin
            selected_core_rdy = fp4_in_rdy && fp4_meta_in_rdy;
        end
    end

    assign err_can_accept = !err_vld_q || err_out_fire;
    assign issue_out_rdy = issue_payload_q.err_path ? err_can_accept :
                                                     (share_group_allow && selected_core_rdy);
    assign core_req_fire = issue_out_fire && !issue_payload_q.err_path;

    assign shared_fp_in_vld = core_req_fire &&
                              (issue_payload_q.f16tf32_sel || issue_payload_q.f4f6f8_sel);
    assign shared_fp_mode   = issue_payload_q.f4f6f8_sel;
    assign int8_in_vld      = core_req_fire && issue_payload_q.int8_sel;
    assign fp4_in_vld       = core_req_fire && issue_payload_q.fp4_sel;

    assign req_rsp_meta = {issue_payload_q.tag, STATUS_OK};

    f16tf32_f4f6f8_shared_dot_prod #(
        .META_W(RSP_META_W)
    ) u_f16tf32_f4f6f8_shared_dot_prod (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_vld_i    (shared_fp_in_vld),
        .in_rdy_o    (shared_fp_in_rdy),
        .mode_i      (shared_fp_mode),
        .f16tf32_dtype_i(issue_payload_q.f16tf32_dtype),
        .f4f6f8_dtype_i(issue_payload_q.f4f6f8_dtype),
        .a_vec_i     (issue_payload_q.a_vec),
        .b_vec_i     (issue_payload_q.b_vec),
        .c_i         (issue_payload_q.c),
        .scale_input_d_i(4'd0),
        .mxfp8_en_i  (issue_payload_q.mxfp8_en),
        .a_mx_scale_i(issue_payload_q.a_mx_scale),
        .b_mx_scale_i(issue_payload_q.b_mx_scale),
        .meta_i      (req_rsp_meta),
        .out_vld_o   (shared_fp_out_vld),
        .out_rdy_i   (shared_fp_out_rdy),
        .d_o         (shared_fp_d),
        .meta_o      (shared_fp_meta)
    );

    int8_dot_prod u_int8_dot_prod (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_vld_i    (int8_in_vld),
        .in_rdy_o    (int8_in_rdy),
        .a_vec_i     (issue_payload_q.a_vec),
        .b_vec_i     (issue_payload_q.b_vec),
        .c_i         (issue_payload_q.c),
        .a_unsigned_i(issue_payload_q.a_unsigned),
        .b_unsigned_i(issue_payload_q.b_unsigned),
        .sat_en_i    (issue_payload_q.int_sat_en),
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
        .a_fp4_i   (issue_payload_q.a_vec),
        .b_fp4_i   (issue_payload_q.b_vec),
        .fp4_mode_i(issue_payload_q.fp4_mode),
        .a_sf_i    (issue_payload_q.a_sf),
        .b_sf_i    (issue_payload_q.b_sf),
        .c_fp32_i  (issue_payload_q.c),
        .out_vld_o (fp4_out_vld),
        .out_rdy_i (fp4_out_rdy),
        .d_fp32_o  (fp4_d)
    );

    dot_rsp_meta_pipe #(
        .W      (RSP_META_W),
        .STAGES (3)
    ) u_int8_meta_pipe (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_vld_i     (int8_in_vld),
        .in_rdy_o     (int8_meta_in_rdy),
        .in_data_i    (req_rsp_meta),
        .out_vld_o    (int8_meta_vld),
        .out_rdy_i    (int8_out_rdy),
        .out_data_o   (int8_meta)
    );

    dot_rsp_meta_pipe #(
        .W      (RSP_META_W),
        .STAGES (5)
    ) u_fp4_meta_pipe (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_vld_i     (fp4_in_vld),
        .in_rdy_o     (fp4_meta_in_rdy),
        .in_data_i    (req_rsp_meta),
        .out_vld_o    (fp4_meta_vld),
        .out_rdy_i    (fp4_out_rdy),
        .out_data_o   (fp4_meta)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_vld_q    <= 1'b0;
            err_d_q      <= 32'h0000_0000;
            err_status_q <= STATUS_OK;
            err_tag_q    <= '0;
        end else begin
            if (issue_out_fire && issue_payload_q.err_path) begin
                err_vld_q    <= 1'b1;
                err_d_q      <= issue_payload_q.c;
                err_status_q <= issue_payload_q.status;
                err_tag_q    <= issue_payload_q.tag;
            end else if (err_out_fire) begin
                err_vld_q <= 1'b0;
            end
        end
    end

    assign arb_err_sel       = err_vld_q;
    assign arb_shared_fp_sel = !arb_err_sel && shared_fp_out_vld;
    assign arb_int8_sel      = !arb_err_sel && !arb_shared_fp_sel && int8_out_vld;
    assign arb_fp4_sel       = !arb_err_sel && !arb_shared_fp_sel &&
                               !arb_int8_sel && fp4_out_vld;

    assign err_out_rdy       = out_rdy_i && arb_err_sel;
    assign shared_fp_out_rdy = out_rdy_i && arb_shared_fp_sel;
    assign int8_out_rdy      = out_rdy_i && arb_int8_sel;
    assign fp4_out_rdy       = out_rdy_i && arb_fp4_sel;
    assign err_out_fire = err_vld_q && err_out_rdy;

    assign out_vld_o = err_vld_q || shared_fp_out_vld || int8_out_vld || fp4_out_vld;

    always_comb begin
        out_d_o      = 32'h0000_0000;
        out_status_o = STATUS_OK;
        out_tag_o    = '0;

        if (arb_err_sel) begin
            out_d_o      = err_d_q;
            out_status_o = err_status_q;
            out_tag_o    = err_tag_q;
        end else if (arb_shared_fp_sel) begin
            out_d_o      = shared_fp_d;
            out_status_o = shared_fp_meta[7:0];
            out_tag_o    = shared_fp_meta[RSP_META_W-1:8];
        end else if (arb_int8_sel) begin
            out_d_o      = int8_d;
            out_status_o = int8_meta[7:0] | (int8_overflow ? STATUS_INT_OVERFLOW : STATUS_OK);
            out_tag_o    = int8_meta[RSP_META_W-1:8];
        end else if (arb_fp4_sel) begin
            out_d_o      = fp4_d;
            out_status_o = fp4_meta[7:0];
            out_tag_o    = fp4_meta[RSP_META_W-1:8];
        end
    end

    assign core_rsp_fire = (shared_fp_out_vld && shared_fp_out_rdy) ||
                           (int8_out_vld && int8_out_rdy) ||
                           (fp4_out_vld  && fp4_out_rdy);

    always_comb begin
        outstanding_nxt = outstanding_q;
        if (core_req_fire && !core_rsp_fire) begin
            outstanding_nxt = outstanding_q + 8'd1;
        end else if (!core_req_fire && core_rsp_fire) begin
            outstanding_nxt = outstanding_q - 8'd1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            outstanding_q   <= 8'd0;
            active_share_group_q <= SHARE_GROUP_NONE;
        end else begin
            outstanding_q <= outstanding_nxt;

            if (outstanding_q == 8'd0 && core_req_fire) begin
                active_share_group_q <= issue_payload_q.share_group;
            end else if (outstanding_nxt == 8'd0) begin
                active_share_group_q <= SHARE_GROUP_NONE;
            end
        end
    end

endmodule

module dot_rsp_meta_pipe #(
    parameter int W = 16,
    parameter int STAGES = 1
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic [W-1:0] in_data_i,
    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [W-1:0] out_data_o
);

    logic [STAGES:0]         vld;
    logic [STAGES:0]         rdy;
    logic [STAGES:0][W-1:0]  data;

    assign vld[0]      = in_vld_i;
    assign in_rdy_o    = rdy[0];
    assign data[0]     = in_data_i;
    assign out_vld_o   = vld[STAGES];
    assign rdy[STAGES] = out_rdy_i;
    assign out_data_o  = data[STAGES];

    genvar stage_idx;
    generate
        for (stage_idx = 0; stage_idx < STAGES; stage_idx = stage_idx + 1) begin : gen_stage
            pipeline_reg #(
                .W(W)
            ) u_meta_reg (
                .clk      (clk),
                .rst_n    (rst_n),
                .in_valid (vld[stage_idx]),
                .in_ready (rdy[stage_idx]),
                .in_data  (data[stage_idx]),
                .out_valid(vld[stage_idx+1]),
                .out_ready(rdy[stage_idx+1]),
                .out_data (data[stage_idx+1])
            );
        end
    endgenerate

endmodule
