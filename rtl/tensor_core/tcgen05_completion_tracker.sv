// Tracks accepted MMA/CP/SHIFT work, including work queued outside this block.
// Register BEFORE dispatch. Complete only after all data writes are visible.
// Commit excludes operations accepted on its own edge; the command frontend
// serializes instructions from a thread. There is no wrap-sensitive watermark.
`default_nettype none
module tcgen05_completion_tracker #(
    parameter int unsigned OPERATIONS = 32,
    parameter int unsigned COMMITS = 8
) (
    input wire clk, rst_n,
    input wire register_vld_i,
    output wire register_rdy_o,
    input blackwell_async_pkg::async_id_t register_i,
    input wire complete_vld_i,
    output wire complete_rdy_o,
    input blackwell_async_pkg::async_event_t complete_i,
    input wire commit_vld_i,
    output wire commit_rdy_o,
    input blackwell_async_pkg::tc_commit_t commit_i,
    output wire arrival_vld_o,
    input wire arrival_rdy_i,
    output blackwell_async_pkg::tc_commit_t arrival_o,
    output wire [7:0] arrival_status_o,
    output wire protocol_error_o
);
    import blackwell_async_pkg::*;
    localparam int unsigned OP_W = (OPERATIONS < 2) ? 1 : $clog2(OPERATIONS);
    localparam int unsigned COM_W = (COMMITS < 2) ? 1 : $clog2(COMMITS);
    logic [OPERATIONS-1:0] live_q, snapshot;
    async_id_t operation_q [0:OPERATIONS-1];
    tc_commit_t commit_q [0:COMMITS-1];
    logic [OPERATIONS-1:0] pending_q [0:COMMITS-1];
    logic [7:0] status_q [0:COMMITS-1];
    // An execution failure remains attached to this CTA/thread until reset.
    // A new CTA must drain and reset this block, not just recycle an epoch.
    logic [1023:0] poisoned_q;
    logic [COMMITS-1:0] commit_live_q, predecessors_q [0:COMMITS-1];
    logic [COMMITS-1:0] predecessors;
    logic [COM_W-1:0] commit_free_idx, ready_idx, rr_q;
    logic commit_free, ready_found, arrival_vld_q;
    tc_commit_t arrival_q;
    logic [7:0] arrival_status_q;
    wire select_fire = ready_found && (!arrival_vld_q || arrival_rdy_i);
    logic free_found, match_found, duplicate;
    logic [OP_W-1:0] free_idx, match_idx;
    wire register_fire = register_vld_i && register_rdy_o;
    wire complete_fire = complete_vld_i && complete_rdy_o;
    wire commit_fire = commit_vld_i && commit_rdy_o;
    wire arrival_fire = arrival_vld_o && arrival_rdy_i;
    wire completion_bad = !match_found || complete_i.domain != CPL_TC;
    wire completion_failed = complete_fire && !completion_bad && complete_i.status != 0;
    assign register_rdy_o = free_found && !duplicate;
    assign complete_rdy_o = 1'b1; // Completion cannot depend on registration credit.
    assign commit_rdy_o = commit_free;
    assign arrival_vld_o = arrival_vld_q;
    assign arrival_o = arrival_q;
    assign arrival_status_o = arrival_status_q;
    assign protocol_error_o = complete_fire && completion_bad;
    always_comb begin
        free_found = 1'b0; match_found = 1'b0; duplicate = 1'b0;
        free_idx = '0; match_idx = '0; snapshot = '0;
        for (int i = 0; i < OPERATIONS; i++) begin
            if (!live_q[i] && !free_found) begin
                free_found = 1'b1; free_idx = OP_W'(i);
            end
            if (live_q[i] && same_operation(operation_q[i], complete_i.id)) begin
                match_found = 1'b1; match_idx = OP_W'(i);
            end
            if (live_q[i] && same_operation(operation_q[i], register_i)) duplicate = 1'b1;
            if (live_q[i] && operation_q[i].issuer == commit_i.id.issuer &&
                operation_q[i].epoch == commit_i.id.epoch) snapshot[i] = 1'b1;
        end
        commit_free = 1'b0; ready_found = 1'b0;
        commit_free_idx = '0; ready_idx = '0; predecessors = '0;
        for (int c = 0; c < COMMITS; c++) begin
            if (!commit_live_q[c] && !commit_free) begin
                commit_free = 1'b1; commit_free_idx = COM_W'(c);
            end
            if (commit_live_q[c] && commit_q[c].id.issuer == commit_i.id.issuer &&
                commit_q[c].id.epoch == commit_i.id.epoch) predecessors[c] = 1'b1;
            if (!ready_found && commit_live_q[(int'(rr_q)+c)%COMMITS] &&
                pending_q[(int'(rr_q)+c)%COMMITS] == '0 &&
                predecessors_q[(int'(rr_q)+c)%COMMITS] == '0) begin
                ready_found = 1'b1; ready_idx = COM_W'((int'(rr_q)+c)%COMMITS);
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            live_q <= '0; poisoned_q <= '0;
            commit_live_q <= '0; rr_q <= '0; arrival_vld_q <= 1'b0;
            arrival_q <= '0; arrival_status_q <= '0;
            for (int c = 0; c < COMMITS; c++) begin
                pending_q[c] <= '0; status_q[c] <= '0; predecessors_q[c] <= '0;
            end
        end else begin
            if (arrival_fire) arrival_vld_q <= 1'b0;
            if (select_fire) begin
                arrival_vld_q <= 1'b1;
                arrival_q <= commit_q[ready_idx];
                arrival_status_q <= status_q[ready_idx];
                commit_live_q[ready_idx] <= 1'b0;
                rr_q <= (ready_idx == COM_W'(COMMITS-1)) ? '0 : ready_idx + COM_W'(1);
                for (int c = 0; c < COMMITS; c++) predecessors_q[c][ready_idx] <= 1'b0;
            end
            if (complete_fire && !completion_bad) begin
                live_q[match_idx] <= 1'b0;
                if (completion_failed) poisoned_q[complete_i.id.issuer] <= 1'b1;
                for (int c = 0; c < COMMITS; c++) begin
                    if (pending_q[c][match_idx]) begin
                        pending_q[c][match_idx] <= 1'b0;
                        if (completion_failed) status_q[c] <= ASYNC_EXECUTION_ERROR;
                    end
                end
            end
            if (register_fire) begin
                live_q[free_idx] <= 1'b1;
                operation_q[free_idx] <= register_i;
            end
            if (commit_fire) begin
                commit_q[commit_free_idx] <= commit_i;
                pending_q[commit_free_idx] <= (complete_fire && !completion_bad) ?
                    snapshot & ~(OPERATIONS'(1) << match_idx) : snapshot;
                status_q[commit_free_idx] <= (poisoned_q[commit_i.id.issuer] ||
                    (completion_failed && complete_i.id.issuer == commit_i.id.issuer)) ?
                    ASYNC_EXECUTION_ERROR : ASYNC_OK;
                commit_live_q[commit_free_idx] <= 1'b1;
                predecessors_q[commit_free_idx] <= select_fire ?
                    predecessors & ~(COMMITS'(1) << ready_idx) : predecessors;
            end
        end
    end
    initial begin
        if (OPERATIONS < 1 || COMMITS < 1) $error("Invalid completion tracker capacity");
    end
endmodule
`default_nettype wire
