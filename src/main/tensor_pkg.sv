package tensor_pkg;
    typedef struct packed {
        logic                      sign;
        logic [EXP_WIDTH-1:0]      exp;
        logic [SIG_WIDTH-1:0]      sig;
        logic                      exp_is_zero;
        logic                      sig_is_zero;
        logic                      exp_is_ones;
        logic                      is_subnormal;
        logic                      is_Inf;
        logic                      is_zero;
        logic                      is_nan;
    } fp_decode_t #(
        parameter int EXP_WIDTH = 8,
        parameter int SIG_WIDTH = 24
    );

    function automatic fp_decode_t#(EXP_WIDTH, SIG_WIDTH) fp_decode #(
        parameter int EXP_WIDTH = 8,
        parameter int SIG_WIDTH = 24,
        parameter bit FLUSH_SUBNORMAL_TO_ZERO = 1'b0
    ) (
        input logic [EXP_WIDTH+SIG_WIDTH-1:0] x
    );
        fp_decode_t #(EXP_WIDTH, SIG_WIDTH) f;
        logic [EXP_WIDTH-1:0] raw_exp;
        logic [SIG_WIDTH-2:0] raw_frac;
        logic raw_exp_is_zero;
        logic raw_exp_is_ones;
        logic raw_frac_is_zero;
        logic raw_is_subnormal;

        f.sign = x[EXP_WIDTH+SIG_WIDTH-1];
        raw_exp  = x[EXP_WIDTH+SIG_WIDTH-2 -: EXP_WIDTH];
        raw_frac = x[SIG_WIDTH-2:0];

        raw_exp_is_zero  = ~(|raw_exp);
        raw_exp_is_ones  = &raw_exp;
        raw_frac_is_zero = ~(|raw_frac);
        raw_is_subnormal = raw_exp_is_zero && !raw_frac_is_zero;

        f.exp_is_ones  = raw_exp_is_ones;
        f.is_Inf       = raw_exp_is_ones && raw_frac_is_zero;
        f.is_nan       = raw_exp_is_ones && !raw_frac_is_zero;
        f.is_subnormal = (!FLUSH_SUBNORMAL_TO_ZERO) && raw_is_subnormal;
        f.is_zero      = (raw_exp_is_zero && raw_frac_is_zero) ||
                         (FLUSH_SUBNORMAL_TO_ZERO && raw_is_subnormal);

        if (FLUSH_SUBNORMAL_TO_ZERO && raw_is_subnormal) begin
            f.exp = '0;
            f.sig = '0;
        end else begin
            f.exp = raw_exp;
            if (f.is_zero || f.is_Inf) begin
                f.sig = '0;
            end else begin
                // decoded significand: hidden bit + fraction field
                f.sig = {(~raw_exp_is_zero) && !f.is_nan, raw_frac};
            end
        end

        f.exp_is_zero = ~(|f.exp);
        f.sig_is_zero = ~(|f.sig);
        return f;
    endfunction
endpackage
