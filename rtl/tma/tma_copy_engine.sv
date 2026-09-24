// Data operations retain their queue; map control owns the backend only after prior copies drain.
`default_nettype none
module tma_copy_engine #(
    parameter int unsigned ADDR_W             = 64,
    parameter int unsigned SMEM_ADDR_W        = 32,
    parameter int unsigned CMD_QUEUE_DEPTH    = 8,
    parameter int unsigned DESC_CACHE_ENTRIES = 4,
    parameter int unsigned MSHR_ENTRIES       = 16,
    parameter int unsigned GMEM_ID_W          = 5,
    parameter int unsigned SMEM_ID_W          = 5
) (

    input tma_mbarrier_pkg::tma_cmd_t tma_cmd_i,
    output tma_mbarrier_pkg::bw_mem_attr_t gmem_req_attr_o,
    output tma_mbarrier_pkg::bw_mem_attr_t smem_req_attr_o,
    output wire tma_order_req_vld_o,
    input wire tma_order_req_rdy_i,
    output tma_mbarrier_pkg::bw_order_req_t tma_order_req_o,
    input wire tma_order_rsp_vld_i,
    output wire tma_order_rsp_rdy_o,
    input tma_mbarrier_pkg::bw_order_rsp_t tma_order_rsp_i,
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         tma_cmd_vld_i,
    output wire                         tma_cmd_rdy_o,

    output wire                         desc_done_o,
    output wire                         source_done_o,
    output wire [15:0]                  event_tag_o,
    output wire                         tma_rsp_vld_o,
    input  wire                         tma_rsp_rdy_i,
    output wire [15:0]                  tma_rsp_tag_o,
    output wire [7:0]                   tma_rsp_status_o,
    output wire [63:0]                  tma_rsp_bytes_o,

    output wire                         gmem_req_vld_o,
    input  wire                         gmem_req_rdy_i,
    output wire                         gmem_req_write_o,
    output wire [ADDR_W-1:0]            gmem_req_addr_o,
    output wire [1023:0]                gmem_req_data_o,
    output wire [127:0]                 gmem_req_mask_o,
    output wire [GMEM_ID_W-1:0]         gmem_req_id_o,

    input  wire                         gmem_rsp_vld_i,
    output wire                         gmem_rsp_rdy_o,
    input  wire [1023:0]                gmem_rsp_data_i,
    input  wire [1:0]                   gmem_rsp_status_i,
    input  wire [GMEM_ID_W-1:0]         gmem_rsp_id_i,

    output wire                         smem_req_vld_o,
    input  wire                         smem_req_rdy_i,
    output wire                         smem_req_write_o,
    output wire [SMEM_ADDR_W-1:0]       smem_req_addr_o,
    output wire [255:0]                 smem_req_data_o,
    output wire [31:0]                  smem_req_mask_o,
    output wire [SMEM_ID_W-1:0]         smem_req_id_o,

    input  wire                         smem_rsp_vld_i,
    output wire                         smem_rsp_rdy_o,
    input  wire [255:0]                 smem_rsp_data_i,
    input  wire [1:0]                   smem_rsp_status_i,
    input  wire [SMEM_ID_W-1:0]         smem_rsp_id_i,

    output wire                         tx_cpl_vld_o,
    input  wire                         tx_cpl_rdy_i,
    output wire [15:0]                  tx_cpl_tag_o,
    output wire [ADDR_W-1:0]            tx_cpl_addr_o,
    output wire [63:0]                  tx_cpl_bytes_o,

    input  wire                         tx_rsp_vld_i,
    output wire                         tx_rsp_rdy_o,
    input  wire [15:0]                  tx_rsp_tag_i,
    input  wire [7:0]                   tx_rsp_status_i,
    input  wire                         tx_rsp_phase_i
);
    import tma_mbarrier_pkg::*;
    localparam int COUNT_W=$clog2(CMD_QUEUE_DEPTH+2);
    logic [COUNT_W-1:0] outstanding_q;
    logic map_active_q;
    wire map_command = tma_cmd_i.opcode >= TMA_OP_MAP_REPLACE;
    wire data_cmd_rdy, map_cmd_rdy, data_rsp_vld, map_rsp_vld;
    wire [15:0] data_rsp_tag;
    wire [7:0] data_rsp_status;
    wire [63:0] data_rsp_bytes;
    tma_rsp_t map_rsp;
    wire accept = tma_cmd_vld_i && tma_cmd_rdy_o;
    assign tma_cmd_rdy_o = !map_active_q && (map_command ? (outstanding_q==0 && map_cmd_rdy) : data_cmd_rdy);
    assign tma_rsp_vld_o = map_active_q ? map_rsp_vld : data_rsp_vld;
    assign tma_rsp_tag_o = map_active_q ? map_rsp.tag : data_rsp_tag;
    assign tma_rsp_status_o = map_active_q ? map_rsp.status : data_rsp_status;
    assign tma_rsp_bytes_o = map_active_q ? map_rsp.bytes : data_rsp_bytes;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin outstanding_q <= 0; map_active_q <= 0; end
        else begin
            case ({accept && !map_command, data_rsp_vld && tma_rsp_rdy_i})
                2'b10:outstanding_q <= outstanding_q+COUNT_W'(1);
                2'b01:outstanding_q <= outstanding_q-COUNT_W'(1);
                default: begin end
            endcase
            if (accept && map_command) map_active_q <= 1'b1;
            if (map_active_q && map_rsp_vld && tma_rsp_rdy_i) map_active_q <= 1'b0;
        end
    end
    tma_mbarrier_pkg::bw_mem_attr_t data_gmem_req_attr_o, map_gmem_req_attr_o;
    assign gmem_req_attr_o = map_active_q ? map_gmem_req_attr_o : data_gmem_req_attr_o;
    tma_mbarrier_pkg::bw_mem_attr_t data_smem_req_attr_o, map_smem_req_attr_o;
    assign smem_req_attr_o = map_active_q ? map_smem_req_attr_o : data_smem_req_attr_o;
    logic data_tma_order_req_vld_o, map_tma_order_req_vld_o;
    assign tma_order_req_vld_o = map_active_q ? map_tma_order_req_vld_o : data_tma_order_req_vld_o;
    tma_mbarrier_pkg::bw_order_req_t data_tma_order_req_o, map_tma_order_req_o;
    assign tma_order_req_o = map_active_q ? map_tma_order_req_o : data_tma_order_req_o;
    logic data_tma_order_rsp_rdy_o, map_tma_order_rsp_rdy_o;
    assign tma_order_rsp_rdy_o = map_active_q ? map_tma_order_rsp_rdy_o : data_tma_order_rsp_rdy_o;
    logic data_gmem_req_vld_o, map_gmem_req_vld_o;
    assign gmem_req_vld_o = map_active_q ? map_gmem_req_vld_o : data_gmem_req_vld_o;
    logic data_gmem_req_write_o, map_gmem_req_write_o;
    assign gmem_req_write_o = map_active_q ? map_gmem_req_write_o : data_gmem_req_write_o;
    logic [ADDR_W-1:0] data_gmem_req_addr_o, map_gmem_req_addr_o;
    assign gmem_req_addr_o = map_active_q ? map_gmem_req_addr_o : data_gmem_req_addr_o;
    logic [1023:0] data_gmem_req_data_o, map_gmem_req_data_o;
    assign gmem_req_data_o = map_active_q ? map_gmem_req_data_o : data_gmem_req_data_o;
    logic [127:0] data_gmem_req_mask_o, map_gmem_req_mask_o;
    assign gmem_req_mask_o = map_active_q ? map_gmem_req_mask_o : data_gmem_req_mask_o;
    logic [GMEM_ID_W-1:0] data_gmem_req_id_o, map_gmem_req_id_o;
    assign gmem_req_id_o = map_active_q ? map_gmem_req_id_o : data_gmem_req_id_o;
    logic data_gmem_rsp_rdy_o, map_gmem_rsp_rdy_o;
    assign gmem_rsp_rdy_o = map_active_q ? map_gmem_rsp_rdy_o : data_gmem_rsp_rdy_o;
    logic data_smem_req_vld_o, map_smem_req_vld_o;
    assign smem_req_vld_o = map_active_q ? map_smem_req_vld_o : data_smem_req_vld_o;
    logic data_smem_req_write_o, map_smem_req_write_o;
    assign smem_req_write_o = map_active_q ? map_smem_req_write_o : data_smem_req_write_o;
    logic [SMEM_ADDR_W-1:0] data_smem_req_addr_o, map_smem_req_addr_o;
    assign smem_req_addr_o = map_active_q ? map_smem_req_addr_o : data_smem_req_addr_o;
    logic [255:0] data_smem_req_data_o, map_smem_req_data_o;
    assign smem_req_data_o = map_active_q ? map_smem_req_data_o : data_smem_req_data_o;
    logic [31:0] data_smem_req_mask_o, map_smem_req_mask_o;
    assign smem_req_mask_o = map_active_q ? map_smem_req_mask_o : data_smem_req_mask_o;
    logic [SMEM_ID_W-1:0] data_smem_req_id_o, map_smem_req_id_o;
    assign smem_req_id_o = map_active_q ? map_smem_req_id_o : data_smem_req_id_o;
    logic data_smem_rsp_rdy_o, map_smem_rsp_rdy_o;
    assign smem_rsp_rdy_o = map_active_q ? map_smem_rsp_rdy_o : data_smem_rsp_rdy_o;
    tma_data_engine #(
        .ADDR_W(ADDR_W),
        .SMEM_ADDR_W(SMEM_ADDR_W),
        .CMD_QUEUE_DEPTH(CMD_QUEUE_DEPTH),
        .DESC_CACHE_ENTRIES(DESC_CACHE_ENTRIES),
        .MSHR_ENTRIES(MSHR_ENTRIES),
        .GMEM_ID_W(GMEM_ID_W),
        .SMEM_ID_W(SMEM_ID_W)
    ) u_data (
        .invalidate_i(map_active_q && map_rsp_vld && tma_rsp_rdy_i),
        .tma_cmd_i(tma_cmd_i),
        .gmem_req_attr_o(data_gmem_req_attr_o),
        .smem_req_attr_o(data_smem_req_attr_o),
        .tma_order_req_vld_o(data_tma_order_req_vld_o),
        .tma_order_req_rdy_i(tma_order_req_rdy_i && !map_active_q),
        .tma_order_req_o(data_tma_order_req_o),
        .tma_order_rsp_vld_i(tma_order_rsp_vld_i && !map_active_q),
        .tma_order_rsp_rdy_o(data_tma_order_rsp_rdy_o),
        .tma_order_rsp_i(tma_order_rsp_i),
        .clk(clk),
        .rst_n(rst_n),
        .tma_cmd_vld_i(tma_cmd_vld_i && !map_active_q && !map_command),
        .tma_cmd_rdy_o(data_cmd_rdy),
        .desc_done_o(desc_done_o),
        .source_done_o(source_done_o),
        .event_tag_o(event_tag_o),
        .tma_rsp_vld_o(data_rsp_vld),
        .tma_rsp_rdy_i(tma_rsp_rdy_i),
        .tma_rsp_tag_o(data_rsp_tag),
        .tma_rsp_status_o(data_rsp_status),
        .tma_rsp_bytes_o(data_rsp_bytes),
        .gmem_req_vld_o(data_gmem_req_vld_o),
        .gmem_req_rdy_i(gmem_req_rdy_i && !map_active_q),
        .gmem_req_write_o(data_gmem_req_write_o),
        .gmem_req_addr_o(data_gmem_req_addr_o),
        .gmem_req_data_o(data_gmem_req_data_o),
        .gmem_req_mask_o(data_gmem_req_mask_o),
        .gmem_req_id_o(data_gmem_req_id_o),
        .gmem_rsp_vld_i(gmem_rsp_vld_i && !map_active_q),
        .gmem_rsp_rdy_o(data_gmem_rsp_rdy_o),
        .gmem_rsp_data_i(gmem_rsp_data_i),
        .gmem_rsp_status_i(gmem_rsp_status_i),
        .gmem_rsp_id_i(gmem_rsp_id_i),
        .smem_req_vld_o(data_smem_req_vld_o),
        .smem_req_rdy_i(smem_req_rdy_i && !map_active_q),
        .smem_req_write_o(data_smem_req_write_o),
        .smem_req_addr_o(data_smem_req_addr_o),
        .smem_req_data_o(data_smem_req_data_o),
        .smem_req_mask_o(data_smem_req_mask_o),
        .smem_req_id_o(data_smem_req_id_o),
        .smem_rsp_vld_i(smem_rsp_vld_i && !map_active_q),
        .smem_rsp_rdy_o(data_smem_rsp_rdy_o),
        .smem_rsp_data_i(smem_rsp_data_i),
        .smem_rsp_status_i(smem_rsp_status_i),
        .smem_rsp_id_i(smem_rsp_id_i),
        .tx_cpl_vld_o(tx_cpl_vld_o),
        .tx_cpl_rdy_i(tx_cpl_rdy_i),
        .tx_cpl_tag_o(tx_cpl_tag_o),
        .tx_cpl_addr_o(tx_cpl_addr_o),
        .tx_cpl_bytes_o(tx_cpl_bytes_o),
        .tx_rsp_vld_i(tx_rsp_vld_i),
        .tx_rsp_rdy_o(tx_rsp_rdy_o),
        .tx_rsp_tag_i(tx_rsp_tag_i),
        .tx_rsp_status_i(tx_rsp_status_i),
        .tx_rsp_phase_i(tx_rsp_phase_i)
    );
    tma_map_control #(.GMEM_ID_W(GMEM_ID_W),.SMEM_ID_W(SMEM_ID_W)) u_map_control (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_i(tma_cmd_i),
        .cmd_vld_i(accept && map_command),
        .cmd_rdy_o(map_cmd_rdy),
        .rsp_vld_o(map_rsp_vld),
        .rsp_rdy_i(tma_rsp_rdy_i && map_active_q),
        .rsp_o(map_rsp),
        .gmem_req_attr_o(map_gmem_req_attr_o),
        .smem_req_attr_o(map_smem_req_attr_o),
        .tma_order_req_vld_o(map_tma_order_req_vld_o),
        .tma_order_req_rdy_i(tma_order_req_rdy_i && map_active_q),
        .tma_order_req_o(map_tma_order_req_o),
        .tma_order_rsp_vld_i(tma_order_rsp_vld_i && map_active_q),
        .tma_order_rsp_rdy_o(map_tma_order_rsp_rdy_o),
        .tma_order_rsp_i(tma_order_rsp_i),
        .gmem_req_vld_o(map_gmem_req_vld_o),
        .gmem_req_rdy_i(gmem_req_rdy_i && map_active_q),
        .gmem_req_write_o(map_gmem_req_write_o),
        .gmem_req_addr_o(map_gmem_req_addr_o),
        .gmem_req_data_o(map_gmem_req_data_o),
        .gmem_req_mask_o(map_gmem_req_mask_o),
        .gmem_req_id_o(map_gmem_req_id_o),
        .gmem_rsp_vld_i(gmem_rsp_vld_i && map_active_q),
        .gmem_rsp_rdy_o(map_gmem_rsp_rdy_o),
        .gmem_rsp_data_i(gmem_rsp_data_i),
        .gmem_rsp_status_i(gmem_rsp_status_i),
        .gmem_rsp_id_i(gmem_rsp_id_i),
        .smem_req_vld_o(map_smem_req_vld_o),
        .smem_req_rdy_i(smem_req_rdy_i && map_active_q),
        .smem_req_write_o(map_smem_req_write_o),
        .smem_req_addr_o(map_smem_req_addr_o),
        .smem_req_data_o(map_smem_req_data_o),
        .smem_req_mask_o(map_smem_req_mask_o),
        .smem_req_id_o(map_smem_req_id_o),
        .smem_rsp_vld_i(smem_rsp_vld_i && map_active_q),
        .smem_rsp_rdy_o(map_smem_rsp_rdy_o),
        .smem_rsp_data_i(smem_rsp_data_i),
        .smem_rsp_status_i(smem_rsp_status_i),
        .smem_rsp_id_i(smem_rsp_id_i)
    );
endmodule
`default_nettype wire
