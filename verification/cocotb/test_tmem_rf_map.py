"""PTX fragment-coordinate examples and legal-domain checks for TMEM RF mapping."""
import cocotb
from cocotb.triggers import Timer


def reference(shape, thread, reg, repeat, lane, column, packed, split):
    if shape == 0:
        dl, dc = thread, reg
    elif shape == 1:
        dl, dc = thread // 4 + 8 * (thread % 2), 2 * reg + (thread // 2) % 2
    elif shape == 2:
        dl, dc = thread // 4 + 8 * (reg % 2), 4 * (reg // 2) + thread % 4
    elif shape == 3:
        dl, dc = thread // 4 + 8 * ((reg // 2) % 2), 8 * (reg // 4) + 2 * (thread % 4) + reg % 2
    elif shape == 4:
        dl, dc = thread % 16, reg
    else:
        return False, 0, 0
    register_count = repeat * (2 if shape == 2 else 4 if shape == 3 else 1)
    valid_repeat = repeat in (1, 2, 4, 8, 16, 32, 64, 128)
    valid_repeat &= repeat <= (64 if shape == 2 else 32 if shape == 3 else 128)
    address_lane = lane + dl
    address_column = column + (split if shape == 4 and thread >= 16 else 0) + dc * (2 if packed else 1)
    return (valid_repeat and reg < register_count and
            0 <= address_lane < 128 and address_column + int(packed) < 512,
            address_lane, address_column)


async def check(d, shape, warp, thread, reg, repeat, base_lane, base_col, packed, split):
    d.shape_i.value = shape
    d.warp_i.value = warp
    d.thread_i.value = thread
    d.reg_index_i.value = reg
    d.repeat_i.value = repeat
    d.base_addr_i.value = (base_lane << 16) | base_col
    d.pack16_i.value = packed
    d.half_offset_i.value = split
    await Timer(1, units="ns")
    valid, lane, col = reference(shape, thread, reg, repeat, base_lane, base_col, packed, split)
    valid &= (warp % 4) * 32 <= lane < (warp % 4 + 1) * 32
    assert int(d.valid_o.value) == valid, (shape, warp, thread, reg, repeat, base_lane, base_col, packed, split)
    if valid:
        assert int(d.cell0_o.value) == (lane << 16) | col
        assert int(d.cell1_o.value) == (lane << 16) | (col + 1)
        assert int(d.second_cell_o.value) == packed


@cocotb.test()
async def five_shapes_full_repeats_pack_and_bounds(d):
    # Explicit PTX/CUTLASS coordinate examples, including x2 second-half base.
    examples = [(1, 1, 0, 8, 0), (1, 2, 0, 0, 1), (1, 4, 0, 1, 0),
                (2, 0, 1, 8, 0), (2, 0, 3, 8, 4),
                (3, 3, 0, 0, 6), (3, 3, 2, 8, 6),
                (4, 16, 1, 0, 9)]
    for shape, thread, reg, lane, col in examples:
        await check(d, shape, 0, thread, reg, 2, 0, 0, 0, 8)
        assert int(d.cell0_o.value) == (lane << 16) | col

    for shape in range(5):
        for repeat in (1, 2, 4, 8, 16, 32, 64, 128):
            registers = repeat * (2 if shape == 2 else 4 if shape == 3 else 1)
            for warp in range(4):
                for thread in (0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 23, 31):
                    for reg in sorted({0, 1, min(255, registers // 2), min(255, registers - 1)}):
                        for packed in (0, 1):
                            await check(d, shape, warp, thread, reg, repeat,
                                        32 * warp + (16 if shape == 4 else 0),
                                        0, packed, 8)
    # Out-of-range register, column wrap, lane escape and invalid shape/repeat.
    for args in ((0, 0, 0, 1, 1, 0, 0, 0, 0),
                 (0, 0, 0, 0, 0, 0, 0, 0, 0),
                 (0, 0, 0, 0, 3, 0, 0, 0, 0),
                 (0, 0, 31, 0, 1, 1, 0, 0, 0),
                 (4, 0, 16, 1, 2, 0, 507, 1, 8),
                 (4, 0, 16, 0, 1, 0, 0, 0, 0xFFFFFFFF),
                 (5, 0, 0, 0, 1, 0, 0, 0, 0)):
        await check(d, *args)
    d._log.info("Five TMEM RF shapes: all repeat classes, pack, four warp ranks and bounds")
