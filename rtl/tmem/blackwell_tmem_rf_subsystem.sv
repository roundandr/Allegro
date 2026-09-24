// Single-CTA warp RF <-> TMEM path. Bank-word grouping keeps
// the whole instruction atomic with respect to allocation changes. It captures
// every ST source register before any bank write and preflights the complete
// footprint. LD reports completion only after every RF destination beat is
// accepted. This is a functional path, not the final throughput scheduler.
`default_nettype none
module blackwell_tmem_rf_subsystem #(
    parameter int unsigned CONTEXTS = 32,
    parameter int unsigned TAG_W = 16
) (
    input wire clk, rst_n,
    input wire ctx_vld_i, output wire ctx_rdy_o,
    input wire ctx_create_i, input wire [4:0] ctx_id_i,
    input wire [15:0] ctx_epoch_i, input wire [TAG_W-1:0] ctx_tag_i,
    input wire alloc_vld_i, output wire alloc_rdy_o,
    input wire [4:0] alloc_ctx_i, input wire [15:0] alloc_epoch_i,
    input wire [9:0] alloc_columns_i, input wire [TAG_W-1:0] alloc_tag_i,
    input wire free_vld_i, output wire free_rdy_o,
    input wire [4:0] free_ctx_i, input wire [15:0] free_epoch_i,
    input wire [8:0] free_base_i, input wire [9:0] free_columns_i,
    input wire [TAG_W-1:0] free_tag_i,
    input wire relinquish_vld_i, output wire relinquish_rdy_o,
    input wire [4:0] relinquish_ctx_i, input wire [15:0] relinquish_epoch_i,
    input wire [TAG_W-1:0] relinquish_tag_i,
    output wire ctrl_rsp_vld_o, input wire ctrl_rsp_rdy_i,
    output wire [TAG_W-1:0] ctrl_rsp_tag_o,
    output wire [7:0] ctrl_rsp_status_o,
    output wire [8:0] ctrl_rsp_base_o,
    input wire cmd_vld_i, output wire cmd_rdy_o,
    input wire cmd_store_i,
    input wire [4:0] cmd_ctx_i, input wire [15:0] cmd_epoch_i,
    input wire [4:0] cmd_warp_i,
    input wire [2:0] cmd_shape_i,
    input wire [7:0] cmd_repeat_i,
    input wire cmd_pack16_i,
    input wire [31:0] cmd_base_addr_i, cmd_half_offset_i,
    input wire [TAG_W-1:0] cmd_tag_i,
    input wire rf_src_vld_i, output wire rf_src_rdy_o,
    input wire [1023:0] rf_src_data_i,
    input wire rf_src_last_i,
    output wire rf_dst_vld_o, input wire rf_dst_rdy_i,
    output wire [1023:0] rf_dst_data_o,
    output wire [7:0] rf_dst_index_o,
    output wire rf_dst_last_o,
    output wire done_vld_o, input wire done_rdy_i,
    output wire [TAG_W-1:0] done_tag_o,
    output wire done_store_o,
    output wire [7:0] done_status_o,
    input wire shift_cmd_vld_i, output wire shift_cmd_rdy_o,
    input wire [4:0] shift_cmd_ctx_i,
    input wire [15:0] shift_cmd_epoch_i,
    input wire [31:0] shift_cmd_base_addr_i,
    input wire [TAG_W-1:0] shift_cmd_tag_i,
    input wire [9:0] shift_cmd_issuer_i,
    input wire [4:0] shift_cmd_warp_i,
    input wire [63:0] shift_cmd_seq_i,
    output wire shift_register_vld_o, input wire shift_register_rdy_i,
    output blackwell_async_pkg::async_id_t shift_register_o,
    output wire shift_complete_vld_o, input wire shift_complete_rdy_i,
    output blackwell_async_pkg::async_event_t shift_complete_o,
    output wire shift_done_vld_o, input wire shift_done_rdy_i,
    output wire [TAG_W-1:0] shift_done_tag_o,
    output wire [7:0] shift_done_status_o,
    input wire wait_vld_i, output wire wait_rdy_o,
    input wire [4:0] wait_ctx_i, input wire [15:0] wait_epoch_i,
    input wire [4:0] wait_warp_i, input wire wait_store_i,
    input wire [TAG_W-1:0] wait_tag_i,
    output wire wait_rsp_vld_o, input wire wait_rsp_rdy_i,
    output wire [4:0] wait_rsp_ctx_o,
    output wire [15:0] wait_rsp_epoch_o,
    output wire [4:0] wait_rsp_warp_o,
    output wire wait_rsp_store_o,
    output wire [TAG_W-1:0] wait_rsp_tag_o,
    output wire [7:0] wait_rsp_status_o,
    output wire wait_protocol_error_o
);
    localparam logic [7:0] OK=0, BAD_ADDR=5, BAD_SHAPE=10;
    typedef enum logic [3:0] {
        IDLE, GATHER, PROBE_REQ, PROBE_RSP, FETCH_STORE_REQ,
        FETCH_STORE_RSP, READ_REQ, READ_RSP, WRITE_REQ, WRITE_RSP,
        FETCH_OUTPUT_REQ, FETCH_OUTPUT_RSP, OUTPUT_RF, DONE
    } state_t;
    state_t state_q;
    logic [4:0] ctx_q, warp_q;
    logic [15:0] epoch_q;
    logic [2:0] shape_q;
    logic [7:0] repeat_q, reg_q, out_q;
    logic [8:0] count_q;
    logic [31:0] base_q, half_offset_q;
    logic pack_q, store_q, second_q;
    logic [31:0] pending_q, issued_q;
    logic [TAG_W-1:0] tag_q;
    logic [7:0] status_q;
    logic [63:0] next_seq_q, seq_q;
    logic finish_sent_q;
    logic ctx_rsp_pending_q, ctx_rsp_create_q;
    logic [4:0] ctx_rsp_id_q;
    logic shift_active_q, shift_pending_q, shift_complete_sent_q;
    logic [4:0] shift_ctx_q;
    logic [15:0] shift_epoch_q;
    logic [31:0] shift_base_q;
    logic [TAG_W-1:0] shift_tag_q;
    blackwell_async_pkg::async_id_t shift_id_q;
    wire tracker_op_rdy, tracker_finish_rdy;
    wire tracker_op_vld = cmd_vld_i && state_q == IDLE &&
                          !control_pending && !ctrl_rsp_vld_o &&
                          !shift_active_q && !shift_pending_q && !shift_cmd_vld_i;
    wire tracker_finish_vld = state_q == DONE && !finish_sent_q;
    // Synchronous 32-bank SRAM staging. The 1024-bit response register is the
    // only full-warp flop payload; source and destination data live in SRAM.
    logic [1023:0] rf_vector_q;
    logic [1023:0] stage_wr_data;
    logic [127:0] stage_wr_mask;
    wire stage_wr_vld, stage_wr_rdy, stage_rd_rdy, stage_rd_rsp;
    wire [1023:0] stage_rd_data;
    wire [31:0] map_valid;
    wire [1023:0] map_cell0, map_cell1;
    wire group_valid;
    wire [31:0] group_selected;
    wire [31:0] pending_after_rsp = pending_q & ~issued_q;
    wire [127:0] rd_mask;
    wire [2047:0] rd_columns, wr_columns, wr_masks;
    wire [16383:0] wr_data;
    wire bank_rd_rdy, bank_rd_rsp, bank_wr_rdy, bank_wr_rsp;
    wire [16383:0] bank_rd_data;
    wire [7:0] bank_rd_status, bank_wr_status;
    wire [TAG_W-1:0] unused_rd_tag, unused_wr_tag;
    wire bank_ctx_rdy, bank_alloc_rdy, bank_free_rdy, bank_relinquish_rdy;
    wire control_window = state_q == IDLE && !shift_active_q && !shift_pending_q;
    wire control_pending = ctx_vld_i || alloc_vld_i || free_vld_i || relinquish_vld_i;
    wire shift_engine_cmd_rdy, shift_rd_vld, shift_rd_rdy;
    wire shift_engine_done_vld;
    wire [TAG_W-1:0] shift_engine_done_tag;
    wire [7:0] shift_engine_done_status;
    wire shift_rd_rsp_rdy, shift_wr_vld, shift_wr_rdy, shift_wr_rsp_rdy;
    wire [4:0] shift_rd_ctx, shift_wr_ctx;
    wire [15:0] shift_rd_epoch, shift_wr_epoch;
    wire [127:0] shift_rd_mask;
    wire [2047:0] shift_rd_columns, shift_wr_columns, shift_wr_masks;
    wire [16383:0] shift_wr_data;
    wire [TAG_W-1:0] shift_rd_tag, shift_wr_tag;
    wire rf_rd_rsp_rdy = state_q == PROBE_RSP ||
        (state_q == READ_RSP && (bank_rd_status != OK || stage_wr_rdy));
    wire rf_wr_rsp_rdy = state_q == WRITE_RSP;
    wire shift_dispatch = shift_pending_q && state_q == IDLE &&
        !ctrl_rsp_vld_o && shift_engine_cmd_rdy;
    wire shift_done_accept = shift_done_vld_o && shift_done_rdy_i;

    assign shift_register_vld_o = shift_cmd_vld_i &&
        !shift_pending_q && !shift_active_q;
    assign shift_cmd_rdy_o = !shift_pending_q && !shift_active_q &&
        shift_register_rdy_i;
    assign shift_complete_vld_o = shift_engine_done_vld && !shift_complete_sent_q;
    assign shift_done_vld_o = shift_engine_done_vld && shift_complete_sent_q;
    assign shift_done_tag_o = shift_engine_done_tag;
    assign shift_done_status_o = shift_engine_done_status;
    always_comb begin
        shift_register_o = '0;
        shift_register_o.issuer = shift_cmd_issuer_i;
        shift_register_o.warp = shift_cmd_warp_i;
        shift_register_o.tag = shift_cmd_tag_i;
        shift_register_o.seq = shift_cmd_seq_i;
        shift_register_o.epoch = shift_cmd_epoch_i;
        shift_complete_o = '0;
        shift_complete_o.id = shift_id_q;
        shift_complete_o.domain = blackwell_async_pkg::CPL_TC;
        shift_complete_o.status = shift_engine_done_status;
    end

    blackwell_tmem_shift_engine #(.TAG_W(TAG_W)) shift_engine (
        .clk,.rst_n,
        .cmd_vld_i(shift_dispatch),
        .cmd_rdy_o(shift_engine_cmd_rdy),
        .cmd_ctx_i(shift_ctx_q),.cmd_epoch_i(shift_epoch_q),
        .cmd_base_addr_i(shift_base_q),.cmd_tag_i(shift_tag_q),
        .done_vld_o(shift_engine_done_vld),.done_rdy_i(shift_done_accept),
        .done_tag_o(shift_engine_done_tag),.done_status_o(shift_engine_done_status),
        .rd_vld_o(shift_rd_vld),.rd_rdy_i(shift_rd_rdy),
        .rd_ctx_o(shift_rd_ctx),.rd_epoch_o(shift_rd_epoch),
        .rd_lane_mask_o(shift_rd_mask),.rd_column_o(shift_rd_columns),
        .rd_tag_o(shift_rd_tag),.rd_rsp_vld_i(bank_rd_rsp && shift_active_q),
        .rd_rsp_rdy_o(shift_rd_rsp_rdy),.rd_rsp_data_i(bank_rd_data),
        .rd_rsp_status_i(bank_rd_status),
        .wr_vld_o(shift_wr_vld),.wr_rdy_i(shift_wr_rdy),
        .wr_ctx_o(shift_wr_ctx),.wr_epoch_o(shift_wr_epoch),
        .wr_column_o(shift_wr_columns),.wr_data_o(shift_wr_data),
        .wr_byte_mask_o(shift_wr_masks),.wr_tag_o(shift_wr_tag),
        .wr_rsp_vld_i(bank_wr_rsp && shift_active_q),
        .wr_rsp_rdy_o(shift_wr_rsp_rdy),.wr_rsp_status_i(bank_wr_status)
    );

    blackwell_tmem_wait_tracker #(.TAG_W(TAG_W)) wait_tracker (
        .clk,.rst_n,
        .op_vld_i(tracker_op_vld),.op_rdy_o(tracker_op_rdy),
        .op_ctx_i(cmd_ctx_i),.op_epoch_i(cmd_epoch_i),
        .op_warp_i(cmd_warp_i),.op_store_i(cmd_store_i),
        .op_tag_i(cmd_tag_i),.op_seq_i(next_seq_q),
        .finish_vld_i(tracker_finish_vld),.finish_rdy_o(tracker_finish_rdy),
        .finish_ctx_i(ctx_q),.finish_epoch_i(epoch_q),
        .finish_warp_i(warp_q),.finish_store_i(store_q),
        .finish_tag_i(tag_q),.finish_seq_i(seq_q),
        .finish_status_i(status_q),
        .wait_vld_i,.wait_rdy_o,.wait_ctx_i,.wait_epoch_i,
        .wait_warp_i,.wait_store_i,.wait_tag_i,
        .clear_ctx_vld_i(ctx_rsp_pending_q && ctx_rsp_create_q &&
                         ctrl_rsp_vld_o && ctrl_rsp_rdy_i &&
                         ctrl_rsp_status_o == OK),
        .clear_ctx_i(ctx_rsp_id_q),
        .rsp_vld_o(wait_rsp_vld_o),.rsp_rdy_i(wait_rsp_rdy_i),
        .rsp_ctx_o(wait_rsp_ctx_o),.rsp_epoch_o(wait_rsp_epoch_o),
        .rsp_warp_o(wait_rsp_warp_o),.rsp_store_o(wait_rsp_store_o),
        .rsp_tag_o(wait_rsp_tag_o),.rsp_status_o(wait_rsp_status_o),
        .protocol_error_o(wait_protocol_error_o)
    );

    for (genvar t=0;t<32;t++) begin : gen_map
        blackwell_tmem_rf_map map (
            .shape_i(shape_q),.warp_i(warp_q),.thread_i(5'(t)),
            .base_addr_i(base_q),.repeat_i(repeat_q),.reg_index_i(reg_q),
            .pack16_i(pack_q),.half_offset_i(half_offset_q),
            .valid_o(map_valid[t]),
            .cell0_o(map_cell0[t*32+:32]),
            .cell1_o(map_cell1[t*32+:32]),.second_cell_o()
        );
    end
    blackwell_tmem_rf_group group_cells (
        .pending_i(pending_q),.valid_i(map_valid),
        .cell0_i(map_cell0),.cell1_i(map_cell1),
        .second_i(second_q),.pack16_i(pack_q),
        .writing_i(state_q == WRITE_REQ),.rf_data_i(rf_vector_q),
        .all_valid_o(group_valid),.selected_o(group_selected),
        .rd_lane_mask_o(rd_mask),.rd_column_o(rd_columns),
        .wr_column_o(wr_columns),.wr_byte_mask_o(wr_masks),
        .wr_data_o(wr_data)
    );
    always_comb begin
        stage_wr_data='0; stage_wr_mask='0;
        if (state_q == GATHER) begin
            stage_wr_data=rf_src_data_i;
            stage_wr_mask='1;
        end else if (state_q == READ_RSP && bank_rd_status == OK) begin
            for (int t=0;t<32;t++) begin
                if (issued_q[t]) begin
                    if (pack_q) begin
                        if (second_q) begin
                            stage_wr_data[t*32+16+:16]=
                                bank_rd_data[map_cell1[t*32+16+:7]*128+
                                             map_cell1[t*32+:2]*32+:16];
                            stage_wr_mask[t*4+2+:2]=2'b11;
                        end else begin
                            stage_wr_data[t*32+:16]=
                                bank_rd_data[map_cell0[t*32+16+:7]*128+
                                             map_cell0[t*32+:2]*32+:16];
                            stage_wr_mask[t*4+:2]=2'b11;
                        end
                    end else begin
                        stage_wr_data[t*32+:32]=
                            bank_rd_data[map_cell0[t*32+16+:7]*128+
                                         map_cell0[t*32+:2]*32+:32];
                        stage_wr_mask[t*4+:4]=4'hF;
                    end
                end
            end
        end
    end
    assign stage_wr_vld=(state_q == GATHER && rf_src_vld_i) ||
                         (state_q == READ_RSP && bank_rd_rsp && bank_rd_status == OK);
    blackwell_tmem_rf_stage rf_stage (
        .clk,.rst_n,
        .rd_vld_i(state_q == FETCH_STORE_REQ || state_q == FETCH_OUTPUT_REQ),
        .rd_rdy_o(stage_rd_rdy),
        .rd_reg_i(state_q == FETCH_OUTPUT_REQ ? out_q[6:0] : reg_q[6:0]),
        .rd_rsp_vld_o(stage_rd_rsp),
        .rd_rsp_rdy_i(state_q == FETCH_STORE_RSP || state_q == FETCH_OUTPUT_RSP),
        .rd_rsp_data_o(stage_rd_data),
        .wr_vld_i(stage_wr_vld),.wr_rdy_o(stage_wr_rdy),
        .wr_reg_i(reg_q[6:0]),.wr_data_i(stage_wr_data),
        .wr_byte_mask_i(stage_wr_mask)
    );
    blackwell_tmem_bank #(.CONTEXTS(CONTEXTS),.TAG_W(TAG_W)) bank (
        .clk,.rst_n,
        .ctx_vld_i(ctx_vld_i && control_window),.ctx_rdy_o(bank_ctx_rdy),
        .ctx_create_i,.ctx_id_i,.ctx_epoch_i,.ctx_tag_i,
        .alloc_vld_i(alloc_vld_i && control_window),.alloc_rdy_o(bank_alloc_rdy),
        .alloc_ctx_i,.alloc_epoch_i,.alloc_columns_i,.alloc_tag_i,
        .free_vld_i(free_vld_i && control_window),.free_rdy_o(bank_free_rdy),
        .free_ctx_i,.free_epoch_i,.free_base_i,.free_columns_i,.free_tag_i,
        .relinquish_vld_i(relinquish_vld_i && control_window),
        .relinquish_rdy_o(bank_relinquish_rdy),
        .relinquish_ctx_i,.relinquish_epoch_i,.relinquish_tag_i,
        .ctrl_rsp_vld_o,.ctrl_rsp_rdy_i,.ctrl_rsp_tag_o,
        .ctrl_rsp_status_o,.ctrl_rsp_base_o,
        .rd_vld_i(shift_active_q ? shift_rd_vld :
                  group_valid && (state_q == PROBE_REQ || state_q == READ_REQ)),
        .rd_rdy_o(bank_rd_rdy),
        .rd_ctx_i(shift_active_q ? shift_rd_ctx : ctx_q),
        .rd_epoch_i(shift_active_q ? shift_rd_epoch : epoch_q),
        .rd_lane_mask_i(shift_active_q ? shift_rd_mask : rd_mask),
        .rd_column_i(shift_active_q ? shift_rd_columns : rd_columns),
        .rd_tag_i(shift_active_q ? shift_rd_tag : tag_q),
        .rd_rsp_vld_o(bank_rd_rsp),
        .rd_rsp_rdy_i(shift_active_q ? shift_rd_rsp_rdy : rf_rd_rsp_rdy),
        .rd_rsp_data_o(bank_rd_data),.rd_rsp_tag_o(unused_rd_tag),
        .rd_rsp_status_o(bank_rd_status),
        .wr_vld_i(shift_active_q ? shift_wr_vld : group_valid && state_q == WRITE_REQ),
        .wr_rdy_o(bank_wr_rdy),
        .wr_ctx_i(shift_active_q ? shift_wr_ctx : ctx_q),
        .wr_epoch_i(shift_active_q ? shift_wr_epoch : epoch_q),
        .wr_column_i(shift_active_q ? shift_wr_columns : wr_columns),
        .wr_data_i(shift_active_q ? shift_wr_data : wr_data),
        .wr_byte_mask_i(shift_active_q ? shift_wr_masks : wr_masks),
        .wr_tag_i(shift_active_q ? shift_wr_tag : tag_q),
        .wr_rsp_vld_o(bank_wr_rsp),
        .wr_rsp_rdy_i(shift_active_q ? shift_wr_rsp_rdy : rf_wr_rsp_rdy),
        .wr_rsp_tag_o(unused_wr_tag),.wr_rsp_status_o(bank_wr_status)
    );
    assign shift_rd_rdy = bank_rd_rdy && shift_active_q;
    assign shift_wr_rdy = bank_wr_rdy && shift_active_q;
    assign ctx_rdy_o=bank_ctx_rdy && control_window;
    assign alloc_rdy_o=bank_alloc_rdy && control_window;
    assign free_rdy_o=bank_free_rdy && control_window;
    assign relinquish_rdy_o=bank_relinquish_rdy && control_window;
    assign cmd_rdy_o=state_q == IDLE && !shift_active_q && !shift_pending_q &&
                     !shift_cmd_vld_i && !control_pending &&
                     !ctrl_rsp_vld_o && tracker_op_rdy;
    assign rf_src_rdy_o=state_q == GATHER && stage_wr_rdy;
    assign rf_dst_vld_o=state_q == OUTPUT_RF;
    assign rf_dst_data_o=rf_vector_q;
    assign rf_dst_index_o=out_q;
    assign rf_dst_last_o={1'b0,out_q}+9'd1 == count_q;
    assign done_vld_o=state_q == DONE;
    assign done_tag_o=tag_q;
    assign done_store_o=store_q;
    assign done_status_o=status_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_seq_q<='0; seq_q<='0; finish_sent_q<=1'b0;
            ctx_rsp_pending_q<=1'b0; ctx_rsp_create_q<=1'b0;
            ctx_rsp_id_q<='0;
            shift_active_q<=1'b0; shift_pending_q<=1'b0;
            shift_complete_sent_q<=1'b0;
            shift_ctx_q<='0; shift_epoch_q<='0; shift_base_q<='0;
            shift_tag_q<='0; shift_id_q<='0;
        end else begin
            if (shift_cmd_vld_i && shift_cmd_rdy_o) begin
                shift_pending_q<=1'b1;
                shift_complete_sent_q<=1'b0;
                shift_ctx_q<=shift_cmd_ctx_i;
                shift_epoch_q<=shift_cmd_epoch_i;
                shift_base_q<=shift_cmd_base_addr_i;
                shift_tag_q<=shift_cmd_tag_i;
                shift_id_q<=shift_register_o;
            end
            if (shift_dispatch) begin
                shift_pending_q<=1'b0;
                shift_active_q<=1'b1;
            end
            if (shift_complete_vld_o && shift_complete_rdy_i)
                shift_complete_sent_q<=1'b1;
            if (shift_done_accept) shift_active_q<=1'b0;
            if (ctrl_rsp_vld_o && ctrl_rsp_rdy_i) ctx_rsp_pending_q<=1'b0;
            if (ctx_vld_i && ctx_rdy_o) begin
                ctx_rsp_pending_q<=1'b1;
                ctx_rsp_create_q<=ctx_create_i;
                ctx_rsp_id_q<=ctx_id_i;
            end
            if (cmd_vld_i && cmd_rdy_o) begin
                seq_q<=next_seq_q;
                next_seq_q<=next_seq_q+64'd1;
                finish_sent_q<=1'b0;
            end
            if (tracker_finish_vld && tracker_finish_rdy)
                finish_sent_q<=1'b1;
        end
    end

    // SRAM reads are synchronous. Hold one fetched warp register in flops
    // while its TMEM cells or RF destination are serviced.
    always_ff @(posedge clk) begin
        if (rst_n && stage_rd_rsp &&
            (state_q == FETCH_STORE_RSP || state_q == FETCH_OUTPUT_RSP))
            rf_vector_q <= stage_rd_data;
    end
    // Every bank response is retired before advancing its cell cursor.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q<=IDLE; ctx_q<='0; epoch_q<='0; warp_q<='0;
            shape_q<='0; repeat_q<='0; reg_q<='0; out_q<='0;
            count_q<='0; pending_q<='0; issued_q<='0; second_q<=1'b0;
            base_q<='0; half_offset_q<='0; pack_q<=1'b0;
            store_q<=1'b0; tag_q<='0; status_q<=OK;
        end else begin
            case (state_q)
                IDLE: if (cmd_vld_i && cmd_rdy_o) begin
                    ctx_q<=cmd_ctx_i; epoch_q<=cmd_epoch_i; warp_q<=cmd_warp_i;
                    shape_q<=cmd_shape_i; repeat_q<=cmd_repeat_i;
                    base_q<=cmd_base_addr_i; half_offset_q<=cmd_half_offset_i;
                    pack_q<=cmd_pack16_i; store_q<=cmd_store_i; tag_q<=cmd_tag_i;
                    count_q<=cmd_shape_i == 3'd2 ? (9'(cmd_repeat_i) << 1) :
                             cmd_shape_i == 3'd3 ? (9'(cmd_repeat_i) << 2) :
                             9'(cmd_repeat_i);
                    reg_q<=0; out_q<=0; pending_q<='1; issued_q<='0;
                    second_q<=1'b0; status_q<=OK;
                    if (cmd_shape_i > 3'd4 || cmd_repeat_i == 0 ||
                        (cmd_repeat_i & (cmd_repeat_i-8'd1)) != 0 ||
                        (cmd_shape_i == 3'd2 && cmd_repeat_i > 8'd64) ||
                        (cmd_shape_i == 3'd3 && cmd_repeat_i > 8'd32)) begin
                        status_q<=BAD_SHAPE; state_q<=DONE;
                    end else state_q<=cmd_store_i ? GATHER : READ_REQ;
                end
                GATHER: if (rf_src_vld_i && rf_src_rdy_o) begin
                    if (rf_src_last_i != ({1'b0,reg_q}+9'd1 == count_q)) begin
                        status_q<=BAD_SHAPE; state_q<=DONE;
                    end else if ({1'b0,reg_q}+9'd1 == count_q) begin
                        reg_q<=0; pending_q<='1; second_q<=1'b0;
                        state_q<=PROBE_REQ;
                    end else reg_q<=reg_q+8'd1;
                end
                PROBE_REQ: if (!group_valid) begin
                    status_q<=BAD_ADDR; state_q<=DONE;
                end else if (bank_rd_rdy) begin
                    issued_q<=group_selected; state_q<=PROBE_RSP;
                end
                FETCH_STORE_REQ: if (stage_rd_rdy) state_q<=FETCH_STORE_RSP;
                FETCH_STORE_RSP: if (stage_rd_rsp) state_q<=WRITE_REQ;
                READ_REQ: if (!group_valid) begin
                    status_q<=BAD_ADDR; state_q<=DONE;
                end else if (bank_rd_rdy) begin
                    issued_q<=group_selected; state_q<=READ_RSP;
                end
                WRITE_REQ: if (!group_valid) begin
                    status_q<=BAD_ADDR; state_q<=DONE;
                end else if (bank_wr_rdy) begin
                    issued_q<=group_selected; state_q<=WRITE_RSP;
                end
                PROBE_RSP, READ_RSP: if (bank_rd_rsp &&
                    (state_q == PROBE_RSP || bank_rd_status != OK || stage_wr_rdy)) begin
                    if (bank_rd_status != OK) begin
                        status_q<=bank_rd_status; state_q<=DONE;
                    end else begin
                        if (pending_after_rsp != 0) begin
                            pending_q<=pending_after_rsp;
                            state_q<=state_q == PROBE_RSP ? PROBE_REQ : READ_REQ;
                        end else begin
                            pending_q<='1;
                            if (pack_q && !second_q) begin
                                second_q<=1'b1;
                                state_q<=state_q == PROBE_RSP ? PROBE_REQ : READ_REQ;
                            end else begin
                                second_q<=1'b0;
                                if ({1'b0,reg_q}+9'd1 != count_q) begin
                                    reg_q<=reg_q+8'd1;
                                    state_q<=state_q == PROBE_RSP ? PROBE_REQ : READ_REQ;
                                end else begin
                                    reg_q<=0;
                                    if (state_q == PROBE_RSP) state_q<=FETCH_STORE_REQ;
                                    else begin out_q<=0; state_q<=FETCH_OUTPUT_REQ; end
                                end
                            end
                        end
                    end
                end
                WRITE_RSP: if (bank_wr_rsp) begin
                    if (bank_wr_status != OK) begin
                        status_q<=bank_wr_status; state_q<=DONE;
                    end else begin
                        if (pending_after_rsp != 0) begin
                            pending_q<=pending_after_rsp;
                            state_q<=WRITE_REQ;
                        end else begin
                            pending_q<='1;
                            if (pack_q && !second_q) begin
                                second_q<=1'b1;
                                state_q<=WRITE_REQ;
                            end else begin
                                second_q<=1'b0;
                                if ({1'b0,reg_q}+9'd1 != count_q) begin
                                    reg_q<=reg_q+8'd1;
                                    state_q<=FETCH_STORE_REQ;
                                end else state_q<=DONE;
                            end
                        end
                    end
                end
                FETCH_OUTPUT_REQ: if (stage_rd_rdy) state_q<=FETCH_OUTPUT_RSP;
                FETCH_OUTPUT_RSP: if (stage_rd_rsp) state_q<=OUTPUT_RF;
                OUTPUT_RF: if (rf_dst_rdy_i) begin
                    if ({1'b0,out_q}+9'd1 == count_q) state_q<=DONE;
                    else begin out_q<=out_q+8'd1; state_q<=FETCH_OUTPUT_REQ; end
                end
                DONE: if (done_rdy_i) state_q<=IDLE;
                default: state_q<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
