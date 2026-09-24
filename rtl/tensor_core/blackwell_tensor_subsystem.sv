// ============================================================================
// File Name   : blackwell_tensor_subsystem.sv
// Description : Standalone Blackwell-style dense FP16 M64N8K16 subsystem.
// ============================================================================

`default_nettype none

module blackwell_tensor_subsystem #(
    parameter int unsigned TMEM_BANKS       = 8,
    parameter int unsigned TMEM_BASE_DEPTH  = 128,
    parameter int unsigned STAGING_DEPTH    = 2,
    parameter int unsigned TC_REG_SLICE     = 1,
    parameter int unsigned TMEM_PORT_MODE   = 0,
    parameter int unsigned SMEM_READ_PORTS  = 2
) (
    input  logic          clk,
    input  logic          rst_n,

    input  logic          cmd_vld_i,
    output logic          cmd_rdy_o,
    input  logic [2:0]    cmd_opcode_i,
    input  logic [15:0]   cmd_tag_i,
    input  logic [31:0]   cmd_a_base_i,
    input  logic [31:0]   cmd_b_base_i,
    input  logic [31:0]   cmd_dst_base_i,
    input  logic          cmd_tile_slot_i,
    input  logic          cmd_accumulate_i,
    input  logic [15:0]   cmd_wait_token_i,

    output logic          completion_vld_o,
    input  logic          completion_rdy_i,
    output logic [15:0]   completion_tag_o,
    output logic [2:0]    completion_opcode_o,
    output logic [7:0]    completion_status_o,
    output logic [15:0]   completion_token_o,

    output logic          smem_a_req_vld_o,
    input  logic          smem_a_req_rdy_i,
    output logic [31:0]   smem_a_req_addr_o,
    output logic [3:0]    smem_a_req_source_o,
    input  logic          smem_a_rsp_vld_i,
    output logic          smem_a_rsp_rdy_o,
    input  logic [255:0]  smem_a_rsp_data_i,
    input  logic [3:0]    smem_a_rsp_source_i,
    input  logic [1:0]    smem_a_rsp_status_i,

    output logic          smem_b_req_vld_o,
    input  logic          smem_b_req_rdy_i,
    output logic [31:0]   smem_b_req_addr_o,
    output logic [3:0]    smem_b_req_source_o,
    input  logic          smem_b_rsp_vld_i,
    output logic          smem_b_rsp_rdy_o,
    input  logic [255:0]  smem_b_rsp_data_i,
    input  logic [3:0]    smem_b_rsp_source_i,
    input  logic [1:0]    smem_b_rsp_status_i,

    output logic          smem_wr_req_vld_o,
    input  logic          smem_wr_req_rdy_i,
    output logic [31:0]   smem_wr_req_addr_o,
    output logic [255:0]  smem_wr_req_data_o,
    output logic [31:0]   smem_wr_req_mask_o,
    output logic [3:0]    smem_wr_req_source_o,
    input  logic          smem_wr_rsp_vld_i,
    output logic          smem_wr_rsp_rdy_o,
    input  logic [3:0]    smem_wr_rsp_source_i,
    input  logic [1:0]    smem_wr_rsp_status_i,


    input  logic          perf_clear_i,
    output logic [31:0]   perf_smem_stall_o,
    output logic [31:0]   perf_tc_busy_o,
    output logic [31:0]   perf_tmem_conflict_o,
    output logic [31:0]   perf_tmem_stall_o,
    output logic [31:0]   perf_writeback_stall_o,
    output logic [31:0]   perf_issued_o,
    output logic [31:0]   perf_completed_o
);
    import blackwell_pkg::*;

    localparam logic [3:0] ST_IDLE            = 4'd0;
    localparam logic [3:0] ST_MMA_B_REQ       = 4'd1;
    localparam logic [3:0] ST_MMA_B_RSP       = 4'd2;
    localparam logic [3:0] ST_MMA_ACC_REQ     = 4'd3;
    localparam logic [3:0] ST_MMA_ACC_RSP     = 4'd4;
    localparam logic [3:0] ST_MMA_A_REQ       = 4'd5;
    localparam logic [3:0] ST_MMA_A_RSP       = 4'd6;
    localparam logic [3:0] ST_MMA_TC_ISSUE    = 4'd7;
    localparam logic [3:0] ST_MMA_TC_WAIT     = 4'd8;
    localparam logic [3:0] ST_STORE_RD_REQ    = 4'd9;
    localparam logic [3:0] ST_STORE_RD_RSP    = 4'd10;
    localparam logic [3:0] ST_STORE_WR_REQ    = 4'd11;
    localparam logic [3:0] ST_STORE_WR_RSP    = 4'd12;
    localparam logic [3:0] ST_WAIT_TOKEN      = 4'd13;
    localparam int unsigned STAGE_PTR_W = (STAGING_DEPTH <= 1) ? 1 : $clog2(STAGING_DEPTH);
    localparam int unsigned STAGE_CNT_W = $clog2(STAGING_DEPTH + 1);

    logic [3:0] state_q;
    logic [15:0] active_tag_q;
    logic [2:0] active_opcode_q;
    logic [31:0] a_base_q;
    logic [31:0] b_base_q;
    logic [31:0] dst_base_q;
    logic tile_slot_q;
    logic accumulate_q;
    logic [15:0] wait_token_q;
    logic [5:0] row_q;
    logic [2:0] b_col_q;

    logic [255:0] b_buf_q [0:7];
    logic [255:0] a_stage_q [0:STAGING_DEPTH-1];
    logic [1:0] a_stage_status_q [0:STAGING_DEPTH-1];
    logic [STAGE_PTR_W-1:0] a_stage_wr_ptr_q;
    logic [STAGE_PTR_W-1:0] a_stage_rd_ptr_q;
    logic [STAGE_CNT_W-1:0] a_stage_count_q;
    logic [6:0] a_fetch_index_q;
    logic [3:0] a_fetch_source_q;
    logic a_fetch_active_q;
    logic a_fetch_outstanding_q;
    logic [255:0] a_row_q;
    logic [255:0] acc_row_q;
    logic [255:0] store_row_q;

    logic completion_vld_q;
    logic [15:0] completion_tag_q;
    logic [2:0] completion_opcode_q;
    logic [7:0] completion_status_q;
    logic [15:0] completion_token_q;

    logic [15:0] issued_watermark_q;
    logic [15:0] retired_watermark_q;
    logic active_work_q;

    logic [31:0] perf_smem_stall_q;
    logic [31:0] perf_tc_busy_q;
    logic [31:0] perf_tmem_conflict_q;
    logic [31:0] perf_tmem_stall_q;
    logic [31:0] perf_writeback_stall_q;
    logic [31:0] perf_issued_q;
    logic [31:0] perf_completed_q;

    logic cmd_fire;
    logic cmd_rdy_comb;
    logic completion_fire;
    logic completion_slot_rdy;
    logic alignment_error;

    logic [7:0] tmem_rd_vld;
    logic [7:0] tmem_rd_rdy;
    logic [7:0] tmem_rd_slot;
    logic [47:0] tmem_rd_row;
    logic [23:0] tmem_rd_col;
    logic [31:0] tmem_rd_tag;
    logic [7:0] tmem_rd_conflict;
    logic [7:0] tmem_rsp_vld;
    logic [7:0] tmem_rsp_rdy;
    logic [255:0] tmem_rsp_data;
    logic [31:0] tmem_rsp_tag;
    logic [7:0] tmem_rsp_error;
    logic tmem_all_req_rdy;
    logic tmem_all_rsp_vld;
    logic tmem_row_wr_vld;
    logic tmem_row_wr_rdy;
    logic [255:0] tmem_row_wr_data;

    logic tc_in_vld;
    logic tc_in_rdy;
    logic [2047:0] tc_b_vec;
    logic tc_out_vld;
    logic tc_out_rdy;
    logic [255:0] tc_d_vec;
    logic [7:0] tc_status;
    logic [6:0] tc_tag;

    logic smem_stall_cycle;
    logic tmem_stall_cycle;
    logic writeback_stall_cycle;
    logic smem_b_req_rdy_eff;
    logic smem_b_rsp_vld_eff;
    logic [255:0] smem_b_rsp_data_eff;
    logic [1:0] smem_b_rsp_status_eff;
    logic [3:0] smem_b_rsp_source_eff;
    logic a_prefetch_start;
    logic a_prefetch_abort;
    logic a_prefetch_req_vld;
    logic a_prefetch_req_fire;
    logic a_prefetch_rsp_rdy;
    logic a_prefetch_rsp_fire;
    logic a_stage_vld;
    logic a_stage_pop;
    logic [255:0] a_stage_data;
    logic [1:0] a_stage_status;


    assign completion_slot_rdy = !completion_vld_q || completion_rdy_i;
    assign completion_fire = completion_vld_q && completion_rdy_i;
    assign completion_vld_o = completion_vld_q;
    assign completion_tag_o = completion_tag_q;
    assign completion_opcode_o = completion_opcode_q;
    assign completion_status_o = completion_status_q;
    assign completion_token_o = completion_token_q;

    assign alignment_error = ((cmd_opcode_i == BW_CMD_MMA) &&
                              ((cmd_a_base_i[4:0] != 5'd0) ||
                               (cmd_b_base_i[4:0] != 5'd0))) ||
                             ((cmd_opcode_i == BW_CMD_STORE) &&
                              (cmd_dst_base_i[4:0] != 5'd0));

    always_comb begin
        cmd_rdy_comb = 1'b0;
        if ((state_q == ST_IDLE) && completion_slot_rdy &&
            !a_fetch_outstanding_q) begin
            cmd_rdy_comb = 1'b1;
        end
    end
    assign cmd_rdy_o = cmd_rdy_comb;
    assign cmd_fire = cmd_vld_i && cmd_rdy_o;

    assign a_prefetch_req_vld = a_fetch_active_q && !a_fetch_outstanding_q &&
                                (a_fetch_index_q < 7'd64) &&
                                (a_stage_count_q < STAGE_CNT_W'(STAGING_DEPTH));
    assign a_prefetch_rsp_rdy = a_fetch_outstanding_q &&
                                (a_stage_count_q < STAGE_CNT_W'(STAGING_DEPTH));
    assign smem_a_req_vld_o = a_prefetch_req_vld ||
                              ((SMEM_READ_PORTS == 1) && (state_q == ST_MMA_B_REQ));
    assign smem_a_req_addr_o = (state_q == ST_MMA_B_REQ) ?
                               (b_base_q + {24'd0, b_col_q, 5'd0}) :
                               (a_base_q + {20'd0, a_fetch_index_q[5:0], 5'd0});
    assign smem_a_req_source_o = (state_q == ST_MMA_B_REQ) ?
                                 {1'b0, b_col_q} : a_fetch_index_q[3:0];
    assign smem_a_rsp_rdy_o = a_prefetch_rsp_rdy ||
                              ((SMEM_READ_PORTS == 1) && (state_q == ST_MMA_B_RSP));
    assign a_prefetch_req_fire = a_prefetch_req_vld && smem_a_req_rdy_i &&
                                 !((SMEM_READ_PORTS == 1) && (state_q == ST_MMA_B_REQ));
    assign a_prefetch_rsp_fire = a_prefetch_rsp_rdy && smem_a_rsp_vld_i &&
                                 !((SMEM_READ_PORTS == 1) && (state_q == ST_MMA_B_RSP));
    assign a_prefetch_start = (state_q == ST_MMA_B_RSP) && smem_b_rsp_vld_eff &&
                              (smem_b_rsp_status_eff == 2'd0) &&
                              (b_col_q == 3'd7);
    assign a_prefetch_abort = ((state_q == ST_MMA_TC_WAIT) && tc_out_vld &&
                               tc_out_rdy && ((tc_status != 8'h00) ||
                               (tc_tag != {tile_slot_q, row_q}))) ||
                              ((state_q == ST_MMA_A_REQ) && a_stage_vld &&
                               (a_stage_status != 2'd0));
    assign a_stage_vld = (a_stage_count_q != 0);
    assign a_stage_data = a_stage_q[a_stage_rd_ptr_q];
    assign a_stage_status = a_stage_status_q[a_stage_rd_ptr_q];
    assign a_stage_pop = (state_q == ST_MMA_A_REQ) && a_stage_vld;

    assign smem_b_req_vld_o = (SMEM_READ_PORTS == 2) && (state_q == ST_MMA_B_REQ);
    assign smem_b_req_addr_o = b_base_q + {24'd0, b_col_q, 5'd0};
    assign smem_b_req_source_o = {1'b0, b_col_q};
    assign smem_b_rsp_rdy_o = (SMEM_READ_PORTS == 2) && (state_q == ST_MMA_B_RSP);
    assign smem_b_req_rdy_eff = (SMEM_READ_PORTS == 1) ?
                                smem_a_req_rdy_i : smem_b_req_rdy_i;
    assign smem_b_rsp_vld_eff = (SMEM_READ_PORTS == 1) ?
                                smem_a_rsp_vld_i : smem_b_rsp_vld_i;
    assign smem_b_rsp_data_eff = (SMEM_READ_PORTS == 1) ?
                                 smem_a_rsp_data_i : smem_b_rsp_data_i;
    assign smem_b_rsp_status_eff = (SMEM_READ_PORTS == 1) ?
                                   smem_a_rsp_status_i : smem_b_rsp_status_i;
    assign smem_b_rsp_source_eff = (SMEM_READ_PORTS == 1) ?
                                   smem_a_rsp_source_i : smem_b_rsp_source_i;

    assign smem_wr_req_vld_o = (state_q == ST_STORE_WR_REQ);
    assign smem_wr_req_addr_o = dst_base_q + {21'd0, row_q, 5'd0};
    assign smem_wr_req_data_o = store_row_q;
    assign smem_wr_req_mask_o = 32'hffff_ffff;
    assign smem_wr_req_source_o = row_q[3:0];
    assign smem_wr_rsp_rdy_o = (state_q == ST_STORE_WR_RSP);

    always_comb begin
        tmem_rd_vld  = 8'h00;
        tmem_rd_slot = {8{tile_slot_q}};
        tmem_rd_row  = {8{row_q}};
        tmem_rd_col  = 24'h00fac688;
        tmem_rd_tag  = 32'h76543210;
        tmem_rsp_rdy = 8'h00;

        if ((state_q == ST_MMA_ACC_REQ) || (state_q == ST_STORE_RD_REQ)) begin
            tmem_rd_vld = 8'hff;
        end
        if ((state_q == ST_MMA_ACC_RSP) || (state_q == ST_STORE_RD_RSP)) begin
            tmem_rsp_rdy = 8'hff;
        end
    end

    assign tmem_all_req_rdy = &tmem_rd_rdy;
    assign tmem_all_rsp_vld = &tmem_rsp_vld;
    assign tmem_row_wr_vld = (state_q == ST_MMA_TC_WAIT) && tc_out_vld &&
                              (tc_status == 8'h00);
    assign tmem_row_wr_data = tc_d_vec;

    tmem_array #(
        .BANKS      (TMEM_BANKS),
        .BASE_DEPTH(TMEM_BASE_DEPTH),
        .READ_PORTS(8),
        .DATA_W     (32),
        .TAG_W      (4),
        .PORT_MODE  (TMEM_PORT_MODE)
    ) u_tmem_array (
        .clk             (clk),
        .rst_n           (rst_n),
        .rd_vld_i        (tmem_rd_vld),
        .rd_rdy_o        (tmem_rd_rdy),
        .rd_slot_i       (tmem_rd_slot),
        .rd_row_i        (tmem_rd_row),
        .rd_col_i        (tmem_rd_col),
        .rd_tag_i        (tmem_rd_tag),
        .rd_conflict_o   (tmem_rd_conflict),
        .rsp_vld_o       (tmem_rsp_vld),
        .rsp_rdy_i       (tmem_rsp_rdy),
        .rsp_data_o      (tmem_rsp_data),
        .rsp_tag_o       (tmem_rsp_tag),
        .rsp_error_o     (tmem_rsp_error),
        .row_wr_vld_i    (tmem_row_wr_vld),
        .row_wr_rdy_o    (tmem_row_wr_rdy),
        .row_wr_slot_i   (tile_slot_q),
        .row_wr_row_i    (row_q),
        .row_wr_data_i   (tmem_row_wr_data),
        .row_wr_mask_i   (8'hff)
    );

    always_comb begin
        for (int unsigned lane_idx = 0; lane_idx < 8; lane_idx = lane_idx + 1) begin
            tc_b_vec[lane_idx*256 +: 256] = b_buf_q[lane_idx];
        end
    end

    assign tc_in_vld = (state_q == ST_MMA_TC_ISSUE);
    assign tc_out_rdy = (tc_status == 8'h00) ? tmem_row_wr_rdy : 1'b1;

    tcgen05_tensor_wrapper #(
        .LANES(8),
        .TAG_W(7),
        .REG_SLICE(TC_REG_SLICE)
    ) u_tcgen05_tensor_wrapper (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_vld_i    (tc_in_vld),
        .in_rdy_o    (tc_in_rdy),
        .a_vec_i     (a_row_q),
        .b_vec_i     (tc_b_vec),
        .c_vec_i     (acc_row_q),
        .accumulate_i(accumulate_q),
        .tag_i       ({tile_slot_q, row_q}),
        .out_vld_o   (tc_out_vld),
        .out_rdy_i   (tc_out_rdy),
        .d_vec_o     (tc_d_vec),
        .status_o    (tc_status),
        .tag_o       (tc_tag)
    );

    assign smem_stall_cycle =
        (smem_a_req_vld_o && !smem_a_req_rdy_i) ||
        (a_prefetch_req_vld && !smem_a_req_rdy_i) ||
        (a_fetch_outstanding_q && !smem_a_rsp_vld_i) ||
        (((state_q == ST_MMA_B_REQ) && !smem_b_req_rdy_eff)) ||
        ((state_q == ST_MMA_B_RSP) && !smem_b_rsp_vld_eff);
    assign tmem_stall_cycle =
        (((state_q == ST_MMA_ACC_REQ) || (state_q == ST_STORE_RD_REQ)) &&
         !tmem_all_req_rdy) ||
        ((state_q == ST_MMA_TC_WAIT) && tc_out_vld && !tc_out_rdy);
    assign writeback_stall_cycle =
        (smem_wr_req_vld_o && !smem_wr_req_rdy_i) ||
        ((state_q == ST_STORE_WR_RSP) && !smem_wr_rsp_vld_i);

    assign perf_smem_stall_o = perf_smem_stall_q;
    assign perf_tc_busy_o = perf_tc_busy_q;
    assign perf_tmem_conflict_o = perf_tmem_conflict_q;
    assign perf_tmem_stall_o = perf_tmem_stall_q;
    assign perf_writeback_stall_o = perf_writeback_stall_q;
    assign perf_issued_o = perf_issued_q;
    assign perf_completed_o = perf_completed_q;

    // A operand fetch runs independently from the compute FSM. The FIFO
    // provides actual latency decoupling for depth 1/2/4 and reserves space
    // before issuing its single outstanding SMEM request.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_stage_wr_ptr_q <= '0;
            a_stage_rd_ptr_q <= '0;
            a_stage_count_q <= '0;
            a_fetch_index_q <= 7'd0;
            a_fetch_source_q <= 4'd0;
            a_fetch_active_q <= 1'b0;
            a_fetch_outstanding_q <= 1'b0;
            for (int unsigned fifo_rst_idx = 0; fifo_rst_idx < STAGING_DEPTH;
                 fifo_rst_idx = fifo_rst_idx + 1) begin
                a_stage_q[fifo_rst_idx] <= 256'd0;
                a_stage_status_q[fifo_rst_idx] <= 2'd0;
            end
        end else if (a_prefetch_start) begin
            a_stage_wr_ptr_q <= '0;
            a_stage_rd_ptr_q <= '0;
            a_stage_count_q <= '0;
            a_fetch_index_q <= 7'd0;
            a_fetch_source_q <= 4'd0;
            a_fetch_active_q <= 1'b1;
            a_fetch_outstanding_q <= 1'b0;
        end else begin
            if (a_prefetch_abort) a_fetch_active_q <= 1'b0;

            if (a_prefetch_req_fire) begin
                a_fetch_outstanding_q <= 1'b1;
                a_fetch_source_q <= a_fetch_index_q[3:0];
                a_fetch_index_q <= a_fetch_index_q + 7'd1;
            end
            if (a_prefetch_rsp_fire) begin
                a_fetch_outstanding_q <= 1'b0;
                a_stage_q[a_stage_wr_ptr_q] <= smem_a_rsp_data_i;
                a_stage_status_q[a_stage_wr_ptr_q] <= smem_a_rsp_status_i |
                    ((smem_a_rsp_source_i == a_fetch_source_q) ? 2'd0 : 2'd1);
                if (a_stage_wr_ptr_q == STAGE_PTR_W'(STAGING_DEPTH - 1))
                    a_stage_wr_ptr_q <= '0;
                else
                    a_stage_wr_ptr_q <= a_stage_wr_ptr_q + STAGE_PTR_W'(1);
            end
            if (a_stage_pop) begin
                if (a_stage_rd_ptr_q == STAGE_PTR_W'(STAGING_DEPTH - 1))
                    a_stage_rd_ptr_q <= '0;
                else
                    a_stage_rd_ptr_q <= a_stage_rd_ptr_q + STAGE_PTR_W'(1);
            end

            case ({a_prefetch_rsp_fire, a_stage_pop})
                2'b10: a_stage_count_q <= a_stage_count_q + STAGE_CNT_W'(1);
                2'b01: a_stage_count_q <= a_stage_count_q - STAGE_CNT_W'(1);
                default: a_stage_count_q <= a_stage_count_q;
            endcase
            if ((a_fetch_index_q == 7'd64) && !a_fetch_outstanding_q)
                a_fetch_active_q <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            active_tag_q <= 16'd0;
            active_opcode_q <= BW_CMD_MMA;
            a_base_q <= 32'd0;
            b_base_q <= 32'd0;
            dst_base_q <= 32'd0;
            tile_slot_q <= 1'b0;
            accumulate_q <= 1'b0;
            wait_token_q <= 16'd0;
            row_q <= 6'd0;
            b_col_q <= 3'd0;
            a_row_q <= 256'd0;
            acc_row_q <= 256'd0;
            store_row_q <= 256'd0;
            completion_vld_q <= 1'b0;
            completion_tag_q <= 16'd0;
            completion_opcode_q <= BW_CMD_MMA;
            completion_status_q <= BW_STATUS_OK;
            completion_token_q <= 16'd0;
            issued_watermark_q <= 16'd0;
            retired_watermark_q <= 16'd0;
            active_work_q <= 1'b0;
        end else begin
            if (completion_fire) begin
                completion_vld_q <= 1'b0;
            end

            case (state_q)
                ST_IDLE: begin
                    if (cmd_fire) begin
                        active_tag_q <= cmd_tag_i;
                        active_opcode_q <= cmd_opcode_i;
                        a_base_q <= cmd_a_base_i;
                        b_base_q <= cmd_b_base_i;
                        dst_base_q <= cmd_dst_base_i;
                        tile_slot_q <= cmd_tile_slot_i;
                        accumulate_q <= cmd_accumulate_i;
                        wait_token_q <= cmd_wait_token_i;
                        row_q <= 6'd0;
                        b_col_q <= 3'd0;

                        if (alignment_error) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= cmd_tag_i;
                            completion_opcode_q <= cmd_opcode_i;
                            completion_status_q <= BW_STATUS_BAD_ALIGNMENT;
                            completion_token_q <= issued_watermark_q;
                        end else begin
                            case (cmd_opcode_i)
                                BW_CMD_MMA: begin
                                    issued_watermark_q <= issued_watermark_q + 16'd1;
                                    active_work_q <= 1'b1;
                                    state_q <= ST_MMA_B_REQ;
                                end
                                BW_CMD_COMMIT: begin
                                    completion_vld_q <= 1'b1;
                                    completion_tag_q <= cmd_tag_i;
                                    completion_opcode_q <= cmd_opcode_i;
                                    completion_status_q <= BW_STATUS_OK;
                                    completion_token_q <= issued_watermark_q;
                                end
                                BW_CMD_WAIT: begin
                                    if (retired_watermark_q >= cmd_wait_token_i) begin
                                        completion_vld_q <= 1'b1;
                                        completion_tag_q <= cmd_tag_i;
                                        completion_opcode_q <= cmd_opcode_i;
                                        completion_status_q <= BW_STATUS_OK;
                                        completion_token_q <= cmd_wait_token_i;
                                    end else begin
                                        state_q <= ST_WAIT_TOKEN;
                                    end
                                end
                                BW_CMD_STORE: begin
                                    issued_watermark_q <= issued_watermark_q + 16'd1;
                                    active_work_q <= 1'b1;
                                    state_q <= ST_STORE_RD_REQ;
                                end
                                default: begin
                                    completion_vld_q <= 1'b1;
                                    completion_tag_q <= cmd_tag_i;
                                    completion_opcode_q <= cmd_opcode_i;
                                    completion_status_q <= BW_STATUS_BAD_OPCODE;
                                    completion_token_q <= issued_watermark_q;
                                end
                            endcase
                        end
                    end
                end

                ST_MMA_B_REQ: begin
                    if (((SMEM_READ_PORTS == 1) && smem_a_req_vld_o && smem_a_req_rdy_i) ||
                        ((SMEM_READ_PORTS == 2) && smem_b_req_vld_o && smem_b_req_rdy_i)) begin
                        state_q <= ST_MMA_B_RSP;
                    end
                end

                ST_MMA_B_RSP: begin
                    if (smem_b_rsp_vld_eff &&
                        (((SMEM_READ_PORTS == 1) && smem_a_rsp_rdy_o) ||
                         ((SMEM_READ_PORTS == 2) && smem_b_rsp_rdy_o))) begin
                        if ((smem_b_rsp_status_eff != 2'd0) ||
                            (smem_b_rsp_source_eff != {1'b0, b_col_q})) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_SMEM_READ;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            retired_watermark_q <= issued_watermark_q;
                            state_q <= ST_IDLE;
                        end else begin
                            b_buf_q[b_col_q] <= smem_b_rsp_data_eff;
                            if (b_col_q == 3'd7) begin
                                row_q <= 6'd0;
                                state_q <= accumulate_q ? ST_MMA_ACC_REQ : ST_MMA_A_REQ;
                                if (!accumulate_q) acc_row_q <= 256'd0;
                            end else begin
                                b_col_q <= b_col_q + 3'd1;
                                state_q <= ST_MMA_B_REQ;
                            end
                        end
                    end
                end

                ST_MMA_ACC_REQ: begin
                    if (tmem_all_req_rdy) state_q <= ST_MMA_ACC_RSP;
                end

                ST_MMA_ACC_RSP: begin
                    if (tmem_all_rsp_vld) begin
                        if ((|tmem_rsp_error) || (tmem_rsp_tag != 32'h76543210)) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_TMEM;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            state_q <= ST_IDLE;
                        end else begin
                            acc_row_q <= tmem_rsp_data;
                            state_q <= ST_MMA_A_REQ;
                        end
                    end
                end

                ST_MMA_A_REQ: begin
                    if (a_stage_vld) begin
                        if (a_stage_status != 2'd0) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_SMEM_READ;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            retired_watermark_q <= issued_watermark_q;
                            state_q <= ST_IDLE;
                        end else begin
                            a_row_q <= a_stage_data;
                            state_q <= ST_MMA_TC_ISSUE;
                        end
                    end
                end

                ST_MMA_A_RSP: state_q <= ST_MMA_A_REQ;

                ST_MMA_TC_ISSUE: begin
                    if (tc_in_vld && tc_in_rdy) state_q <= ST_MMA_TC_WAIT;
                end

                ST_MMA_TC_WAIT: begin
                    if (tc_out_vld && tc_out_rdy) begin
                        if ((tc_status != 8'h00) ||
                            (tc_tag != {tile_slot_q, row_q})) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_TC;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            retired_watermark_q <= issued_watermark_q;
                            state_q <= ST_IDLE;
                        end else if (row_q == 6'd63) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_OK;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            retired_watermark_q <= issued_watermark_q;
                            state_q <= ST_IDLE;
                        end else begin
                            row_q <= row_q + 6'd1;
                            if (!accumulate_q) acc_row_q <= 256'd0;
                            state_q <= accumulate_q ? ST_MMA_ACC_REQ : ST_MMA_A_REQ;
                        end
                    end
                end

                ST_STORE_RD_REQ: begin
                    if (tmem_all_req_rdy) state_q <= ST_STORE_RD_RSP;
                end

                ST_STORE_RD_RSP: begin
                    if (tmem_all_rsp_vld) begin
                        if ((|tmem_rsp_error) || (tmem_rsp_tag != 32'h76543210)) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_TMEM;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            state_q <= ST_IDLE;
                        end else begin
                            store_row_q <= tmem_rsp_data;
                            state_q <= ST_STORE_WR_REQ;
                        end
                    end
                end

                ST_STORE_WR_REQ: begin
                    if (smem_wr_req_vld_o && smem_wr_req_rdy_i) state_q <= ST_STORE_WR_RSP;
                end

                ST_STORE_WR_RSP: begin
                    if (smem_wr_rsp_vld_i && smem_wr_rsp_rdy_o) begin
                        if ((smem_wr_rsp_status_i != 2'd0) ||
                            (smem_wr_rsp_source_i != row_q[3:0])) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_SMEM_WRITE;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            retired_watermark_q <= issued_watermark_q;
                            state_q <= ST_IDLE;
                        end else if (row_q == 6'd63) begin
                            completion_vld_q <= 1'b1;
                            completion_tag_q <= active_tag_q;
                            completion_opcode_q <= active_opcode_q;
                            completion_status_q <= BW_STATUS_OK;
                            completion_token_q <= issued_watermark_q;
                            active_work_q <= 1'b0;
                            retired_watermark_q <= issued_watermark_q;
                            state_q <= ST_IDLE;
                        end else begin
                            row_q <= row_q + 6'd1;
                            state_q <= ST_STORE_RD_REQ;
                        end
                    end
                end

                ST_WAIT_TOKEN: begin
                    if ((retired_watermark_q >= wait_token_q) && completion_slot_rdy) begin
                        completion_vld_q <= 1'b1;
                        completion_tag_q <= active_tag_q;
                        completion_opcode_q <= active_opcode_q;
                        completion_status_q <= BW_STATUS_OK;
                        completion_token_q <= wait_token_q;
                        state_q <= ST_IDLE;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase

            // Tensor COMMIT/WAIT covers accepted Tensor work only.
            if (!active_work_q) begin
                retired_watermark_q <= issued_watermark_q;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_smem_stall_q <= 32'd0;
            perf_tc_busy_q <= 32'd0;
            perf_tmem_conflict_q <= 32'd0;
            perf_tmem_stall_q <= 32'd0;
            perf_writeback_stall_q <= 32'd0;
            perf_issued_q <= 32'd0;
            perf_completed_q <= 32'd0;
        end else if (perf_clear_i) begin
            perf_smem_stall_q <= 32'd0;
            perf_tc_busy_q <= 32'd0;
            perf_tmem_conflict_q <= 32'd0;
            perf_tmem_stall_q <= 32'd0;
            perf_writeback_stall_q <= 32'd0;
            perf_issued_q <= 32'd0;
            perf_completed_q <= 32'd0;
        end else begin
            if (smem_stall_cycle) perf_smem_stall_q <= perf_smem_stall_q + 32'd1;
            if ((state_q == ST_MMA_TC_ISSUE) || (state_q == ST_MMA_TC_WAIT))
                perf_tc_busy_q <= perf_tc_busy_q + 32'd1;
            if (|tmem_rd_conflict) perf_tmem_conflict_q <= perf_tmem_conflict_q + 32'd1;
            if (tmem_stall_cycle) perf_tmem_stall_q <= perf_tmem_stall_q + 32'd1;
            if (writeback_stall_cycle) perf_writeback_stall_q <= perf_writeback_stall_q + 32'd1;
            if (cmd_fire) perf_issued_q <= perf_issued_q + 32'd1;
            if (completion_fire) perf_completed_q <= perf_completed_q + 32'd1;
        end
    end

    initial begin
        if ((STAGING_DEPTH != 1) && (STAGING_DEPTH != 2) && (STAGING_DEPTH != 4))
            $error("STAGING_DEPTH must be 1, 2, or 4");
        if (TC_REG_SLICE > 2) $error("TC_REG_SLICE must be 0, 1, or 2");
        if ((TMEM_PORT_MODE != 0) && (TMEM_PORT_MODE != 1) && (TMEM_PORT_MODE != 2))
            $error("TMEM_PORT_MODE must be 0, 1, or 2");
        if ((SMEM_READ_PORTS != 1) && (SMEM_READ_PORTS != 2))
            $error("SMEM_READ_PORTS must be 1 or 2");
    end

endmodule

`default_nettype wire
