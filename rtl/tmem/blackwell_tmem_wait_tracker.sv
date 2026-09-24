// Single-CTA TMEM LD/ST wait domain. A wait captures only accepted older
// operations of its own warp, context, epoch and class. Slot reuse is safe:
// completion clears every captured bit before the slot becomes free.
`default_nettype none
module blackwell_tmem_wait_tracker #(
    parameter int unsigned OPERATIONS = 16,
    parameter int unsigned WAITS = 16,
    parameter int unsigned TAG_W = 16
) (
    input wire clk, rst_n,
    input wire op_vld_i, output wire op_rdy_o,
    input wire [4:0] op_ctx_i, input wire [15:0] op_epoch_i,
    input wire [4:0] op_warp_i, input wire op_store_i,
    input wire [TAG_W-1:0] op_tag_i, input wire [63:0] op_seq_i,
    input wire finish_vld_i, output wire finish_rdy_o,
    input wire [4:0] finish_ctx_i, input wire [15:0] finish_epoch_i,
    input wire [4:0] finish_warp_i, input wire finish_store_i,
    input wire [TAG_W-1:0] finish_tag_i, input wire [63:0] finish_seq_i,
    input wire [7:0] finish_status_i,
    input wire wait_vld_i, output wire wait_rdy_o,
    input wire [4:0] wait_ctx_i, input wire [15:0] wait_epoch_i,
    input wire [4:0] wait_warp_i, input wire wait_store_i,
    input wire [TAG_W-1:0] wait_tag_i,
    input wire clear_ctx_vld_i, input wire [4:0] clear_ctx_i,
    output wire rsp_vld_o, input wire rsp_rdy_i,
    output wire [4:0] rsp_ctx_o, output wire [15:0] rsp_epoch_o,
    output wire [4:0] rsp_warp_o, output wire rsp_store_o,
    output wire [TAG_W-1:0] rsp_tag_o, output wire [7:0] rsp_status_o,
    output wire protocol_error_o
);
    localparam logic [7:0] OK=8'd0, ERR_DEPENDENCY=8'd16;
    localparam int unsigned OP_W = OPERATIONS < 2 ? 1 : $clog2(OPERATIONS);
    localparam int unsigned WAIT_W = WAITS < 2 ? 1 : $clog2(WAITS);
    typedef struct packed {
        logic [4:0] ctx, warp;
        logic [15:0] epoch;
        logic store;
        logic [TAG_W-1:0] tag;
        logic [63:0] seq;
    } operation_t;
    typedef struct packed {
        logic [4:0] ctx, warp;
        logic [15:0] epoch;
        logic store;
        logic [TAG_W-1:0] tag;
    } wait_t;
    operation_t op_q [0:OPERATIONS-1];
    wait_t wait_q [0:WAITS-1];
    logic [OPERATIONS-1:0] op_live_q, snapshot;
    logic [WAITS-1:0] wait_live_q, predecessor, predecessors_q [0:WAITS-1];
    logic [OPERATIONS-1:0] pending_q [0:WAITS-1];
    logic [7:0] status_q [0:WAITS-1];
    // A context has one live epoch. Keep the epoch once per context, and
    // the sticky failure bit per warp/class. This avoids a 2048-entry epoch
    // comparison mux on every wait admission.
    logic [31:0][15:0] context_epoch_q;
    logic [31:0] context_valid_q;
    logic [31:0][63:0] poisoned_q;
    logic [OP_W-1:0] op_free_idx, finish_idx;
    logic [WAIT_W-1:0] wait_free_idx, ready_idx, rr_q;
    logic op_free, duplicate, finish_match, wait_free, ready_found;
    logic rsp_vld_q;
    wait_t rsp_q;
    logic [7:0] rsp_status_q;
    wire op_fire = op_vld_i && op_rdy_o;
    wire finish_fire = finish_vld_i && finish_rdy_o;
    wire wait_fire = wait_vld_i && wait_rdy_o;
    wire rsp_fire = rsp_vld_o && rsp_rdy_i;
    wire select_fire = ready_found && (!rsp_vld_q || rsp_rdy_i);
    wire finish_bad = finish_fire && !finish_match;
    wire finish_failed = finish_fire && finish_match && finish_status_i != OK;
    wire [5:0] finish_poison_idx = {finish_warp_i,finish_store_i};
    wire [5:0] wait_poison_idx = {wait_warp_i,wait_store_i};
    assign op_rdy_o = op_free && !duplicate;
    assign finish_rdy_o = 1'b1; // Never depend on wait or output credit.
    assign wait_rdy_o = wait_free;
    assign rsp_vld_o = rsp_vld_q;
    assign rsp_ctx_o = rsp_q.ctx;
    assign rsp_epoch_o = rsp_q.epoch;
    assign rsp_warp_o = rsp_q.warp;
    assign rsp_store_o = rsp_q.store;
    assign rsp_tag_o = rsp_q.tag;
    assign rsp_status_o = rsp_status_q;
    assign protocol_error_o = finish_bad;
    always_comb begin
        op_free=1'b0; duplicate=1'b0; finish_match=1'b0;
        op_free_idx='0; finish_idx='0; snapshot='0;
        for (int i=0;i<OPERATIONS;i++) begin
            if (!op_live_q[i] && !op_free) begin
                op_free=1'b1; op_free_idx=OP_W'(i);
            end
            if (op_live_q[i]) begin
                if (op_q[i].ctx == op_ctx_i && op_q[i].epoch == op_epoch_i &&
                    op_q[i].warp == op_warp_i && op_q[i].store == op_store_i &&
                    op_q[i].tag == op_tag_i && op_q[i].seq == op_seq_i)
                    duplicate=1'b1;
                if (op_q[i].ctx == finish_ctx_i && op_q[i].epoch == finish_epoch_i &&
                    op_q[i].warp == finish_warp_i && op_q[i].store == finish_store_i &&
                    op_q[i].tag == finish_tag_i && op_q[i].seq == finish_seq_i) begin
                    finish_match=1'b1; finish_idx=OP_W'(i);
                end
                if (op_q[i].ctx == wait_ctx_i && op_q[i].epoch == wait_epoch_i &&
                    op_q[i].warp == wait_warp_i && op_q[i].store == wait_store_i)
                    snapshot[i]=1'b1;
            end
        end
        wait_free=1'b0; ready_found=1'b0;
        wait_free_idx='0; ready_idx='0; predecessor='0;
        for (int w=0;w<WAITS;w++) begin
            if (!wait_live_q[w] && !wait_free) begin
                wait_free=1'b1; wait_free_idx=WAIT_W'(w);
            end
            if (wait_live_q[w] && wait_q[w].ctx == wait_ctx_i &&
                wait_q[w].epoch == wait_epoch_i && wait_q[w].warp == wait_warp_i &&
                wait_q[w].store == wait_store_i) predecessor[w]=1'b1;
            if (!ready_found && wait_live_q[(int'(rr_q)+w)%WAITS] &&
                pending_q[(int'(rr_q)+w)%WAITS] == '0 &&
                predecessors_q[(int'(rr_q)+w)%WAITS] == '0) begin
                ready_found=1'b1;
                ready_idx=WAIT_W'((int'(rr_q)+w)%WAITS);
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_live_q<='0; wait_live_q<='0; poisoned_q<='0;
            context_epoch_q<='0; context_valid_q<='0;
            rr_q<='0; rsp_vld_q<=1'b0; rsp_q<='0; rsp_status_q<=OK;
            for (int w=0;w<WAITS;w++) begin
                pending_q[w]<='0; predecessors_q[w]<='0; status_q[w]<=OK;
            end
        end else begin
            if (rsp_fire) rsp_vld_q<=1'b0;
            if (select_fire) begin
                rsp_vld_q<=1'b1;
                rsp_q<=wait_q[ready_idx];
                rsp_status_q<=status_q[ready_idx];
                wait_live_q[ready_idx]<=1'b0;
                rr_q<=ready_idx == WAIT_W'(WAITS-1) ? '0 : ready_idx+WAIT_W'(1);
                for (int w=0;w<WAITS;w++)
                    predecessors_q[w][ready_idx]<=1'b0;
            end
            if (finish_fire && finish_match) begin
                op_live_q[finish_idx]<=1'b0;
                if (finish_failed &&
                    (!context_valid_q[finish_ctx_i] ||
                     context_epoch_q[finish_ctx_i] == finish_epoch_i)) begin
                    poisoned_q[finish_ctx_i][finish_poison_idx]<=1'b1;
                    context_valid_q[finish_ctx_i]<=1'b1;
                    context_epoch_q[finish_ctx_i]<=finish_epoch_i;
                end
                for (int w=0;w<WAITS;w++) begin
                    if (pending_q[w][finish_idx]) begin
                        pending_q[w][finish_idx]<=1'b0;
                        if (finish_failed) status_q[w]<=ERR_DEPENDENCY;
                    end
                end
            end
            if (op_fire) begin
                op_live_q[op_free_idx]<=1'b1;
                op_q[op_free_idx]<='{op_ctx_i,op_warp_i,op_epoch_i,
                                     op_store_i,op_tag_i,op_seq_i};
                if (!context_valid_q[op_ctx_i] ||
                    context_epoch_q[op_ctx_i] != op_epoch_i)
                    poisoned_q[op_ctx_i]<=
                        (finish_failed && finish_ctx_i == op_ctx_i &&
                         finish_epoch_i == op_epoch_i) ?
                        (64'(1) << finish_poison_idx) : 64'd0;
                context_valid_q[op_ctx_i]<=1'b1;
                context_epoch_q[op_ctx_i]<=op_epoch_i;
            end
            if (wait_fire) begin
                wait_live_q[wait_free_idx]<=1'b1;
                wait_q[wait_free_idx]<='{wait_ctx_i,wait_warp_i,wait_epoch_i,
                                         wait_store_i,wait_tag_i};
                pending_q[wait_free_idx]<=finish_fire && finish_match ?
                    snapshot & ~(OPERATIONS'(1) << finish_idx) : snapshot;
                status_q[wait_free_idx]<=
                    ((context_valid_q[wait_ctx_i] &&
                      context_epoch_q[wait_ctx_i] == wait_epoch_i &&
                      poisoned_q[wait_ctx_i][wait_poison_idx]) ||
                     (finish_failed && finish_ctx_i == wait_ctx_i &&
                      finish_epoch_i == wait_epoch_i &&
                      finish_warp_i == wait_warp_i &&
                      finish_store_i == wait_store_i)) ? ERR_DEPENDENCY : OK;
                predecessors_q[wait_free_idx]<=select_fire ?
                    predecessor & ~(WAITS'(1) << ready_idx) : predecessor;
            end
            // A successfully recreated context may reuse the same 16-bit
            // epoch. Old completed failures must not leak into that lifetime.
            if (clear_ctx_vld_i)
                begin
                    poisoned_q[clear_ctx_i]<='0;
                    context_valid_q[clear_ctx_i]<=1'b0;
                end
        end
    end
    initial begin
        if (OPERATIONS<1 || WAITS<1) $error("Invalid TMEM wait capacity");
    end
endmodule
`default_nettype wire
