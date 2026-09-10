// ============================================================================
// File Name   : tma_engine.sv
// Date        : 2026-08-27
// Description : Patent-inspired 1D-5D tensor/linear asynchronous copy engine.
//
// The request generator walks one logical tensor box at a time.  Up to
// MSHR_ENTRIES line transactions may overlap and responses are matched by ID.
// Commands complete in issue order.  This is an open research model, not a
// proprietary TMA instruction encoding.
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
    import tma_mbarrier_pkg::*;

    localparam int unsigned CMD_PTR_W  = (CMD_QUEUE_DEPTH <= 1) ? 1 : $clog2(CMD_QUEUE_DEPTH);
    localparam int unsigned CMD_CNT_W  = $clog2(CMD_QUEUE_DEPTH + 1);
    localparam int unsigned DESC_IDX_W = (DESC_CACHE_ENTRIES <= 1) ? 1 : $clog2(DESC_CACHE_ENTRIES);
    localparam int unsigned MSHR_IDX_W = (MSHR_ENTRIES <= 1) ? 1 : $clog2(MSHR_ENTRIES);
    localparam int unsigned MSHR_CNT_W = $clog2(MSHR_ENTRIES + 1);

    localparam logic [3:0] ST_IDLE        = 4'd0;
    localparam logic [3:0] ST_DESC_LOOKUP = 4'd1;
    localparam logic [3:0] ST_DESC_WAIT   = 4'd2;
    localparam logic [3:0] ST_SETUP       = 4'd3;
    localparam logic [3:0] ST_GENERATE    = 4'd4;
    localparam logic [3:0] ST_WAIT_MSHR   = 4'd5;
    localparam logic [3:0] ST_TX_REQ      = 4'd6;
    localparam logic [3:0] ST_TX_RSP      = 4'd7;
    localparam logic [3:0] ST_RESP        = 4'd8;
    localparam logic [3:0] ST_DESC_INV    = 4'd9;

    localparam logic [3:0] M_FREE       = 4'd0;
    localparam logic [3:0] M_LD_GREQ    = 4'd1;
    localparam logic [3:0] M_LD_GRSP    = 4'd2;
    localparam logic [3:0] M_LD_SREQ    = 4'd3;
    localparam logic [3:0] M_LD_SRSP    = 4'd4;
    localparam logic [3:0] M_ST_SREQ    = 4'd5;
    localparam logic [3:0] M_ST_SRSP    = 4'd6;
    localparam logic [3:0] M_ST_GREQ    = 4'd7;
    localparam logic [3:0] M_ST_GRSP    = 4'd8;

    logic [2:0]                   cmd_opcode_q [0:CMD_QUEUE_DEPTH-1];
    logic [15:0]                  cmd_tag_q [0:CMD_QUEUE_DEPTH-1];
    logic [ADDR_W-1:0]            cmd_desc_ptr_q [0:CMD_QUEUE_DEPTH-1];
    logic [159:0]                 cmd_coord_q [0:CMD_QUEUE_DEPTH-1];
    logic [SMEM_ADDR_W-1:0]       cmd_smem_addr_q [0:CMD_QUEUE_DEPTH-1];
    logic [ADDR_W-1:0]            cmd_linear_addr_q [0:CMD_QUEUE_DEPTH-1];
    logic [31:0]                  cmd_linear_bytes_q [0:CMD_QUEUE_DEPTH-1];
    logic [ADDR_W-1:0]            cmd_barrier_addr_q [0:CMD_QUEUE_DEPTH-1];
    logic [CMD_PTR_W-1:0]         cmd_rd_ptr_q;
    logic [CMD_PTR_W-1:0]         cmd_wr_ptr_q;
    logic [CMD_CNT_W-1:0]         cmd_count_q;

    logic [3:0]                   state_q;
    logic [2:0]                   active_opcode_q;
    logic [15:0]                  active_tag_q;
    logic [ADDR_W-1:0]            active_desc_ptr_q;
    logic signed [31:0]           active_coord_q [0:4];
    logic [SMEM_ADDR_W-1:0]       active_smem_base_q;
    logic [ADDR_W-1:0]            active_linear_addr_q;
    logic [31:0]                  active_linear_bytes_q;
    logic [ADDR_W-1:0]            active_barrier_addr_q;
    logic [7:0]                   active_status_q;
    logic [63:0]                  active_total_bytes_q;
    logic [63:0]                  logical_offset_q;
    logic [31:0]                  iter_idx_q [0:4];
    logic [MSHR_CNT_W-1:0]        active_outstanding_q;
    logic                         generation_done_q;

    logic [1023:0]                desc_data_q;
    logic                         desc_cache_vld_q [0:DESC_CACHE_ENTRIES-1];
    logic [ADDR_W-1:0]            desc_cache_addr_q [0:DESC_CACHE_ENTRIES-1];
    logic [1023:0]                desc_cache_data_q [0:DESC_CACHE_ENTRIES-1];
    logic [DESC_IDX_W-1:0]        desc_replace_q;
    logic                         desc_fetch_pending_q;
    logic                         desc_fetch_issued_q;

    logic [2:0]                   desc_dims_q;
    logic [4:0]                   desc_elem_bytes_q;
    logic [ADDR_W-1:0]            desc_gmem_base_q;
    logic [31:0]                  desc_tensor_size_q [0:4];
    logic [63:0]                  desc_tensor_stride_q [0:4];
    logic [15:0]                  desc_box_size_q [0:4];
    logic [15:0]                  desc_trav_stride_q [0:4];

    logic [3:0]                   m_state_q [0:MSHR_ENTRIES-1];
    logic [ADDR_W-1:0]            m_gmem_addr_q [0:MSHR_ENTRIES-1];
    logic [6:0]                   m_gmem_off_q [0:MSHR_ENTRIES-1];
    logic [SMEM_ADDR_W-1:0]       m_smem_addr_q [0:MSHR_ENTRIES-1];
    logic [4:0]                   m_smem_off_q [0:MSHR_ENTRIES-1];
    logic [5:0]                   m_len_q [0:MSHR_ENTRIES-1];
    logic [1023:0]                m_data_q [0:MSHR_ENTRIES-1];
    logic [127:0]                 m_mask_q [0:MSHR_ENTRIES-1];

    logic                         g_req_vld_q;
    logic                         g_req_write_q;
    logic [ADDR_W-1:0]            g_req_addr_q;
    logic [1023:0]                g_req_data_q;
    logic [127:0]                 g_req_mask_q;
    logic [GMEM_ID_W-1:0]         g_req_id_q;
    logic                         s_req_vld_q;
    logic                         s_req_write_q;
    logic [SMEM_ADDR_W-1:0]       s_req_addr_q;
    logic [255:0]                 s_req_data_q;
    logic [31:0]                  s_req_mask_q;
    logic [SMEM_ID_W-1:0]         s_req_id_q;

    logic                         rsp_vld_q;
    logic [15:0]                  rsp_tag_q;
    logic [7:0]                   rsp_status_q;
    logic [63:0]                  rsp_bytes_q;
    logic                         tx_cpl_vld_q;

    logic                         cmd_fire;
    logic                         cmd_pop;
    logic                         rsp_fire;
    logic                         g_req_fire;
    logic                         s_req_fire;
    logic                         g_rsp_fire;
    logic                         s_rsp_fire;
    logic                         tx_cpl_fire;
    logic                         tx_rsp_fire;

    logic                         desc_cache_hit;
    logic [DESC_IDX_W-1:0]        desc_cache_hit_idx;
    logic                         free_mshr_found;
    logic [MSHR_IDX_W-1:0]        free_mshr_idx;
    logic                         g_send_found;
    logic [MSHR_IDX_W-1:0]        g_send_idx;
    logic                         s_send_found;
    logic [MSHR_IDX_W-1:0]        s_send_idx;

    logic [7:0]                   setup_version;
    logic [2:0]                   setup_dims_m1;
    logic [2:0]                   setup_elem_log2;
    logic [2:0]                   setup_dims;
    logic [4:0]                   setup_elem_bytes;
    logic [ADDR_W-1:0]            setup_gmem_base;
    logic [31:0]                  setup_tensor_size [0:4];
    logic [63:0]                  setup_tensor_stride [0:4];
    logic [15:0]                  setup_box_size [0:4];
    logic [15:0]                  setup_trav_stride [0:4];
    logic [127:0]                 setup_product;
    logic                         setup_valid;
    logic [7:0]                   setup_error_status;

    logic signed [ADDR_W:0]       gen_gaddr_signed;
    logic [ADDR_W:0]              gen_linear_gaddr_ext;
    logic [64:0]                  gen_saddr_ext;
    logic [ADDR_W-1:0]            gen_gaddr;
    logic [SMEM_ADDR_W-1:0]       gen_saddr;
    logic                         gen_in_bounds;
    logic                         gen_addr_valid;
    logic [5:0]                   gen_segment_bytes;
    logic [31:0]                  gen_step_elems;
    logic [63:0]                  gen_remaining_bytes;
    logic [31:0]                  gen_dim0_remaining;
    logic [31:0]                  gen_tensor0_remaining;
    logic [31:0]                  gen_line_elements;
    logic [31:0]                  gen_smem_elements;
    logic [31:0]                  gen_group_elements;
    logic [7:0]                   gen_gline_bytes;
    logic                         gen_is_load;
    logic                         gen_is_store;
    logic                         gen_advance;
    logic                         gen_allocate;
    logic                         gen_last;
    logic [31:0]                  iter_idx_next [0:4];
    logic                         iter_carry;
    logic [32:0]                  iter_sum;
    logic [2:0]                   free_rsp_count;
    logic                         free_from_gmem;
    logic                         free_from_smem;
    logic [MSHR_IDX_W-1:0]        g_rsp_mshr_idx;
    logic [MSHR_IDX_W-1:0]        s_rsp_mshr_idx;
    logic                         active_done_after_rsp;
    logic [7:0]                   active_status_after_rsp;
    logic signed [63:0]           gen_coord_value [0:4];

    localparam logic [GMEM_ID_W:0] MSHR_ENTRIES_GMEM_EXT =
        (GMEM_ID_W + 1)'(MSHR_ENTRIES);
    localparam logic [SMEM_ID_W:0] MSHR_ENTRIES_SMEM_EXT =
        (SMEM_ID_W + 1)'(MSHR_ENTRIES);

    function automatic logic [31:0] make_mask32(
        input logic [5:0] length,
        input logic [4:0] offset
    );
        begin
            make_mask32 = 32'd0;
            for (int unsigned mask_bit = 0; mask_bit < 32;
                 mask_bit = mask_bit + 1) begin
                if ((mask_bit >= 32'(offset)) &&
                    (mask_bit < (32'(offset) + 32'(length)))) begin
                    make_mask32[mask_bit] = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic [127:0] make_mask128(
        input logic [5:0] length,
        input logic [6:0] offset
    );
        begin
            make_mask128 = 128'd0;
            for (int unsigned mask_bit = 0; mask_bit < 128;
                 mask_bit = mask_bit + 1) begin
                if ((mask_bit >= 32'(offset)) &&
                    (mask_bit < (32'(offset) + 32'(length)))) begin
                    make_mask128[mask_bit] = 1'b1;
                end
            end
        end
    endfunction

    assign tma_cmd_rdy_o = (cmd_count_q != CMD_CNT_W'(CMD_QUEUE_DEPTH));
    assign cmd_fire = tma_cmd_vld_i && tma_cmd_rdy_o;
    assign cmd_pop = (state_q == ST_IDLE) && (cmd_count_q != 0) && !rsp_vld_q;

    assign tma_rsp_vld_o = rsp_vld_q;
    assign tma_rsp_tag_o = rsp_tag_q;
    assign tma_rsp_status_o = rsp_status_q;
    assign tma_rsp_bytes_o = rsp_bytes_q;
    assign rsp_fire = rsp_vld_q && tma_rsp_rdy_i;

    assign gmem_req_vld_o = g_req_vld_q;
    assign gmem_req_write_o = g_req_write_q;
    assign gmem_req_addr_o = g_req_addr_q;
    assign gmem_req_data_o = g_req_data_q;
    assign gmem_req_mask_o = g_req_mask_q;
    assign gmem_req_id_o = g_req_id_q;
    assign gmem_rsp_rdy_o = 1'b1;
    assign g_req_fire = g_req_vld_q && gmem_req_rdy_i;
    assign g_rsp_fire = gmem_rsp_vld_i && gmem_rsp_rdy_o;

    assign smem_req_vld_o = s_req_vld_q;
    assign smem_req_write_o = s_req_write_q;
    assign smem_req_addr_o = s_req_addr_q;
    assign smem_req_data_o = s_req_data_q;
    assign smem_req_mask_o = s_req_mask_q;
    assign smem_req_id_o = s_req_id_q;
    assign smem_rsp_rdy_o = 1'b1;
    assign s_req_fire = s_req_vld_q && smem_req_rdy_i;
    assign s_rsp_fire = smem_rsp_vld_i && smem_rsp_rdy_o;

    assign tx_cpl_vld_o = tx_cpl_vld_q;
    assign tx_cpl_tag_o = active_tag_q;
    assign tx_cpl_addr_o = active_barrier_addr_q;
    assign tx_cpl_bytes_o = active_total_bytes_q;
    assign tx_cpl_fire = tx_cpl_vld_q && tx_cpl_rdy_i;
    assign tx_rsp_rdy_o = (state_q == ST_TX_RSP);
    assign tx_rsp_fire = tx_rsp_vld_i && tx_rsp_rdy_o;

    always_comb begin
        desc_cache_hit = 1'b0;
        desc_cache_hit_idx = {DESC_IDX_W{1'b0}};
        for (int unsigned cache_idx = 0;
             cache_idx < DESC_CACHE_ENTRIES; cache_idx = cache_idx + 1) begin
            if (desc_cache_vld_q[cache_idx] &&
                (desc_cache_addr_q[cache_idx] == active_desc_ptr_q)) begin
                desc_cache_hit = 1'b1;
                desc_cache_hit_idx = DESC_IDX_W'(cache_idx);
            end
        end
    end

    always_comb begin
        free_mshr_found = 1'b0;
        free_mshr_idx = {MSHR_IDX_W{1'b0}};
        g_send_found = 1'b0;
        g_send_idx = {MSHR_IDX_W{1'b0}};
        s_send_found = 1'b0;
        s_send_idx = {MSHR_IDX_W{1'b0}};
        for (int unsigned mshr_idx = 0;
             mshr_idx < MSHR_ENTRIES; mshr_idx = mshr_idx + 1) begin
            if ((m_state_q[mshr_idx] == M_FREE) && !free_mshr_found) begin
                free_mshr_found = 1'b1;
                free_mshr_idx = MSHR_IDX_W'(mshr_idx);
            end
            if (((m_state_q[mshr_idx] == M_LD_GREQ) ||
                 (m_state_q[mshr_idx] == M_ST_GREQ)) && !g_send_found) begin
                g_send_found = 1'b1;
                g_send_idx = MSHR_IDX_W'(mshr_idx);
            end
            if (((m_state_q[mshr_idx] == M_LD_SREQ) ||
                 (m_state_q[mshr_idx] == M_ST_SREQ)) && !s_send_found) begin
                s_send_found = 1'b1;
                s_send_idx = MSHR_IDX_W'(mshr_idx);
            end
        end
    end

    always_comb begin
        setup_version = desc_data_q[DESC_VERSION_LSB +: 8];
        setup_dims_m1 = desc_data_q[DESC_DIMS_M1_LSB +: 3];
        setup_elem_log2 = desc_data_q[DESC_ELEM_LOG2_LSB +: 3];
        setup_dims = setup_dims_m1 + 3'd1;
        setup_elem_bytes = 5'd1 << setup_elem_log2;
        setup_gmem_base = desc_data_q[DESC_GMEM_BASE_LSB +: ADDR_W];
        setup_product = 128'd1;
        setup_valid = 1'b1;
        setup_error_status = TMA_STATUS_OK;
        for (int unsigned setup_dim = 0; setup_dim < 5;
             setup_dim = setup_dim + 1) begin
            setup_tensor_size[setup_dim] =
                desc_data_q[DESC_TENSOR_SIZE_LSB + setup_dim*32 +: 32];
            setup_tensor_stride[setup_dim] =
                desc_data_q[DESC_TENSOR_STRIDE_LSB + setup_dim*64 +: 64];
            setup_box_size[setup_dim] =
                desc_data_q[DESC_BOX_SIZE_LSB + setup_dim*16 +: 16];
            setup_trav_stride[setup_dim] =
                desc_data_q[DESC_TRAV_STRIDE_LSB + setup_dim*16 +: 16];
            if (setup_dim < setup_dims) begin
                setup_product = setup_product * setup_box_size[setup_dim];
                if ((setup_tensor_size[setup_dim] == 32'd0) ||
                    (setup_box_size[setup_dim] == 16'd0) ||
                    (setup_trav_stride[setup_dim] == 16'd0)) begin
                    setup_valid = 1'b0;
                    setup_error_status = TMA_STATUS_BAD_DESC;
                end
            end
        end
        setup_product = setup_product * setup_elem_bytes;
        if (setup_version != 8'd1) begin
            setup_valid = 1'b0;
            setup_error_status = TMA_STATUS_BAD_DESC;
        end else if (setup_dims_m1 > 3'd4) begin
            setup_valid = 1'b0;
            setup_error_status = TMA_STATUS_BAD_DIM;
        end else if (setup_elem_log2 > 3'd4) begin
            setup_valid = 1'b0;
            setup_error_status = TMA_STATUS_BAD_ELEM;
        end else if (desc_data_q[1023:720] != 304'd0) begin
            setup_valid = 1'b0;
            setup_error_status = TMA_STATUS_BAD_DESC;
        end else if ((setup_gmem_base &
                      (ADDR_W'(setup_elem_bytes) - ADDR_W'(1))) !=
                     {ADDR_W{1'b0}}) begin
            setup_valid = 1'b0;
            setup_error_status = TMA_STATUS_BAD_DESC;
        end else if (setup_product[127:64] != 64'd0) begin
            setup_valid = 1'b0;
            setup_error_status = TMA_STATUS_ADDR_OVERFLOW;
        end
        for (int unsigned stride_dim = 0; stride_dim < 5;
             stride_dim = stride_dim + 1) begin
            if ((stride_dim < setup_dims) &&
                ((setup_tensor_stride[stride_dim] &
                  (64'(setup_elem_bytes) - 64'd1)) != 64'd0)) begin
                setup_valid = 1'b0;
                setup_error_status = TMA_STATUS_BAD_DESC;
            end
        end
    end

    // Address generation and one-dimensional coalescing.  A segment never
    // crosses a 128-byte GMEM line or a 32-byte SMEM beat.
    always_comb begin
        gen_is_load = (active_opcode_q == TMA_OP_LOAD_TENSOR) ||
                      (active_opcode_q == TMA_OP_LOAD_LINEAR);
        gen_is_store = (active_opcode_q == TMA_OP_STORE_TENSOR) ||
                       (active_opcode_q == TMA_OP_STORE_LINEAR);
        gen_remaining_bytes = active_total_bytes_q - logical_offset_q;
        gen_gaddr_signed = '0;
        gen_linear_gaddr_ext = {1'b0, active_linear_addr_q} + logical_offset_q;
        gen_saddr_ext = {{(65-SMEM_ADDR_W){1'b0}}, active_smem_base_q} +
                        {1'b0, logical_offset_q};
        gen_gaddr = gen_linear_gaddr_ext[ADDR_W-1:0];
        gen_saddr = gen_saddr_ext[SMEM_ADDR_W-1:0];
        gen_in_bounds = 1'b1;
        gen_addr_valid = (gen_linear_gaddr_ext[ADDR_W] == 1'b0) &&
                         (gen_saddr_ext[64:SMEM_ADDR_W] == '0);
        gen_segment_bytes = 6'd1;
        gen_step_elems = 32'd1;
        gen_dim0_remaining = 32'd1;
        gen_tensor0_remaining = 32'd1;
        gen_line_elements = 32'd1;
        gen_smem_elements = 32'd1;
        gen_group_elements = 32'd1;
        gen_gline_bytes = 8'd128 - {1'b0, gen_gaddr[6:0]};
        gen_allocate = 1'b0;
        gen_advance = 1'b0;
        gen_last = 1'b0;
        iter_carry = 1'b0;
        iter_sum = 33'd0;
        for (int unsigned init_dim = 0; init_dim < 5;
             init_dim = init_dim + 1) begin
            gen_coord_value[init_dim] = 64'sd0;
            iter_idx_next[init_dim] = iter_idx_q[init_dim];
        end

        if ((active_opcode_q == TMA_OP_LOAD_LINEAR) ||
            (active_opcode_q == TMA_OP_STORE_LINEAR)) begin
            if (gen_remaining_bytes < 64'd32) begin
                gen_segment_bytes = gen_remaining_bytes[5:0];
            end else begin
                gen_segment_bytes = 6'd32;
            end
            if (gen_segment_bytes > (6'd32 - {1'b0, gen_saddr[4:0]})) begin
                gen_segment_bytes = 6'd32 - {1'b0, gen_saddr[4:0]};
            end
            gen_gline_bytes = 8'd128 - {1'b0, gen_gaddr[6:0]};
            if ({2'd0, gen_segment_bytes} > gen_gline_bytes) begin
                gen_segment_bytes = gen_gline_bytes[5:0];
            end
            gen_step_elems = {26'd0, gen_segment_bytes};
        end else begin
            gen_gaddr_signed = $signed({1'b0, desc_gmem_base_q});
            gen_in_bounds = 1'b1;
            for (int unsigned addr_dim = 0; addr_dim < 5;
                 addr_dim = addr_dim + 1) begin
                gen_coord_value[addr_dim] =
                    $signed({{32{active_coord_q[addr_dim][31]}},
                             active_coord_q[addr_dim]}) +
                    $signed({32'd0, iter_idx_q[addr_dim]}) *
                    $signed({48'd0, desc_trav_stride_q[addr_dim]});
                if (addr_dim < desc_dims_q) begin
                    if ((gen_coord_value[addr_dim] < 0) ||
                        ($unsigned(gen_coord_value[addr_dim]) >=
                         {32'd0, desc_tensor_size_q[addr_dim]})) begin
                        gen_in_bounds = 1'b0;
                    end
                    gen_gaddr_signed = gen_gaddr_signed +
                        gen_coord_value[addr_dim] *
                        $signed({1'b0, desc_tensor_stride_q[addr_dim]});
                end
            end
            gen_gaddr = gen_gaddr_signed[ADDR_W-1:0];
            // An OOB element never accesses GMEM, so a negative synthetic
            // GMEM address is harmless; the SMEM destination must still fit.
            gen_addr_valid = (!gen_in_bounds ||
                              (gen_gaddr_signed[ADDR_W] == 1'b0)) &&
                             (gen_saddr_ext[64:SMEM_ADDR_W] == '0);
            gen_segment_bytes = {1'b0, desc_elem_bytes_q};
            gen_step_elems = 32'd1;
            if (gen_in_bounds && (desc_trav_stride_q[0] == 16'd1) &&
                (desc_tensor_stride_q[0] == {59'd0, desc_elem_bytes_q})) begin
                gen_dim0_remaining = {16'd0, desc_box_size_q[0]} -
                                     iter_idx_q[0];
                gen_tensor0_remaining = desc_tensor_size_q[0] -
                                        gen_coord_value[0][31:0];
                gen_line_elements = (32'd128 - {25'd0, gen_gaddr[6:0]}) /
                                    32'(desc_elem_bytes_q);
                gen_smem_elements = (32'd32 - {27'd0, gen_saddr[4:0]}) /
                                    32'(desc_elem_bytes_q);
                gen_group_elements = gen_dim0_remaining;
                if (gen_group_elements > gen_tensor0_remaining)
                    gen_group_elements = gen_tensor0_remaining;
                if (gen_group_elements > gen_line_elements)
                    gen_group_elements = gen_line_elements;
                if (gen_group_elements > gen_smem_elements)
                    gen_group_elements = gen_smem_elements;
                if (gen_group_elements == 32'd0) gen_group_elements = 32'd1;
                gen_step_elems = gen_group_elements;
                gen_segment_bytes = 6'(gen_group_elements *
                                       32'(desc_elem_bytes_q));
            end
        end

        gen_allocate = (state_q == ST_GENERATE) && !generation_done_q &&
                       gen_addr_valid && (gen_is_load || gen_is_store) &&
                       (gen_in_bounds || gen_is_load) && free_mshr_found;
        gen_advance = (state_q == ST_GENERATE) && !generation_done_q &&
                      gen_addr_valid && (gen_is_load || gen_is_store) &&
                      ((!gen_in_bounds && gen_is_store) || gen_allocate);
        gen_last = (logical_offset_q + {58'd0, gen_segment_bytes} >=
                    active_total_bytes_q);

        iter_sum = {1'b0, iter_idx_q[0]} + gen_step_elems;
        if (iter_sum >= {17'd0, desc_box_size_q[0]}) begin
            iter_idx_next[0] = 32'd0;
            iter_carry = 1'b1;
        end else begin
            iter_idx_next[0] = iter_sum[31:0];
        end
        for (int unsigned carry_dim = 1; carry_dim < 5;
             carry_dim = carry_dim + 1) begin
            if (iter_carry && (carry_dim < desc_dims_q)) begin
                if (iter_idx_q[carry_dim] + 32'd1 >=
                    desc_box_size_q[carry_dim]) begin
                    iter_idx_next[carry_dim] = 32'd0;
                    iter_carry = 1'b1;
                end else begin
                    iter_idx_next[carry_dim] = iter_idx_q[carry_dim] + 32'd1;
                    iter_carry = 1'b0;
                end
            end
        end
    end

    assign g_rsp_mshr_idx = gmem_rsp_id_i[MSHR_IDX_W-1:0];
    assign s_rsp_mshr_idx = smem_rsp_id_i[MSHR_IDX_W-1:0];
    assign free_from_gmem = g_rsp_fire &&
                            ({1'b0, gmem_rsp_id_i} < MSHR_ENTRIES_GMEM_EXT) &&
                            (m_state_q[g_rsp_mshr_idx] == M_ST_GRSP);
    assign free_from_smem = s_rsp_fire &&
                            ({1'b0, smem_rsp_id_i} < MSHR_ENTRIES_SMEM_EXT) &&
                            (m_state_q[s_rsp_mshr_idx] == M_LD_SRSP);
    assign free_rsp_count = {2'd0, free_from_gmem} + {2'd0, free_from_smem};
    assign active_done_after_rsp = generation_done_q &&
        (active_outstanding_q == MSHR_CNT_W'(free_rsp_count));

    always_comb begin
        active_status_after_rsp = active_status_q;
        if (active_status_q == TMA_STATUS_OK) begin
            if (free_from_gmem && (gmem_rsp_status_i != 2'd0)) begin
                active_status_after_rsp = TMA_STATUS_GMEM;
            end else if (free_from_smem && (smem_rsp_status_i != 2'd0)) begin
                active_status_after_rsp = TMA_STATUS_SMEM;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_rd_ptr_q <= {CMD_PTR_W{1'b0}};
            cmd_wr_ptr_q <= {CMD_PTR_W{1'b0}};
            cmd_count_q <= {CMD_CNT_W{1'b0}};
            state_q <= ST_IDLE;
            active_opcode_q <= TMA_OP_LOAD_TENSOR;
            active_tag_q <= 16'd0;
            active_desc_ptr_q <= {ADDR_W{1'b0}};
            active_smem_base_q <= {SMEM_ADDR_W{1'b0}};
            active_linear_addr_q <= {ADDR_W{1'b0}};
            active_linear_bytes_q <= 32'd0;
            active_barrier_addr_q <= {ADDR_W{1'b0}};
            active_status_q <= TMA_STATUS_OK;
            active_total_bytes_q <= 64'd0;
            logical_offset_q <= 64'd0;
            active_outstanding_q <= {MSHR_CNT_W{1'b0}};
            generation_done_q <= 1'b0;
            desc_data_q <= 1024'd0;
            desc_replace_q <= {DESC_IDX_W{1'b0}};
            desc_fetch_pending_q <= 1'b0;
            desc_fetch_issued_q <= 1'b0;
            desc_dims_q <= 3'd1;
            desc_elem_bytes_q <= 5'd1;
            desc_gmem_base_q <= {ADDR_W{1'b0}};
            g_req_vld_q <= 1'b0;
            g_req_write_q <= 1'b0;
            g_req_addr_q <= {ADDR_W{1'b0}};
            g_req_data_q <= 1024'd0;
            g_req_mask_q <= 128'd0;
            g_req_id_q <= {GMEM_ID_W{1'b0}};
            s_req_vld_q <= 1'b0;
            s_req_write_q <= 1'b0;
            s_req_addr_q <= {SMEM_ADDR_W{1'b0}};
            s_req_data_q <= 256'd0;
            s_req_mask_q <= 32'd0;
            s_req_id_q <= {SMEM_ID_W{1'b0}};
            rsp_vld_q <= 1'b0;
            rsp_tag_q <= 16'd0;
            rsp_status_q <= TMA_STATUS_OK;
            rsp_bytes_q <= 64'd0;
            tx_cpl_vld_q <= 1'b0;
            for (int unsigned reset_dim = 0; reset_dim < 5;
                 reset_dim = reset_dim + 1) begin
                active_coord_q[reset_dim] <= 32'sd0;
                iter_idx_q[reset_dim] <= 32'd0;
                desc_tensor_size_q[reset_dim] <= 32'd0;
                desc_tensor_stride_q[reset_dim] <= 64'd0;
                desc_box_size_q[reset_dim] <= 16'd0;
                desc_trav_stride_q[reset_dim] <= 16'd0;
            end
            for (int unsigned reset_cache = 0;
                 reset_cache < DESC_CACHE_ENTRIES;
                 reset_cache = reset_cache + 1) begin
                desc_cache_vld_q[reset_cache] <= 1'b0;
                desc_cache_addr_q[reset_cache] <= {ADDR_W{1'b0}};
                desc_cache_data_q[reset_cache] <= 1024'd0;
            end
            for (int unsigned reset_mshr = 0; reset_mshr < MSHR_ENTRIES;
                 reset_mshr = reset_mshr + 1) begin
                m_state_q[reset_mshr] <= M_FREE;
                m_gmem_addr_q[reset_mshr] <= {ADDR_W{1'b0}};
                m_gmem_off_q[reset_mshr] <= 7'd0;
                m_smem_addr_q[reset_mshr] <= {SMEM_ADDR_W{1'b0}};
                m_smem_off_q[reset_mshr] <= 5'd0;
                m_len_q[reset_mshr] <= 6'd0;
                m_data_q[reset_mshr] <= 1024'd0;
                m_mask_q[reset_mshr] <= 128'd0;
            end
        end else begin
            if (cmd_fire) begin
                cmd_opcode_q[cmd_wr_ptr_q] <= tma_cmd_opcode_i;
                cmd_tag_q[cmd_wr_ptr_q] <= tma_cmd_tag_i;
                cmd_desc_ptr_q[cmd_wr_ptr_q] <= tma_cmd_desc_ptr_i;
                cmd_coord_q[cmd_wr_ptr_q] <= tma_cmd_coord_i;
                cmd_smem_addr_q[cmd_wr_ptr_q] <= tma_cmd_smem_addr_i;
                cmd_linear_addr_q[cmd_wr_ptr_q] <= tma_cmd_linear_addr_i;
                cmd_linear_bytes_q[cmd_wr_ptr_q] <= tma_cmd_linear_bytes_i;
                cmd_barrier_addr_q[cmd_wr_ptr_q] <= tma_cmd_barrier_addr_i;
                cmd_wr_ptr_q <= (cmd_wr_ptr_q == CMD_PTR_W'(CMD_QUEUE_DEPTH-1)) ?
                                {CMD_PTR_W{1'b0}} : cmd_wr_ptr_q + CMD_PTR_W'(1);
            end
            if (cmd_pop) begin
                active_opcode_q <= cmd_opcode_q[cmd_rd_ptr_q];
                active_tag_q <= cmd_tag_q[cmd_rd_ptr_q];
                active_desc_ptr_q <= cmd_desc_ptr_q[cmd_rd_ptr_q];
                active_smem_base_q <= cmd_smem_addr_q[cmd_rd_ptr_q];
                active_linear_addr_q <= cmd_linear_addr_q[cmd_rd_ptr_q];
                active_linear_bytes_q <= cmd_linear_bytes_q[cmd_rd_ptr_q];
                active_barrier_addr_q <= cmd_barrier_addr_q[cmd_rd_ptr_q];
                active_status_q <= TMA_STATUS_OK;
                active_total_bytes_q <= 64'd0;
                logical_offset_q <= 64'd0;
                active_outstanding_q <= {MSHR_CNT_W{1'b0}};
                generation_done_q <= 1'b0;
                for (int unsigned pop_dim = 0; pop_dim < 5;
                     pop_dim = pop_dim + 1) begin
                    active_coord_q[pop_dim] <=
                        $signed(cmd_coord_q[cmd_rd_ptr_q][pop_dim*32 +: 32]);
                    iter_idx_q[pop_dim] <= 32'd0;
                end
                cmd_rd_ptr_q <= (cmd_rd_ptr_q == CMD_PTR_W'(CMD_QUEUE_DEPTH-1)) ?
                                {CMD_PTR_W{1'b0}} : cmd_rd_ptr_q + CMD_PTR_W'(1);
                case (cmd_opcode_q[cmd_rd_ptr_q])
                    TMA_OP_LOAD_TENSOR,
                    TMA_OP_STORE_TENSOR: state_q <= ST_DESC_LOOKUP;
                    TMA_OP_LOAD_LINEAR,
                    TMA_OP_STORE_LINEAR: state_q <= ST_SETUP;
                    TMA_OP_DESC_INV: state_q <= ST_DESC_INV;
                    default: begin
                        rsp_vld_q <= 1'b1;
                        rsp_tag_q <= cmd_tag_q[cmd_rd_ptr_q];
                        rsp_status_q <= TMA_STATUS_BAD_OPCODE;
                        rsp_bytes_q <= 64'd0;
                        state_q <= ST_RESP;
                    end
                endcase
            end
            case ({cmd_fire, cmd_pop})
                2'b10: cmd_count_q <= cmd_count_q + CMD_CNT_W'(1);
                2'b01: cmd_count_q <= cmd_count_q - CMD_CNT_W'(1);
                default: cmd_count_q <= cmd_count_q;
            endcase

            if (rsp_fire) begin
                rsp_vld_q <= 1'b0;
                if (state_q == ST_RESP) state_q <= ST_IDLE;
            end

            case (state_q)
                ST_DESC_LOOKUP: begin
                    if (active_desc_ptr_q[6:0] != 7'd0) begin
                        rsp_vld_q <= 1'b1;
                        rsp_tag_q <= active_tag_q;
                        rsp_status_q <= TMA_STATUS_BAD_DESC_ALIGN;
                        rsp_bytes_q <= 64'd0;
                        state_q <= ST_RESP;
                    end else if (desc_cache_hit) begin
                        desc_data_q <= desc_cache_data_q[desc_cache_hit_idx];
                        state_q <= ST_SETUP;
                    end else begin
                        desc_fetch_pending_q <= 1'b1;
                        state_q <= ST_DESC_WAIT;
                    end
                end

                ST_SETUP: begin
                    if ((active_smem_base_q[4:0] != 5'd0)) begin
                        rsp_vld_q <= 1'b1;
                        rsp_tag_q <= active_tag_q;
                        rsp_status_q <= TMA_STATUS_BAD_SMEM_ALIGN;
                        rsp_bytes_q <= 64'd0;
                        state_q <= ST_RESP;
                    end else if ((active_opcode_q == TMA_OP_LOAD_LINEAR) ||
                                 (active_opcode_q == TMA_OP_STORE_LINEAR)) begin
                        if (active_linear_bytes_q == 32'd0) begin
                            rsp_vld_q <= 1'b1;
                            rsp_tag_q <= active_tag_q;
                            rsp_status_q <= TMA_STATUS_BAD_DESC;
                            rsp_bytes_q <= 64'd0;
                            state_q <= ST_RESP;
                        end else begin
                            active_total_bytes_q <= {32'd0, active_linear_bytes_q};
                            logical_offset_q <= 64'd0;
                            state_q <= ST_GENERATE;
                        end
                    end else if (!setup_valid) begin
                        rsp_vld_q <= 1'b1;
                        rsp_tag_q <= active_tag_q;
                        rsp_status_q <= setup_error_status;
                        rsp_bytes_q <= 64'd0;
                        state_q <= ST_RESP;
                    end else begin
                        desc_dims_q <= setup_dims;
                        desc_elem_bytes_q <= setup_elem_bytes;
                        desc_gmem_base_q <= setup_gmem_base;
                        active_total_bytes_q <= setup_product[63:0];
                        logical_offset_q <= 64'd0;
                        for (int unsigned load_dim = 0; load_dim < 5;
                             load_dim = load_dim + 1) begin
                            desc_tensor_size_q[load_dim] <= setup_tensor_size[load_dim];
                            desc_tensor_stride_q[load_dim] <= setup_tensor_stride[load_dim];
                            desc_box_size_q[load_dim] <= setup_box_size[load_dim];
                            desc_trav_stride_q[load_dim] <= setup_trav_stride[load_dim];
                            iter_idx_q[load_dim] <= 32'd0;
                        end
                        state_q <= ST_GENERATE;
                    end
                end

                ST_DESC_INV: begin
                    for (int unsigned inv_idx = 0;
                         inv_idx < DESC_CACHE_ENTRIES;
                         inv_idx = inv_idx + 1) begin
                        if ((active_desc_ptr_q == {ADDR_W{1'b0}}) ||
                            (desc_cache_addr_q[inv_idx] == active_desc_ptr_q)) begin
                            desc_cache_vld_q[inv_idx] <= 1'b0;
                        end
                    end
                    rsp_vld_q <= 1'b1;
                    rsp_tag_q <= active_tag_q;
                    rsp_status_q <= TMA_STATUS_OK;
                    rsp_bytes_q <= 64'd0;
                    state_q <= ST_RESP;
                end

                ST_GENERATE: begin
                    if (!gen_addr_valid) begin
                        active_status_q <= TMA_STATUS_ADDR_OVERFLOW;
                        generation_done_q <= 1'b1;
                        state_q <= ST_WAIT_MSHR;
                    end else if (gen_advance) begin
                        logical_offset_q <= logical_offset_q +
                                            {58'd0, gen_segment_bytes};
                        if ((active_opcode_q == TMA_OP_LOAD_TENSOR) ||
                            (active_opcode_q == TMA_OP_STORE_TENSOR)) begin
                            for (int unsigned next_dim = 0; next_dim < 5;
                                 next_dim = next_dim + 1) begin
                                iter_idx_q[next_dim] <= iter_idx_next[next_dim];
                            end
                        end
                        if (gen_last) begin
                            generation_done_q <= 1'b1;
                            state_q <= ST_WAIT_MSHR;
                        end
                    end
                end

                ST_WAIT_MSHR: begin
                    if (active_done_after_rsp) begin
                        if (active_barrier_addr_q != {ADDR_W{1'b0}}) begin
                            tx_cpl_vld_q <= 1'b1;
                            state_q <= ST_TX_REQ;
                        end else begin
                            rsp_vld_q <= 1'b1;
                            rsp_tag_q <= active_tag_q;
                            rsp_status_q <= active_status_after_rsp;
                            rsp_bytes_q <= active_total_bytes_q;
                            state_q <= ST_RESP;
                        end
                    end
                end

                ST_TX_REQ: begin
                    if (tx_cpl_fire) begin
                        tx_cpl_vld_q <= 1'b0;
                        state_q <= ST_TX_RSP;
                    end
                end

                ST_TX_RSP: begin
                    if (tx_rsp_fire) begin
                        rsp_vld_q <= 1'b1;
                        rsp_tag_q <= active_tag_q;
                        if ((tx_rsp_tag_i != active_tag_q) ||
                            (tx_rsp_status_i != MBAR_STATUS_OK)) begin
                            rsp_status_q <= TMA_STATUS_MBARRIER;
                        end else begin
                            rsp_status_q <= active_status_q;
                        end
                        rsp_bytes_q <= active_total_bytes_q;
                        state_q <= ST_RESP;
                    end
                end

                default: begin
                end
            endcase

            if (gen_allocate) begin
                m_gmem_addr_q[free_mshr_idx] <=
                    {gen_gaddr[ADDR_W-1:7], 7'd0};
                m_gmem_off_q[free_mshr_idx] <= gen_gaddr[6:0];
                m_smem_addr_q[free_mshr_idx] <=
                    {gen_saddr[SMEM_ADDR_W-1:5], 5'd0};
                m_smem_off_q[free_mshr_idx] <= gen_saddr[4:0];
                m_len_q[free_mshr_idx] <= gen_segment_bytes;
                m_mask_q[free_mshr_idx] <= make_mask128(
                    gen_segment_bytes, gen_gaddr[6:0]);
                if (gen_is_load) begin
                    if (gen_in_bounds) begin
                        m_state_q[free_mshr_idx] <= M_LD_GREQ;
                    end else begin
                        m_state_q[free_mshr_idx] <= M_LD_SREQ;
                        m_data_q[free_mshr_idx] <= 1024'd0;
                    end
                end else begin
                    m_state_q[free_mshr_idx] <= M_ST_SREQ;
                end
            end

            // Register outgoing requests so every payload remains stable under
            // external backpressure.
            if (g_req_fire) begin
                g_req_vld_q <= 1'b0;
                if (g_req_id_q == GMEM_ID_W'(MSHR_ENTRIES)) begin
                    desc_fetch_pending_q <= 1'b0;
                    desc_fetch_issued_q <= 1'b1;
                end else if (g_req_write_q) begin
                    m_state_q[g_req_id_q[MSHR_IDX_W-1:0]] <= M_ST_GRSP;
                end else begin
                    m_state_q[g_req_id_q[MSHR_IDX_W-1:0]] <= M_LD_GRSP;
                end
            end
            if (!g_req_vld_q) begin
                if (desc_fetch_pending_q) begin
                    g_req_vld_q <= 1'b1;
                    g_req_write_q <= 1'b0;
                    g_req_addr_q <= active_desc_ptr_q;
                    g_req_data_q <= 1024'd0;
                    g_req_mask_q <= 128'd0;
                    g_req_id_q <= GMEM_ID_W'(MSHR_ENTRIES);
                end else if (g_send_found) begin
                    g_req_vld_q <= 1'b1;
                    g_req_write_q <= (m_state_q[g_send_idx] == M_ST_GREQ);
                    g_req_addr_q <= m_gmem_addr_q[g_send_idx];
                    g_req_data_q <= m_data_q[g_send_idx];
                    g_req_mask_q <= (m_state_q[g_send_idx] == M_ST_GREQ) ?
                                    m_mask_q[g_send_idx] : 128'd0;
                    g_req_id_q <= GMEM_ID_W'(g_send_idx);
                end
            end

            if (s_req_fire) begin
                s_req_vld_q <= 1'b0;
                if (s_req_write_q) begin
                    m_state_q[s_req_id_q[MSHR_IDX_W-1:0]] <= M_LD_SRSP;
                end else begin
                    m_state_q[s_req_id_q[MSHR_IDX_W-1:0]] <= M_ST_SRSP;
                end
            end
            if (!s_req_vld_q && s_send_found) begin
                s_req_vld_q <= 1'b1;
                s_req_write_q <= (m_state_q[s_send_idx] == M_LD_SREQ);
                s_req_addr_q <= m_smem_addr_q[s_send_idx];
                s_req_data_q <= m_data_q[s_send_idx][255:0] <<
                                (m_smem_off_q[s_send_idx] * 8);
                s_req_mask_q <= (m_state_q[s_send_idx] == M_LD_SREQ) ?
                    make_mask32(m_len_q[s_send_idx], m_smem_off_q[s_send_idx]) :
                    32'd0;
                s_req_id_q <= SMEM_ID_W'(s_send_idx);
            end

            if (g_rsp_fire) begin
                if (gmem_rsp_id_i == GMEM_ID_W'(MSHR_ENTRIES)) begin
                    if (desc_fetch_issued_q && (state_q == ST_DESC_WAIT)) begin
                        desc_fetch_issued_q <= 1'b0;
                        if (gmem_rsp_status_i != 2'd0) begin
                            rsp_vld_q <= 1'b1;
                            rsp_tag_q <= active_tag_q;
                            rsp_status_q <= TMA_STATUS_GMEM;
                            rsp_bytes_q <= 64'd0;
                            state_q <= ST_RESP;
                        end else begin
                            desc_data_q <= gmem_rsp_data_i;
                            desc_cache_vld_q[desc_replace_q] <= 1'b1;
                            desc_cache_addr_q[desc_replace_q] <= active_desc_ptr_q;
                            desc_cache_data_q[desc_replace_q] <= gmem_rsp_data_i;
                            desc_replace_q <=
                                (desc_replace_q == DESC_IDX_W'(DESC_CACHE_ENTRIES-1)) ?
                                {DESC_IDX_W{1'b0}} : desc_replace_q + DESC_IDX_W'(1);
                            state_q <= ST_SETUP;
                        end
                    end
                end else if ({1'b0, gmem_rsp_id_i} <
                             MSHR_ENTRIES_GMEM_EXT) begin
                    if (m_state_q[g_rsp_mshr_idx] == M_LD_GRSP) begin
                        m_data_q[g_rsp_mshr_idx] <= gmem_rsp_data_i >>
                            (m_gmem_off_q[g_rsp_mshr_idx] * 8);
                        m_state_q[g_rsp_mshr_idx] <= M_LD_SREQ;
                        if ((gmem_rsp_status_i != 2'd0) &&
                            (active_status_q == TMA_STATUS_OK)) begin
                            active_status_q <= TMA_STATUS_GMEM;
                            m_data_q[g_rsp_mshr_idx] <= 1024'd0;
                        end
                    end else if (m_state_q[g_rsp_mshr_idx] == M_ST_GRSP) begin
                        m_state_q[g_rsp_mshr_idx] <= M_FREE;
                        if ((gmem_rsp_status_i != 2'd0) &&
                            (active_status_q == TMA_STATUS_OK)) begin
                            active_status_q <= TMA_STATUS_GMEM;
                        end
                    end else if (active_status_q == TMA_STATUS_OK) begin
                        active_status_q <= TMA_STATUS_INTERNAL;
                    end
                end
            end

            if (s_rsp_fire && ({1'b0, smem_rsp_id_i} <
                               MSHR_ENTRIES_SMEM_EXT)) begin
                if (m_state_q[s_rsp_mshr_idx] == M_ST_SRSP) begin
                    m_data_q[s_rsp_mshr_idx] <=
                        (({{768{1'b0}}, smem_rsp_data_i} >>
                          (m_smem_off_q[s_rsp_mshr_idx] * 8)) <<
                         (m_gmem_off_q[s_rsp_mshr_idx] * 8));
                    m_state_q[s_rsp_mshr_idx] <= M_ST_GREQ;
                    if ((smem_rsp_status_i != 2'd0) &&
                        (active_status_q == TMA_STATUS_OK)) begin
                        active_status_q <= TMA_STATUS_SMEM;
                        m_data_q[s_rsp_mshr_idx] <= 1024'd0;
                        m_mask_q[s_rsp_mshr_idx] <= 128'd0;
                    end
                end else if (m_state_q[s_rsp_mshr_idx] == M_LD_SRSP) begin
                    m_state_q[s_rsp_mshr_idx] <= M_FREE;
                    if ((smem_rsp_status_i != 2'd0) &&
                        (active_status_q == TMA_STATUS_OK)) begin
                        active_status_q <= TMA_STATUS_SMEM;
                    end
                end else if (active_status_q == TMA_STATUS_OK) begin
                    active_status_q <= TMA_STATUS_INTERNAL;
                end
            end

            // Up to one allocation and two independent backend completions may
            // occur on the same cycle.
            if (!cmd_pop) begin
                active_outstanding_q <= active_outstanding_q +
                    MSHR_CNT_W'(gen_allocate) - MSHR_CNT_W'(free_rsp_count);
            end
        end
    end

    initial begin
        if (ADDR_W != 64) $error("The v1 descriptor layout requires ADDR_W=64");
        if (SMEM_ADDR_W < 32) $error("SMEM_ADDR_W must be at least 32");
        if (CMD_QUEUE_DEPTH < 2) $error("CMD_QUEUE_DEPTH must be at least two");
        if (DESC_CACHE_ENTRIES < 1) $error("DESC_CACHE_ENTRIES must be positive");
        if (MSHR_ENTRIES < 2) $error("MSHR_ENTRIES must be at least two");
        if ((1 << GMEM_ID_W) <= MSHR_ENTRIES)
            $error("GMEM_ID_W must include a reserved descriptor-fetch ID");
        if ((1 << SMEM_ID_W) < MSHR_ENTRIES)
            $error("SMEM_ID_W is too small for MSHR_ENTRIES");
    end

`ifndef SYNTHESIS
    logic                         assert_g_stalled_q;
    logic                         assert_g_write_q;
    logic [ADDR_W-1:0]            assert_g_addr_q;
    logic [1023:0]                assert_g_data_q;
    logic [127:0]                 assert_g_mask_q;
    logic [GMEM_ID_W-1:0]         assert_g_id_q;
    logic                         assert_s_stalled_q;
    logic                         assert_s_write_q;
    logic [SMEM_ADDR_W-1:0]       assert_s_addr_q;
    logic [255:0]                 assert_s_data_q;
    logic [31:0]                  assert_s_mask_q;
    logic [SMEM_ID_W-1:0]         assert_s_id_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assert_g_stalled_q <= 1'b0;
            assert_s_stalled_q <= 1'b0;
        end else begin
            if (assert_g_stalled_q) begin
                assert (gmem_req_vld_o &&
                        (gmem_req_write_o == assert_g_write_q) &&
                        (gmem_req_addr_o == assert_g_addr_q) &&
                        (gmem_req_data_o == assert_g_data_q) &&
                        (gmem_req_mask_o == assert_g_mask_q) &&
                        (gmem_req_id_o == assert_g_id_q))
                    else $error("GMEM request changed while stalled");
            end
            if (assert_s_stalled_q) begin
                assert (smem_req_vld_o &&
                        (smem_req_write_o == assert_s_write_q) &&
                        (smem_req_addr_o == assert_s_addr_q) &&
                        (smem_req_data_o == assert_s_data_q) &&
                        (smem_req_mask_o == assert_s_mask_q) &&
                        (smem_req_id_o == assert_s_id_q))
                    else $error("SMEM request changed while stalled");
            end
            assert (active_outstanding_q <= MSHR_CNT_W'(MSHR_ENTRIES))
                else $error("TMA outstanding count exceeded MSHR capacity");
            if (tx_cpl_vld_o) begin
                assert (generation_done_q && (active_outstanding_q == 0))
                    else $error("TX_COMPLETE preceded data acknowledgements");
            end

            assert_g_stalled_q <= gmem_req_vld_o && !gmem_req_rdy_i;
            assert_g_write_q <= gmem_req_write_o;
            assert_g_addr_q <= gmem_req_addr_o;
            assert_g_data_q <= gmem_req_data_o;
            assert_g_mask_q <= gmem_req_mask_o;
            assert_g_id_q <= gmem_req_id_o;
            assert_s_stalled_q <= smem_req_vld_o && !smem_req_rdy_i;
            assert_s_write_q <= smem_req_write_o;
            assert_s_addr_q <= smem_req_addr_o;
            assert_s_data_q <= smem_req_data_o;
            assert_s_mask_q <= smem_req_mask_o;
            assert_s_id_q <= smem_req_id_o;
        end
    end
`endif

endmodule

`default_nettype wire
