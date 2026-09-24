"""Real 4x64 FP16/BF16 arithmetic lanes: values, tags and steady issue rate."""
import struct
import cocotb
from cocotb.triggers import Timer


def f32_bits(number):
    return int.from_bytes(struct.pack("<f", float(number)), "little")


def operands(dots, dtype):
    one = 0x3C00 if dtype == 2 else 0x3F80
    vector = sum(one << (16 * k) for k in range(16))
    ab = sum(vector << (256 * dot) for dot in range(dots))
    c = sum(f32_bits(dot) << (32 * dot) for dot in range(dots))
    return ab, c


@cocotb.test()
async def real_steady_dot_array_and_tags(d):
    dots = len(d.d_o) // 32
    assert dots in (4, 256)
    d.clk.value = 0
    d.rst_n.value = 0
    d.in_vld_i.value = 0
    d.out_rdy_i.value = 1
    d.tag_i.value = 0
    d.a_dtype_i.value = d.b_dtype_i.value = 2
    d.scale_input_d_i.value = 0
    ab, c = operands(dots, 2)
    d.a_vec_i.value = d.b_vec_i.value = ab
    d.c_i.value = c

    async def cycle(valid, tag, ready=True):
        d.clk.value = 0
        d.in_vld_i.value = int(valid)
        d.tag_i.value = tag
        d.out_rdy_i.value = int(ready)
        await Timer(5, units="ns")
        issue = valid and int(d.in_rdy_o.value)
        retire = ready and int(d.out_vld_o.value)
        result = (int(d.tag_o.value), int(d.d_o.value)) if retire else None
        d.clk.value = 1
        await Timer(5, units="ns")
        return issue, result

    for _ in range(3):
        await cycle(False, 0)
    d.rst_n.value = 1
    issued = retired = 0
    for tick in range(4096):
        fire, result = await cycle(True, tick)
        issued += fire
        if result is not None:
            tag, values = result
            assert tag == retired
            if retired in (0, 1, 1024, 2048, 4090):
                for dot in range(dots):
                    assert (values >> (dot * 32)) & 0xFFFFFFFF == f32_bits(16 + dot)
            else:
                assert values & 0xFFFFFFFF == f32_bits(16)
                assert (values >> ((dots - 1) * 32)) & 0xFFFFFFFF == f32_bits(15 + dots)
            retired += 1
    assert issued == 4096, (dots, issued)
    for _ in range(40):
        _, result = await cycle(False, 0)
        if result is not None:
            assert result[0] == retired
            retired += 1
        if retired == issued:
            break
    assert retired == 4096
    d._log.info("%d physical dots: %d steady cycles, %d FP16 operation/cycle",
                dots, issued, dots * 16 * 2)

    # A distinct BF16 operand stream checks that the shared dtype control
    # reaches every physical arithmetic pipeline after the FP16 drain.
    ab, _ = operands(dots, 1)
    d.a_vec_i.value = d.b_vec_i.value = ab
    d.a_dtype_i.value = d.b_dtype_i.value = 1
    issued = retired = 0
    for tag in range(4096):
        fire, result = await cycle(True, tag)
        assert fire
        issued += 1
        if result is not None:
            assert result[0] == retired
            assert result[1] & 0xFFFFFFFF == f32_bits(16)
            assert (result[1] >> ((dots - 1) * 32)) & 0xFFFFFFFF == f32_bits(15 + dots)
            retired += 1
    for _ in range(40):
        _, result = await cycle(False, 0)
        if result is not None:
            assert result[0] == retired
            values = result[1]
            assert values & 0xFFFFFFFF == f32_bits(16)
            assert (values >> ((dots - 1) * 32)) & 0xFFFFFFFF == f32_bits(15 + dots)
            retired += 1
        if retired == issued:
            break
    assert retired == issued == 4096
    d._log.info("%d physical dots: %d steady cycles, %d BF16 operation/cycle",
                dots, issued, dots * 16 * 2)

    # A stopped result consumer must hold the complete vector and tag while
    # admission eventually backpressures, then retire each accepted request.
    d.a_dtype_i.value = d.b_dtype_i.value = 2
    ab, _ = operands(dots, 2)
    d.a_vec_i.value = d.b_vec_i.value = ab
    accepted = 0
    for _ in range(40):
        fire, _ = await cycle(accepted < 4, accepted, ready=False)
        accepted += fire
        if accepted == 4 and int(d.out_vld_o.value):
            break
    assert accepted == 4
    held_tag = int(d.tag_o.value)
    held_data = int(d.d_o.value)
    assert held_tag == 0
    for _ in range(6):
        await cycle(False, 0, ready=False)
        assert int(d.out_vld_o.value)
        assert int(d.tag_o.value) == held_tag
        assert int(d.d_o.value) == held_data
    retired = 0
    for _ in range(40):
        _, result = await cycle(False, 0, ready=True)
        if result is not None:
            assert result[0] == retired
            retired += 1
        if retired == accepted:
            break
    assert retired == accepted
