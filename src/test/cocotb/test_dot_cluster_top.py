from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from mma_sim_f4f6f8_ref import (
    F4F6F8DotMmaSimGolden,
    F4F6F8_TYPE_E2M3,
    F4F6F8_TYPE_E3M2,
    F4F6F8_TYPE_E4M3,
    F4F6F8_TYPE_E5M2,
    FP8_E4M3,
    pack_u6_lanes,
    pack_u8_lanes,
)
from mma_sim_fp16_ref import BF16, FP16, FP16DotMmaSimGolden, pack_u16_lanes
from mma_sim_tf32_ref import TF32DotMmaSimGolden, float32_to_bits, pack_u32_lanes
from test_int8_dot import int8_dot_ref, pack_u8_lanes as pack_int8_lanes


DTYPE_TF32 = 0
DTYPE_BF16 = 1
DTYPE_FP16 = 2
DTYPE_FP8_E4M3 = 3
DTYPE_FP8_E5M2 = 4
DTYPE_INT8 = 5
DTYPE_FP6_E3M2 = 7
DTYPE_FP6_E2M3 = 8

STATUS_OK = 0x00
STATUS_INVALID_SPARSE_META = 0x01
STATUS_UNSUPPORTED_DTYPE = 0x02


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 1
    dut.req_dtype_i.value = 0
    dut.req_sparse_en_i.value = 0
    dut.req_a_packed_i.value = 0
    dut.req_b_packed_i.value = 0
    dut.req_meta_i.value = 0
    dut.req_c_i.value = 0
    dut.req_tag_i.value = 0
    dut.req_mxfp8_en_i.value = 0
    dut.req_a_mx_scale_i.value = 127
    dut.req_b_mx_scale_i.value = 127
    dut.req_a_unsigned_i.value = 0
    dut.req_b_unsigned_i.value = 0
    dut.req_int_sat_en_i.value = 0
    dut.req_fp4_mode_i.value = 0
    dut.req_a_sf_i.value = 0
    dut.req_b_sf_i.value = 0

    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def run_cluster_case(
    dut,
    dtype: int,
    a_bits: int,
    b_bits: int,
    c_bits: int,
    *,
    tag: int,
    sparse_en: int = 0,
    meta: int = 0,
    a_unsigned: int = 0,
    b_unsigned: int = 0,
    sat_en: int = 0,
) -> tuple[int, int, int]:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    dut.req_dtype_i.value = dtype
    dut.req_sparse_en_i.value = sparse_en
    dut.req_a_packed_i.value = a_bits
    dut.req_b_packed_i.value = b_bits
    dut.req_meta_i.value = meta
    dut.req_c_i.value = c_bits
    dut.req_tag_i.value = tag
    dut.req_mxfp8_en_i.value = 0
    dut.req_a_mx_scale_i.value = 127
    dut.req_b_mx_scale_i.value = 127
    dut.req_a_unsigned_i.value = a_unsigned
    dut.req_b_unsigned_i.value = b_unsigned
    dut.req_int_sat_en_i.value = sat_en
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0

    while not int(dut.out_vld_o.value):
        await RisingEdge(dut.clk)

    result = int(dut.out_d_o.value)
    status = int(dut.out_status_o.value)
    out_tag = int(dut.out_tag_o.value)
    await RisingEdge(dut.clk)
    return result, status, out_tag


@cocotb.test()
async def dot_cluster_top_dispatch_matches_goldens(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    tf32_golden = TF32DotMmaSimGolden()
    fp16_golden = FP16DotMmaSimGolden()
    f4f6f8_golden = F4F6F8DotMmaSimGolden()
    c_bits = float32_to_bits(0.0)

    tf32_a = pack_u32_lanes([float32_to_bits(1.0)] * 8)
    tf32_b = pack_u32_lanes([float32_to_bits(1.0)] * 8)
    expected = tf32_golden(tf32_a, tf32_b, c_bits)
    actual, status, tag = await run_cluster_case(dut, DTYPE_TF32, tf32_a, tf32_b, c_bits, tag=0x10)
    assert (actual, status, tag) == (expected, STATUS_OK, 0x10)

    fp16_a = pack_u16_lanes([0x3C00] * 16)
    fp16_b = pack_u16_lanes([0x3C00] * 16)
    expected = fp16_golden(fp16_a, fp16_b, c_bits, FP16, FP16)
    actual, status, tag = await run_cluster_case(dut, DTYPE_FP16, fp16_a, fp16_b, c_bits, tag=0x11)
    assert (actual, status, tag) == (expected, STATUS_OK, 0x11)

    bf16_a = pack_u16_lanes([0x3F80] * 16)
    bf16_b = pack_u16_lanes([0x3F80] * 16)
    expected = fp16_golden(bf16_a, bf16_b, c_bits, BF16, BF16)
    actual, status, tag = await run_cluster_case(dut, DTYPE_BF16, bf16_a, bf16_b, c_bits, tag=0x12)
    assert (actual, status, tag) == (expected, STATUS_OK, 0x12)

    f4f6f8_cases = [
        (DTYPE_FP8_E4M3, F4F6F8_TYPE_E4M3, pack_u8_lanes([0x38] * 32)),
        (DTYPE_FP8_E5M2, F4F6F8_TYPE_E5M2, pack_u8_lanes([0x3C] * 32)),
        (DTYPE_FP6_E2M3, F4F6F8_TYPE_E2M3, pack_u6_lanes([0x08] * 32)),
        (DTYPE_FP6_E3M2, F4F6F8_TYPE_E3M2, pack_u6_lanes([0x0C] * 32)),
    ]
    for index, (dtype, value_type, packed) in enumerate(f4f6f8_cases):
        expected = f4f6f8_golden(packed, packed, c_bits, FP8_E4M3, a_type=value_type, b_type=value_type)
        actual, status, tag = await run_cluster_case(dut, dtype, packed, packed, c_bits, tag=0x20 + index)
        assert (actual, status, tag) == (expected, STATUS_OK, 0x20 + index)

    int8_a_vec = [1] * 32
    int8_b_vec = [2] * 32
    int8_a = pack_int8_lanes(int8_a_vec)
    int8_b = pack_int8_lanes(int8_b_vec)
    expected, overflow = int8_dot_ref(int8_a_vec, int8_b_vec, c_bits, 0, 0, 0)
    actual, status, tag = await run_cluster_case(dut, DTYPE_INT8, int8_a, int8_b, c_bits, tag=0x30)
    assert overflow == 0
    assert (actual, status, tag) == (expected, STATUS_OK, 0x30)

    c_passthrough = 0x12345678
    actual, status, tag = await run_cluster_case(dut, 15, 0, 0, c_passthrough, tag=0x40)
    assert (actual, status, tag) == (c_passthrough, STATUS_UNSUPPORTED_DTYPE, 0x40)

    actual, status, tag = await run_cluster_case(
        dut,
        DTYPE_FP16,
        fp16_a,
        fp16_b,
        c_passthrough,
        tag=0x41,
        sparse_en=1,
        meta=0,
    )
    assert (actual, status, tag) == (c_passthrough, STATUS_INVALID_SPARSE_META, 0x41)
