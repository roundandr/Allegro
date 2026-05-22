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


NUM_CASES = int(os.getenv("NUM_CASES", "20000"))
RANDOM_SEED = int(os.getenv("RANDOM_SEED", os.getenv("COCOTB_RANDOM_SEED", "20260428")))


def fp32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def fmt_name(fmt_is_bf16: int) -> str:
    return "BF16" if fmt_is_bf16 else "FP16"


def mode_code(fmt_is_bf16: int) -> int:
    return 1 if fmt_is_bf16 else 2


def case_dump(
    a_bits: int,
    b_bits: int,
    c_bits: int,
    a_fmt_is_bf16: int,
    b_fmt_is_bf16: int,
    scale_input_d: int = 0,
) -> str:
    return (
        f"a_fmt={fmt_name(a_fmt_is_bf16)}, "
        f"b_fmt={fmt_name(b_fmt_is_bf16)}, "
        f"a_vec_i=0x{a_bits:064x}, "
        f"b_vec_i=0x{b_bits:064x}, "
        f"c_i=0x{c_bits:08x}, "
        f"scale_input_d_i={scale_input_d}"
    )


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 1
    dut.a_mode_i.value = 2
    dut.b_mode_i.value = 2
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
    a_fmt_is_bf16: int,
    b_fmt_is_bf16: int,
    scale_input_d: int = 0,
) -> int:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    dut.a_vec_i.value = a_bits
    dut.b_vec_i.value = b_bits
    dut.c_i.value = c_bits
    dut.scale_input_d_i.value = scale_input_d
    dut.a_mode_i.value = mode_code(a_fmt_is_bf16)
    dut.b_mode_i.value = mode_code(b_fmt_is_bf16)
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0

    while not int(dut.out_vld_o.value):
        await RisingEdge(dut.clk)

    result = int(dut.d_o.value)
    await RisingEdge(dut.clk)
    return result


def random_fp16_vec(rng: random.Random) -> list[int]:
    finite_normals = [
        0x0000, 0x8000, 0x0001, 0x03FF, 0x0400, 0x3C00, 0xBC00,
        0x4000, 0xC000, 0x3555, 0xB555, 0x7BFF, 0xFBFF,
    ]
    return [rng.choice(finite_normals + [rng.randrange(0x0000, 0x7C00)]) for _ in range(16)]


def random_bf16_vec(rng: random.Random) -> list[int]:
    finite_normals = [
        0x0000, 0x8000, 0x0001, 0x007F, 0x0080, 0x3F80, 0xBF80,
        0x4000, 0xC000, 0x3EAB, 0xBEAB, 0x7F7F, 0xFF7F,
    ]
    return [rng.choice(finite_normals + [rng.randrange(0x0000, 0x7F80)]) for _ in range(16)]


