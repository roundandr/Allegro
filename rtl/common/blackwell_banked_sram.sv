// Shared physical primitive for TMEM/SMEM: one read and one byte-masked write
// per bank/cycle. Read-during-write returns the old word. Storage is not reset.
// Logical layouts, bank-conflict arbitration and ownership live above this ABI.
`default_nettype none
module blackwell_banked_sram #(
    parameter int unsigned BANKS = 128,
    parameter int unsigned DEPTH = 128,
    parameter int unsigned DATA_W = 128,
    parameter int unsigned TAG_W = 16,
    parameter int unsigned ADDR_W = (DEPTH < 2) ? 1 : $clog2(DEPTH)
) (
    input wire clk, rst_n,
    input wire rd_vld_i,
    output wire rd_rdy_o,
    input wire [BANKS-1:0] rd_mask_i,
    input wire [BANKS*ADDR_W-1:0] rd_addr_i,
    input wire [TAG_W-1:0] rd_tag_i,
    output wire rd_rsp_vld_o,
    input wire rd_rsp_rdy_i,
    output wire [BANKS*DATA_W-1:0] rd_data_o,
    output wire [TAG_W-1:0] rd_tag_o,
    output wire rd_error_o,
    input wire wr_vld_i,
    output wire wr_rdy_o,
    input wire [BANKS*ADDR_W-1:0] wr_addr_i,
    input wire [BANKS*DATA_W-1:0] wr_data_i,
    input wire [BANKS*DATA_W/8-1:0] wr_mask_i,
    input wire [TAG_W-1:0] wr_tag_i,
    output wire wr_rsp_vld_o,
    input wire wr_rsp_rdy_i,
    output wire [TAG_W-1:0] wr_tag_o,
    output wire wr_error_o
);
    localparam int unsigned BYTES = DATA_W/8;
    logic rd_vld_q, wr_vld_q, rd_error_q, wr_error_q;
    logic [TAG_W-1:0] rd_tag_q, wr_tag_q;
    logic [BANKS*DATA_W-1:0] rd_data_q;
    logic rd_bad, wr_bad;
    wire rd_fire = rd_vld_i && rd_rdy_o;
    wire wr_fire = wr_vld_i && wr_rdy_o;
    assign rd_rdy_o = !rd_vld_q || rd_rsp_rdy_i;
    assign wr_rdy_o = !wr_vld_q || wr_rsp_rdy_i;
    assign rd_rsp_vld_o = rd_vld_q;
    assign wr_rsp_vld_o = wr_vld_q;
    assign rd_data_o = rd_data_q;
    assign rd_tag_o = rd_tag_q;
    assign wr_tag_o = wr_tag_q;
    assign rd_error_o = rd_error_q;
    assign wr_error_o = wr_error_q;
    always_comb begin
        rd_bad = 1'b0; wr_bad = 1'b0;
        for (int b = 0; b < BANKS; b++) begin
            if (rd_mask_i[b] && int'(rd_addr_i[b*ADDR_W+:ADDR_W]) >= DEPTH) rd_bad = 1'b1;
            if ((|wr_mask_i[b*BYTES+:BYTES]) && int'(wr_addr_i[b*ADDR_W+:ADDR_W]) >= DEPTH) wr_bad = 1'b1;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_vld_q <= 1'b0; wr_vld_q <= 1'b0;
            rd_tag_q <= '0; wr_tag_q <= '0; rd_error_q <= 1'b0; wr_error_q <= 1'b0;
        end else begin
            if (rd_rdy_o) begin
                rd_vld_q <= rd_vld_i;
                if (rd_vld_i) begin rd_tag_q <= rd_tag_i; rd_error_q <= rd_bad; end
            end
            if (wr_rdy_o) begin
                wr_vld_q <= wr_vld_i;
                if (wr_vld_i) begin wr_tag_q <= wr_tag_i; wr_error_q <= wr_bad; end
            end
        end
    end
    for (genvar b = 0; b < BANKS; b++) begin : gen_bank
        // Replace this 1R1W memory with a technology macro preserving the ABI.
        logic [DATA_W-1:0] mem [0:DEPTH-1];
        always_ff @(posedge clk) begin
            if (rst_n && wr_fire && !wr_bad)
                for (int byte_idx = 0; byte_idx < BYTES; byte_idx++)
                    if (wr_mask_i[b*BYTES+byte_idx])
                        mem[wr_addr_i[b*ADDR_W+:ADDR_W]][byte_idx*8+:8] <=
                            wr_data_i[b*DATA_W+byte_idx*8+:8];
            if (rst_n && rd_fire) begin
                if (rd_mask_i[b] && !rd_bad)
                    rd_data_q[b*DATA_W+:DATA_W] <= mem[rd_addr_i[b*ADDR_W+:ADDR_W]];
                else rd_data_q[b*DATA_W+:DATA_W] <= '0;
            end
        end
    end
    initial begin
        if (BANKS < 1 || DEPTH < 1 || DATA_W < 8 || DATA_W % 8 != 0 ||
            ADDR_W < $clog2(DEPTH)) $error("Invalid banked SRAM geometry");
    end
endmodule
`default_nettype wire
