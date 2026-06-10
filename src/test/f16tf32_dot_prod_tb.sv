// ============================================================================
// File Name   : f16tf32_dot_prod_tb.sv
// Author      : LIU YUXUAN
// Date        : 2026-04-29
// Description : Focused testbench for f16tf32_dot_prod modes.
// ============================================================================

`default_nettype none

module f16tf32_dot_prod_tb;

    localparam logic [1:0] F16TF32_DTYPE_TF32 = 2'd0;
    localparam logic [1:0] F16TF32_DTYPE_BF16 = 2'd1;
    localparam logic [1:0] F16TF32_DTYPE_FP16 = 2'd2;

    logic         clk;
    logic         rst_n;
    logic         in_vld_i;
    logic         in_rdy_o;
    logic [1:0]   dtype_i;
    logic [255:0] a_vec_i;
    logic [255:0] b_vec_i;
    logic [31:0]  c_i;
    logic         out_vld_o;
    logic         out_rdy_i;
    logic [31:0]  d_o;

    f16tf32_dot_prod dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_vld_i (in_vld_i),
        .in_rdy_o (in_rdy_o),
        .a_dtype_i(dtype_i),
        .b_dtype_i(dtype_i),
        .a_vec_i  (a_vec_i),
        .b_vec_i  (b_vec_i),
        .c_i      (c_i),
        .scale_input_d_i(4'd0),
        .out_vld_o(out_vld_o),
        .out_rdy_i(out_rdy_i),
        .d_o      (d_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic drive_core(
        input logic [1:0]   dtype,
        input logic [255:0] a_vec,
        input logic [255:0] b_vec,
        input logic [31:0]  c
    );
        begin
            @(posedge clk);
            dtype_i   = dtype;
            a_vec_i  = a_vec;
            b_vec_i  = b_vec;
            c_i      = c;
            in_vld_i = 1'b1;

            while (!in_rdy_o) begin
                @(posedge clk);
            end

            @(posedge clk);
            in_vld_i = 1'b0;
        end
    endtask

    task automatic expect_core(input logic [31:0] exp_d);
        begin
            while (!(out_vld_o && out_rdy_i)) begin
                @(posedge clk);
            end

            if (d_o !== exp_d) begin
                $fatal(1, "f16tf32 result mismatch: got 0x%08x expected 0x%08x", d_o, exp_d);
            end

            @(posedge clk);
        end
    endtask

    integer idx;
    logic [255:0] a_vec;
    logic [255:0] b_vec;

    initial begin
        rst_n              = 1'b0;
        in_vld_i           = 1'b0;
        dtype_i             = F16TF32_DTYPE_TF32;
        a_vec_i            = '0;
        b_vec_i            = '0;
        c_i                = '0;
        out_rdy_i          = 1'b1;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 8; idx = idx + 1) begin
            a_vec[idx*32 +: 32] = 32'h3f80_0000;
            b_vec[idx*32 +: 32] = 32'h3f80_0000;
        end
        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h4100_0000);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 16; idx = idx + 1) begin
            a_vec[idx*16 +: 16] = 16'h3f80;
            b_vec[idx*16 +: 16] = 16'h3f80;
        end
        drive_core(F16TF32_DTYPE_BF16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h4180_0000);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 16; idx = idx + 1) begin
            a_vec[idx*16 +: 16] = 16'h3c00;
            b_vec[idx*16 +: 16] = 16'h3c00;
        end
        drive_core(F16TF32_DTYPE_FP16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h4180_0000);

        a_vec = '0;
        b_vec = '0;
        a_vec[0*16 +: 16] = 16'h4000;
        b_vec[0*16 +: 16] = 16'h4000;
        a_vec[1*16 +: 16] = 16'h3800;
        b_vec[1*16 +: 16] = 16'h3800;
        drive_core(F16TF32_DTYPE_FP16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h4088_0000);

        a_vec = '0;
        b_vec = '0;
        a_vec[31:0] = 32'h0000_2000;
        b_vec[31:0] = 32'h3f80_0000;
        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h0000_2000);

        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h3f80_0000);
        expect_core(32'h3f80_0000);

        a_vec = '0;
        b_vec = '0;
        a_vec[15:0] = 16'h0001;
        b_vec[15:0] = 16'h3f80;
        drive_core(F16TF32_DTYPE_BF16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h0001_0000);

        a_vec = '0;
        b_vec = '0;
        a_vec[31:0] = 32'h0000_2000;
        b_vec[31:0] = 32'h0000_2000;
        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h0000_0000);

        drive_core(F16TF32_DTYPE_TF32, '0, '0, 32'h0000_0001);
        expect_core(32'h0000_0001);

        a_vec = '0;
        b_vec = '0;
        a_vec[15:0] = 16'h0001;
        b_vec[15:0] = 16'h3c00;
        drive_core(F16TF32_DTYPE_FP16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h3380_0000);

        a_vec = '0;
        b_vec = '0;
        a_vec[15:0] = 16'h7f7f;
        b_vec[15:0] = 16'h7f7f;
        drive_core(F16TF32_DTYPE_BF16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h7f80_0000);

        a_vec = '0;
        b_vec = '0;
        for (idx = 0; idx < 16; idx = idx + 1) begin
            a_vec[idx*16 +: 16] = 16'hbc00;
            b_vec[idx*16 +: 16] = 16'h3c00;
        end
        drive_core(F16TF32_DTYPE_FP16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'hc180_0000);

        a_vec = '0;
        b_vec = '0;
        a_vec[31:0] = 32'h7f80_0001;
        b_vec[31:0] = 32'h3f80_0000;
        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h7fff_ffff);

        a_vec = '0;
        b_vec = '0;
        a_vec[31:0] = 32'h7f80_0000;
        b_vec[31:0] = 32'h3f80_0000;
        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h7f80_0000);

        a_vec[31:0] = 32'hff80_0000;
        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'hff80_0000);

        a_vec = '0;
        b_vec = '0;
        a_vec[15:0] = 16'h7f80;
        b_vec[15:0] = 16'h3f80;
        drive_core(F16TF32_DTYPE_BF16, a_vec, b_vec, 32'hff80_0000);
        expect_core(32'h7fff_ffff);

        a_vec = '0;
        b_vec = '0;
        a_vec[31:0] = 32'h0000_0000;
        b_vec[31:0] = 32'h7f80_0000;
        drive_core(F16TF32_DTYPE_TF32, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h7fff_ffff);

        a_vec = '0;
        b_vec = '0;
        a_vec[15:0] = 16'h7c00;
        b_vec[15:0] = 16'h0000;
        drive_core(F16TF32_DTYPE_FP16, a_vec, b_vec, 32'h0000_0000);
        expect_core(32'h7fff_ffff);

        drive_core(2'd3, '0, '0, 32'h0000_0000);
        expect_core(32'h7fff_ffff);

        @(posedge clk);
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("f16tf32_dot_prod_tb PASS");
        $finish;
    end

endmodule

`default_nettype wire
