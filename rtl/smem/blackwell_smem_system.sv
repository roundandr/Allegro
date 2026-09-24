// Shared byte-addressable SMEM endpoint for TMA, barrier, Tensor Core, TMEM CP
// and generic clients. No private per-engine copy of shared memory exists.
`default_nettype none
module blackwell_smem_system #(
    parameter int unsigned CLIENTS = 8,
    parameter int unsigned ENTRIES = 8,
    parameter int unsigned LINES = 1824,
    parameter int unsigned RESPONSE_DEPTH = 4,
    parameter int unsigned TAG_W = 16
) (
    input wire clk, rst_n,
    input wire [CLIENTS-1:0] req_vld_i,
    output wire [CLIENTS-1:0] req_rdy_o,
    input wire [CLIENTS*32-1:0] req_addr_i,
    input wire [CLIENTS*1024-1:0] req_data_i,
    input wire [CLIENTS*128-1:0] req_mask_i,
    input wire [CLIENTS*2-1:0] req_kind_i,
    input wire [CLIENTS*4-1:0] req_dtype_i, req_op_i,
    input wire [CLIENTS*TAG_W-1:0] req_tag_i,
    output wire [CLIENTS-1:0] rsp_vld_o,
    input wire [CLIENTS-1:0] rsp_rdy_i,
    output wire [CLIENTS*1024-1:0] rsp_data_o,
    output wire [CLIENTS*TAG_W-1:0] rsp_tag_o,
    output wire [CLIENTS-1:0] rsp_error_o,
    output wire [CLIENTS-1:0] protocol_error_o
);
    localparam int unsigned CW = CLIENTS < 2 ? 1 : $clog2(CLIENTS);
    wire [CLIENTS-1:0] rd_vld,rd_rdy,rd_rsp_vld,rd_rsp_rdy,rd_error;
    wire [CLIENTS-1:0] wr_vld,wr_rdy,wr_rsp_vld,wr_rsp_rdy,wr_error;
    wire [CLIENTS*32-1:0] rd_addr,wr_addr;
    wire [CLIENTS*16-1:0] rd_tag,rd_rsp_tag,wr_tag,wr_rsp_tag;
    wire [CLIENTS*1024-1:0] rd_data,wr_data;
    wire [CLIENTS*128-1:0] wr_mask;
    wire [CLIENTS-1:0] a_vld,a_rsp_rdy;
    logic [CLIENTS-1:0] a_rdy,a_rsp_vld;
    wire [CLIENTS*32-1:0] a_addr;
    wire [CLIENTS*1024-1:0] a_data;
    wire [CLIENTS*128-1:0] a_mask;
    wire [CLIENTS*16-1:0] a_tag;
    wire [CLIENTS*4-1:0] a_dtype,a_op;
    wire atom_rdy,atom_rsp_vld,atom_error;
    wire [15:0] atom_tag;
    logic [CW-1:0] atom_turn_q,atom_route_q,atom_hold_client_q;
    logic atom_hold_q;
    integer atom_sel;
    always_comb begin
        atom_sel = -1;
        for (int i = 0; i < CLIENTS; i++)
            if (a_vld[(int'(atom_turn_q)+i)%CLIENTS] && atom_sel < 0) atom_sel = (int'(atom_turn_q)+i)%CLIENTS;
        if (atom_hold_q) atom_sel = int'(atom_hold_client_q);
        a_rdy = '0; a_rsp_vld = '0;
        if (atom_sel >= 0) a_rdy[atom_sel] = atom_rdy;
        a_rsp_vld[atom_route_q] = atom_rsp_vld;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin atom_turn_q <= '0; atom_route_q <= '0; atom_hold_q <= 1'b0; atom_hold_client_q <= '0; end
        else if (atom_sel >= 0) begin
            if (atom_rdy) begin
                atom_route_q <= CW'(atom_sel); atom_hold_q <= 1'b0;
                atom_turn_q <= atom_sel == CLIENTS-1 ? '0 : CW'(atom_sel+1);
            end else begin atom_hold_q <= 1'b1; atom_hold_client_q <= CW'(atom_sel); end
        end
    end
    for (genvar c = 0; c < CLIENTS; c++) begin : gen_client
        blackwell_smem_port #(.ENTRIES(ENTRIES),.CAPACITY_BYTES(LINES*128),.TAG_W(TAG_W)) port (
            .clk,.rst_n,.req_vld_i(req_vld_i[c]),.req_rdy_o(req_rdy_o[c]),
            .req_addr_i(req_addr_i[c*32+:32]),.req_data_i(req_data_i[c*1024+:1024]),.req_mask_i(req_mask_i[c*128+:128]),
            .req_kind_i(req_kind_i[c*2+:2]),.req_dtype_i(req_dtype_i[c*4+:4]),.req_op_i(req_op_i[c*4+:4]),.req_tag_i(req_tag_i[c*TAG_W+:TAG_W]),
            .rsp_vld_o(rsp_vld_o[c]),.rsp_rdy_i(rsp_rdy_i[c]),.rsp_data_o(rsp_data_o[c*1024+:1024]),
            .rsp_tag_o(rsp_tag_o[c*TAG_W+:TAG_W]),.rsp_error_o(rsp_error_o[c]),
            .rd_vld_o(rd_vld[c]),.rd_rdy_i(rd_rdy[c]),.rd_addr_o(rd_addr[c*32+:32]),.rd_tag_o(rd_tag[c*16+:16]),
            .rd_rsp_vld_i(rd_rsp_vld[c]),.rd_rsp_rdy_o(rd_rsp_rdy[c]),.rd_data_i(rd_data[c*1024+:1024]),.rd_tag_i(rd_rsp_tag[c*16+:16]),.rd_error_i(rd_error[c]),
            .wr_vld_o(wr_vld[c]),.wr_rdy_i(wr_rdy[c]),.wr_addr_o(wr_addr[c*32+:32]),.wr_data_o(wr_data[c*1024+:1024]),
            .wr_mask_o(wr_mask[c*128+:128]),.wr_tag_o(wr_tag[c*16+:16]),.wr_rsp_vld_i(wr_rsp_vld[c]),.wr_rsp_rdy_o(wr_rsp_rdy[c]),
            .wr_tag_i(wr_rsp_tag[c*16+:16]),.wr_error_i(wr_error[c]),
            .atom_vld_o(a_vld[c]),.atom_rdy_i(a_rdy[c]),.atom_addr_o(a_addr[c*32+:32]),.atom_data_o(a_data[c*1024+:1024]),
            .atom_mask_o(a_mask[c*128+:128]),.atom_dtype_o(a_dtype[c*4+:4]),.atom_op_o(a_op[c*4+:4]),.atom_tag_o(a_tag[c*16+:16]),
            .atom_rsp_vld_i(a_rsp_vld[c]),.atom_rsp_rdy_o(a_rsp_rdy[c]),.atom_tag_i(atom_tag),.atom_error_i(atom_error),.protocol_error_o(protocol_error_o[c])
        );
    end
    blackwell_smem_backend #(.CLIENTS(CLIENTS),.RESPONSE_DEPTH(RESPONSE_DEPTH),.LINES(LINES)) backend (
        .clk,.rst_n,.rd_vld_i(rd_vld),.rd_rdy_o(rd_rdy),.rd_addr_i(rd_addr),.rd_tag_i(rd_tag),.rd_rsp_vld_o(rd_rsp_vld),.rd_rsp_rdy_i(rd_rsp_rdy),
        .rd_data_o(rd_data),.rd_tag_o(rd_rsp_tag),.rd_error_o(rd_error),
        .wr_vld_i(wr_vld),.wr_rdy_o(wr_rdy),.wr_addr_i(wr_addr),.wr_data_i(wr_data),.wr_mask_i(wr_mask),.wr_tag_i(wr_tag),
        .wr_rsp_vld_o(wr_rsp_vld),.wr_rsp_rdy_i(wr_rsp_rdy),.wr_tag_o(wr_rsp_tag),.wr_error_o(wr_error),
        .atom_vld_i(atom_sel >= 0),.atom_rdy_o(atom_rdy),
        .atom_addr_i(atom_sel >= 0 ? a_addr[atom_sel*32+:32] : 32'd0),
        .atom_data_i(atom_sel >= 0 ? a_data[atom_sel*1024+:1024] : 1024'd0),
        .atom_mask_i(atom_sel >= 0 ? a_mask[atom_sel*128+:128] : 128'd0),
        .atom_dtype_i(atom_sel >= 0 ? a_dtype[atom_sel*4+:4] : 4'd0),
        .atom_op_i(atom_sel >= 0 ? a_op[atom_sel*4+:4] : 4'd0),
        .atom_tag_i(atom_sel >= 0 ? a_tag[atom_sel*16+:16] : 16'd0),
        .atom_rsp_vld_o(atom_rsp_vld),.atom_rsp_rdy_i(a_rsp_rdy[atom_route_q]),.atom_tag_o(atom_tag),.atom_error_o(atom_error)
    );
endmodule
`default_nettype wire
