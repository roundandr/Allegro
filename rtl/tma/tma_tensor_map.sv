// SM100a single-CTA address semantics for the project v3 tensor descriptor.
// Pure coordinate/layout stage: no memory traffic or completion state.
`default_nettype none
module tma_tensor_map (
    input wire [1023:0] desc_i,
    input wire [2:0] mode_i,
    input wire store_i,
    input wire [159:0] coord_i,
    input wire [79:0] im2col_i, // {wOffset:u16,wHalo:u16,offsetD/H/W:u16}
    input wire [31:0] smem_base_i,
    input wire [63:0] offset_i,
    output logic [2:0] packed_shift_o,
    output logic [7:0] status_o,
    output logic [63:0] total_bytes_o,
    output logic [4:0] elem_bytes_o,
    output logic [63:0] gmem_addr_o,
    output logic [31:0] smem_addr_o,
    output logic in_bounds_o,
    output logic address_valid_o
);
    import tma_mbarrier_pkg::*;
    logic [32:0] size_d [0:4];
    logic [63:0] stride_d [0:4];
    logic [15:0] box_d [0:4], step_d [0:4];
    logic signed [63:0] start_d [0:4], coord_d [0:4];
    logic signed [63:0] lower_d [0:2], upper_d [0:2];
    logic [63:0] radix_d [0:4];
    logic [63:0] ordinal, carry, first_count, capacity, rest, pixel, channel;
    logic [63:0] count, channels, pixels, halo, woffset;
    logic [63:0] elem, linear_saddr, swizzled, atom, span, inner_bytes;
    logic signed [63:0] lo, hi, begin_coord, corner_limit;
    logic signed [127:0] address_sum;
    logic [127:0] product_count;
    logic [2:0] rank;
    logic [3:0] swizzle;
    logic [1:0] kind;
    logic wide_mode, tiled_mode, four_rows, packed_type;
    logic [3:0] dtype;
    logic [1:0] interleave;
    logic [63:0] bits_per_element, group_payload, group_storage;
    logic [63:0] packed_byte, logical_storage, inner_payload, slice_channels;
    logic [63:0] interleave_bytes, slice_lane, channel_group;

    always_comb begin
        rank = desc_i[10:8] + 3'd1;
        dtype = desc_i[867:864];
        interleave = desc_i[869:868];
        packed_type = dtype >= TMA_TYPE_B4X16;
        bits_per_element = 64'(tensor_element_bits(dtype));
        elem = packed_type ? 64'd1 : bits_per_element / 8;
        group_payload = (dtype == TMA_TYPE_B6X16) ? 64'd12 : 64'd8;
        group_storage = (dtype == TMA_TYPE_B4X16) ? 64'd8 : 64'd16;
        packed_byte = 0;
        logical_storage = offset_i;
        packed_shift_o = 3'd0;
        inner_payload = 1;
        interleave_bytes = (interleave == 1) ? 64'd16 : 64'd32;
        slice_channels = interleave_bytes * 8 / bits_per_element;
        slice_lane = 0; channel_group = 0;
        four_rows = mode_i == TMA_MODE_GATHER4 || mode_i == TMA_MODE_SCATTER4;
        tiled_mode = mode_i == TMA_MODE_TILE || four_rows;
        elem_bytes_o = elem[4:0];
        kind = desc_i[15:14];
        swizzle = desc_i[723:720] == 3 ? 4'd3+{2'd0,desc_i[725:724]} : desc_i[723:720];
        if (desc_i[723:720] > 3) swizzle = 4'd7;
        channels = {48'd0, desc_i[847:832]};
        pixels = {48'd0, desc_i[863:848]};
        halo = {48'd0, im2col_i[63:48]};
        woffset = {48'd0, im2col_i[79:64]};
        wide_mode = (mode_i == TMA_MODE_IM2COL_W) || (mode_i == TMA_MODE_IM2COL_W128);
        status_o = TMA_STATUS_OK;
        product_count = 128'd1;
        ordinal = 0; carry = 0; first_count = 1; capacity = 1; rest = 0;
        pixel = 0; channel = 0; count = 0;
        lo = 0; hi = 1; begin_coord = 0;
        corner_limit = (rank == 3) ? 64'sd32768 : ((rank == 4) ? 64'sd128 : 64'sd16);
        for (int d = 0; d < 5; d = d + 1) begin
            size_d[d] = {1'b0, desc_i[80+d*32 +: 32]} + 33'd1;
            stride_d[d] = desc_i[240+d*64 +: 64];
            box_d[d] = desc_i[560+d*16 +: 16];
            step_d[d] = desc_i[640+d*16 +: 16];
            start_d[d] = {{32{coord_i[d*32+31]}}, coord_i[d*32 +: 32]};
            coord_d[d] = start_d[d];
            radix_d[d] = 1;
            if (d < rank) begin
                if ((step_d[d] == 0) || (step_d[d] > 8)) status_o = TMA_STATUS_BAD_DESC;
                if (tiled_mode) begin
                    if ((box_d[d] == 0) || (box_d[d] > 256)) status_o = TMA_STATUS_BAD_DESC;
                    radix_d[d] = (64'(box_d[d]) + 64'(step_d[d]) - 64'd1) /
                                 ((step_d[d] == 0) ? 64'd1 : 64'(step_d[d]));
                    if (interleave == 0 && d == 0) radix_d[d] = 64'(box_d[d]);
                    if (radix_d[d] == 0) radix_d[d] = 1;
                    if (interleave != 0 && d == 0)
                        radix_d[d] = (64'(box_d[d]) + slice_channels * 64'(step_d[d]) - 1) / (slice_channels * 64'(step_d[d]));
                    product_count = product_count * 128'(radix_d[d]);
                end
                if (d > 0) begin
                    if ((stride_d[d][3:0] != 0) || (stride_d[d] >= (64'd1 << 40)) ||
                        (interleave == 0 && ((d == 1 && 128'(stride_d[d])*8 < 128'(bits_per_element)*128'(size_d[0])) ||
                         (d > 1 && 128'(stride_d[d]) < 128'(stride_d[d-1])*128'(size_d[d-1])))))
                        status_o = TMA_STATUS_BAD_DESC;
                end
                if (store_i && (start_d[d] < 0)) status_o = TMA_STATUS_BAD_DESC;
            end
        end
        for (int d = 0; d < 3; d = d + 1) begin
            lower_d[d] = {{48{desc_i[736+d*16+15]}}, desc_i[736+d*16 +: 16]};
            upper_d[d] = {{48{desc_i[784+d*16+15]}}, desc_i[784+d*16 +: 16]};
        end
        if ((desc_i[7:0] != 8'd3) || (desc_i[735:726] != 0) || (desc_i[13:11] != 0) ||
            (desc_i[879:874] != 0) || (desc_i[1023:944] != 0))
            status_o = TMA_STATUS_BAD_DESC;
        if ((desc_i[10:8] > 4)) status_o = TMA_STATUS_BAD_DIM;
        if ((desc_i[19:16] != 0) || (desc_i[723:720] != 3 && desc_i[725:724] != 0))
            status_o = TMA_STATUS_BAD_DESC;
        if ((smem_base_i[3:0] != 0) || (tiled_mode && interleave == 0 && ((start_d[0] * $signed(bits_per_element)) & 64'sd127) != 0))
            status_o = TMA_STATUS_BAD_SMEM_ALIGN;
        if ((mode_i > TMA_MODE_SCATTER4) || (swizzle > 6)) status_o = TMA_STATUS_UNSUPPORTED;
        if ((store_i && (swizzle == 5)) || (wide_mode && ((swizzle == 0) || (swizzle == 5))))
            status_o = TMA_STATUS_UNSUPPORTED;
        if (((swizzle == 4 || swizzle == 5) && smem_base_i[4:0] != 0) ||
            ((swizzle == 6) && smem_base_i[5:0] != 0)) status_o = TMA_STATUS_BAD_SMEM_ALIGN;
        if ((tiled_mode && kind != 0) ||
            (wide_mode && kind != 2) ||
            ((mode_i == TMA_MODE_IM2COL || mode_i == TMA_MODE_IM2COL_NO_OFFS) && kind != 1))
            status_o = TMA_STATUS_BAD_DESC;
        if ((store_i && !tiled_mode && mode_i != TMA_MODE_IM2COL_NO_OFFS) ||
            (!store_i && mode_i == TMA_MODE_IM2COL_NO_OFFS)) status_o = TMA_STATUS_UNSUPPORTED;
        if (tiled_mode) begin
            if (interleave == 0 && (64'(box_d[0]) * bits_per_element) % 128 != 0) status_o = TMA_STATUS_BAD_DESC;
            count = 64'(box_d[0]);
        end else begin
            if (rank < 3 || channels == 0 || channels > 256 ||
                (mode_i != TMA_MODE_IM2COL_W128 && (pixels == 0 || pixels > 1024)) ||
                (interleave == 0 && ((channels * bits_per_element) % 128 != 0))) status_o = TMA_STATUS_BAD_DESC;
            if ((mode_i == TMA_MODE_IM2COL_W && halo >= 512) ||
                (mode_i == TMA_MODE_IM2COL_W128 && halo >= 32) || (wide_mode && woffset >= 32))
                status_o = TMA_STATUS_BAD_DESC;
            count = channels;
            if (mode_i == TMA_MODE_IM2COL_W128) product_count = 128'(channels) * (128'd128 + 128'd4 * 128'(halo));
            else product_count = 128'(channels) * (128'(pixels) + (wide_mode ? 128'(halo) : 128'd0));
            for (int d = 1; d < 4; d = d + 1) begin
                if (d < int'(rank)-1 && (!wide_mode || d == 1)) begin
                    lo = lower_d[d-1]; hi = $signed({31'd0,size_d[d]}) + upper_d[d-1];
                    if (lo < -corner_limit || lo >= corner_limit || upper_d[d-1] < -corner_limit ||
                        upper_d[d-1] >= corner_limit || hi <= lo || start_d[d] >= hi ||
                        (!wide_mode && start_d[d] < lo)) status_o = TMA_STATUS_BAD_DESC;
                    if (store_i && (lo < 0 || upper_d[d-1] > 0)) status_o = TMA_STATUS_BAD_DESC;
                    if (!wide_mode && mode_i != TMA_MODE_IM2COL_NO_OFFS &&
                        64'(im2col_i[(d-1)*16 +: 16]) >= (64'(corner_limit)*2)) status_o = TMA_STATUS_BAD_DESC;
                end
            end
        end
        if ((swizzle != 0) && interleave == 0 && (count * (packed_type && dtype != TMA_TYPE_B4X16 ? 64'd8 : bits_per_element)/8 > ((swizzle == 1) ? 32 : ((swizzle == 2) ? 64 : 128))))
            status_o = TMA_STATUS_BAD_DESC;
        if (four_rows) begin
            if (rank != 2 || box_d[1] != 1 || interleave != 0 ||
                (store_i != (mode_i == TMA_MODE_SCATTER4))) status_o = TMA_STATUS_BAD_DESC;
            for (int row=1; row<5; row=row+1)
                if (store_i && start_d[row] < 0) status_o = TMA_STATUS_BAD_DESC;
            product_count = product_count * 128'd4;
        end
        if (interleave != 0) begin
            if (rank < 3 || interleave > 2 || wide_mode || four_rows || dtype == TMA_TYPE_B6X16 || start_d[0] % $signed(slice_channels) != 0)
                status_o = TMA_STATUS_BAD_DESC;
            if (interleave == 2 && (swizzle != 1 || desc_i[20:16] != 0)) status_o = TMA_STATUS_BAD_DESC;
            if (tiled_mode) product_count = product_count * 128'(slice_channels);
            else product_count = product_count / ((channels == 0) ? 128'd1 : 128'(channels)) *
                ((128'(channels) + 128'(slice_channels) - 1)/128'(slice_channels))*128'(slice_channels);
            if (stride_d[0][3:0] != 0 || stride_d[0] >= (64'd1 << 40)) status_o = TMA_STATUS_BAD_DESC;
            for (int d = 0; d < 5; d = d + 1)
                if (d < rank && interleave == 2 && stride_d[d][4:0] != 0) status_o = TMA_STATUS_BAD_DESC;
        end
        if (packed_type) begin
            if (dtype == TMA_TYPE_B4X16 && size_d[0][0]) status_o = TMA_STATUS_BAD_DESC;
            if (dtype != TMA_TYPE_B4X16) begin
                if (size_d[0][6:0] != 0 || count != 128 || desc_i[20:16] != 0 || start_d[0][6:0] != 0) status_o = TMA_STATUS_BAD_DESC;
                for (int d = 1; d < 5; d = d + 1)
                    if (d < rank && stride_d[d][4:0] != 0) status_o = TMA_STATUS_BAD_DESC;
                if (dtype == TMA_TYPE_B4X16_P64 && store_i) status_o = TMA_STATUS_UNSUPPORTED;
                if (swizzle != 0 && swizzle != 3 && swizzle != 4 && swizzle != 6)
                    status_o = TMA_STATUS_UNSUPPORTED;
            end
        end
        if (desc_i[870] && (dtype < TMA_TYPE_F16 || packed_type)) status_o = TMA_STATUS_BAD_DESC;
        product_count = product_count * 128'(bits_per_element) / 128'd8;
        total_bytes_o = product_count[63:0];
        if (product_count[127:64] != 0) status_o = TMA_STATUS_ADDR_OVERFLOW;
        ordinal = offset_i / ((elem == 0) ? 64'd1 : elem);
        if (packed_type) begin
            ordinal = (offset_i / group_payload) * 16;
            packed_byte = offset_i % group_payload;
            logical_storage = (offset_i / group_payload) * group_storage + packed_byte;
            if (store_i && dtype == TMA_TYPE_B6X16) begin
                logical_storage = (offset_i / 12) * 16 + (packed_byte * 8) / 6;
                packed_shift_o = 3'((packed_byte * 8) % 6);
            end
        end
        if (tiled_mode && interleave != 0) begin
            slice_lane = ordinal % slice_channels;
            ordinal = ordinal / slice_channels;
            for (int d = 1; d < 4; d = d + 1) begin
                if (d < int'(rank)-1) begin
                    coord_d[d] = start_d[d] + $signed((ordinal % radix_d[d]) * ((d == 0 && interleave == 0) ? 64'd1 : 64'(step_d[d])));
                    ordinal = ordinal / radix_d[d];
                end
            end
            channel_group = ordinal % radix_d[0];
            ordinal = ordinal / radix_d[0];
            coord_d[0] = start_d[0] + $signed(channel_group*slice_channels*64'(step_d[0])+slice_lane);
            if (rank >= 3 && rank <= 5) coord_d[rank-1] = start_d[rank-1] + $signed(ordinal*64'(step_d[rank-1]));
        end else if (tiled_mode) begin
            for (int d = 0; d < 5; d = d + 1) begin
                if (d < rank) begin
                    coord_d[d] = start_d[d] + $signed((ordinal % radix_d[d]) * ((d == 0 && interleave == 0) ? 64'd1 : 64'(step_d[d])));
                    ordinal = ordinal / radix_d[d];
                end
            end
            if (four_rows) coord_d[1] = start_d[3'(1+((offset_i / ((64'(box_d[0])*bits_per_element)/8))%4))];
        end else begin
            inner_payload = interleave != 0 ? ((channels+slice_channels-1)/slice_channels)*slice_channels : channels;
            channel = ordinal % ((inner_payload == 0) ? 64'd1 : inner_payload);
            pixel = ordinal / ((inner_payload == 0) ? 64'd1 : inner_payload);
            if (mode_i == TMA_MODE_IM2COL_W128 && pixel >= 128 && halo != 0)
                pixel = ((pixel - 128) / halo + 1)*32 + ((pixel - 128) % halo);
            coord_d[0] = start_d[0] + $signed(channel);
            carry = pixel;
            for (int d = 1; d < 4; d = d + 1) begin
                if (d < int'(rank)-1 && (!wide_mode || d == 1)) begin
                    lo = lower_d[d-1] + ((wide_mode && d == 1) ? $signed(woffset) : 64'sd0);
                    hi = $signed({31'd0,size_d[d]}) + upper_d[d-1] + ((wide_mode && d == 1) ? $signed(woffset) : 64'sd0);
                    begin_coord = start_d[d] + ((wide_mode && d == 1) ? $signed(woffset) : 64'sd0);
                    first_count = (hi > begin_coord) ? (64'(hi-begin_coord) + 64'(step_d[d]) - 1) /
                        ((step_d[d] == 0) ? 64'd1 : 64'(step_d[d])) : 64'd1;
                    capacity = (hi > lo) ? (64'(hi-lo) + 64'(step_d[d]) - 1) /
                        ((step_d[d] == 0) ? 64'd1 : 64'(step_d[d])) : 64'd1;
                    if (capacity == 0) capacity = 1;
                    if (carry < first_count) begin
                        coord_d[d] = begin_coord + $signed(carry * 64'(step_d[d]));
                        carry = 0;
                    end else begin
                        rest = carry - first_count;
                        coord_d[d] = lo + $signed((rest % capacity) * 64'(step_d[d]));
                        carry = 1 + rest / capacity;
                    end
                    if (!wide_mode && mode_i != TMA_MODE_IM2COL_NO_OFFS)
                        coord_d[d] = coord_d[d] + $signed({48'd0,im2col_i[(d-1)*16 +: 16]});
                end
            end
            if (rank >= 3 && rank <= 5) coord_d[rank-1] = start_d[rank-1] + $signed(carry);
        end
        address_sum = $signed({64'd0, desc_i[79:16]});
        in_bounds_o = 1'b1;
        for (int d = 0; d < 5; d = d + 1) begin
            if (d < rank) begin
                if (coord_d[d] < 0 || $unsigned(coord_d[d]) >= {31'd0,size_d[d]}) in_bounds_o = 1'b0;
                if (d == 0 && interleave != 0) begin
                    address_sum = address_sum + (128'(coord_d[0]) / $signed({64'd0,slice_channels})) * $signed({64'd0,stride_d[0]}) +
                        (128'(coord_d[0]) % $signed({64'd0,slice_channels})) * $signed({64'd0,bits_per_element}) / 8;
                end else if (d == 0) address_sum = address_sum + 128'(coord_d[0]) * $signed({64'd0,bits_per_element}) / 8;
                else address_sum = address_sum + 128'(coord_d[d]) * $signed({64'd0,stride_d[d]});
            end
        end
        if (packed_type && (coord_d[0] + $signed(packed_byte*8/bits_per_element) >= $signed({31'd0,size_d[0]}))) in_bounds_o = 1'b0;
        if (packed_type) address_sum = address_sum + $signed({64'd0,packed_byte});
        gmem_addr_o = address_sum[63:0];
        span = (swizzle == 1) ? 64'd32 : ((swizzle == 2) ? 64'd64 : 64'd128);
        inner_bytes = (tiled_mode ? 64'(box_d[0]) : channels) * bits_per_element / 8;
        if (packed_type && dtype != TMA_TYPE_B4X16) inner_bytes = tiled_mode ? 64'(box_d[0]) : channels;
        if (interleave != 0) inner_bytes = interleave_bytes;
        if (inner_bytes == 0) inner_bytes = 1;
        linear_saddr = {32'd0,smem_base_i} + ((swizzle == 0) ? logical_storage :
            ((logical_storage / inner_bytes) * span + logical_storage % inner_bytes));
        swizzled = linear_saddr;
        atom = (swizzle == 4 || swizzle == 5) ? 64'd32 : ((swizzle == 6) ? 64'd64 : 64'd16);
        span = (swizzle == 1) ? 64'd32 : ((swizzle == 2) ? 64'd64 : 64'd128);
        if (swizzle != 0) begin
            swizzled = linear_saddr ^ (((linear_saddr / 128) % (span / atom)) * atom);
            if (swizzle == 5 && linear_saddr[7]) swizzled = swizzled ^ 64'd8;
        end
        smem_addr_o = swizzled[31:0];
        address_valid_o = (!in_bounds_o || address_sum[127:64] == 0) && swizzled[63:32] == 0;
    end
endmodule
`default_nettype wire
