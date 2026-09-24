// Connect this controller's bar_* channel to the independent tc_arrive_* input
// of tma_mbarrier_subsystem. Execution engines register before dispatch and send
// complete_i only after the last write acknowledgment (or an execution fault).
`default_nettype none
module tcgen05_async_completion #(
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
    output wire bar_vld_o,
    input wire bar_rdy_i,
    output tma_mbarrier_pkg::bar_cmd_t bar_o,
    input wire bar_rsp_vld_i,
    output wire bar_rsp_rdy_o,
    input tma_mbarrier_pkg::bar_rsp_t bar_rsp_i,
    output wire event_vld_o,
    input wire event_rdy_i,
    output blackwell_async_pkg::async_event_t event_o,
    output wire protocol_error_o
);
    wire arrival_vld, arrival_rdy;
    wire [7:0] arrival_status;
    blackwell_async_pkg::tc_commit_t arrival;
    tcgen05_completion_tracker #(.OPERATIONS(OPERATIONS), .COMMITS(COMMITS)) u_tracker (
        .clk(clk), .rst_n(rst_n), .register_vld_i(register_vld_i),
        .register_rdy_o(register_rdy_o), .register_i(register_i),
        .complete_vld_i(complete_vld_i), .complete_rdy_o(complete_rdy_o), .complete_i(complete_i),
        .commit_vld_i(commit_vld_i), .commit_rdy_o(commit_rdy_o), .commit_i(commit_i),
        .arrival_vld_o(arrival_vld), .arrival_rdy_i(arrival_rdy), .arrival_o(arrival),
        .arrival_status_o(arrival_status), .protocol_error_o(protocol_error_o)
    );
    tcgen05_commit_bridge u_bridge (
        .clk(clk), .rst_n(rst_n), .commit_vld_i(arrival_vld), .commit_rdy_o(arrival_rdy),
        .commit_i(arrival), .commit_status_i(arrival_status),
        .bar_vld_o(bar_vld_o), .bar_rdy_i(bar_rdy_i), .bar_o(bar_o),
        .bar_rsp_vld_i(bar_rsp_vld_i), .bar_rsp_rdy_o(bar_rsp_rdy_o), .bar_rsp_i(bar_rsp_i),
        .event_vld_o(event_vld_o), .event_rdy_i(event_rdy_i), .event_o(event_o)
    );
endmodule
`default_nettype wire
