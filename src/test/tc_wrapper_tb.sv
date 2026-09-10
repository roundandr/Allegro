`default_nettype none
module tc_wrapper_tb #(
    parameter int unsigned REG_SLICE = 1
);
    logic clk;
    logic rst_n;
    logic in_vld_i;
    wire in_rdy_o;
    logic [255:0] a_vec_i;
    logic [2047:0] b_vec_i;
    logic [255:0] c_vec_i;
    logic accumulate_i;
    logic [6:0] tag_i;
    wire out_vld_o;
    logic out_rdy_i;
    wire [255:0] d_vec_o;
    wire [7:0] status_o;
    wire [6:0] tag_o;
    tcgen05_tensor_wrapper #(.REG_SLICE(REG_SLICE)) u_dut (.*);
endmodule
`default_nettype wire
