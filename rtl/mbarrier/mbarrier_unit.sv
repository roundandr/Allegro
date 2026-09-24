// ============================================================================
// File Name   : mbarrier_unit.sv
// Date        : 2026-08-27
// Description : Memory-backed transaction barrier with phase-token waits.
//
// Architecture notes:
//   * Four-entry fully associative, non-coherent state cache by default.
//   * State-changing hits enqueue a write-through update.
//   * A wait completes when the cached phase differs from its old-phase token.
//   * TMA transaction completions share the same serialized datapath.
// ============================================================================

`default_nettype none

module mbarrier_unit #(
    parameter int unsigned ADDR_W          = 64,
    parameter int unsigned CACHE_ENTRIES   = 4,
    parameter int unsigned WAIT_ENTRIES    = 32,
    parameter int unsigned WRITE_BUF_DEPTH = 8,
    parameter int unsigned MEM_ID_W        = 2,
    parameter int unsigned CLOCK_PERIOD_NS = 10,
    parameter int unsigned WAIT_DEFAULT_CYCLES = 64
) (

    input wire  bar_cmd_layout_i,
    input wire  bar_cmd_no_complete_i,
    input wire  bar_cmd_conditional_i,
    input wire [7:0] bar_cmd_report_i,
    output wire [31:0] bar_rsp_value_o,
    output wire  bar_rsp_predicate_o,
    output wire [7:0] bar_rsp_report_o,
    output wire  bar_rsp_report_predicate_o,
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    bar_cmd_vld_i,
    output wire                    bar_cmd_rdy_o,
    input  wire [4:0]              bar_cmd_opcode_i,
    input  wire [15:0]             bar_cmd_tag_i,
    input  wire [ADDR_W-1:0]       bar_cmd_addr_i,
    input  wire [31:0]             bar_cmd_arrive_count_i,
    input  wire [63:0]             bar_cmd_tx_bytes_i,
    input  wire                    bar_cmd_phase_token_i,

    input  wire                    bar_cmd_wait_parity_i,
    input  wire [63:0]             bar_cmd_state_i,
    input  wire [31:0]             bar_cmd_time_hint_i,
    output wire [63:0]             bar_rsp_state_o,
    output wire                    bar_rsp_wait_complete_o,
    output wire                    bar_rsp_vld_o,
    input  wire                    bar_rsp_rdy_i,
    output wire [15:0]             bar_rsp_tag_o,
    output wire [7:0]              bar_rsp_status_o,
    output wire                    bar_rsp_phase_o,
    output wire                    bar_rsp_locked_o,

    input wire tc_cmd_vld_i,
    output wire tc_cmd_rdy_o,
    input tma_mbarrier_pkg::bar_cmd_t tc_cmd_i,

    input  wire                    tx_cpl_vld_i,
    output wire                    tx_cpl_rdy_o,
    input  wire [15:0]             tx_cpl_tag_i,
    input  wire [ADDR_W-1:0]       tx_cpl_addr_i,
    input  wire [63:0]             tx_cpl_bytes_i,

    output wire                    tx_rsp_vld_o,
    input  wire                    tx_rsp_rdy_i,
    output wire [15:0]             tx_rsp_tag_o,
    output wire [7:0]              tx_rsp_status_o,
    output wire                    tx_rsp_phase_o,

    output wire                    mem_req_vld_o,
    input  wire                    mem_req_rdy_i,
    output wire                    mem_req_write_o,
    output wire [ADDR_W-1:0]       mem_req_addr_o,
    output wire [255:0]            mem_req_data_o,
    output wire [31:0]             mem_req_mask_o,
    output wire [MEM_ID_W-1:0]     mem_req_id_o,

    input  wire                    mem_rsp_vld_i,
    output wire                    mem_rsp_rdy_o,
    input  wire [255:0]            mem_rsp_data_i,
    input  wire [1:0]              mem_rsp_status_i,
    input  wire [MEM_ID_W-1:0]     mem_rsp_id_i
);
    import tma_mbarrier_pkg::*;

    localparam int unsigned CACHE_IDX_W = (CACHE_ENTRIES <= 1) ? 1 : $clog2(CACHE_ENTRIES);
    localparam int unsigned WAIT_IDX_W  = (WAIT_ENTRIES <= 1) ? 1 : $clog2(WAIT_ENTRIES);
    localparam int unsigned WR_PTR_W    = (WRITE_BUF_DEPTH <= 1) ? 1 : $clog2(WRITE_BUF_DEPTH);
    localparam int unsigned WR_CNT_W    = $clog2(WRITE_BUF_DEPTH + 1);


    logic                    cache_locked_q [0:CACHE_ENTRIES-1];
    logic                    op_layout_q, op_no_complete_q, op_conditional_q, op_parity_q;
    logic [63:0]             op_input_state_q;
    logic [7:0]              op_report_q;
    logic                    wait_conditional_q [0:WAIT_ENTRIES-1];
    logic [31:0]             bar_rsp_value_q;
    logic                    bar_rsp_predicate_q;
    logic [7:0]              bar_rsp_report_q;
    logic [7:0]              wake_report;
    logic [31:0]             op_value;
    logic                    op_predicate, op_wait_complete;
    bar_object_t             op_object_cur, op_object_next;
    logic [63:0]             op_token;
    logic [31:0]             op_count_limit;
    logic                    cache_vld_q [0:CACHE_ENTRIES-1];
    logic [ADDR_W-1:0]       cache_addr_q [0:CACHE_ENTRIES-1];
    logic [63:0]             cache_state_q [0:CACHE_ENTRIES-1];
    logic [CACHE_IDX_W-1:0]  cache_replace_q;

    logic                    wait_vld_q [0:WAIT_ENTRIES-1];
    logic [ADDR_W-1:0]       wait_addr_q [0:WAIT_ENTRIES-1];
    logic [15:0]             wait_tag_q [0:WAIT_ENTRIES-1];
    logic                    wait_phase_q [0:WAIT_ENTRIES-1];

    logic [ADDR_W-1:0]       wr_addr_q [0:WRITE_BUF_DEPTH-1];
    logic [63:0]             wr_state_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_vld_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_is_tx_q [0:WRITE_BUF_DEPTH-1];
    logic [15:0]             wr_tag_q [0:WRITE_BUF_DEPTH-1];
    logic [7:0]              wr_status_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_phase_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_locked_q [0:WRITE_BUF_DEPTH-1];
    logic [WR_PTR_W-1:0]     wr_rd_ptr_q;
    logic [WR_PTR_W-1:0]     wr_wr_ptr_q;
    logic [WR_CNT_W-1:0]     wr_count_q;

    logic [63:0]             wr_token_q [0:WRITE_BUF_DEPTH-1];
    logic [63:0]             mem_busy_token_q;
    logic [63:0]             bar_rsp_state_q;
    logic                    bar_rsp_wait_complete_q;
    logic [31:0]             wait_cycles_q [0:WAIT_ENTRIES-1];
    logic [31:0]             op_wait_cycles_q;
    logic                    wake_complete;
    logic                    op_vld_q;
    logic                    op_is_tx_q;
    logic [4:0]              op_opcode_q;
    logic [15:0]             op_tag_q;
    logic [ADDR_W-1:0]       op_addr_q;
    logic [31:0]             op_arrive_q;
    logic [63:0]             op_tx_bytes_q;
    logic                    op_phase_token_q;
    logic [1:0]              arb_next_q;
    logic [2:0]              arb_requests, arb_grant;
    logic                    accept_tc;
    logic                    op_force_error_q;

    logic                    miss_active_q;
    logic                    miss_sent_q;
    logic [ADDR_W-1:0]       miss_addr_q;
    logic [CACHE_IDX_W-1:0]  miss_slot_q;

    logic                    mem_req_vld_q;
    logic                    mem_req_write_q;
    logic [ADDR_W-1:0]       mem_req_addr_q;
    logic [255:0]            mem_req_data_q;
    logic [31:0]             mem_req_mask_q;
    logic [MEM_ID_W-1:0]     mem_req_id_q;
    logic                    mem_busy_q;
    logic                    mem_busy_write_q;
    logic [ADDR_W-1:0]       mem_busy_addr_q;
    logic                    mem_busy_is_tx_q;
    logic [15:0]             mem_busy_tag_q;
    logic [7:0]              mem_busy_status_q;
    logic                    mem_busy_phase_q;
    logic                    mem_busy_locked_q;

    logic                    bar_rsp_vld_q;
    logic [15:0]             bar_rsp_tag_q;
    logic [7:0]              bar_rsp_status_q;
    logic                    bar_rsp_phase_q;
    logic                    bar_rsp_locked_q;
    logic                    tx_rsp_vld_q;
    logic [15:0]             tx_rsp_tag_q;
    logic [7:0]              tx_rsp_status_q;
    logic                    tx_rsp_phase_q;

    logic                    op_cache_hit;
    logic [CACHE_IDX_W-1:0]  op_cache_idx;
    logic [63:0]             op_state_cur;
    logic [63:0]             op_state_next;
    logic                    op_state_change;
    logic                    op_phase_flip;
    logic                    op_phase_cur;
    logic                    op_lock_cur;
    logic [19:0]             op_expected_cur;
    logic [19:0]             op_remaining_cur;
    logic signed [20:0]      op_tx_balance_cur;
    logic                    op_phase_next;
    logic                    op_lock_next;
    logic [19:0]             op_remaining_next;
    logic signed [20:0]      op_tx_balance_next;
    logic signed [64:0]      op_tx_ext;
    logic [7:0]              op_status;
    logic                    op_rsp_needed;
    logic                    op_wait_enqueue;
    logic                    op_finish;
    logic                    op_can_process;
    logic                    op_init_slot_found;
    logic [CACHE_IDX_W-1:0]  op_init_slot;

    logic                    wait_free_found;
    logic                    wait_second_free_found;
    logic [WAIT_IDX_W-1:0]   wait_free_idx;
    logic                    wake_found;
    logic [WAIT_IDX_W-1:0]   wake_idx;
    logic [7:0]              wake_status;
    logic                    wake_phase;
    logic                    wake_locked;
    logic [CACHE_ENTRIES-1:0] cache_has_wait;
    logic [CACHE_ENTRIES-1:0] cache_has_pending_write;

    logic                    op_accept;
    logic                    accept_tx;
    logic                    bar_rsp_slot_rdy;
    logic                    tx_rsp_slot_rdy;
    logic                    mem_req_fire;
    logic                    mem_rsp_fire;
    logic                    wr_pop;
    logic                    wr_enq;
    logic                    victim_has_wait;
    logic                    incoming_wait_blocked;
    logic                    bar_rsp_slot_for_op;
    logic                    tx_rsp_slot_for_op;

    assign bar_rsp_slot_rdy = !bar_rsp_vld_q || bar_rsp_rdy_i;
    assign tx_rsp_slot_rdy = !tx_rsp_vld_q || tx_rsp_rdy_i;
    assign bar_rsp_slot_for_op = bar_rsp_slot_rdy &&
        !(mem_rsp_vld_i && mem_busy_q && mem_busy_write_q &&
          !mem_busy_is_tx_q) && !wake_found;
    assign tx_rsp_slot_for_op = tx_rsp_slot_rdy &&
        !(mem_rsp_vld_i && mem_busy_q && mem_busy_write_q &&
          mem_busy_is_tx_q);

    assign bar_rsp_value_o = bar_rsp_value_q;
    assign bar_rsp_predicate_o = bar_rsp_predicate_q;
    assign bar_rsp_report_o = bar_rsp_report_q;
    assign bar_rsp_report_predicate_o = |bar_rsp_report_q;
    assign bar_rsp_state_o = bar_rsp_state_q;
    assign bar_rsp_wait_complete_o = bar_rsp_wait_complete_q;
    assign bar_rsp_vld_o = bar_rsp_vld_q;
    assign bar_rsp_tag_o = bar_rsp_tag_q;
    assign bar_rsp_status_o = bar_rsp_status_q;
    assign bar_rsp_phase_o = bar_rsp_phase_q;
    assign bar_rsp_locked_o = bar_rsp_locked_q;
    assign tx_rsp_vld_o = tx_rsp_vld_q;
    assign tx_rsp_tag_o = tx_rsp_tag_q;
    assign tx_rsp_status_o = tx_rsp_status_q;
    assign tx_rsp_phase_o = tx_rsp_phase_q;

    assign mem_req_vld_o = mem_req_vld_q;
    assign mem_req_write_o = mem_req_write_q;
    assign mem_req_addr_o = {mem_req_addr_q[ADDR_W-1:5], 5'd0};
    assign mem_req_data_o = mem_req_data_q;
    assign mem_req_mask_o = mem_req_mask_q;
    assign mem_req_id_o = mem_req_id_q;
    assign mem_rsp_rdy_o = mem_busy_q &&
        (!mem_busy_write_q ||
         (mem_busy_is_tx_q ? tx_rsp_slot_rdy : bar_rsp_slot_rdy));
    assign mem_req_fire = mem_req_vld_q && mem_req_rdy_i;
    assign mem_rsp_fire = mem_rsp_vld_i && mem_rsp_rdy_o;
    assign wr_pop = mem_req_fire && mem_req_write_q;

    // Three independent producers reach this arbitration point. In particular,
    // a software TRY_WAIT blocked by a full waiter table cannot hide a TC arrival.
    assign incoming_wait_blocked = bar_cmd_vld_i &&
        (bar_cmd_opcode_i == MBAR_OP_TRY_WAIT) &&
        (!wait_free_found ||
         (op_vld_q && op_finish && op_wait_enqueue && !wait_second_free_found));
    assign arb_requests = {tc_cmd_vld_i, tx_cpl_vld_i,
                           bar_cmd_vld_i && !incoming_wait_blocked};
    always_comb begin
        arb_grant = '0;
        for (int offset = 0; offset < 3; offset++) begin
            if (arb_grant == '0 && arb_requests[(int'(arb_next_q)+offset)%3])
                arb_grant[(int'(arb_next_q)+offset)%3] = 1'b1;
        end
    end
    assign accept_tx = arb_grant[1];
    assign accept_tc = arb_grant[2];
    assign op_accept = (!op_vld_q || op_finish) && (|arb_grant);
    assign tx_cpl_rdy_o = (!op_vld_q || op_finish) && arb_grant[1];
    assign tc_cmd_rdy_o = (!op_vld_q || op_finish) && arb_grant[2];
    assign bar_cmd_rdy_o = (!op_vld_q || op_finish) && arb_grant[0];

    always_comb begin
        op_cache_hit = 1'b0;
        op_cache_idx = {CACHE_IDX_W{1'b0}};
        for (int unsigned hit_idx = 0; hit_idx < CACHE_ENTRIES;
             hit_idx = hit_idx + 1) begin
            if (cache_vld_q[hit_idx] &&
                (cache_addr_q[hit_idx] == op_addr_q)) begin
                op_cache_hit = 1'b1;
                op_cache_idx = CACHE_IDX_W'(hit_idx);
            end
        end
    end

    always_comb begin
        wait_free_found = 1'b0;
        wait_second_free_found = 1'b0;
        wait_free_idx = {WAIT_IDX_W{1'b0}};
        for (int unsigned free_idx = 0; free_idx < WAIT_ENTRIES;
             free_idx = free_idx + 1) begin
            if (!wait_vld_q[free_idx] && !wait_free_found) begin
                wait_free_found = 1'b1;
                wait_free_idx = WAIT_IDX_W'(free_idx);
            end else if (!wait_vld_q[free_idx]) begin
                wait_second_free_found = 1'b1;
            end
        end
    end

    always_comb begin
        cache_has_wait = '0;
        for (int unsigned wait_scan = 0; wait_scan < WAIT_ENTRIES;
             wait_scan = wait_scan + 1) begin
            for (int unsigned cache_scan = 0; cache_scan < CACHE_ENTRIES;
                 cache_scan = cache_scan + 1) begin
                if (wait_vld_q[wait_scan] && cache_vld_q[cache_scan] &&
                    (wait_addr_q[wait_scan] == cache_addr_q[cache_scan])) begin
                    cache_has_wait[cache_scan] = 1'b1;
                end
            end
        end
    end

    // A phase or lock update is not visible to waiters until every older
    // write-through update for the same cache line has been acknowledged.
    // This prevents a waiter from reporting success before a failing backing
    // write has had the opportunity to lock the barrier.
    always_comb begin
        cache_has_pending_write = '0;
        for (int unsigned cache_scan = 0; cache_scan < CACHE_ENTRIES;
             cache_scan = cache_scan + 1) begin
            if (cache_vld_q[cache_scan]) begin
                if (mem_busy_q && mem_busy_write_q &&
                    (mem_busy_addr_q == cache_addr_q[cache_scan])) begin
                    cache_has_pending_write[cache_scan] = 1'b1;
                end
                for (int unsigned wr_scan = 0; wr_scan < WRITE_BUF_DEPTH;
                     wr_scan = wr_scan + 1) begin
                    if (wr_vld_q[wr_scan] &&
                        (wr_addr_q[wr_scan] == cache_addr_q[cache_scan])) begin
                        cache_has_pending_write[cache_scan] = 1'b1;
                    end
                end
            end
        end
    end

    // Prefer an invalid cache line.  Otherwise select the round-robin line if
    // it has no resident waiter, then fall back to the first waiter-free line.
    always_comb begin
        op_init_slot_found = 1'b0;
        op_init_slot = cache_replace_q;
        victim_has_wait = 1'b0;
        victim_has_wait = cache_has_wait[cache_replace_q] || cache_has_pending_write[cache_replace_q] ||
            (cache_vld_q[cache_replace_q] && cache_locked_q[cache_replace_q]);
        for (int unsigned invalid_idx = 0;
             invalid_idx < CACHE_ENTRIES; invalid_idx = invalid_idx + 1) begin
            if (!cache_vld_q[invalid_idx] && !op_init_slot_found) begin
                op_init_slot_found = 1'b1;
                op_init_slot = CACHE_IDX_W'(invalid_idx);
            end
        end
        if (!op_init_slot_found && !victim_has_wait) begin
            op_init_slot_found = 1'b1;
            op_init_slot = cache_replace_q;
        end
        if (!op_init_slot_found) begin
            for (int unsigned victim_idx = 0;
                 victim_idx < CACHE_ENTRIES; victim_idx = victim_idx + 1) begin
                if (!cache_has_wait[victim_idx] && !cache_has_pending_write[victim_idx] &&
                    !cache_locked_q[victim_idx] && !op_init_slot_found) begin
                    op_init_slot_found = 1'b1;
                    op_init_slot = CACHE_IDX_W'(victim_idx);
                end
            end
        end
    end

    always_comb begin
        op_state_cur = op_cache_hit ? cache_state_q[op_cache_idx] : 64'd0;
        op_object_cur = bar_unpack(op_state_cur);
        op_object_next = op_object_cur;
        op_phase_cur = op_object_cur.phase;
        op_lock_cur = op_cache_hit && cache_locked_q[op_cache_idx];
        op_expected_cur = op_object_cur.expected;
        op_remaining_cur = op_object_cur.pending;
        op_tx_balance_cur = op_object_cur.tx;
        op_count_limit = (op_opcode_q == MBAR_OP_INIT ? op_layout_q : op_object_cur.layout_v1) ?
            32'd511 : 32'd1048575;
        op_token = bar_token(op_object_cur, op_no_complete_q);
        op_state_change = 1'b0;
        op_phase_flip = 1'b0;
        op_lock_next = op_lock_cur;
        op_tx_ext = {{44{op_tx_balance_cur[20]}}, op_tx_balance_cur};
        op_status = MBAR_STATUS_OK;
        op_rsp_needed = 1'b1;
        op_wait_enqueue = 1'b0;
        op_can_process = 1'b0;
        op_value = 32'd0;
        op_predicate = 1'b0;
        op_wait_complete = 1'b0;

        // pending_count reads only the captured token, never backing memory.
        if (op_opcode_q == MBAR_OP_PENDING_COUNT) begin
            op_can_process = 1'b1;
            if (op_input_state_q[63:56] != 8'ha7 || !op_input_state_q[0] ||
                op_input_state_q[2] || !op_input_state_q[3] || op_layout_q)
                op_status = MBAR_STATUS_BAD_TOKEN;
            else op_value = {12'd0, op_input_state_q[4 +: 20]};
        end else if (op_addr_q[2:0] != 3'd0) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_BAD_ALIGN;
        end else if (op_force_error_q) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_MEMORY;
        end else if (op_no_complete_q && op_opcode_q != MBAR_OP_ARRIVE && op_opcode_q != MBAR_OP_ARRIVE_DROP) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_BAD_MODIFIER;
        end else if (op_opcode_q == MBAR_OP_INIT && op_cache_hit && op_lock_cur) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_LOCKED;
        end else if (op_opcode_q == MBAR_OP_INIT) begin
            op_can_process = op_cache_hit || op_init_slot_found;
            op_object_next = '0;
            op_object_next.valid = 1'b1;
            op_object_next.layout_v1 = op_layout_q;
            op_object_next.expected = op_arrive_q[19:0];
            op_object_next.pending = op_arrive_q[19:0];
            op_state_change = op_can_process;
            op_lock_next = 1'b0;
            if (op_arrive_q == 0 || op_arrive_q > op_count_limit) begin
                op_status = MBAR_STATUS_BAD_ARRIVE;
                op_lock_next = 1'b1;
            end
        end else if (op_cache_hit) begin
            op_can_process = 1'b1;
            if (op_opcode_q == MBAR_OP_INVAL) begin
                op_object_next = '0;
                op_lock_next = 1'b0;
                op_state_change = 1'b1;
            end else if (!op_object_cur.valid) begin
                op_status = MBAR_STATUS_UNINITIALIZED;
            end else if (op_lock_cur) begin
                op_status = MBAR_STATUS_LOCKED;
            end else begin
                case (op_opcode_q)
                    MBAR_OP_ARRIVE, MBAR_OP_ARRIVE_EXPECT_TX,
                    MBAR_OP_ARRIVE_DROP, MBAR_OP_DROP_EXPECT_TX: begin
                        op_state_change = 1'b1;
                        if (op_arrive_q == 0 || op_arrive_q > {12'd0, op_object_cur.pending}) begin
                            op_status = MBAR_STATUS_BAD_ARRIVE;
                        end else begin
                            op_object_next.pending = op_object_cur.pending - op_arrive_q[19:0];
                        end
                        if (op_opcode_q == MBAR_OP_ARRIVE_DROP || op_opcode_q == MBAR_OP_DROP_EXPECT_TX) begin
                            if (op_arrive_q >= {12'd0, op_object_cur.expected}) op_status = MBAR_STATUS_BAD_ARRIVE;
                            else op_object_next.expected = op_object_cur.expected - op_arrive_q[19:0];
                        end
                        if (op_opcode_q == MBAR_OP_ARRIVE_EXPECT_TX || op_opcode_q == MBAR_OP_DROP_EXPECT_TX) begin
                            op_tx_ext = op_tx_ext + $signed({1'b0, op_tx_bytes_q});
                            if (op_tx_bytes_q > 64'd1048575 || op_tx_ext > 65'sd1048575 || op_tx_ext < -65'sd1048575)
                                op_status = MBAR_STATUS_OVERFLOW;
                            else op_object_next.tx = op_tx_ext[20:0];
                        end
                        if (op_no_complete_q && op_object_next.pending == 0 && op_object_next.tx == 0)
                            op_status = MBAR_STATUS_BAD_ARRIVE;
                    end
                    MBAR_OP_EXPECT_TX, MBAR_OP_COMPLETE_TX, MBAR_OP_TX_COMPLETE: begin
                        op_state_change = 1'b1;
                        op_tx_ext = (op_opcode_q == MBAR_OP_EXPECT_TX) ?
                            op_tx_ext + $signed({1'b0, op_tx_bytes_q}) :
                            op_tx_ext - $signed({1'b0, op_tx_bytes_q});
                        if (op_tx_bytes_q > 64'd1048575 || op_tx_ext > 65'sd1048575 || op_tx_ext < -65'sd1048575)
                            op_status = MBAR_STATUS_OVERFLOW;
                        else op_object_next.tx = op_tx_ext[20:0];
                    end
                    MBAR_OP_FAULT: begin
                        op_state_change = 1'b1;
                        op_status = MBAR_STATUS_MEMORY;
                    end
                    MBAR_OP_REPORT: begin
                        if (!op_object_cur.layout_v1) op_status = MBAR_STATUS_BAD_MODIFIER;
                        else begin
                            op_state_change = 1'b1;
                            // The producer supplies an already encoded b8 report. Reports
                            // accumulate by bitwise OR in this project's producer contract.
                            if (op_phase_cur) op_object_next.report1 = op_object_cur.report1 | op_report_q;
                            else op_object_next.report0 = op_object_cur.report0 | op_report_q;
                        end
                    end
                    MBAR_OP_PENDING_INC: begin
                        op_state_change = 1'b1;
                        if ({12'd0, op_object_cur.pending} == op_count_limit) op_status = MBAR_STATUS_BAD_ARRIVE;
                        else op_object_next.pending = op_object_cur.pending + 20'd1;
                    end
                    MBAR_OP_TRY_WAIT, MBAR_OP_TEST_WAIT: begin
                        if ((op_conditional_q && !op_parity_q) || (!op_parity_q &&
                            (op_input_state_q[63:56] != 8'ha7 || !op_input_state_q[0] ||
                             op_input_state_q[2] != op_object_cur.layout_v1))) begin
                            op_status = MBAR_STATUS_BAD_TOKEN;
                        end else begin
                            op_wait_complete = (bar_wait_phase(op_state_cur, op_conditional_q) != op_phase_token_q) &&
                                !cache_has_pending_write[op_cache_idx];
                            if (!op_wait_complete && op_opcode_q == MBAR_OP_TRY_WAIT) begin
                                op_rsp_needed = 1'b0;
                                op_wait_enqueue = 1'b1;
                            end
                        end
                    end
                    MBAR_OP_CHECK_LAYOUT: op_predicate = op_object_cur.layout_v1 == op_layout_q;
                    default: op_status = MBAR_STATUS_BAD_OPCODE;
                endcase
            end
        end
        if (op_state_change) begin
            if (op_status != MBAR_STATUS_OK) begin
                // Invalid operands have project-defined fault containment, not NV behavior.
                if (op_opcode_q != MBAR_OP_INIT) op_object_next = op_object_cur;
                op_lock_next = 1'b1;
            end
            if (op_opcode_q != MBAR_OP_INIT && op_opcode_q != MBAR_OP_INVAL && !op_lock_next &&
                op_object_next.pending == 0 && op_object_next.tx == 0) begin
                op_phase_flip = 1'b1;
                op_object_next.phase = ~op_phase_cur;
                if (!op_object_next.layout_v1 || (op_phase_cur ? op_object_next.report1 : op_object_next.report0) == 0)
                    op_object_next.conditional_phase = ~op_object_cur.conditional_phase;
                if (op_object_next.phase) op_object_next.report1 = 8'd0;
                else op_object_next.report0 = 8'd0;
                op_object_next.pending = op_object_next.expected;
            end
        end
        op_phase_next = op_object_next.phase;
        op_remaining_next = op_object_next.pending;
        op_tx_balance_next = op_object_next.tx;
        op_state_next = bar_pack(op_object_next);

        if (op_force_error_q) begin
            op_finish = op_is_tx_q ? tx_rsp_slot_for_op : bar_rsp_slot_for_op;
        end else if (!op_vld_q || !op_can_process) begin
            op_finish = 1'b0;
        end else if (op_state_change && (wr_count_q == WR_CNT_W'(WRITE_BUF_DEPTH))) begin
            op_finish = 1'b0;
        end else if (op_state_change) begin
            // State-changing operations retire into the write-through FIFO.
            // Their sole response is generated after backing-memory confirms
            // the write, so a backend error can be reported precisely.
            op_finish = 1'b1;
        end else if (op_wait_enqueue) begin
            op_finish = wait_free_found;
        end else if (op_rsp_needed) begin
            op_finish = op_is_tx_q ? tx_rsp_slot_for_op : bar_rsp_slot_for_op;
        end else begin
            op_finish = 1'b1;
        end
    end

    assign wr_enq = op_vld_q && op_finish && op_state_change;

    // Background waiter wakeup.  Cached barriers with changed phase or lock
    // state are drained one response per cycle.
    always_comb begin
        wake_complete = 1'b0;
        wake_report = 8'd0;
        wake_found = 1'b0;
        wake_idx = {WAIT_IDX_W{1'b0}};
        wake_status = MBAR_STATUS_OK;
        wake_phase = 1'b0;
        wake_locked = 1'b0;
        for (int unsigned wake_wait_idx = 0;
             wake_wait_idx < WAIT_ENTRIES;
             wake_wait_idx = wake_wait_idx + 1) begin
            if (wait_vld_q[wake_wait_idx] && !wake_found) begin
                for (int unsigned wake_cache_idx = 0;
                     wake_cache_idx < CACHE_ENTRIES;
                     wake_cache_idx = wake_cache_idx + 1) begin
                    if (cache_vld_q[wake_cache_idx] &&
                        (cache_addr_q[wake_cache_idx] ==
                         wait_addr_q[wake_wait_idx]) &&
                        (!cache_has_pending_write[wake_cache_idx] ||
                         wait_cycles_q[wake_wait_idx] == 0)) begin
                        if (!cache_state_q[wake_cache_idx][BAR_STATE_VALID_BIT] ||
                            (wait_cycles_q[wake_wait_idx] == 0) ||
                            cache_locked_q[wake_cache_idx] ||
                            (bar_wait_phase(cache_state_q[wake_cache_idx], wait_conditional_q[wake_wait_idx]) !=
                             wait_phase_q[wake_wait_idx])) begin
                            wake_found = 1'b1;
                            wake_complete = cache_state_q[wake_cache_idx][BAR_STATE_VALID_BIT] &&
                                !cache_locked_q[wake_cache_idx] &&
                                !cache_has_pending_write[wake_cache_idx] &&
                                (bar_wait_phase(cache_state_q[wake_cache_idx], wait_conditional_q[wake_wait_idx]) != wait_phase_q[wake_wait_idx]);
                            if (wake_complete && !wait_conditional_q[wake_wait_idx])
                                wake_report = bar_report(cache_state_q[wake_cache_idx], wait_phase_q[wake_wait_idx]);
                            wake_idx = WAIT_IDX_W'(wake_wait_idx);
                            wake_phase =
                                cache_state_q[wake_cache_idx][BAR_STATE_PHASE_BIT];
                            wake_locked =
                                cache_locked_q[wake_cache_idx];
                            wake_status =
                                !cache_state_q[wake_cache_idx][BAR_STATE_VALID_BIT] ? MBAR_STATUS_UNINITIALIZED :
                                (cache_locked_q[wake_cache_idx] ? MBAR_STATUS_LOCKED : MBAR_STATUS_OK);
                        end
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_layout_q <= 1'b0;
            op_no_complete_q <= 1'b0;
            op_conditional_q <= 1'b0;
            op_parity_q <= 1'b0;
            op_input_state_q <= 64'd0;
            op_report_q <= 8'd0;
            bar_rsp_value_q <= 32'd0;
            bar_rsp_predicate_q <= 1'b0;
            bar_rsp_report_q <= 8'd0;
            op_wait_cycles_q <= 32'd0;
            mem_busy_token_q <= 64'd0;
            bar_rsp_state_q <= 64'd0;
            bar_rsp_wait_complete_q <= 1'b0;
            op_vld_q <= 1'b0;
            op_is_tx_q <= 1'b0;
            op_opcode_q <= MBAR_OP_INIT;
            op_tag_q <= 16'd0;
            op_addr_q <= {ADDR_W{1'b0}};
            op_arrive_q <= 32'd0;
            op_tx_bytes_q <= 64'd0;
            op_phase_token_q <= 1'b0;
            arb_next_q <= 2'd0;
            op_force_error_q <= 1'b0;
            cache_replace_q <= {CACHE_IDX_W{1'b0}};
            miss_active_q <= 1'b0;
            miss_sent_q <= 1'b0;
            miss_addr_q <= {ADDR_W{1'b0}};
            miss_slot_q <= {CACHE_IDX_W{1'b0}};
            wr_rd_ptr_q <= {WR_PTR_W{1'b0}};
            wr_wr_ptr_q <= {WR_PTR_W{1'b0}};
            wr_count_q <= {WR_CNT_W{1'b0}};
            mem_req_vld_q <= 1'b0;
            mem_req_write_q <= 1'b0;
            mem_req_addr_q <= {ADDR_W{1'b0}};
            mem_req_data_q <= 256'd0;
            mem_req_mask_q <= 32'd0;
            mem_req_id_q <= {MEM_ID_W{1'b0}};
            mem_busy_q <= 1'b0;
            mem_busy_write_q <= 1'b0;
            mem_busy_addr_q <= {ADDR_W{1'b0}};
            mem_busy_is_tx_q <= 1'b0;
            mem_busy_tag_q <= 16'd0;
            mem_busy_status_q <= MBAR_STATUS_OK;
            mem_busy_phase_q <= 1'b0;
            mem_busy_locked_q <= 1'b0;
            bar_rsp_vld_q <= 1'b0;
            bar_rsp_tag_q <= 16'd0;
            bar_rsp_status_q <= MBAR_STATUS_OK;
            bar_rsp_phase_q <= 1'b0;
            bar_rsp_locked_q <= 1'b0;
            tx_rsp_vld_q <= 1'b0;
            tx_rsp_tag_q <= 16'd0;
            tx_rsp_status_q <= MBAR_STATUS_OK;
            tx_rsp_phase_q <= 1'b0;
            for (int unsigned reset_cache = 0; reset_cache < CACHE_ENTRIES;
                 reset_cache = reset_cache + 1) begin
                cache_locked_q[reset_cache] <= 1'b0;
                cache_vld_q[reset_cache] <= 1'b0;
                cache_addr_q[reset_cache] <= {ADDR_W{1'b0}};
                cache_state_q[reset_cache] <= 64'd0;
            end
            for (int unsigned reset_wait = 0; reset_wait < WAIT_ENTRIES;
                 reset_wait = reset_wait + 1) begin
                wait_conditional_q[reset_wait] <= 1'b0;
                wait_cycles_q[reset_wait] <= 32'd0;
                wait_vld_q[reset_wait] <= 1'b0;
                wait_addr_q[reset_wait] <= {ADDR_W{1'b0}};
                wait_tag_q[reset_wait] <= 16'd0;
                wait_phase_q[reset_wait] <= 1'b0;
            end
            for (int unsigned reset_wr = 0; reset_wr < WRITE_BUF_DEPTH;
                 reset_wr = reset_wr + 1) begin
                wr_vld_q[reset_wr] <= 1'b0;
            end
        end else begin
            for (int wi = 0; wi < WAIT_ENTRIES; wi = wi + 1) begin
                if (wait_vld_q[wi] && (wait_cycles_q[wi] != 0))
                    wait_cycles_q[wi] <= wait_cycles_q[wi] - 32'd1;
            end
            if (bar_rsp_vld_q && bar_rsp_rdy_i) begin
                bar_rsp_vld_q <= 1'b0;
            end
            if (tx_rsp_vld_q && tx_rsp_rdy_i) begin
                tx_rsp_vld_q <= 1'b0;
            end

            if (op_vld_q && !op_force_error_q &&
                (op_opcode_q != MBAR_OP_INIT) && (op_opcode_q != MBAR_OP_PENDING_COUNT) && !op_cache_hit &&
                (op_addr_q[2:0] == 3'd0) && !op_finish &&
                !miss_active_q && op_init_slot_found) begin
                miss_active_q <= 1'b1;
                miss_sent_q <= 1'b0;
                miss_addr_q <= op_addr_q;
                miss_slot_q <= op_init_slot;
            end

            if (op_vld_q && op_finish) begin
                if (op_state_change) begin
                    if (op_cache_hit) begin
                        cache_locked_q[op_cache_idx] <= op_lock_next;
                        cache_state_q[op_cache_idx] <= op_state_next;
                        cache_addr_q[op_cache_idx] <= op_addr_q;
                        cache_vld_q[op_cache_idx] <= 1'b1;
                    end else begin
                        cache_locked_q[op_init_slot] <= op_lock_next;
                        cache_state_q[op_init_slot] <= op_state_next;
                        cache_addr_q[op_init_slot] <= op_addr_q;
                        cache_vld_q[op_init_slot] <= 1'b1;
                        cache_replace_q <= (op_init_slot == CACHE_IDX_W'(CACHE_ENTRIES-1)) ?
                                           {CACHE_IDX_W{1'b0}} :
                                           op_init_slot + CACHE_IDX_W'(1);
                    end
                    wr_addr_q[wr_wr_ptr_q] <= op_addr_q;
                    wr_state_q[wr_wr_ptr_q] <= op_state_next;
                    wr_token_q[wr_wr_ptr_q] <= op_token;
                    wr_vld_q[wr_wr_ptr_q] <= 1'b1;
                    wr_is_tx_q[wr_wr_ptr_q] <= op_is_tx_q;
                    wr_tag_q[wr_wr_ptr_q] <= op_tag_q;
                    wr_status_q[wr_wr_ptr_q] <= op_status;
                    wr_phase_q[wr_wr_ptr_q] <= op_phase_next;
                    wr_locked_q[wr_wr_ptr_q] <= op_lock_next;
                    wr_wr_ptr_q <= (wr_wr_ptr_q == WR_PTR_W'(WRITE_BUF_DEPTH-1)) ?
                                   {WR_PTR_W{1'b0}} : wr_wr_ptr_q + WR_PTR_W'(1);
                end
                if (op_wait_enqueue) begin
                    wait_conditional_q[wait_free_idx] <= op_conditional_q;
                    wait_vld_q[wait_free_idx] <= 1'b1;
                    wait_addr_q[wait_free_idx] <= op_addr_q;
                    wait_tag_q[wait_free_idx] <= op_tag_q;
                    wait_phase_q[wait_free_idx] <= op_phase_token_q;
                    wait_cycles_q[wait_free_idx] <= op_wait_cycles_q;
                end else if (!op_state_change &&
                             (op_rsp_needed || op_force_error_q)) begin
                    if (op_is_tx_q) begin
                        tx_rsp_vld_q <= 1'b1;
                        tx_rsp_tag_q <= op_tag_q;
                        tx_rsp_status_q <= op_status;
                        tx_rsp_phase_q <= op_phase_next;
                    end else begin
                        bar_rsp_vld_q <= 1'b1;
                        bar_rsp_tag_q <= op_tag_q;
                        bar_rsp_status_q <= op_status;
                        bar_rsp_phase_q <= op_phase_next;
                        bar_rsp_state_q <= op_token;
                        bar_rsp_value_q <= op_value;
                        bar_rsp_predicate_q <= op_predicate;
                        bar_rsp_report_q <= (op_wait_complete && !op_conditional_q) ?
                            bar_report(op_state_cur, op_phase_token_q) : 8'd0;
                        bar_rsp_wait_complete_q <= op_wait_complete;
                        bar_rsp_locked_q <= op_lock_next;
                    end
                end
                op_vld_q <= 1'b0;
                op_force_error_q <= 1'b0;
            end

            if (op_accept) begin
                op_layout_q <= !accept_tx && !accept_tc && bar_cmd_layout_i;
                op_no_complete_q <= !accept_tx && !accept_tc && bar_cmd_no_complete_i;
                op_conditional_q <= !accept_tx && !accept_tc && bar_cmd_conditional_i;
                op_parity_q <= bar_cmd_wait_parity_i;
                op_input_state_q <= bar_cmd_state_i;
                op_report_q <= accept_tc ? 8'd0 : bar_cmd_report_i;
                op_vld_q <= 1'b1;
                op_is_tx_q <= accept_tx;
                op_opcode_q <= accept_tx ? MBAR_OP_TX_COMPLETE :
                    (accept_tc ? (tc_cmd_i.opcode == MBAR_OP_FAULT ? MBAR_OP_FAULT : MBAR_OP_ARRIVE) : bar_cmd_opcode_i);
                op_tag_q <= accept_tx ? tx_cpl_tag_i : (accept_tc ? tc_cmd_i.tag : bar_cmd_tag_i);
                op_addr_q <= accept_tx ? tx_cpl_addr_i : (accept_tc ? ADDR_W'(tc_cmd_i.addr) : bar_cmd_addr_i);
                op_arrive_q <= accept_tx ? 32'd0 : accept_tc ? 32'd1 :
                    ((bar_cmd_opcode_i == MBAR_OP_ARRIVE_EXPECT_TX || bar_cmd_opcode_i == MBAR_OP_DROP_EXPECT_TX) ? 32'd1 : bar_cmd_arrive_count_i);
                op_tx_bytes_q <= accept_tx ? tx_cpl_bytes_i : (accept_tc ? 64'd0 : bar_cmd_tx_bytes_i);
                op_phase_token_q <= bar_cmd_wait_parity_i ? bar_cmd_phase_token_i : bar_cmd_state_i[BAR_STATE_PHASE_BIT];
                op_wait_cycles_q <= (bar_cmd_time_hint_i == 0) ? WAIT_DEFAULT_CYCLES :
                    32'(({32'd0, bar_cmd_time_hint_i} + 64'(CLOCK_PERIOD_NS) - 64'd1) / 64'(CLOCK_PERIOD_NS));
                op_force_error_q <= 1'b0;
                arb_next_q <= accept_tc ? 2'd0 : (accept_tx ? 2'd2 : 2'd1);
            end

            // Backing acknowledgements have priority. Ready/expired waiters
            // precede direct software responses, so polls cannot starve them.
            if (wake_found && bar_rsp_slot_rdy &&
                !(mem_rsp_fire && mem_busy_write_q && !mem_busy_is_tx_q) &&
                !(op_vld_q && op_finish && !op_is_tx_q &&
                  !op_state_change && !op_wait_enqueue &&
                  (op_rsp_needed || op_force_error_q))) begin
                bar_rsp_vld_q <= 1'b1;
                bar_rsp_tag_q <= wait_tag_q[wake_idx];
                bar_rsp_status_q <= wake_status;
                bar_rsp_phase_q <= wake_phase;
                bar_rsp_state_q <= 64'd0;
                bar_rsp_value_q <= 32'd0;
                bar_rsp_predicate_q <= 1'b0;
                bar_rsp_report_q <= wake_report;
                bar_rsp_wait_complete_q <= wake_complete;
                bar_rsp_locked_q <= wake_locked;
                wait_vld_q[wake_idx] <= 1'b0;
            end

            if (mem_req_fire) begin
                mem_req_vld_q <= 1'b0;
                mem_busy_q <= 1'b1;
                mem_busy_write_q <= mem_req_write_q;
                mem_busy_addr_q <= mem_req_addr_q;
                if (mem_req_write_q) begin
                    mem_busy_is_tx_q <= wr_is_tx_q[wr_rd_ptr_q];
                    mem_busy_tag_q <= wr_tag_q[wr_rd_ptr_q];
                    mem_busy_status_q <= wr_status_q[wr_rd_ptr_q];
                    mem_busy_phase_q <= wr_phase_q[wr_rd_ptr_q];
                    mem_busy_token_q <= wr_token_q[wr_rd_ptr_q];
                    mem_busy_locked_q <= wr_locked_q[wr_rd_ptr_q];
                    wr_vld_q[wr_rd_ptr_q] <= 1'b0;
                    wr_rd_ptr_q <= (wr_rd_ptr_q == WR_PTR_W'(WRITE_BUF_DEPTH-1)) ?
                                   {WR_PTR_W{1'b0}} : wr_rd_ptr_q + WR_PTR_W'(1);
                end else begin
                    miss_sent_q <= 1'b1;
                end
            end

            if (!mem_req_vld_q && !mem_busy_q) begin
                if (miss_active_q && !miss_sent_q) begin
                    mem_req_vld_q <= 1'b1;
                    mem_req_write_q <= 1'b0;
                    mem_req_addr_q <= miss_addr_q;
                    mem_req_data_q <= 256'd0;
                    mem_req_mask_q <= 32'd0;
                    mem_req_id_q <= MEM_ID_W'(0);
                end else if (wr_count_q != 0) begin
                    mem_req_vld_q <= 1'b1;
                    mem_req_write_q <= 1'b1;
                    mem_req_addr_q <= wr_addr_q[wr_rd_ptr_q];
                    mem_req_data_q <= {192'd0, wr_state_q[wr_rd_ptr_q]} << (wr_addr_q[wr_rd_ptr_q][4:3] * 64);
                    mem_req_mask_q <= 32'h0000_00ff << (wr_addr_q[wr_rd_ptr_q][4:3] * 8);
                    mem_req_id_q <= MEM_ID_W'(1);
                end
            end

            if (mem_rsp_fire) begin
                mem_busy_q <= 1'b0;
                if (!mem_busy_write_q) begin
                    miss_active_q <= 1'b0;
                    miss_sent_q <= 1'b0;
                    if ((mem_rsp_status_i == 2'd0) &&
                        (mem_rsp_id_i == MEM_ID_W'(0))) begin
                        cache_locked_q[miss_slot_q] <= 1'b0;
                        cache_vld_q[miss_slot_q] <= 1'b1;
                        cache_addr_q[miss_slot_q] <= miss_addr_q;
                        cache_state_q[miss_slot_q] <= mem_rsp_data_i[miss_addr_q[4:3]*64 +: 64];
                        cache_replace_q <= (miss_slot_q == CACHE_IDX_W'(CACHE_ENTRIES-1)) ?
                                           {CACHE_IDX_W{1'b0}} :
                                           miss_slot_q + CACHE_IDX_W'(1);
                    end else begin
                        op_force_error_q <= 1'b1;
                    end
                end else if ((mem_rsp_status_i != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) begin
                    for (int unsigned lock_cache = 0;
                         lock_cache < CACHE_ENTRIES;
                         lock_cache = lock_cache + 1) begin
                        if (cache_vld_q[lock_cache] &&
                            (cache_addr_q[lock_cache] == mem_busy_addr_q)) begin
                            cache_locked_q[lock_cache] <= 1'b1;
                        end
                    end
                    // Include an enqueue on the same edge as the failed ack;
                    // wr_vld_q still contains its old value during this scan.
                    if (wr_enq && op_addr_q == mem_busy_addr_q) begin

                        wr_status_q[wr_wr_ptr_q] <= MBAR_STATUS_LOCKED;
                        wr_locked_q[wr_wr_ptr_q] <= 1'b1;
                    end
                    for (int unsigned poison_wr = 0;
                         poison_wr < WRITE_BUF_DEPTH;
                         poison_wr = poison_wr + 1) begin
                        if (wr_vld_q[poison_wr] &&
                            (wr_addr_q[poison_wr] == mem_busy_addr_q)) begin

                            wr_status_q[poison_wr] <= MBAR_STATUS_LOCKED;
                            wr_locked_q[poison_wr] <= 1'b1;
                        end
                    end
                end
                if (mem_busy_write_q) begin
                    if (mem_busy_is_tx_q) begin
                        tx_rsp_vld_q <= 1'b1;
                        tx_rsp_tag_q <= mem_busy_tag_q;
                        tx_rsp_status_q <=
                            ((mem_rsp_status_i != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) ?
                            MBAR_STATUS_MEMORY : mem_busy_status_q;
                        tx_rsp_phase_q <= mem_busy_phase_q;
                    end else begin
                        bar_rsp_vld_q <= 1'b1;
                        bar_rsp_tag_q <= mem_busy_tag_q;
                        bar_rsp_status_q <=
                            ((mem_rsp_status_i != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) ?
                            MBAR_STATUS_MEMORY : mem_busy_status_q;
                        bar_rsp_phase_q <= mem_busy_phase_q;
                        bar_rsp_state_q <= mem_busy_token_q;
                        bar_rsp_value_q <= 32'd0;
                        bar_rsp_predicate_q <= 1'b0;
                        bar_rsp_report_q <= 8'd0;
                        bar_rsp_wait_complete_q <= 1'b0;
                        bar_rsp_locked_q <=
                            ((mem_rsp_status_i != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) ?
                            1'b1 : mem_busy_locked_q;
                    end
                end
            end

            case ({wr_enq, wr_pop})
                2'b10: wr_count_q <= wr_count_q + WR_CNT_W'(1);
                2'b01: wr_count_q <= wr_count_q - WR_CNT_W'(1);
                default: wr_count_q <= wr_count_q;
            endcase
        end
    end

    initial begin
        if (CLOCK_PERIOD_NS == 0 || WAIT_DEFAULT_CYCLES == 0) $error("wait timing parameters must be positive");
        if (ADDR_W < 32) $error("ADDR_W must be at least 32");
        if (CACHE_ENTRIES < 1) $error("CACHE_ENTRIES must be positive");
        if (WAIT_ENTRIES < 1) $error("WAIT_ENTRIES must be positive");
        if (WRITE_BUF_DEPTH < 2) $error("WRITE_BUF_DEPTH must be at least two");
        if (MEM_ID_W < 1) $error("MEM_ID_W must be positive");
    end

`ifndef SYNTHESIS
    logic                    assert_mem_stalled_q;
    logic                    assert_mem_write_q;
    logic [ADDR_W-1:0]       assert_mem_addr_q;
    logic [255:0]            assert_mem_data_q;
    logic [31:0]             assert_mem_mask_q;
    logic [MEM_ID_W-1:0]     assert_mem_id_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assert_mem_stalled_q <= 1'b0;
        end else begin
            if (assert_mem_stalled_q) begin
                assert (mem_req_vld_o &&
                        (mem_req_write_o == assert_mem_write_q) &&
                        (mem_req_addr_o == assert_mem_addr_q) &&
                        (mem_req_data_o == assert_mem_data_q) &&
                        (mem_req_mask_o == assert_mem_mask_q) &&
                        (mem_req_id_o == assert_mem_id_q))
                    else $error("mbarrier memory request changed while stalled");
            end
            if (op_vld_q && op_finish && op_state_change &&
                (op_phase_next != op_phase_cur) &&
                (op_opcode_q != MBAR_OP_INIT) && (op_opcode_q != MBAR_OP_INVAL)) begin
                assert (op_phase_flip &&
                        (op_tx_balance_next == 21'sd0) && !op_lock_next)
                    else $error("mbarrier phase changed before joint completion");
            end
            if (op_vld_q && op_finish && op_cache_hit && op_lock_cur &&
                (op_opcode_q != MBAR_OP_INIT) && (op_opcode_q != MBAR_OP_INVAL)) begin
                assert (!op_state_change)
                    else $error("locked mbarrier changed without INVAL");
            end
            assert (wr_count_q <= WR_CNT_W'(WRITE_BUF_DEPTH))
                else $error("mbarrier write buffer count overflow");

            assert_mem_stalled_q <= mem_req_vld_o && !mem_req_rdy_i;
            assert_mem_write_q <= mem_req_write_o;
            assert_mem_addr_q <= mem_req_addr_o;
            assert_mem_data_q <= mem_req_data_o;
            assert_mem_mask_q <= mem_req_mask_o;
            assert_mem_id_q <= mem_req_id_o;
        end
    end
`endif

endmodule

`default_nettype wire
