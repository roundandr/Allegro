// Project ABI for one CTA. These are not PTX/SASS binary encodings.
package blackwell_async_pkg;
    localparam int unsigned TMEM_LANES = 128;
    localparam int unsigned TMEM_COLUMNS = 512;
    localparam int unsigned SMEM_BYTES = 228 * 1024;
    typedef enum logic [2:0] {
        TC_MMA, TC_CP, TC_SHIFT, TC_COMMIT, TC_FENCE_BEFORE, TC_FENCE_AFTER
    } tc_opcode_t;
    typedef enum logic [3:0] {
        TM_ALLOC=4'd0, TM_DEALLOC=4'd1, TM_RELINQUISH=4'd2,
        TM_LD=4'd3, TM_ST=4'd4, TM_WAIT_LD=4'd5, TM_WAIT_ST=4'd6,
        TM_CP=4'd7, TM_SHIFT=4'd8,
        TM_FENCE_BEFORE=4'd9, TM_FENCE_AFTER=4'd10
    } tmem_opcode_t;
    typedef enum logic [2:0] {
        CPL_TC, CPL_TMEM_LD, CPL_TMEM_ST, CPL_TMA_BYTES, CPL_BULK_GROUP
    } completion_domain_t;
    typedef struct packed {
        logic [9:0] issuer;
        logic [4:0] warp;
        logic [15:0] tag;
        logic [63:0] seq;
        logic [15:0] epoch;
    } async_id_t;
    typedef struct packed {
        async_id_t id;
        tc_opcode_t opcode;
        logic [3:0] kind;
        logic [3:0] a_type, b_type, d_type;
        logic [8:0] m, n, k;
        logic [63:0] a_desc, b_desc;
        logic [31:0] a_tmem, d_tmem, scale_a, scale_b, sparse_meta;
        logic a_from_tmem, sparse, ws, ashift, input_d;
        logic [3:0] scale_d;
        logic [2:0] scale_type, scale_vec;
        logic [2:0] collector;
        logic [7:0] output_mask;
    } tc_cmd_t;
    typedef struct packed {
        async_id_t id;
        tmem_opcode_t opcode;
        logic [31:0] addr;
        logic [9:0] columns;
        logic [2:0] shape;
        logic [7:0] repeat_count;
        logic pack, unpack;
        logic [31:0] half_offset;
        logic [63:0] smem_desc;
        logic [1:0] source_format;
    } tmem_cmd_t;
    typedef struct packed {
        async_id_t id;
        completion_domain_t domain;
        logic [7:0] status;
        logic [63:0] value;
    } async_event_t;
    typedef struct packed {
        async_id_t id;
        logic [63:0] barrier;
    } tc_commit_t;
    localparam logic [7:0] ASYNC_OK = 8'd0;
    localparam logic [7:0] ASYNC_BAD_COMPLETION = 8'd1;
    localparam logic [7:0] ASYNC_EXECUTION_ERROR = 8'd2;
    function automatic logic same_operation(input async_id_t a, input async_id_t b);
        return a == b;
    endfunction
endpackage
