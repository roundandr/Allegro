// Coherent, shared 228 KiB SMEM. Client requests address 128-byte lines;
// byte-address splitting/merging belongs to blackwell_smem_port. Read and write
// bandwidth is shared by ALL clients, including the atomic execution path.
// Responses have independently reserved per-client credits: a stopped consumer
// cannot hold the SRAM output or consume another client's completion storage.
`default_nettype none
module blackwell_smem_backend #(
    parameter int unsigned CLIENTS = 8,
    parameter int unsigned RESPONSE_DEPTH = 4,
    parameter int unsigned LINES = 1824,
    parameter int unsigned TAG_W = 16
) (
    input wire clk, rst_n,
    input wire [CLIENTS-1:0] rd_vld_i,
    output logic [CLIENTS-1:0] rd_rdy_o,
    input wire [CLIENTS*32-1:0] rd_addr_i,
    input wire [CLIENTS*TAG_W-1:0] rd_tag_i,
    output wire [CLIENTS-1:0] rd_rsp_vld_o,
    input wire [CLIENTS-1:0] rd_rsp_rdy_i,
    output wire [CLIENTS*1024-1:0] rd_data_o,
    output wire [CLIENTS*TAG_W-1:0] rd_tag_o,
    output wire [CLIENTS-1:0] rd_error_o,
    input wire [CLIENTS-1:0] wr_vld_i,
    output logic [CLIENTS-1:0] wr_rdy_o,
    input wire [CLIENTS*32-1:0] wr_addr_i,
    input wire [CLIENTS*1024-1:0] wr_data_i,
    input wire [CLIENTS*128-1:0] wr_mask_i,
    input wire [CLIENTS*TAG_W-1:0] wr_tag_i,
    output wire [CLIENTS-1:0] wr_rsp_vld_o,
    input wire [CLIENTS-1:0] wr_rsp_rdy_i,
    output wire [CLIENTS*TAG_W-1:0] wr_tag_o,
    output wire [CLIENTS-1:0] wr_error_o,
    // TMA shared-memory reduction types: u32/s32/u64 add, u32/s32 min/max,
    // u32 inc/dec/and/or/xor. Each selected element must be wholly masked in.
    input wire atom_vld_i,
    output wire atom_rdy_o,
    input wire [31:0] atom_addr_i,
    input wire [1023:0] atom_data_i,
    input wire [127:0] atom_mask_i,
    input wire [3:0] atom_dtype_i, atom_op_i,
    input wire [TAG_W-1:0] atom_tag_i,
    output wire atom_rsp_vld_o,
    input wire atom_rsp_rdy_i,
    output wire [TAG_W-1:0] atom_tag_o,
    output wire atom_error_o
);
    import tma_mbarrier_pkg::*;
    localparam int unsigned CW = CLIENTS < 2 ? 1 : $clog2(CLIENTS);
    localparam int unsigned AW = $clog2(LINES+1);
    localparam int unsigned QW = $clog2(RESPONSE_DEPTH+1);
    localparam int unsigned MTW = TAG_W+CW+2;
    typedef enum logic [2:0] {A_IDLE, A_READ, A_WAIT_READ, A_WRITE, A_WAIT_WRITE, A_DONE} atom_state_t;
    atom_state_t atom_state_q;
    logic [31:0] atom_addr_q;
    logic [1023:0] atom_src_q, atom_result_q;
    logic [127:0] atom_mask_q;
    logic [3:0] atom_dtype_q, atom_op_q;
    logic [TAG_W-1:0] atom_tag_q;
    logic atom_error_q, atom_turn_q;
    logic [CW-1:0] rd_turn_q, wr_turn_q;
    logic [QW-1:0] rd_credit_q [CLIENTS], wr_credit_q [CLIENTS];
    logic [CLIENTS-1:0] rd_push, wr_push;
    wire [CLIENTS-1:0] rd_queue_rdy, wr_queue_rdy;
    logic mem_rd_vld, mem_wr_vld;
    wire mem_rd_rdy, mem_wr_rdy, mem_rd_rsp, mem_wr_rsp;
    logic [32*AW-1:0] mem_rd_addr, mem_wr_addr;
    logic [MTW-1:0] mem_rd_tag, mem_wr_tag;
    wire [MTW-1:0] mem_rd_rsp_tag, mem_wr_rsp_tag;
    wire [1023:0] mem_rd_data;
    logic [1023:0] mem_wr_data;
    logic [127:0] mem_wr_mask;
    wire mem_rd_error, mem_wr_error;
    integer rd_sel, wr_sel;
    logic rd_atom, wr_atom, rd_bad, wr_bad;
    logic [31:0] selected_rd_addr, selected_wr_addr;
    wire atom_active = atom_state_q != A_IDLE && atom_state_q != A_DONE;
    // Lock acquired when the atomic command is accepted, before its read.
    // A same-edge ordinary operation is ordered BEFORE the new atomic.
    assign atom_rdy_o = atom_state_q == A_IDLE;
    assign atom_rsp_vld_o = atom_state_q == A_DONE;
    assign atom_tag_o = atom_tag_q;
    assign atom_error_o = atom_error_q;
    function automatic logic bad_address(input logic [31:0] addr);
        return addr[6:0] != 0 || addr[31:7] >= 25'(LINES);
    endfunction
    function automatic logic conflict(input logic [31:0] addr);
        return atom_active && addr[31:7] == atom_addr_q[31:7];
    endfunction
    always_comb begin
        rd_sel = -1; wr_sel = -1;
        for (int delta = 0; delta < CLIENTS; delta++) begin
            if (rd_sel < 0 && rd_vld_i[(int'(rd_turn_q)+delta)%CLIENTS] &&
                (int'(rd_credit_q[(int'(rd_turn_q)+delta)%CLIENTS]) < RESPONSE_DEPTH ||
                 (rd_rsp_vld_o[(int'(rd_turn_q)+delta)%CLIENTS] && rd_rsp_rdy_i[(int'(rd_turn_q)+delta)%CLIENTS])) &&
                !conflict(rd_addr_i[((int'(rd_turn_q)+delta)%CLIENTS)*32+:32]))
                rd_sel = (int'(rd_turn_q)+delta)%CLIENTS;
            if (wr_sel < 0 && wr_vld_i[(int'(wr_turn_q)+delta)%CLIENTS] &&
                (int'(wr_credit_q[(int'(wr_turn_q)+delta)%CLIENTS]) < RESPONSE_DEPTH ||
                 (wr_rsp_vld_o[(int'(wr_turn_q)+delta)%CLIENTS] && wr_rsp_rdy_i[(int'(wr_turn_q)+delta)%CLIENTS])) &&
                !conflict(wr_addr_i[((int'(wr_turn_q)+delta)%CLIENTS)*32+:32]))
                wr_sel = (int'(wr_turn_q)+delta)%CLIENTS;
        end
        rd_atom = atom_state_q == A_READ && (rd_sel < 0 || atom_turn_q);
        wr_atom = atom_state_q == A_WRITE;
        selected_rd_addr = rd_atom ? atom_addr_q : (rd_sel >= 0 ? rd_addr_i[rd_sel*32+:32] : 32'd0);
        selected_wr_addr = wr_atom ? atom_addr_q : (wr_sel >= 0 ? wr_addr_i[wr_sel*32+:32] : 32'd0);
        rd_bad = bad_address(selected_rd_addr); wr_bad = bad_address(selected_wr_addr);
        mem_rd_vld = rd_atom || rd_sel >= 0;
        mem_wr_vld = wr_atom || wr_sel >= 0;
        rd_rdy_o = '0; wr_rdy_o = '0;
        if (rd_sel >= 0 && !rd_atom) rd_rdy_o[rd_sel] = mem_rd_rdy;
        if (wr_sel >= 0 && !wr_atom) wr_rdy_o[wr_sel] = mem_wr_rdy;
        mem_rd_tag = {rd_atom,rd_bad,CW'(rd_sel < 0 ? 0 : rd_sel),
                      rd_atom ? atom_tag_q : (rd_sel >= 0 ? rd_tag_i[rd_sel*TAG_W+:TAG_W] : {TAG_W{1'b0}})};
        mem_wr_tag = {wr_atom,wr_bad,CW'(wr_sel < 0 ? 0 : wr_sel),
                      wr_atom ? atom_tag_q : (wr_sel >= 0 ? wr_tag_i[wr_sel*TAG_W+:TAG_W] : {TAG_W{1'b0}})};
        for (int b = 0; b < 32; b++) begin
            // Invalid vectors deliberately use a representable out-of-range row
            // so the SRAM rejects the ENTIRE write, without truncated addressing.
            mem_rd_addr[b*AW+:AW] = rd_bad ? AW'(LINES) : AW'(selected_rd_addr >> 7);
            mem_wr_addr[b*AW+:AW] = wr_bad ? AW'(LINES) : AW'(selected_wr_addr >> 7);
        end
        mem_wr_data = wr_atom ? atom_result_q : (wr_sel >= 0 ? wr_data_i[wr_sel*1024+:1024] : '0);
        mem_wr_mask = wr_atom ? atom_mask_q : (wr_sel >= 0 ? wr_mask_i[wr_sel*128+:128] : '0);
        rd_push = '0; wr_push = '0;
        if (mem_rd_rsp && !mem_rd_rsp_tag[MTW-1]) rd_push[mem_rd_rsp_tag[TAG_W+:CW]] = 1'b1;
        if (mem_wr_rsp && !mem_wr_rsp_tag[MTW-1]) wr_push[mem_wr_rsp_tag[TAG_W+:CW]] = 1'b1;
    end
    blackwell_banked_sram #(.BANKS(32),.DATA_W(32),.DEPTH(LINES),.ADDR_W(AW),.TAG_W(MTW)) storage (
        .clk,.rst_n,.rd_vld_i(mem_rd_vld),.rd_rdy_o(mem_rd_rdy),.rd_mask_i(32'hffffffff),
        .rd_addr_i(mem_rd_addr),.rd_tag_i(mem_rd_tag),.rd_rsp_vld_o(mem_rd_rsp),.rd_rsp_rdy_i(1'b1),
        .rd_data_o(mem_rd_data),.rd_tag_o(mem_rd_rsp_tag),.rd_error_o(mem_rd_error),
        .wr_vld_i(mem_wr_vld),.wr_rdy_o(mem_wr_rdy),.wr_addr_i(mem_wr_addr),.wr_data_i(mem_wr_data),
        .wr_mask_i(mem_wr_mask),.wr_tag_i(mem_wr_tag),.wr_rsp_vld_o(mem_wr_rsp),.wr_rsp_rdy_i(1'b1),
        .wr_tag_o(mem_wr_rsp_tag),.wr_error_o(mem_wr_error)
    );
    for (genvar c = 0; c < CLIENTS; c++) begin : gen_responses
        blackwell_fifo #(.WIDTH(1025+TAG_W),.DEPTH(RESPONSE_DEPTH)) read_responses (
            .clk,.rst_n,.in_vld_i(rd_push[c]),.in_rdy_o(rd_queue_rdy[c]),
            .in_data_i({mem_rd_error | mem_rd_rsp_tag[MTW-2],mem_rd_rsp_tag[TAG_W-1:0],mem_rd_data}),
            .out_vld_o(rd_rsp_vld_o[c]),.out_rdy_i(rd_rsp_rdy_i[c]),
            .out_data_o({rd_error_o[c],rd_tag_o[c*TAG_W+:TAG_W],rd_data_o[c*1024+:1024]}),.count_o()
        );
        blackwell_fifo #(.WIDTH(1+TAG_W),.DEPTH(RESPONSE_DEPTH)) write_responses (
            .clk,.rst_n,.in_vld_i(wr_push[c]),.in_rdy_o(wr_queue_rdy[c]),
            .in_data_i({mem_wr_error | mem_wr_rsp_tag[MTW-2],mem_wr_rsp_tag[TAG_W-1:0]}),
            .out_vld_o(wr_rsp_vld_o[c]),.out_rdy_i(wr_rsp_rdy_i[c]),
            .out_data_o({wr_error_o[c],wr_tag_o[c*TAG_W+:TAG_W]}),.count_o()
        );
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin rd_credit_q[c] <= '0; wr_credit_q[c] <= '0; end
            else begin
                case ({rd_vld_i[c] && rd_rdy_o[c],rd_rsp_vld_o[c] && rd_rsp_rdy_i[c]})
                    2'b10: rd_credit_q[c] <= rd_credit_q[c]+1'b1;
                    2'b01: rd_credit_q[c] <= rd_credit_q[c]-1'b1;
                    default: ;
                endcase
                case ({wr_vld_i[c] && wr_rdy_o[c],wr_rsp_vld_o[c] && wr_rsp_rdy_i[c]})
                    2'b10: wr_credit_q[c] <= wr_credit_q[c]+1'b1;
                    2'b01: wr_credit_q[c] <= wr_credit_q[c]-1'b1;
                    default: ;
                endcase
                assert (!(rd_push[c] && !rd_queue_rdy[c])) else $error("SMEM read response credit lost");
                assert (!(wr_push[c] && !wr_queue_rdy[c])) else $error("SMEM write response credit lost");
            end
        end
    end
    logic atomic_legal;
    logic [1023:0] reduced;
    always_comb begin
        atomic_legal = !bad_address(atom_addr_i) && reduction_legal(atom_dtype_i,atom_op_i,1'b1,1'b0);
        for (int b = 0; b < 32; b++)
            if (atom_mask_i[b*4+:4] != 0 && atom_mask_i[b*4+:4] != 4'hf) atomic_legal = 1'b0;
        if (atom_dtype_i == TMA_TYPE_U64)
            for (int b = 0; b < 16; b++)
                if (atom_mask_i[b*8+:8] != 0 && atom_mask_i[b*8+:8] != 8'hff) atomic_legal = 1'b0;
        reduced = mem_rd_data;
        for (int b = 0; b < 32; b++) begin
            case (atom_op_q)
                TMA_RED_ADD: reduced[b*32+:32] = mem_rd_data[b*32+:32] + atom_src_q[b*32+:32];
                TMA_RED_MIN: reduced[b*32+:32] = atom_dtype_q == TMA_TYPE_S32 ?
                    ($signed(mem_rd_data[b*32+:32]) < $signed(atom_src_q[b*32+:32]) ? mem_rd_data[b*32+:32] : atom_src_q[b*32+:32]) :
                    (mem_rd_data[b*32+:32] < atom_src_q[b*32+:32] ? mem_rd_data[b*32+:32] : atom_src_q[b*32+:32]);
                TMA_RED_MAX: reduced[b*32+:32] = atom_dtype_q == TMA_TYPE_S32 ?
                    ($signed(mem_rd_data[b*32+:32]) > $signed(atom_src_q[b*32+:32]) ? mem_rd_data[b*32+:32] : atom_src_q[b*32+:32]) :
                    (mem_rd_data[b*32+:32] > atom_src_q[b*32+:32] ? mem_rd_data[b*32+:32] : atom_src_q[b*32+:32]);
                TMA_RED_INC: reduced[b*32+:32] = mem_rd_data[b*32+:32] >= atom_src_q[b*32+:32] ? 32'd0 : mem_rd_data[b*32+:32]+32'd1;
                TMA_RED_DEC: reduced[b*32+:32] = mem_rd_data[b*32+:32] == 0 || mem_rd_data[b*32+:32] > atom_src_q[b*32+:32] ? atom_src_q[b*32+:32] : mem_rd_data[b*32+:32]-32'd1;
                TMA_RED_AND: reduced[b*32+:32] = mem_rd_data[b*32+:32] & atom_src_q[b*32+:32];
                TMA_RED_OR: reduced[b*32+:32] = mem_rd_data[b*32+:32] | atom_src_q[b*32+:32];
                TMA_RED_XOR: reduced[b*32+:32] = mem_rd_data[b*32+:32] ^ atom_src_q[b*32+:32];
                default: ;
            endcase
        end
        if (atom_dtype_q == TMA_TYPE_U64)
            for (int b = 0; b < 16; b++) reduced[b*64+:64] = mem_rd_data[b*64+:64]+atom_src_q[b*64+:64];
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_turn_q <= '0; wr_turn_q <= '0; atom_state_q <= A_IDLE; atom_turn_q <= 1'b0;
            atom_addr_q <= '0; atom_mask_q <= '0; atom_dtype_q <= '0; atom_op_q <= '0; atom_tag_q <= '0; atom_error_q <= 1'b0;
        end else begin
            if (mem_rd_vld && mem_rd_rdy) begin
                atom_turn_q <= !rd_atom;
                if (!rd_atom) rd_turn_q <= rd_sel == CLIENTS-1 ? '0 : CW'(rd_sel+1);
            end
            if (mem_wr_vld && mem_wr_rdy && !wr_atom) wr_turn_q <= wr_sel == CLIENTS-1 ? '0 : CW'(wr_sel+1);
            case (atom_state_q)
                A_IDLE: if (atom_vld_i) begin
                    atom_addr_q <= atom_addr_i; atom_src_q <= atom_data_i; atom_mask_q <= atom_mask_i;
                    atom_dtype_q <= atom_dtype_i; atom_op_q <= atom_op_i; atom_tag_q <= atom_tag_i;
                    atom_error_q <= !atomic_legal; atom_state_q <= atomic_legal ? A_READ : A_DONE;
                end
                A_READ: if (mem_rd_vld && mem_rd_rdy && rd_atom) atom_state_q <= A_WAIT_READ;
                A_WAIT_READ: if (mem_rd_rsp && mem_rd_rsp_tag[MTW-1]) begin
                    atom_result_q <= reduced; atom_error_q <= mem_rd_error;
                    atom_state_q <= mem_rd_error ? A_DONE : A_WRITE;
                end
                A_WRITE: if (mem_wr_vld && mem_wr_rdy && wr_atom) atom_state_q <= A_WAIT_WRITE;
                A_WAIT_WRITE: if (mem_wr_rsp && mem_wr_rsp_tag[MTW-1]) begin
                    atom_error_q <= mem_wr_error; atom_state_q <= A_DONE;
                end
                A_DONE: if (atom_rsp_rdy_i) atom_state_q <= A_IDLE;
                default: atom_state_q <= A_IDLE;
            endcase
        end
    end
    initial if (CLIENTS < 1 || RESPONSE_DEPTH < 2 || LINES < 2) $error("Invalid SMEM configuration");
endmodule
`default_nettype wire