@cocotb.test()
async def fp16_bf16_dot_matches_mmasim(dut):
    required_ports = [
        "clk",
        "rst_n",
        "in_vld_i",
        "in_rdy_o",
        "a_mode_i",
        "b_mode_i",
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
    golden = FP16DotMmaSimGolden()

    directed_cases = [
        (FP16, [0x0000] * 16, [0x0000] * 16, fp32_bits(0.0)),
        (FP16, [0x3C00] * 16, [0x3C00] * 16, fp32_bits(0.0)),
        (FP16, [0x3C00, 0xBC00] * 8, [0x3C00] * 16, fp32_bits(0.0)),
        (FP16, [0x0001] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, fp32_bits(0.0)),
        (FP16, [0x0000] + [0x0000] * 15, [0x7C00] + [0x0000] * 15, fp32_bits(0.0)),
        (FP16, [0x7C00] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, fp32_bits(0.0)),
        (FP16, [0xFC00] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, fp32_bits(0.0)),
        (FP16, [0x7C00] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, 0xFF800000),
        (FP16, [0x7C00, 0xFC00] + [0x0000] * 14, [0x3C00] * 16, fp32_bits(0.0)),
        (FP16, [0x7E01] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, fp32_bits(0.0)),
        (FP16, [0x0001] + [0x0000] * 15, [0x0001] + [0x0000] * 15, fp32_bits(0.0)),
        (FP16, [0x3C00] * 16, [0x3C00] * 16, 0x7FC00001),
        (BF16, [0x0000] * 16, [0x0000] * 16, fp32_bits(0.0)),
        (BF16, [0x3F80] * 16, [0x3F80] * 16, fp32_bits(0.0)),
        (BF16, [0x3F80, 0xBF80] * 8, [0x3F80] * 16, fp32_bits(0.0)),
        (BF16, [0x0001] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(0.0)),
        (BF16, [0x0000] + [0x0000] * 15, [0x7F80] + [0x0000] * 15, fp32_bits(0.0)),
        (BF16, [0x7F80] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(0.0)),
        (BF16, [0xFF80] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(0.0)),
        (BF16, [0x7F80] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, 0xFF800000),
        (BF16, [0x7F80, 0xFF80] + [0x0000] * 14, [0x3F80] * 16, fp32_bits(0.0)),
        (BF16, [0x7FC1] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(0.0)),
        (BF16, [0x7F7F] * 16, [0x7F7F] * 16, fp32_bits(0.0)),
        (BF16, [0x0001] + [0x0000] * 15, [0x0001] + [0x0000] * 15, fp32_bits(0.0)),
        (BF16, [0x3F80] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(2.0 ** -149)),
    ]

    for index, (fmt_is_bf16, a_vec, b_vec, c_bits) in enumerate(directed_cases):
        a_fmt_is_bf16 = fmt_is_bf16
        b_fmt_is_bf16 = fmt_is_bf16
        a_bits = pack_u16_lanes(a_vec)
        b_bits = pack_u16_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)
        actual = await run_case(dut, a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)
        assert actual == expected, (
            f"directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)}"
        )

    mixed_directed_cases = [
        (FP16, BF16, [0x3C00, 0xBC00] * 8, [0x3F80] * 16, fp32_bits(0.0)),
        (BF16, FP16, [0x3F80, 0xBF80] * 8, [0x3C00] * 16, fp32_bits(0.0)),
        (FP16, BF16, [0x7C00] + [0x0000] * 15, [0x3F80] + [0x0000] * 15, fp32_bits(0.0)),
        (BF16, FP16, [0x7FC1] + [0x0000] * 15, [0x3C00] + [0x0000] * 15, fp32_bits(0.0)),
    ]
    for index, (a_fmt_is_bf16, b_fmt_is_bf16, a_vec, b_vec, c_bits) in enumerate(mixed_directed_cases):
        a_bits = pack_u16_lanes(a_vec)
        b_bits = pack_u16_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)
        actual = await run_case(dut, a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)
        assert actual == expected, (
            f"mixed directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)}"
        )

    scale_a_fmt = FP16
    scale_b_fmt = BF16
    a_bits = pack_u16_lanes([0x0000] * 16)
    b_bits = pack_u16_lanes([0x0000] * 16)
    c_bits = fp32_bits(8.0)
    scale_input_d = 2
    expected = golden(a_bits, b_bits, fp32_bits(2.0), scale_a_fmt, scale_b_fmt)
    actual = await run_case(
        dut,
        a_bits,
        b_bits,
        c_bits,
        scale_a_fmt,
        scale_b_fmt,
        scale_input_d=scale_input_d,
    )
    assert actual == expected, (
        f"scale-input-d mixed case mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
        f"{case_dump(a_bits, b_bits, c_bits, scale_a_fmt, scale_b_fmt, scale_input_d)}"
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
        combo = [(FP16, FP16), (BF16, BF16), (FP16, BF16), (BF16, FP16)][index % 4]
        a_fmt_is_bf16, b_fmt_is_bf16 = combo
        if a_fmt_is_bf16:
            a_vec = random_bf16_vec(rng)
        else:
            a_vec = random_fp16_vec(rng)
        if b_fmt_is_bf16:
            b_vec = random_bf16_vec(rng)
        else:
            b_vec = random_fp16_vec(rng)

        c_bits = rng.choice(c_values + [fp32_bits(rng.uniform(-32.0, 32.0))])
        a_bits = pack_u16_lanes(a_vec)
        b_bits = pack_u16_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)
        actual = await run_case(dut, a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)
        assert actual == expected, (
            f"random case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits, a_fmt_is_bf16, b_fmt_is_bf16)}"
        )
