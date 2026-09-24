// ============================================================================
// File Name   : tma_mbarrier_subsystem.sv
// Date        : 2026-08-27
// Description : Integrated TMA engine and memory-backed mbarrier unit.
// ============================================================================

`default_nettype none

module tma_mbarrier_subsystem #(
    parameter int unsigned BAR_ASYNC_ENTRIES = 16,
    parameter int unsigned ADDR_W             = 64,
    parameter int unsigned SMEM_ADDR_W        = 32,
    parameter int unsigned CMD_QUEUE_DEPTH    = 8,
    parameter int unsigned DESC_CACHE_ENTRIES = 4,
    parameter int unsigned MSHR_ENTRIES       = 16,
    parameter int unsigned BAR_CACHE_ENTRIES  = 4,
    parameter int unsigned WAIT_ENTRIES       = 32,
    parameter int unsigned WRITE_BUF_DEPTH    = 8,
    parameter int unsigned GMEM_ID_W          = 5,
    parameter int unsigned SMEM_ID_W          = 6,
    parameter int unsigned BAR_CLOCK_PERIOD_NS = 10,
    parameter int unsigned BAR_WAIT_DEFAULT_CYCLES = 64
) (

    input tma_mbarrier_pkg::tma_cmd_t tma_cmd_i,
    output tma_mbarrier_pkg::tma_rsp_t tma_rsp_o,
    output tma_mbarrier_pkg::bw_mem_attr_t gmem_req_attr_o,
    output tma_mbarrier_pkg::bw_mem_attr_t smem_req_attr_o,
    output wire tma_order_req_vld_o,
    input wire tma_order_req_rdy_i,
    output tma_mbarrier_pkg::bw_order_req_t tma_order_req_o,
    input wire tma_order_rsp_vld_i,
    output wire tma_order_rsp_rdy_o,
    input tma_mbarrier_pkg::bw_order_rsp_t tma_order_rsp_i,


    input wire tc_arrive_vld_i,
    output wire tc_arrive_rdy_o,
    input tma_mbarrier_pkg::bar_cmd_t tc_arrive_i,
    output wire tc_arrive_rsp_vld_o,
    input wire tc_arrive_rsp_rdy_i,
    output tma_mbarrier_pkg::bar_rsp_t tc_arrive_rsp_o,
    input tma_mbarrier_pkg::bar_cmd_t bar_cmd_i,
    output tma_mbarrier_pkg::bar_rsp_t bar_rsp_o,
    input wire async_cpl_req_vld_i,
    output wire async_cpl_req_rdy_o,
    input tma_mbarrier_pkg::bw_async_req_t async_cpl_req_i,
    input wire async_req_vld_i,
    output wire async_req_rdy_o,
    input tma_mbarrier_pkg::bw_async_req_t async_req_i,
    output wire async_rsp_vld_o,
    input wire async_rsp_rdy_i,
    output tma_mbarrier_pkg::bw_async_rsp_t async_rsp_o,
    input wire report_req_vld_i,
    output wire report_req_rdy_o,
    input tma_mbarrier_pkg::bar_report_req_t report_req_i,
    output wire report_rsp_vld_o,
    input wire report_rsp_rdy_i,
    output tma_mbarrier_pkg::bar_rsp_t report_rsp_o,
    output wire bar_order_req_vld_o,
    input wire bar_order_req_rdy_i,
    output tma_mbarrier_pkg::bw_order_req_t bar_order_req_o,
    input wire bar_order_rsp_vld_i,
    output wire bar_order_rsp_rdy_o,
    input tma_mbarrier_pkg::bw_order_rsp_t bar_order_rsp_i,


    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         tma_cmd_vld_i,
    output wire                         tma_cmd_rdy_o,


    output wire                         tma_rsp_vld_o,
    input  wire                         tma_rsp_rdy_i,

    input  wire                         bar_cmd_vld_i,
    output wire                         bar_cmd_rdy_o,

    output wire                         bar_rsp_vld_o,
    input  wire                         bar_rsp_rdy_i,

    output wire                         gmem_req_vld_o,
    input  wire                         gmem_req_rdy_i,
    output wire                         gmem_req_write_o,
    output wire [ADDR_W-1:0]            gmem_req_addr_o,
    output wire [1023:0]                gmem_req_data_o,
    output wire [127:0]                 gmem_req_mask_o,
    output wire [GMEM_ID_W-1:0]         gmem_req_id_o,
    input  wire                         gmem_rsp_vld_i,
    output wire                         gmem_rsp_rdy_o,
    input  wire [1023:0]                gmem_rsp_data_i,
    input  wire [1:0]                   gmem_rsp_status_i,
    input  wire [GMEM_ID_W-1:0]         gmem_rsp_id_i,

    output wire                         smem_req_vld_o,
    input  wire                         smem_req_rdy_i,
    output wire                         smem_req_write_o,
    output wire [SMEM_ADDR_W-1:0]       smem_req_addr_o,
    output wire [255:0]                 smem_req_data_o,
    output wire [31:0]                  smem_req_mask_o,
    output wire [SMEM_ID_W-1:0]         smem_req_id_o,
    input  wire                         smem_rsp_vld_i,
    output wire                         smem_rsp_rdy_o,
    input  wire [255:0]                 smem_rsp_data_i,
    input  wire [1:0]                   smem_rsp_status_i,
    input  wire [SMEM_ID_W-1:0]         smem_rsp_id_i
);

    localparam int unsigned TMA_SMEM_ID_W = (MSHR_ENTRIES <= 1) ? 1 : $clog2(MSHR_ENTRIES);
    localparam int unsigned BAR_MEM_ID_W = 2;

    wire                         tma_smem_req_vld;
    wire                         tma_smem_req_rdy;
    wire                         tma_smem_req_write;
    wire [SMEM_ADDR_W-1:0]       tma_smem_req_addr;
    wire [255:0]                 tma_smem_req_data;
    wire [31:0]                  tma_smem_req_mask;
    wire [TMA_SMEM_ID_W-1:0]     tma_smem_req_id;
    wire                         tma_smem_rsp_vld;
    wire                         tma_smem_rsp_rdy;
    wire [TMA_SMEM_ID_W-1:0]     tma_smem_rsp_id;

    wire                         bar_mem_req_vld;
    wire                         bar_mem_req_rdy;
    wire                         bar_mem_req_write;
    wire [ADDR_W-1:0]            bar_mem_req_addr;
    wire [255:0]                 bar_mem_req_data;
    wire [31:0]                  bar_mem_req_mask;
    wire [BAR_MEM_ID_W-1:0]      bar_mem_req_id;
    wire                         bar_mem_rsp_vld;
    wire                         bar_mem_rsp_rdy;
    wire [BAR_MEM_ID_W-1:0]      bar_mem_rsp_id;

    wire                         tx_cpl_vld;
    wire                         tx_cpl_rdy;
    wire [15:0]                  tx_cpl_tag;
    wire [ADDR_W-1:0]            tx_cpl_addr;
    wire [63:0]                  tx_cpl_bytes;
    wire                         tx_rsp_vld;
    wire                         tx_rsp_rdy;
    wire [15:0]                  tx_rsp_tag;
    wire [7:0]                   tx_rsp_status;
    wire                         tx_rsp_phase;

    tma_mbarrier_pkg::bw_mem_attr_t tma_smem_req_attr, bar_mem_attr;
    always_comb begin
        bar_mem_attr = '0;
        bar_mem_attr.kind = bar_mem_req_write ? tma_mbarrier_pkg::BW_MEM_WRITE : tma_mbarrier_pkg::BW_MEM_READ;
        bar_mem_attr.dtype = tma_mbarrier_pkg::TMA_TYPE_U64;
        bar_mem_attr.proxy = tma_mbarrier_pkg::BW_PROXY_GENERIC;
    end
    assign smem_req_attr_o = smem_grant_bar ? bar_mem_attr : tma_smem_req_attr;
    logic smem_hold_q, smem_hold_bar_q;
    logic                        smem_grant_bar;
    logic                        smem_bar_turn_q;
    wire                         smem_req_fire;
    wire                         bar_mem_addr_upper_nonzero;

    assign smem_grant_bar = smem_hold_q ? smem_hold_bar_q :
        (bar_mem_req_vld && (!tma_smem_req_vld || smem_bar_turn_q));
    assign smem_req_vld_o = smem_grant_bar ? bar_mem_req_vld : tma_smem_req_vld;
    assign smem_req_write_o = smem_grant_bar ? bar_mem_req_write : tma_smem_req_write;
    assign smem_req_addr_o = smem_grant_bar ?
        bar_mem_req_addr[SMEM_ADDR_W-1:0] : tma_smem_req_addr;
    assign smem_req_data_o = smem_grant_bar ? bar_mem_req_data : tma_smem_req_data;
    assign smem_req_mask_o = smem_grant_bar ? (bar_mem_req_write ? bar_mem_req_mask : 32'hffff_ffff) : tma_smem_req_mask;
    assign smem_req_id_o = smem_grant_bar ?
        {1'b1, {(SMEM_ID_W-BAR_MEM_ID_W-1){1'b0}}, bar_mem_req_id} :
        {1'b0, {(SMEM_ID_W-TMA_SMEM_ID_W-1){1'b0}}, tma_smem_req_id};
    assign bar_mem_req_rdy = smem_req_rdy_i && smem_grant_bar;
    assign tma_smem_req_rdy = smem_req_rdy_i && !smem_grant_bar;
    assign smem_req_fire = smem_req_vld_o && smem_req_rdy_i;
    assign bar_mem_addr_upper_nonzero =
        |bar_mem_req_addr[ADDR_W-1:SMEM_ADDR_W];

    assign bar_mem_rsp_vld = smem_rsp_vld_i && smem_rsp_id_i[SMEM_ID_W-1];
    assign tma_smem_rsp_vld = smem_rsp_vld_i && !smem_rsp_id_i[SMEM_ID_W-1];
    assign bar_mem_rsp_id = smem_rsp_id_i[BAR_MEM_ID_W-1:0];
    assign tma_smem_rsp_id = smem_rsp_id_i[TMA_SMEM_ID_W-1:0];
    assign smem_rsp_rdy_o = smem_rsp_id_i[SMEM_ID_W-1] ?
                            bar_mem_rsp_rdy : tma_smem_rsp_rdy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            smem_bar_turn_q <= 1'b0;
        end else if (smem_req_fire && bar_mem_req_vld && tma_smem_req_vld) begin
            smem_bar_turn_q <= ~smem_bar_turn_q;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin smem_hold_q <= 1'b0; smem_hold_bar_q <= 1'b0; end
        else begin
            if (smem_req_vld_o && !smem_req_rdy_i) begin
                smem_hold_q <= 1'b1; smem_hold_bar_q <= smem_grant_bar;
            end else if (smem_req_fire) smem_hold_q <= 1'b0;
        end
    end
    tma_engine #(
        .ADDR_W             (ADDR_W),
        .SMEM_ADDR_W        (SMEM_ADDR_W),
        .CMD_QUEUE_DEPTH    (CMD_QUEUE_DEPTH),
        .DESC_CACHE_ENTRIES (DESC_CACHE_ENTRIES),
        .MSHR_ENTRIES       (MSHR_ENTRIES),
        .GMEM_ID_W          (GMEM_ID_W),
        .SMEM_ID_W          (TMA_SMEM_ID_W)
    ) u_tma_engine (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .tma_cmd_i(tma_cmd_i),
        .gmem_req_attr_o(gmem_req_attr_o),
        .tma_order_req_vld_o(tma_order_req_vld_o),
        .tma_order_req_rdy_i(tma_order_req_rdy_i),
        .tma_order_req_o(tma_order_req_o),
        .tma_order_rsp_vld_i(tma_order_rsp_vld_i),
        .tma_order_rsp_rdy_o(tma_order_rsp_rdy_o),
        .tma_order_rsp_i(tma_order_rsp_i),
        .smem_req_attr_o(tma_smem_req_attr),

        .tma_cmd_vld_i          (tma_cmd_vld_i),
        .tma_cmd_rdy_o          (tma_cmd_rdy_o),

        .tma_rsp_o(tma_rsp_o),
        .tma_rsp_vld_o          (tma_rsp_vld_o),
        .tma_rsp_rdy_i          (tma_rsp_rdy_i),
        .gmem_req_vld_o         (gmem_req_vld_o),
        .gmem_req_rdy_i         (gmem_req_rdy_i),
        .gmem_req_write_o       (gmem_req_write_o),
        .gmem_req_addr_o        (gmem_req_addr_o),
        .gmem_req_data_o        (gmem_req_data_o),
        .gmem_req_mask_o        (gmem_req_mask_o),
        .gmem_req_id_o          (gmem_req_id_o),
        .gmem_rsp_vld_i         (gmem_rsp_vld_i),
        .gmem_rsp_rdy_o         (gmem_rsp_rdy_o),
        .gmem_rsp_data_i        (gmem_rsp_data_i),
        .gmem_rsp_status_i      (gmem_rsp_status_i),
        .gmem_rsp_id_i          (gmem_rsp_id_i),
        .smem_req_vld_o         (tma_smem_req_vld),
        .smem_req_rdy_i         (tma_smem_req_rdy),
        .smem_req_write_o       (tma_smem_req_write),
        .smem_req_addr_o        (tma_smem_req_addr),
        .smem_req_data_o        (tma_smem_req_data),
        .smem_req_mask_o        (tma_smem_req_mask),
        .smem_req_id_o          (tma_smem_req_id),
        .smem_rsp_vld_i         (tma_smem_rsp_vld),
        .smem_rsp_rdy_o         (tma_smem_rsp_rdy),
        .smem_rsp_data_i        (smem_rsp_data_i),
        .smem_rsp_status_i      (smem_rsp_status_i),
        .smem_rsp_id_i          (tma_smem_rsp_id),
        .tx_cpl_vld_o           (tx_cpl_vld),
        .tx_cpl_rdy_i           (tx_cpl_rdy),
        .tx_cpl_tag_o           (tx_cpl_tag),
        .tx_cpl_addr_o          (tx_cpl_addr),
        .tx_cpl_bytes_o         (tx_cpl_bytes),
        .tx_rsp_vld_i           (tx_rsp_vld),
        .tx_rsp_rdy_o           (tx_rsp_rdy),
        .tx_rsp_tag_i           (tx_rsp_tag),
        .tx_rsp_status_i        (tx_rsp_status),
        .tx_rsp_phase_i         (tx_rsp_phase)
    );

    mbarrier_frontend #(
        .ASYNC_ENTRIES(BAR_ASYNC_ENTRIES),
        .ADDR_W          (ADDR_W),
        .CACHE_ENTRIES   (BAR_CACHE_ENTRIES),
        .WAIT_ENTRIES    (WAIT_ENTRIES),
        .WRITE_BUF_DEPTH (WRITE_BUF_DEPTH),
        .MEM_ID_W        (BAR_MEM_ID_W),
        .CLOCK_PERIOD_NS (BAR_CLOCK_PERIOD_NS),
        .WAIT_DEFAULT_CYCLES (BAR_WAIT_DEFAULT_CYCLES)
    ) u_mbarrier_unit (
        .clk                    (clk),
        .rst_n                  (rst_n),

        .async_cpl_req_vld_i(async_cpl_req_vld_i), .async_cpl_req_rdy_o(async_cpl_req_rdy_o),
        .async_cpl_req_i(async_cpl_req_i), .async_req_vld_i(async_req_vld_i),
        .async_req_rdy_o(async_req_rdy_o),
        .async_req_i(async_req_i),
        .async_rsp_vld_o(async_rsp_vld_o),
        .async_rsp_rdy_i(async_rsp_rdy_i),
        .async_rsp_o(async_rsp_o),
        .report_req_vld_i(report_req_vld_i),
        .report_req_rdy_o(report_req_rdy_o),
        .report_req_i(report_req_i),
        .report_rsp_vld_o(report_rsp_vld_o),
        .report_rsp_rdy_i(report_rsp_rdy_i),
        .report_rsp_o(report_rsp_o),
        .order_req_vld_o(bar_order_req_vld_o),
        .order_req_rdy_i(bar_order_req_rdy_i),
        .order_req_o(bar_order_req_o),
        .order_rsp_vld_i(bar_order_rsp_vld_i),
        .order_rsp_rdy_o(bar_order_rsp_rdy_o),
        .order_rsp_i(bar_order_rsp_i),
        .tc_arrive_vld_i(tc_arrive_vld_i), .tc_arrive_rdy_o(tc_arrive_rdy_o),
        .tc_arrive_i(tc_arrive_i), .tc_arrive_rsp_vld_o(tc_arrive_rsp_vld_o),
        .tc_arrive_rsp_rdy_i(tc_arrive_rsp_rdy_i), .tc_arrive_rsp_o(tc_arrive_rsp_o),
        .bar_cmd_i(bar_cmd_i), .bar_rsp_o(bar_rsp_o),
        .bar_cmd_vld_i          (bar_cmd_vld_i),
        .bar_cmd_rdy_o          (bar_cmd_rdy_o),

        .bar_rsp_vld_o          (bar_rsp_vld_o),
        .bar_rsp_rdy_i          (bar_rsp_rdy_i),

        .tx_cpl_vld_i           (tx_cpl_vld),
        .tx_cpl_rdy_o           (tx_cpl_rdy),
        .tx_cpl_tag_i           (tx_cpl_tag),
        .tx_cpl_addr_i          (tx_cpl_addr),
        .tx_cpl_bytes_i         (tx_cpl_bytes),
        .tx_rsp_vld_o           (tx_rsp_vld),
        .tx_rsp_rdy_i           (tx_rsp_rdy),
        .tx_rsp_tag_o           (tx_rsp_tag),
        .tx_rsp_status_o        (tx_rsp_status),
        .tx_rsp_phase_o         (tx_rsp_phase),
        .mem_req_vld_o          (bar_mem_req_vld),
        .mem_req_rdy_i          (bar_mem_req_rdy),
        .mem_req_write_o        (bar_mem_req_write),
        .mem_req_addr_o         (bar_mem_req_addr),
        .mem_req_data_o         (bar_mem_req_data),
        .mem_req_mask_o         (bar_mem_req_mask),
        .mem_req_id_o           (bar_mem_req_id),
        .mem_rsp_vld_i          (bar_mem_rsp_vld),
        .mem_rsp_rdy_o          (bar_mem_rsp_rdy),
        .mem_rsp_data_i         (smem_rsp_data_i),
        .mem_rsp_status_i       (smem_rsp_status_i),
        .mem_rsp_id_i           (bar_mem_rsp_id)
    );

    initial begin
        if (SMEM_ID_W <= TMA_SMEM_ID_W)
            $error("SMEM_ID_W must reserve one source bit");
        if (SMEM_ID_W <= BAR_MEM_ID_W)
            $error("SMEM_ID_W must reserve one source bit for mbarrier");
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && bar_mem_req_vld) begin
            assert (!bar_mem_addr_upper_nonzero)
                else $error("mbarrier backing address exceeds SMEM address width");
        end
    end
`endif

endmodule

`default_nettype wire
