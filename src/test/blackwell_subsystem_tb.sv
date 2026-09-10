`default_nettype none
module blackwell_subsystem_tb #(
    parameter int unsigned STAGING_DEPTH   = 2,
    parameter int unsigned TC_REG_SLICE    = 1,
    parameter int unsigned TMEM_PORT_MODE  = 0,
    parameter int unsigned SMEM_READ_PORTS = 2
);
    logic clk; logic rst_n;
    logic cmd_vld_i; wire cmd_rdy_o; logic [2:0] cmd_opcode_i;
    logic [15:0] cmd_tag_i; logic [31:0] cmd_a_base_i;
    logic [31:0] cmd_b_base_i; logic [31:0] cmd_dst_base_i;
    logic cmd_tile_slot_i; logic cmd_accumulate_i;
    logic [3:0] cmd_barrier_id_i; logic cmd_barrier_phase_i;
    logic [15:0] cmd_wait_token_i;
    wire completion_vld_o; logic completion_rdy_i;
    wire [15:0] completion_tag_o; wire [2:0] completion_opcode_o;
    wire [7:0] completion_status_o; wire [15:0] completion_token_o;
    wire smem_a_req_vld_o; logic smem_a_req_rdy_i;
    wire [31:0] smem_a_req_addr_o; wire [3:0] smem_a_req_source_o;
    logic smem_a_rsp_vld_i; wire smem_a_rsp_rdy_o;
    logic [255:0] smem_a_rsp_data_i; logic [3:0] smem_a_rsp_source_i;
    logic [1:0] smem_a_rsp_status_i;
    wire smem_b_req_vld_o; logic smem_b_req_rdy_i;
    wire [31:0] smem_b_req_addr_o; wire [3:0] smem_b_req_source_o;
    logic smem_b_rsp_vld_i; wire smem_b_rsp_rdy_o;
    logic [255:0] smem_b_rsp_data_i; logic [3:0] smem_b_rsp_source_i;
    logic [1:0] smem_b_rsp_status_i;
    wire smem_wr_req_vld_o; logic smem_wr_req_rdy_i;
    wire [31:0] smem_wr_req_addr_o; wire [255:0] smem_wr_req_data_o;
    wire [31:0] smem_wr_req_mask_o; wire [3:0] smem_wr_req_source_o;
    logic smem_wr_rsp_vld_i; wire smem_wr_rsp_rdy_o;
    logic [3:0] smem_wr_rsp_source_i; logic [1:0] smem_wr_rsp_status_i;
    wire tma_req_vld_o; logic tma_req_rdy_i; wire [15:0] tma_req_tag_o;
    wire [31:0] tma_req_src_addr_o; wire [31:0] tma_req_dst_addr_o;
    wire [15:0] tma_req_bytes_o; wire [3:0] tma_req_barrier_id_o;
    wire tma_req_phase_o; logic tma_done_vld_i; wire tma_done_rdy_o;
    logic [15:0] tma_done_tag_i; logic [3:0] tma_done_barrier_id_i;
    logic tma_done_phase_i; logic [1:0] tma_done_status_i;
    logic perf_clear_i; wire [31:0] perf_smem_stall_o;
    wire [31:0] perf_tc_busy_o; wire [31:0] perf_tmem_conflict_o;
    wire [31:0] perf_tmem_stall_o; wire [31:0] perf_writeback_stall_o;
    wire [31:0] perf_issued_o; wire [31:0] perf_completed_o;

    blackwell_tensor_subsystem #(
        .STAGING_DEPTH  (STAGING_DEPTH),
        .TC_REG_SLICE   (TC_REG_SLICE),
        .TMEM_PORT_MODE (TMEM_PORT_MODE),
        .SMEM_READ_PORTS(SMEM_READ_PORTS)
    ) u_dut (.*);
endmodule
`default_nettype wire
