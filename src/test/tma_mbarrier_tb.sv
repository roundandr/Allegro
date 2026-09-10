`default_nettype none

module tma_mbarrier_tb;
    logic clk;
    logic rst_n;

    logic          tma_cmd_vld_i;
    wire           tma_cmd_rdy_o;
    logic [2:0]    tma_cmd_opcode_i;
    logic [15:0]   tma_cmd_tag_i;
    logic [63:0]   tma_cmd_desc_ptr_i;
    logic [159:0]  tma_cmd_coord_i;
    logic [31:0]   tma_cmd_smem_addr_i;
    logic [63:0]   tma_cmd_linear_addr_i;
    logic [31:0]   tma_cmd_linear_bytes_i;
    logic [63:0]   tma_cmd_barrier_addr_i;
    wire           tma_rsp_vld_o;
    logic          tma_rsp_rdy_i;
    wire [15:0]    tma_rsp_tag_o;
    wire [7:0]     tma_rsp_status_o;
    wire [63:0]    tma_rsp_bytes_o;

    logic          bar_cmd_vld_i;
    wire           bar_cmd_rdy_o;
    logic [2:0]    bar_cmd_opcode_i;
    logic [15:0]   bar_cmd_tag_i;
    logic [63:0]   bar_cmd_addr_i;
    logic [15:0]   bar_cmd_arrive_count_i;
    logic [63:0]   bar_cmd_tx_bytes_i;
    logic          bar_cmd_phase_token_i;
    wire           bar_rsp_vld_o;
    logic          bar_rsp_rdy_i;
    wire [15:0]    bar_rsp_tag_o;
    wire [7:0]     bar_rsp_status_o;
    wire           bar_rsp_phase_o;
    wire           bar_rsp_locked_o;

    wire           gmem_req_vld_o;
    logic          gmem_req_rdy_i;
    wire           gmem_req_write_o;
    wire [63:0]    gmem_req_addr_o;
    wire [1023:0]  gmem_req_data_o;
    wire [127:0]   gmem_req_mask_o;
    wire [4:0]     gmem_req_id_o;
    logic          gmem_rsp_vld_i;
    wire           gmem_rsp_rdy_o;
    logic [1023:0] gmem_rsp_data_i;
    logic [1:0]    gmem_rsp_status_i;
    logic [4:0]    gmem_rsp_id_i;

    wire           smem_req_vld_o;
    logic          smem_req_rdy_i;
    wire           smem_req_write_o;
    wire [31:0]    smem_req_addr_o;
    wire [255:0]   smem_req_data_o;
    wire [31:0]    smem_req_mask_o;
    wire [5:0]     smem_req_id_o;
    logic          smem_rsp_vld_i;
    wire           smem_rsp_rdy_o;
    logic [255:0]  smem_rsp_data_i;
    logic [1:0]    smem_rsp_status_i;
    logic [5:0]    smem_rsp_id_i;

    tma_mbarrier_subsystem u_dut (.*);
endmodule

`default_nettype wire
