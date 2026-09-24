// ============================================================================
// File Name   : f16tf32_f4f6f8_shared_dot_prod.sv
// Author      : LIU YUXUAN
// Date        : 2026-06-03
// Description : Combined F16TF32 and F4/F6/F8 dot-product core.  Per-format
//               S0-S2 frontends are kept in separate modules.  This shared
//               layer physically shares the 17-term accumulation tree and the
//               FP32 RZ normalize/pack block.
// ============================================================================

module f16tf32_f4f6f8_shared_dot_prod #(
    parameter int META_W = 16
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         in_vld_i,
    output logic         in_rdy_o,
    input  logic         mode_i,
    input  logic [1:0]   f16tf32_dtype_i,
    input  logic [2:0]   f4f6f8_dtype_i,
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  c_i,
    input  logic [3:0]   scale_input_d_i,
    input  logic         mxfp8_en_i,
    input  logic [7:0]   a_mx_scale_i,
    input  logic [7:0]   b_mx_scale_i,
    input  logic [META_W-1:0] meta_i,

    output logic         out_vld_o,
    input  logic         out_rdy_i,
    output logic [31:0]  d_o,
    output logic [META_W-1:0] meta_o
);

    import dot_prod_pkg::*;

    localparam logic MODE_F16TF32      = 1'b0;
    localparam logic MODE_F4F6F8   = 1'b1;
    localparam int   SHARED_SUM_W  = DOT_F4F6F8_SUM_W;
    localparam int   SHARED_EXP_W  = DOT_F4F6F8_FULL_EXP_W;
    localparam int   SHARED_TERM_N = DOT_F4F6F8_NUM_ELEMS + 1;

    typedef struct packed {
        logic mode;
        logic [META_W-1:0] meta;
        logic signed [SHARED_SUM_W-1:0] sum_lo;
        logic signed [SHARED_SUM_W-1:0] sum_hi;
        logic signed [SHARED_EXP_W-1:0] base_exp;
        logic special_vld;
        logic [31:0] special_result;
    } stage3_data_t;

    typedef struct packed {
        logic [META_W-1:0] meta;
        logic signed [SHARED_SUM_W-1:0] sum;
        logic signed [SHARED_EXP_W-1:0] base_exp;
        logic special_vld;
        logic [31:0] special_result;
    } stage4_data_t;

    logic f16tf32_front_in_vld;
    logic f16tf32_front_in_rdy;
    logic f16tf32_front_out_vld;
    logic f16tf32_front_out_rdy;
    logic [SHARED_TERM_N*SHARED_SUM_W-1:0] f16tf32_front_term_flat;
    logic signed [SHARED_EXP_W-1:0] f16tf32_front_base_exp;
    logic f16tf32_front_special_vld;
    logic [31:0] f16tf32_front_special_result;
    logic [META_W-1:0] f16tf32_front_meta;

    logic f4_front_in_vld;
    logic f4_front_in_rdy;
    logic f4_front_out_vld;
    logic f4_front_out_rdy;
    logic [SHARED_TERM_N*SHARED_SUM_W-1:0] f4_front_term_flat;
    logic signed [SHARED_EXP_W-1:0] f4_front_base_exp;
    logic f4_front_special_vld;
    logic [31:0] f4_front_special_result;
    logic [META_W-1:0] f4_front_meta;

    logic front_out_vld;
    logic front_mode;
    logic [SHARED_TERM_N*SHARED_SUM_W-1:0] front_term_flat;
    logic signed [SHARED_EXP_W-1:0] front_base_exp;
    logic front_special_vld;
    logic [31:0] front_special_result;
    logic [META_W-1:0] front_meta;

    stage3_data_t s3_d;
    stage3_data_t s3_q;
    stage4_data_t f4_s4_d;
    stage4_data_t f4_s4_q;

    logic s3_vld_q;
    logic f4_s4_vld_q;
    logic s3_in_rdy;
    logic s3_out_rdy;
    logic f4_s4_in_rdy;
    logic f4_s4_out_fire;
    logic s3_to_f4_s4_fire;

    logic pack_f16tf32_sel;
    logic pack_f4_sel;
    logic pack_in_vld;
    logic pack_fire;
    logic out_reg_rdy;
    logic out_fire;

    logic signed [SHARED_SUM_W-1:0] pack_sum;
    logic signed [SHARED_EXP_W-1:0] pack_base_exp;
    logic                           pack_special_vld;
    logic [31:0]                    pack_special_result;
    logic [META_W-1:0]              pack_meta;
    logic [31:0]                    pack_result;
    logic                           out_vld_q;
    logic [31:0]                    out_d_q;
    logic [META_W-1:0]              out_meta_q;

    logic [17*SHARED_SUM_W-1:0]     s3_sum_lo_term_flat;
    logic [16*SHARED_SUM_W-1:0]     s3_sum_hi_term_flat;
    logic signed [SHARED_SUM_W-1:0] s3_sum_lo;
    logic signed [SHARED_SUM_W-1:0] s3_sum_hi;

    assign f16tf32_front_in_vld = in_vld_i && (mode_i == MODE_F16TF32);
    assign f4_front_in_vld  = in_vld_i && (mode_i == MODE_F4F6F8);
    assign in_rdy_o = (mode_i == MODE_F16TF32) ? f16tf32_front_in_rdy : f4_front_in_rdy;

    f16tf32_s0_s2_frontend #(
        .META_W(META_W)
    ) u_f16tf32_s0_s2_frontend (
        .clk             (clk),
        .rst_n           (rst_n),
        .in_vld_i        (f16tf32_front_in_vld),
        .in_rdy_o        (f16tf32_front_in_rdy),
        .f16tf32_dtype_i  (f16tf32_dtype_i),
        .a_vec_i         (a_vec_i),
        .b_vec_i         (b_vec_i),
        .c_i             (c_i),
        .scale_input_d_i (scale_input_d_i),
        .meta_i          (meta_i),
        .out_vld_o       (f16tf32_front_out_vld),
        .out_rdy_i       (f16tf32_front_out_rdy),
        .term_flat_o     (f16tf32_front_term_flat),
        .base_exp_o      (f16tf32_front_base_exp),
        .special_vld_o   (f16tf32_front_special_vld),
        .special_result_o(f16tf32_front_special_result),
        .meta_o          (f16tf32_front_meta)
    );

    f4f6f8_s0_s2_frontend #(
        .META_W(META_W)
    ) u_f4f6f8_s0_s2_frontend (
        .clk             (clk),
        .rst_n           (rst_n),
        .in_vld_i        (f4_front_in_vld),
        .in_rdy_o        (f4_front_in_rdy),
        .f4f6f8_dtype_i  (f4f6f8_dtype_i),
        .a_vec_i         (a_vec_i),
        .b_vec_i         (b_vec_i),
        .c_i             (c_i),
        .mxfp8_en_i      (mxfp8_en_i),
        .a_mx_scale_i    (a_mx_scale_i),
        .b_mx_scale_i    (b_mx_scale_i),
        .meta_i          (meta_i),
        .out_vld_o       (f4_front_out_vld),
        .out_rdy_i       (f4_front_out_rdy),
        .term_flat_o     (f4_front_term_flat),
        .base_exp_o      (f4_front_base_exp),
        .special_vld_o   (f4_front_special_vld),
        .special_result_o(f4_front_special_result),
        .meta_o          (f4_front_meta)
    );

    assign front_out_vld = f16tf32_front_out_vld || f4_front_out_vld;
    assign front_mode = f4_front_out_vld ? MODE_F4F6F8 : MODE_F16TF32;
    assign front_term_flat = f4_front_out_vld ? f4_front_term_flat : f16tf32_front_term_flat;
    assign front_base_exp = f4_front_out_vld ? f4_front_base_exp : f16tf32_front_base_exp;
    assign front_special_vld = f4_front_out_vld ? f4_front_special_vld : f16tf32_front_special_vld;
    assign front_special_result = f4_front_out_vld ? f4_front_special_result : f16tf32_front_special_result;
    assign front_meta = f4_front_out_vld ? f4_front_meta : f16tf32_front_meta;
    assign f16tf32_front_out_rdy = s3_in_rdy;
    assign f4_front_out_rdy  = s3_in_rdy;

    genvar s3_term_idx;
    generate
        for (s3_term_idx = 0; s3_term_idx < 17; s3_term_idx = s3_term_idx + 1) begin : gen_s3_sum_lo_terms
            assign s3_sum_lo_term_flat[s3_term_idx*SHARED_SUM_W +: SHARED_SUM_W] =
                front_term_flat[s3_term_idx*SHARED_SUM_W +: SHARED_SUM_W];
        end
        for (s3_term_idx = 0; s3_term_idx < 16; s3_term_idx = s3_term_idx + 1) begin : gen_s3_sum_hi_terms
            assign s3_sum_hi_term_flat[s3_term_idx*SHARED_SUM_W +: SHARED_SUM_W] =
                front_term_flat[(17+s3_term_idx)*SHARED_SUM_W +: SHARED_SUM_W];
        end
    endgenerate

    dot_signed_reduce_tree #(
        .TERM_W(SHARED_SUM_W),
        .TERM_N(17)
    ) u_s3_sum_lo_tree (
        .term_flat_i(s3_sum_lo_term_flat),
        .sum_o      (s3_sum_lo)
    );

    dot_signed_reduce_tree #(
        .TERM_W(SHARED_SUM_W),
        .TERM_N(16)
    ) u_s3_sum_hi_tree (
        .term_flat_i(s3_sum_hi_term_flat),
        .sum_o      (s3_sum_hi)
    );

    always_comb begin
        s3_d = '0;
        s3_d.mode = front_mode;
        s3_d.meta = front_meta;
        s3_d.base_exp = front_base_exp;
        s3_d.special_vld = front_special_vld;
        s3_d.special_result = front_special_result;
        s3_d.sum_lo = s3_sum_lo;
        s3_d.sum_hi = (front_mode == MODE_F4F6F8) ? s3_sum_hi : '0;
    end

    always_comb begin
        f4_s4_d = '0;
        f4_s4_d.meta = s3_q.meta;
        f4_s4_d.sum = s3_q.sum_lo + s3_q.sum_hi;
        f4_s4_d.base_exp = s3_q.base_exp;
        f4_s4_d.special_vld = s3_q.special_vld;
        f4_s4_d.special_result = s3_q.special_result;
    end

    assign out_reg_rdy = !out_vld_q || out_rdy_i;
    assign pack_f16tf32_sel = s3_vld_q && (s3_q.mode == MODE_F16TF32);
    assign pack_f4_sel      = !pack_f16tf32_sel && f4_s4_vld_q;
    assign pack_in_vld      = pack_f16tf32_sel || pack_f4_sel;
    assign pack_fire    = pack_in_vld && out_reg_rdy;
    assign out_fire     = out_vld_q && out_rdy_i;

    assign f4_s4_out_fire = pack_f4_sel && out_reg_rdy;
    assign f4_s4_in_rdy = !f4_s4_vld_q || f4_s4_out_fire;
    assign s3_to_f4_s4_fire = s3_vld_q && (s3_q.mode == MODE_F4F6F8) && f4_s4_in_rdy;
    assign s3_out_rdy = !s3_vld_q || ((s3_q.mode == MODE_F16TF32) ? out_reg_rdy : f4_s4_in_rdy);

    always_comb begin
        pack_sum = s3_q.sum_lo;
        pack_base_exp = s3_q.base_exp;
        pack_special_vld = s3_q.special_vld;
        pack_special_result = s3_q.special_result;
        pack_meta = s3_q.meta;

        if (pack_f4_sel) begin
            pack_sum = f4_s4_q.sum;
            pack_base_exp = f4_s4_q.base_exp;
            pack_special_vld = f4_s4_q.special_vld;
            pack_special_result = f4_s4_q.special_result;
            pack_meta = f4_s4_q.meta;
        end
    end

    dot_fp32_rz_norm_pack #(
        .SUM_W(SHARED_SUM_W),
        .EXP_W(SHARED_EXP_W),
        .CANONICALIZE_ZERO_RESULT(1'b0)
    ) u_dot_fp32_rz_norm_pack (
        .sum_i           (pack_sum),
        .base_exp_i      (pack_base_exp),
        .special_vld_i   (pack_special_vld),
        .special_result_i(pack_special_result),
        .result_o        (pack_result)
    );

    pipeline_reg #(
        .W($bits(stage3_data_t))
    ) u_stage3_reg (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (front_out_vld),
        .in_ready (s3_in_rdy),
        .in_data  (s3_d),
        .out_valid(s3_vld_q),
        .out_ready(s3_out_rdy),
        .out_data (s3_q)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f4_s4_vld_q <= 1'b0;
            f4_s4_q     <= '0;
        end else begin
            if (s3_to_f4_s4_fire) begin
                f4_s4_vld_q <= 1'b1;
                f4_s4_q     <= f4_s4_d;
            end else if (f4_s4_out_fire) begin
                f4_s4_vld_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vld_q  <= 1'b0;
            out_d_q    <= '0;
            out_meta_q <= '0;
        end else begin
            if (pack_fire) begin
                out_vld_q  <= 1'b1;
                out_d_q    <= pack_result;
                out_meta_q <= pack_meta;
            end else if (out_fire) begin
                out_vld_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    always @(*) begin
        if (rst_n) begin
            assert (!(f16tf32_front_out_vld && f4_front_out_vld));
            assert (!(s3_vld_q && (s3_q.mode == MODE_F16TF32) && f4_s4_vld_q));
        end
    end
`endif

    assign out_vld_o = out_vld_q;
    assign d_o       = out_d_q;
    assign meta_o    = out_meta_q;

endmodule
