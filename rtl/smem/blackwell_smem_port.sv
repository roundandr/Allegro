// Byte-addressed client bridge to the 128 B shared SRAM fabric. Eight tagged
// contexts overlap real backend latency; requests crossing a line are split and
// reassembled. A response is emitted only after every selected byte is acked.
`default_nettype none
module blackwell_smem_port #(
    parameter int unsigned ENTRIES = 8,
    parameter int unsigned CAPACITY_BYTES = 228*1024,
    parameter int unsigned TAG_W = 16
) (
    input wire clk, rst_n,
    input wire req_vld_i,
    output wire req_rdy_o,
    input wire [31:0] req_addr_i,
    input wire [1023:0] req_data_i,
    input wire [127:0] req_mask_i,
    input wire [1:0] req_kind_i,
    input wire [3:0] req_dtype_i, req_op_i,
    input wire [TAG_W-1:0] req_tag_i,
    output wire rsp_vld_o,
    input wire rsp_rdy_i,
    output wire [1023:0] rsp_data_o,
    output wire [TAG_W-1:0] rsp_tag_o,
    output wire rsp_error_o,
    output logic rd_vld_o,
    input wire rd_rdy_i,
    output logic [31:0] rd_addr_o,
    output logic [15:0] rd_tag_o,
    input wire rd_rsp_vld_i,
    output wire rd_rsp_rdy_o,
    input wire [1023:0] rd_data_i,
    input wire [15:0] rd_tag_i,
    input wire rd_error_i,
    output logic wr_vld_o,
    input wire wr_rdy_i,
    output logic [31:0] wr_addr_o,
    output logic [1023:0] wr_data_o,
    output logic [127:0] wr_mask_o,
    output logic [15:0] wr_tag_o,
    input wire wr_rsp_vld_i,
    output wire wr_rsp_rdy_o,
    input wire [15:0] wr_tag_i,
    input wire wr_error_i,
    output logic atom_vld_o,
    input wire atom_rdy_i,
    output logic [31:0] atom_addr_o,
    output logic [1023:0] atom_data_o,
    output logic [127:0] atom_mask_o,
    output logic [3:0] atom_dtype_o, atom_op_o,
    output logic [15:0] atom_tag_o,
    input wire atom_rsp_vld_i,
    output wire atom_rsp_rdy_o,
    input wire [15:0] atom_tag_i,
    input wire atom_error_i,
    output logic protocol_error_o
);
    import tma_mbarrier_pkg::*;
    localparam int unsigned SW = ENTRIES < 2 ? 1 : $clog2(ENTRIES);
    localparam int unsigned GW = 15-SW;
    logic [ENTRIES-1:0] live_q, error_q;
    logic [31:0] address_q [ENTRIES];
    logic [1023:0] source_q [ENTRIES], result_q [ENTRIES];
    logic [127:0] mask_q [ENTRIES];
    logic [1:0] kind_q [ENTRIES], needed_q [ENTRIES], issued_q [ENTRIES], done_q [ENTRIES];
    logic [3:0] dtype_q [ENTRIES], op_q [ENTRIES];
    logic [TAG_W-1:0] tag_q [ENTRIES];
    logic [GW-1:0] generation_q [ENTRIES];
    logic [ENTRIES-1:0] deps_q [ENTRIES];
    logic [ENTRIES-1:0] data_complete, input_deps;
    logic [SW-1:0] turn_q [4], hold_slot_q [4];
    logic [3:0] hold_q, hold_half_q;
    integer selected [4];
    logic [3:0] half_sel, fire;
    integer free_slot;
    logic input_bad;
    logic [1:0] input_needed;
    logic [32:0] last_address;
    logic [127:0] input_first, input_second;
    logic [2:0] completion_valid;
    logic [15:0] completion_tag [3];
    logic [2:0] completion_error;
    integer completion_slot [3];
    logic [2:0] completion_match;
    assign req_rdy_o = free_slot >= 0;
    assign rd_rsp_rdy_o = 1'b1;
    assign wr_rsp_rdy_o = 1'b1;
    assign atom_rsp_rdy_o = 1'b1;
    assign rsp_vld_o = selected[3] >= 0;
    assign rsp_data_o = selected[3] >= 0 ? result_q[selected[3]] : '0;
    assign rsp_tag_o = selected[3] >= 0 ? tag_q[selected[3]] : '0;
    assign rsp_error_o = selected[3] >= 0 && error_q[selected[3]];
    assign fire = {rsp_vld_o && rsp_rdy_i,atom_vld_o && atom_rdy_i,wr_vld_o && wr_rdy_i,rd_vld_o && rd_rdy_i};
    always_comb begin
        free_slot = -1;
        for (int s = 0; s < ENTRIES; s++) if (!live_q[s] && free_slot < 0) free_slot = s;
        data_complete = '0; input_deps = '0;
        for (int s = 0; s < ENTRIES; s++) begin
            data_complete[s] = live_q[s] && done_q[s] == needed_q[s];
            // Conservatively reserve each request's byte interval, rather than
            // an entire allocation. Read/read and disjoint intervals overlap.
            input_deps[s] = live_q[s] && !data_complete[s] && (|mask_q[s]) && (|req_mask_i) &&
                (kind_q[s] != 0 || req_kind_i != 0) &&
                ({1'b0,address_q[s]} < {1'b0,req_addr_i}+33'd128) &&
                ({1'b0,req_addr_i} < {1'b0,address_q[s]}+33'd128);
        end
        input_bad = req_kind_i > 2;
        last_address = '0;
        for (int i = 0; i < 128; i++) begin
            last_address = {1'b0,req_addr_i}+33'(i);
            if (req_mask_i[i] && last_address >= 33'(CAPACITY_BYTES)) input_bad = 1'b1;
        end
        if (req_kind_i == 2) begin
            if (!reduction_legal(req_dtype_i,req_op_i,1'b1,1'b0) || req_addr_i[1:0] != 0) input_bad = 1'b1;
            for (int b = 0; b < 32; b++)
                if (req_mask_i[b*4+:4] != 0 && req_mask_i[b*4+:4] != 4'hf) input_bad = 1'b1;
            if (req_dtype_i == TMA_TYPE_U64) begin
                if (req_addr_i[2:0] != 0) input_bad = 1'b1;
                for (int b = 0; b < 16; b++)
                    if (req_mask_i[b*8+:8] != 0 && req_mask_i[b*8+:8] != 8'hff) input_bad = 1'b1;
            end
        end
        input_first = req_mask_i << req_addr_i[6:0];
        input_second = req_mask_i >> (128-int'(req_addr_i[6:0]));
        input_needed = input_bad ? 2'b00 : {(|input_second),(|input_first)};
        half_sel = '0;
        for (int p = 0; p < 4; p++) begin
            selected[p] = -1;
            for (int delta = 0; delta < ENTRIES; delta++) begin
                if (live_q[(int'(turn_q[p])+delta)%ENTRIES] && selected[p] < 0) begin
                    if (p == 3) begin
                        if (done_q[(int'(turn_q[p])+delta)%ENTRIES] == needed_q[(int'(turn_q[p])+delta)%ENTRIES])
                            selected[p] = (int'(turn_q[p])+delta)%ENTRIES;
                    end else if (int'(kind_q[(int'(turn_q[p])+delta)%ENTRIES]) == p &&
                                 !(|deps_q[(int'(turn_q[p])+delta)%ENTRIES]) &&
                                 (|(needed_q[(int'(turn_q[p])+delta)%ENTRIES] & ~issued_q[(int'(turn_q[p])+delta)%ENTRIES]))) begin
                        selected[p] = (int'(turn_q[p])+delta)%ENTRIES;
                        half_sel[p] = !(needed_q[selected[p]][0] && !issued_q[selected[p]][0]);
                    end
                end
            end
            if (hold_q[p]) begin selected[p] = int'(hold_slot_q[p]); half_sel[p] = hold_half_q[p]; end
        end
        rd_vld_o = selected[0] >= 0; wr_vld_o = selected[1] >= 0; atom_vld_o = selected[2] >= 0;
        rd_addr_o = '0; rd_tag_o = '0;
        wr_addr_o = '0; wr_data_o = '0; wr_mask_o = '0; wr_tag_o = '0;
        atom_addr_o = '0; atom_data_o = '0; atom_mask_o = '0; atom_tag_o = '0; atom_dtype_o = '0; atom_op_o = '0;
        if (selected[0] >= 0) begin
            rd_addr_o = {address_q[selected[0]][31:7],7'd0}+(half_sel[0] ? 32'd128 : 32'd0);
            rd_tag_o = {generation_q[selected[0]],SW'(selected[0]),half_sel[0]};
        end
        if (selected[1] >= 0) begin
            wr_addr_o = {address_q[selected[1]][31:7],7'd0}+(half_sel[1] ? 32'd128 : 32'd0);
            wr_tag_o = {generation_q[selected[1]],SW'(selected[1]),half_sel[1]};
            wr_data_o = half_sel[1] ? source_q[selected[1]] >> (8*(128-int'(address_q[selected[1]][6:0]))) :
                                                    source_q[selected[1]] << (8*int'(address_q[selected[1]][6:0]));
            wr_mask_o = half_sel[1] ? mask_q[selected[1]] >> (128-int'(address_q[selected[1]][6:0])) :
                                                    mask_q[selected[1]] << address_q[selected[1]][6:0];
        end
        if (selected[2] >= 0) begin
            atom_addr_o = {address_q[selected[2]][31:7],7'd0}+(half_sel[2] ? 32'd128 : 32'd0);
            atom_tag_o = {generation_q[selected[2]],SW'(selected[2]),half_sel[2]};
            atom_data_o = half_sel[2] ? source_q[selected[2]] >> (8*(128-int'(address_q[selected[2]][6:0]))) :
                                                      source_q[selected[2]] << (8*int'(address_q[selected[2]][6:0]));
            atom_mask_o = half_sel[2] ? mask_q[selected[2]] >> (128-int'(address_q[selected[2]][6:0])) :
                                                      mask_q[selected[2]] << address_q[selected[2]][6:0];
            atom_dtype_o = dtype_q[selected[2]]; atom_op_o = op_q[selected[2]];
        end
        completion_valid = {atom_rsp_vld_i,wr_rsp_vld_i,rd_rsp_vld_i};
        completion_error = {atom_error_i,wr_error_i,rd_error_i};
        completion_tag[0] = rd_tag_i; completion_tag[1] = wr_tag_i; completion_tag[2] = atom_tag_i;
        completion_match = '0;
        for (int p = 0; p < 3; p++) begin
            completion_slot[p] = int'(completion_tag[p][1+:SW]);
            if (completion_slot[p] < ENTRIES)
                completion_match[p] = live_q[completion_slot[p]] &&
                    generation_q[completion_slot[p]] == completion_tag[p][SW+1+:GW] &&
                    int'(kind_q[completion_slot[p]]) == p &&
                    issued_q[completion_slot[p]][completion_tag[p][0]] &&
                    !done_q[completion_slot[p]][completion_tag[p][0]];
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            live_q <= '0; error_q <= '0; hold_q <= '0; hold_half_q <= '0; protocol_error_o <= 1'b0;
            for (int s = 0; s < ENTRIES; s++) begin generation_q[s] <= '0; issued_q[s] <= '0; done_q[s] <= '0; deps_q[s] <= '0; end
            for (int p = 0; p < 4; p++) begin turn_q[p] <= '0; hold_slot_q[p] <= '0; end
        end else begin
            for (int s = 0; s < ENTRIES; s++) deps_q[s] <= deps_q[s] & ~data_complete;
            for (int p = 0; p < 4; p++) begin
                if (fire[p]) begin
                    hold_q[p] <= 1'b0;
                    turn_q[p] <= selected[p] == ENTRIES-1 ? '0 : SW'(selected[p]+1);
                    if (p < 3) issued_q[selected[p]][half_sel[p]] <= 1'b1;
                    else live_q[selected[p]] <= 1'b0;
                end else if (selected[p] >= 0) begin
                    hold_q[p] <= 1'b1; hold_slot_q[p] <= SW'(selected[p]); hold_half_q[p] <= half_sel[p];
                end
            end
            for (int p = 0; p < 3; p++) begin
                if (completion_valid[p]) begin
                    if (!completion_match[p]) protocol_error_o <= 1'b1;
                    else begin
                        done_q[completion_slot[p]][completion_tag[p][0]] <= 1'b1;
                        error_q[completion_slot[p]] <= error_q[completion_slot[p]] | completion_error[p];
                    end
                end
            end
            if (req_vld_i && req_rdy_o) begin
                live_q[free_slot] <= 1'b1; address_q[free_slot] <= req_addr_i; source_q[free_slot] <= req_data_i;
                mask_q[free_slot] <= req_mask_i; kind_q[free_slot] <= req_kind_i;
                dtype_q[free_slot] <= req_dtype_i; op_q[free_slot] <= req_op_i; tag_q[free_slot] <= req_tag_i;
                needed_q[free_slot] <= input_needed; issued_q[free_slot] <= '0; done_q[free_slot] <= '0;
                error_q[free_slot] <= input_bad; generation_q[free_slot] <= generation_q[free_slot]+1'b1;
                deps_q[free_slot] <= input_deps;
            end
        end
    end
    for (genvar s = 0; s < ENTRIES; s++) begin : gen_read_assembly
        wire [1023:0] update_mask;
        wire [1023:0] shifted_data = completion_tag[0][0] ?
            rd_data_i << (8*(128-int'(address_q[s][6:0]))) : rd_data_i >> (8*int'(address_q[s][6:0]));
        for (genvar b = 0; b < 128; b++) begin : gen_byte
            assign update_mask[b*8+:8] = {8{((int'(address_q[s][6:0])+b)/128) == int'(completion_tag[0][0]) && mask_q[s][b]}};
        end
        always_ff @(posedge clk) begin
            if (rst_n && req_vld_i && req_rdy_o && free_slot == s) result_q[s] <= '0;
            else if (rst_n && completion_valid[0] && completion_match[0] && completion_slot[0] == s)
                result_q[s] <= (result_q[s] & ~update_mask) | (shifted_data & update_mask);
        end
    end
    initial if (ENTRIES < 2 || SW > 10 || CAPACITY_BYTES % 128 != 0) $error("Invalid SMEM bridge configuration");
endmodule
`default_nettype wire
