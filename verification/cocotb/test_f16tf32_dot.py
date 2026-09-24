from __future__ import annotations

import os
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from mma_sim_fp16_ref import (
    BF16,
    FP16,
    FP16DotMmaSimGolden,
    float32_to_bits,
    pack_u16_lanes,
)
from mma_sim_tf32_ref import (
    TF32DotMmaSimGolden,
    pack_u32_lanes,
    float32_to_bits as tf32_float32_to_bits,
)


F16TF32_DTYPE_TF32 = 0
F16TF32_DTYPE_BF16 = 1
F16TF32_DTYPE_FP16 = 2

NUM_CASES = int(os.getenv("NUM_CASES", "6000"))
RANDOM_SEED = int(os.getenv("RANDOM_SEED", os.getenv("COCOTB_RANDOM_SEED", "20260429")))


def fp32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def dtype_name(dtype: int) -> str:
    if dtype == F16TF32_DTYPE_TF32:
        return "TF32"
    if dtype == F16TF32_DTYPE_BF16:
        return "BF16"
    if dtype == F16TF32_DTYPE_FP16:
        return "FP16"
    return f"dtype{dtype}"


def case_dump(dtype: int, a_bits: int, b_bits: int, c_bits: int) -> str:
    return (
        f"dtype={dtype_name(dtype)}, "
        f"a_vec_i=0x{a_bits:064x}, "
        f"b_vec_i=0x{b_bits:064x}, "
        f"c_i=0x{c_bits:08x}"
    )


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 1
    dut.a_dtype_i.value = F16TF32_DTYPE_TF32
    dut.b_dtype_i.value = F16TF32_DTYPE_TF32
    dut.a_vec_i.value = 0
    dut.b_vec_i.value = 0
    dut.c_i.value = 0
    dut.scale_input_d_i.value = 0

    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def run_case(
    dut,
    dtype: int,
    a_bits: int,
    b_bits: int,
    c_bits: int,
    stall_output: bool = False,
) -> int:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    dut.a_dtype_i.value = dtype
    dut.b_dtype_i.value = dtype
    dut.a_vec_i.value = a_bits
    dut.b_vec_i.value = b_bits
    dut.c_i.value = c_bits
    dut.scale_input_d_i.value = 0
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0

    if stall_output:
        dut.out_rdy_i.value = 0
        for _ in range(8):
            await RisingEdge(dut.clk)
        dut.out_rdy_i.value = 1

    while not int(dut.out_vld_o.value):
        await RisingEdge(dut.clk)

    result = int(dut.d_o.value)
    await RisingEdge(dut.clk)
    return result


def random_fp16_vec(rng: random.Random) -> list[int]:
    finite_pool = [
        0x0000, 0x8000, 0x0001, 0x03FF, 0x0400, 0x3C00, 0xBC00,
        0x4000, 0xC000, 0x3555, 0xB555, 0x7BFF, 0xFBFF,
    ]
    return [rng.choice(finite_pool + [rng.randrange(0x0000, 0x7C00)]) for _ in range(16)]


def random_bf16_vec(rng: random.Random) -> list[int]:
    finite_pool = [
        0x0000, 0x8000, 0x0001, 0x007F, 0x0080, 0x3F80, 0xBF80,
        0x4000, 0xC000, 0x3EAB, 0xBEAB, 0x7F7F, 0xFF7F,
    ]
    return [rng.choice(finite_pool + [rng.randrange(0x0000, 0x7F80)]) for _ in range(16)]


def random_tf32_bits(rng: random.Random) -> int:
    special_pool = [
        0x00000000,
        0x80000000,
        0x00000001,
        0x00002000,
        0x007FE000,
        0x00800000,
        0x3F800000,
        0xBF800000,
        0x40000000,
        0xC0000000,
        0x7F7FE000,
        0xFF7FE000,
    ]
    if rng.randrange(4) == 0:
        return rng.choice(special_pool)
    return tf32_float32_to_bits(rng.uniform(-32.0, 32.0))


