`timescale 1ns / 1ps

module tb_fp4_dot;

    // ---------- Parameters (可配置) ----------
    localparam int VECTOR_LEN = 8;
    localparam int ACC_PREC = 32;
    localparam int FP4_W = 4;
    localparam int VEC_BITS = VECTOR_LEN * FP4_W;

    // ---------- DUT signals ----------
    logic clk;
    logic rst_n;
    logic in_valid, in_ready;
    logic out_valid, out_ready;
    logic [VEC_BITS-1:0] vecA_flat, vecB_flat;
    logic signed [ACC_PREC-1:0] d;

    // ---------- Instantiate DUT (assume module exists) ----------
    // If your module name/wiring differs, update here.
    fp4_dot #(
        .VECTOR_LEN(VECTOR_LEN),
        .ACC_PREC  (ACC_PREC)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .out_ready(out_ready),
        .vecA_flat(vecA_flat),
        .vecB_flat(vecB_flat),
        .d        (d),
        .out_valid(out_valid),
        .in_ready (in_ready)
    );

    // ---------- Clock ----------
    initial clk = 0;
    always #5 clk = ~clk;

    // ---------- Helper: decode FP4 -> real ----------
    // FP4 format: [3]=sign, [2:1]=exp(2bits), [0]=frac(1bit), bias=1
    function shortreal fp4_to_shortreal(input logic [3:0] f4);
        logic s;
        logic [1:0] e;
        logic fr;
        int mant;
        int exp_field;
        shortreal val;
        begin
            {s, e, fr} = f4;
            if (e == 2'b00) begin
                val = 0.0;
            end else begin
                mant = (1 << 1) | fr;
                val  = (shortreal'(mant) / 2.0) * (2.0 ** (shortreal'(e) - 1.0));
                if (s) val = -val;
            end
            fp4_to_shortreal = val;
        end
    endfunction

    function automatic shortreal fp32_to_shortreal(input logic [31:0] bits);
        // IEEE754: sign(31), exponent(30:23), fraction(22:0)
        int   sign;
        int   exp;
        int   frac;
        real  mant;
        real  value;

        begin
            sign = bits[31];
            exp  = bits[30:23];
            frac = bits[22:0];

            // ======= Special cases =======
            if (exp == 8'hFF) begin
                if (frac == 0)
                    value = (sign ? -1.0 : 1.0) * (1.0 / 0.0); // ±inf
                else
                    value = 0.0 / 0.0; // NaN
            end
            else if (exp == 0) begin
                if (frac == 0)
                    value = (sign ? -0.0 : 0.0); // ±0
                else begin
                    // denormalized
                    mant  = frac / (2.0**23);
                    value = (sign ? -1.0 : 1.0) * mant * 2.0**(-126);
                end
            end
            else begin
                // normalized
                mant  = 1.0 + frac / (2.0**23);
                value = (sign ? -1.0 : 1.0) * mant * 2.0**(exp - 127);
            end

            return shortreal'(value);
        end
    endfunction

    // ---------- Test procedure ----------
    int NUM_TESTS;
    int timeout;
    shortreal diff;
    shortreal abs_err;
    shortreal golden;
    shortreal dut_fp32_value;
    logic [31:0] golden_bits;

    initial begin
        // reset
        rst_n = 0;
        in_valid = 0;
        out_ready = 1;
        vecA_flat = '0;
        vecB_flat = '0;
        #20;
        rst_n = 1;
        #20;

        // We'll run multiple random tests
        NUM_TESTS = 20;
        for (int t = 0; t < NUM_TESTS; t++) begin
            // prepare random FP4 vectors
            logic [FP4_W-1:0] A[VECTOR_LEN];
            logic [FP4_W-1:0] B[VECTOR_LEN];

            // populate random legal FP4 (avoid exp==0 or allow zeros)
            for (int i = 0; i < VECTOR_LEN; i++) begin
                // Randomly choose zero or a non-zero FP4
                if ($urandom_range(0, 3) == 0) begin
                    A[i] = 4'b0000;  // zero
                end else begin
                    logic s = $urandom_range(0, 1);
                    logic [1:0] e = $urandom_range(1, 3);  // 1..3
                    logic f = $urandom_range(0, 1);
                    A[i] = {s, e, f};
                end

                if ($urandom_range(0, 3) == 0) begin
                    B[i] = 4'b0000;
                end else begin
                    logic s = $urandom_range(0, 1);
                    logic [1:0] e = $urandom_range(1, 3);
                    logic f = $urandom_range(0, 1);
                    B[i] = {s, e, f};
                end
            end

            for (int i = 0; i < VECTOR_LEN; i++) begin
                vecA_flat[FP4_W*i+:FP4_W] = A[i];
                vecB_flat[FP4_W*i+:FP4_W] = B[i];
            end

            // compute golden in real (shortreal) using fp4_to_shortreal
            golden = 0.0;
            for (int i = 0; i < VECTOR_LEN; i++) begin
                golden += fp4_to_shortreal(A[i]) * fp4_to_shortreal(B[i]);
            end

            // start DUT
            @(negedge clk);
            in_valid <= 1;
            @(negedge clk);
            in_valid <= 0;

            // wait for done (with timeout safety)
            timeout = 1000;
            while (!out_valid && timeout > 0) begin
                @(negedge clk);
                timeout -= 1;
            end
            if (timeout == 0) begin
                $display("[%0t] ERROR: DUT timed out on test %0d", $time, t);
                $finish;
            end

            dut_fp32_value = fp32_to_shortreal(d);  

            diff = dut_fp32_value - golden;
            abs_err = (diff < 0.0) ? -diff : diff;

            // display detailed info
            $display("====================================================================");
            $display("TEST %0d:", t);
            $display("vecA:");
            for (int i = 0; i < VECTOR_LEN; i++)
            $display("  A[%0d] = %b => %f", i, A[i], fp4_to_shortreal(A[i]));
            $display("vecB:");
            for (int i = 0; i < VECTOR_LEN; i++)
            $display("  B[%0d] = %b => %f", i, B[i], fp4_to_shortreal(B[i]));
            $display("golden = %f   (bits=0x%08h)", golden);
            $display("dut = %f  (bits=0x%08h)", dut_fp32_value, d);
            $display("abs error = %e", abs_err);

            if (abs_err > 1e-3) begin
                $display(">> MISMATCH detected (abs_err > 1e-3).");
                $finish;
            end else begin
                $display(">> PASS");
            end

            // small gap between tests
            #20;
        end

        $display("All tests finished.");
        $finish;
    end

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_fp4_dot);
    end

endmodule
