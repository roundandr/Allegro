// Independent TC completion credit. Software wait-table exhaustion must never
// prevent the TC arrival that satisfies those waits from reaching mbarrier.
`default_nettype none
module mbarrier_tc_arbiter (
    input wire clk, rst_n,
    input wire sw_vld_i,
    output wire sw_rdy_o,
    input tma_mbarrier_pkg::bar_cmd_t sw_i,
    output wire sw_rsp_vld_o,
    input wire sw_rsp_rdy_i,
    output tma_mbarrier_pkg::bar_rsp_t sw_rsp_o,
    input wire tc_vld_i,
    output wire tc_rdy_o,
    input tma_mbarrier_pkg::bar_cmd_t tc_i,
    output wire tc_rsp_vld_o,
    input wire tc_rsp_rdy_i,
    output tma_mbarrier_pkg::bar_rsp_t tc_rsp_o,
    output wire core_vld_o,
    input wire core_rdy_i,
    output tma_mbarrier_pkg::bar_cmd_t core_o,
    output wire core_tc_vld_o,
    input wire core_tc_rdy_i,
    output tma_mbarrier_pkg::bar_cmd_t core_tc_o,
    input wire core_rsp_vld_i,
    output wire core_rsp_rdy_o,
    input tma_mbarrier_pkg::bar_rsp_t core_rsp_i
);
    import tma_mbarrier_pkg::*;
    logic vld_q, tc_busy_q, tc_rsp_vld_q;
    bar_cmd_t cmd_q;
    bar_rsp_t tc_rsp_q;
    logic [15:0] tc_tag_q;
    logic [9:0] tc_issuer_q;
    assign tc_rdy_o = !tc_busy_q;
    // Never multiplex TC behind the software skid register: the state unit
    // arbitrates these channels separately, including when TRY_WAIT is blocked.
    assign sw_rdy_o = core_rdy_i;
    assign core_vld_o = sw_vld_i;
    assign core_o = sw_i;
    assign core_tc_vld_o = vld_q;
    assign core_tc_o = cmd_q;
    assign sw_rsp_vld_o = core_rsp_vld_i && !core_rsp_i.tag[15];
    assign sw_rsp_o = core_rsp_i;
    assign core_rsp_rdy_o = core_rsp_i.tag[15] ? !tc_rsp_vld_q : sw_rsp_rdy_i;
    assign tc_rsp_vld_o = tc_rsp_vld_q;
    assign tc_rsp_o = tc_rsp_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_q <= 1'b0; tc_busy_q <= 1'b0;
            tc_rsp_vld_q <= 1'b0; cmd_q <= '0; tc_rsp_q <= '0;
            tc_tag_q <= '0; tc_issuer_q <= '0;
        end else begin
            if (vld_q && core_tc_rdy_i) vld_q <= 1'b0;
            if (tc_vld_i && tc_rdy_o) begin
                vld_q <= 1'b1;
                cmd_q <= '0;
                cmd_q.opcode <= tc_i.opcode == MBAR_OP_FAULT ? MBAR_OP_FAULT : MBAR_OP_ARRIVE;
                cmd_q.tag <= 16'h8000;
                cmd_q.addr <= tc_i.addr;
                cmd_q.arrive_count <= 32'd1;
                tc_tag_q <= tc_i.tag;
                tc_issuer_q <= tc_i.issuer;
                tc_busy_q <= 1'b1;
            end
            if (core_rsp_vld_i && core_rsp_rdy_o && core_rsp_i.tag[15]) begin
                tc_rsp_q <= core_rsp_i;
                tc_rsp_q.tag <= tc_tag_q;
                tc_rsp_q.issuer <= tc_issuer_q;
                tc_rsp_vld_q <= 1'b1;
            end
            if (tc_rsp_vld_q && tc_rsp_rdy_i) begin
                tc_rsp_vld_q <= 1'b0;
                tc_busy_q <= 1'b0;
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (rst_n && sw_vld_i && sw_rdy_o)
        assert (!sw_i.tag[15]) else $error("Software internal tag uses reserved TC bit");
`endif
endmodule
`default_nettype wire
