// Four partitions x 64 real FP16/BF16 dot pipelines. Each pipeline consumes a
// distinct 16-element A/B pair every accepted cycle and produces one FP32 D.
// Operand collection, TMEM accumulation scheduling and MMA instruction decoding
// live above this arithmetic array; they are not replaced by latency counters.
`default_nettype none
module blackwell_f16_dot_array #(
    parameter int unsigned DOTS = 256,
    parameter int unsigned TAG_W = 16,
    parameter int unsigned INFLIGHT = 32
) (
    input wire clk, rst_n,
    input wire in_vld_i, output wire in_rdy_o,
    input wire [TAG_W-1:0] tag_i,
    input wire [1:0] a_dtype_i, b_dtype_i,
    input wire [DOTS*256-1:0] a_vec_i, b_vec_i,
    input wire [DOTS*32-1:0] c_i,
    input wire [3:0] scale_input_d_i,
    output wire out_vld_o, input wire out_rdy_i,
    output wire [TAG_W-1:0] tag_o,
    output wire [DOTS*32-1:0] d_o
);
    wire [DOTS-1:0] lane_in_rdy, lane_out_vld;
    wire tag_in_rdy, tag_out_vld;
    wire issue_fire = in_vld_i && in_rdy_o;
    wire retire_fire = out_vld_o && out_rdy_i;
    wire lane_out_rdy = retire_fire;
    assign in_rdy_o = tag_in_rdy && (&lane_in_rdy);
    assign out_vld_o = tag_out_vld && (&lane_out_vld);
    blackwell_fifo #(.WIDTH(TAG_W),.DEPTH(INFLIGHT)) tag_queue (
        .clk,.rst_n,.in_vld_i(issue_fire),.in_rdy_o(tag_in_rdy),
        .in_data_i(tag_i),.out_vld_o(tag_out_vld),
        .out_rdy_i(retire_fire),.out_data_o(tag_o),.count_o()
    );
    for (genvar partition=0;partition<4;partition++) begin : gen_partition
        for (genvar stream=0;stream<DOTS/4;stream++) begin : gen_dot
            localparam int unsigned INDEX = partition*(DOTS/4)+stream;
            f16tf32_dot_prod arithmetic (
                .clk,.rst_n,.in_vld_i(issue_fire),.in_rdy_o(lane_in_rdy[INDEX]),
                .a_dtype_i(a_dtype_i),.b_dtype_i(b_dtype_i),
                .a_vec_i(a_vec_i[INDEX*256+:256]),
                .b_vec_i(b_vec_i[INDEX*256+:256]),
                .c_i(c_i[INDEX*32+:32]),.scale_input_d_i(scale_input_d_i),
                .out_vld_o(lane_out_vld[INDEX]),.out_rdy_i(lane_out_rdy),
                .d_o(d_o[INDEX*32+:32])
            );
        end
    end
    always_ff @(posedge clk) if (rst_n) begin
        for (int dot=1;dot<DOTS;dot++)
            assert (lane_out_vld[dot] == lane_out_vld[0])
                else $error("dot lanes lost lockstep");
    end
    initial if (DOTS < 4 || DOTS % 4 != 0 || INFLIGHT < 1)
        $error("Invalid f16 dot array geometry");
endmodule
`default_nettype wire
