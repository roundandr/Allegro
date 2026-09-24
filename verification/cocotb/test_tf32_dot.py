from __future__ import annotations

import os
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from mma_sim_tf32_ref import TF32DotMmaSimGolden, float32_to_bits, pack_u32_lanes


NUM_CASES = int(os.getenv("NUM_CASES", "2000"))
RANDOM_SEED = int(os.getenv("RANDOM_SEED", os.getenv("COCOTB_RANDOM_SEED", "20260429")))


def fp32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def case_dump(a_bits: int, b_bits: int, c_bits: int, scale_input_d: int = 0) -> str:
    return (
        f"a_vec_i=0x{a_bits:064x}, "
        f"b_vec_i=0x{b_bits:064x}, "
        f"c_i=0x{c_bits:08x}, "
        f"scale_input_d_i={scale_input_d}"
    )


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 1
    dut.a_dtype_i.value = 0
    dut.b_dtype_i.value = 0
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
    a_bits: int,
    b_bits: int,
    c_bits: int,
    stall_output: bool = False,
    scale_input_d: int = 0,
) -> int:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    dut.a_vec_i.value = a_bits
    dut.b_vec_i.value = b_bits
    dut.c_i.value = c_bits
    dut.scale_input_d_i.value = scale_input_d
    dut.a_dtype_i.value = 0
    dut.b_dtype_i.value = 0
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


def random_fp32_bits(rng: random.Random) -> int:
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
    return float32_to_bits(rng.uniform(-32.0, 32.0))


@cocotb.test()
async def tf32_dot_matches_mmasim(dut):
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

    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(RANDOM_SEED)
    golden = TF32DotMmaSimGolden()

    directed_cases = [
        ([0x00000000] * 8, [0x00000000] * 8, fp32_bits(0.0)),
        ([0x3F800001] + [0x00000000] * 7, [0x3F800001] + [0x00000000] * 7, fp32_bits(0.0)),
        ([0x3F800000, 0xBF800000] * 4, [0x3F800000] * 8, fp32_bits(0.0)),
        ([0x00002000] + [0x00000000] * 7, [0x3F800000] + [0x00000000] * 7, fp32_bits(0.0)),
        ([0x00002000] + [0x00000000] * 7, [0x00002000] + [0x00000000] * 7, fp32_bits(0.0)),
        ([0x7F800000] + [0x00000000] * 7, [0x3F800000] + [0x00000000] * 7, fp32_bits(0.0)),
        ([0xFF800000] + [0x00000000] * 7, [0x3F800000] + [0x00000000] * 7, fp32_bits(0.0)),
        ([0x00000000] + [0x00000000] * 7, [0x7F800000] + [0x00000000] * 7, fp32_bits(0.0)),
        ([0x7F800000, 0xFF800000] + [0x00000000] * 6, [0x3F800000] * 8, fp32_bits(0.0)),
        ([0x7FC00001] + [0x00000000] * 7, [0x3F800000] + [0x00000000] * 7, fp32_bits(0.0)),
        ([0x3F800000] * 8, [0x3F800000] * 8, 0x7FC00001),
        ([0x3F800000] * 8, [0x3F800000] * 8, 0x7F800000),
        ([0x3F800000] * 8, [0x3F800000] * 8, 0xFF800000),
        ([0x7F7FE000] * 8, [0x7F7FE000] * 8, fp32_bits(0.0)),
        ([0x00000000] * 8, [0x00000000] * 8, 0x00000001),
    ]

    for index, (a_vec, b_vec, c_bits) in enumerate(directed_cases):
        a_bits = pack_u32_lanes(a_vec)
        b_bits = pack_u32_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits)
        actual = await run_case(dut, a_bits, b_bits, c_bits, stall_output=(index == 1))
        assert actual == expected, (
            f"directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits)}"
        )

    a_bits = pack_u32_lanes([0x00000000] * 8)
    b_bits = pack_u32_lanes([0x00000000] * 8)
    c_bits = fp32_bits(8.0)
    scale_input_d = 2
    expected = golden(a_bits, b_bits, fp32_bits(2.0))
    actual = await run_case(dut, a_bits, b_bits, c_bits, scale_input_d=scale_input_d)
    assert actual == expected, (
        f"scale-input-d case mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
        f"{case_dump(a_bits, b_bits, c_bits, scale_input_d)}"
    )

    for index in range(NUM_CASES):
        a_vec = [random_fp32_bits(rng) for _ in range(8)]
        b_vec = [random_fp32_bits(rng) for _ in range(8)]
        c_bits = random_fp32_bits(rng)
        if (c_bits & 0x7F800000) == 0x7F800000:
            c_bits = fp32_bits(rng.uniform(-32.0, 32.0))
        a_bits = pack_u32_lanes(a_vec)
        b_bits = pack_u32_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits)
        actual = await run_case(dut, a_bits, b_bits, c_bits)
        assert actual == expected, (
            f"random case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits)}"
        )
