// SM100a tcgen05.ld/st register-to-TMEM address generation. One combinational
// result describes a 32-bit RF item; pack/unpack accesses a second TMEM cell.
// Ownership and physical arbitration are performed by blackwell_tmem_bank.
`default_nettype none
module blackwell_tmem_rf_map (
    input wire [2:0] shape_i,
    input wire [4:0] warp_i, thread_i,
    input wire [31:0] base_addr_i,
    input wire [7:0] repeat_i,
    input wire [7:0] reg_index_i,
    input wire pack16_i,
    input wire [31:0] half_offset_i,
    output logic valid_o,
    output logic [31:0] cell0_o, cell1_o,
    output logic second_cell_o
);
    logic [8:0] register_count;
    logic [8:0] dl, dc;
    logic [33:0] col_ext;
    logic [16:0] lane_ext;
    logic [6:0] partition_first;
    logic shape_valid, repeat_valid;
    int unsigned t, j;
    always_comb begin
        t = int'(thread_i); j = int'(reg_index_i);
        repeat_valid = repeat_i != 0 && ((repeat_i & (repeat_i-8'd1)) == 0);
        shape_valid = shape_i <= 3'd4;
        register_count = {1'b0,repeat_i};
        if (shape_i == 3'd2) begin
            register_count = {repeat_i,1'b0};
            if (repeat_i > 8'd64) repeat_valid = 1'b0;
        end
        if (shape_i == 3'd3) begin
            register_count = 9'(int'(repeat_i) << 2);
            if (repeat_i > 8'd32) repeat_valid = 1'b0;
        end
        dl = '0; dc = '0;
        case (shape_i)
            // .32x32b
            3'd0: begin dl = 9'(t); dc = 9'(j); end
            // .16x64b
            3'd1: begin
                dl = 9'((t >> 2) + ((t & 1) << 3));
                dc = 9'((j << 1) + ((t >> 1) & 1));
            end
            // .16x128b
            3'd2: begin
                dl = 9'((t >> 2) + ((j & 1) << 3));
                dc = 9'(((j >> 1) << 2) + (t & 3));
            end
            // .16x256b
            3'd3: begin
                dl = 9'((t >> 2) + (((j >> 1) & 1) << 3));
                dc = 9'(((j >> 2) << 3) + ((t & 3) << 1) + (j & 1));
            end
            // .16x32bx2: threads 0..15 and 16..31 access the same lane
            // group, with the latter half displaced by the instruction offset.
            3'd4: begin dl = 9'(t & 15); dc = 9'(j); end
            default: ;
        endcase
        partition_first = {warp_i[1:0],5'b00000};
        lane_ext = {1'b0,base_addr_i[31:16]} + 17'(dl);
        col_ext = 34'(base_addr_i[15:0]) +
                  (shape_i == 3'd4 && thread_i[4] ? 34'(half_offset_i) : 34'd0) +
                  (pack16_i ? (34'(dc) << 1) : 34'(dc));
        second_cell_o = pack16_i;
        cell0_o = {lane_ext[15:0],col_ext[15:0]};
        cell1_o = {lane_ext[15:0],16'(col_ext + 34'd1)};
        valid_o = shape_valid && repeat_valid && 9'(reg_index_i) < register_count &&
                  lane_ext <= 17'd127 && lane_ext >= 17'(partition_first) &&
                  lane_ext < 17'(partition_first) + 17'd32 &&
                  col_ext <= (pack16_i ? 34'd510 : 34'd511);
    end
endmodule
`default_nettype wire
