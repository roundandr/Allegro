// ============================================================================
// File Name   : tma_engine.sv
// Date        : 2026-08-27
// Description : Single-CTA command dispatch and per-thread bulk-group tracking.
//
// Copy generation is delegated to tma_copy_engine. Control commands progress
// independently of memory completion; responses may retire out of issue order.
// The command ABI is a project mapping of PTX, not a NVIDIA instruction encoding.
// ============================================================================

`default_nettype none

module tma_engine #(
    parameter int unsigned ADDR_W             = 64,
    parameter int unsigned SMEM_ADDR_W        = 32,
    parameter int unsigned CMD_QUEUE_DEPTH    = 8,
    parameter int unsigned DESC_CACHE_ENTRIES = 4,
    parameter int unsigned MSHR_ENTRIES       = 16,
    parameter int unsigned GMEM_ID_W          = 5,
    parameter int unsigned SMEM_ID_W          = 5
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

    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         tma_cmd_vld_i,
    output wire                         tma_cmd_rdy_o,

    output wire                         tma_rsp_vld_o,
    input  wire                         tma_rsp_rdy_i,

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
    input  wire [SMEM_ID_W-1:0]         smem_rsp_id_i,

    output wire                         tx_cpl_vld_o,
    input  wire                         tx_cpl_rdy_i,
    output wire [15:0]                  tx_cpl_tag_o,
    output wire [ADDR_W-1:0]            tx_cpl_addr_o,
    output wire [63:0]                  tx_cpl_bytes_o,

    input  wire                         tx_rsp_vld_i,
    output wire                         tx_rsp_rdy_o,
    input  wire [15:0]                  tx_rsp_tag_i,
    input  wire [7:0]                   tx_rsp_status_i,
    input  wire                         tx_rsp_phase_i
);
    wire [4:0] tma_cmd_opcode_i = tma_cmd_i.opcode;
    wire [15:0] tma_cmd_tag_i = tma_cmd_i.tag;
    wire [9:0] tma_cmd_issuer_i = tma_cmd_i.issuer;
    wire [63:0] tma_cmd_desc_ptr_i = tma_cmd_i.desc_ptr;
    wire [159:0] tma_cmd_coord_i = tma_cmd_i.coord;
    wire [31:0] tma_cmd_smem_addr_i = tma_cmd_i.smem_addr;
    wire [63:0] tma_cmd_linear_addr_i = tma_cmd_i.linear_addr;
    wire [31:0] tma_cmd_linear_bytes_i = tma_cmd_i.linear_bytes;
    wire [63:0] tma_cmd_barrier_addr_i = tma_cmd_i.barrier_addr;
    wire [2:0] tma_cmd_mode_i = tma_cmd_i.mode;
    wire [79:0] tma_cmd_im2col_i = tma_cmd_i.im2col;
    wire [1:0] tma_cmd_completion_i = tma_cmd_i.completion;
    wire  tma_cmd_multi_cta_i = tma_cmd_i.multi_cta;
    wire [31:0] tma_cmd_wait_n_i = tma_cmd_i.wait_n;
    wire  tma_cmd_wait_read_i = tma_cmd_i.wait_read;

    import tma_mbarrier_pkg::*;
    localparam int unsigned TICKETS = CMD_QUEUE_DEPTH*2 + 4;
    localparam int unsigned IDX_W = $clog2(TICKETS);
    // Resource capacities are project parameters, not NVIDIA hardware claims.
    typedef struct packed {
        logic valid;
        logic copy;
        logic done;
        logic read_done;
        logic desc_done;
        logic grouped;
        logic desc_only;
        logic waiting;
        logic wait_read;
        logic [9:0] issuer;
        logic [15:0] tag;
        logic [63:0] group_seq;
        logic [63:0] cutoff;
        logic [63:0] bytes;
        logic [7:0] status;
    } ticket_t;
    ticket_t ticket_q [0:TICKETS-1];
    logic [1023:0][63:0] open_group_q, failed_group_q;
    logic [1023:0][7:0] group_error_q;
    logic [IDX_W-1:0] response_rr_q;
    logic free_found, response_found, pending;
    logic [IDX_W-1:0] free_idx, response_idx;
    integer copy_count, scan_idx;
    logic [7:0] issue_status;
    wire issue_copy = tma_cmd_opcode_i != TMA_OP_COMMIT_GROUP && tma_cmd_opcode_i != TMA_OP_WAIT_GROUP;
    wire issue_store = (tma_cmd_opcode_i == TMA_OP_STORE_TENSOR || tma_cmd_opcode_i == TMA_OP_STORE_LINEAR || tma_cmd_opcode_i == TMA_OP_REDUCE_LINEAR || tma_cmd_opcode_i == TMA_OP_REDUCE_TENSOR);
    wire issue_load = (tma_cmd_opcode_i == TMA_OP_LOAD_TENSOR || tma_cmd_opcode_i == TMA_OP_LOAD_LINEAR || tma_cmd_opcode_i == TMA_OP_COPY_SHARED || tma_cmd_opcode_i == TMA_OP_REDUCE_SHARED);
    wire issue_fire = tma_cmd_vld_i && tma_cmd_rdy_o;
    wire copy_cmd_rdy, copy_rsp_vld;
    wire [15:0] copy_rsp_tag;
    wire [7:0] copy_rsp_status;
    wire [63:0] copy_rsp_bytes;
    wire desc_done, source_done;
    wire [15:0] event_tag;
    wire copy_cmd_vld = tma_cmd_vld_i && free_found && issue_copy &&
        issue_status == TMA_STATUS_OK && copy_count < TICKETS-2;
    logic rsp_vld_q;
    logic [15:0] rsp_tag_q;
    logic [9:0] rsp_issuer_q;
    logic [7:0] rsp_status_q;
    logic [63:0] rsp_bytes_q;
    assign tma_rsp_vld_o = rsp_vld_q;
    assign tma_rsp_o.tag = rsp_tag_q;
    assign tma_rsp_o.issuer = rsp_issuer_q;
    assign tma_rsp_o.status = rsp_status_q;
    assign tma_rsp_o.bytes = rsp_bytes_q;
    assign tma_cmd_rdy_o = free_found &&
        ((!issue_copy || issue_status != TMA_STATUS_OK) || (copy_cmd_rdy && copy_count < TICKETS-2));
    always_comb begin
        free_found = 1'b0; free_idx = '0; copy_count = 0;
        for (int i = 0; i < TICKETS; i = i + 1) begin
            if (!ticket_q[i].valid && !free_found) begin
                free_found = 1'b1; free_idx = IDX_W'(i);
            end
            if (ticket_q[i].valid && ticket_q[i].copy) copy_count = copy_count + 1;
        end
        issue_status = TMA_STATUS_OK;
        if (tma_cmd_opcode_i > TMA_OP_FENCE_PROXY) issue_status = TMA_STATUS_BAD_OPCODE;
        if ((issue_store && tma_cmd_completion_i != TMA_CPL_BULK) ||
            (issue_load && tma_cmd_completion_i != TMA_CPL_MBAR))
            issue_status = TMA_STATUS_UNSUPPORTED;
        if (tma_cmd_i.cp_mask_enable && tma_cmd_opcode_i != TMA_OP_STORE_LINEAR) issue_status = TMA_STATUS_UNSUPPORTED;
        if (tma_cmd_i.ignore_oob && tma_cmd_opcode_i != TMA_OP_LOAD_LINEAR) issue_status = TMA_STATUS_UNSUPPORTED;
        if (tma_cmd_i.multimem && tma_cmd_opcode_i != TMA_OP_STORE_LINEAR && tma_cmd_opcode_i != TMA_OP_REDUCE_LINEAR) issue_status = TMA_STATUS_UNSUPPORTED;
        if (tma_cmd_i.multimem && tma_cmd_i.cache_hint) issue_status = TMA_STATUS_UNSUPPORTED;
        if (tma_cmd_i.atomic128 && tma_cmd_opcode_i != TMA_OP_STORE_LINEAR && tma_cmd_opcode_i != TMA_OP_LOAD_LINEAR && tma_cmd_opcode_i != TMA_OP_COPY_SHARED) issue_status = TMA_STATUS_UNSUPPORTED;
        if ((tma_cmd_opcode_i == TMA_OP_COPY_SHARED || tma_cmd_opcode_i == TMA_OP_REDUCE_SHARED) && tma_cmd_i.scope > BW_SCOPE_CLUSTER)
            issue_status = TMA_STATUS_UNSUPPORTED;
        if ((tma_cmd_opcode_i == TMA_OP_COMMIT_GROUP) && open_group_q[tma_cmd_issuer_i] == 64'hffff_ffff_ffff_ffff)
            issue_status = TMA_STATUS_INTERNAL;
        if ((tma_cmd_opcode_i == TMA_OP_REDUCE_LINEAR || tma_cmd_opcode_i == TMA_OP_REDUCE_SHARED || tma_cmd_opcode_i == TMA_OP_REDUCE_TENSOR) && tma_cmd_i.sem != BW_SEM_RELAXED)
            issue_status = TMA_STATUS_UNSUPPORTED;
        if ((tma_cmd_opcode_i == TMA_OP_LOAD_TENSOR || tma_cmd_opcode_i == TMA_OP_STORE_TENSOR || tma_cmd_opcode_i == TMA_OP_REDUCE_TENSOR || tma_cmd_opcode_i == TMA_OP_PREFETCH_TENSOR) && tma_cmd_i.map_shared)
            issue_status = TMA_STATUS_UNSUPPORTED;
        if (tma_cmd_multi_cta_i) issue_status = TMA_STATUS_UNSUPPORTED;
    end
    always_comb begin
        response_found = 1'b0; response_idx = '0; pending = 1'b0; scan_idx = 0;
        for (int i = 0; i < TICKETS; i = i + 1) begin
            scan_idx = (int'(response_rr_q) + i) % TICKETS;
            pending = 1'b0;
            if (ticket_q[scan_idx].waiting) begin
                for (int j = 0; j < TICKETS; j = j + 1) begin
                    if (ticket_q[j].valid && ticket_q[j].copy && ticket_q[j].grouped &&
                        ticket_q[j].issuer == ticket_q[scan_idx].issuer &&
                        ticket_q[j].group_seq < ticket_q[scan_idx].cutoff &&
                        !(ticket_q[j].desc_only ? ticket_q[j].desc_done :
                          (ticket_q[scan_idx].wait_read ? ticket_q[j].read_done : ticket_q[j].done)))
                        pending = 1'b1;
                end
            end
            if (ticket_q[scan_idx].valid && (ticket_q[scan_idx].done ||
                (ticket_q[scan_idx].waiting && !pending)) && !response_found) begin
                response_found = 1'b1; response_idx = IDX_W'(scan_idx);
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < TICKETS; i = i + 1) ticket_q[i] <= '0;
            // Exactly 1024 thread counters; the wide reset is intentional.
            /* verilator lint_off WIDTHCONCAT */
            open_group_q <= '0; failed_group_q <= '0; group_error_q <= '0;
            /* verilator lint_on WIDTHCONCAT */
            response_rr_q <= '0;
            rsp_vld_q <= 1'b0;
            rsp_tag_q <= 0; rsp_issuer_q <= 0; rsp_status_q <= 0; rsp_bytes_q <= 0;
        end else begin
            if (rsp_vld_q && tma_rsp_rdy_i) rsp_vld_q <= 1'b0;
            if (response_found && (!rsp_vld_q || tma_rsp_rdy_i)) begin
                rsp_vld_q <= 1'b1;
                rsp_tag_q <= ticket_q[response_idx].tag;
                rsp_issuer_q <= ticket_q[response_idx].issuer;
                rsp_status_q <= ticket_q[response_idx].status;
                if (ticket_q[response_idx].waiting && group_error_q[ticket_q[response_idx].issuer] != 0 &&
                    failed_group_q[ticket_q[response_idx].issuer] < ticket_q[response_idx].cutoff)
                    rsp_status_q <= group_error_q[ticket_q[response_idx].issuer];
                rsp_bytes_q <= ticket_q[response_idx].bytes;
                ticket_q[response_idx].valid <= 1'b0;
                response_rr_q <= (response_idx == IDX_W'(TICKETS-1)) ? '0 : response_idx + IDX_W'(1);
            end
            if (issue_fire) begin
                ticket_q[free_idx] <= '0;
                ticket_q[free_idx].valid <= 1'b1;
                ticket_q[free_idx].copy <= issue_copy && issue_status == TMA_STATUS_OK;
                ticket_q[free_idx].done <= !issue_copy || issue_status != TMA_STATUS_OK;
                ticket_q[free_idx].tag <= tma_cmd_tag_i;
                ticket_q[free_idx].issuer <= tma_cmd_issuer_i;
                ticket_q[free_idx].status <= issue_status;
                ticket_q[free_idx].group_seq <= open_group_q[tma_cmd_issuer_i];
                ticket_q[free_idx].grouped <= (issue_store && tma_cmd_completion_i == TMA_CPL_BULK) ||
                    (tma_cmd_opcode_i == TMA_OP_LOAD_TENSOR && tma_cmd_completion_i == TMA_CPL_MBAR);
                ticket_q[free_idx].desc_only <= tma_cmd_opcode_i == TMA_OP_LOAD_TENSOR;
                if (issue_status == TMA_STATUS_OK && tma_cmd_opcode_i == TMA_OP_COMMIT_GROUP)
                    open_group_q[tma_cmd_issuer_i] <= open_group_q[tma_cmd_issuer_i] + 64'd1;
                if (issue_status == TMA_STATUS_OK && tma_cmd_opcode_i == TMA_OP_WAIT_GROUP) begin
                    ticket_q[free_idx].done <= 1'b0;
                    ticket_q[free_idx].waiting <= 1'b1;
                    ticket_q[free_idx].wait_read <= tma_cmd_wait_read_i;
                    ticket_q[free_idx].cutoff <= (open_group_q[tma_cmd_issuer_i] > {32'd0,tma_cmd_wait_n_i}) ?
                        open_group_q[tma_cmd_issuer_i] - {32'd0,tma_cmd_wait_n_i} : 64'd0;
                end
            end
            if (desc_done && int'(event_tag) < TICKETS) ticket_q[event_tag[IDX_W-1:0]].desc_done <= 1'b1;
            if (source_done && int'(event_tag) < TICKETS) ticket_q[event_tag[IDX_W-1:0]].read_done <= 1'b1;
            if (copy_rsp_vld && int'(copy_rsp_tag) < TICKETS) begin
                if (copy_rsp_status != 0 && ticket_q[copy_rsp_tag[IDX_W-1:0]].grouped &&
                    group_error_q[ticket_q[copy_rsp_tag[IDX_W-1:0]].issuer] == 0) begin
                    group_error_q[ticket_q[copy_rsp_tag[IDX_W-1:0]].issuer] <= copy_rsp_status;
                    failed_group_q[ticket_q[copy_rsp_tag[IDX_W-1:0]].issuer] <= ticket_q[copy_rsp_tag[IDX_W-1:0]].group_seq;
                end
                ticket_q[copy_rsp_tag[IDX_W-1:0]].done <= 1'b1;
                ticket_q[copy_rsp_tag[IDX_W-1:0]].read_done <= 1'b1;
                ticket_q[copy_rsp_tag[IDX_W-1:0]].desc_done <= 1'b1;
                ticket_q[copy_rsp_tag[IDX_W-1:0]].status <= copy_rsp_status;
                ticket_q[copy_rsp_tag[IDX_W-1:0]].bytes <= copy_rsp_bytes;
            end
        end
    end
    initial begin
        if (TICKETS > 65536) $error("copy ticket index must fit the internal 16-bit tag");
    end

    tma_cmd_t copy_cmd;
    always_comb begin
        copy_cmd = tma_cmd_i;
        copy_cmd.tag = 16'(free_idx);
    end
    tma_copy_engine #(
        .ADDR_W(ADDR_W), .SMEM_ADDR_W(SMEM_ADDR_W), .CMD_QUEUE_DEPTH(CMD_QUEUE_DEPTH),
        .DESC_CACHE_ENTRIES(DESC_CACHE_ENTRIES), .MSHR_ENTRIES(MSHR_ENTRIES),
        .GMEM_ID_W(GMEM_ID_W), .SMEM_ID_W(SMEM_ID_W)
    ) u_copy (
        .clk(clk),
        .rst_n(rst_n),
        .tma_cmd_i(copy_cmd),
        .gmem_req_attr_o(gmem_req_attr_o),
        .tma_order_req_vld_o(tma_order_req_vld_o),
        .tma_order_req_rdy_i(tma_order_req_rdy_i),
        .tma_order_req_o(tma_order_req_o),
        .tma_order_rsp_vld_i(tma_order_rsp_vld_i),
        .tma_order_rsp_rdy_o(tma_order_rsp_rdy_o),
        .tma_order_rsp_i(tma_order_rsp_i),
        .smem_req_attr_o(smem_req_attr_o),

        .tma_cmd_vld_i(copy_cmd_vld),
        .tma_cmd_rdy_o(copy_cmd_rdy),

        .tma_rsp_vld_o(copy_rsp_vld),
        .tma_rsp_rdy_i(1'b1),
        .tma_rsp_tag_o(copy_rsp_tag),
        .tma_rsp_status_o(copy_rsp_status),
        .tma_rsp_bytes_o(copy_rsp_bytes),
        .gmem_req_vld_o(gmem_req_vld_o),
        .gmem_req_rdy_i(gmem_req_rdy_i),
        .gmem_req_write_o(gmem_req_write_o),
        .gmem_req_addr_o(gmem_req_addr_o),
        .gmem_req_data_o(gmem_req_data_o),
        .gmem_req_mask_o(gmem_req_mask_o),
        .gmem_req_id_o(gmem_req_id_o),
        .gmem_rsp_vld_i(gmem_rsp_vld_i),
        .gmem_rsp_rdy_o(gmem_rsp_rdy_o),
        .gmem_rsp_data_i(gmem_rsp_data_i),
        .gmem_rsp_status_i(gmem_rsp_status_i),
        .gmem_rsp_id_i(gmem_rsp_id_i),
        .smem_req_vld_o(smem_req_vld_o),
        .smem_req_rdy_i(smem_req_rdy_i),
        .smem_req_write_o(smem_req_write_o),
        .smem_req_addr_o(smem_req_addr_o),
        .smem_req_data_o(smem_req_data_o),
        .smem_req_mask_o(smem_req_mask_o),
        .smem_req_id_o(smem_req_id_o),
        .smem_rsp_vld_i(smem_rsp_vld_i),
        .smem_rsp_rdy_o(smem_rsp_rdy_o),
        .smem_rsp_data_i(smem_rsp_data_i),
        .smem_rsp_status_i(smem_rsp_status_i),
        .smem_rsp_id_i(smem_rsp_id_i),
        .tx_cpl_vld_o(tx_cpl_vld_o),
        .tx_cpl_rdy_i(tx_cpl_rdy_i),
        .tx_cpl_tag_o(tx_cpl_tag_o),
        .tx_cpl_addr_o(tx_cpl_addr_o),
        .tx_cpl_bytes_o(tx_cpl_bytes_o),
        .tx_rsp_vld_i(tx_rsp_vld_i),
        .tx_rsp_rdy_o(tx_rsp_rdy_o),
        .tx_rsp_tag_i(tx_rsp_tag_i),
        .tx_rsp_status_i(tx_rsp_status_i),
        .tx_rsp_phase_i(tx_rsp_phase_i),

        .desc_done_o(desc_done),
        .source_done_o(source_done),
        .event_tag_o(event_tag)
    );
endmodule
`default_nettype wire
