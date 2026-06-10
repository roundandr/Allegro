from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

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
from mma_sim_nvfp4_ref import FP4_MODE_NVFP4, NVFP4DotMmaSimGolden, pack_fp4_lanes
from mma_sim_tf32_ref import TF32DotMmaSimGolden, float32_to_bits, pack_u32_lanes
from test_int8_dot import int8_dot_ref, pack_u8_lanes as pack_int8_lanes


DTYPE_TF32 = 0
DTYPE_BF16 = 1
DTYPE_FP16 = 2
DTYPE_FP8_E4M3 = 3
DTYPE_FP8_E5M2 = 4
DTYPE_INT8 = 5
DTYPE_FP4 = 6
DTYPE_FP6_E3M2 = 7
DTYPE_FP6_E2M3 = 8

STATUS_OK = 0x00
STATUS_INVALID_SPARSE_META = 0x01
STATUS_UNSUPPORTED_DTYPE = 0x02


def pack_lanes(values: list[int], width: int) -> int:
    word = 0
    mask = (1 << width) - 1
    for index, value in enumerate(values):
        word |= (value & mask) << (width * index)
    return word


def make_2to4_meta(groups: int, pattern: int = 0b0011) -> int:
    meta = 0
    for group in range(groups):
        meta |= (pattern & 0xF) << (group * 4)
    return meta


def make_4to8_meta(groups: int = 16, pattern: int = 0x0F) -> int:
    meta = 0
    for group in range(groups):
        meta |= (pattern & 0xFF) << (group * 8)
    return meta


def sparse_full_from_compact(
    compact_values: list[int],
    meta: int,
    group_width: int,
    select_count: int,
    filler_values: list[int],
) -> list[int]:
    full: list[int] = []
    compact_index = 0
    groups = len(compact_values) // select_count
    for group in range(groups):
        mask = (meta >> (group * group_width)) & ((1 << group_width) - 1)
        selected = 0
        for lane in range(group_width):
            if mask & (1 << lane):
                full.append(compact_values[compact_index])
                compact_index += 1
                selected += 1
            else:
                fill_index = (group * group_width + lane) % len(filler_values)
                full.append(filler_values[fill_index])
        assert selected == select_count
    return full


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


def drive_request_inputs(
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
    mxfp8_en: int = 0,
    a_mx_scale: int = 127,
    b_mx_scale: int = 127,
    fp4_mode: int = 0,
    a_sf: int = 0,
    b_sf: int = 0,
) -> None:
    dut.req_dtype_i.value = dtype
    dut.req_sparse_en_i.value = sparse_en
    dut.req_a_packed_i.value = a_bits
    dut.req_b_packed_i.value = b_bits
    dut.req_meta_i.value = meta
    dut.req_c_i.value = c_bits
    dut.req_tag_i.value = tag
    dut.req_mxfp8_en_i.value = mxfp8_en
    dut.req_a_mx_scale_i.value = a_mx_scale
    dut.req_b_mx_scale_i.value = b_mx_scale
    dut.req_a_unsigned_i.value = a_unsigned
    dut.req_b_unsigned_i.value = b_unsigned
    dut.req_int_sat_en_i.value = sat_en
    dut.req_fp4_mode_i.value = fp4_mode
    dut.req_a_sf_i.value = a_sf
    dut.req_b_sf_i.value = b_sf


async def send_cluster_case(
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
    mxfp8_en: int = 0,
    a_mx_scale: int = 127,
    b_mx_scale: int = 127,
    fp4_mode: int = 0,
    a_sf: int = 0,
    b_sf: int = 0,
) -> None:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    drive_request_inputs(
        dut,
        dtype,
        a_bits,
        b_bits,
        c_bits,
        tag=tag,
        sparse_en=sparse_en,
        meta=meta,
        a_unsigned=a_unsigned,
        b_unsigned=b_unsigned,
        sat_en=sat_en,
        mxfp8_en=mxfp8_en,
        a_mx_scale=a_mx_scale,
        b_mx_scale=b_mx_scale,
        fp4_mode=fp4_mode,
        a_sf=a_sf,
        b_sf=b_sf,
    )
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0


