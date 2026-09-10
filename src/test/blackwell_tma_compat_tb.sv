`default_nettype none

module blackwell_tma_compat_tb;
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

    logic tma_cmd_vld_i; wire tma_cmd_rdy_o; logic [2:0] tma_cmd_opcode_i;
    logic [15:0] tma_cmd_tag_i; logic [63:0] tma_cmd_desc_ptr_i;
    logic [159:0] tma_cmd_coord_i; logic [31:0] tma_cmd_smem_addr_i;
    logic [63:0] tma_cmd_linear_addr_i; logic [31:0] tma_cmd_linear_bytes_i;
    logic [63:0] tma_cmd_barrier_addr_i;
    wire tma_rsp_vld_o; logic tma_rsp_rdy_i; wire [15:0] tma_rsp_tag_o;
    wire [7:0] tma_rsp_status_o; wire [63:0] tma_rsp_bytes_o;
    logic bar_cmd_vld_i; wire bar_cmd_rdy_o; logic [2:0] bar_cmd_opcode_i;
    logic [15:0] bar_cmd_tag_i; logic [63:0] bar_cmd_addr_i;
    logic [15:0] bar_cmd_arrive_count_i; logic [63:0] bar_cmd_tx_bytes_i;
    logic bar_cmd_phase_token_i; wire bar_rsp_vld_o; logic bar_rsp_rdy_i;
    wire [15:0] bar_rsp_tag_o; wire [7:0] bar_rsp_status_o;
    wire bar_rsp_phase_o; wire bar_rsp_locked_o;

    wire gmem_req_vld_o; logic gmem_req_rdy_i; wire gmem_req_write_o;
    wire [63:0] gmem_req_addr_o; wire [1023:0] gmem_req_data_o;
    wire [127:0] gmem_req_mask_o; wire [4:0] gmem_req_id_o;
    logic gmem_rsp_vld_i; wire gmem_rsp_rdy_o; logic [1023:0] gmem_rsp_data_i;
    logic [1:0] gmem_rsp_status_i; logic [4:0] gmem_rsp_id_i;
    wire tma_smem_req_vld_o; logic tma_smem_req_rdy_i;
    wire tma_smem_req_write_o; wire [31:0] tma_smem_req_addr_o;
    wire [255:0] tma_smem_req_data_o; wire [31:0] tma_smem_req_mask_o;
    wire [5:0] tma_smem_req_id_o; logic tma_smem_rsp_vld_i;
    wire tma_smem_rsp_rdy_o; logic [255:0] tma_smem_rsp_data_i;
    logic [1:0] tma_smem_rsp_status_i; logic [5:0] tma_smem_rsp_id_i;

    logic perf_clear_i; wire [31:0] perf_smem_stall_o;
    wire [31:0] perf_tc_busy_o; wire [31:0] perf_tmem_conflict_o;
    wire [31:0] perf_tmem_stall_o; wire [31:0] perf_writeback_stall_o;
    wire [31:0] perf_issued_o; wire [31:0] perf_completed_o;

    blackwell_tma_mbarrier_top u_dut (.*);
endmodule

`default_nettype wire
