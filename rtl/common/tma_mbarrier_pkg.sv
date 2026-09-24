// ============================================================================
// File Name   : tma_mbarrier_pkg.sv
// Date        : 2026-08-27
// Description : Public constants for the SM100a semantic TMA/mbarrier interface.
//
// This package describes an independently designed research interface.  It is
// not an NVIDIA ISA encoding and is not intended to be cycle accurate to a
// proprietary implementation.
// ============================================================================

package tma_mbarrier_pkg;
    localparam int unsigned TMA_DESC_W = 1024;
    localparam int unsigned TMA_DIMS   = 5;

    // Fixed-width project command ABI. Address translation and state-space
    // validation occur before issue; issuer is a thread ID within this CTA.
    localparam logic [1:0] BW_SEM_RELAXED = 2'd0;
    localparam logic [1:0] BW_SEM_RELEASE = 2'd1;
    localparam logic [1:0] BW_SEM_ACQUIRE = 2'd2;
    localparam logic [1:0] BW_SCOPE_CTA = 2'd0;
    localparam logic [1:0] BW_SCOPE_CLUSTER = 2'd1;
    localparam logic [1:0] BW_SCOPE_GPU = 2'd2;
    localparam logic [1:0] BW_SCOPE_SYS = 2'd3;
    localparam logic [2:0] BW_ORDER_RELEASE = 3'd0;
    localparam logic [2:0] BW_ORDER_ACQUIRE = 3'd1;
    localparam logic [2:0] BW_ORDER_PROXY = 3'd2;
    localparam logic [1:0] BW_PROXY_GENERIC = 2'd0;
    localparam logic [1:0] BW_PROXY_ASYNC = 2'd1;
    localparam logic [1:0] BW_PROXY_TENSORMAP = 2'd2;

    typedef struct packed {
        logic [4:0] opcode;
        logic [15:0] tag;
        logic [9:0] issuer;
        logic [63:0] seq;
        logic [63:0] addr;
        logic [31:0] arrive_count;
        logic [63:0] tx_bytes;
        logic phase_token;
        logic wait_parity;
        logic [63:0] state;
        logic [31:0] time_hint;
        logic layout;
        logic no_complete;
        logic conditional;
        logic [7:0] report;
        logic noinc;
        logic [1:0] sem;
        logic [1:0] scope;
    } bar_cmd_t;
    typedef struct packed {
        logic [15:0] tag;
        logic [9:0] issuer;
        logic [7:0] status;
        logic phase;
        logic locked;
        logic [63:0] state;
        logic wait_complete;
        logic [31:0] value;
        logic predicate;
        logic [7:0] report;
        logic report_predicate;
    } bar_rsp_t;
    typedef struct packed {
        logic [15:0] id;
        logic [9:0] issuer;
        logic [63:0] seq;
        logic [2:0] kind;
        logic [1:0] scope;
        logic [1:0] from_proxy;
        logic [1:0] to_proxy;
        logic [63:0] addr;
        logic [63:0] bytes;
    } bw_order_req_t;
    typedef struct packed {
        logic [15:0] id;
        logic [7:0] status;
    } bw_order_rsp_t;
    typedef struct packed {
        logic complete;
        logic [9:0] issuer;
        logic [63:0] seq;
        logic [7:0] status;
    } bw_async_req_t;
    typedef struct packed {
        logic [9:0] issuer;
        logic [63:0] seq;
        logic [7:0] status;
    } bw_async_rsp_t;
    typedef struct packed {
        logic [15:0] tag;
        logic [63:0] addr;
        logic [7:0] value;
    } bar_report_req_t;

    typedef struct packed {
        logic [4:0] opcode;
        logic [15:0] tag;
        logic [9:0] issuer;
        logic [63:0] seq;
        logic [63:0] desc_ptr;
        logic [159:0] coord;
        logic [31:0] smem_addr;
        logic [63:0] linear_addr;
        logic [31:0] linear_bytes;
        logic [63:0] barrier_addr;
        logic [2:0] mode;
        logic [79:0] im2col;
        logic [1:0] completion;
        logic  multi_cta;
        logic [31:0] wait_n;
        logic  wait_read;
        logic [3:0] dtype;
        logic [3:0] reduce_op;
        logic  multimem;
        logic  cp_mask_enable;
        logic [15:0] cp_mask;
        logic  ignore_oob;
        logic [3:0] oob_start;
        logic [3:0] oob_end;
        logic  atomic128;
        logic [1:0] sem;
        logic [1:0] scope;
        logic  cache_hint;
        logic [63:0] cache_policy;
        logic  map_shared;
        logic [3:0] replace_field;
        logic [2:0] replace_ord;
        logic [63:0] replace_value;
        logic [1:0] from_proxy;
        logic [1:0] to_proxy;
        logic  warp_converged;
    } tma_cmd_t;
    typedef struct packed {
        logic [15:0] tag;
        logic [9:0] issuer;
        logic [7:0] status;
        logic [63:0] bytes;
    } tma_rsp_t;
    localparam logic [2:0] BW_MEM_READ = 3'd0;
    localparam logic [2:0] BW_MEM_WRITE = 3'd1;
    localparam logic [2:0] BW_MEM_REDUCE = 3'd2;
    localparam logic [2:0] BW_MEM_PREFETCH = 3'd3;
    typedef struct packed {
        logic [2:0] kind;
        logic [3:0] dtype;
        logic [3:0] reduce_op;
        logic multimem;
        logic atomic128;
        logic [9:0] issuer;
        logic [63:0] seq;
        logic [1:0] scope;
        logic [1:0] proxy;
        logic cache_hint;
        logic [63:0] cache_policy;
        logic [1:0] l2_promotion;
    } bw_mem_attr_t;

    localparam logic [7:0] TMA_STATUS_ORDER = 8'h28;
    // TMA command opcodes.
    localparam logic [4:0] TMA_OP_LOAD_TENSOR  = 5'd0;
    localparam logic [4:0] TMA_OP_STORE_TENSOR = 5'd1;
    localparam logic [4:0] TMA_OP_LOAD_LINEAR  = 5'd2;
    localparam logic [4:0] TMA_OP_STORE_LINEAR = 5'd3;
    localparam logic [4:0] TMA_OP_DESC_INV     = 5'd4;

    // mbarrier semantic operations; internal producer operations are separate.
    localparam logic [4:0] MBAR_OP_INIT              = 5'd0;
    localparam logic [4:0] MBAR_OP_ARRIVE            = 5'd1;
    localparam logic [4:0] MBAR_OP_EXPECT_TX         = 5'd2;
    localparam logic [4:0] MBAR_OP_ARRIVE_EXPECT_TX  = 5'd3;
    localparam logic [4:0] MBAR_OP_TRY_WAIT          = 5'd4;

    localparam logic [4:0] MBAR_OP_INVAL = 5'd5;
    localparam logic [4:0] TMA_OP_COMMIT_GROUP = 5'd5;
    localparam logic [4:0] TMA_OP_WAIT_GROUP = 5'd6;
    localparam logic [7:0] TMA_STATUS_UNSUPPORTED = 8'h27;
    localparam logic [1:0] TMA_CPL_MBAR = 2'd0;
    localparam logic [1:0] TMA_CPL_BULK = 2'd1;
    localparam logic [2:0] TMA_MODE_TILE = 3'd0;
    localparam logic [2:0] TMA_MODE_IM2COL = 3'd1;
    localparam logic [2:0] TMA_MODE_IM2COL_W = 3'd2;
    localparam logic [2:0] TMA_MODE_IM2COL_W128 = 3'd3;
    localparam logic [2:0] TMA_MODE_IM2COL_NO_OFFS = 3'd4;

    // Project same-CTA extension; PTX cp.async.bulk shared->shared requires a different CTA.
    localparam logic [4:0] TMA_OP_COPY_SHARED = 5'd7;
    localparam logic [4:0] TMA_OP_REDUCE_LINEAR = 5'd8;
    localparam logic [4:0] TMA_OP_REDUCE_TENSOR = 5'd9;
    localparam logic [4:0] TMA_OP_REDUCE_SHARED = 5'd10;
    localparam logic [4:0] TMA_OP_PREFETCH_LINEAR = 5'd11;
    localparam logic [4:0] TMA_OP_PREFETCH_TENSOR = 5'd12;
    localparam logic [4:0] TMA_OP_MAP_REPLACE = 5'd13;
    localparam logic [4:0] TMA_OP_MAP_CP_FENCE = 5'd14;
    localparam logic [4:0] TMA_OP_FENCE_PROXY = 5'd15;
    localparam logic [1:0] TMA_CPL_NONE = 2'd2;
    localparam logic [2:0] TMA_MODE_GATHER4 = 3'd5;
    localparam logic [2:0] TMA_MODE_SCATTER4 = 3'd6;
    // Type numbering follows PTX tensormap.replace Table 36 (not CUDA enum).
    localparam logic [3:0] TMA_TYPE_U8=4'd0, TMA_TYPE_U16=4'd1, TMA_TYPE_U32=4'd2,
        TMA_TYPE_S32=4'd3, TMA_TYPE_U64=4'd4, TMA_TYPE_S64=4'd5,
        TMA_TYPE_F16=4'd6, TMA_TYPE_F32=4'd7, TMA_TYPE_F32_FTZ=4'd8,
        TMA_TYPE_F64=4'd9, TMA_TYPE_BF16=4'd10, TMA_TYPE_TF32=4'd11,
        TMA_TYPE_TF32_FTZ=4'd12, TMA_TYPE_B4X16=4'd13,
        TMA_TYPE_B4X16_P64=4'd14, TMA_TYPE_B6X16=4'd15;
    localparam logic [3:0] TMA_RED_ADD=4'd0, TMA_RED_MIN=4'd1, TMA_RED_MAX=4'd2,
        TMA_RED_INC=4'd3, TMA_RED_DEC=4'd4, TMA_RED_AND=4'd5,
        TMA_RED_OR=4'd6, TMA_RED_XOR=4'd7;

    // Common status values.
    localparam logic [7:0] TMA_STATUS_OK             = 8'h00;
    localparam logic [7:0] TMA_STATUS_BAD_OPCODE     = 8'h20;
    localparam logic [7:0] TMA_STATUS_BAD_DESC_ALIGN = 8'h21;
    localparam logic [7:0] TMA_STATUS_BAD_DESC       = 8'h22;
    localparam logic [7:0] TMA_STATUS_BAD_DIM        = 8'h23;
    localparam logic [7:0] TMA_STATUS_BAD_ELEM       = 8'h24;
    localparam logic [7:0] TMA_STATUS_BAD_SMEM_ALIGN = 8'h25;
    localparam logic [7:0] TMA_STATUS_ADDR_OVERFLOW  = 8'h26;
    localparam logic [7:0] TMA_STATUS_GMEM           = 8'h30;
    localparam logic [7:0] TMA_STATUS_SMEM           = 8'h31;
    localparam logic [7:0] TMA_STATUS_MBARRIER       = 8'h32;
    localparam logic [7:0] TMA_STATUS_INTERNAL       = 8'h3f;

    localparam logic [7:0] MBAR_STATUS_OK            = 8'h00;
    localparam logic [7:0] MBAR_STATUS_BAD_OPCODE    = 8'h40;
    localparam logic [7:0] MBAR_STATUS_UNINITIALIZED = 8'h41;
    localparam logic [7:0] MBAR_STATUS_LOCKED        = 8'h42;
    localparam logic [7:0] MBAR_STATUS_OVERFLOW      = 8'h43;
    localparam logic [7:0] MBAR_STATUS_BAD_ARRIVE    = 8'h44;
    localparam logic [7:0] MBAR_STATUS_MEMORY        = 8'h45;
    // 0x46 retired: ARRIVE no longer consumes an input phase token.
    localparam logic [7:0] MBAR_STATUS_BAD_ALIGN     = 8'h47;
    localparam logic [7:0] MBAR_STATUS_INTERNAL      = 8'h4f;

    // Version 3, project-private 128-byte descriptor layout.  Multi-byte fields are little-endian when
    // represented in memory.  Unused high bits are reserved and must be zero.
    localparam int unsigned DESC_VERSION_LSB       = 0;
    localparam int unsigned DESC_DIMS_M1_LSB       = 8;
    localparam int unsigned DESC_RESERVED_TYPE_LSB     = 11;
    localparam int unsigned DESC_KIND_LSB          = 14;
    localparam int unsigned DESC_GMEM_BASE_LSB     = 16;
    localparam int unsigned DESC_TENSOR_SIZE_LSB   = 80;
    localparam int unsigned DESC_TENSOR_STRIDE_LSB = 240;
    localparam int unsigned DESC_BOX_SIZE_LSB      = 560;
    localparam int unsigned DESC_TRAV_STRIDE_LSB   = 640;

    localparam int unsigned DESC_SWIZZLE_LSB       = 720;
    localparam int unsigned DESC_LOWER_LSB         = 736;
    localparam int unsigned DESC_UPPER_LSB         = 784;
    localparam int unsigned DESC_CHANNELS_LSB      = 832;
    localparam int unsigned DESC_PIXELS_LSB        = 848;
    localparam int unsigned DESC_DTYPE_LSB = 864;
    localparam int unsigned DESC_INTERLEAVE_LSB = 868;
    localparam int unsigned DESC_FILL_BIT = 870;
    localparam int unsigned DESC_L2_PROMOTION_LSB = 871;
    localparam int unsigned DESC_CACHE_HINT_BIT = 873;
    localparam int unsigned DESC_CACHE_POLICY_LSB = 880;

    function automatic logic reduction_legal(input logic [3:0] dtype, op,
        input logic shared_dst, tensor_mode);
        begin
            reduction_legal = 1'b0;
            case (op)
                TMA_RED_ADD: reduction_legal = dtype == TMA_TYPE_U32 || dtype == TMA_TYPE_S32 || dtype == TMA_TYPE_U64 ||
                    (!shared_dst && (dtype == TMA_TYPE_F16 || dtype == TMA_TYPE_BF16 || dtype == TMA_TYPE_F32 ||
                     (tensor_mode && dtype == TMA_TYPE_F32_FTZ) || (!tensor_mode && dtype == TMA_TYPE_F64)));
                TMA_RED_MIN, TMA_RED_MAX: reduction_legal = dtype == TMA_TYPE_U32 || dtype == TMA_TYPE_S32 ||
                    (!shared_dst && (dtype == TMA_TYPE_U64 || dtype == TMA_TYPE_S64 || dtype == TMA_TYPE_F16 || dtype == TMA_TYPE_BF16));
                TMA_RED_INC, TMA_RED_DEC: reduction_legal = dtype == TMA_TYPE_U32;
                TMA_RED_AND, TMA_RED_OR, TMA_RED_XOR: reduction_legal = dtype == TMA_TYPE_U32 || (!shared_dst && dtype == TMA_TYPE_U64);
                default: reduction_legal = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [6:0] tensor_element_bits(input logic [3:0] dtype);
        case (dtype)
            TMA_TYPE_U8: return 7'd8;
            TMA_TYPE_U16, TMA_TYPE_F16, TMA_TYPE_BF16: return 7'd16;
            TMA_TYPE_U64, TMA_TYPE_S64, TMA_TYPE_F64: return 7'd64;
            TMA_TYPE_B4X16, TMA_TYPE_B4X16_P64: return 7'd4;
            TMA_TYPE_B6X16: return 7'd6;
            default: return 7'd32;
        endcase
    endfunction

    function automatic logic [31:0] tensor_tf32_rne(input logic [31:0] word);
        logic [18:0] rounded;
        if (word[30:23] == 8'hff)
            return (word[22:0] == 0) ? word : 32'h7fff_e000;
        rounded = {1'b0,word[30:13]} + 19'((word[12:0] > 13'd4096) ||
            ((word[12:0] == 13'd4096) && word[13]));
        return {word[31], rounded[17:0], 13'd0};
    endfunction

    function automatic logic [1023:0] tensor_convert(
        input logic [1023:0] data, input logic [3:0] dtype,
        input logic store, input logic [2:0] packed_shift);
        logic [1023:0] result;
        logic [11:0] packed_pair;
        result = data;
        if (!store && (dtype == TMA_TYPE_TF32 || dtype == TMA_TYPE_TF32_FTZ))
            result[31:0] = tensor_tf32_rne(data[31:0]);
        if (store && dtype == TMA_TYPE_B6X16) begin
            packed_pair = {data[13:8], data[5:0]};
            result = (1024'(packed_pair) >> packed_shift);
        end
        return result;
    endfunction
    // DESC_TENSOR_SIZE stores globalDim - 1; v1 direct sizes are rejected.

    localparam logic [4:0] MBAR_OP_TEST_WAIT = 5'd6;
    localparam logic [4:0] MBAR_OP_COMPLETE_TX = 5'd7;
    localparam logic [4:0] MBAR_OP_ARRIVE_DROP = 5'd8;
    localparam logic [4:0] MBAR_OP_DROP_EXPECT_TX = 5'd9;
    localparam logic [4:0] MBAR_OP_PENDING_COUNT = 5'd10;
    localparam logic [4:0] MBAR_OP_CHECK_LAYOUT = 5'd11;
    localparam logic [4:0] MBAR_OP_CP_ASYNC_ARRIVE = 5'd12;
    localparam logic [4:0] MBAR_OP_FAULT = 5'd28;
    localparam logic [4:0] MBAR_OP_REPORT = 5'd29;
    localparam logic [4:0] MBAR_OP_PENDING_INC = 5'd30;
    localparam logic [4:0] MBAR_OP_TX_COMPLETE = 5'd31;
    localparam logic [7:0] MBAR_STATUS_BAD_TOKEN = 8'h48;
    localparam logic [7:0] MBAR_STATUS_BAD_MODIFIER = 8'h49;

    // Decoded arithmetic representation; backing encoding remains exactly b64.
    typedef struct packed {
        logic valid;
        logic layout_v1;
        logic phase;
        logic conditional_phase;
        logic [19:0] expected;
        logic [19:0] pending;
        logic signed [20:0] tx;
        logic [7:0] report0;
        logic [7:0] report1;
    } bar_object_t;

    function automatic bar_object_t bar_unpack(input logic [63:0] raw);
        bar_object_t obj;
        obj = '0;
        obj.valid = raw[0];
        obj.phase = raw[1];
        obj.layout_v1 = raw[2];
        if (raw[2]) begin
            obj.expected = {11'd0, raw[3 +: 9]};
            obj.pending = {11'd0, raw[12 +: 9]};
            obj.tx = $signed(raw[21 +: 21]);
            obj.conditional_phase = raw[42];
            obj.report0 = raw[43 +: 8];
            obj.report1 = raw[51 +: 8];
        end else begin
            obj.expected = raw[3 +: 20];
            obj.pending = raw[23 +: 20];
            obj.tx = $signed(raw[43 +: 21]);
            obj.conditional_phase = raw[1];
        end
        return obj;
    endfunction

    function automatic logic [63:0] bar_pack(input bar_object_t obj);
        logic [63:0] raw;
        raw = '0;
        raw[0] = obj.valid;
        raw[1] = obj.phase;
        raw[2] = obj.layout_v1;
        if (obj.layout_v1) begin
            raw[3 +: 9] = obj.expected[8:0];
            raw[12 +: 9] = obj.pending[8:0];
            raw[21 +: 21] = obj.tx;
            raw[42] = obj.conditional_phase;
            raw[43 +: 8] = obj.report0;
            raw[51 +: 8] = obj.report1;
        end else begin
            raw[3 +: 20] = obj.expected;
            raw[23 +: 20] = obj.pending;
            raw[43 +: 21] = obj.tx;
        end
        return raw;
    endfunction

    function automatic logic bar_wait_phase(input logic [63:0] raw, input logic conditional);
        return conditional && raw[2] ? raw[42] : raw[1];
    endfunction

    function automatic logic [7:0] bar_report(input logic [63:0] raw, input logic phase);
        return !raw[2] ? 8'd0 : (phase ? raw[51 +: 8] : raw[43 +: 8]);
    endfunction

    function automatic logic [63:0] bar_token(input bar_object_t obj, input logic no_complete);
        logic [63:0] token;
        token = '0;
        token[63:56] = 8'ha7;
        token[0] = obj.valid;
        token[1] = obj.phase;
        token[2] = obj.layout_v1;
        token[3] = no_complete;
        token[4 +: 20] = obj.pending;
        return token;
    endfunction

    // Versioned private backing layout. Tokens are independently encoded.
    localparam int unsigned BAR_STATE_VALID_BIT     = 0;
    localparam int unsigned BAR_STATE_PHASE_BIT     = 1;
    localparam int unsigned BAR_STATE_LAYOUT_BIT    = 2;
    localparam int unsigned BAR_STATE_EXPECTED_LSB  = 3;
    localparam int unsigned BAR_STATE_REMAINING_LSB = 23;
    localparam int unsigned BAR_STATE_TX_BAL_LSB    = 43;
endpackage
