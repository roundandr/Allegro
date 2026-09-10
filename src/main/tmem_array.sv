// ============================================================================
// File Name   : tmem_array.sv
// Description : Parameterized banked accumulator storage with deterministic
//               scalar-read arbitration and an eight-lane row write port.
// ============================================================================

`default_nettype none

module tmem_array #(
    parameter int unsigned BANKS          = 8,
    parameter int unsigned BASE_DEPTH     = 128,
    parameter int unsigned READ_PORTS     = 8,
    parameter int unsigned DATA_W         = 32,
    parameter int unsigned TAG_W          = 4,
    // 0: 1R1W, 1: shared 1RW, 2: 2R1W per bank.
    parameter int unsigned PORT_MODE      = 0
) (
    input  logic                               clk,
    input  logic                               rst_n,

    input  logic [READ_PORTS-1:0]              rd_vld_i,
    output logic [READ_PORTS-1:0]              rd_rdy_o,
    input  logic [READ_PORTS-1:0]              rd_slot_i,
    input  logic [READ_PORTS*6-1:0]            rd_row_i,
    input  logic [READ_PORTS*3-1:0]            rd_col_i,
    input  logic [READ_PORTS*TAG_W-1:0]        rd_tag_i,
    output logic [READ_PORTS-1:0]              rd_conflict_o,

    output logic [READ_PORTS-1:0]              rsp_vld_o,
    input  logic [READ_PORTS-1:0]              rsp_rdy_i,
    output logic [READ_PORTS*DATA_W-1:0]       rsp_data_o,
    output logic [READ_PORTS*TAG_W-1:0]        rsp_tag_o,
    output logic [READ_PORTS-1:0]              rsp_error_o,

    input  logic                               row_wr_vld_i,
    output logic                               row_wr_rdy_o,
    input  logic                               row_wr_slot_i,
    input  logic [5:0]                         row_wr_row_i,
    input  logic [8*DATA_W-1:0]                row_wr_data_i,
    input  logic [7:0]                         row_wr_mask_i
);

    // The total capacity is BASE_DEPTH * 8 cells. Changing BANKS redistributes
    // the same capacity across banks; changing BASE_DEPTH changes capacity.
    localparam int unsigned TOTAL_CELLS = BASE_DEPTH * 8;
    localparam int unsigned BANK_DEPTH  = TOTAL_CELLS / BANKS;
    localparam int unsigned BANK_W      = (BANKS <= 1) ? 1 : $clog2(BANKS);
    localparam int unsigned ADDR_W      = (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH);
    localparam int unsigned WR_GROUPS   = (8 + BANKS - 1) / BANKS;
    localparam int unsigned WR_GROUP_W  = (WR_GROUPS <= 1) ? 1 : $clog2(WR_GROUPS);
    localparam int unsigned RD_PER_BANK = (PORT_MODE == 2) ? 2 : 1;

    logic [DATA_W-1:0] mem_q [0:BANKS-1][0:BANK_DEPTH-1];

    logic [READ_PORTS-1:0]        rsp_vld_q;
    logic [DATA_W-1:0]             rsp_data_q [0:READ_PORTS-1];
    logic [TAG_W-1:0]              rsp_tag_q [0:READ_PORTS-1];
    logic [READ_PORTS-1:0]        rd_grant;
    logic [READ_PORTS-1:0]        rd_conflict;
    logic [BANK_W-1:0]            rd_bank [0:READ_PORTS-1];
    logic [ADDR_W-1:0]            rd_addr [0:READ_PORTS-1];

    function automatic integer cell_linear_idx(
        input logic       slot_i,
        input logic [5:0] row_i,
        input logic [2:0] col_i
    );
        begin
            cell_linear_idx = (slot_i ? 512 : 0) + (integer'(row_i) * 8) + integer'(col_i);
        end
    endfunction

    function automatic integer cell_bank_idx(
        input logic       slot_i,
        input logic [5:0] row_i,
        input logic [2:0] col_i
    );
        begin
            cell_bank_idx = cell_linear_idx(slot_i, row_i, col_i) % BANKS;
        end
    endfunction

    function automatic integer cell_addr_idx(
        input logic       slot_i,
        input logic [5:0] row_i,
        input logic [2:0] col_i
    );
        begin
            cell_addr_idx = cell_linear_idx(slot_i, row_i, col_i) / BANKS;
        end
    endfunction

    always_comb begin
        for (int unsigned map_idx = 0; map_idx < READ_PORTS; map_idx = map_idx + 1) begin
            rd_bank[map_idx] = BANK_W'(cell_bank_idx(rd_slot_i[map_idx],
                                                     rd_row_i[map_idx*6 +: 6],
                                                     rd_col_i[map_idx*3 +: 3]));
            rd_addr[map_idx] = ADDR_W'(cell_addr_idx(rd_slot_i[map_idx],
                                                     rd_row_i[map_idx*6 +: 6],
                                                     rd_col_i[map_idx*3 +: 3]));
        end
    end

    always_comb begin : proc_read_arbiter
        int unsigned same_bank_grants;
        rd_grant    = '0;
        rd_conflict = '0;

        for (int unsigned arb_idx = 0; arb_idx < READ_PORTS; arb_idx = arb_idx + 1) begin
            same_bank_grants = 0;
            if (rd_vld_i[arb_idx] && (!rsp_vld_q[arb_idx] || rsp_rdy_i[arb_idx])) begin
                rd_grant[arb_idx] = 1'b1;
                for (int unsigned prior_idx = 0; prior_idx < arb_idx; prior_idx = prior_idx + 1) begin
                    if (rd_grant[prior_idx] && (rd_bank[prior_idx] == rd_bank[arb_idx])) begin
                        same_bank_grants = same_bank_grants + 1;
                    end
                end
                if ((same_bank_grants >= RD_PER_BANK) ||
                    ((PORT_MODE == 1) && row_wr_vld_i)) begin
                    rd_grant[arb_idx]    = 1'b0;
                    rd_conflict[arb_idx] = 1'b1;
                end
            end
        end
    end

    assign rd_rdy_o      = rd_grant;
    assign rd_conflict_o = rd_conflict;
    assign rsp_vld_o     = rsp_vld_q;
    assign rsp_error_o   = {READ_PORTS{1'b0}};
    generate
        genvar rsp_idx;
        for (rsp_idx = 0; rsp_idx < READ_PORTS; rsp_idx = rsp_idx + 1) begin : gen_rsp_output
            assign rsp_data_o[rsp_idx*DATA_W +: DATA_W] = rsp_data_q[rsp_idx];
            assign rsp_tag_o[rsp_idx*TAG_W +: TAG_W]    = rsp_tag_q[rsp_idx];
        end
    endgenerate

    // Data cells are not reset. Reads are valid only after architectural init.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_vld_q <= '0;
            for (int unsigned rst_idx = 0; rst_idx < READ_PORTS; rst_idx = rst_idx + 1) begin
                rsp_data_q[rst_idx] <= '0;
                rsp_tag_q[rst_idx]  <= '0;
            end
        end else begin
            for (int unsigned rsp_upd_idx = 0; rsp_upd_idx < READ_PORTS; rsp_upd_idx = rsp_upd_idx + 1) begin
                if (rd_grant[rsp_upd_idx]) begin
                    rsp_vld_q[rsp_upd_idx]  <= 1'b1;
                    rsp_data_q[rsp_upd_idx] <= mem_q[rd_bank[rsp_upd_idx]][rd_addr[rsp_upd_idx]];
                    rsp_tag_q[rsp_upd_idx]  <= rd_tag_i[rsp_upd_idx*TAG_W +: TAG_W];
                end else if (rsp_vld_q[rsp_upd_idx] && rsp_rdy_i[rsp_upd_idx]) begin
                    rsp_vld_q[rsp_upd_idx] <= 1'b0;
                end
            end
        end
    end

    // A row write is one cycle for BANKS>=8. Narrower bank sweeps serialize
    // groups without changing the external valid-ready contract. Separate
    // generate branches keep inactive serialization state out of the netlist.
    generate
        if (WR_GROUPS == 1) begin : gen_single_cycle_row_write
            // Shared 1RW mode gives the row write deterministic priority;
            // read requesters observe conflict/backpressure in that cycle.
            assign row_wr_rdy_o = 1'b1;

            always_ff @(posedge clk) begin
                if (row_wr_vld_i && row_wr_rdy_o) begin
                    for (int unsigned wr_lane_idx = 0; wr_lane_idx < 8;
                         wr_lane_idx = wr_lane_idx + 1) begin
                        if (row_wr_mask_i[wr_lane_idx]) begin
                            mem_q[cell_bank_idx(row_wr_slot_i, row_wr_row_i, 3'(wr_lane_idx))]
                                 [cell_addr_idx(row_wr_slot_i, row_wr_row_i, 3'(wr_lane_idx))]
                                <= row_wr_data_i[wr_lane_idx*DATA_W +: DATA_W];
                        end
                    end
                end
            end
        end else begin : gen_serial_row_write
            logic                  row_wr_busy_q;
            logic [WR_GROUP_W-1:0] row_wr_group_q;
            logic                  row_wr_slot_q;
            logic [5:0]            row_wr_row_q;
            logic [8*DATA_W-1:0]   row_wr_data_q;
            logic [7:0]            row_wr_mask_q;

            assign row_wr_rdy_o = !row_wr_busy_q;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    row_wr_busy_q  <= 1'b0;
                    row_wr_group_q <= '0;
                    row_wr_slot_q  <= 1'b0;
                    row_wr_row_q   <= 6'd0;
                    row_wr_data_q  <= '0;
                    row_wr_mask_q  <= 8'h00;
                end else begin
                    if (row_wr_vld_i && row_wr_rdy_o) begin
                        for (int unsigned first_lane_idx = 0; first_lane_idx < 8;
                             first_lane_idx = first_lane_idx + 1) begin
                            if ((first_lane_idx < BANKS) && row_wr_mask_i[first_lane_idx]) begin
                                mem_q[cell_bank_idx(row_wr_slot_i, row_wr_row_i, 3'(first_lane_idx))]
                                     [cell_addr_idx(row_wr_slot_i, row_wr_row_i, 3'(first_lane_idx))]
                                    <= row_wr_data_i[first_lane_idx*DATA_W +: DATA_W];
                            end
                        end
                        row_wr_busy_q  <= 1'b1;
                        row_wr_group_q <= WR_GROUP_W'(1);
                        row_wr_slot_q  <= row_wr_slot_i;
                        row_wr_row_q   <= row_wr_row_i;
                        row_wr_data_q  <= row_wr_data_i;
                        row_wr_mask_q  <= row_wr_mask_i;
                    end else if (row_wr_busy_q) begin
                        for (int unsigned serial_lane_idx = 0; serial_lane_idx < 8;
                             serial_lane_idx = serial_lane_idx + 1) begin
                            if ((serial_lane_idx >= (integer'(row_wr_group_q) * BANKS)) &&
                                (serial_lane_idx < ((integer'(row_wr_group_q) + 1) * BANKS)) &&
                                row_wr_mask_q[serial_lane_idx]) begin
                                mem_q[cell_bank_idx(row_wr_slot_q, row_wr_row_q, 3'(serial_lane_idx))]
                                     [cell_addr_idx(row_wr_slot_q, row_wr_row_q, 3'(serial_lane_idx))]
                                    <= row_wr_data_q[serial_lane_idx*DATA_W +: DATA_W];
                            end
                        end

                        if (integer'(row_wr_group_q) == (WR_GROUPS - 1)) begin
                            row_wr_busy_q <= 1'b0;
                        end else begin
                            row_wr_group_q <= row_wr_group_q + WR_GROUP_W'(1);
                        end
                    end
                end
            end
        end
    endgenerate

    initial begin
        if ((BANKS < 1) || ((BANKS & (BANKS - 1)) != 0)) begin
            $error("TMEM BANKS must be a positive power of two");
        end
        if ((TOTAL_CELLS % BANKS) != 0) begin
            $error("TMEM total capacity must divide evenly across banks");
        end
        if (PORT_MODE > 2) begin
            $error("TMEM PORT_MODE must be 0 (1R1W), 1 (1RW), or 2 (2R1W)");
        end
    end

endmodule

`default_nettype wire
