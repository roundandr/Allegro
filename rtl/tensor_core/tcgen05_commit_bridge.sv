// Completion-to-mbarrier bridge. Acknowledgment is after barrier backing write.
// Failed execution locks the barrier through the project fault path; it never
// produces a successful arrival. No transaction-byte accounting occurs here.
`default_nettype none
module tcgen05_commit_bridge (
    input wire clk, rst_n,
    input wire commit_vld_i,
    output wire commit_rdy_o,
    input blackwell_async_pkg::tc_commit_t commit_i,
    input wire [7:0] commit_status_i,
    output wire bar_vld_o,
    input wire bar_rdy_i,
    output tma_mbarrier_pkg::bar_cmd_t bar_o,
    input wire bar_rsp_vld_i,
    output wire bar_rsp_rdy_o,
    input tma_mbarrier_pkg::bar_rsp_t bar_rsp_i,
    output wire event_vld_o,
    input wire event_rdy_i,
    output blackwell_async_pkg::async_event_t event_o
);
    import blackwell_async_pkg::*;
    import tma_mbarrier_pkg::*;
    logic busy_q, event_vld_q;
    async_id_t id_q;
    logic [7:0] status_q;
    async_event_t event_q;
    assign commit_rdy_o = !busy_q && !event_vld_q && bar_rdy_i;
    assign bar_vld_o = commit_vld_i && !busy_q && !event_vld_q;
    assign bar_rsp_rdy_o = busy_q && !event_vld_q;
    assign event_vld_o = event_vld_q;
    assign event_o = event_q;
    always_comb begin
        bar_o = '0;
        bar_o.opcode = commit_status_i == 0 ? MBAR_OP_ARRIVE : MBAR_OP_FAULT;
        bar_o.tag = commit_i.id.tag;
        bar_o.issuer = commit_i.id.issuer;
        bar_o.seq = commit_i.id.seq;
        bar_o.addr = commit_i.barrier;
        bar_o.arrive_count = 32'd1;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0; event_vld_q <= 1'b0;
            id_q <= '0; status_q <= '0; event_q <= '0;
        end else begin
            if (commit_vld_i && commit_rdy_o) begin
                busy_q <= 1'b1; id_q <= commit_i.id; status_q <= commit_status_i;
            end
            if (bar_rsp_vld_i && bar_rsp_rdy_o) begin
                busy_q <= 1'b0; event_vld_q <= 1'b1;
                event_q.id <= id_q; event_q.domain <= CPL_TC;
                event_q.value <= {63'd0, bar_rsp_i.phase};
                event_q.status <= status_q != 0 ? status_q :
                    ((bar_rsp_i.tag != id_q.tag || bar_rsp_i.issuer != id_q.issuer) ?
                     ASYNC_BAD_COMPLETION : bar_rsp_i.status);
            end
            if (event_vld_q && event_rdy_i) event_vld_q <= 1'b0;
        end
    end
endmodule
`default_nettype wire
