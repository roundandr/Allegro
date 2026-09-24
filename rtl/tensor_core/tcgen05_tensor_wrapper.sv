// ============================================================================
// File Name   : tcgen05_tensor_wrapper.sv
// Description : Eight-lane dense FP16 TCGen05 wrapper for one M row.
// ============================================================================

`default_nettype none

module tcgen05_tensor_wrapper #(
    parameter int unsigned LANES = 8,
    parameter int unsigned TAG_W = 7,
    parameter int unsigned REG_SLICE = 1
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      in_vld_i,
    output logic                      in_rdy_o,
    input  logic [255:0]              a_vec_i,
    input  logic [LANES*256-1:0]      b_vec_i,
    input  logic [LANES*32-1:0]       c_vec_i,
    input  logic                      accumulate_i,
    input  logic [TAG_W-1:0]          tag_i,

    output logic                      out_vld_o,
    input  logic                      out_rdy_i,
    output logic [LANES*32-1:0]       d_vec_o,
    output logic [7:0]                status_o,
    output logic [TAG_W-1:0]          tag_o
);

    logic [LANES-1:0] lane_in_rdy;
    logic [LANES-1:0] lane_out_vld;
    logic [LANES-1:0] lane_out_rdy;
    logic [31:0]      lane_d [0:LANES-1];
    logic [LANES*32-1:0] raw_d_vec;
    logic [7:0]       lane_status [0:LANES-1];
    logic [TAG_W-1:0] lane_tag [0:LANES-1];
    logic             issue_fire;
    logic [7:0]       status_comb;

    assign in_rdy_o   = &lane_in_rdy;
    assign issue_fire = in_vld_i && in_rdy_o;
    always_comb begin
        status_comb = 8'h00;
        for (int unsigned lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
            status_comb = status_comb | lane_status[lane_idx];
        end
    end
    generate
        genvar gen_lane;
        for (gen_lane = 0; gen_lane < LANES; gen_lane = gen_lane + 1) begin : gen_tc_lane
            assign raw_d_vec[gen_lane*32 +: 32] = lane_d[gen_lane];

            tcgen05_dot_adapter #(.TAG_W(TAG_W)) u_tcgen05_dot_adapter (
                .tag_i(tag_i), .tag_o(lane_tag[gen_lane]),
                .clk               (clk),
                .rst_n             (rst_n),
                .in_vld_i          (issue_fire),
                .in_rdy_o          (lane_in_rdy[gen_lane]),
                .op_i              (2'd0),
                .kind_i            (4'd0),
                .d_type_i          (4'd0),
                .a_type_i          (4'd1),
                .b_type_i          (4'd1),
                .scale_type_i      (3'd0),
                .scale_vec_i       (3'd0),
                .cta_group_i       (1'b0),
                .enable_input_d_i  (accumulate_i),
                .scale_input_d_i   (4'd0),
                .a_vec_i           (a_vec_i),
                .b_vec_i           ({256'd0, b_vec_i[gen_lane*256 +: 256]}),
                .sparse_meta_i     (128'd0),
                .c_i               (c_vec_i[gen_lane*32 +: 32]),
                .a_sf_i            (32'd0),
                .b_sf_i            (32'd0),
                .out_vld_o         (lane_out_vld[gen_lane]),
                .out_rdy_i         (lane_out_rdy[gen_lane]),
                .d_o               (lane_d[gen_lane]),
                .status_o          (lane_status[gen_lane])
            );
        end
    endgenerate

    generate
        if (REG_SLICE == 0) begin : gen_no_output_slice
            assign out_vld_o = &lane_out_vld;
            assign lane_out_rdy = {LANES{out_vld_o && out_rdy_i}};
            assign d_vec_o = raw_d_vec;
            assign status_o = status_comb;
            assign tag_o = lane_tag[0];
        end else begin : gen_output_slice
            logic [REG_SLICE-1:0] pipe_vld_q;
            logic [REG_SLICE-1:0] pipe_rdy;
            logic [LANES*32-1:0]  pipe_data_q [0:REG_SLICE-1];
            logic [7:0]           pipe_status_q [0:REG_SLICE-1];
            logic [TAG_W-1:0]     pipe_tag_q [0:REG_SLICE-1];

            always_comb begin
                pipe_rdy[REG_SLICE-1] = !pipe_vld_q[REG_SLICE-1] || out_rdy_i;
                for (int signed slice_idx = REG_SLICE - 2; slice_idx >= 0;
                     slice_idx = slice_idx - 1) begin
                    pipe_rdy[slice_idx] = !pipe_vld_q[slice_idx] || pipe_rdy[slice_idx+1];
                end
            end

            assign lane_out_rdy = {LANES{(&lane_out_vld) && pipe_rdy[0]}};
            assign out_vld_o = pipe_vld_q[REG_SLICE-1];
            assign d_vec_o = pipe_data_q[REG_SLICE-1];
            assign status_o = pipe_status_q[REG_SLICE-1];
            assign tag_o = pipe_tag_q[REG_SLICE-1];

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pipe_vld_q <= '0;
                    for (int unsigned rst_slice_idx = 0; rst_slice_idx < REG_SLICE;
                         rst_slice_idx = rst_slice_idx + 1) begin
                        pipe_data_q[rst_slice_idx] <= '0;
                        pipe_status_q[rst_slice_idx] <= 8'h00;
                        pipe_tag_q[rst_slice_idx] <= '0;
                    end
                end else begin
                    if (pipe_rdy[0]) begin
                        pipe_vld_q[0] <= &lane_out_vld;
                        if (&lane_out_vld) begin
                            pipe_data_q[0] <= raw_d_vec;
                            pipe_status_q[0] <= status_comb;
                            pipe_tag_q[0] <= lane_tag[0];
                        end
                    end
                    for (int unsigned upd_slice_idx = 1; upd_slice_idx < REG_SLICE;
                         upd_slice_idx = upd_slice_idx + 1) begin
                        if (pipe_rdy[upd_slice_idx]) begin
                            pipe_vld_q[upd_slice_idx] <= pipe_vld_q[upd_slice_idx-1];
                            if (pipe_vld_q[upd_slice_idx-1]) begin
                                pipe_data_q[upd_slice_idx] <= pipe_data_q[upd_slice_idx-1];
                                pipe_status_q[upd_slice_idx] <= pipe_status_q[upd_slice_idx-1];
                                pipe_tag_q[upd_slice_idx] <= pipe_tag_q[upd_slice_idx-1];
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    initial begin
        if (REG_SLICE > 2) $error("REG_SLICE must be 0, 1, or 2");
    end

endmodule

`default_nettype wire
