// Ordering at the command-admission boundary. Register an operation before it
// enters any execution queue; complete it only at its required visibility point.
// Scope/proxy maintenance is an acknowledged external endpoint, never a timer.
// CTA teardown must drain and jointly reset this tracker and its endpoints.
`default_nettype none
module blackwell_order_tracker #(
    parameter int unsigned OPERATIONS = 64,
    parameter int unsigned FENCES = 16
) (
    input wire clk, rst_n,
    input wire register_vld_i,
    output wire register_rdy_o,
    input wire [9:0] register_issuer_i,
    input wire [63:0] register_seq_i,
    output wire [15:0] register_token_o,
    input wire complete_vld_i,
    output wire complete_rdy_o,
    input wire [15:0] complete_token_i,
    input wire complete_error_i,
    input wire order_vld_i,
    output wire order_rdy_o,
    input tma_mbarrier_pkg::bw_order_req_t order_i,
    output wire order_rsp_vld_o,
    input wire order_rsp_rdy_i,
    output tma_mbarrier_pkg::bw_order_rsp_t order_rsp_o,
    output wire maintenance_vld_o,
    input wire maintenance_rdy_i,
    output tma_mbarrier_pkg::bw_order_req_t maintenance_o,
    input wire maintenance_rsp_vld_i,
    output wire maintenance_rsp_rdy_o,
    input tma_mbarrier_pkg::bw_order_rsp_t maintenance_rsp_i,
    output logic protocol_error_o
);
    import tma_mbarrier_pkg::*;
    localparam int unsigned OW = OPERATIONS < 2 ? 1 : $clog2(OPERATIONS);
    localparam int unsigned FW = FENCES < 2 ? 1 : $clog2(FENCES);
    logic [OPERATIONS-1:0] op_live_q;
    logic [9:0] issuer_q [OPERATIONS];
    logic [63:0] seq_q [OPERATIONS];
    logic [15-OW:0] op_generation_q [OPERATIONS];
    logic [FENCES-1:0] fence_live_q, maintenance_sent_q, fence_done_q, fence_error_q;
    logic [OPERATIONS-1:0] pending_q [FENCES];
    logic [FENCES-1:0] predecessors_q [FENCES];
    logic [15-FW:0] fence_generation_q [FENCES];
    bw_order_req_t fence_q [FENCES];
    logic [1023:0] faulted_q;
    integer free_op, free_fence, complete_slot, maint_slot, maint_pick, response_pick;
    logic completion_match, maintenance_match, registration_blocked;
    logic [OPERATIONS-1:0] retire_mask, new_pending;
    logic [FENCES-1:0] retire_fence, new_predecessors;
    logic [FW-1:0] maintenance_turn_q,response_turn_q,maintenance_hold_slot_q,response_hold_slot_q;
    logic maintenance_hold_q,response_hold_q;
    wire register_fire = register_vld_i && register_rdy_o;
    wire order_fire = order_vld_i && order_rdy_o;
    assign register_rdy_o = free_op >= 0 && !registration_blocked;
    assign register_token_o = free_op >= 0 ? {op_generation_q[free_op]+(16-OW)'(1),OW'(free_op)} : 16'd0;
    assign complete_rdy_o = 1'b1;
    assign order_rdy_o = free_fence >= 0;
    assign maintenance_rsp_rdy_o = 1'b1;
    assign maintenance_vld_o = maint_pick >= 0;
    assign order_rsp_vld_o = response_pick >= 0;
    always_comb begin
        free_op = -1; free_fence = -1;
        for (int s = 0; s < OPERATIONS; s++) if (!op_live_q[s] && free_op < 0) free_op = s;
        for (int f = 0; f < FENCES; f++) if (!fence_live_q[f] && free_fence < 0) free_fence = f;
        complete_slot = int'(complete_token_i[OW-1:0]);
        completion_match = 1'b0;
        if (complete_slot < OPERATIONS)
            completion_match = op_live_q[complete_slot] && op_generation_q[complete_slot] == complete_token_i[15:OW];
        retire_mask = '0;
        if (complete_vld_i && completion_match) retire_mask[complete_slot] = 1'b1;
        maint_slot = int'(maintenance_rsp_i.id[FW-1:0]);
        maintenance_match = 1'b0;
        if (maint_slot < FENCES)
            maintenance_match = fence_live_q[maint_slot] && maintenance_sent_q[maint_slot] && !fence_done_q[maint_slot] &&
                fence_generation_q[maint_slot] == maintenance_rsp_i.id[15:FW];
        registration_blocked = 1'b0;
        for (int f = 0; f < FENCES; f++)
            if (fence_live_q[f] && fence_q[f].issuer == register_issuer_i && register_seq_i >= fence_q[f].seq)
                registration_blocked = 1'b1;
        // A fence and a later operation on the same edge must not race admission.
        if (order_vld_i && free_fence >= 0 && order_i.issuer == register_issuer_i && register_seq_i >= order_i.seq)
            registration_blocked = 1'b1;
        new_pending = '0; new_predecessors = '0;
        for (int s = 0; s < OPERATIONS; s++)
            if (op_live_q[s] && issuer_q[s] == order_i.issuer && seq_q[s] < order_i.seq && !retire_mask[s]) new_pending[s] = 1'b1;
        if (register_vld_i && free_op >= 0 && !registration_blocked && register_issuer_i == order_i.issuer && register_seq_i < order_i.seq)
            new_pending[free_op] = 1'b1;
        for (int f = 0; f < FENCES; f++)
            if (fence_live_q[f] && fence_q[f].issuer == order_i.issuer) new_predecessors[f] = 1'b1;
        maint_pick = -1; response_pick = -1;
        for (int delta = 0; delta < FENCES; delta++) begin
            if (maint_pick < 0 && fence_live_q[(int'(maintenance_turn_q)+delta)%FENCES] &&
                !maintenance_sent_q[(int'(maintenance_turn_q)+delta)%FENCES] && !fence_done_q[(int'(maintenance_turn_q)+delta)%FENCES] &&
                !(|pending_q[(int'(maintenance_turn_q)+delta)%FENCES]) && !(|predecessors_q[(int'(maintenance_turn_q)+delta)%FENCES]))
                maint_pick = (int'(maintenance_turn_q)+delta)%FENCES;
            if (response_pick < 0 && fence_live_q[(int'(response_turn_q)+delta)%FENCES] && fence_done_q[(int'(response_turn_q)+delta)%FENCES] &&
                !(|predecessors_q[(int'(response_turn_q)+delta)%FENCES])) response_pick = (int'(response_turn_q)+delta)%FENCES;
        end
        if (maintenance_hold_q) maint_pick = int'(maintenance_hold_slot_q);
        if (response_hold_q) response_pick = int'(response_hold_slot_q);
        maintenance_o = '0; order_rsp_o = '0;
        if (maint_pick >= 0) begin
            maintenance_o = fence_q[maint_pick];
            maintenance_o.id = {fence_generation_q[maint_pick],FW'(maint_pick)};
        end
        if (response_pick >= 0) begin
            order_rsp_o.id = fence_q[response_pick].id;
            order_rsp_o.status = fence_error_q[response_pick] ? 8'd1 : 8'd0;
        end
        retire_fence = '0;
        if (response_pick >= 0 && order_rsp_rdy_i) retire_fence[response_pick] = 1'b1;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_live_q <= '0; fence_live_q <= '0; fence_done_q <= '0; fence_error_q <= '0; maintenance_sent_q <= '0;
            faulted_q <= '0; protocol_error_o <= 1'b0;
            maintenance_hold_q <= 1'b0; response_hold_q <= 1'b0; maintenance_turn_q <= '0; response_turn_q <= '0;
            maintenance_hold_slot_q <= '0; response_hold_slot_q <= '0;
            for (int s = 0; s < OPERATIONS; s++) op_generation_q[s] <= '0;
            for (int f = 0; f < FENCES; f++) begin fence_generation_q[f] <= '0; pending_q[f] <= '0; predecessors_q[f] <= '0; end
        end else begin
            for (int f = 0; f < FENCES; f++) begin
                pending_q[f] <= pending_q[f] & ~retire_mask;
                predecessors_q[f] <= predecessors_q[f] & ~retire_fence;
                if (complete_vld_i && completion_match && complete_error_i && pending_q[f][complete_slot]) fence_error_q[f] <= 1'b1;
                if (maintenance_rsp_vld_i && maintenance_match && maintenance_rsp_i.status != 0 &&
                    predecessors_q[f][maint_slot]) fence_error_q[f] <= 1'b1;
            end
            if (complete_vld_i) begin
                if (!completion_match) protocol_error_o <= 1'b1;
                else begin
                    op_live_q[complete_slot] <= 1'b0;
                    if (complete_error_i) faulted_q[issuer_q[complete_slot]] <= 1'b1;
                end
            end
            if (register_fire) begin
                op_live_q[free_op] <= 1'b1; issuer_q[free_op] <= register_issuer_i; seq_q[free_op] <= register_seq_i;
                op_generation_q[free_op] <= op_generation_q[free_op]+1'b1;
            end
            if (order_fire) begin
                fence_live_q[free_fence] <= 1'b1; fence_done_q[free_fence] <= 1'b0; maintenance_sent_q[free_fence] <= 1'b0;
                fence_q[free_fence] <= order_i; fence_generation_q[free_fence] <= fence_generation_q[free_fence]+1'b1;
                pending_q[free_fence] <= new_pending; predecessors_q[free_fence] <= new_predecessors & ~retire_fence;
                fence_error_q[free_fence] <= faulted_q[order_i.issuer] || order_i.kind > BW_ORDER_PROXY ||
                    order_i.from_proxy > BW_PROXY_TENSORMAP || order_i.to_proxy > BW_PROXY_TENSORMAP ||
                    (complete_vld_i && completion_match && complete_error_i && issuer_q[complete_slot] == order_i.issuer) ||
                    (maintenance_rsp_vld_i && maintenance_match && maintenance_rsp_i.status != 0 && fence_q[maint_slot].issuer == order_i.issuer);
            end
            if (maint_pick >= 0) begin
                if (maintenance_rdy_i) begin
                    maintenance_sent_q[maint_pick] <= 1'b1; maintenance_hold_q <= 1'b0;
                    maintenance_turn_q <= maint_pick == FENCES-1 ? '0 : FW'(maint_pick+1);
                end else begin maintenance_hold_q <= 1'b1; maintenance_hold_slot_q <= FW'(maint_pick); end
            end
            if (maintenance_rsp_vld_i) begin
                if (!maintenance_match) protocol_error_o <= 1'b1;
                else begin
                    fence_done_q[maint_slot] <= 1'b1;
                    fence_error_q[maint_slot] <= fence_error_q[maint_slot] || maintenance_rsp_i.status != 0;
                    if (maintenance_rsp_i.status != 0) faulted_q[fence_q[maint_slot].issuer] <= 1'b1;
                end
            end
            if (response_pick >= 0) begin
                if (order_rsp_rdy_i) begin
                    fence_live_q[response_pick] <= 1'b0; response_hold_q <= 1'b0;
                    response_turn_q <= response_pick == FENCES-1 ? '0 : FW'(response_pick+1);
                end else begin response_hold_q <= 1'b1; response_hold_slot_q <= FW'(response_pick); end
            end
        end
    end
    initial if (OPERATIONS < 1 || FENCES < 1 || OW > 12 || FW > 12) $error("Invalid ordering tracker geometry");
endmodule
`default_nettype wire
