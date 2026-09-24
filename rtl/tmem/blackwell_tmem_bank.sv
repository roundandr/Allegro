// One physical SM100a-sized TMEM instance. A request transfers at most one
// aligned 128-bit word from each of the 128 lane banks. Allocation ownership is
// checked before ANY bank is touched; storage itself is deliberately unreset.
// The RF shape, CP and MMA address generators sit above this word interface.
`default_nettype none
module blackwell_tmem_bank #(
    parameter int unsigned CONTEXTS = 32,
    parameter int unsigned TAG_W = 16
) (
    input wire clk, rst_n,
    input wire ctx_vld_i, output logic ctx_rdy_o,
    input wire ctx_create_i,
    input wire [4:0] ctx_id_i,
    input wire [15:0] ctx_epoch_i,
    input wire [TAG_W-1:0] ctx_tag_i,
    input wire alloc_vld_i, output logic alloc_rdy_o,
    input wire [4:0] alloc_ctx_i,
    input wire [15:0] alloc_epoch_i,
    input wire [9:0] alloc_columns_i,
    input wire [TAG_W-1:0] alloc_tag_i,
    input wire free_vld_i, output logic free_rdy_o,
    input wire [4:0] free_ctx_i,
    input wire [15:0] free_epoch_i,
    input wire [8:0] free_base_i,
    input wire [9:0] free_columns_i,
    input wire [TAG_W-1:0] free_tag_i,
    input wire relinquish_vld_i, output logic relinquish_rdy_o,
    input wire [4:0] relinquish_ctx_i,
    input wire [15:0] relinquish_epoch_i,
    input wire [TAG_W-1:0] relinquish_tag_i,
    output logic ctrl_rsp_vld_o, input wire ctrl_rsp_rdy_i,
    output logic [TAG_W-1:0] ctrl_rsp_tag_o,
    output logic [7:0] ctrl_rsp_status_o,
    output logic [8:0] ctrl_rsp_base_o,
    input wire rd_vld_i, output logic rd_rdy_o,
    input wire [4:0] rd_ctx_i,
    input wire [15:0] rd_epoch_i,
    input wire [127:0] rd_lane_mask_i,
    input wire [2047:0] rd_column_i,
    input wire [TAG_W-1:0] rd_tag_i,
    output wire rd_rsp_vld_o, input wire rd_rsp_rdy_i,
    output wire [16383:0] rd_rsp_data_o,
    output wire [TAG_W-1:0] rd_rsp_tag_o,
    output wire [7:0] rd_rsp_status_o,
    input wire wr_vld_i, output logic wr_rdy_o,
    input wire [4:0] wr_ctx_i,
    input wire [15:0] wr_epoch_i,
    input wire [2047:0] wr_column_i,
    input wire [16383:0] wr_data_i,
    input wire [2047:0] wr_byte_mask_i,
    input wire [TAG_W-1:0] wr_tag_i,
    output wire wr_rsp_vld_o, input wire wr_rsp_rdy_i,
    output wire [TAG_W-1:0] wr_rsp_tag_o,
    output wire [7:0] wr_rsp_status_o
);
    // Project diagnostics follow the TMEM command ABI in doc/tmem_spec.md.
    localparam logic [7:0] OK=0, BAD_CONTEXT=3, BAD_SIZE=7,
                            BAD_OWNER=6, BAD_ADDR=5, BAD_PERMIT=8,
                            BAD_BUSY=17;
    // Packed owner/control tables retain variable-index hardware muxes while
    // remaining accepted by the synthesis frontend used for this project.
    logic [CONTEXTS-1:0] ctx_live_q, permit_q;
    logic [CONTEXTS*16-1:0] ctx_epoch_q;
    logic [CONTEXTS*10-1:0] last_cols_q;
    logic [CONTEXTS*9-1:0] outstanding_q;
    logic [15:0] unit_live_q;
    logic [79:0] unit_ctx_q;
    logic [255:0] unit_epoch_q;
    logic [895:0] mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rd_mask;
    logic [2047:0] mem_wr_mask;
    wire mem_rd_rdy, mem_wr_rdy, mem_rd_rsp, mem_wr_rsp;
    wire [16383:0] mem_rd_data;
    wire [TAG_W-1:0] mem_rd_tag, mem_wr_tag;
    wire mem_rd_error, mem_wr_error;
    logic [7:0] rd_bad, wr_bad;
    logic [7:0] rd_bad_q, wr_bad_q;
    logic [4:0] rd_rsp_ctx_q, wr_rsp_ctx_q;
    logic rw_turn_q, same_word_conflict;
    logic [3:0] alloc_first;
    logic [4:0] alloc_units;
    logic alloc_found, alloc_valid, free_valid;
    logic [7:0] ctx_error, alloc_error, free_error, relinquish_error;
    logic ctx_has_units, free_has_all_units;
    wire rd_fire = rd_vld_i && rd_rdy_o;
    wire wr_fire = wr_vld_i && wr_rdy_o;
    wire rd_retire = rd_rsp_vld_o && rd_rsp_rdy_i;
    wire wr_retire = wr_rsp_vld_o && wr_rsp_rdy_i;
    wire ctrl_space = !ctrl_rsp_vld_o || ctrl_rsp_rdy_i;

    function automatic logic legal_size(input logic [9:0] n);
        return n == 10'd32 || n == 10'd64 || n == 10'd128 ||
               n == 10'd256 || n == 10'd512;
    endfunction
    function automatic logic context_ok(input logic [4:0] c,input logic [15:0] e);
        return int'(c) < CONTEXTS && ctx_live_q[c] && ctx_epoch_q[c*16+:16] == e;
    endfunction
    function automatic logic word_owned(input logic [4:0] c,input logic [15:0] e,
                                          input logic [15:0] column);
        return column <= 16'd508 && column[1:0] == 2'b00 &&
               unit_live_q[column[8:5]] && unit_ctx_q[column[8:5]*5+:5] == c &&
               unit_epoch_q[column[8:5]*16+:16] == e;
    endfunction

    always_comb begin
        rd_bad = context_ok(rd_ctx_i,rd_epoch_i) ? OK : BAD_CONTEXT;
        wr_bad = context_ok(wr_ctx_i,wr_epoch_i) ? OK : BAD_CONTEXT;
        same_word_conflict = 1'b0;
        mem_rd_addr = '0; mem_wr_addr = '0;
        for (int b=0;b<128;b++) begin
            mem_rd_addr[b*7+:7] = rd_column_i[b*16+2+:7];
            mem_wr_addr[b*7+:7] = wr_column_i[b*16+2+:7];
            if (rd_bad == OK && rd_lane_mask_i[b] &&
                !word_owned(rd_ctx_i,rd_epoch_i,rd_column_i[b*16+:16]))
                rd_bad = rd_column_i[b*16+:16] > 16'd508 ||
                    (rd_column_i[b*16+:16] & 16'h0003) != 0 ? BAD_ADDR : BAD_OWNER;
            if (wr_bad == OK && (|wr_byte_mask_i[b*16+:16]) &&
                !word_owned(wr_ctx_i,wr_epoch_i,wr_column_i[b*16+:16]))
                wr_bad = wr_column_i[b*16+:16] > 16'd508 ||
                    (wr_column_i[b*16+:16] & 16'h0003) != 0 ? BAD_ADDR : BAD_OWNER;
            if (rd_lane_mask_i[b] && (|wr_byte_mask_i[b*16+:16]) &&
                rd_column_i[b*16+:16] == wr_column_i[b*16+:16]) same_word_conflict = 1'b1;
        end
        mem_rd_mask = rd_bad == OK ? rd_lane_mask_i : '0;
        mem_wr_mask = wr_bad == OK ? wr_byte_mask_i : '0;
        rd_rdy_o = mem_rd_rdy && (!same_word_conflict || !rw_turn_q || !wr_vld_i || !rd_vld_i);
        wr_rdy_o = mem_wr_rdy && (!same_word_conflict || rw_turn_q || !wr_vld_i || !rd_vld_i);
    end
    // Permission failure is an acknowledged transaction with all SRAM masks
    // clear. This preserves response ordering without exposing unowned data.
    blackwell_banked_sram #(.BANKS(128),.DEPTH(128),.DATA_W(128),.TAG_W(TAG_W)) storage (
        .clk,.rst_n,
        .rd_vld_i(rd_fire),.rd_rdy_o(mem_rd_rdy),.rd_mask_i(mem_rd_mask),
        .rd_addr_i(mem_rd_addr),.rd_tag_i(rd_tag_i),
        .rd_rsp_vld_o(mem_rd_rsp),.rd_rsp_rdy_i(rd_rsp_rdy_i),
        .rd_data_o(mem_rd_data),.rd_tag_o(mem_rd_tag),.rd_error_o(mem_rd_error),
        .wr_vld_i(wr_fire),.wr_rdy_o(mem_wr_rdy),.wr_addr_i(mem_wr_addr),
        .wr_data_i(wr_data_i),.wr_mask_i(mem_wr_mask),.wr_tag_i(wr_tag_i),
        .wr_rsp_vld_o(mem_wr_rsp),.wr_rsp_rdy_i(wr_rsp_rdy_i),
        .wr_tag_o(mem_wr_tag),.wr_error_o(mem_wr_error)
    );
    assign rd_rsp_vld_o = mem_rd_rsp;
    assign wr_rsp_vld_o = mem_wr_rsp;
    assign rd_rsp_data_o = mem_rd_data;
    assign rd_rsp_tag_o = mem_rd_tag;
    assign wr_rsp_tag_o = mem_wr_tag;
    assign rd_rsp_status_o = rd_bad_q != OK ? rd_bad_q : (mem_rd_error ? BAD_ADDR : OK);
    assign wr_rsp_status_o = wr_bad_q != OK ? wr_bad_q : (mem_wr_error ? BAD_ADDR : OK);

    always_comb begin
        alloc_found = 1'b0; alloc_first = '0;
        alloc_valid = legal_size(alloc_columns_i);
        case (alloc_columns_i)
            10'd32: alloc_units=5'd1;
            10'd64: alloc_units=5'd2;
            10'd128: alloc_units=5'd4;
            10'd256: alloc_units=5'd8;
            10'd512: alloc_units=5'd16;
            default: alloc_units=5'd0;
        endcase
        for (int base=0;base<16;base++) begin
            logic fit;
            fit = alloc_valid && ((base & (int'(alloc_units)-1)) == 0) &&
                  base + int'(alloc_units) <= 16;
            for (int u=0;u<16;u++)
                if (u >= base && u < base + int'(alloc_units) && unit_live_q[u]) fit = 1'b0;
            if (fit && !alloc_found) begin alloc_found=1'b1; alloc_first=4'(base); end
        end
        ctx_has_units=1'b0; free_has_all_units=1'b1;
        for (int u=0;u<16;u++) begin
            if (unit_live_q[u] && unit_ctx_q[u*5+:5] == ctx_id_i && unit_epoch_q[u*16+:16] == ctx_epoch_i)
                ctx_has_units=1'b1;
            if (u >= int'(free_base_i)/32 && u < (int'(free_base_i)+int'(free_columns_i))/32 &&
                !(unit_live_q[u] && unit_ctx_q[u*5+:5] == free_ctx_i && unit_epoch_q[u*16+:16] == free_epoch_i))
                free_has_all_units=1'b0;
        end
        ctx_error = OK;
        if (int'(ctx_id_i) >= CONTEXTS) ctx_error=BAD_CONTEXT;
        else if (ctx_create_i ? ctx_live_q[ctx_id_i] : !context_ok(ctx_id_i,ctx_epoch_i)) ctx_error=BAD_CONTEXT;
        else if ((!ctx_create_i && ctx_has_units) || outstanding_q[ctx_id_i*9+:9] != 0 ||
                 (rd_fire && rd_ctx_i == ctx_id_i) ||
                 (wr_fire && wr_ctx_i == ctx_id_i)) ctx_error=BAD_BUSY;
        alloc_error=OK;
        if (!context_ok(alloc_ctx_i,alloc_epoch_i)) alloc_error=BAD_CONTEXT;
        else if (!permit_q[alloc_ctx_i]) alloc_error=BAD_PERMIT;
        else if (!alloc_valid || alloc_columns_i > last_cols_q[alloc_ctx_i*10+:10]) alloc_error=BAD_SIZE;
        free_valid=legal_size(free_columns_i) && free_base_i[4:0]==0 &&
                   (int'(free_base_i)+int'(free_columns_i) <= 512);
        free_error=OK;
        if (!context_ok(free_ctx_i,free_epoch_i)) free_error=BAD_CONTEXT;
        else if (!free_valid) free_error=BAD_ADDR;
        else if (!free_has_all_units) free_error=BAD_OWNER;
        relinquish_error=context_ok(relinquish_ctx_i,relinquish_epoch_i) ? OK : BAD_CONTEXT;
        ctx_rdy_o=1'b0; alloc_rdy_o=1'b0; free_rdy_o=1'b0; relinquish_rdy_o=1'b0;
        if (ctrl_space) begin
            if (free_vld_i && (free_error != OK ||
                (outstanding_q[free_ctx_i*9+:9] == 0 && !(rd_fire && rd_ctx_i == free_ctx_i) &&
                 !(wr_fire && wr_ctx_i == free_ctx_i)))) free_rdy_o=1'b1;
            else if (relinquish_vld_i) relinquish_rdy_o=1'b1;
            else if (ctx_vld_i) ctx_rdy_o=1'b1;
            else if (alloc_vld_i && (alloc_error != OK || alloc_found)) alloc_rdy_o=1'b1;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_rsp_vld_o <= 1'b0; ctrl_rsp_tag_o <= '0;
            ctrl_rsp_status_o <= OK; ctrl_rsp_base_o <= '0;
            rw_turn_q <= 1'b0; rd_bad_q <= OK; wr_bad_q <= OK;
            rd_rsp_ctx_q <= '0; wr_rsp_ctx_q <= '0;
            for (int c=0;c<CONTEXTS;c++) begin
                ctx_live_q[c] <= 1'b0; ctx_epoch_q[c*16+:16] <= '0;
                permit_q[c] <= 1'b0; last_cols_q[c*10+:10] <= 10'd512;
                outstanding_q[c*9+:9] <= '0;
            end
            for (int u=0;u<16;u++) begin
                unit_live_q[u] <= 1'b0; unit_ctx_q[u*5+:5] <= '0; unit_epoch_q[u*16+:16] <= '0;
            end
        end else begin
            if (same_word_conflict && rd_vld_i && wr_vld_i && (rd_fire || wr_fire)) rw_turn_q <= ~rw_turn_q;
            if (rd_fire) begin rd_bad_q <= rd_bad; rd_rsp_ctx_q <= rd_ctx_i; end
            if (wr_fire) begin wr_bad_q <= wr_bad; wr_rsp_ctx_q <= wr_ctx_i; end
            for (int c=0;c<CONTEXTS;c++) begin
                // A response remains outstanding until the consumer accepts it.
                outstanding_q[c*9+:9] <= outstanding_q[c*9+:9] +
                    9'(rd_fire && rd_ctx_i == 5'(c)) + 9'(wr_fire && wr_ctx_i == 5'(c)) -
                    9'(rd_retire && rd_rsp_ctx_q == 5'(c)) -
                    9'(wr_retire && wr_rsp_ctx_q == 5'(c));
                assert (int'(outstanding_q[c*9+:9]) + int'(rd_fire && rd_ctx_i == 5'(c)) +
                    int'(wr_fire && wr_ctx_i == 5'(c)) >=
                    int'(rd_retire && rd_rsp_ctx_q == 5'(c)) +
                    int'(wr_retire && wr_rsp_ctx_q == 5'(c)))
                    else $error("TMEM outstanding underflow");
            end
            if (ctrl_space) begin
                ctrl_rsp_vld_o <= free_rdy_o || relinquish_rdy_o || ctx_rdy_o || alloc_rdy_o;
                if (free_rdy_o) begin
                    ctrl_rsp_tag_o <= free_tag_i; ctrl_rsp_status_o <= free_error; ctrl_rsp_base_o <= free_base_i;
                    if (free_error == OK)
                        for (int u=0;u<16;u++)
                            if (u >= int'(free_base_i)/32 && u < (int'(free_base_i)+int'(free_columns_i))/32)
                                unit_live_q[u] <= 1'b0;
                end else if (relinquish_rdy_o) begin
                    ctrl_rsp_tag_o <= relinquish_tag_i; ctrl_rsp_status_o <= relinquish_error; ctrl_rsp_base_o <= '0;
                    if (relinquish_error == OK) permit_q[relinquish_ctx_i] <= 1'b0;
                end else if (ctx_rdy_o) begin
                    ctrl_rsp_tag_o <= ctx_tag_i; ctrl_rsp_status_o <= ctx_error; ctrl_rsp_base_o <= '0;
                    if (ctx_error == OK) begin
                        ctx_live_q[ctx_id_i] <= ctx_create_i;
                        if (ctx_create_i) begin
                            ctx_epoch_q[ctx_id_i*16+:16] <= ctx_epoch_i;
                            permit_q[ctx_id_i] <= 1'b1; last_cols_q[ctx_id_i*10+:10] <= 10'd512;
                        end
                    end
                end else if (alloc_rdy_o) begin
                    ctrl_rsp_tag_o <= alloc_tag_i; ctrl_rsp_status_o <= alloc_error;
                    ctrl_rsp_base_o <= {alloc_first,5'b0};
                    if (alloc_error == OK) begin
                        last_cols_q[alloc_ctx_i*10+:10] <= alloc_columns_i;
                        for (int u=0;u<16;u++)
                            if (u >= int'(alloc_first) && u < int'(alloc_first)+int'(alloc_units)) begin
                                unit_live_q[u] <= 1'b1;
                                unit_ctx_q[u*5+:5] <= alloc_ctx_i; unit_epoch_q[u*16+:16] <= alloc_epoch_i;
                            end
                    end
                end
            end
        end
    end
    initial begin
        if (CONTEXTS < 1 || CONTEXTS > 32) $error("TMEM CONTEXTS must be 1..32");
    end
endmodule
`default_nettype wire
