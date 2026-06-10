// ============================================================================
// File Name   : shared_accum33_tree_tb.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-03
// Description : Directed self-checking testbench for shared_accum33_tree.
// ============================================================================

`timescale 1ns/1ps
`default_nettype none

module shared_accum33_tree_tb;

    localparam int TERM_W  = 33;
    localparam int TERM_N  = 33;
    localparam int META_W  = 16;
    localparam int MAX_EXP = 512;

    localparam logic MODE_F16TF32    = 1'b0;
    localparam logic MODE_F4F6F8 = 1'b1;

    logic                         clk;
    logic                         rst_n;

    logic                         in_vld_i;
    logic                         in_rdy_o;
    logic                         mode_i;
    logic [TERM_N*TERM_W-1:0]     term_flat_i;
    logic [META_W-1:0]            meta_i;

    logic                         f16tf32_out_vld_o;
    logic                         f16tf32_out_rdy_i;
    logic                         f16tf32_sum_sign_o;
    logic [TERM_W-1:0]            f16tf32_sum_abs_o;
    logic [META_W-1:0]            f16tf32_meta_o;

    logic                         f4f6f8_out_vld_o;
    logic                         f4f6f8_out_rdy_i;
    logic signed [TERM_W-1:0]     f4f6f8_sum_o;
    logic [META_W-1:0]            f4f6f8_meta_o;

    logic                         random_ready_en;
    logic                         saw_dual_fire;

    logic                         exp_f16tf32_sign [0:MAX_EXP-1];
    logic [TERM_W-1:0]            exp_f16tf32_abs  [0:MAX_EXP-1];
    logic [META_W-1:0]            exp_f16tf32_meta [0:MAX_EXP-1];
    int                           exp_f16tf32_wr;
    int                           exp_f16tf32_rd;

    logic signed [TERM_W-1:0]     exp_f4_sum  [0:MAX_EXP-1];
    logic [META_W-1:0]            exp_f4_meta [0:MAX_EXP-1];
    int                           exp_f4_wr;
    int                           exp_f4_rd;

    logic                         f16tf32_stall_q;
    logic                         f16tf32_stall_sign_q;
    logic [TERM_W-1:0]            f16tf32_stall_abs_q;
    logic [META_W-1:0]            f16tf32_stall_meta_q;

    logic                         f4_stall_q;
    logic signed [TERM_W-1:0]     f4_stall_sum_q;
    logic [META_W-1:0]            f4_stall_meta_q;

    shared_accum33_tree #(
        .TERM_W(TERM_W),
        .TERM_N(TERM_N),
        .META_W(META_W)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .in_vld_i           (in_vld_i),
        .in_rdy_o           (in_rdy_o),
        .mode_i             (mode_i),
        .term_flat_i        (term_flat_i),
        .meta_i             (meta_i),
        .f16tf32_out_vld_o      (f16tf32_out_vld_o),
        .f16tf32_out_rdy_i      (f16tf32_out_rdy_i),
        .f16tf32_sum_sign_o     (f16tf32_sum_sign_o),
        .f16tf32_sum_abs_o      (f16tf32_sum_abs_o),
        .f16tf32_meta_o         (f16tf32_meta_o),
        .f4f6f8_out_vld_o   (f4f6f8_out_vld_o),
        .f4f6f8_out_rdy_i   (f4f6f8_out_rdy_i),
        .f4f6f8_sum_o       (f4f6f8_sum_o),
        .f4f6f8_meta_o      (f4f6f8_meta_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(negedge clk) begin
        if (!rst_n) begin
            f16tf32_out_rdy_i    <= 1'b0;
            f4f6f8_out_rdy_i <= 1'b0;
        end else if (random_ready_en) begin
            f16tf32_out_rdy_i    <= ($urandom_range(0, 3) != 0);
            f4f6f8_out_rdy_i <= ($urandom_range(0, 3) != 0);
        end else begin
            f16tf32_out_rdy_i    <= 1'b1;
            f4f6f8_out_rdy_i <= 1'b1;
        end
    end

    function automatic logic [TERM_N*TERM_W-1:0] make_terms(input int seed);
        logic [TERM_N*TERM_W-1:0] flat;
        logic [63:0]              raw;
        int                       idx;
        begin
            flat = '0;
            for (idx = 0; idx < TERM_N; idx = idx + 1) begin
                raw = (64'h9e37_79b9_7f4a_7c15 * (longint'(seed) + 64'd1)) ^
                      (64'hbf58_476d_1ce4_e5b9 * (longint'(idx)  + 64'd3));
                flat[idx*TERM_W +: TERM_W] = raw[TERM_W-1:0];
            end
            make_terms = flat;
        end
    endfunction

    function automatic logic [TERM_N*TERM_W-1:0] make_directed_f16tf32_terms;
        logic [TERM_N*TERM_W-1:0] flat;
        logic [TERM_N*TERM_W-1:0] rand_flat;
        int                       idx;
        begin
            flat = '0;
            for (idx = 0; idx < 17; idx = idx + 1) begin
                flat[idx*TERM_W +: TERM_W] = (idx[0] == 1'b0) ?
                                             TERM_W'(33'sd31 + idx) :
                                             TERM_W'(-33'sd19 - idx);
            end
            for (idx = 17; idx < TERM_N; idx = idx + 1) begin
                rand_flat = make_terms(idx);
                flat[idx*TERM_W +: TERM_W] = rand_flat[idx*TERM_W +: TERM_W];
            end
            make_directed_f16tf32_terms = flat;
        end
    endfunction

    function automatic logic [TERM_N*TERM_W-1:0] make_directed_f4_terms;
        logic [TERM_N*TERM_W-1:0] flat;
        int                       idx;
        begin
            flat = '0;
            for (idx = 0; idx < TERM_N; idx = idx + 1) begin
                flat[idx*TERM_W +: TERM_W] = (idx[1] == 1'b0) ?
                                             TERM_W'(33'sd103 + idx * 3) :
                                             TERM_W'(-33'sd71 - idx * 5);
            end
            make_directed_f4_terms = flat;
        end
    endfunction

    function automatic logic signed [TERM_W-1:0] sum_range(
        input logic [TERM_N*TERM_W-1:0] flat,
        input int                       start_idx,
        input int                       term_cnt
    );
        logic signed [TERM_W-1:0] acc;
        int                       idx;
        begin
            acc = '0;
            for (idx = 0; idx < term_cnt; idx = idx + 1) begin
                acc = acc + $signed(flat[(start_idx + idx)*TERM_W +: TERM_W]);
            end
            sum_range = acc;
        end
    endfunction

    function automatic logic [TERM_W-1:0] abs_twos(
        input logic signed [TERM_W-1:0] value
    );
        begin
            abs_twos = value[TERM_W-1] ? $unsigned(-value) : $unsigned(value);
        end
    endfunction

    task automatic push_expected(
        input logic                         mode,
        input logic [TERM_N*TERM_W-1:0]     flat,
        input logic [META_W-1:0]            meta
    );
        logic signed [TERM_W-1:0] f16tf32_sum;
        logic signed [TERM_W-1:0] f4_sum;
        begin
            if (mode == MODE_F16TF32) begin
                if (exp_f16tf32_wr >= MAX_EXP) begin
                    $fatal(1, "F16TF32 expected queue overflow");
                end
                f16tf32_sum = sum_range(flat, 0, 17);
                exp_f16tf32_sign[exp_f16tf32_wr] = f16tf32_sum[TERM_W-1];
                exp_f16tf32_abs[exp_f16tf32_wr]  = abs_twos(f16tf32_sum);
                exp_f16tf32_meta[exp_f16tf32_wr] = meta;
                exp_f16tf32_wr++;
            end else begin
                if (exp_f4_wr >= MAX_EXP) begin
                    $fatal(1, "F4F6F8 expected queue overflow");
                end
                f4_sum = sum_range(flat, 0, TERM_N);
                exp_f4_sum[exp_f4_wr]  = f4_sum;
                exp_f4_meta[exp_f4_wr] = meta;
                exp_f4_wr++;
            end
        end
    endtask

    task automatic drive_one(
        input logic                         mode,
        input logic [TERM_N*TERM_W-1:0]     flat,
        input logic [META_W-1:0]            meta
    );
        begin
            @(negedge clk);
            mode_i      = mode;
            term_flat_i = flat;
            meta_i      = meta;
            in_vld_i    = 1'b1;

            while (!in_rdy_o) begin
                @(negedge clk);
            end
            push_expected(mode, flat, meta);

            @(negedge clk);
            in_vld_i = 1'b0;
        end
    endtask

    task automatic drive_burst(input int req_cnt);
        logic [TERM_N*TERM_W-1:0] flat;
        logic [META_W-1:0]        meta;
        logic                     mode;
        int                       req_idx;
        bit                       accepted;
        begin
            req_idx = 0;
            @(negedge clk);

            flat        = make_terms(req_idx);
            meta        = META_W'(16'h3000 + req_idx);
            mode        = (req_idx % 3 == 0) ? MODE_F16TF32 : MODE_F4F6F8;
            mode_i      = mode;
            term_flat_i = flat;
            meta_i      = meta;
            in_vld_i    = 1'b1;

            while (req_idx < req_cnt) begin
                @(posedge clk);
                accepted = (in_vld_i && in_rdy_o);
                if (accepted) begin
                    push_expected(mode, flat, meta);
                    req_idx++;
                end

                @(negedge clk);
                if (accepted && req_idx < req_cnt) begin
                    flat        = make_terms(req_idx);
                    meta        = META_W'(16'h3000 + req_idx);
                    mode        = (req_idx % 3 == 0) ? MODE_F16TF32 : MODE_F4F6F8;
                    mode_i      = mode;
                    term_flat_i = flat;
                    meta_i      = meta;
                    in_vld_i    = 1'b1;
                end else if (accepted) begin
                    in_vld_i = 1'b0;
                end
            end
        end
    endtask

    task automatic wait_drained;
        int wait_cycle;
        begin
            wait_cycle = 0;
            while ((exp_f16tf32_rd != exp_f16tf32_wr || exp_f4_rd != exp_f4_wr) &&
                   wait_cycle < 1000) begin
                @(posedge clk);
                wait_cycle++;
            end

            if (exp_f16tf32_rd != exp_f16tf32_wr || exp_f4_rd != exp_f4_wr) begin
                $fatal(1, "Timeout waiting for expected outputs: F16TF32 %0d/%0d F4F6F8 %0d/%0d",
                       exp_f16tf32_rd, exp_f16tf32_wr, exp_f4_rd, exp_f4_wr);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exp_f16tf32_wr       <= 0;
            exp_f16tf32_rd       <= 0;
            exp_f4_wr        <= 0;
            exp_f4_rd        <= 0;
            f16tf32_stall_q      <= 1'b0;
            f16tf32_stall_sign_q <= 1'b0;
            f16tf32_stall_abs_q  <= '0;
            f16tf32_stall_meta_q <= '0;
            f4_stall_q       <= 1'b0;
            f4_stall_sum_q   <= '0;
            f4_stall_meta_q  <= '0;
            saw_dual_fire    <= 1'b0;
        end else begin
            if (f16tf32_stall_q && f16tf32_out_vld_o) begin
                if (f16tf32_sum_sign_o !== f16tf32_stall_sign_q ||
                    f16tf32_sum_abs_o  !== f16tf32_stall_abs_q  ||
                    f16tf32_meta_o     !== f16tf32_stall_meta_q) begin
                    $fatal(1, "F16TF32 output changed while backpressured");
                end
            end

            if (f4_stall_q && f4f6f8_out_vld_o) begin
                if (f4f6f8_sum_o  !== f4_stall_sum_q ||
                    f4f6f8_meta_o !== f4_stall_meta_q) begin
                    $fatal(1, "F4F6F8 output changed while backpressured");
                end
            end

            if (f16tf32_out_vld_o && f16tf32_out_rdy_i) begin
                if (exp_f16tf32_rd >= exp_f16tf32_wr) begin
                    $fatal(1, "Unexpected F16TF32 output meta=0x%0h", f16tf32_meta_o);
                end
                if (f16tf32_sum_sign_o !== exp_f16tf32_sign[exp_f16tf32_rd] ||
                    f16tf32_sum_abs_o  !== exp_f16tf32_abs[exp_f16tf32_rd]  ||
                    f16tf32_meta_o     !== exp_f16tf32_meta[exp_f16tf32_rd]) begin
                    $fatal(1, "F16TF32 mismatch at %0d: sign=%0b abs=0x%0h meta=0x%0h expected sign=%0b abs=0x%0h meta=0x%0h",
                           exp_f16tf32_rd, f16tf32_sum_sign_o, f16tf32_sum_abs_o, f16tf32_meta_o,
                           exp_f16tf32_sign[exp_f16tf32_rd], exp_f16tf32_abs[exp_f16tf32_rd],
                           exp_f16tf32_meta[exp_f16tf32_rd]);
                end
                exp_f16tf32_rd <= exp_f16tf32_rd + 1;
            end

            if (f4f6f8_out_vld_o && f4f6f8_out_rdy_i) begin
                if (exp_f4_rd >= exp_f4_wr) begin
                    $fatal(1, "Unexpected F4F6F8 output meta=0x%0h", f4f6f8_meta_o);
                end
                if (f4f6f8_sum_o  !== exp_f4_sum[exp_f4_rd] ||
                    f4f6f8_meta_o !== exp_f4_meta[exp_f4_rd]) begin
                    $fatal(1, "F4F6F8 mismatch at %0d: sum=0x%0h meta=0x%0h expected sum=0x%0h meta=0x%0h",
                           exp_f4_rd, f4f6f8_sum_o, f4f6f8_meta_o,
                           exp_f4_sum[exp_f4_rd], exp_f4_meta[exp_f4_rd]);
                end
                exp_f4_rd <= exp_f4_rd + 1;
            end

            if ((f16tf32_out_vld_o && f16tf32_out_rdy_i) &&
                (f4f6f8_out_vld_o && f4f6f8_out_rdy_i)) begin
                saw_dual_fire <= 1'b1;
            end

            f16tf32_stall_q <= f16tf32_out_vld_o && !f16tf32_out_rdy_i;
            if (f16tf32_out_vld_o && !f16tf32_out_rdy_i) begin
                f16tf32_stall_sign_q <= f16tf32_sum_sign_o;
                f16tf32_stall_abs_q  <= f16tf32_sum_abs_o;
                f16tf32_stall_meta_q <= f16tf32_meta_o;
            end

            f4_stall_q <= f4f6f8_out_vld_o && !f4f6f8_out_rdy_i;
            if (f4f6f8_out_vld_o && !f4f6f8_out_rdy_i) begin
                f4_stall_sum_q  <= f4f6f8_sum_o;
                f4_stall_meta_q <= f4f6f8_meta_o;
            end
        end
    end

    initial begin
        rst_n              = 1'b0;
        in_vld_i           = 1'b0;
        mode_i             = MODE_F16TF32;
        term_flat_i        = '0;
        meta_i             = '0;
        f16tf32_out_rdy_i      = 1'b0;
        f4f6f8_out_rdy_i   = 1'b0;
        random_ready_en    = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        drive_one(MODE_F16TF32, make_directed_f16tf32_terms(), 16'h1001);
        wait_drained();

        drive_one(MODE_F4F6F8, make_directed_f4_terms(), 16'h2001);
        wait_drained();

        random_ready_en = 1'b0;
        drive_burst(12);
        wait_drained();
        if (!saw_dual_fire) begin
            $fatal(1, "Did not observe simultaneous F16TF32 and F4F6F8 output fires");
        end

        random_ready_en = 1'b1;
        drive_burst(120);
        wait_drained();

        $display("shared_accum33_tree_tb PASS");
        $finish;
    end

endmodule

`default_nettype wire
