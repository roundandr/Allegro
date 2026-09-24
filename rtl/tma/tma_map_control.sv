// Serialized generic-proxy descriptor update and tensor-map publication.
// Frontend proves warp convergence/operand agreement before MAP_CP_FENCE issue.
`default_nettype none
module tma_map_control #(
    parameter int unsigned GMEM_ID_W=5, SMEM_ID_W=5
)(
    input wire clk,rst_n,
    input wire cmd_vld_i, output wire cmd_rdy_o,
    input tma_mbarrier_pkg::tma_cmd_t cmd_i,
    output wire rsp_vld_o, input wire rsp_rdy_i,
    output tma_mbarrier_pkg::tma_rsp_t rsp_o,
    output wire gmem_req_vld_o, input wire gmem_req_rdy_i,
    output wire gmem_req_write_o, output wire [63:0] gmem_req_addr_o,
    output wire [1023:0] gmem_req_data_o, output wire [127:0] gmem_req_mask_o,
    output wire [GMEM_ID_W-1:0] gmem_req_id_o,
    output tma_mbarrier_pkg::bw_mem_attr_t gmem_req_attr_o,
    input wire gmem_rsp_vld_i, output wire gmem_rsp_rdy_o,
    input wire [1023:0] gmem_rsp_data_i, input wire [1:0] gmem_rsp_status_i,
    input wire [GMEM_ID_W-1:0] gmem_rsp_id_i,
    output wire smem_req_vld_o, input wire smem_req_rdy_i,
    output wire smem_req_write_o, output wire [31:0] smem_req_addr_o,
    output wire [255:0] smem_req_data_o, output wire [31:0] smem_req_mask_o,
    output wire [SMEM_ID_W-1:0] smem_req_id_o,
    output tma_mbarrier_pkg::bw_mem_attr_t smem_req_attr_o,
    input wire smem_rsp_vld_i, output wire smem_rsp_rdy_o,
    input wire [255:0] smem_rsp_data_i, input wire [1:0] smem_rsp_status_i,
    input wire [SMEM_ID_W-1:0] smem_rsp_id_i,
    output wire tma_order_req_vld_o, input wire tma_order_req_rdy_i,
    output tma_mbarrier_pkg::bw_order_req_t tma_order_req_o,
    input wire tma_order_rsp_vld_i, output wire tma_order_rsp_rdy_o,
    input tma_mbarrier_pkg::bw_order_rsp_t tma_order_rsp_i
);
    import tma_mbarrier_pkg::*;
    typedef enum logic [3:0] {IDLE,READ_REQ,READ_RSP,REPLACE,WRITE_REQ,WRITE_RSP,ORDER_REQ,ORDER_RSP,RESP} state_t;
    state_t state_q;
    tma_cmd_t cmd_q;
    logic [1023:0] data_q, replaced;
    logic [1:0] beat_q;
    logic [7:0] status_q, replace_status;
    logic source_shared,destination_shared,bus_shared,writing;
    logic [63:0] byte_addr;
    logic [6:0] global_offset;
    bw_mem_attr_t attr;
    wire response_fire = bus_shared ? (smem_rsp_vld_i && smem_rsp_rdy_o) : (gmem_rsp_vld_i && gmem_rsp_rdy_o);
    wire [1:0] mem_status = bus_shared ? smem_rsp_status_i : gmem_rsp_status_i;
    wire response_id_ok = bus_shared ? smem_rsp_id_i == 0 : gmem_rsp_id_i == 0;
    assign cmd_rdy_o = state_q == IDLE;
    assign rsp_vld_o = state_q == RESP;
    assign rsp_o = {cmd_q.tag,cmd_q.issuer,status_q,64'd0};
    always_comb begin
        source_shared = cmd_q.opcode == TMA_OP_MAP_CP_FENCE || cmd_q.map_shared;
        destination_shared = cmd_q.opcode == TMA_OP_MAP_REPLACE && cmd_q.map_shared;
        writing = state_q == WRITE_REQ || state_q == WRITE_RSP;
        bus_shared = writing ? destination_shared : source_shared;
        byte_addr = ((cmd_q.opcode == TMA_OP_MAP_CP_FENCE && !writing) ? {32'd0,cmd_q.smem_addr} : cmd_q.desc_ptr) + {57'd0,beat_q,5'd0};
        global_offset = byte_addr[6:0];
        attr = '0; attr.kind = writing ? BW_MEM_WRITE : BW_MEM_READ;
        attr.dtype = TMA_TYPE_U8; attr.proxy = BW_PROXY_GENERIC;
        attr.issuer = cmd_q.issuer; attr.seq = cmd_q.seq; attr.scope = cmd_q.scope;
    end
    assign gmem_req_attr_o = attr;
    assign smem_req_attr_o = attr;
    assign gmem_req_vld_o = !bus_shared && (state_q == READ_REQ || state_q == WRITE_REQ);
    assign smem_req_vld_o = bus_shared && (state_q == READ_REQ || state_q == WRITE_REQ);
    assign gmem_req_write_o = writing;
    assign smem_req_write_o = writing;
    assign gmem_req_addr_o = {byte_addr[63:7],7'd0};
    assign smem_req_addr_o = byte_addr[31:0];
    assign gmem_req_data_o = 1024'(data_q[beat_q*256 +: 256]) << (global_offset*8);
    assign smem_req_data_o = data_q[beat_q*256 +: 256];
    assign gmem_req_mask_o = (128'hffff_ffff << global_offset);
    assign smem_req_mask_o = 32'hffff_ffff;
    assign gmem_req_id_o = '0;
    assign smem_req_id_o = '0;
    assign gmem_rsp_rdy_o = !bus_shared && (state_q == READ_RSP || state_q == WRITE_RSP);
    assign smem_rsp_rdy_o = bus_shared && (state_q == READ_RSP || state_q == WRITE_RSP);
    assign tma_order_req_vld_o = state_q == ORDER_REQ;
    assign tma_order_rsp_rdy_o = state_q == ORDER_RSP;
    always_comb begin
        tma_order_req_o = '0;
        tma_order_req_o.id = cmd_q.tag; tma_order_req_o.issuer = cmd_q.issuer;
        tma_order_req_o.seq = cmd_q.seq; tma_order_req_o.scope = cmd_q.scope;
        tma_order_req_o.kind = cmd_q.sem == BW_SEM_ACQUIRE ? BW_ORDER_ACQUIRE : BW_ORDER_RELEASE;
        tma_order_req_o.addr = cmd_q.desc_ptr;
        tma_order_req_o.bytes = cmd_q.opcode == TMA_OP_MAP_CP_FENCE ? 64'd128 : {32'd0,cmd_q.linear_bytes};
        tma_order_req_o.from_proxy = cmd_q.opcode == TMA_OP_MAP_CP_FENCE ? BW_PROXY_GENERIC : cmd_q.from_proxy;
        tma_order_req_o.to_proxy = cmd_q.opcode == TMA_OP_MAP_CP_FENCE ? BW_PROXY_TENSORMAP : cmd_q.to_proxy;
    end
    // Field ordinals belong to the public replacement operation; the project
    // v3 object's positions below are private and are never CUDA opaque bits.
    always_comb begin
        replaced = data_q; replace_status = TMA_STATUS_OK;
        if (data_q[7:0] != 3 || data_q[15:14] != 0) replace_status = TMA_STATUS_BAD_DESC;
        if (cmd_q.replace_ord > 4) replace_status = TMA_STATUS_BAD_DESC;
        case (cmd_q.replace_field)
            0: replaced[79:16] = cmd_q.replace_value; // global_address
            1: begin
                if (cmd_q.replace_value > 4) replace_status = TMA_STATUS_BAD_DIM;
                replaced[10:8] = cmd_q.replace_value[2:0];
            end
            2: begin // box_dim
                if (cmd_q.replace_value == 0 || cmd_q.replace_value > 256) replace_status = TMA_STATUS_BAD_DESC;
                replaced[560+int'(cmd_q.replace_ord)*16 +: 16] = cmd_q.replace_value[15:0];
            end
            3: begin // global_dim: u32 operand; zero wraps to the encoded 2^32 extent
                if (cmd_q.replace_value > 64'hffff_ffff) replace_status = TMA_STATUS_BAD_DESC;
                replaced[80+int'(cmd_q.replace_ord)*32 +: 32] = cmd_q.replace_value[31:0]-32'd1;
            end
            4: begin
                // PTX global_stride ordinal zero is the stride of dimension 1.
                // Slot zero is implicit without interleave; ordinal 4 occupies
                // that spare internal slot (C-outer stride after normalization).
                replaced[240+((int'(cmd_q.replace_ord)+1)%5)*64 +: 64] = cmd_q.replace_value;
            end
            5: begin
                if (cmd_q.replace_value == 0 || cmd_q.replace_value > 8) replace_status = TMA_STATUS_BAD_DESC;
                replaced[640+int'(cmd_q.replace_ord)*16 +: 16] = cmd_q.replace_value[15:0];
            end
            6: begin
                if (cmd_q.replace_value > 15) replace_status = TMA_STATUS_BAD_DESC;
                replaced[867:864] = cmd_q.replace_value[3:0];
            end
            7: begin
                if (cmd_q.replace_value > 2) replace_status = TMA_STATUS_BAD_DESC;
                replaced[869:868] = cmd_q.replace_value[1:0];
            end
            8: begin
                if (cmd_q.replace_value > 3) replace_status = TMA_STATUS_UNSUPPORTED;
                replaced[723:720] = cmd_q.replace_value[3:0];
            end
            9: begin
                if (cmd_q.replace_value > 3) replace_status = TMA_STATUS_BAD_DESC;
                replaced[725:724] = cmd_q.replace_value[1:0];
            end
            10: begin
                if (cmd_q.replace_value > 1) replace_status = TMA_STATUS_BAD_DESC;
                replaced[870] = cmd_q.replace_value[0];
            end
            default: replace_status = TMA_STATUS_BAD_DESC;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= IDLE; cmd_q <= '0; data_q <= '0; beat_q <= 0; status_q <= 0;
        end else begin
            case (state_q)
                IDLE: if (cmd_vld_i) begin
                    cmd_q <= cmd_i; beat_q <= 0; status_q <= 0;
                    if (cmd_i.opcode == TMA_OP_FENCE_PROXY) begin
                        if ((cmd_i.sem != BW_SEM_RELEASE && cmd_i.sem != BW_SEM_ACQUIRE) || cmd_i.from_proxy > BW_PROXY_TENSORMAP || cmd_i.to_proxy > BW_PROXY_TENSORMAP) begin
                            status_q <= TMA_STATUS_UNSUPPORTED; state_q <= RESP;
                        end else state_q <= ORDER_REQ;
                    end else if (cmd_i.desc_ptr[5:0] != 0 || (cmd_i.map_shared && cmd_i.desc_ptr[63:32] != 0) ||
                        (cmd_i.opcode == TMA_OP_MAP_CP_FENCE && (cmd_i.smem_addr[5:0] != 0 || !cmd_i.warp_converged || cmd_i.linear_bytes != 128))) begin
                        status_q <= TMA_STATUS_BAD_DESC; state_q <= RESP;
                    end else state_q <= READ_REQ;
                end
                READ_REQ: if (bus_shared ? smem_req_rdy_i : gmem_req_rdy_i) state_q <= READ_RSP;
                READ_RSP: if (response_fire) begin
                    if (mem_status != 0 || !response_id_ok) begin
                        status_q <= bus_shared ? TMA_STATUS_SMEM : TMA_STATUS_GMEM; state_q <= RESP;
                    end else begin
                        data_q[beat_q*256 +: 256] <= bus_shared ? smem_rsp_data_i : 256'(gmem_rsp_data_i >> (global_offset*8));
                        if (beat_q == 3) begin
                            beat_q <= 0; state_q <= cmd_q.opcode == TMA_OP_MAP_REPLACE ? REPLACE : WRITE_REQ;
                        end else begin beat_q <= beat_q+2'd1; state_q <= READ_REQ; end
                    end
                end
                REPLACE: begin
                    data_q <= replaced;
                    if (replace_status != 0) begin status_q <= replace_status; state_q <= RESP; end
                    else state_q <= WRITE_REQ;
                end
                WRITE_REQ: if (bus_shared ? smem_req_rdy_i : gmem_req_rdy_i) state_q <= WRITE_RSP;
                WRITE_RSP: if (response_fire) begin
                    if (mem_status != 0 || !response_id_ok) begin
                        status_q <= bus_shared ? TMA_STATUS_SMEM : TMA_STATUS_GMEM; state_q <= RESP;
                    end else if (beat_q == 3) state_q <= cmd_q.opcode == TMA_OP_MAP_CP_FENCE ? ORDER_REQ : RESP;
                    else begin beat_q <= beat_q+2'd1; state_q <= WRITE_REQ; end
                end
                ORDER_REQ: if (tma_order_req_rdy_i) state_q <= ORDER_RSP;
                ORDER_RSP: if (tma_order_rsp_vld_i) begin
                    status_q <= tma_order_rsp_i.status == 0 && tma_order_rsp_i.id == cmd_q.tag ? TMA_STATUS_OK : TMA_STATUS_ORDER;
                    state_q <= RESP;
                end
                RESP: if (rsp_rdy_i) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
