`default_nettype none
module tmem_array_tb #(
    parameter int unsigned PORT_MODE = 0
);
    logic clk;
    logic rst_n;
    logic [7:0] rd_vld_i;
    wire [7:0] rd_rdy_o;
    logic [7:0] rd_slot_i;
    logic [47:0] rd_row_i;
    logic [23:0] rd_col_i;
    logic [31:0] rd_tag_i;
    wire [7:0] rd_conflict_o;
    wire [7:0] rsp_vld_o;
    logic [7:0] rsp_rdy_i;
    wire [255:0] rsp_data_o;
    wire [31:0] rsp_tag_o;
    wire [7:0] rsp_error_o;
    logic row_wr_vld_i;
    wire row_wr_rdy_o;
    logic row_wr_slot_i;
    logic [5:0] row_wr_row_i;
    logic [255:0] row_wr_data_i;
    logic [7:0] row_wr_mask_i;

    tmem_array #(.PORT_MODE(PORT_MODE)) u_dut (.*);
endmodule
`default_nettype wire
