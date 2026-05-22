// ============================================================================
// File Name   : dot_cluster_top_tb.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-29
// Description : Focused testbench for dot_cluster_top dense/sparse dispatch.
// ============================================================================

`default_nettype none

module dot_cluster_top_tb;

    localparam int TAG_W = 8;

    localparam logic [3:0] DTYPE_TF32     = 4'd0;
    localparam logic [3:0] DTYPE_BF16     = 4'd1;
    localparam logic [3:0] DTYPE_FP16     = 4'd2;
    localparam logic [3:0] DTYPE_FP8_E4M3 = 4'd3;
    localparam logic [3:0] DTYPE_FP8_E5M2 = 4'd4;
    localparam logic [3:0] DTYPE_INT8     = 4'd5;
    localparam logic [3:0] DTYPE_FP4      = 4'd6;

    localparam logic [7:0] STATUS_OK                  = 8'h00;
    localparam logic [7:0] STATUS_INVALID_SPARSE_META = 8'h01;
    localparam logic [7:0] STATUS_UNSUPPORTED_DTYPE   = 8'h02;
    localparam logic [7:0] STATUS_INT_OVERFLOW        = 8'h04;

    logic             clk;
    logic             rst_n;
    logic             in_vld_i;
    logic             in_rdy_o;
    logic [3:0]       req_dtype_i;
    logic             req_sparse_en_i;
    logic [255:0]     req_a_packed_i;
    logic [511:0]     req_b_packed_i;
    logic [127:0]     req_meta_i;
    logic [31:0]      req_c_i;
    logic [TAG_W-1:0] req_tag_i;
    logic             req_mxfp8_en_i;
    logic [7:0]       req_a_mx_scale_i;
    logic [7:0]       req_b_mx_scale_i;
    logic             req_a_unsigned_i;
    logic             req_b_unsigned_i;
    logic             req_int_sat_en_i;
    logic [1:0]       req_fp4_mode_i;
    logic [31:0]      req_a_sf_i;
    logic [31:0]      req_b_sf_i;
    logic             out_vld_o;
    logic             out_rdy_i;
    logic [31:0]      out_d_o;
    logic [7:0]       out_status_o;
    logic [TAG_W-1:0] out_tag_o;

    dot_cluster_top #(
        .TAG_W(TAG_W)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .in_vld_i         (in_vld_i),
        .in_rdy_o         (in_rdy_o),
        .req_dtype_i      (req_dtype_i),
        .req_sparse_en_i  (req_sparse_en_i),
        .req_a_packed_i   (req_a_packed_i),
        .req_b_packed_i   (req_b_packed_i),
        .req_meta_i       (req_meta_i),
        .req_c_i          (req_c_i),
        .req_tag_i        (req_tag_i),
        .req_mxfp8_en_i   (req_mxfp8_en_i),
        .req_a_mx_scale_i (req_a_mx_scale_i),
        .req_b_mx_scale_i (req_b_mx_scale_i),
        .req_a_unsigned_i (req_a_unsigned_i),
        .req_b_unsigned_i (req_b_unsigned_i),
        .req_int_sat_en_i (req_int_sat_en_i),
        .req_fp4_mode_i   (req_fp4_mode_i),
        .req_a_sf_i       (req_a_sf_i),
        .req_b_sf_i       (req_b_sf_i),
        .out_vld_o        (out_vld_o),
        .out_rdy_i        (out_rdy_i),
        .out_d_o          (out_d_o),
        .out_status_o     (out_status_o),
        .out_tag_o        (out_tag_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [7:0] enc_s8(input integer value_i);
        begin
            enc_s8 = value_i[7:0];
        end
    endfunction

    function automatic logic [3:0] pattern_2to4(input integer group_i);
        begin
            case (group_i % 6)
                0: pattern_2to4 = 4'b0011;
                1: pattern_2to4 = 4'b0101;
                2: pattern_2to4 = 4'b1001;
                3: pattern_2to4 = 4'b0110;
                4: pattern_2to4 = 4'b1010;
                default: pattern_2to4 = 4'b1100;
            endcase
        end
    endfunction

    task automatic drive_req(
        input logic [3:0]       dtype_i,
        input logic             sparse_i,
        input logic [255:0]     a_i,
        input logic [511:0]     b_i,
        input logic [127:0]     meta_i,
        input logic [31:0]      c_i,
        input logic [TAG_W-1:0] tag_i,
        input logic [1:0]       fp4_mode_i
    );
        begin
            @(posedge clk);
            req_dtype_i     = dtype_i;
            req_sparse_en_i = sparse_i;
            req_a_packed_i  = a_i;
            req_b_packed_i  = b_i;
            req_meta_i      = meta_i;
            req_c_i         = c_i;
            req_tag_i       = tag_i;
            req_fp4_mode_i  = fp4_mode_i;
            in_vld_i        = 1'b1;

            while (!in_rdy_o) begin
                @(posedge clk);
            end

            @(posedge clk);
            in_vld_i = 1'b0;
        end
    endtask

    task automatic expect_rsp(
        input logic [TAG_W-1:0] exp_tag_i,
        input logic [31:0]      exp_d_i,
        input logic [7:0]       exp_status_i
    );
        begin
            while (!(out_vld_o && out_rdy_i)) begin
                @(posedge clk);
            end

            if (out_tag_o !== exp_tag_i) begin
                $fatal(1, "tag mismatch: got %0d expected %0d", out_tag_o, exp_tag_i);
            end
            if (out_d_o !== exp_d_i) begin
                $fatal(1, "data mismatch for tag %0d: got 0x%08x expected 0x%08x",
                       exp_tag_i, out_d_o, exp_d_i);
            end
            if (out_status_o !== exp_status_i) begin
                $fatal(1, "status mismatch for tag %0d: got 0x%02x expected 0x%02x",
                       exp_tag_i, out_status_o, exp_status_i);
            end

            @(posedge clk);
        end
    endtask

    task automatic expect_rsp_with_backpressure(
        input logic [TAG_W-1:0] exp_tag_i,
        input logic [31:0]      exp_d_i,
        input logic [7:0]       exp_status_i
    );
        begin
            out_rdy_i = 1'b0;
            while (!out_vld_o) begin
                @(posedge clk);
            end

            repeat (2) @(posedge clk);
            if (!out_vld_o) begin
                $fatal(1, "response did not hold under backpressure");
            end
            if (out_tag_o !== exp_tag_i || out_d_o !== exp_d_i ||
                out_status_o !== exp_status_i) begin
                $fatal(1, "backpressure response mismatch tag=%0d d=0x%08x status=0x%02x",
                       out_tag_o, out_d_o, out_status_o);
            end

            out_rdy_i = 1'b1;
            @(posedge clk);
        end
    endtask

    integer idx;
    integer group_idx;
    integer lane_idx;
    integer phys_idx;
    integer a_val;
    integer b_val;
    integer expected_int;
    logic [3:0] mask4;
    logic [255:0] a_vec;
    logic [511:0] b_vec;
    logic [127:0] meta_vec;

    initial begin
        rst_n             = 1'b0;
        in_vld_i          = 1'b0;
        req_dtype_i       = DTYPE_FP8_E4M3;
        req_sparse_en_i   = 1'b0;
        req_a_packed_i    = '0;
        req_b_packed_i    = '0;
        req_meta_i        = '0;
        req_c_i           = '0;
        req_tag_i         = '0;
        req_mxfp8_en_i    = 1'b0;
        req_a_mx_scale_i  = 8'h00;
        req_b_mx_scale_i  = 8'h00;
        req_a_unsigned_i  = 1'b0;
        req_b_unsigned_i  = 1'b0;
        req_int_sat_en_i  = 1'b0;
        req_fp4_mode_i    = 2'd2;
        req_a_sf_i        = '0;
        req_b_sf_i        = '0;
        out_rdy_i         = 1'b1;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        drive_req(DTYPE_TF32, 1'b0, '0, '0, '0, 32'h0000_0000, 8'h01, 2'd2);
        expect_rsp(8'h01, 32'h0000_0000, STATUS_OK);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 8; idx = idx + 1) begin
            a_vec[idx*32 +: 32] = 32'h3f80_0000;
            b_vec[idx*32 +: 32] = 32'h3f80_0000;
        end
        drive_req(DTYPE_TF32, 1'b0, a_vec, b_vec, '0, 32'h0000_0000, 8'h08, 2'd2);
        expect_rsp(8'h08, 32'h4100_0000, STATUS_OK);

        meta_vec = '0;
        for (group_idx = 0; group_idx < 4; group_idx = group_idx + 1) begin
            meta_vec[group_idx*4 +: 4] = 4'b0011;
        end
        drive_req(DTYPE_TF32, 1'b1, '0, '0, meta_vec, 32'h0000_0000, 8'h02, 2'd2);
        expect_rsp(8'h02, 32'h0000_0000, STATUS_OK);

        drive_req(DTYPE_FP16, 1'b0, '0, '0, '0, 32'h0000_0000, 8'h03, 2'd2);
        expect_rsp(8'h03, 32'h0000_0000, STATUS_OK);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 16; idx = idx + 1) begin
            a_vec[idx*16 +: 16] = 16'h3c00;
            b_vec[idx*16 +: 16] = 16'h3c00;
        end
        drive_req(DTYPE_FP16, 1'b0, a_vec, b_vec, '0, 32'h0000_0000, 8'h09, 2'd2);
        expect_rsp(8'h09, 32'h4180_0000, STATUS_OK);

        meta_vec = '0;
        for (group_idx = 0; group_idx < 8; group_idx = group_idx + 1) begin
            meta_vec[group_idx*4 +: 4] = 4'b0101;
        end
        drive_req(DTYPE_BF16, 1'b1, '0, '0, meta_vec, 32'h0000_0000, 8'h04, 2'd2);
        expect_rsp(8'h04, 32'h0000_0000, STATUS_OK);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 16; idx = idx + 1) begin
            a_vec[idx*16 +: 16] = 16'h3f80;
            b_vec[idx*16 +: 16] = 16'h3f80;
        end
        drive_req(DTYPE_BF16, 1'b0, a_vec, b_vec, '0, 32'h0000_0000, 8'h0a, 2'd2);
        expect_rsp(8'h0a, 32'h4180_0000, STATUS_OK);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 32; idx = idx + 1) begin
            a_vec[idx*8 +: 8] = 8'h38;
            b_vec[idx*8 +: 8] = 8'h38;
        end
        drive_req(DTYPE_FP8_E4M3, 1'b0, a_vec, b_vec, '0, 32'h0000_0000, 8'h0b, 2'd2);
        expect_rsp(8'h0b, 32'h4200_0000, STATUS_OK);

        req_mxfp8_en_i   = 1'b1;
        req_a_mx_scale_i = 8'h7f;
        req_b_mx_scale_i = 8'h80;
        drive_req(DTYPE_FP8_E5M2, 1'b0, '0, '0, '0, 32'h0000_0000, 8'h05, 2'd2);
        expect_rsp_with_backpressure(8'h05, 32'h0000_0000, STATUS_OK);
        req_mxfp8_en_i   = 1'b0;
        req_a_mx_scale_i = 8'h00;
        req_b_mx_scale_i = 8'h00;

        out_rdy_i = 1'b0;
        drive_req(DTYPE_TF32, 1'b0, '0, '0, '0, 32'h0000_0000, 8'h06, 2'd2);
        while (!out_vld_o) begin
            @(posedge clk);
        end
        if (out_tag_o !== 8'h06 || out_d_o !== 32'h0000_0000 ||
            out_status_o !== STATUS_OK) begin
            $fatal(1, "held response mismatch tag=%0d d=0x%08x status=0x%02x",
                   out_tag_o, out_d_o, out_status_o);
        end
        @(posedge clk);
        req_dtype_i     = DTYPE_FP16;
        req_sparse_en_i = 1'b0;
        req_a_packed_i  = '0;
        req_b_packed_i  = '0;
        req_meta_i      = '0;
        req_c_i         = 32'h0000_0000;
        req_tag_i       = 8'h07;
        req_fp4_mode_i  = 2'd2;
        in_vld_i        = 1'b1;
        #1;
        if (!in_rdy_o) begin
            $fatal(1, "MID-FP shared datapath did not accept FP16 while TF32 was outstanding");
        end

        @(posedge clk);
        in_vld_i = 1'b0;
        out_rdy_i = 1'b1;
        expect_rsp(8'h06, 32'h0000_0000, STATUS_OK);
        expect_rsp(8'h07, 32'h0000_0000, STATUS_OK);

        a_vec = '0;
        b_vec = '0;
        meta_vec = '0;
        expected_int = 11;
        for (idx = 0; idx < 32; idx = idx + 1) begin
            a_val = (idx % 7) - 3;
            b_val = (idx % 5) - 2;
            a_vec[idx*8 +: 8] = enc_s8(a_val);
            b_vec[idx*8 +: 8] = enc_s8(b_val);
            expected_int = expected_int + a_val * b_val;
        end
        drive_req(DTYPE_INT8, 1'b0, a_vec, b_vec, meta_vec, 32'd11, 8'h11, 2'd2);
        expect_rsp(8'h11, expected_int[31:0], STATUS_OK);

        a_vec = '0;
        b_vec = '0;
        meta_vec = '0;
        expected_int = -17;
        phys_idx = 0;
        for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin
            mask4 = pattern_2to4(group_idx);
            meta_vec[group_idx*4 +: 4] = mask4;
            for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                b_val = ((group_idx*4 + lane_idx) % 9) - 4;
                b_vec[(group_idx*4+lane_idx)*8 +: 8] = enc_s8(b_val);
                if (mask4[lane_idx]) begin
                    a_val = (phys_idx % 11) - 5;
                    a_vec[phys_idx*8 +: 8] = enc_s8(a_val);
                    expected_int = expected_int + a_val * b_val;
                    phys_idx = phys_idx + 1;
                end
            end
        end
        drive_req(DTYPE_INT8, 1'b1, a_vec, b_vec, meta_vec, 32'hffff_ffef, 8'h22, 2'd2);
        expect_rsp(8'h22, expected_int[31:0], STATUS_OK);

        meta_vec = '0;
        meta_vec[3:0] = 4'b0111;
        drive_req(DTYPE_INT8, 1'b1, '0, '0, meta_vec, 32'h1234_5678, 8'h33, 2'd2);
        expect_rsp(8'h33, 32'h1234_5678, STATUS_INVALID_SPARSE_META);

        a_vec = '0;
        b_vec = '0;
        meta_vec = '0;
        a_vec[7:0] = 8'h01;
        b_vec[7:0] = 8'h01;
        drive_req(DTYPE_INT8, 1'b0, a_vec, b_vec, meta_vec, 32'h7fff_ffff, 8'h34, 2'd2);
        expect_rsp(8'h34, 32'h8000_0000, STATUS_INT_OVERFLOW);

        a_vec = '0;
        b_vec = '0;
        meta_vec = '0;
        a_vec[7:0] = 8'hff;
        b_vec[7:0] = 8'h02;
        req_a_unsigned_i = 1'b1;
        req_b_unsigned_i = 1'b1;
        req_int_sat_en_i = 1'b1;
        drive_req(DTYPE_INT8, 1'b0, a_vec, b_vec, meta_vec, 32'h7fff_ff00, 8'h35, 2'd2);
        expect_rsp(8'h35, 32'h7fff_ffff, STATUS_INT_OVERFLOW);
        req_a_unsigned_i = 1'b0;
        req_b_unsigned_i = 1'b0;
        req_int_sat_en_i = 1'b0;

        req_a_sf_i = 32'h8180_7f7e;
        req_b_sf_i = 32'h8281_807f;
        drive_req(DTYPE_FP4, 1'b0, '0, '0, '0, 32'h0000_0000, 8'h43, 2'd1);
        expect_rsp(8'h43, 32'h0000_0000, STATUS_OK);
        req_a_sf_i = '0;
        req_b_sf_i = '0;

        drive_req(DTYPE_FP4, 1'b0, '0, '0, '0, 32'h7fc0_0000, 8'h42, 2'd2);
        expect_rsp(8'h42, 32'h7fff_ffff, STATUS_OK);

        a_vec = '0;
        b_vec = '0;
        meta_vec = '0;
        for (idx = 0; idx < 64; idx = idx + 1) begin
            a_vec[idx*4 +: 4] = 4'h2;
        end
        for (group_idx = 0; group_idx < 16; group_idx = group_idx + 1) begin
            meta_vec[group_idx*8 +: 8] = 8'h0f;
            for (lane_idx = 0; lane_idx < 8; lane_idx = lane_idx + 1) begin
                if (lane_idx < 4) begin
                    b_vec[(group_idx*8+lane_idx)*4 +: 4] = 4'h2;
                end else begin
                    b_vec[(group_idx*8+lane_idx)*4 +: 4] = 4'h7;
                end
            end
        end
        drive_req(DTYPE_FP4, 1'b1, a_vec, b_vec, meta_vec, 32'h0000_0000, 8'h44, 2'd2);
        expect_rsp(8'h44, 32'h4280_0000, STATUS_OK);

        meta_vec = '0;
        meta_vec[7:0] = 8'h1f;
        drive_req(DTYPE_FP4, 1'b1, '0, '0, meta_vec, 32'h8765_4321, 8'h45, 2'd2);
        expect_rsp(8'h45, 32'h8765_4321, STATUS_INVALID_SPARSE_META);

        drive_req(4'hf, 1'b1, '0, '0, '0, 32'habcd_0001, 8'h55, 2'd2);
        expect_rsp(8'h55, 32'habcd_0001, STATUS_UNSUPPORTED_DTYPE);

        $display("dot_cluster_top_tb PASS");
        $finish;
    end

endmodule

`default_nettype wire