async def collect_outputs(dut, count: int) -> list[tuple[int, int, int]]:
    outputs: list[tuple[int, int, int]] = []
    while len(outputs) < count:
        if int(dut.out_vld_o.value):
            outputs.append(
                (
                    int(dut.out_d_o.value),
                    int(dut.out_status_o.value),
                    int(dut.out_tag_o.value),
                )
            )
        await RisingEdge(dut.clk)
    return outputs


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
    mxfp8_en: int = 0,
    a_mx_scale: int = 127,
    b_mx_scale: int = 127,
    fp4_mode: int = 0,
    a_sf: int = 0,
    b_sf: int = 0,
) -> tuple[int, int, int]:
    await send_cluster_case(
        dut,
        dtype,
        a_bits,
        b_bits,
        c_bits,
        tag=tag,
        sparse_en=sparse_en,
        meta=meta,
        a_unsigned=a_unsigned,
        b_unsigned=b_unsigned,
        sat_en=sat_en,
        mxfp8_en=mxfp8_en,
        a_mx_scale=a_mx_scale,
        b_mx_scale=b_mx_scale,
        fp4_mode=fp4_mode,
        a_sf=a_sf,
        b_sf=b_sf,
    )

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


@cocotb.test()
async def dot_cluster_top_sparse_dispatch_matches_goldens(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    fp16_golden = FP16DotMmaSimGolden()
    f4f6f8_golden = F4F6F8DotMmaSimGolden()
    fp4_golden = NVFP4DotMmaSimGolden()
    c_bits = float32_to_bits(0.0)

    fp16_meta = make_2to4_meta(8, 0b0101)
    fp16_a_values = [0x3C00] * 16
    fp16_b_compact = [0x4000] * 16
    fp16_b_full = sparse_full_from_compact(fp16_b_compact, fp16_meta, 4, 2, [0x7C00, 0xFC00])
    expected = fp16_golden(
        pack_u16_lanes(fp16_a_values),
        pack_u16_lanes(fp16_b_compact),
        c_bits,
        FP16,
        FP16,
    )
    actual, status, tag = await run_cluster_case(
        dut,
        DTYPE_FP16,
        pack_u16_lanes(fp16_a_values),
        pack_u16_lanes(fp16_b_full),
        c_bits,
        tag=0x50,
        sparse_en=1,
        meta=fp16_meta,
    )
    assert (actual, status, tag) == (expected, STATUS_OK, 0x50)

    fp8_meta = make_2to4_meta(16, 0b1010)
    fp8_a_values = [0x38] * 32
    fp8_b_compact = [0x38] * 32
    fp8_b_full = sparse_full_from_compact(fp8_b_compact, fp8_meta, 4, 2, [0x7F, 0x80])
    expected = f4f6f8_golden(
        pack_u8_lanes(fp8_a_values),
        pack_u8_lanes(fp8_b_compact),
        c_bits,
        FP8_E4M3,
        a_type=F4F6F8_TYPE_E4M3,
        b_type=F4F6F8_TYPE_E4M3,
    )
    actual, status, tag = await run_cluster_case(
        dut,
        DTYPE_FP8_E4M3,
        pack_u8_lanes(fp8_a_values),
        pack_u8_lanes(fp8_b_full),
        c_bits,
        tag=0x51,
        sparse_en=1,
        meta=fp8_meta,
    )
    assert (actual, status, tag) == (expected, STATUS_OK, 0x51)

    int8_meta = make_2to4_meta(16, 0b0110)
    int8_a_values = [1] * 32
    int8_b_compact = [2] * 32
    int8_b_full = sparse_full_from_compact(int8_b_compact, int8_meta, 4, 2, [0x7F, 0x80])
    expected, overflow = int8_dot_ref(int8_a_values, int8_b_compact, c_bits, 0, 0, 0)
    assert overflow == 0
    actual, status, tag = await run_cluster_case(
        dut,
        DTYPE_INT8,
        pack_int8_lanes(int8_a_values),
        pack_lanes(int8_b_full, 8),
        c_bits,
        tag=0x52,
        sparse_en=1,
        meta=int8_meta,
    )
    assert (actual, status, tag) == (expected, STATUS_OK, 0x52)

    fp4_meta = make_4to8_meta(16, 0x3C)
    fp4_a_values = [0x2] * 64
    fp4_b_compact = [0x2] * 64
    fp4_b_full = sparse_full_from_compact(fp4_b_compact, fp4_meta, 8, 4, [0x7, 0xF])
    fp4_scale = 0x38383838
    expected = fp4_golden(
        pack_fp4_lanes(fp4_a_values),
        pack_fp4_lanes(fp4_b_compact),
        fp4_scale,
        fp4_scale,
        c_bits,
        FP4_MODE_NVFP4,
    )
    actual, status, tag = await run_cluster_case(
        dut,
        DTYPE_FP4,
        pack_fp4_lanes(fp4_a_values),
        pack_fp4_lanes(fp4_b_full),
        c_bits,
        tag=0x53,
        sparse_en=1,
        meta=fp4_meta,
        fp4_mode=FP4_MODE_NVFP4,
        a_sf=fp4_scale,
        b_sf=fp4_scale,
    )
    assert (actual, status, tag) == (expected, STATUS_OK, 0x53)


@cocotb.test()
async def dot_cluster_top_same_group_streams_after_fill(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    fp16_golden = FP16DotMmaSimGolden()
    c_bits = float32_to_bits(0.0)
    a_bits = pack_u16_lanes([0x3C00] * 16)
    b_patterns = [0x3C00, 0x4000, 0x4200, 0x4400]
    expected_outputs: list[tuple[int, int, int]] = []

    dut.in_vld_i.value = 1
    for index, b_value in enumerate(b_patterns):
        assert int(dut.in_rdy_o.value), f"same share-group request {index} stalled"
        b_bits = pack_u16_lanes([b_value] * 16)
        tag = 0x60 + index
        drive_request_inputs(dut, DTYPE_FP16, a_bits, b_bits, c_bits, tag=tag)
        expected_outputs.append((fp16_golden(a_bits, b_bits, c_bits, FP16, FP16), STATUS_OK, tag))
        await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0

    assert await collect_outputs(dut, len(expected_outputs)) == expected_outputs


@cocotb.test()
async def dot_cluster_top_mixed_share_group_preserves_issue_order(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    fp16_golden = FP16DotMmaSimGolden()
    c_bits = float32_to_bits(0.0)
    fp16_a = pack_u16_lanes([0x3C00] * 16)
    fp16_b = pack_u16_lanes([0x3C00] * 16)
    int8_a_values = [1] * 32
    int8_b_values = [2] * 32
    int8_a = pack_int8_lanes(int8_a_values)
    int8_b = pack_int8_lanes(int8_b_values)

    await send_cluster_case(dut, DTYPE_FP16, fp16_a, fp16_b, c_bits, tag=0x70)
    await send_cluster_case(dut, DTYPE_INT8, int8_a, int8_b, c_bits, tag=0x71)
    await send_cluster_case(dut, DTYPE_FP16, fp16_a, fp16_b, c_bits, tag=0x72)
    await ReadOnly()
    assert not int(dut.in_rdy_o.value), "two-stage request buffering did not backpressure"

    int8_expected, int8_overflow = int8_dot_ref(int8_a_values, int8_b_values, c_bits, 0, 0, 0)
    assert int8_overflow == 0
    expected_outputs = [
        (fp16_golden(fp16_a, fp16_b, c_bits, FP16, FP16), STATUS_OK, 0x70),
        (int8_expected, STATUS_OK, 0x71),
        (fp16_golden(fp16_a, fp16_b, c_bits, FP16, FP16), STATUS_OK, 0x72),
    ]
    assert await collect_outputs(dut, len(expected_outputs)) == expected_outputs


@cocotb.test()
async def dot_cluster_top_output_backpressure_holds_response(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    c_bits = float32_to_bits(0.0)
    fp16_a = pack_u16_lanes([0x3C00] * 16)
    fp16_b = pack_u16_lanes([0x3C00] * 16)
    dut.out_rdy_i.value = 0

    await send_cluster_case(dut, DTYPE_FP16, fp16_a, fp16_b, c_bits, tag=0x80)
    while not int(dut.out_vld_o.value):
        await RisingEdge(dut.clk)

    held = (int(dut.out_d_o.value), int(dut.out_status_o.value), int(dut.out_tag_o.value))
    for _ in range(3):
        await RisingEdge(dut.clk)
        assert (int(dut.out_d_o.value), int(dut.out_status_o.value), int(dut.out_tag_o.value)) == held

    dut.out_rdy_i.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def dot_cluster_top_ingress_capture_isolates_raw_inputs(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    fp16_golden = FP16DotMmaSimGolden()
    c_bits = float32_to_bits(0.0)
    fp16_a = pack_u16_lanes([0x3C00] * 16)
    fp16_b = pack_u16_lanes([0x3C00] * 16)
    expected = fp16_golden(fp16_a, fp16_b, c_bits, FP16, FP16)

    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    drive_request_inputs(dut, DTYPE_FP16, fp16_a, fp16_b, c_bits, tag=0x90)
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)

    dut.in_vld_i.value = 0
    drive_request_inputs(dut, 15, 0, 0, 0xDEADBEEF, tag=0x91)

    assert await collect_outputs(dut, 1) == [(expected, STATUS_OK, 0x90)]
