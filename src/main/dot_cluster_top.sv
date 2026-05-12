// ============================================================================
// File Name   : dot_cluster_top.sv
// Author      : Codex
// Date        : 2026-04-29
// Description : Multi-precision dot-product cluster wrapper with A-side
//               structured sparse operand selection and dtype dispatch.
//
// Revision History:
//   Date        Version   Author      Description
//   ----------  --------  ----------  ----------------------------------------
//   2026-04-29  v0.1      Codex       Initial version
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
    // TF32/BF16/FP16 share the MID-FP 16-lane 11x11 datapath.
    localparam logic [2:0] SHARE_GROUP_NONE  = 3'd0;
    localparam logic [2:0] SHARE_GROUP_MIDFP = 3'd1;
    localparam logic [2:0] SHARE_GROUP_F6F8  = 3'd2;
    localparam logic [2:0] SHARE_GROUP_INT8  = 3'd3;
    localparam logic [2:0] SHARE_GROUP_FP4   = 3'd4;

    localparam logic [1:0] MID_FP_MODE_TF32 = 2'd0;
    localparam logic [1:0] MID_FP_MODE_BF16 = 2'd1;
    localparam logic [1:0] MID_FP_MODE_FP16 = 2'd2;

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
                DTYPE_FP16: dtype_share_group = SHARE_GROUP_MIDFP;
                DTYPE_FP8_E4M3,
                DTYPE_FP8_E5M2,
                DTYPE_FP6_E3M2,
                DTYPE_FP6_E2M3: dtype_share_group = SHARE_GROUP_F6F8;
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

    logic        req_supported;
    logic        req_meta_valid;
    logic        invalid_sparse_meta;
    logic        unsupported_dtype;
    logic        err_path;
    logic [2:0]  req_share_group;
    logic [2:0]  active_share_group_q;
    logic [7:0]  outstanding_q;
    logic        share_group_allow;

    logic [255:0] b_tf32_core;
    logic [255:0] b_fp16_core;
    logic [255:0] b_mid_fp_core;
    logic [255:0] b_8b_lane_core;
    logic [255:0] b_fp6_core;
    logic [255:0] b_fp4_core;

    logic tf32_sel;
    logic fp16_sel;
    logic mid_fp_sel;
    logic f6f8_sel;
    logic fp6_sel;
    logic int8_sel;
    logic fp4_sel;
    logic [1:0] mid_fp_mode;

    logic mid_fp_in_rdy;
    logic f6f8_in_rdy;
    logic int8_in_rdy;
    logic fp4_in_rdy;

    logic mid_fp_meta_in_rdy;
    logic f6f8_meta_in_rdy;
    logic int8_meta_in_rdy;
    logic fp4_meta_in_rdy;

    logic selected_core_rdy;
    logic core_req_fire;
    logic err_can_accept;
    logic err_out_rdy;
    logic err_out_fire;

    logic mid_fp_in_vld;
    logic f6f8_in_vld;
    logic int8_in_vld;
    logic fp4_in_vld;

    logic mid_fp_out_vld;
    logic f6f8_out_vld;
    logic int8_out_vld;
    logic fp4_out_vld;

    logic mid_fp_out_rdy;
    logic f6f8_out_rdy;
    logic int8_out_rdy;
    logic fp4_out_rdy;

    logic [31:0] mid_fp_d;
    logic [31:0] f6f8_d;
    logic [31:0] int8_d;
    logic [31:0] fp4_d;
    logic        int8_overflow;

    logic mid_fp_meta_vld;
    logic f6f8_meta_vld;
    logic int8_meta_vld;
    logic fp4_meta_vld;
    logic [RSP_META_W-1:0] mid_fp_meta;
    logic [RSP_META_W-1:0] f6f8_meta;
    logic [RSP_META_W-1:0] int8_meta;
    logic [RSP_META_W-1:0] fp4_meta;
    logic [RSP_META_W-1:0] req_rsp_meta;

    logic err_vld_q;
    logic [31:0] err_d_q;
    logic [7:0] err_status_q;
    logic [TAG_W-1:0] err_tag_q;

    logic arb_err_sel;
    logic arb_mid_fp_sel;
    logic arb_f6f8_sel;
    logic arb_int8_sel;
    logic arb_fp4_sel;

    logic [7:0] outstanding_nxt;
    logic core_rsp_fire;

    assign req_supported       = supported_dtype(req_dtype_i);
    assign req_meta_valid      = (!req_sparse_en_i) || meta_valid_by_dtype(req_dtype_i, req_meta_i);
    assign invalid_sparse_meta = req_sparse_en_i && req_supported && !req_meta_valid;
    assign unsupported_dtype   = !req_supported;
    assign err_path            = unsupported_dtype || invalid_sparse_meta;
    assign req_share_group     = dtype_share_group(req_dtype_i);

    assign b_tf32_core     = req_sparse_en_i ? select_b_2to4_32(req_b_packed_i, req_meta_i) : req_b_packed_i[255:0];
    assign b_fp16_core     = req_sparse_en_i ? select_b_2to4_16(req_b_packed_i, req_meta_i) : req_b_packed_i[255:0];
    assign b_mid_fp_core   = tf32_sel ? b_tf32_core : b_fp16_core;
    assign b_8b_lane_core  = req_sparse_en_i ? select_b_2to4_8(req_b_packed_i, req_meta_i)  : req_b_packed_i[255:0];
    assign b_fp6_core      = req_sparse_en_i ? select_b_2to4_6(req_b_packed_i, req_meta_i)  : req_b_packed_i[255:0];
    assign b_fp4_core      = req_sparse_en_i ? select_b_4to8_4(req_b_packed_i, req_meta_i)  : req_b_packed_i[255:0];

    assign tf32_sel = (req_dtype_i == DTYPE_TF32);
    assign fp16_sel = (req_dtype_i == DTYPE_FP16) || (req_dtype_i == DTYPE_BF16);
    assign mid_fp_sel = tf32_sel || fp16_sel;
    assign fp6_sel   = (req_dtype_i == DTYPE_FP6_E3M2) || (req_dtype_i == DTYPE_FP6_E2M3);
    assign f6f8_sel  = (req_dtype_i == DTYPE_FP8_E4M3) || (req_dtype_i == DTYPE_FP8_E5M2) ||
                       fp6_sel;
    assign int8_sel = (req_dtype_i == DTYPE_INT8);
    assign fp4_sel  = (req_dtype_i == DTYPE_FP4);
    assign mid_fp_mode = tf32_sel ? MID_FP_MODE_TF32 :
                         ((req_dtype_i == DTYPE_BF16) ? MID_FP_MODE_BF16 :
                                                         MID_FP_MODE_FP16);

    assign share_group_allow = (outstanding_q == 8'd0) ||
                               (req_share_group == active_share_group_q);

    always_comb begin
        selected_core_rdy = 1'b0;
        if (mid_fp_sel) begin
            selected_core_rdy = mid_fp_in_rdy && mid_fp_meta_in_rdy;
        end else if (f6f8_sel) begin
            selected_core_rdy = f6f8_in_rdy && f6f8_meta_in_rdy;
        end else if (int8_sel) begin
            selected_core_rdy = int8_in_rdy && int8_meta_in_rdy;
        end else if (fp4_sel) begin
            selected_core_rdy = fp4_in_rdy && fp4_meta_in_rdy;
        end
    end

    assign err_can_accept = !err_vld_q || err_out_fire;
    assign in_rdy_o = err_path ? err_can_accept : (share_group_allow && selected_core_rdy);
    assign core_req_fire = in_vld_i && in_rdy_o && !err_path;

    assign mid_fp_in_vld = core_req_fire && mid_fp_sel;
    assign f6f8_in_vld  = core_req_fire && f6f8_sel;
    assign int8_in_vld = core_req_fire && int8_sel;
    assign fp4_in_vld  = core_req_fire && fp4_sel;

    assign req_rsp_meta = {req_tag_i, STATUS_OK};

    mid_fp_dot_prod u_mid_fp_dot_prod (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_vld_i (mid_fp_in_vld),
        .in_rdy_o (mid_fp_in_rdy),
        .mode_i   (mid_fp_mode),
        .a_vec_i  (req_a_packed_i),
        .b_vec_i  (b_mid_fp_core),
        .c_i      (req_c_i),
        .out_vld_o(mid_fp_out_vld),
        .out_rdy_i(mid_fp_out_rdy),
        .d_o      (mid_fp_d)
    );

    f6f8_dot_prod u_f6f8_dot_prod (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_vld_i    (f6f8_in_vld),
        .in_rdy_o    (f6f8_in_rdy),
        .a_vec_i     (req_a_packed_i),
        .b_vec_i     (fp6_sel ? b_fp6_core : b_8b_lane_core),
        .c_i         (req_c_i),
        .fp8_format_i(req_dtype_i == DTYPE_FP8_E5M2),
        .fp6_en_i    (fp6_sel),
        .fp6_format_i(req_dtype_i == DTYPE_FP6_E3M2),
        .mxfp8_en_i  (req_mxfp8_en_i),
        .a_mx_scale_i(req_a_mx_scale_i),
        .b_mx_scale_i(req_b_mx_scale_i),
        .out_vld_o   (f6f8_out_vld),
        .out_rdy_i   (f6f8_out_rdy),
        .d_o         (f6f8_d)
    );

    int8_dot_prod u_int8_dot_prod (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_vld_i    (int8_in_vld),
        .in_rdy_o    (int8_in_rdy),
        .a_vec_i     (req_a_packed_i),
        .b_vec_i     (b_8b_lane_core),
        .c_i         (req_c_i),
        .a_unsigned_i(req_a_unsigned_i),
        .b_unsigned_i(req_b_unsigned_i),
        .sat_en_i    (req_int_sat_en_i),
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
        .a_fp4_i   (req_a_packed_i),
        .b_fp4_i   (b_fp4_core),
        .fp4_mode_i(req_fp4_mode_i),
        .a_sf_i    (req_a_sf_i),
        .b_sf_i    (req_b_sf_i),
        .c_fp32_i  (req_c_i),
        .out_vld_o (fp4_out_vld),
        .out_rdy_i (fp4_out_rdy),
        .d_fp32_o  (fp4_d)
    );

    dot_rsp_meta_pipe #(
        .W      (RSP_META_W),
        .STAGES (5)
    ) u_mid_fp_meta_pipe (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_vld_i     (mid_fp_in_vld),
        .in_rdy_o     (mid_fp_meta_in_rdy),
        .in_data_i    (req_rsp_meta),
        .out_vld_o    (mid_fp_meta_vld),
        .out_rdy_i    (mid_fp_out_rdy),
        .out_data_o   (mid_fp_meta)
    );

    dot_rsp_meta_pipe #(
        .W      (RSP_META_W),
        .STAGES (5)
    ) u_f6f8_meta_pipe (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_vld_i     (f6f8_in_vld),
        .in_rdy_o     (f6f8_meta_in_rdy),
        .in_data_i    (req_rsp_meta),
        .out_vld_o    (f6f8_meta_vld),
        .out_rdy_i    (f6f8_out_rdy),
        .out_data_o   (f6f8_meta)
    );

    dot_rsp_meta_pipe #(
        .W      (RSP_META_W),
        .STAGES (4)
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
            if (in_vld_i && in_rdy_o && err_path) begin
                err_vld_q    <= 1'b1;
                err_d_q      <= req_c_i;
                err_status_q <= unsupported_dtype ? STATUS_UNSUPPORTED_DTYPE :
                                                     STATUS_INVALID_SPARSE_META;
                err_tag_q    <= req_tag_i;
            end else if (err_out_fire) begin
                err_vld_q <= 1'b0;
            end
        end
    end

    assign arb_err_sel    = err_vld_q;
    assign arb_mid_fp_sel = !arb_err_sel && mid_fp_out_vld;
    assign arb_f6f8_sel  = !arb_err_sel && !arb_mid_fp_sel && f6f8_out_vld;
    assign arb_int8_sel   = !arb_err_sel && !arb_mid_fp_sel &&
                            !arb_f6f8_sel && int8_out_vld;
    assign arb_fp4_sel    = !arb_err_sel && !arb_mid_fp_sel &&
                            !arb_f6f8_sel && !arb_int8_sel && fp4_out_vld;

    assign err_out_rdy    = out_rdy_i && arb_err_sel;
    assign mid_fp_out_rdy = out_rdy_i && arb_mid_fp_sel;
    assign f6f8_out_rdy  = out_rdy_i && arb_f6f8_sel;
    assign int8_out_rdy   = out_rdy_i && arb_int8_sel;
    assign fp4_out_rdy    = out_rdy_i && arb_fp4_sel;
    assign err_out_fire = err_vld_q && err_out_rdy;

    assign out_vld_o = err_vld_q || mid_fp_out_vld || f6f8_out_vld ||
                       int8_out_vld || fp4_out_vld;

    always_comb begin
        out_d_o      = 32'h0000_0000;
        out_status_o = STATUS_OK;
        out_tag_o    = '0;

        if (arb_err_sel) begin
            out_d_o      = err_d_q;
            out_status_o = err_status_q;
            out_tag_o    = err_tag_q;
        end else if (arb_mid_fp_sel) begin
            out_d_o      = mid_fp_d;
            out_status_o = mid_fp_meta[7:0];
            out_tag_o    = mid_fp_meta[RSP_META_W-1:8];
        end else if (arb_f6f8_sel) begin
            out_d_o      = f6f8_d;
            out_status_o = f6f8_meta[7:0];
            out_tag_o    = f6f8_meta[RSP_META_W-1:8];
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

    assign core_rsp_fire = (mid_fp_out_vld && mid_fp_out_rdy) ||
                           (f6f8_out_vld  && f6f8_out_rdy)  ||
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
                active_share_group_q <= req_share_group;
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
