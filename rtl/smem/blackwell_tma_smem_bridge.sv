// Connect the existing 32 B TMA/mbarrier memory ABI to actual shared SMEM.
// Auxiliary 128 B clients use the same array and the same aggregate bandwidth.
`default_nettype none
module blackwell_tma_smem_bridge #(
    parameter int unsigned AUX_CLIENTS = 7,
    parameter int unsigned ENTRIES = 8,
    parameter int unsigned MEM_ID_W = 6
) (
    input wire clk, rst_n,
    input wire mem_req_vld_i,
    output wire mem_req_rdy_o,
    input wire [31:0] mem_req_addr_i,
    input wire [255:0] mem_req_data_i,
    input wire [31:0] mem_req_mask_i,
    input wire [MEM_ID_W-1:0] mem_req_id_i,
    input tma_mbarrier_pkg::bw_mem_attr_t mem_req_attr_i,
    output wire mem_rsp_vld_o,
    input wire mem_rsp_rdy_i,
    output wire [255:0] mem_rsp_data_o,
    output wire [MEM_ID_W-1:0] mem_rsp_id_o,
    output wire [1:0] mem_rsp_status_o,
    input wire [AUX_CLIENTS-1:0] req_vld_i,
    output wire [AUX_CLIENTS-1:0] req_rdy_o,
    input wire [AUX_CLIENTS*32-1:0] req_addr_i,
    input wire [AUX_CLIENTS*1024-1:0] req_data_i,
    input wire [AUX_CLIENTS*128-1:0] req_mask_i,
    input wire [AUX_CLIENTS*2-1:0] req_kind_i,
    input wire [AUX_CLIENTS*4-1:0] req_dtype_i, req_op_i,
    input wire [AUX_CLIENTS*16-1:0] req_tag_i,
    output wire [AUX_CLIENTS-1:0] rsp_vld_o,
    input wire [AUX_CLIENTS-1:0] rsp_rdy_i,
    output wire [AUX_CLIENTS*1024-1:0] rsp_data_o,
    output wire [AUX_CLIENTS*16-1:0] rsp_tag_o,
    output wire [AUX_CLIENTS-1:0] rsp_error_o,
    output wire [AUX_CLIENTS:0] protocol_error_o
);
    wire [1023:0] mem_data;
    wire [15:0] mem_tag;
    wire mem_error;
    wire [1:0] mem_kind = mem_req_attr_i.multimem || mem_req_attr_i.kind > 2 ? 2'd3 : mem_req_attr_i.kind[1:0];
    assign mem_rsp_data_o = mem_data[255:0];
    assign mem_rsp_id_o = mem_tag[MEM_ID_W-1:0];
    assign mem_rsp_status_o = {1'b0,mem_error};
    blackwell_smem_system #(.CLIENTS(AUX_CLIENTS+1),.ENTRIES(ENTRIES)) shared_memory (
        .clk,.rst_n,
        .req_vld_i({req_vld_i,mem_req_vld_i}),.req_rdy_o({req_rdy_o,mem_req_rdy_o}),
        .req_addr_i({req_addr_i,mem_req_addr_i}),.req_data_i({req_data_i,768'd0,mem_req_data_i}),
        .req_mask_i({req_mask_i,96'd0,mem_req_mask_i}),.req_kind_i({req_kind_i,mem_kind}),
        .req_dtype_i({req_dtype_i,mem_req_attr_i.dtype}),.req_op_i({req_op_i,mem_req_attr_i.reduce_op}),
        .req_tag_i({req_tag_i,16'(mem_req_id_i)}),.rsp_vld_o({rsp_vld_o,mem_rsp_vld_o}),
        .rsp_rdy_i({rsp_rdy_i,mem_rsp_rdy_i}),.rsp_data_o({rsp_data_o,mem_data}),
        .rsp_tag_o({rsp_tag_o,mem_tag}),.rsp_error_o({rsp_error_o,mem_error}),.protocol_error_o
    );
    initial if (MEM_ID_W < 1 || MEM_ID_W > 16 || AUX_CLIENTS < 1) $error("Invalid TMA SMEM bridge configuration");
endmodule
`default_nettype wire
