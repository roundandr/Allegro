`timescale 1ns / 1ps

module tb_fp4_dot_prod;

    logic         clk;
    logic         rst_n;
    logic         in_vld_i;
    logic         in_rdy_o;
    logic [255:0] a_fp4_i;
    logic [255:0] b_fp4_i;
    logic [1:0]   fp4_mode_i;
    logic [31:0]  a_sf_i;
    logic [31:0]  b_sf_i;
    logic [31:0]  c_fp32_i;
    logic         out_vld_o;
    logic         out_rdy_i;
    logic [31:0]  d_fp32_o;

    fp4_dot_prod dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_vld_i (in_vld_i),
        .in_rdy_o (in_rdy_o),
        .a_fp4_i  (a_fp4_i),
        .b_fp4_i  (b_fp4_i),
        .fp4_mode_i(fp4_mode_i),
        .a_sf_i   (a_sf_i),
        .b_sf_i   (b_sf_i),
        .c_fp32_i (c_fp32_i),
        .out_vld_o(out_vld_o),
        .out_rdy_i(out_rdy_i),
        .d_fp32_o (d_fp32_o)
    );

    function automatic logic [3:0] fp4_code(input logic sign_i, input logic [2:0] mag_code_i);
        begin
            fp4_code = {sign_i, mag_code_i};
        end
    endfunction

    function automatic logic [7:0] sf_one();
        begin
            sf_one = 8'h38;
        end
    endfunction

    function automatic logic [7:0] sf_two();
        begin
            sf_two = 8'h40;
        end
    endfunction

    task automatic clear_vectors;
        begin
            a_fp4_i  = '0;
            b_fp4_i  = '0;
            fp4_mode_i = 2'd0;
            a_sf_i   = {4{sf_one()}};
            b_sf_i   = {4{sf_one()}};
            c_fp32_i = 32'h0000_0000;
        end
    endtask

    task automatic set_elem(
        inout logic [255:0] vec_i,
        input integer       idx_i,
        input logic [3:0]   val_i
    );
        begin
            vec_i[idx_i*4 +: 4] = val_i;
        end
    endtask

    task automatic send_and_check(
        input logic [255:0] a_vec_i,
        input logic [255:0] b_vec_i,
        input logic [31:0]  a_sf_vec_i,
        input logic [31:0]  b_sf_vec_i,
        input logic [31:0]  c_vec_i,
        input logic [31:0]  expected_i,
        input string        name_i
    );
        integer timeout;
        begin
            @(negedge clk);
            while (!in_rdy_o) begin
                @(negedge clk);
            end

            a_fp4_i  <= a_vec_i;
            b_fp4_i  <= b_vec_i;
            a_sf_i   <= a_sf_vec_i;
            b_sf_i   <= b_sf_vec_i;
            c_fp32_i <= c_vec_i;
            in_vld_i <= 1'b1;

            @(negedge clk);
            in_vld_i <= 1'b0;

            timeout = 100;
            while (!out_vld_o && timeout > 0) begin
                @(negedge clk);
                timeout = timeout - 1;
            end

            if (timeout == 0) begin
                $display("TIMEOUT: %s", name_i);
                $fatal;
            end

            if (d_fp32_o !== expected_i) begin
                $display("FAIL: %s", name_i);
                $display("  expected = 0x%08h", expected_i);
                $display("  got      = 0x%08h", d_fp32_o);
                $fatal;
            end else begin
                $display("PASS: %s -> 0x%08h", name_i, d_fp32_o);
            end

            @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n     = 1'b0;
        in_vld_i  = 1'b0;
        out_rdy_i = 1'b1;
        clear_vectors();

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        clear_vectors();
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i, 32'h0000_0000, "all_zero");

        clear_vectors();
        set_elem(a_fp4_i, 0, fp4_code(1'b0, 3'd2));
        set_elem(b_fp4_i, 0, fp4_code(1'b0, 3'd2));
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i, 32'h3f80_0000, "single_one_product");

        clear_vectors();
        for (int i = 0; i < 16; i++) begin
            set_elem(a_fp4_i, i, fp4_code(1'b0, 3'd2));
            set_elem(b_fp4_i, i, fp4_code(1'b0, 3'd2));
        end
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i, 32'h4180_0000, "block_sum_16");

        clear_vectors();
        for (int i = 0; i < 16; i++) begin
            set_elem(a_fp4_i, i, fp4_code(1'b0, 3'd2));
            set_elem(b_fp4_i, i, fp4_code(1'b0, 3'd2));
        end
        a_sf_i[7:0] = sf_two();
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i, 32'h4200_0000, "block_sum_scaled_32");

        clear_vectors();
        set_elem(a_fp4_i, 0, fp4_code(1'b1, 3'd2));
        set_elem(b_fp4_i, 0, fp4_code(1'b0, 3'd2));
        c_fp32_i = 32'h3fc0_0000;
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i, 32'h3f00_0000, "negative_plus_c");

        clear_vectors();
        for (int i = 0; i < 16; i++) begin
            set_elem(a_fp4_i, i, fp4_code(1'b0, 3'd7));
            set_elem(b_fp4_i, i, fp4_code(1'b0, 3'd7));
        end
        for (int i = 16; i < 32; i++) begin
            set_elem(a_fp4_i, i, fp4_code(1'b1, 3'd7));
            set_elem(b_fp4_i, i, fp4_code(1'b0, 3'd7));
        end
        c_fp32_i = 32'h2d80_0000;
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i,
                       32'h3080_0000, "large_cancel_keeps_aligned_c");

        clear_vectors();
        for (int i = 0; i < 16; i++) begin
            set_elem(a_fp4_i, i, fp4_code(1'b0, 3'd7));
            set_elem(b_fp4_i, i, fp4_code(1'b0, 3'd7));
        end
        for (int i = 16; i < 32; i++) begin
            set_elem(a_fp4_i, i, fp4_code(1'b1, 3'd7));
            set_elem(b_fp4_i, i, fp4_code(1'b0, 3'd7));
        end
        c_fp32_i = 32'h2d80_0000;
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i,
                       32'h0000_0000, "large_cancel_truncates_tiny_c");

        clear_vectors();
        a_sf_i[7:0] = 8'h7f;
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i, 32'h7fff_ffff, "scale_nan");

        clear_vectors();
        c_fp32_i = 32'h7f80_0000;
        send_and_check(a_fp4_i, b_fp4_i, a_sf_i, b_sf_i, c_fp32_i, 32'h7f80_0000, "c_pos_inf");

        $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
