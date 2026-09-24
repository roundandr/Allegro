// Warp RF staging: one SRAM bank per thread, 128 registers per thread.
// A beat can write all 32 banks; partial byte enables support packed LD.
// The read response is elastic and supplies one 1024-bit warp register beat.
`default_nettype none
module blackwell_tmem_rf_stage (
    input wire clk, rst_n,
    input wire rd_vld_i, output wire rd_rdy_o,
    input wire [6:0] rd_reg_i,
    output wire rd_rsp_vld_o, input wire rd_rsp_rdy_i,
    output wire [1023:0] rd_rsp_data_o,
    input wire wr_vld_i, output wire wr_rdy_o,
    input wire [6:0] wr_reg_i,
    input wire [1023:0] wr_data_i,
    input wire [127:0] wr_byte_mask_i
);
    logic [223:0] rd_addr, wr_addr;
    wire unused_rd_error, unused_wr_error, unused_wr_rsp;
    wire [0:0] unused_rd_tag, unused_wr_tag;
    always_comb begin
        rd_addr='0; wr_addr='0;
        for (int t=0;t<32;t++) begin
            rd_addr[t*7+:7]=rd_reg_i;
            wr_addr[t*7+:7]=wr_reg_i;
        end
    end
    blackwell_banked_sram #(.BANKS(32),.DEPTH(128),.DATA_W(32),
                            .TAG_W(1)) storage (
        .clk,.rst_n,
        .rd_vld_i,.rd_rdy_o,.rd_mask_i(32'hFFFFFFFF),.rd_addr_i(rd_addr),
        .rd_tag_i(1'b0),.rd_rsp_vld_o,.rd_rsp_rdy_i,
        .rd_data_o(rd_rsp_data_o),.rd_tag_o(unused_rd_tag),
        .rd_error_o(unused_rd_error),
        .wr_vld_i,.wr_rdy_o,.wr_addr_i(wr_addr),.wr_data_i,
        .wr_mask_i(wr_byte_mask_i),.wr_tag_i(1'b0),
        .wr_rsp_vld_o(unused_wr_rsp),.wr_rsp_rdy_i(1'b1),
        .wr_tag_o(unused_wr_tag),.wr_error_o(unused_wr_error)
    );
endmodule
`default_nettype wire
