// ============================================================================
// File Name   : mbarrier_frontend.sv
// Date        : 2026-09-11
// Description : Typed command, ordering and ordinary cp.async tracking frontend.
//
// One clock, active-low asynchronous reset. Commands use a bounded transaction
// table and internal slot tags. Release is acknowledged before core issue;
// successful acquire waits are acknowledged before the response is exposed.
// Ordinary cp.async registration precedes instruction issue in the frontend.
// Registration sequence numbers must increase per issuer and cannot wrap in
// a live context. Completion may be out of order. Source failures poison that
// issuer until context reset; they are never converted to NVIDIA payload reports.
// ============================================================================
`default_nettype none
module mbarrier_frontend #(
    parameter int unsigned ADDR_W = 64,
    parameter int unsigned CACHE_ENTRIES = 4,
    parameter int unsigned WAIT_ENTRIES = 32,
    parameter int unsigned WRITE_BUF_DEPTH = 8,
    parameter int unsigned MEM_ID_W = 2,
    parameter int unsigned CLOCK_PERIOD_NS = 10,
    parameter int unsigned WAIT_DEFAULT_CYCLES = 64,
    parameter int unsigned ASYNC_ENTRIES = 16,
    parameter int unsigned COMMAND_ENTRIES = WAIT_ENTRIES + WRITE_BUF_DEPTH + 4
) (
    input wire clk,
    input wire rst_n,
    input wire bar_cmd_vld_i,
    output wire bar_cmd_rdy_o,
    input wire tc_arrive_vld_i,
    output wire tc_arrive_rdy_o,
    input tma_mbarrier_pkg::bar_cmd_t tc_arrive_i,
    output wire tc_arrive_rsp_vld_o,
    input wire tc_arrive_rsp_rdy_i,
    output tma_mbarrier_pkg::bar_rsp_t tc_arrive_rsp_o,
    input tma_mbarrier_pkg::bar_cmd_t bar_cmd_i,
    output wire bar_rsp_vld_o,
    input wire bar_rsp_rdy_i,
    output tma_mbarrier_pkg::bar_rsp_t bar_rsp_o,
    input wire async_req_vld_i,
    output wire async_req_rdy_o,
    input tma_mbarrier_pkg::bw_async_req_t async_req_i,
    input wire async_cpl_req_vld_i,
    output wire async_cpl_req_rdy_o,
    input tma_mbarrier_pkg::bw_async_req_t async_cpl_req_i,
    output wire async_rsp_vld_o,
    input wire async_rsp_rdy_i,
    output tma_mbarrier_pkg::bw_async_rsp_t async_rsp_o,
    input wire report_req_vld_i,
    output wire report_req_rdy_o,
    input tma_mbarrier_pkg::bar_report_req_t report_req_i,
    output wire report_rsp_vld_o,
    input wire report_rsp_rdy_i,
    output tma_mbarrier_pkg::bar_rsp_t report_rsp_o,
    output wire order_req_vld_o,
    input wire order_req_rdy_i,
    output tma_mbarrier_pkg::bw_order_req_t order_req_o,
    input wire order_rsp_vld_i,
    output wire order_rsp_rdy_o,
    input tma_mbarrier_pkg::bw_order_rsp_t order_rsp_i,
    input wire tx_cpl_vld_i,
    output wire tx_cpl_rdy_o,
    input wire [15:0] tx_cpl_tag_i,
    input wire [ADDR_W-1:0] tx_cpl_addr_i,
    input wire [63:0] tx_cpl_bytes_i,
    output wire tx_rsp_vld_o,
    input wire tx_rsp_rdy_i,
    output wire [15:0] tx_rsp_tag_o,
    output wire [7:0] tx_rsp_status_o,
    output wire tx_rsp_phase_o,
    output wire mem_req_vld_o,
    input wire mem_req_rdy_i,
    output wire mem_req_write_o,
    output wire [ADDR_W-1:0] mem_req_addr_o,
    output wire [255:0] mem_req_data_o,
    output wire [31:0] mem_req_mask_o,
    output wire [MEM_ID_W-1:0] mem_req_id_o,
    input wire mem_rsp_vld_i,
    output wire mem_rsp_rdy_o,
    input wire [255:0] mem_rsp_data_i,
    input wire [1:0] mem_rsp_status_i,
    input wire [MEM_ID_W-1:0] mem_rsp_id_i
);
    import tma_mbarrier_pkg::*;
    // A full registration table cannot block the completion path that frees it.
    wire selected_async_req_vld_i = async_req_vld_i || async_cpl_req_vld_i;
    wire selected_async_req_rdy_o;
    bw_async_req_t selected_async_req_i;
    always_comb begin
        selected_async_req_i = async_cpl_req_vld_i ? async_cpl_req_i : async_req_i;
        selected_async_req_i.complete = async_cpl_req_vld_i;
    end
    assign async_req_rdy_o = selected_async_req_rdy_o && !async_cpl_req_vld_i;
    assign async_cpl_req_rdy_o = selected_async_req_rdy_o;
    localparam int unsigned IDX_W = (COMMAND_ENTRIES <= 1) ? 1 : $clog2(COMMAND_ENTRIES);
    localparam int unsigned ASYNC_IDX_W = (ASYNC_ENTRIES <= 1) ? 1 : $clog2(ASYNC_ENTRIES);
    typedef enum logic [3:0] {E_FREE, E_RELEASE, E_ORDER, E_ISSUE, E_CORE,
        E_ACQUIRE, E_READY, E_CP_WAIT, E_CP_ISSUE, E_CP_CORE, E_CP_READY} entry_state_t;
    entry_state_t state_q [0:COMMAND_ENTRIES-1];
    bar_cmd_t cmd_q [0:COMMAND_ENTRIES-1];
    bar_rsp_t result_q [0:COMMAND_ENTRIES-1];
    logic report_source_q [0:COMMAND_ENTRIES-1];
    logic cp_ack_q [0:COMMAND_ENTRIES-1];
    logic [63:0] acceptance_q;
    logic [63:0] age_q [0:COMMAND_ENTRIES-1];
    logic issue_blocked [0:COMMAND_ENTRIES-1];
    logic cp_pending [0:COMMAND_ENTRIES-1];
    logic [1023:0] issuer_failed_q;
    logic async_vld_q [0:ASYNC_ENTRIES-1];
    logic [9:0] async_issuer_q [0:ASYNC_ENTRIES-1];
    logic [63:0] async_seq_q [0:ASYNC_ENTRIES-1];
    logic [1023:0] issuer_seen_q;
    logic [1023:0][63:0] issuer_last_seq_q;
    logic free_found, issue_found, order_found, response_found, async_free, async_match;
    logic [IDX_W-1:0] free_idx, issue_idx, order_idx, response_idx;
    logic [ASYNC_IDX_W-1:0] async_free_idx, async_match_idx;
    logic [IDX_W-1:0] issue_rr_q, response_rr_q, order_rr_q;
    logic [7:0] input_status;
    logic input_release;
    logic core_cmd_vld_q, core_cmd_rdy;
    logic [IDX_W-1:0] core_slot_q;
    bar_cmd_t core_cmd_q;
    logic core_rsp_vld;
    bar_rsp_t core_rsp;
    logic [15:0] core_rsp_tag;
    logic order_vld_q, order_busy_q, order_acquire_q;
    logic [IDX_W-1:0] order_slot_q;
    bw_order_req_t order_q;
    logic rsp_vld_q, rsp_report_q;
    bar_rsp_t rsp_q;
    logic async_rsp_vld_q;
    bw_async_rsp_t async_rsp_q;
    integer scan;

    assign bar_cmd_rdy_o = free_found;
    assign report_req_rdy_o = free_found && !bar_cmd_vld_i;
    assign bar_rsp_vld_o = rsp_vld_q && !rsp_report_q;
    assign report_rsp_vld_o = rsp_vld_q && rsp_report_q;
    assign bar_rsp_o = rsp_q;
    assign report_rsp_o = rsp_q;
    assign order_req_vld_o = order_vld_q;
    assign order_req_o = order_q;
    assign order_rsp_rdy_o = order_busy_q;
    assign async_rsp_vld_o = async_rsp_vld_q;
    assign async_rsp_o = async_rsp_q;
    assign selected_async_req_rdy_o = (!async_rsp_vld_q || async_rsp_rdy_i) &&
        (selected_async_req_i.complete || async_free ||
         (issuer_seen_q[selected_async_req_i.issuer] && selected_async_req_i.seq <= issuer_last_seq_q[selected_async_req_i.issuer]));

    always_comb begin
        async_free = 1'b0; async_match = 1'b0;
        async_free_idx = '0; async_match_idx = '0;
        for (int i = 0; i < ASYNC_ENTRIES; i = i + 1) begin
            if (!async_vld_q[i] && !async_free) begin
                async_free = 1'b1; async_free_idx = ASYNC_IDX_W'(i);
            end
            if (async_vld_q[i] && async_issuer_q[i] == selected_async_req_i.issuer && async_seq_q[i] == selected_async_req_i.seq) begin
                async_match = 1'b1; async_match_idx = ASYNC_IDX_W'(i);
            end
        end
        for (int i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
            cp_pending[i] = 1'b0;
            issue_blocked[i] = 1'b0;
            for (int k = 0; k < COMMAND_ENTRIES; k = k + 1) begin
                if (age_q[k] < age_q[i] && cmd_q[k].issuer == cmd_q[i].issuer && !report_source_q[k] && !report_source_q[i] &&
                    (state_q[k] == E_RELEASE || state_q[k] == E_ISSUE ||
                     (state_q[k] == E_ORDER && !(order_busy_q && order_acquire_q && order_slot_q == IDX_W'(k)))))
                    issue_blocked[i] = 1'b1;
            end
            for (int j = 0; j < ASYNC_ENTRIES; j = j + 1) begin
                if (async_vld_q[j] && async_issuer_q[j] == cmd_q[i].issuer && async_seq_q[j] < cmd_q[i].seq)
                    cp_pending[i] = 1'b1;
            end
        end
    end

    always_comb begin
        input_status = MBAR_STATUS_OK;
        input_release = 1'b0;
        if (bar_cmd_i.opcode > MBAR_OP_CP_ASYNC_ARRIVE) input_status = MBAR_STATUS_BAD_OPCODE;
        if (bar_cmd_i.scope > BW_SCOPE_CLUSTER) input_status = MBAR_STATUS_BAD_MODIFIER;
        case (bar_cmd_i.opcode)
            MBAR_OP_ARRIVE, MBAR_OP_ARRIVE_EXPECT_TX, MBAR_OP_ARRIVE_DROP, MBAR_OP_DROP_EXPECT_TX: begin
                if (bar_cmd_i.sem > BW_SEM_RELEASE || (bar_cmd_i.no_complete &&
                    (bar_cmd_i.sem != BW_SEM_RELEASE || bar_cmd_i.scope != BW_SCOPE_CTA)))
                    input_status = MBAR_STATUS_BAD_MODIFIER;
                input_release = bar_cmd_i.sem == BW_SEM_RELEASE;
            end
            MBAR_OP_TRY_WAIT, MBAR_OP_TEST_WAIT: begin
                if (bar_cmd_i.sem != BW_SEM_RELAXED && bar_cmd_i.sem != BW_SEM_ACQUIRE)
                    input_status = MBAR_STATUS_BAD_MODIFIER;
            end
            default: if (bar_cmd_i.sem != BW_SEM_RELAXED) input_status = MBAR_STATUS_BAD_MODIFIER;
        endcase
        if (bar_cmd_i.no_complete && bar_cmd_i.opcode != MBAR_OP_ARRIVE && bar_cmd_i.opcode != MBAR_OP_ARRIVE_DROP)
            input_status = MBAR_STATUS_BAD_MODIFIER;
        free_found = 1'b0; free_idx = '0;
        issue_found = 1'b0; issue_idx = '0;
        order_found = 1'b0; order_idx = '0;
        response_found = 1'b0; response_idx = '0;
        scan = 0;
        for (int i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
            if (state_q[i] == E_FREE && !free_found) begin free_found = 1'b1; free_idx = IDX_W'(i); end
            scan = (int'(issue_rr_q) + i) % COMMAND_ENTRIES;
            if (!issue_found && !issue_blocked[scan] && (state_q[scan] == E_ISSUE || state_q[scan] == E_CP_ISSUE)) begin
                issue_found = 1'b1; issue_idx = IDX_W'(scan);
            end
            scan = (int'(order_rr_q) + i) % COMMAND_ENTRIES;
            if (!order_found && (state_q[scan] == E_RELEASE || state_q[scan] == E_ACQUIRE)) begin
                order_found = 1'b1; order_idx = IDX_W'(scan);
            end
            scan = (int'(response_rr_q) + i) % COMMAND_ENTRIES;
            if (!response_found && (state_q[scan] == E_READY ||
                ((state_q[scan] == E_CP_WAIT || state_q[scan] == E_CP_READY) && !cp_ack_q[scan]))) begin
                response_found = 1'b1; response_idx = IDX_W'(scan);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
                state_q[i] <= E_FREE; cmd_q[i] <= '0; result_q[i] <= '0;
                report_source_q[i] <= 1'b0; cp_ack_q[i] <= 1'b0; age_q[i] <= 64'd0;
            end
            for (int i = 0; i < ASYNC_ENTRIES; i = i + 1) begin
                async_vld_q[i] <= 1'b0; async_issuer_q[i] <= '0; async_seq_q[i] <= '0;
            end
            acceptance_q <= 64'd0;
            issuer_failed_q <= '0; issuer_seen_q <= '0;
            /* verilator lint_off WIDTHCONCAT */
            issuer_last_seq_q <= '0;
            /* verilator lint_on WIDTHCONCAT */
            issue_rr_q <= '0; response_rr_q <= '0; order_rr_q <= '0;
            core_cmd_vld_q <= 1'b0; core_cmd_q <= '0; core_slot_q <= '0;
            order_vld_q <= 1'b0; order_busy_q <= 1'b0; order_slot_q <= '0; order_acquire_q <= 1'b0; order_q <= '0;
            rsp_vld_q <= 1'b0; rsp_q <= '0; rsp_report_q <= 1'b0;
            async_rsp_vld_q <= 1'b0; async_rsp_q <= '0;
        end else begin
            if (async_rsp_vld_q && async_rsp_rdy_i) async_rsp_vld_q <= 1'b0;
            if (selected_async_req_vld_i && selected_async_req_rdy_o) begin
                async_rsp_vld_q <= 1'b1;
                async_rsp_q.issuer <= selected_async_req_i.issuer;
                async_rsp_q.seq <= selected_async_req_i.seq;
                async_rsp_q.status <= 8'd0;
                if (selected_async_req_i.complete) begin
                    if (!async_match) async_rsp_q.status <= MBAR_STATUS_BAD_TOKEN;
                    else begin
                        async_vld_q[async_match_idx] <= 1'b0;
                        async_rsp_q.status <= selected_async_req_i.status;
                        if (selected_async_req_i.status != 0) issuer_failed_q[selected_async_req_i.issuer] <= 1'b1;
                    end
                end else if (issuer_seen_q[selected_async_req_i.issuer] && selected_async_req_i.seq <= issuer_last_seq_q[selected_async_req_i.issuer]) begin
                    async_rsp_q.status <= MBAR_STATUS_BAD_TOKEN;
                end else begin
                    async_vld_q[async_free_idx] <= 1'b1;
                    async_issuer_q[async_free_idx] <= selected_async_req_i.issuer;
                    async_seq_q[async_free_idx] <= selected_async_req_i.seq;
                    issuer_seen_q[selected_async_req_i.issuer] <= 1'b1;
                    issuer_last_seq_q[selected_async_req_i.issuer] <= selected_async_req_i.seq;
                end
            end
            if (bar_cmd_vld_i && bar_cmd_rdy_o) begin
                cmd_q[free_idx] <= bar_cmd_i;
                result_q[free_idx] <= '0;
                result_q[free_idx].tag <= bar_cmd_i.tag;
                result_q[free_idx].issuer <= bar_cmd_i.issuer;
                result_q[free_idx].status <= input_status;
                report_source_q[free_idx] <= 1'b0;
                cp_ack_q[free_idx] <= 1'b0; age_q[free_idx] <= acceptance_q;
                acceptance_q <= acceptance_q + 64'd1;
                if (input_status != MBAR_STATUS_OK) state_q[free_idx] <= E_READY;
                else if (bar_cmd_i.opcode == MBAR_OP_CP_ASYNC_ARRIVE && bar_cmd_i.noinc) state_q[free_idx] <= E_CP_WAIT;
                else state_q[free_idx] <= input_release ? E_RELEASE : E_ISSUE;
            end else if (report_req_vld_i && report_req_rdy_o) begin
                cmd_q[free_idx] <= '0;
                cmd_q[free_idx].opcode <= MBAR_OP_REPORT;
                cmd_q[free_idx].addr <= report_req_i.addr;
                cmd_q[free_idx].tag <= report_req_i.tag;
                cmd_q[free_idx].report <= report_req_i.value;
                result_q[free_idx] <= '0;
                report_source_q[free_idx] <= 1'b1;
                state_q[free_idx] <= E_ISSUE;
                cp_ack_q[free_idx] <= 1'b0; age_q[free_idx] <= acceptance_q;
                acceptance_q <= acceptance_q + 64'd1;
            end
            // Request registers preserve payload across arbitrary core backpressure.
            if (issue_found && !core_cmd_vld_q) begin
                core_cmd_q <= cmd_q[issue_idx];
                core_cmd_q.tag <= 16'(issue_idx);
                core_slot_q <= issue_idx;
                core_cmd_vld_q <= 1'b1;
                if (state_q[issue_idx] == E_CP_ISSUE) begin
                    core_cmd_q.opcode <= issuer_failed_q[cmd_q[issue_idx].issuer] ? MBAR_OP_FAULT : MBAR_OP_ARRIVE;
                    core_cmd_q.arrive_count <= 32'd1;
                    core_cmd_q.no_complete <= 1'b0;
                    state_q[issue_idx] <= E_CP_CORE;
                end else begin
                    if (cmd_q[issue_idx].opcode == MBAR_OP_CP_ASYNC_ARRIVE) core_cmd_q.opcode <= MBAR_OP_PENDING_INC;
                    state_q[issue_idx] <= E_CORE;
                end
                issue_rr_q <= (issue_idx == IDX_W'(COMMAND_ENTRIES-1)) ? '0 : issue_idx + IDX_W'(1);
            end
            if (core_cmd_vld_q && core_cmd_rdy) core_cmd_vld_q <= 1'b0;
            for (int i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
                // Wait for the submission response to be captured before the
                // deferred arrival; noinc captures only operations earlier in sequence.
                if (state_q[i] == E_CP_WAIT && cp_ack_q[i] && !cp_pending[i]) state_q[i] <= E_CP_ISSUE;
            end
            if (core_rsp_vld && int'(core_rsp_tag) < COMMAND_ENTRIES) begin
                if (state_q[core_rsp_tag[IDX_W-1:0]] == E_CP_CORE) begin
                    state_q[core_rsp_tag[IDX_W-1:0]] <= E_FREE;
                end else begin
                    result_q[core_rsp_tag[IDX_W-1:0]] <= core_rsp;
                    result_q[core_rsp_tag[IDX_W-1:0]].tag <= cmd_q[core_rsp_tag[IDX_W-1:0]].tag;
                    result_q[core_rsp_tag[IDX_W-1:0]].issuer <= cmd_q[core_rsp_tag[IDX_W-1:0]].issuer;
                    if (core_rsp.status == 0 && cmd_q[core_rsp_tag[IDX_W-1:0]].opcode == MBAR_OP_CP_ASYNC_ARRIVE)
                        state_q[core_rsp_tag[IDX_W-1:0]] <= E_CP_WAIT;
                    else if (core_rsp.status == 0 && core_rsp.wait_complete && cmd_q[core_rsp_tag[IDX_W-1:0]].sem == BW_SEM_ACQUIRE)
                        state_q[core_rsp_tag[IDX_W-1:0]] <= E_ACQUIRE;
                    else state_q[core_rsp_tag[IDX_W-1:0]] <= E_READY;
                end
            end
            if (order_found && !order_vld_q && !order_busy_q) begin
                order_vld_q <= 1'b1;
                order_slot_q <= order_idx;
                order_acquire_q <= state_q[order_idx] == E_ACQUIRE;
                order_q.id <= 16'(order_idx);
                order_q.issuer <= cmd_q[order_idx].issuer;
                order_q.seq <= cmd_q[order_idx].seq;
                order_q.kind <= (state_q[order_idx] == E_ACQUIRE) ? BW_ORDER_ACQUIRE : BW_ORDER_RELEASE;
                order_q.scope <= cmd_q[order_idx].scope;
                order_q.from_proxy <= BW_PROXY_GENERIC;
                order_q.to_proxy <= BW_PROXY_GENERIC;
                order_q.addr <= cmd_q[order_idx].addr;
                order_q.bytes <= 64'd8;
                state_q[order_idx] <= E_ORDER;
                order_rr_q <= (order_idx == IDX_W'(COMMAND_ENTRIES-1)) ? '0 : order_idx + IDX_W'(1);
            end
            if (order_vld_q && order_req_rdy_i) begin order_vld_q <= 1'b0; order_busy_q <= 1'b1; end
            if (order_rsp_vld_i && order_rsp_rdy_o) begin
                order_busy_q <= 1'b0;
                if (order_rsp_i.status != 0 || order_rsp_i.id != 16'(order_slot_q)) begin
                    result_q[order_slot_q].status <= MBAR_STATUS_MEMORY;
                    result_q[order_slot_q].wait_complete <= 1'b0;
                    state_q[order_slot_q] <= E_READY;
                end else state_q[order_slot_q] <= order_acquire_q ? E_READY : E_ISSUE;
            end
            if (rsp_vld_q && (rsp_report_q ? report_rsp_rdy_i : bar_rsp_rdy_i)) rsp_vld_q <= 1'b0;
            if (response_found && (!rsp_vld_q || (rsp_report_q ? report_rsp_rdy_i : bar_rsp_rdy_i))) begin
                rsp_vld_q <= 1'b1; rsp_q <= result_q[response_idx]; rsp_report_q <= report_source_q[response_idx];
                if (state_q[response_idx] == E_CP_WAIT || state_q[response_idx] == E_CP_READY) cp_ack_q[response_idx] <= 1'b1;
                else state_q[response_idx] <= E_FREE;
                response_rr_q <= (response_idx == IDX_W'(COMMAND_ENTRIES-1)) ? '0 : response_idx + IDX_W'(1);
            end
        end
    end

    wire arb_vld, arb_rdy, arb_rsp_vld, arb_rsp_rdy;
    bar_cmd_t arb_cmd, arb_tc_cmd;
    wire arb_tc_vld, arb_tc_rdy;
    bar_rsp_t arb_rsp;
    mbarrier_tc_arbiter u_tc_arrival (
        .clk(clk), .rst_n(rst_n),
        .sw_vld_i(core_cmd_vld_q), .sw_rdy_o(core_cmd_rdy), .sw_i(core_cmd_q),
        .sw_rsp_vld_o(core_rsp_vld), .sw_rsp_rdy_i(1'b1), .sw_rsp_o(core_rsp),
        .tc_vld_i(tc_arrive_vld_i), .tc_rdy_o(tc_arrive_rdy_o), .tc_i(tc_arrive_i),
        .tc_rsp_vld_o(tc_arrive_rsp_vld_o), .tc_rsp_rdy_i(tc_arrive_rsp_rdy_i),
        .tc_rsp_o(tc_arrive_rsp_o),
        .core_vld_o(arb_vld), .core_rdy_i(arb_rdy), .core_o(arb_cmd),
        .core_tc_vld_o(arb_tc_vld), .core_tc_rdy_i(arb_tc_rdy), .core_tc_o(arb_tc_cmd),
        .core_rsp_vld_i(arb_rsp_vld), .core_rsp_rdy_o(arb_rsp_rdy), .core_rsp_i(arb_rsp)
    );
    mbarrier_unit #(
        .ADDR_W(ADDR_W), .CACHE_ENTRIES(CACHE_ENTRIES), .WAIT_ENTRIES(WAIT_ENTRIES),
        .WRITE_BUF_DEPTH(WRITE_BUF_DEPTH), .MEM_ID_W(MEM_ID_W),
        .CLOCK_PERIOD_NS(CLOCK_PERIOD_NS), .WAIT_DEFAULT_CYCLES(WAIT_DEFAULT_CYCLES)
    ) u_state (
        .clk(clk), .rst_n(rst_n),
        .tc_cmd_vld_i(arb_tc_vld), .tc_cmd_rdy_o(arb_tc_rdy), .tc_cmd_i(arb_tc_cmd),
        .bar_cmd_vld_i(arb_vld), .bar_cmd_rdy_o(arb_rdy),
        .bar_cmd_opcode_i(arb_cmd.opcode), .bar_cmd_tag_i(arb_cmd.tag),
        .bar_cmd_addr_i(arb_cmd.addr), .bar_cmd_arrive_count_i(arb_cmd.arrive_count),
        .bar_cmd_tx_bytes_i(arb_cmd.tx_bytes), .bar_cmd_phase_token_i(arb_cmd.phase_token),
        .bar_cmd_wait_parity_i(arb_cmd.wait_parity), .bar_cmd_state_i(arb_cmd.state),
        .bar_cmd_time_hint_i(arb_cmd.time_hint), .bar_cmd_layout_i(arb_cmd.layout),
        .bar_cmd_no_complete_i(arb_cmd.no_complete), .bar_cmd_conditional_i(arb_cmd.conditional),
        .bar_cmd_report_i(arb_cmd.report),
        .bar_rsp_vld_o(arb_rsp_vld), .bar_rsp_rdy_i(arb_rsp_rdy),
        .bar_rsp_tag_o(arb_rsp.tag), .bar_rsp_status_o(arb_rsp.status), .bar_rsp_phase_o(arb_rsp.phase),
        .bar_rsp_locked_o(arb_rsp.locked), .bar_rsp_state_o(arb_rsp.state),
        .bar_rsp_wait_complete_o(arb_rsp.wait_complete), .bar_rsp_value_o(arb_rsp.value),
        .bar_rsp_predicate_o(arb_rsp.predicate), .bar_rsp_report_o(arb_rsp.report),
        .bar_rsp_report_predicate_o(arb_rsp.report_predicate),
        .tx_cpl_vld_i(tx_cpl_vld_i), .tx_cpl_rdy_o(tx_cpl_rdy_o), .tx_cpl_tag_i(tx_cpl_tag_i),
        .tx_cpl_addr_i(tx_cpl_addr_i), .tx_cpl_bytes_i(tx_cpl_bytes_i), .tx_rsp_vld_o(tx_rsp_vld_o),
        .tx_rsp_rdy_i(tx_rsp_rdy_i), .tx_rsp_tag_o(tx_rsp_tag_o), .tx_rsp_status_o(tx_rsp_status_o),
        .tx_rsp_phase_o(tx_rsp_phase_o), .mem_req_vld_o(mem_req_vld_o), .mem_req_rdy_i(mem_req_rdy_i),
        .mem_req_write_o(mem_req_write_o), .mem_req_addr_o(mem_req_addr_o), .mem_req_data_o(mem_req_data_o),
        .mem_req_mask_o(mem_req_mask_o), .mem_req_id_o(mem_req_id_o), .mem_rsp_vld_i(mem_rsp_vld_i),
        .mem_rsp_rdy_o(mem_rsp_rdy_o), .mem_rsp_data_i(mem_rsp_data_i),
        .mem_rsp_status_i(mem_rsp_status_i), .mem_rsp_id_i(mem_rsp_id_i)
    );
    assign core_rsp_tag = core_rsp.tag;
    assign arb_rsp.issuer = 10'd0;
    initial begin
        if (COMMAND_ENTRIES < 4 || COMMAND_ENTRIES > 32768 || ASYNC_ENTRIES < 1)
            $error("mbarrier frontend table bounds invalid");
    end
endmodule
`default_nettype wire
