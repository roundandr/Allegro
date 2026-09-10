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
    parameter int unsigned MEM_ID_W        = 2
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    bar_cmd_vld_i,
    output wire                    bar_cmd_rdy_o,
    input  wire [2:0]              bar_cmd_opcode_i,
    input  wire [15:0]             bar_cmd_tag_i,
    input  wire [ADDR_W-1:0]       bar_cmd_addr_i,
    input  wire [15:0]             bar_cmd_arrive_count_i,
    input  wire [63:0]             bar_cmd_tx_bytes_i,
    input  wire                    bar_cmd_phase_token_i,

    output wire                    bar_rsp_vld_o,
    input  wire                    bar_rsp_rdy_i,
    output wire [15:0]             bar_rsp_tag_o,
    output wire [7:0]              bar_rsp_status_o,
    output wire                    bar_rsp_phase_o,
    output wire                    bar_rsp_locked_o,

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
    localparam logic [2:0] MBAR_OP_TX_COMPLETE = 3'd7;

    logic                    cache_vld_q [0:CACHE_ENTRIES-1];
    logic [ADDR_W-1:0]       cache_addr_q [0:CACHE_ENTRIES-1];
    logic [255:0]            cache_state_q [0:CACHE_ENTRIES-1];
    logic [CACHE_IDX_W-1:0]  cache_replace_q;

    logic                    wait_vld_q [0:WAIT_ENTRIES-1];
    logic [ADDR_W-1:0]       wait_addr_q [0:WAIT_ENTRIES-1];
    logic [15:0]             wait_tag_q [0:WAIT_ENTRIES-1];
    logic                    wait_phase_q [0:WAIT_ENTRIES-1];

    logic [ADDR_W-1:0]       wr_addr_q [0:WRITE_BUF_DEPTH-1];
    logic [255:0]            wr_state_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_vld_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_is_tx_q [0:WRITE_BUF_DEPTH-1];
    logic [15:0]             wr_tag_q [0:WRITE_BUF_DEPTH-1];
    logic [7:0]              wr_status_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_phase_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_locked_q [0:WRITE_BUF_DEPTH-1];
    logic [WR_PTR_W-1:0]     wr_rd_ptr_q;
    logic [WR_PTR_W-1:0]     wr_wr_ptr_q;
    logic [WR_CNT_W-1:0]     wr_count_q;

    logic                    op_vld_q;
    logic                    op_is_tx_q;
    logic [2:0]              op_opcode_q;
    logic [15:0]             op_tag_q;
    logic [ADDR_W-1:0]       op_addr_q;
    logic [15:0]             op_arrive_q;
    logic [63:0]             op_tx_bytes_q;
    logic                    op_phase_token_q;
    logic                    arb_tx_turn_q;
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
    logic [255:0]            op_state_cur;
    logic [255:0]            op_state_next;
    logic                    op_state_change;
    logic                    op_phase_flip;
    logic                    op_phase_cur;
    logic                    op_lock_cur;
    logic [15:0]             op_expected_cur;
    logic [15:0]             op_remaining_cur;
    logic signed [63:0]      op_tx_balance_cur;
    logic                    op_phase_next;
    logic                    op_lock_next;
    logic [15:0]             op_remaining_next;
    logic signed [63:0]      op_tx_balance_next;
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
          !mem_busy_is_tx_q);
    assign tx_rsp_slot_for_op = tx_rsp_slot_rdy &&
        !(mem_rsp_vld_i && mem_busy_q && mem_busy_write_q &&
          mem_busy_is_tx_q);

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
    assign mem_req_addr_o = mem_req_addr_q;
    assign mem_req_data_o = mem_req_data_q;
    assign mem_req_mask_o = mem_req_mask_q;
    assign mem_req_id_o = mem_req_id_q;
    assign mem_rsp_rdy_o = mem_busy_q &&
        (!mem_busy_write_q ||
         (mem_busy_is_tx_q ? tx_rsp_slot_rdy : bar_rsp_slot_rdy));
    assign mem_req_fire = mem_req_vld_q && mem_req_rdy_i;
    assign mem_rsp_fire = mem_rsp_vld_i && mem_rsp_rdy_o;
    assign wr_pop = mem_req_fire && mem_req_write_q;

    // A completed operation may be replaced in the skid register on the same
    // edge.  Transaction completions alternate with software traffic when
    // both sources remain asserted.
    assign incoming_wait_blocked = bar_cmd_vld_i &&
        (bar_cmd_opcode_i == MBAR_OP_TRY_WAIT) &&
        (!wait_free_found ||
         (op_vld_q && op_finish && op_wait_enqueue &&
          !wait_second_free_found));
    assign accept_tx = tx_cpl_vld_i &&
                       (!bar_cmd_vld_i || incoming_wait_blocked ||
                        arb_tx_turn_q);
    assign op_accept = (!op_vld_q || op_finish) &&
                       ((bar_cmd_vld_i && !incoming_wait_blocked) ||
                        tx_cpl_vld_i);
    assign tx_cpl_rdy_o = (!op_vld_q || op_finish) && accept_tx;
    assign bar_cmd_rdy_o = (!op_vld_q || op_finish) &&
                           bar_cmd_vld_i && !incoming_wait_blocked &&
                           !accept_tx;

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
        victim_has_wait = cache_has_wait[cache_replace_q];
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
                if (!cache_has_wait[victim_idx] && !op_init_slot_found) begin
                    op_init_slot_found = 1'b1;
                    op_init_slot = CACHE_IDX_W'(victim_idx);
                end
            end
        end
    end

    always_comb begin
        op_state_cur = op_cache_hit ? cache_state_q[op_cache_idx] : 256'd0;
        op_phase_cur = op_state_cur[BAR_STATE_PHASE_BIT];
        op_lock_cur = op_state_cur[BAR_STATE_LOCK_BIT];
        op_expected_cur = op_state_cur[BAR_STATE_EXPECTED_LSB +: 16];
        op_remaining_cur = op_state_cur[BAR_STATE_REMAINING_LSB +: 16];
        op_tx_balance_cur = $signed(op_state_cur[BAR_STATE_TX_BAL_LSB +: 64]);

        op_state_next = op_state_cur;
        op_state_change = 1'b0;
        op_phase_flip = 1'b0;
        op_phase_next = op_phase_cur;
        op_lock_next = op_lock_cur;
        op_remaining_next = op_remaining_cur;
        op_tx_balance_next = op_tx_balance_cur;
        op_tx_ext = {op_tx_balance_cur[63], op_tx_balance_cur};
        op_status = MBAR_STATUS_OK;
        // Every accepted software command and every accepted TMA completion
        // produces exactly one response.  TRY_WAIT is the sole exception: it
        // defers that response while resident in the wait CAM.
        op_rsp_needed = 1'b1;
        op_wait_enqueue = 1'b0;
        op_can_process = 1'b0;

        if (op_addr_q[4:0] != 5'd0) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_BAD_ALIGN;
        end else if (op_force_error_q) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_MEMORY;
        end else if (op_opcode_q == MBAR_OP_INIT) begin
            op_can_process = op_cache_hit || op_init_slot_found;
            op_state_next = 256'd0;
            op_state_next[BAR_STATE_VALID_BIT] = 1'b1;
            op_state_next[BAR_STATE_PHASE_BIT] = 1'b0;
            op_state_next[BAR_STATE_LOCK_BIT] = 1'b0;
            op_state_next[BAR_STATE_EXPECTED_LSB +: 16] = op_arrive_q;
            op_state_next[BAR_STATE_REMAINING_LSB +: 16] = op_arrive_q;
            op_state_next[BAR_STATE_TX_BAL_LSB +: 64] = 64'd0;
            op_state_change = op_can_process;
            op_phase_next = 1'b0;
            op_lock_next = 1'b0;
            op_remaining_next = op_arrive_q;
            op_tx_balance_next = 64'sd0;
            if (op_arrive_q == 16'd0) begin
                op_status = MBAR_STATUS_BAD_ARRIVE;
                op_state_next[BAR_STATE_LOCK_BIT] = 1'b1;
                op_lock_next = 1'b1;
            end
        end else if (op_cache_hit) begin
            op_can_process = 1'b1;
            if (!op_state_cur[BAR_STATE_VALID_BIT]) begin
                op_status = MBAR_STATUS_UNINITIALIZED;
            end else if (op_lock_cur) begin
                op_status = MBAR_STATUS_LOCKED;
            end else begin
                case (op_opcode_q)
                    MBAR_OP_ARRIVE,
                    MBAR_OP_ARRIVE_EXPECT_TX: begin
                        if (op_phase_token_q != op_phase_cur) begin
                            op_status = MBAR_STATUS_BAD_PHASE;
                            op_lock_next = 1'b1;
                            op_state_change = 1'b1;
                        end else if ((op_arrive_q == 16'd0) ||
                            (op_arrive_q > op_remaining_cur)) begin
                            op_status = MBAR_STATUS_BAD_ARRIVE;
                            op_lock_next = 1'b1;
                            op_state_change = 1'b1;
                        end else begin
                            op_remaining_next = op_remaining_cur - op_arrive_q;
                            op_state_change = 1'b1;
                        end
                        if ((op_opcode_q == MBAR_OP_ARRIVE_EXPECT_TX) &&
                            (op_status == MBAR_STATUS_OK)) begin
                            op_tx_ext = {op_tx_balance_cur[63], op_tx_balance_cur} -
                                        $signed({1'b0, op_tx_bytes_q});
                            if (op_tx_ext[64] != op_tx_ext[63]) begin
                                op_status = MBAR_STATUS_OVERFLOW;
                                op_lock_next = 1'b1;
                            end else begin
                                op_tx_balance_next = op_tx_ext[63:0];
                            end
                        end
                    end

                    MBAR_OP_EXPECT_TX: begin
                        op_tx_ext = {op_tx_balance_cur[63], op_tx_balance_cur} -
                                    $signed({1'b0, op_tx_bytes_q});
                        op_state_change = 1'b1;
                        if (op_tx_ext[64] != op_tx_ext[63]) begin
                            op_status = MBAR_STATUS_OVERFLOW;
                            op_lock_next = 1'b1;
                        end else begin
                            op_tx_balance_next = op_tx_ext[63:0];
                        end
                    end

                    MBAR_OP_TX_COMPLETE: begin
                        op_tx_ext = {op_tx_balance_cur[63], op_tx_balance_cur} +
                                    $signed({1'b0, op_tx_bytes_q});
                        op_state_change = 1'b1;
                        op_rsp_needed = 1'b1;
                        if (op_tx_ext[64] != op_tx_ext[63]) begin
                            op_status = MBAR_STATUS_OVERFLOW;
                            op_lock_next = 1'b1;
                        end else begin
                            op_tx_balance_next = op_tx_ext[63:0];
                        end
                    end

                    MBAR_OP_TRY_WAIT: begin
                        if (op_phase_cur == op_phase_token_q) begin
                            op_rsp_needed = 1'b0;
                            op_wait_enqueue = 1'b1;
                        end
                    end

                    default: begin
                        op_status = MBAR_STATUS_BAD_OPCODE;
                    end
                endcase
            end
        end

        if (op_state_change) begin
            if ((op_opcode_q != MBAR_OP_INIT) && !op_lock_next &&
                (op_remaining_next == 16'd0) &&
                (op_tx_balance_next == 64'sd0)) begin
                op_phase_flip = 1'b1;
                op_phase_next = ~op_phase_cur;
                op_remaining_next = op_expected_cur;
            end
            op_state_next[BAR_STATE_VALID_BIT] = 1'b1;
            op_state_next[BAR_STATE_PHASE_BIT] = op_phase_next;
            op_state_next[BAR_STATE_LOCK_BIT] = op_lock_next;
            op_state_next[BAR_STATE_REMAINING_LSB +: 16] = op_remaining_next;
            op_state_next[BAR_STATE_TX_BAL_LSB +: 64] = op_tx_balance_next;
        end

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
                        !cache_has_pending_write[wake_cache_idx]) begin
                        if (cache_state_q[wake_cache_idx][BAR_STATE_LOCK_BIT] ||
                            (cache_state_q[wake_cache_idx][BAR_STATE_PHASE_BIT] !=
                             wait_phase_q[wake_wait_idx])) begin
                            wake_found = 1'b1;
                            wake_idx = WAIT_IDX_W'(wake_wait_idx);
                            wake_phase =
                                cache_state_q[wake_cache_idx][BAR_STATE_PHASE_BIT];
                            wake_locked =
                                cache_state_q[wake_cache_idx][BAR_STATE_LOCK_BIT];
                            wake_status =
                                cache_state_q[wake_cache_idx][BAR_STATE_LOCK_BIT] ?
                                          MBAR_STATUS_LOCKED : MBAR_STATUS_OK;
                        end
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_vld_q <= 1'b0;
            op_is_tx_q <= 1'b0;
            op_opcode_q <= MBAR_OP_INIT;
            op_tag_q <= 16'd0;
            op_addr_q <= {ADDR_W{1'b0}};
            op_arrive_q <= 16'd0;
            op_tx_bytes_q <= 64'd0;
            op_phase_token_q <= 1'b0;
            arb_tx_turn_q <= 1'b0;
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
                cache_vld_q[reset_cache] <= 1'b0;
                cache_addr_q[reset_cache] <= {ADDR_W{1'b0}};
                cache_state_q[reset_cache] <= 256'd0;
            end
            for (int unsigned reset_wait = 0; reset_wait < WAIT_ENTRIES;
                 reset_wait = reset_wait + 1) begin
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
            if (bar_rsp_vld_q && bar_rsp_rdy_i) begin
                bar_rsp_vld_q <= 1'b0;
            end
            if (tx_rsp_vld_q && tx_rsp_rdy_i) begin
                tx_rsp_vld_q <= 1'b0;
            end

            if (op_vld_q && !op_force_error_q &&
                (op_opcode_q != MBAR_OP_INIT) && !op_cache_hit &&
                !miss_active_q && op_init_slot_found) begin
                miss_active_q <= 1'b1;
                miss_sent_q <= 1'b0;
                miss_addr_q <= op_addr_q;
                miss_slot_q <= op_init_slot;
            end

            if (op_vld_q && op_finish) begin
                if (op_state_change) begin
                    if (op_cache_hit) begin
                        cache_state_q[op_cache_idx] <= op_state_next;
                        cache_addr_q[op_cache_idx] <= op_addr_q;
                        cache_vld_q[op_cache_idx] <= 1'b1;
                    end else begin
                        cache_state_q[op_init_slot] <= op_state_next;
                        cache_addr_q[op_init_slot] <= op_addr_q;
                        cache_vld_q[op_init_slot] <= 1'b1;
                        cache_replace_q <= (op_init_slot == CACHE_IDX_W'(CACHE_ENTRIES-1)) ?
                                           {CACHE_IDX_W{1'b0}} :
                                           op_init_slot + CACHE_IDX_W'(1);
                    end
                    wr_addr_q[wr_wr_ptr_q] <= op_addr_q;
                    wr_state_q[wr_wr_ptr_q] <= op_state_next;
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
                    wait_vld_q[wait_free_idx] <= 1'b1;
                    wait_addr_q[wait_free_idx] <= op_addr_q;
                    wait_tag_q[wait_free_idx] <= op_tag_q;
                    wait_phase_q[wait_free_idx] <= op_phase_token_q;
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
                        bar_rsp_locked_q <= op_lock_next;
                    end
                end
                op_vld_q <= 1'b0;
                op_force_error_q <= 1'b0;
            end

            if (op_accept) begin
                op_vld_q <= 1'b1;
                op_is_tx_q <= accept_tx;
                op_opcode_q <= accept_tx ? MBAR_OP_TX_COMPLETE : bar_cmd_opcode_i;
                op_tag_q <= accept_tx ? tx_cpl_tag_i : bar_cmd_tag_i;
                op_addr_q <= accept_tx ? tx_cpl_addr_i : bar_cmd_addr_i;
                op_arrive_q <= accept_tx ? 16'd0 : bar_cmd_arrive_count_i;
                op_tx_bytes_q <= accept_tx ? tx_cpl_bytes_i : bar_cmd_tx_bytes_i;
                op_phase_token_q <= accept_tx ? 1'b0 : bar_cmd_phase_token_i;
                op_force_error_q <= 1'b0;
                if (bar_cmd_vld_i && tx_cpl_vld_i) begin
                    arb_tx_turn_q <= ~arb_tx_turn_q;
                end
            end

            // Wake traffic is lower priority than a response generated by the
            // serialized datapath on this edge.
            if (wake_found && bar_rsp_slot_rdy &&
                !(mem_rsp_fire && mem_busy_write_q && !mem_busy_is_tx_q) &&
                !(op_vld_q && op_finish && !op_is_tx_q &&
                  (op_rsp_needed || op_force_error_q))) begin
                bar_rsp_vld_q <= 1'b1;
                bar_rsp_tag_q <= wait_tag_q[wake_idx];
                bar_rsp_status_q <= wake_status;
                bar_rsp_phase_q <= wake_phase;
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
                    mem_req_data_q <= wr_state_q[wr_rd_ptr_q];
                    mem_req_mask_q <= 32'hffff_ffff;
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
                        cache_vld_q[miss_slot_q] <= 1'b1;
                        cache_addr_q[miss_slot_q] <= miss_addr_q;
                        cache_state_q[miss_slot_q] <= mem_rsp_data_i;
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
                            cache_state_q[lock_cache][BAR_STATE_LOCK_BIT] <= 1'b1;
                        end
                    end
                    for (int unsigned poison_wr = 0;
                         poison_wr < WRITE_BUF_DEPTH;
                         poison_wr = poison_wr + 1) begin
                        if (wr_vld_q[poison_wr] &&
                            (wr_addr_q[poison_wr] == mem_busy_addr_q)) begin
                            wr_state_q[poison_wr][BAR_STATE_LOCK_BIT] <= 1'b1;
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
                (op_phase_next != op_phase_cur)) begin
                assert (op_phase_flip &&
                        (op_tx_balance_next == 64'sd0) && !op_lock_next)
                    else $error("mbarrier phase changed before joint completion");
            end
            if (op_vld_q && op_finish && op_cache_hit && op_lock_cur &&
                (op_opcode_q != MBAR_OP_INIT)) begin
                assert (!op_state_change)
                    else $error("locked mbarrier changed without INIT");
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
