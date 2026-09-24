`default_nettype none

module tma_mbarrier_tb #(
    parameter int REAL_SMEM = 0,
    parameter int BAR_ASYNC_ENTRIES = 16,
    parameter int CMD_QUEUE_DEPTH = 8,
    parameter int DESC_CACHE_ENTRIES = 4,
    parameter int MSHR_ENTRIES = 16,
    parameter int WAIT_ENTRIES = 32,
    parameter int WRITE_BUF_DEPTH = 8,
    parameter int BAR_CLOCK_PERIOD_NS = 10
);
    logic async_cpl_req_vld_i, async_cpl_req_rdy_o;
    logic [9:0] async_cpl_req_issuer_i;
    logic [63:0] async_cpl_req_seq_i;
    logic [7:0] async_cpl_req_status_i;
    tma_mbarrier_pkg::bw_async_req_t async_cpl_req_i;
    assign async_cpl_req_i = {1'b1,async_cpl_req_issuer_i,async_cpl_req_seq_i,async_cpl_req_status_i};
    logic tc_arrive_vld_i = 1'b0;
    wire tc_arrive_rdy_o;
    logic tc_arrive_rsp_rdy_i = 1'b1;
    wire tc_arrive_rsp_vld_o;
    tma_mbarrier_pkg::bar_cmd_t tc_arrive_i;
    tma_mbarrier_pkg::bar_rsp_t tc_arrive_rsp_o;
    logic [63:0] tc_arrive_addr_i = 64'd0;
    logic [15:0] tc_arrive_tag_i = 16'd0;
    wire [7:0] tc_arrive_status_o = tc_arrive_rsp_o.status;
    wire [15:0] tc_arrive_tag_o = tc_arrive_rsp_o.tag;
    logic tc_control_enable_i = 1'b0;
    logic register_vld_i = 1'b0;
    wire register_rdy_o;
    blackwell_async_pkg::async_id_t register_i;
    logic complete_vld_i = 1'b0;
    wire complete_rdy_o;
    blackwell_async_pkg::async_event_t complete_i;
    logic commit_vld_i = 1'b0;
    wire commit_rdy_o;
    blackwell_async_pkg::tc_commit_t commit_i;
    wire event_vld_o;
    logic event_rdy_i = 1'b1;
    blackwell_async_pkg::async_event_t event_o;
    wire protocol_error_o;
    wire controlled_vld, controlled_rsp_rdy;
    tma_mbarrier_pkg::bar_cmd_t controlled_cmd;
    wire selected_tc_vld = tc_control_enable_i ? controlled_vld : tc_arrive_vld_i;
    wire selected_tc_rsp_rdy = tc_control_enable_i ? controlled_rsp_rdy : tc_arrive_rsp_rdy_i;
    always_comb begin
        tc_arrive_i = '0;
        tc_arrive_i.addr = tc_arrive_addr_i;
        tc_arrive_i.tag = tc_arrive_tag_i;
        if (tc_control_enable_i) tc_arrive_i = controlled_cmd;
    end
    tcgen05_async_completion u_completion (
        .clk(clk), .rst_n(rst_n),
        .register_vld_i(register_vld_i), .register_rdy_o(register_rdy_o), .register_i(register_i),
        .complete_vld_i(complete_vld_i), .complete_rdy_o(complete_rdy_o), .complete_i(complete_i),
        .commit_vld_i(commit_vld_i), .commit_rdy_o(commit_rdy_o), .commit_i(commit_i),
        .bar_vld_o(controlled_vld), .bar_rdy_i(tc_arrive_rdy_o && tc_control_enable_i),
        .bar_o(controlled_cmd), .bar_rsp_vld_i(tc_arrive_rsp_vld_o && tc_control_enable_i),
        .bar_rsp_rdy_o(controlled_rsp_rdy), .bar_rsp_i(tc_arrive_rsp_o),
        .event_vld_o(event_vld_o), .event_rdy_i(event_rdy_i), .event_o(event_o),
        .protocol_error_o(protocol_error_o)
    );
    tma_mbarrier_pkg::bar_cmd_t bar_cmd_i;
    tma_mbarrier_pkg::bar_rsp_t bar_rsp_o;
    tma_mbarrier_pkg::tma_rsp_t tma_rsp_o;
    tma_mbarrier_pkg::bw_mem_attr_t gmem_req_attr_o, smem_req_attr_o;
    tma_mbarrier_pkg::bw_order_req_t tma_order_req_o;
    tma_mbarrier_pkg::bw_order_rsp_t tma_order_rsp_i;
    logic tma_order_req_vld_o, tma_order_req_rdy_i, tma_order_rsp_vld_i, tma_order_rsp_rdy_o;
    logic [15:0] tma_order_rsp_id_i;
    logic [7:0] tma_order_rsp_status_i;
    assign tma_order_rsp_i.id = tma_order_rsp_id_i;
    assign tma_order_rsp_i.status = tma_order_rsp_status_i;
    wire [15:0] tma_order_req_id_o = tma_order_req_o.id;
    wire [9:0] tma_order_req_issuer_o = tma_order_req_o.issuer;
    wire [63:0] tma_order_req_seq_o = tma_order_req_o.seq;
    wire [2:0] tma_order_req_kind_o = tma_order_req_o.kind;
    wire [1:0] tma_order_req_scope_o = tma_order_req_o.scope;
    wire [1:0] tma_order_req_from_proxy_o = tma_order_req_o.from_proxy;
    wire [1:0] tma_order_req_to_proxy_o = tma_order_req_o.to_proxy;
    wire [63:0] tma_order_req_addr_o = tma_order_req_o.addr;
    wire [63:0] tma_order_req_bytes_o = tma_order_req_o.bytes;
    wire [2:0] gmem_req_kind_o = gmem_req_attr_o.kind;
    wire [3:0] gmem_req_dtype_o = gmem_req_attr_o.dtype;
    wire [3:0] gmem_req_reduce_op_o = gmem_req_attr_o.reduce_op;
    wire [0:0] gmem_req_multimem_o = gmem_req_attr_o.multimem;
    wire [0:0] gmem_req_atomic128_o = gmem_req_attr_o.atomic128;
    wire [9:0] gmem_req_issuer_o = gmem_req_attr_o.issuer;
    wire [63:0] gmem_req_seq_o = gmem_req_attr_o.seq;
    wire [1:0] gmem_req_scope_o = gmem_req_attr_o.scope;
    wire [1:0] gmem_req_proxy_o = gmem_req_attr_o.proxy;
    wire [0:0] gmem_req_cache_hint_o = gmem_req_attr_o.cache_hint;
    wire [63:0] gmem_req_cache_policy_o = gmem_req_attr_o.cache_policy;
    wire [1:0] gmem_req_l2_promotion_o = gmem_req_attr_o.l2_promotion;
    wire [2:0] smem_req_kind_o = smem_req_attr_o.kind;
    wire [3:0] smem_req_dtype_o = smem_req_attr_o.dtype;
    wire [3:0] smem_req_reduce_op_o = smem_req_attr_o.reduce_op;
    wire [0:0] smem_req_multimem_o = smem_req_attr_o.multimem;
    wire [0:0] smem_req_atomic128_o = smem_req_attr_o.atomic128;
    wire [9:0] smem_req_issuer_o = smem_req_attr_o.issuer;
    wire [63:0] smem_req_seq_o = smem_req_attr_o.seq;
    wire [1:0] smem_req_scope_o = smem_req_attr_o.scope;
    wire [1:0] smem_req_proxy_o = smem_req_attr_o.proxy;
    wire [0:0] smem_req_cache_hint_o = smem_req_attr_o.cache_hint;
    wire [63:0] smem_req_cache_policy_o = smem_req_attr_o.cache_policy;
    wire [1:0] smem_req_l2_promotion_o = smem_req_attr_o.l2_promotion;
    assign tma_rsp_tag_o = tma_rsp_o.tag;
    assign tma_rsp_issuer_o = tma_rsp_o.issuer;
    assign tma_rsp_status_o = tma_rsp_o.status;
    assign tma_rsp_bytes_o = tma_rsp_o.bytes;
    tma_mbarrier_pkg::tma_cmd_t tma_cmd_i;
    logic [63:0] tma_cmd_seq_i;
    logic [3:0] tma_cmd_dtype_i;
    logic [3:0] tma_cmd_reduce_op_i;
    logic  tma_cmd_multimem_i;
    logic  tma_cmd_cp_mask_enable_i;
    logic [15:0] tma_cmd_cp_mask_i;
    logic  tma_cmd_ignore_oob_i;
    logic [3:0] tma_cmd_oob_start_i;
    logic [3:0] tma_cmd_oob_end_i;
    logic  tma_cmd_atomic128_i;
    logic [1:0] tma_cmd_sem_i;
    logic [1:0] tma_cmd_scope_i;
    logic  tma_cmd_cache_hint_i;
    logic [63:0] tma_cmd_cache_policy_i;
    logic  tma_cmd_map_shared_i;
    logic [3:0] tma_cmd_replace_field_i;
    logic [2:0] tma_cmd_replace_ord_i;
    logic [63:0] tma_cmd_replace_value_i;
    logic [1:0] tma_cmd_from_proxy_i;
    logic [1:0] tma_cmd_to_proxy_i;
    logic  tma_cmd_warp_converged_i;
    always_comb begin
        tma_cmd_i = '0;
        tma_cmd_i.opcode = tma_cmd_opcode_i;
        tma_cmd_i.tag = tma_cmd_tag_i;
        tma_cmd_i.issuer = tma_cmd_issuer_i;
        tma_cmd_i.seq = tma_cmd_seq_i;
        tma_cmd_i.desc_ptr = tma_cmd_desc_ptr_i;
        tma_cmd_i.coord = tma_cmd_coord_i;
        tma_cmd_i.smem_addr = tma_cmd_smem_addr_i;
        tma_cmd_i.linear_addr = tma_cmd_linear_addr_i;
        tma_cmd_i.linear_bytes = tma_cmd_linear_bytes_i;
        tma_cmd_i.barrier_addr = tma_cmd_barrier_addr_i;
        tma_cmd_i.mode = tma_cmd_mode_i;
        tma_cmd_i.im2col = tma_cmd_im2col_i;
        tma_cmd_i.completion = tma_cmd_completion_i;
        tma_cmd_i.multi_cta = tma_cmd_multi_cta_i;
        tma_cmd_i.wait_n = tma_cmd_wait_n_i;
        tma_cmd_i.wait_read = tma_cmd_wait_read_i;
        tma_cmd_i.dtype = tma_cmd_dtype_i;
        tma_cmd_i.reduce_op = tma_cmd_reduce_op_i;
        tma_cmd_i.multimem = tma_cmd_multimem_i;
        tma_cmd_i.cp_mask_enable = tma_cmd_cp_mask_enable_i;
        tma_cmd_i.cp_mask = tma_cmd_cp_mask_i;
        tma_cmd_i.ignore_oob = tma_cmd_ignore_oob_i;
        tma_cmd_i.oob_start = tma_cmd_oob_start_i;
        tma_cmd_i.oob_end = tma_cmd_oob_end_i;
        tma_cmd_i.atomic128 = tma_cmd_atomic128_i;
        tma_cmd_i.sem = tma_cmd_sem_i;
        tma_cmd_i.scope = tma_cmd_scope_i;
        tma_cmd_i.cache_hint = tma_cmd_cache_hint_i;
        tma_cmd_i.cache_policy = tma_cmd_cache_policy_i;
        tma_cmd_i.map_shared = tma_cmd_map_shared_i;
        tma_cmd_i.replace_field = tma_cmd_replace_field_i;
        tma_cmd_i.replace_ord = tma_cmd_replace_ord_i;
        tma_cmd_i.replace_value = tma_cmd_replace_value_i;
        tma_cmd_i.from_proxy = tma_cmd_from_proxy_i;
        tma_cmd_i.to_proxy = tma_cmd_to_proxy_i;
        tma_cmd_i.warp_converged = tma_cmd_warp_converged_i;
    end
    logic async_req_vld_i;
    wire async_req_rdy_o;
    tma_mbarrier_pkg::bw_async_req_t async_req_i;
    wire async_rsp_vld_o;
    logic async_rsp_rdy_i;
    tma_mbarrier_pkg::bw_async_rsp_t async_rsp_o;
    logic report_req_vld_i;
    wire report_req_rdy_o;
    tma_mbarrier_pkg::bar_report_req_t report_req_i;
    wire report_rsp_vld_o;
    logic report_rsp_rdy_i;
    tma_mbarrier_pkg::bar_rsp_t report_rsp_o;
    wire bar_order_req_vld_o;
    logic bar_order_req_rdy_i;
    tma_mbarrier_pkg::bw_order_req_t bar_order_req_o;
    logic bar_order_rsp_vld_i;
    wire bar_order_rsp_rdy_o;
    tma_mbarrier_pkg::bw_order_rsp_t bar_order_rsp_i;
    logic [9:0] bar_cmd_issuer_i;
    logic [63:0] bar_cmd_seq_i;
    logic  bar_cmd_noinc_i;
    logic [1:0] bar_cmd_sem_i;
    logic [1:0] bar_cmd_scope_i;
    wire [9:0] bar_rsp_issuer_o;
    always_comb begin
        bar_cmd_i = '0;
        bar_cmd_i.opcode = bar_cmd_opcode_i;
        bar_cmd_i.tag = bar_cmd_tag_i;
        bar_cmd_i.issuer = bar_cmd_issuer_i;
        bar_cmd_i.seq = bar_cmd_seq_i;
        bar_cmd_i.addr = bar_cmd_addr_i;
        bar_cmd_i.arrive_count = bar_cmd_arrive_count_i;
        bar_cmd_i.tx_bytes = bar_cmd_tx_bytes_i;
        bar_cmd_i.phase_token = bar_cmd_phase_token_i;
        bar_cmd_i.wait_parity = bar_cmd_wait_parity_i;
        bar_cmd_i.state = bar_cmd_state_i;
        bar_cmd_i.time_hint = bar_cmd_time_hint_i;
        bar_cmd_i.layout = bar_cmd_layout_i;
        bar_cmd_i.no_complete = bar_cmd_no_complete_i;
        bar_cmd_i.conditional = bar_cmd_conditional_i;
        bar_cmd_i.report = bar_cmd_report_i;
        bar_cmd_i.noinc = bar_cmd_noinc_i;
        bar_cmd_i.sem = bar_cmd_sem_i;
        bar_cmd_i.scope = bar_cmd_scope_i;
    end
    assign bar_rsp_tag_o = bar_rsp_o.tag;
    assign bar_rsp_issuer_o = bar_rsp_o.issuer;
    assign bar_rsp_status_o = bar_rsp_o.status;
    assign bar_rsp_phase_o = bar_rsp_o.phase;
    assign bar_rsp_locked_o = bar_rsp_o.locked;
    assign bar_rsp_state_o = bar_rsp_o.state;
    assign bar_rsp_wait_complete_o = bar_rsp_o.wait_complete;
    assign bar_rsp_value_o = bar_rsp_o.value;
    assign bar_rsp_predicate_o = bar_rsp_o.predicate;
    assign bar_rsp_report_o = bar_rsp_o.report;
    assign bar_rsp_report_predicate_o = bar_rsp_o.report_predicate;
    logic  async_req_complete_i;
    assign async_req_i.complete = async_req_complete_i;
    logic [9:0] async_req_issuer_i;
    assign async_req_i.issuer = async_req_issuer_i;
    logic [63:0] async_req_seq_i;
    assign async_req_i.seq = async_req_seq_i;
    logic [7:0] async_req_status_i;
    assign async_req_i.status = async_req_status_i;
    wire [9:0] async_rsp_issuer_o;
    assign async_rsp_issuer_o = async_rsp_o.issuer;
    wire [63:0] async_rsp_seq_o;
    assign async_rsp_seq_o = async_rsp_o.seq;
    wire [7:0] async_rsp_status_o;
    assign async_rsp_status_o = async_rsp_o.status;
    logic [15:0] report_req_tag_i;
    assign report_req_i.tag = report_req_tag_i;
    logic [63:0] report_req_addr_i;
    assign report_req_i.addr = report_req_addr_i;
    logic [7:0] report_req_value_i;
    assign report_req_i.value = report_req_value_i;
    wire [15:0] report_rsp_tag_o;
    assign report_rsp_tag_o = report_rsp_o.tag;
    wire [9:0] report_rsp_issuer_o;
    assign report_rsp_issuer_o = report_rsp_o.issuer;
    wire [7:0] report_rsp_status_o;
    assign report_rsp_status_o = report_rsp_o.status;
    wire  report_rsp_phase_o;
    assign report_rsp_phase_o = report_rsp_o.phase;
    wire  report_rsp_locked_o;
    assign report_rsp_locked_o = report_rsp_o.locked;
    wire [63:0] report_rsp_state_o;
    assign report_rsp_state_o = report_rsp_o.state;
    wire  report_rsp_wait_complete_o;
    assign report_rsp_wait_complete_o = report_rsp_o.wait_complete;
    wire [31:0] report_rsp_value_o;
    assign report_rsp_value_o = report_rsp_o.value;
    wire  report_rsp_predicate_o;
    assign report_rsp_predicate_o = report_rsp_o.predicate;
    wire [7:0] report_rsp_report_o;
    assign report_rsp_report_o = report_rsp_o.report;
    wire  report_rsp_report_predicate_o;
    assign report_rsp_report_predicate_o = report_rsp_o.report_predicate;
    wire [15:0] bar_order_req_id_o;
    assign bar_order_req_id_o = bar_order_req_o.id;
    wire [9:0] bar_order_req_issuer_o;
    assign bar_order_req_issuer_o = bar_order_req_o.issuer;
    wire [63:0] bar_order_req_seq_o;
    assign bar_order_req_seq_o = bar_order_req_o.seq;
    wire [2:0] bar_order_req_kind_o;
    assign bar_order_req_kind_o = bar_order_req_o.kind;
    wire [1:0] bar_order_req_scope_o;
    assign bar_order_req_scope_o = bar_order_req_o.scope;
    wire [1:0] bar_order_req_from_proxy_o;
    assign bar_order_req_from_proxy_o = bar_order_req_o.from_proxy;
    wire [1:0] bar_order_req_to_proxy_o;
    assign bar_order_req_to_proxy_o = bar_order_req_o.to_proxy;
    wire [63:0] bar_order_req_addr_o;
    assign bar_order_req_addr_o = bar_order_req_o.addr;
    wire [63:0] bar_order_req_bytes_o;
    assign bar_order_req_bytes_o = bar_order_req_o.bytes;
    logic [15:0] bar_order_rsp_id_i;
    assign bar_order_rsp_i.id = bar_order_rsp_id_i;
    logic [7:0] bar_order_rsp_status_i;
    assign bar_order_rsp_i.status = bar_order_rsp_status_i;
    logic  bar_cmd_layout_i;
    logic  bar_cmd_no_complete_i;
    logic  bar_cmd_conditional_i;
    logic [7:0] bar_cmd_report_i;
    wire [31:0] bar_rsp_value_o;
    wire  bar_rsp_predicate_o;
    wire [7:0] bar_rsp_report_o;
    wire  bar_rsp_report_predicate_o;
    logic [9:0] tma_cmd_issuer_i;
    logic [2:0] tma_cmd_mode_i;
    logic [79:0] tma_cmd_im2col_i;
    logic [1:0] tma_cmd_completion_i;
    logic  tma_cmd_multi_cta_i;
    logic [31:0] tma_cmd_wait_n_i;
    logic  tma_cmd_wait_read_i;
    wire [9:0] tma_rsp_issuer_o;
    logic  bar_cmd_wait_parity_i;
    logic [63:0] bar_cmd_state_i;
    logic [31:0] bar_cmd_time_hint_i;
    wire [63:0] bar_rsp_state_o;
    wire  bar_rsp_wait_complete_o;
    logic clk;
    logic rst_n;

    logic          tma_cmd_vld_i;
    wire           tma_cmd_rdy_o;
    logic [4:0]    tma_cmd_opcode_i;
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
    logic [4:0]    bar_cmd_opcode_i;
    logic [15:0]   bar_cmd_tag_i;
    logic [63:0]   bar_cmd_addr_i;
    logic [31:0]   bar_cmd_arrive_count_i;
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

    wire real_smem_req_rdy_o, real_smem_rsp_vld_o;
    wire [255:0] real_smem_rsp_data_o;
    wire [1:0] real_smem_rsp_status_o;
    wire [5:0] real_smem_rsp_id_o;
    logic real_smem_ack_enable_i = 1'b1;
    logic debug_req_vld_i = 1'b0;
    wire debug_req_rdy_o;
    logic [31:0] debug_req_addr_i = '0;
    logic [1023:0] debug_req_data_i = '0;
    logic [127:0] debug_req_mask_i = '0;
    logic [1:0] debug_req_kind_i = '0;
    logic [3:0] debug_req_dtype_i = '0, debug_req_op_i = '0;
    logic [15:0] debug_req_tag_i = '0;
    wire debug_rsp_vld_o;
    logic debug_rsp_rdy_i = 1'b1;
    wire [1023:0] debug_rsp_data_o;
    wire [15:0] debug_rsp_tag_o;
    wire debug_rsp_error_o;
    wire [1:0] smem_protocol_error_o;
    if (REAL_SMEM != 0) begin : gen_real_smem
        blackwell_tma_smem_bridge #(.AUX_CLIENTS(1)) memory_backend (
            .clk,.rst_n,.mem_req_vld_i(smem_req_vld_o),.mem_req_rdy_o(real_smem_req_rdy_o),
            .mem_req_addr_i(smem_req_addr_o),.mem_req_data_i(smem_req_data_o),.mem_req_mask_i(smem_req_mask_o),
            .mem_req_id_i(smem_req_id_o),.mem_req_attr_i(smem_req_attr_o),
            .mem_rsp_vld_o(real_smem_rsp_vld_o),.mem_rsp_rdy_i(smem_rsp_rdy_o && real_smem_ack_enable_i),
            .mem_rsp_data_o(real_smem_rsp_data_o),.mem_rsp_id_o(real_smem_rsp_id_o),.mem_rsp_status_o(real_smem_rsp_status_o),
            .req_vld_i(debug_req_vld_i),.req_rdy_o(debug_req_rdy_o),.req_addr_i(debug_req_addr_i),
            .req_data_i(debug_req_data_i),.req_mask_i(debug_req_mask_i),.req_kind_i(debug_req_kind_i),
            .req_dtype_i(debug_req_dtype_i),.req_op_i(debug_req_op_i),.req_tag_i(debug_req_tag_i),
            .rsp_vld_o(debug_rsp_vld_o),.rsp_rdy_i(debug_rsp_rdy_i),.rsp_data_o(debug_rsp_data_o),
            .rsp_tag_o(debug_rsp_tag_o),.rsp_error_o(debug_rsp_error_o),.protocol_error_o(smem_protocol_error_o)
        );
    end else begin : gen_external_smem
        assign real_smem_req_rdy_o = smem_req_rdy_i;
        assign real_smem_rsp_vld_o = smem_rsp_vld_i;
        assign real_smem_rsp_data_o = smem_rsp_data_i;
        assign real_smem_rsp_status_o = smem_rsp_status_i;
        assign real_smem_rsp_id_o = smem_rsp_id_i;
        assign debug_req_rdy_o = 1'b0;
        assign debug_rsp_vld_o = 1'b0;
        assign debug_rsp_data_o = '0;
        assign debug_rsp_tag_o = '0;
        assign debug_rsp_error_o = 1'b0;
        assign smem_protocol_error_o = '0;
    end

    tma_mbarrier_subsystem #(
        .BAR_ASYNC_ENTRIES(BAR_ASYNC_ENTRIES),
        .CMD_QUEUE_DEPTH(CMD_QUEUE_DEPTH), .DESC_CACHE_ENTRIES(DESC_CACHE_ENTRIES),
        .MSHR_ENTRIES(MSHR_ENTRIES), .WAIT_ENTRIES(WAIT_ENTRIES),
        .WRITE_BUF_DEPTH(WRITE_BUF_DEPTH), .BAR_CLOCK_PERIOD_NS(BAR_CLOCK_PERIOD_NS)
    ) u_dut (.tc_arrive_vld_i(selected_tc_vld), .tc_arrive_rsp_rdy_i(selected_tc_rsp_rdy),
        .smem_req_rdy_i(real_smem_req_rdy_o),.smem_rsp_vld_i(real_smem_rsp_vld_o && real_smem_ack_enable_i),
        .smem_rsp_data_i(real_smem_rsp_data_o),.smem_rsp_status_i(real_smem_rsp_status_o),.smem_rsp_id_i(real_smem_rsp_id_o), .*);
endmodule

`default_nettype wire
