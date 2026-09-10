// ============================================================================
// File Name   : blackwell_tma_mbarrier_top.sv
// Date        : 2026-08-27
// Description : Tensor-core baseline plus the complete TMA/mbarrier subsystem.
//
// The legacy tensor-core TMA proxy and the complete research interface share
// the TMA command path through a fair round-robin, one-command adapter.  A
// legacy request is translated to a 256-byte LOAD_LINEAR; its old completion
// fields are reconstructed after the real memory movement retires.
// ============================================================================

`default_nettype none

module blackwell_tma_mbarrier_top #(
    parameter int unsigned TMEM_BANKS          = 8,
    parameter int unsigned TMEM_BASE_DEPTH     = 128,
    parameter int unsigned STAGING_DEPTH       = 2,
    parameter int unsigned TC_REG_SLICE        = 1,
    parameter int unsigned TMEM_PORT_MODE      = 0,
    parameter int unsigned SMEM_READ_PORTS     = 2,
    parameter int unsigned CMD_QUEUE_DEPTH     = 8,
    parameter int unsigned DESC_CACHE_ENTRIES  = 4,
    parameter int unsigned MSHR_ENTRIES        = 16,
    parameter int unsigned BAR_CACHE_ENTRIES   = 4,
    parameter int unsigned WAIT_ENTRIES        = 32
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire          cmd_vld_i,
    output wire          cmd_rdy_o,
    input  wire [2:0]    cmd_opcode_i,
    input  wire [15:0]   cmd_tag_i,
    input  wire [31:0]   cmd_a_base_i,
    input  wire [31:0]   cmd_b_base_i,
    input  wire [31:0]   cmd_dst_base_i,
    input  wire          cmd_tile_slot_i,
    input  wire          cmd_accumulate_i,
    input  wire [3:0]    cmd_barrier_id_i,
    input  wire          cmd_barrier_phase_i,
    input  wire [15:0]   cmd_wait_token_i,
    output wire          completion_vld_o,
    input  wire          completion_rdy_i,
    output wire [15:0]   completion_tag_o,
    output wire [2:0]    completion_opcode_o,
    output wire [7:0]    completion_status_o,
    output wire [15:0]   completion_token_o,

    output wire          smem_a_req_vld_o,
    input  wire          smem_a_req_rdy_i,
    output wire [31:0]   smem_a_req_addr_o,
    output wire [3:0]    smem_a_req_source_o,
    input  wire          smem_a_rsp_vld_i,
    output wire          smem_a_rsp_rdy_o,
    input  wire [255:0]  smem_a_rsp_data_i,
    input  wire [3:0]    smem_a_rsp_source_i,
    input  wire [1:0]    smem_a_rsp_status_i,
    output wire          smem_b_req_vld_o,
    input  wire          smem_b_req_rdy_i,
    output wire [31:0]   smem_b_req_addr_o,
    output wire [3:0]    smem_b_req_source_o,
    input  wire          smem_b_rsp_vld_i,
    output wire          smem_b_rsp_rdy_o,
    input  wire [255:0]  smem_b_rsp_data_i,
    input  wire [3:0]    smem_b_rsp_source_i,
    input  wire [1:0]    smem_b_rsp_status_i,
    output wire          smem_wr_req_vld_o,
    input  wire          smem_wr_req_rdy_i,
    output wire [31:0]   smem_wr_req_addr_o,
    output wire [255:0]  smem_wr_req_data_o,
    output wire [31:0]   smem_wr_req_mask_o,
    output wire [3:0]    smem_wr_req_source_o,
    input  wire          smem_wr_rsp_vld_i,
    output wire          smem_wr_rsp_rdy_o,
    input  wire [3:0]    smem_wr_rsp_source_i,
    input  wire [1:0]    smem_wr_rsp_status_i,

    input  wire          tma_cmd_vld_i,
    output wire          tma_cmd_rdy_o,
    input  wire [2:0]    tma_cmd_opcode_i,
    input  wire [15:0]   tma_cmd_tag_i,
    input  wire [63:0]   tma_cmd_desc_ptr_i,
    input  wire [159:0]  tma_cmd_coord_i,
    input  wire [31:0]   tma_cmd_smem_addr_i,
    input  wire [63:0]   tma_cmd_linear_addr_i,
    input  wire [31:0]   tma_cmd_linear_bytes_i,
    input  wire [63:0]   tma_cmd_barrier_addr_i,
    output wire          tma_rsp_vld_o,
    input  wire          tma_rsp_rdy_i,
    output wire [15:0]   tma_rsp_tag_o,
    output wire [7:0]    tma_rsp_status_o,
    output wire [63:0]   tma_rsp_bytes_o,

    input  wire          bar_cmd_vld_i,
    output wire          bar_cmd_rdy_o,
    input  wire [2:0]    bar_cmd_opcode_i,
    input  wire [15:0]   bar_cmd_tag_i,
    input  wire [63:0]   bar_cmd_addr_i,
    input  wire [15:0]   bar_cmd_arrive_count_i,
    input  wire [63:0]   bar_cmd_tx_bytes_i,
    input  wire          bar_cmd_phase_token_i,
    output wire          bar_rsp_vld_o,
    input  wire          bar_rsp_rdy_i,
    output wire [15:0]   bar_rsp_tag_o,
    output wire [7:0]    bar_rsp_status_o,
    output wire          bar_rsp_phase_o,
    output wire          bar_rsp_locked_o,

    output wire          gmem_req_vld_o,
    input  wire          gmem_req_rdy_i,
    output wire          gmem_req_write_o,
    output wire [63:0]   gmem_req_addr_o,
    output wire [1023:0] gmem_req_data_o,
    output wire [127:0]  gmem_req_mask_o,
    output wire [4:0]    gmem_req_id_o,
    input  wire          gmem_rsp_vld_i,
    output wire          gmem_rsp_rdy_o,
    input  wire [1023:0] gmem_rsp_data_i,
    input  wire [1:0]    gmem_rsp_status_i,
    input  wire [4:0]    gmem_rsp_id_i,
    output wire          tma_smem_req_vld_o,
    input  wire          tma_smem_req_rdy_i,
    output wire          tma_smem_req_write_o,
    output wire [31:0]   tma_smem_req_addr_o,
    output wire [255:0]  tma_smem_req_data_o,
    output wire [31:0]   tma_smem_req_mask_o,
    output wire [5:0]    tma_smem_req_id_o,
    input  wire          tma_smem_rsp_vld_i,
    output wire          tma_smem_rsp_rdy_o,
    input  wire [255:0]  tma_smem_rsp_data_i,
    input  wire [1:0]    tma_smem_rsp_status_i,
    input  wire [5:0]    tma_smem_rsp_id_i,

    input  wire          perf_clear_i,
    output wire [31:0]   perf_smem_stall_o,
    output wire [31:0]   perf_tc_busy_o,
    output wire [31:0]   perf_tmem_conflict_o,
    output wire [31:0]   perf_tmem_stall_o,
    output wire [31:0]   perf_writeback_stall_o,
    output wire [31:0]   perf_issued_o,
    output wire [31:0]   perf_completed_o
);
    import tma_mbarrier_pkg::*;

    wire          tma_req_vld_o;
    wire          tma_req_rdy_i;
    wire [15:0]   tma_req_tag_o;
    wire [31:0]   tma_req_src_addr_o;
    wire [31:0]   tma_req_dst_addr_o;
    wire [15:0]   tma_req_bytes_o;
    wire [3:0]    tma_req_barrier_id_o;
    wire          tma_req_phase_o;
    wire          tma_done_vld_i;
    wire          tma_done_rdy_o;
    wire [15:0]   tma_done_tag_i;
    wire [3:0]    tma_done_barrier_id_i;
    wire          tma_done_phase_i;
    wire [1:0]    tma_done_status_i;

    logic         adapter_busy_q;
    logic         adapter_legacy_q;
    logic         adapter_legacy_turn_q;
    logic [3:0]   legacy_barrier_q;
    logic         legacy_phase_q;
    logic         choose_legacy;
    wire          sub_cmd_vld;
    wire          sub_cmd_rdy;
    wire          sub_rsp_vld;
    wire          sub_rsp_rdy;
    wire [15:0]   sub_rsp_tag;
    wire [7:0]    sub_rsp_status;
    wire [63:0]   sub_rsp_bytes;
    wire          sub_cmd_fire;
    wire          sub_rsp_fire;

    always_comb begin
        choose_legacy = 1'b0;
        if (tma_req_vld_o &&
            (!tma_cmd_vld_i || adapter_legacy_turn_q)) begin
            choose_legacy = 1'b1;
        end
    end

    assign sub_cmd_vld = !adapter_busy_q &&
                         (tma_req_vld_o || tma_cmd_vld_i);
    assign tma_req_rdy_i = !adapter_busy_q && choose_legacy && sub_cmd_rdy;
    assign tma_cmd_rdy_o = !adapter_busy_q && !choose_legacy && sub_cmd_rdy;
    assign sub_cmd_fire = sub_cmd_vld && sub_cmd_rdy;
    assign sub_rsp_rdy = adapter_legacy_q ? tma_done_rdy_o : tma_rsp_rdy_i;
    assign sub_rsp_fire = sub_rsp_vld && sub_rsp_rdy;

    assign tma_done_vld_i = sub_rsp_vld && adapter_busy_q && adapter_legacy_q;
    assign tma_done_tag_i = sub_rsp_tag;
    assign tma_done_barrier_id_i = legacy_barrier_q;
    assign tma_done_phase_i = legacy_phase_q;
    assign tma_done_status_i = (sub_rsp_status == TMA_STATUS_OK) ? 2'd0 : 2'd1;
    assign tma_rsp_vld_o = sub_rsp_vld && adapter_busy_q && !adapter_legacy_q;
    assign tma_rsp_tag_o = sub_rsp_tag;
    assign tma_rsp_status_o = sub_rsp_status;
    assign tma_rsp_bytes_o = sub_rsp_bytes;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adapter_busy_q <= 1'b0;
            adapter_legacy_q <= 1'b0;
            adapter_legacy_turn_q <= 1'b0;
            legacy_barrier_q <= 4'd0;
            legacy_phase_q <= 1'b0;
        end else begin
            if (sub_cmd_fire) begin
                adapter_busy_q <= 1'b1;
                adapter_legacy_q <= choose_legacy;
                if (choose_legacy) begin
                    legacy_barrier_q <= tma_req_barrier_id_o;
                    legacy_phase_q <= tma_req_phase_o;
                end
                if (tma_req_vld_o && tma_cmd_vld_i) begin
                    adapter_legacy_turn_q <= ~adapter_legacy_turn_q;
                end
            end
            if (sub_rsp_fire) begin
                adapter_busy_q <= 1'b0;
            end
        end
    end

    blackwell_tensor_subsystem #(
        .TMEM_BANKS      (TMEM_BANKS),
        .TMEM_BASE_DEPTH (TMEM_BASE_DEPTH),
        .STAGING_DEPTH   (STAGING_DEPTH),
        .TC_REG_SLICE    (TC_REG_SLICE),
        .TMEM_PORT_MODE  (TMEM_PORT_MODE),
        .SMEM_READ_PORTS (SMEM_READ_PORTS)
    ) u_tensor_subsystem (.*);

    tma_mbarrier_subsystem #(
        .CMD_QUEUE_DEPTH    (CMD_QUEUE_DEPTH),
        .DESC_CACHE_ENTRIES (DESC_CACHE_ENTRIES),
        .MSHR_ENTRIES       (MSHR_ENTRIES),
        .BAR_CACHE_ENTRIES  (BAR_CACHE_ENTRIES),
        .WAIT_ENTRIES       (WAIT_ENTRIES)
    ) u_tma_mbarrier (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .tma_cmd_vld_i          (sub_cmd_vld),
        .tma_cmd_rdy_o          (sub_cmd_rdy),
        .tma_cmd_opcode_i       (choose_legacy ? TMA_OP_LOAD_LINEAR :
                                                tma_cmd_opcode_i),
        .tma_cmd_tag_i          (choose_legacy ? tma_req_tag_o :
                                                tma_cmd_tag_i),
        .tma_cmd_desc_ptr_i     (choose_legacy ? 64'd0 :
                                                tma_cmd_desc_ptr_i),
        .tma_cmd_coord_i        (choose_legacy ? 160'd0 : tma_cmd_coord_i),
        .tma_cmd_smem_addr_i    (choose_legacy ? tma_req_dst_addr_o :
                                                tma_cmd_smem_addr_i),
        .tma_cmd_linear_addr_i  (choose_legacy ? {32'd0, tma_req_src_addr_o} :
                                                tma_cmd_linear_addr_i),
        .tma_cmd_linear_bytes_i (choose_legacy ? {16'd0, tma_req_bytes_o} :
                                                tma_cmd_linear_bytes_i),
        .tma_cmd_barrier_addr_i (choose_legacy ? 64'd0 :
                                                tma_cmd_barrier_addr_i),
        .tma_rsp_vld_o          (sub_rsp_vld),
        .tma_rsp_rdy_i          (sub_rsp_rdy),
        .tma_rsp_tag_o          (sub_rsp_tag),
        .tma_rsp_status_o       (sub_rsp_status),
        .tma_rsp_bytes_o        (sub_rsp_bytes),
        .bar_cmd_vld_i          (bar_cmd_vld_i),
        .bar_cmd_rdy_o          (bar_cmd_rdy_o),
        .bar_cmd_opcode_i       (bar_cmd_opcode_i),
        .bar_cmd_tag_i          (bar_cmd_tag_i),
        .bar_cmd_addr_i         (bar_cmd_addr_i),
        .bar_cmd_arrive_count_i (bar_cmd_arrive_count_i),
        .bar_cmd_tx_bytes_i     (bar_cmd_tx_bytes_i),
        .bar_cmd_phase_token_i  (bar_cmd_phase_token_i),
        .bar_rsp_vld_o          (bar_rsp_vld_o),
        .bar_rsp_rdy_i          (bar_rsp_rdy_i),
        .bar_rsp_tag_o          (bar_rsp_tag_o),
        .bar_rsp_status_o       (bar_rsp_status_o),
        .bar_rsp_phase_o        (bar_rsp_phase_o),
        .bar_rsp_locked_o       (bar_rsp_locked_o),
        .gmem_req_vld_o         (gmem_req_vld_o),
        .gmem_req_rdy_i         (gmem_req_rdy_i),
        .gmem_req_write_o       (gmem_req_write_o),
        .gmem_req_addr_o        (gmem_req_addr_o),
        .gmem_req_data_o        (gmem_req_data_o),
        .gmem_req_mask_o        (gmem_req_mask_o),
        .gmem_req_id_o          (gmem_req_id_o),
        .gmem_rsp_vld_i         (gmem_rsp_vld_i),
        .gmem_rsp_rdy_o         (gmem_rsp_rdy_o),
        .gmem_rsp_data_i        (gmem_rsp_data_i),
        .gmem_rsp_status_i      (gmem_rsp_status_i),
        .gmem_rsp_id_i          (gmem_rsp_id_i),
        .smem_req_vld_o         (tma_smem_req_vld_o),
        .smem_req_rdy_i         (tma_smem_req_rdy_i),
        .smem_req_write_o       (tma_smem_req_write_o),
        .smem_req_addr_o        (tma_smem_req_addr_o),
        .smem_req_data_o        (tma_smem_req_data_o),
        .smem_req_mask_o        (tma_smem_req_mask_o),
        .smem_req_id_o          (tma_smem_req_id_o),
        .smem_rsp_vld_i         (tma_smem_rsp_vld_i),
        .smem_rsp_rdy_o         (tma_smem_rsp_rdy_o),
        .smem_rsp_data_i        (tma_smem_rsp_data_i),
        .smem_rsp_status_i      (tma_smem_rsp_status_i),
        .smem_rsp_id_i          (tma_smem_rsp_id_i)
    );

endmodule

`default_nettype wire
