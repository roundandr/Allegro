// Single-CTA tcgen05.shift.down data mover. The complete 32x8-cell source
// footprint is checked before any destination word can be changed. Each
// column is then read into a 32-cell register before the overlapping write.
// SHIFT completion belongs to the TC commit domain, never to wait::ld/st.
`default_nettype none
module blackwell_tmem_shift_engine #(
    parameter int unsigned TAG_W = 16
) (
    input wire clk, rst_n,
    input wire cmd_vld_i, output wire cmd_rdy_o,
    input wire [4:0] cmd_ctx_i, input wire [15:0] cmd_epoch_i,
    input wire [31:0] cmd_base_addr_i,
    input wire [TAG_W-1:0] cmd_tag_i,
    output wire done_vld_o, input wire done_rdy_i,
    output wire [TAG_W-1:0] done_tag_o,
    output wire [7:0] done_status_o,
    output wire rd_vld_o, input wire rd_rdy_i,
    output wire [4:0] rd_ctx_o, output wire [15:0] rd_epoch_o,
    output wire [127:0] rd_lane_mask_o,
    output wire [2047:0] rd_column_o,
    output wire [TAG_W-1:0] rd_tag_o,
    input wire rd_rsp_vld_i, output wire rd_rsp_rdy_o,
    input wire [16383:0] rd_rsp_data_i,
    input wire [7:0] rd_rsp_status_i,
    output wire wr_vld_o, input wire wr_rdy_i,
    output wire [4:0] wr_ctx_o, output wire [15:0] wr_epoch_o,
    output wire [2047:0] wr_column_o,
    output wire [16383:0] wr_data_o,
    output wire [2047:0] wr_byte_mask_o,
    output wire [TAG_W-1:0] wr_tag_o,
    input wire wr_rsp_vld_i, output wire wr_rsp_rdy_o,
    input wire [7:0] wr_rsp_status_i
);
    localparam logic [7:0] OK = 8'd0, BAD_ADDR = 8'd5;
    typedef enum logic [2:0] {
        IDLE, PROBE_REQ, PROBE_RSP, READ_REQ, READ_RSP,
        WRITE_REQ, WRITE_RSP, DONE
    } state_t;
    state_t state_q;
    logic [4:0] ctx_q;
    logic [15:0] epoch_q;
    logic [31:0] base_q;
    logic [TAG_W-1:0] tag_q;
    logic [7:0] status_q;
    logic [2:0] column_index_q;
    logic [1023:0] old_cells_q;
    wire [15:0] column = base_q[15:0] + {13'b0, column_index_q};
    wire [15:0] word_column = {column[15:2], 2'b00};

    assign cmd_rdy_o = state_q == IDLE;
    assign done_vld_o = state_q == DONE;
    assign done_tag_o = tag_q;
    assign done_status_o = status_q;
    assign rd_vld_o = state_q == PROBE_REQ || state_q == READ_REQ;
    assign rd_rsp_rdy_o = state_q == PROBE_RSP || state_q == READ_RSP;
    assign wr_vld_o = state_q == WRITE_REQ;
    assign wr_rsp_rdy_o = state_q == WRITE_RSP;
    assign rd_ctx_o = ctx_q;
    assign rd_epoch_o = epoch_q;
    assign wr_ctx_o = ctx_q;
    assign wr_epoch_o = epoch_q;
    assign rd_tag_o = tag_q;
    assign wr_tag_o = tag_q;
    assign rd_column_o = {128{word_column}};
    assign wr_column_o = {128{word_column}};

    // A legal base selects one of four fixed 32-lane partitions. Keep each
    // bank's data/mask cone local; a dynamic part-select into the entire
    // 16,384-bit bus would synthesize a large global write barrel network.
    for (genvar b = 0; b < 128; b++) begin : gen_bank_word
        localparam int unsigned PARTITION = b / 32;
        localparam int unsigned ROW = b % 32;
        wire selected = base_q[31:16] == 16'(PARTITION * 32);
        assign rd_lane_mask_o[b] = selected;
        if (ROW < 31) begin : gen_shifted_row
            assign wr_data_o[b*128 +: 128] = selected ?
                ({96'b0, old_cells_q[(ROW+1)*32 +: 32]} <<
                 {column[1:0], 5'b0}) : 128'b0;
            assign wr_byte_mask_o[b*16 +: 16] = selected ?
                (16'h000f << {column[1:0], 2'b0}) : 16'b0;
        end else begin : gen_last_row
            assign wr_data_o[b*128 +: 128] = 128'b0;
            assign wr_byte_mask_o[b*16 +: 16] = 16'b0;
        end
    end
    wire [31:0] read_cell [0:31];
    for (genvar r = 0; r < 32; r++) begin : gen_read_cell
        wire [127:0] selected_word =
            base_q[31:16] == 16'd0 ? rd_rsp_data_i[r*128 +: 128] :
            base_q[31:16] == 16'd32 ? rd_rsp_data_i[(32+r)*128 +: 128] :
            base_q[31:16] == 16'd64 ? rd_rsp_data_i[(64+r)*128 +: 128] :
            rd_rsp_data_i[(96+r)*128 +: 128];
        assign read_cell[r] = selected_word[int'(column[1:0])*32 +: 32];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= IDLE;
            ctx_q <= '0;
            epoch_q <= '0;
            base_q <= '0;
            tag_q <= '0;
            status_q <= OK;
            column_index_q <= '0;
        end else begin
            case (state_q)
                IDLE: if (cmd_vld_i) begin
                    ctx_q <= cmd_ctx_i;
                    epoch_q <= cmd_epoch_i;
                    base_q <= cmd_base_addr_i;
                    tag_q <= cmd_tag_i;
                    status_q <= OK;
                    column_index_q <= '0;
                    if (cmd_base_addr_i[31:16] > 16'd96 ||
                        cmd_base_addr_i[20:16] != 5'd0 ||
                        cmd_base_addr_i[15:0] > 16'd504) begin
                        status_q <= BAD_ADDR;
                        state_q <= DONE;
                    end else state_q <= PROBE_REQ;
                end
                PROBE_REQ: if (rd_rdy_i) state_q <= PROBE_RSP;
                PROBE_RSP: if (rd_rsp_vld_i) begin
                    if (rd_rsp_status_i != OK) begin
                        status_q <= rd_rsp_status_i;
                        state_q <= DONE;
                    end else if (column_index_q == 3'd7) begin
                        column_index_q <= '0;
                        state_q <= READ_REQ;
                    end else begin
                        column_index_q <= column_index_q + 3'd1;
                        state_q <= PROBE_REQ;
                    end
                end
                READ_REQ: if (rd_rdy_i) state_q <= READ_RSP;
                READ_RSP: if (rd_rsp_vld_i) begin
                    if (rd_rsp_status_i != OK) begin
                        status_q <= rd_rsp_status_i;
                        state_q <= DONE;
                    end else begin
                        for (int r = 0; r < 32; r++)
                            old_cells_q[r*32 +: 32] <= read_cell[r];
                        state_q <= WRITE_REQ;
                    end
                end
                WRITE_REQ: if (wr_rdy_i) state_q <= WRITE_RSP;
                WRITE_RSP: if (wr_rsp_vld_i) begin
                    if (wr_rsp_status_i != OK) begin
                        status_q <= wr_rsp_status_i;
                        state_q <= DONE;
                    end else if (column_index_q == 3'd7) begin
                        state_q <= DONE;
                    end else begin
                        column_index_q <= column_index_q + 3'd1;
                        state_q <= READ_REQ;
                    end
                end
                DONE: if (done_rdy_i) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