@cocotb.test()
async def f16tf32_dot_matches_mmasim(dut):
    required_ports = [
        "clk",
        "rst_n",
        "in_vld_i",
        "in_rdy_o",
        "a_dtype_i",
        "b_dtype_i",
        "a_vec_i",
        "b_vec_i",
        "c_i",
        "scale_input_d_i",
        "out_vld_o",
        "out_rdy_i",
        "d_o",
    ]
    for port in required_ports:
        assert hasattr(dut, port), f"missing DUT port: {port}"

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    rng = random.Random(RANDOM_SEED)
    fp16_golden = FP16DotMmaSimGolden()
    tf32_golden = TF32DotMmaSimGolden()

    directed_cases = [
        (F16TF32_DTYPE_TF32, [0x00000000] * 8, [0x00000000] * 8, fp32_bits(0.0)),
        (F16TF32_DTYPE_TF32, [0x3F800001] + [0x00000000] * 7, [0x3F800001] + [0x00000000] * 7, fp32_bits(0.0)),
        (F16TF32_DTYPE_TF32, [0x00002000] + [0x00000000] * 7, [0x3F800000] + [0x00000000] * 7, fp32_bits(0.0)),
        (F16TF32_DTYPE_TF32, [0x7F800000, 0xFF800000] + [0x00000000] * 6, [0x3F800000] * 8, fp32_bits(0.0)),
        (F16TF32_DTYPE_TF32, [0x7FC00001] + [0x00000000] * 7, [0x3F800000] + [0x00000000] * 7, fp32_bits(0.0)),
        (F16TF32_DTYPE_TF32, [0x00000000] * 8, [0x00000000] * 8, 0x00000001),
        (F16TF32_DTYPE_FP16, [0x0000] * 16, [0x0000] * 16, fp32_bits(0.0)),
        (F16TF32_DTYPE_FP16, [0x3C00] * 16, [0x3C00] * 16, fp32_bits(0.0)),
        (F16TF32_DTYPE_FP16, [0x0001] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, fp32_bits(0.0)),
        (F16TF32_DTYPE_FP16, [0x0000] + [0x0000] * 15, [0x7C00] + [0x0000] * 15, fp32_bits(0.0)),
        (F16TF32_DTYPE_FP16, [0x7C00, 0xFC00] + [0x0000] * 14, [0x3C00] * 16, fp32_bits(0.0)),
        (F16TF32_DTYPE_FP16, [0x7E01] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, fp32_bits(0.0)),
        (F16TF32_DTYPE_BF16, [0x0000] * 16, [0x0000] * 16, fp32_bits(0.0)),
        (F16TF32_DTYPE_BF16, [0x3F80] * 16, [0x3F80] * 16, fp32_bits(0.0)),
        (F16TF32_DTYPE_BF16, [0x0001] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(0.0)),
        (F16TF32_DTYPE_BF16, [0x0000] + [0x0000] * 15, [0x7F80] + [0x0000] * 15, fp32_bits(0.0)),
        (F16TF32_DTYPE_BF16, [0x7F80, 0xFF80] + [0x0000] * 14, [0x3F80] * 16, fp32_bits(0.0)),
        (F16TF32_DTYPE_BF16, [0x7FC1] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(0.0)),
    ]

    for index, (dtype, a_vec, b_vec, c_bits) in enumerate(directed_cases):
        if dtype == F16TF32_DTYPE_TF32:
            a_bits = pack_u32_lanes(a_vec)
            b_bits = pack_u32_lanes(b_vec)
            expected = tf32_golden(a_bits, b_bits, c_bits)
        else:
            a_bits = pack_u16_lanes(a_vec)
            b_bits = pack_u16_lanes(b_vec)
            expected = fp16_golden(a_bits, b_bits, c_bits, BF16 if dtype == F16TF32_DTYPE_BF16 else FP16)

        actual = await run_case(dut, dtype, a_bits, b_bits, c_bits, stall_output=(index == 1))
        assert actual == expected, (
            f"directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(dtype, a_bits, b_bits, c_bits)}"
        )

    c_values = [
        fp32_bits(0.0),
        fp32_bits(1.0),
        fp32_bits(-1.0),
        fp32_bits(2.0 ** -149),
        fp32_bits(2.0 ** -126),
        float32_to_bits(65504.0),
    ]
    for index in range(NUM_CASES):
        dtype = [F16TF32_DTYPE_FP16, F16TF32_DTYPE_BF16, F16TF32_DTYPE_TF32][index % 3]
        if dtype == F16TF32_DTYPE_TF32:
            a_vec = [random_tf32_bits(rng) for _ in range(8)]
            b_vec = [random_tf32_bits(rng) for _ in range(8)]
            c_bits = random_tf32_bits(rng)
            if (c_bits & 0x7F800000) == 0x7F800000:
                c_bits = fp32_bits(rng.uniform(-32.0, 32.0))
            a_bits = pack_u32_lanes(a_vec)
            b_bits = pack_u32_lanes(b_vec)
            expected = tf32_golden(a_bits, b_bits, c_bits)
        elif dtype == F16TF32_DTYPE_BF16:
            a_vec = random_bf16_vec(rng)
            b_vec = random_bf16_vec(rng)
            c_bits = rng.choice(c_values + [fp32_bits(rng.uniform(-32.0, 32.0))])
            a_bits = pack_u16_lanes(a_vec)
            b_bits = pack_u16_lanes(b_vec)
            expected = fp16_golden(a_bits, b_bits, c_bits, BF16)
        else:
            a_vec = random_fp16_vec(rng)
            b_vec = random_fp16_vec(rng)
            c_bits = rng.choice(c_values + [fp32_bits(rng.uniform(-32.0, 32.0))])
            a_bits = pack_u16_lanes(a_vec)
            b_bits = pack_u16_lanes(b_vec)
            expected = fp16_golden(a_bits, b_bits, c_bits, FP16)

        actual = await run_case(dut, dtype, a_bits, b_bits, c_bits)
        assert actual == expected, (
            f"random case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(dtype, a_bits, b_bits, c_bits)}"
        )
