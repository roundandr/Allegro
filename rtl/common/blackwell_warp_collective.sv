// Actual 32-thread rendezvous for .sync.aligned instructions. One per-thread
// operand packet is collected for each warp; no warp_converged boolean can
// substitute for the 32 handshakes. The execution engine explicitly releases
// a warp after the instruction's specified issue/completion boundary.
`default_nettype none
module blackwell_warp_collective #(
    parameter int unsigned WARPS = 32,
    parameter int unsigned PAYLOAD_W = 256
) (
    input wire clk, rst_n,
    input wire lane_vld_i,
    output wire lane_rdy_o,
    input wire [4:0] lane_warp_i, lane_thread_i,
    input wire [31:0] lane_ticket_i,
    input wire [15:0] lane_epoch_i,
    input wire [PAYLOAD_W-1:0] lane_payload_i,
    output wire issue_vld_o,
    input wire issue_rdy_i,
    output wire [4:0] issue_warp_o,
    output wire [31:0] issue_ticket_o,
    output wire [15:0] issue_epoch_o,
    output wire [PAYLOAD_W-1:0] issue_payload_o,
    input wire release_vld_i,
    output wire release_rdy_o,
    input wire [4:0] release_warp_i,
    input wire [31:0] release_ticket_i,
    input wire [15:0] release_epoch_i,
    input wire [7:0] release_status_i,
    output wire done_vld_o,
    input wire done_rdy_i,
    output wire [4:0] done_warp_o,
    output wire [31:0] done_ticket_o,
    output wire [15:0] done_epoch_o,
    output wire [7:0] done_status_o,
    output logic protocol_error_o
);
    logic [31:0] arrived_q [WARPS], ticket_q [WARPS];
    logic [15:0] epoch_q [WARPS];
    logic [PAYLOAD_W-1:0] payload_q [WARPS];
    logic [7:0] status_q [WARPS];
    logic [WARPS-1:0] mismatch_q, issued_q, released_q;
    logic [4:0] issue_turn_q,done_turn_q,issue_hold_warp_q,done_hold_warp_q;
    logic issue_hold_q,done_hold_q;
    integer issue_sel,done_sel;
    logic release_match;
    assign lane_rdy_o = int'(lane_warp_i) < WARPS && !arrived_q[lane_warp_i][lane_thread_i];
    assign issue_vld_o = issue_sel >= 0;
    assign issue_warp_o = issue_sel >= 0 ? 5'(issue_sel) : 5'd0;
    assign issue_ticket_o = issue_sel >= 0 ? ticket_q[issue_sel] : 32'd0;
    assign issue_epoch_o = issue_sel >= 0 ? epoch_q[issue_sel] : 16'd0;
    assign issue_payload_o = issue_sel >= 0 ? payload_q[issue_sel] : '0;
    assign release_rdy_o = 1'b1;
    assign done_vld_o = done_sel >= 0;
    assign done_warp_o = done_sel >= 0 ? 5'(done_sel) : 5'd0;
    assign done_ticket_o = done_sel >= 0 ? ticket_q[done_sel] : 32'd0;
    assign done_epoch_o = done_sel >= 0 ? epoch_q[done_sel] : 16'd0;
    assign done_status_o = done_sel >= 0 ? (mismatch_q[done_sel] ? 8'd1 : status_q[done_sel]) : 8'd0;
    always_comb begin
        issue_sel = -1; done_sel = -1;
        for (int delta = 0; delta < WARPS; delta++) begin
            if (issue_sel < 0 && (&arrived_q[(int'(issue_turn_q)+delta)%WARPS]) &&
                !issued_q[(int'(issue_turn_q)+delta)%WARPS] && !mismatch_q[(int'(issue_turn_q)+delta)%WARPS])
                issue_sel = (int'(issue_turn_q)+delta)%WARPS;
            if (done_sel < 0 && (&arrived_q[(int'(done_turn_q)+delta)%WARPS]) &&
                (released_q[(int'(done_turn_q)+delta)%WARPS] || mismatch_q[(int'(done_turn_q)+delta)%WARPS]))
                done_sel = (int'(done_turn_q)+delta)%WARPS;
        end
        if (issue_hold_q) issue_sel = int'(issue_hold_warp_q);
        if (done_hold_q) done_sel = int'(done_hold_warp_q);
        release_match = 1'b0;
        if (int'(release_warp_i) < WARPS)
            release_match = issued_q[release_warp_i] && !released_q[release_warp_i] &&
                ticket_q[release_warp_i] == release_ticket_i && epoch_q[release_warp_i] == release_epoch_i;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mismatch_q <= '0; issued_q <= '0; released_q <= '0; protocol_error_o <= 1'b0;
            issue_turn_q <= '0; done_turn_q <= '0; issue_hold_q <= 1'b0; done_hold_q <= 1'b0;
            issue_hold_warp_q <= '0; done_hold_warp_q <= '0;
            for (int w = 0; w < WARPS; w++) begin arrived_q[w] <= '0; status_q[w] <= '0; end
        end else begin
            if (lane_vld_i && int'(lane_warp_i) >= WARPS) protocol_error_o <= 1'b1;
            if (lane_vld_i && lane_rdy_o) begin
                arrived_q[lane_warp_i][lane_thread_i] <= 1'b1;
                if (arrived_q[lane_warp_i] == 0) begin
                    ticket_q[lane_warp_i] <= lane_ticket_i; epoch_q[lane_warp_i] <= lane_epoch_i;
                    payload_q[lane_warp_i] <= lane_payload_i;
                end else if (ticket_q[lane_warp_i] != lane_ticket_i || epoch_q[lane_warp_i] != lane_epoch_i ||
                             payload_q[lane_warp_i] != lane_payload_i) mismatch_q[lane_warp_i] <= 1'b1;
            end
            if (issue_sel >= 0) begin
                if (issue_rdy_i) begin
                    issued_q[issue_sel] <= 1'b1; issue_hold_q <= 1'b0;
                    issue_turn_q <= issue_sel == WARPS-1 ? '0 : 5'(issue_sel+1);
                end else begin issue_hold_q <= 1'b1; issue_hold_warp_q <= 5'(issue_sel); end
            end
            if (release_vld_i) begin
                if (!release_match) protocol_error_o <= 1'b1;
                else begin released_q[release_warp_i] <= 1'b1; status_q[release_warp_i] <= release_status_i; end
            end
            if (done_sel >= 0) begin
                if (done_rdy_i) begin
                    arrived_q[done_sel] <= '0; mismatch_q[done_sel] <= 1'b0;
                    issued_q[done_sel] <= 1'b0; released_q[done_sel] <= 1'b0; status_q[done_sel] <= '0;
                    done_hold_q <= 1'b0; done_turn_q <= done_sel == WARPS-1 ? '0 : 5'(done_sel+1);
                end else begin done_hold_q <= 1'b1; done_hold_warp_q <= 5'(done_sel); end
            end
        end
    end
    initial if (WARPS < 1 || WARPS > 32 || PAYLOAD_W < 1) $error("Invalid collective configuration");
endmodule
`default_nettype wire
