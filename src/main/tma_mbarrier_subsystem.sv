// ============================================================================
// File Name   : tma_mbarrier_subsystem.sv
// Date        : 2026-08-27
// Description : Integrated TMA engine and memory-backed mbarrier unit.
// ============================================================================

`default_nettype none

module tma_mbarrier_subsystem #(
    parameter int unsigned ADDR_W             = 64,
    parameter int unsigned SMEM_ADDR_W        = 32,
    parameter int unsigned CMD_QUEUE_DEPTH    = 8,
    parameter int unsigned DESC_CACHE_ENTRIES = 4,
    parameter int unsigned MSHR_ENTRIES       = 16,
    parameter int unsigned BAR_CACHE_ENTRIES  = 4,
    parameter int unsigned WAIT_ENTRIES       = 32,
    parameter int unsigned WRITE_BUF_DEPTH    = 8,
    parameter int unsigned GMEM_ID_W          = 5,
    parameter int unsigned SMEM_ID_W          = 6
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         tma_cmd_vld_i,
    output wire                         tma_cmd_rdy_o,
    input  wire [2:0]                   tma_cmd_opcode_i,
    input  wire [15:0]                  tma_cmd_tag_i,
    input  wire [ADDR_W-1:0]            tma_cmd_desc_ptr_i,
    input  wire [159:0]                 tma_cmd_coord_i,
    input  wire [SMEM_ADDR_W-1:0]       tma_cmd_smem_addr_i,
    input  wire [ADDR_W-1:0]            tma_cmd_linear_addr_i,
    input  wire [31:0]                  tma_cmd_linear_bytes_i,
    input  wire [ADDR_W-1:0]            tma_cmd_barrier_addr_i,

    output wire                         tma_rsp_vld_o,
    input  wire                         tma_rsp_rdy_i,
    output wire [15:0]                  tma_rsp_tag_o,
    output wire [7:0]                   tma_rsp_status_o,
    output wire [63:0]                  tma_rsp_bytes_o,

    input  wire                         bar_cmd_vld_i,
    output wire                         bar_cmd_rdy_o,
    input  wire [2:0]                   bar_cmd_opcode_i,
    input  wire [15:0]                  bar_cmd_tag_i,
    input  wire [ADDR_W-1:0]            bar_cmd_addr_i,
    input  wire [15:0]                  bar_cmd_arrive_count_i,
    input  wire [63:0]                  bar_cmd_tx_bytes_i,
    input  wire                         bar_cmd_phase_token_i,

    output wire                         bar_rsp_vld_o,
    input  wire                         bar_rsp_rdy_i,
    output wire [15:0]                  bar_rsp_tag_o,
    output wire [7:0]                   bar_rsp_status_o,
    output wire                         bar_rsp_phase_o,
    output wire                         bar_rsp_locked_o,

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

    logic                        smem_grant_bar;
    logic                        smem_bar_turn_q;
    wire                         smem_req_fire;
    wire                         bar_mem_addr_upper_nonzero;

    assign smem_grant_bar = bar_mem_req_vld &&
                            (!tma_smem_req_vld || smem_bar_turn_q);
    assign smem_req_vld_o = smem_grant_bar ? bar_mem_req_vld : tma_smem_req_vld;
    assign smem_req_write_o = smem_grant_bar ? bar_mem_req_write : tma_smem_req_write;
    assign smem_req_addr_o = smem_grant_bar ?
        bar_mem_req_addr[SMEM_ADDR_W-1:0] : tma_smem_req_addr;
    assign smem_req_data_o = smem_grant_bar ? bar_mem_req_data : tma_smem_req_data;
    assign smem_req_mask_o = smem_grant_bar ? bar_mem_req_mask : tma_smem_req_mask;
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
        .tma_cmd_vld_i          (tma_cmd_vld_i),
        .tma_cmd_rdy_o          (tma_cmd_rdy_o),
        .tma_cmd_opcode_i       (tma_cmd_opcode_i),
        .tma_cmd_tag_i          (tma_cmd_tag_i),
        .tma_cmd_desc_ptr_i     (tma_cmd_desc_ptr_i),
        .tma_cmd_coord_i        (tma_cmd_coord_i),
        .tma_cmd_smem_addr_i    (tma_cmd_smem_addr_i),
        .tma_cmd_linear_addr_i  (tma_cmd_linear_addr_i),
        .tma_cmd_linear_bytes_i (tma_cmd_linear_bytes_i),
        .tma_cmd_barrier_addr_i (tma_cmd_barrier_addr_i),
        .tma_rsp_vld_o          (tma_rsp_vld_o),
        .tma_rsp_rdy_i          (tma_rsp_rdy_i),
        .tma_rsp_tag_o          (tma_rsp_tag_o),
        .tma_rsp_status_o       (tma_rsp_status_o),
        .tma_rsp_bytes_o        (tma_rsp_bytes_o),
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

    mbarrier_unit #(
        .ADDR_W          (ADDR_W),
        .CACHE_ENTRIES   (BAR_CACHE_ENTRIES),
        .WAIT_ENTRIES    (WAIT_ENTRIES),
        .WRITE_BUF_DEPTH (WRITE_BUF_DEPTH),
        .MEM_ID_W        (BAR_MEM_ID_W)
    ) u_mbarrier_unit (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .bar_cmd_vld_i          (bar_cmd_vld_i),
        .bar_cmd_rdy_o          (bar_cmd_rdy_o),
        .bar_cmd_opcode_i       (bar_cmd_opcode_i),
        .bar_cmd_tag_i          (bar_cmd_tag_i),
        .bar_cmd_addr_i         (bar_cmd_addr_i),
        .bar_cmd_arrive_count_i (bar_cmd_arrive_count_i),
        .bar_cmd_tx_bytes_i     (bar_cmd_tx_bytes_i),
        .bar_cmd_phase_token_i  (bar_cmd_phase_token_i),
        .bar_rsp_vld_o          (bar_rsp_vld_o),
        .bar_rsp_rdy_i          (bar_rsp_rdy_i),
        .bar_rsp_tag_o          (bar_rsp_tag_o),
        .bar_rsp_status_o       (bar_rsp_status_o),
        .bar_rsp_phase_o        (bar_rsp_phase_o),
        .bar_rsp_locked_o       (bar_rsp_locked_o),
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
