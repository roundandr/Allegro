// Real TMEM bank + shared TC completion controller integration fixture.
// The bar_* interface is the same producer endpoint used by mbarrier's
// independent tc_arrive channel; the test drives its acknowledgment.
`default_nettype none
module blackwell_tmem_shift_commit_tb #(
    parameter int REAL_BACKING = 0
) (
    input wire clk, rst_n,
    input wire ctx_vld_i, output wire ctx_rdy_o,
    input wire ctx_create_i, input wire [4:0] ctx_id_i,
    input wire [15:0] ctx_epoch_i, input wire [15:0] ctx_tag_i,
    input wire alloc_vld_i, output wire alloc_rdy_o,
    input wire [4:0] alloc_ctx_i, input wire [15:0] alloc_epoch_i,
    input wire [9:0] alloc_columns_i, input wire [15:0] alloc_tag_i,
    output wire ctrl_rsp_vld_o, input wire ctrl_rsp_rdy_i,
    output wire [15:0] ctrl_rsp_tag_o,
    output wire [7:0] ctrl_rsp_status_o,
    output wire [8:0] ctrl_rsp_base_o,
    input wire shift_cmd_vld_i, output wire shift_cmd_rdy_o,
    input wire [4:0] shift_cmd_ctx_i,
    input wire [15:0] shift_cmd_epoch_i,
    input wire [31:0] shift_cmd_base_addr_i,
    input wire [15:0] shift_cmd_tag_i,
    input wire [9:0] shift_cmd_issuer_i,
    input wire [4:0] shift_cmd_warp_i,
    input wire [63:0] shift_cmd_seq_i,
    output wire shift_complete_vld_o,
    output wire shift_done_vld_o, input wire shift_done_rdy_i,
    output wire [15:0] shift_done_tag_o,
    output wire [7:0] shift_done_status_o,
    input wire commit_vld_i, output wire commit_rdy_o,
    input wire [9:0] commit_issuer_i, input wire [4:0] commit_warp_i,
    input wire [15:0] commit_tag_i, input wire [63:0] commit_seq_i,
    input wire [15:0] commit_epoch_i, input wire [63:0] commit_barrier_i,
    output wire bar_vld_o, input wire bar_rdy_i,
    output wire [4:0] bar_opcode_o,
    output wire [15:0] bar_tag_o,
    output wire [9:0] bar_issuer_o,
    output wire [63:0] bar_addr_o,
    output wire [31:0] bar_arrive_count_o,
    input wire bar_rsp_vld_i, output wire bar_rsp_rdy_o,
    input wire [15:0] bar_rsp_tag_i,
    input wire [9:0] bar_rsp_issuer_i,
    input wire [7:0] bar_rsp_status_i,
    input wire bar_rsp_phase_i,
    output wire event_vld_o, input wire event_rdy_i,
    output wire [15:0] event_tag_o,
    output wire [9:0] event_issuer_o,
    output wire [7:0] event_status_o,
    output wire event_phase_o,
    output wire protocol_error_o,
    input wire sw_bar_vld_i, output wire sw_bar_rdy_o,
    input wire [4:0] sw_bar_opcode_i,
    input wire [15:0] sw_bar_tag_i,
    input wire [63:0] sw_bar_addr_i,
    input wire [31:0] sw_bar_arrive_count_i,
    input wire sw_bar_phase_token_i,
    output wire sw_bar_rsp_vld_o, input wire sw_bar_rsp_rdy_i,
    output wire [15:0] sw_bar_rsp_tag_o,
    output wire [7:0] sw_bar_rsp_status_o,
    output wire sw_bar_rsp_phase_o,
    output wire sw_bar_rsp_wait_complete_o,
    input wire backing_ack_enable_i,
    output wire backing_write_vld_o,
    output wire backing_read_vld_o,
    output wire backing_rsp_pending_o,
    output wire backing_protocol_error_o
);
    import blackwell_async_pkg::*;
    import tma_mbarrier_pkg::*;
    wire shift_register_vld, shift_register_rdy;
    async_id_t shift_register;
    wire shift_complete_rdy;
    async_event_t shift_complete;
    tc_commit_t commit;
    bar_cmd_t bar;
    bar_rsp_t bar_rsp;
    bar_rsp_t selected_bar_rsp;
    wire selected_bar_rdy, selected_bar_rsp_vld;
    async_event_t tc_event;
    always_comb begin
        commit = '0;
        commit.id.issuer = commit_issuer_i;
        commit.id.warp = commit_warp_i;
        commit.id.tag = commit_tag_i;
        commit.id.seq = commit_seq_i;
        commit.id.epoch = commit_epoch_i;
        commit.barrier = commit_barrier_i;
        bar_rsp = '0;
        bar_rsp.tag = bar_rsp_tag_i;
        bar_rsp.issuer = bar_rsp_issuer_i;
        bar_rsp.status = bar_rsp_status_i;
        bar_rsp.phase = bar_rsp_phase_i;
    end
    assign bar_opcode_o = bar.opcode;
    assign bar_tag_o = bar.tag;
    assign bar_issuer_o = bar.issuer;
    assign bar_addr_o = bar.addr;
    assign bar_arrive_count_o = bar.arrive_count;
    assign event_tag_o = tc_event.id.tag;
    assign event_issuer_o = tc_event.id.issuer;
    assign event_status_o = tc_event.status;
    assign event_phase_o = tc_event.value[0];

    blackwell_tmem_rf_subsystem u_tmem (
        .clk,.rst_n,
        .ctx_vld_i,.ctx_rdy_o,.ctx_create_i,.ctx_id_i,.ctx_epoch_i,.ctx_tag_i,
        .alloc_vld_i,.alloc_rdy_o,.alloc_ctx_i,.alloc_epoch_i,
        .alloc_columns_i,.alloc_tag_i,
        .free_vld_i(1'b0),.free_rdy_o(),.free_ctx_i(5'd0),
        .free_epoch_i(16'd0),.free_base_i(9'd0),
        .free_columns_i(10'd0),.free_tag_i(16'd0),
        .relinquish_vld_i(1'b0),.relinquish_rdy_o(),
        .relinquish_ctx_i(5'd0),.relinquish_epoch_i(16'd0),
        .relinquish_tag_i(16'd0),
        .ctrl_rsp_vld_o,.ctrl_rsp_rdy_i,.ctrl_rsp_tag_o,
        .ctrl_rsp_status_o,.ctrl_rsp_base_o,
        .cmd_vld_i(1'b0),.cmd_rdy_o(),.cmd_store_i(1'b0),
        .cmd_ctx_i(5'd0),.cmd_epoch_i(16'd0),.cmd_warp_i(5'd0),
        .cmd_shape_i(3'd0),.cmd_repeat_i(8'd0),.cmd_pack16_i(1'b0),
        .cmd_base_addr_i(32'd0),.cmd_half_offset_i(32'd0),
        .cmd_tag_i(16'd0),
        .rf_src_vld_i(1'b0),.rf_src_rdy_o(),.rf_src_data_i(1024'd0),
        .rf_src_last_i(1'b0),
        .rf_dst_vld_o(),.rf_dst_rdy_i(1'b1),.rf_dst_data_o(),
        .rf_dst_index_o(),.rf_dst_last_o(),
        .done_vld_o(),.done_rdy_i(1'b1),.done_tag_o(),
        .done_store_o(),.done_status_o(),
        .shift_cmd_vld_i,.shift_cmd_rdy_o,.shift_cmd_ctx_i,
        .shift_cmd_epoch_i,.shift_cmd_base_addr_i,.shift_cmd_tag_i,
        .shift_cmd_issuer_i,.shift_cmd_warp_i,.shift_cmd_seq_i,
        .shift_register_vld_o(shift_register_vld),
        .shift_register_rdy_i(shift_register_rdy),
        .shift_register_o(shift_register),
        .shift_complete_vld_o,
        .shift_complete_rdy_i(shift_complete_rdy),
        .shift_complete_o(shift_complete),
        .shift_done_vld_o,.shift_done_rdy_i,.shift_done_tag_o,
        .shift_done_status_o,
        .wait_vld_i(1'b0),.wait_rdy_o(),.wait_ctx_i(5'd0),
        .wait_epoch_i(16'd0),.wait_warp_i(5'd0),
        .wait_store_i(1'b0),.wait_tag_i(16'd0),
        .wait_rsp_vld_o(),.wait_rsp_rdy_i(1'b1),
        .wait_rsp_ctx_o(),.wait_rsp_epoch_o(),.wait_rsp_warp_o(),
        .wait_rsp_store_o(),.wait_rsp_tag_o(),.wait_rsp_status_o(),
        .wait_protocol_error_o()
    );
    tcgen05_async_completion u_tc_completion (
        .clk,.rst_n,
        .register_vld_i(shift_register_vld),
        .register_rdy_o(shift_register_rdy),.register_i(shift_register),
        .complete_vld_i(shift_complete_vld_o),
        .complete_rdy_o(shift_complete_rdy),.complete_i(shift_complete),
        .commit_vld_i,.commit_rdy_o,.commit_i(commit),
        .bar_vld_o,.bar_rdy_i(selected_bar_rdy),.bar_o(bar),
        .bar_rsp_vld_i(selected_bar_rsp_vld),.bar_rsp_rdy_o,.bar_rsp_i(selected_bar_rsp),
        .event_vld_o,.event_rdy_i,.event_o(tc_event),
        .protocol_error_o
    );
    if (REAL_BACKING != 0) begin : gen_real_backing
        bar_cmd_t sw_cmd;
        bar_rsp_t sw_rsp, tc_rsp;
        wire mem_req_vld, mem_req_rdy, mem_req_write;
        wire [63:0] mem_req_addr;
        wire [255:0] mem_req_data, mem_rsp_data;
        wire [31:0] mem_req_mask;
        wire [1:0] mem_req_id, mem_rsp_id, mem_rsp_status;
        wire mem_rsp_vld, mem_rsp_rdy;
        bw_mem_attr_t mem_attr;
        wire [1:0] smem_protocol_error;
        always_comb begin
            sw_cmd = '0;
            sw_cmd.opcode = sw_bar_opcode_i;
            sw_cmd.tag = sw_bar_tag_i;
            sw_cmd.addr = sw_bar_addr_i;
            sw_cmd.arrive_count = sw_bar_arrive_count_i;
            sw_cmd.phase_token = sw_bar_phase_token_i;
            sw_cmd.wait_parity = 1'b1;
            mem_attr = '0;
            mem_attr.kind = mem_req_write ? BW_MEM_WRITE : BW_MEM_READ;
            mem_attr.dtype = TMA_TYPE_U64;
            mem_attr.proxy = BW_PROXY_GENERIC;
        end
        assign selected_bar_rdy = tc_arrive_rdy;
        assign selected_bar_rsp_vld = tc_arrive_rsp_vld;
        assign selected_bar_rsp = tc_rsp;
        assign sw_bar_rsp_tag_o = sw_rsp.tag;
        assign sw_bar_rsp_status_o = sw_rsp.status;
        assign sw_bar_rsp_phase_o = sw_rsp.phase;
        assign sw_bar_rsp_wait_complete_o = sw_rsp.wait_complete;
        assign backing_write_vld_o = mem_req_vld && mem_req_write;
        assign backing_read_vld_o = mem_req_vld && !mem_req_write;
        assign backing_rsp_pending_o = mem_rsp_vld;
        assign backing_protocol_error_o = |smem_protocol_error;
        wire tc_arrive_rdy, tc_arrive_rsp_vld;
        mbarrier_frontend u_mbarrier (
            .clk,.rst_n,
            .bar_cmd_vld_i(sw_bar_vld_i),.bar_cmd_rdy_o(sw_bar_rdy_o),.bar_cmd_i(sw_cmd),
            .bar_rsp_vld_o(sw_bar_rsp_vld_o),.bar_rsp_rdy_i(sw_bar_rsp_rdy_i),.bar_rsp_o(sw_rsp),
            .tc_arrive_vld_i(bar_vld_o),.tc_arrive_rdy_o(tc_arrive_rdy),.tc_arrive_i(bar),
            .tc_arrive_rsp_vld_o(tc_arrive_rsp_vld),.tc_arrive_rsp_rdy_i(bar_rsp_rdy_o),.tc_arrive_rsp_o(tc_rsp),
            .async_req_vld_i(1'b0),.async_req_rdy_o(),.async_req_i('0),
            .async_cpl_req_vld_i(1'b0),.async_cpl_req_rdy_o(),.async_cpl_req_i('0),
            .async_rsp_vld_o(),.async_rsp_rdy_i(1'b1),.async_rsp_o(),
            .report_req_vld_i(1'b0),.report_req_rdy_o(),.report_req_i('0),
            .report_rsp_vld_o(),.report_rsp_rdy_i(1'b1),.report_rsp_o(),
            .order_req_vld_o(),.order_req_rdy_i(1'b0),.order_req_o(),
            .order_rsp_vld_i(1'b0),.order_rsp_rdy_o(),.order_rsp_i('0),
            .tx_cpl_vld_i(1'b0),.tx_cpl_rdy_o(),.tx_cpl_tag_i('0),
            .tx_cpl_addr_i('0),.tx_cpl_bytes_i('0),
            .tx_rsp_vld_o(),.tx_rsp_rdy_i(1'b1),.tx_rsp_tag_o(),.tx_rsp_status_o(),.tx_rsp_phase_o(),
            .mem_req_vld_o(mem_req_vld),.mem_req_rdy_i(mem_req_rdy),
            .mem_req_write_o(mem_req_write),.mem_req_addr_o(mem_req_addr),
            .mem_req_data_o(mem_req_data),.mem_req_mask_o(mem_req_mask),.mem_req_id_o(mem_req_id),
            .mem_rsp_vld_i(mem_rsp_vld && backing_ack_enable_i),
            .mem_rsp_rdy_o(mem_rsp_rdy),.mem_rsp_data_i(mem_rsp_data),
            .mem_rsp_status_i(mem_rsp_status),.mem_rsp_id_i(mem_rsp_id)
        );
        blackwell_tma_smem_bridge #(.AUX_CLIENTS(1),.MEM_ID_W(2)) u_smem (
            .clk,.rst_n,
            .mem_req_vld_i(mem_req_vld),.mem_req_rdy_o(mem_req_rdy),
            .mem_req_addr_i(mem_req_addr[31:0]),.mem_req_data_i(mem_req_data),
            // A barrier read has no write mask in its ABI. Match the product
            // tma_mbarrier_subsystem adapter by requesting all 32 bytes.
            .mem_req_mask_i(mem_req_write ? mem_req_mask : 32'hffff_ffff),
            .mem_req_id_i(mem_req_id),.mem_req_attr_i(mem_attr),
            .mem_rsp_vld_o(mem_rsp_vld),.mem_rsp_rdy_i(mem_rsp_rdy && backing_ack_enable_i),
            .mem_rsp_data_o(mem_rsp_data),.mem_rsp_id_o(mem_rsp_id),.mem_rsp_status_o(mem_rsp_status),
            .req_vld_i(1'b0),.req_rdy_o(),.req_addr_i('0),.req_data_i('0),
            .req_mask_i('0),.req_kind_i('0),.req_dtype_i('0),.req_op_i('0),.req_tag_i('0),
            .rsp_vld_o(),.rsp_rdy_i(1'b1),.rsp_data_o(),.rsp_tag_o(),.rsp_error_o(),
            .protocol_error_o(smem_protocol_error)
        );
    end else begin : gen_manual_backing
        assign selected_bar_rdy = bar_rdy_i;
        assign selected_bar_rsp_vld = bar_rsp_vld_i;
        assign selected_bar_rsp = bar_rsp;
        assign sw_bar_rdy_o = 1'b0;
        assign sw_bar_rsp_vld_o = 1'b0;
        assign sw_bar_rsp_tag_o = '0;
        assign sw_bar_rsp_status_o = '0;
        assign sw_bar_rsp_phase_o = 1'b0;
        assign sw_bar_rsp_wait_complete_o = 1'b0;
        assign backing_write_vld_o = 1'b0;
        assign backing_read_vld_o = 1'b0;
        assign backing_rsp_pending_o = 1'b0;
        assign backing_protocol_error_o = 1'b0;
    end
endmodule
`default_nettype wire
