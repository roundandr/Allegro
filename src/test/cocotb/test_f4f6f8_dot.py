from __future__ import annotations

import os
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from mma_sim_f4f6f8_ref import (
    F4F6F8DotMmaSimGolden,
    F4F6F8_TYPE_E2M1,
    F4F6F8_TYPE_E2M3,
    F4F6F8_TYPE_E3M2,
    F4F6F8_TYPE_E4M3,
    F4F6F8_TYPE_E5M2,
    FP8_E4M3,
    FP8_E5M2,
    FP6_E2M3,
    FP6_E3M2,
    E8M0_BIAS,
    pack_u4_lanes,
    pack_u8_lanes,
    pack_u6_lanes,
)


NUM_CASES = int(os.getenv("NUM_CASES", "20000"))
MIXED_NUM_CASES = int(os.getenv("MIXED_NUM_CASES", str(NUM_CASES)))
RANDOM_SEED = int(os.getenv("RANDOM_SEED", os.getenv("COCOTB_RANDOM_SEED", "20260422")))
E4M3_VALUES = list(range(256))
E5M2_VALUES = list(range(256))
FP6_VALUES = list(range(64))
FP4_VALUES = list(range(16))
F4F6F8_TYPES = [F4F6F8_TYPE_E4M3, F4F6F8_TYPE_E5M2, F4F6F8_TYPE_E2M3, F4F6F8_TYPE_E3M2, F4F6F8_TYPE_E2M1]


def fp32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def random_fp8_vec(rng: random.Random, fp8_format: int) -> list[int]:
    values = E4M3_VALUES if fp8_format == FP8_E4M3 else E5M2_VALUES
    return [rng.choice(values) for _ in range(32)]


def random_fp6_vec(rng: random.Random) -> list[int]:
    return [rng.choice(FP6_VALUES) for _ in range(32)]


def type_name(value_type: int) -> str:
    return {
        F4F6F8_TYPE_E4M3: "E4M3",
        F4F6F8_TYPE_E5M2: "E5M2",
        F4F6F8_TYPE_E2M3: "E2M3",
        F4F6F8_TYPE_E3M2: "E3M2",
        F4F6F8_TYPE_E2M1: "E2M1",
    }[value_type]


def legacy_type(fp8_format: int, fp6_en: int = 0, fp6_format: int = FP6_E2M3) -> int:
    if fp6_en:
        return F4F6F8_TYPE_E3M2 if fp6_format == FP6_E3M2 else F4F6F8_TYPE_E2M3
    return F4F6F8_TYPE_E5M2 if fp8_format == FP8_E5M2 else F4F6F8_TYPE_E4M3


def random_vec_by_type(rng: random.Random, value_type: int) -> list[int]:
    if value_type == F4F6F8_TYPE_E4M3:
        return random_fp8_vec(rng, FP8_E4M3)
    if value_type == F4F6F8_TYPE_E5M2:
        return random_fp8_vec(rng, FP8_E5M2)
    if value_type == F4F6F8_TYPE_E2M1:
        return [rng.choice(FP4_VALUES) for _ in range(32)]
    return random_fp6_vec(rng)


def pack_by_type(values: list[int], value_type: int) -> int:
    if value_type == F4F6F8_TYPE_E2M1:
        return pack_u4_lanes(values)
    if value_type in {F4F6F8_TYPE_E2M3, F4F6F8_TYPE_E3M2}:
        return pack_u6_lanes(values)
    return pack_u8_lanes(values)


def one_two_by_type(value_type: int) -> tuple[int, int]:
    return {
        F4F6F8_TYPE_E4M3: (0x38, 0x40),
        F4F6F8_TYPE_E5M2: (0x3C, 0x40),
        F4F6F8_TYPE_E2M3: (0x08, 0x10),
        F4F6F8_TYPE_E3M2: (0x0C, 0x10),
        F4F6F8_TYPE_E2M1: (0x2, 0x4),
    }[value_type]


def case_dump(
    a_bits: int,
    b_bits: int,
    c_bits: int,
    fp8_format: int,
    mxfp8_en: int = 0,
    a_mx_scale: int = E8M0_BIAS,
    b_mx_scale: int = E8M0_BIAS,
    fp6_en: int = 0,
    fp6_format: int = FP6_E2M3,
) -> str:
    if fp6_en:
        fmt = "E3M2" if fp6_format == FP6_E3M2 else "E2M3"
    else:
        fmt = "E4M3" if fp8_format == FP8_E4M3 else "E5M2"
    return (
        f"fmt={fmt}, "
        f"mx_en={mxfp8_en}, "
        f"a_mx_scale=0x{a_mx_scale:02x}, "
        f"b_mx_scale=0x{b_mx_scale:02x}, "
        f"a_vec_i=0x{a_bits:064x}, "
        f"b_vec_i=0x{b_bits:064x}, "
        f"c_i=0x{c_bits:08x}"
    )


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 1
    dut.a_vec_i.value = 0
    dut.b_vec_i.value = 0
    dut.c_i.value = 0
    dut.a_type_i.value = F4F6F8_TYPE_E4M3
    dut.b_type_i.value = F4F6F8_TYPE_E4M3
    dut.mxfp8_en_i.value = 0
    dut.a_mx_scale_i.value = E8M0_BIAS
    dut.b_mx_scale_i.value = E8M0_BIAS

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
    fp8_format: int,
    mxfp8_en: int = 0,
    a_mx_scale: int = E8M0_BIAS,
    b_mx_scale: int = E8M0_BIAS,
    fp6_en: int = 0,
    fp6_format: int = FP6_E2M3,
    a_type: int | None = None,
    b_type: int | None = None,
) -> int:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    if a_type is None:
        a_type = legacy_type(fp8_format, fp6_en, fp6_format)
    if b_type is None:
        b_type = a_type

    dut.a_vec_i.value = a_bits
    dut.b_vec_i.value = b_bits
    dut.c_i.value = c_bits
    dut.a_type_i.value = a_type
    dut.b_type_i.value = b_type
    dut.mxfp8_en_i.value = mxfp8_en
    dut.a_mx_scale_i.value = a_mx_scale
    dut.b_mx_scale_i.value = b_mx_scale
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0

    while not int(dut.out_vld_o.value):
        await RisingEdge(dut.clk)

    result = int(dut.d_o.value)
    await RisingEdge(dut.clk)
    return result


@cocotb.test()
async def f4f6f8_dot_matches_mmasim(dut):
    required_ports = [
        "clk",
        "rst_n",
        "in_vld_i",
        "in_rdy_o",
        "a_vec_i",
        "b_vec_i",
        "c_i",
        "a_type_i",
        "b_type_i",
        "mxfp8_en_i",
        "a_mx_scale_i",
        "b_mx_scale_i",
        "out_vld_o",
        "out_rdy_i",
        "d_o",
    ]
    for port in required_ports:
        assert hasattr(dut, port), f"missing DUT port: {port}"

    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(RANDOM_SEED)
    golden = F4F6F8DotMmaSimGolden()

    directed_cases = [
        (FP8_E4M3, [0x00] * 32, [0x00] * 32, fp32_bits(0.0)),
        (FP8_E4M3, [0x38] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0)),
        (FP8_E4M3, [0x7F] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0)),
        (FP8_E4M3, [0x38] * 32, [0x38] * 32, 0x7F800000),
        (FP8_E4M3, [0x38] * 32, [0x38] * 32, 0xFF800000),
        (FP8_E4M3, [0x38] * 32, [0x38] * 32, 0x7FC00001),
        (FP8_E4M3, [0x00] * 32, [0x00] * 32, 0x00000001),
        (FP8_E5M2, [0x00] * 32, [0x00] * 32, fp32_bits(0.0)),
        (FP8_E5M2, [0x3C] + [0x00] * 31, [0x3C] + [0x00] * 31, fp32_bits(0.0)),
        (FP8_E5M2, [0x7D] + [0x00] * 31, [0x3C] + [0x00] * 31, fp32_bits(0.0)),
        (FP8_E5M2, [0x00] + [0x00] * 31, [0x7C] + [0x00] * 31, fp32_bits(0.0)),
        (FP8_E5M2, [0x7C] + [0x00] * 31, [0xBC] + [0x00] * 31, fp32_bits(0.0)),
        (FP8_E5M2, [0x7C] + [0x00] * 31, [0x3C] + [0x00] * 31, 0xFF800000),
        (FP8_E5M2, [0x7C] + [0x00] * 31, [0x3C] + [0x00] * 31, 0x7F800000),
    ]

    for index, (fp8_format, a_vec, b_vec, c_bits) in enumerate(directed_cases):
        a_bits = pack_u8_lanes(a_vec)
        b_bits = pack_u8_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits, fp8_format)
        actual = await run_case(dut, a_bits, b_bits, c_bits, fp8_format)
        assert actual == expected, (
            f"directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits, fp8_format)}"
        )

    fp6_directed_cases = [
        (FP6_E2M3, [0x00] * 32, [0x00] * 32, fp32_bits(0.0)),
        (FP6_E2M3, [0x08] + [0x00] * 31, [0x08] + [0x00] * 31, fp32_bits(0.0)),
        (FP6_E2M3, [0x01] + [0x00] * 31, [0x08] + [0x00] * 31, fp32_bits(0.0)),
        (FP6_E2M3, [0x1F] * 32, [0x08] * 32, fp32_bits(1.0)),
        (FP6_E2M3, [0x28] + [0x00] * 31, [0x08] + [0x00] * 31, fp32_bits(0.0)),
        (FP6_E3M2, [0x00] * 32, [0x00] * 32, fp32_bits(0.0)),
        (FP6_E3M2, [0x0C] + [0x00] * 31, [0x0C] + [0x00] * 31, fp32_bits(0.0)),
        (FP6_E3M2, [0x01] + [0x00] * 31, [0x0C] + [0x00] * 31, fp32_bits(0.0)),
        (FP6_E3M2, [0x1F] * 32, [0x0C] * 32, fp32_bits(1.0)),
        (FP6_E3M2, [0x2C] + [0x00] * 31, [0x0C] + [0x00] * 31, fp32_bits(0.0)),
    ]

    for index, (fp6_format, a_vec, b_vec, c_bits) in enumerate(fp6_directed_cases):
        a_bits = pack_u6_lanes(a_vec)
        b_bits = pack_u6_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits, FP8_E4M3, fp6_en=1, fp6_format=fp6_format)
        actual = await run_case(dut, a_bits, b_bits, c_bits, FP8_E4M3, fp6_en=1, fp6_format=fp6_format)
        assert actual == expected, (
            f"FP6 directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits, FP8_E4M3, fp6_en=1, fp6_format=fp6_format)}"
        )

    mx_directed_cases = [
        (FP8_E4M3, [0x38] * 32, [0x38] * 32, fp32_bits(0.0), E8M0_BIAS, E8M0_BIAS),
        (FP8_E4M3, [0x38] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0), 128, 127),
        (FP8_E4M3, [0x38] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0), 126, 127),
        (FP8_E4M3, [0x38] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0), 130, 125),
        (FP8_E4M3, [0x38] * 32, [0x38] * 32, fp32_bits(1.0), 0xFF, 127),
        (FP8_E4M3, [0x38] * 32, [0x38] * 32, fp32_bits(1.0), 127, 0xFF),
        (FP8_E4M3, [0x7F] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0), 128, 126),
        (FP8_E5M2, [0x00] * 32, [0x00] * 32, fp32_bits(3.5), 128, 126),
        (FP8_E5M2, [0x00] + [0x00] * 31, [0x7C] + [0x00] * 31, fp32_bits(0.0), 128, 126),
        (FP8_E5M2, [0x7C] + [0x00] * 31, [0x3C] + [0x00] * 31, 0xFF800000, 127, 127),
        (FP8_E5M2, [0x7C] + [0x00] * 31, [0x3C] + [0x00] * 31, 0x7F800000, 127, 127),
        (FP8_E5M2, [0x3C] * 32, [0x3C] * 32, 0x7FC00001, 127, 127),
        (FP8_E4M3, [0x7E] * 32, [0x7E] * 32, fp32_bits(0.0), 254, 254),
        (FP8_E4M3, [0x38] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0), 0, 0),
        (FP8_E4M3, [0x38] + [0x00] * 31, [0x38] + [0x00] * 31, fp32_bits(0.0), 62, 62),
        (FP8_E5M2, [0x3C] + [0x00] * 31, [0x3C] + [0x00] * 31, fp32_bits(0.0), 0, 254),
    ]

    for index, (fp8_format, a_vec, b_vec, c_bits, a_scale, b_scale) in enumerate(mx_directed_cases):
        a_bits = pack_u8_lanes(a_vec)
        b_bits = pack_u8_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits, fp8_format, 1, a_scale, b_scale)
        actual = await run_case(dut, a_bits, b_bits, c_bits, fp8_format, 1, a_scale, b_scale)
        assert actual == expected, (
            f"MX directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits, fp8_format, 1, a_scale, b_scale)}"
        )

    fp6_mx_directed_cases = [
        (FP6_E2M3, [0x08] * 32, [0x08] * 32, fp32_bits(0.0), E8M0_BIAS, E8M0_BIAS),
        (FP6_E2M3, [0x08] + [0x00] * 31, [0x08] + [0x00] * 31, fp32_bits(0.0), 128, 127),
        (FP6_E2M3, [0x01] + [0x00] * 31, [0x08] + [0x00] * 31, fp32_bits(0.0), 126, 127),
        (FP6_E2M3, [0x1F] * 32, [0x1F] * 32, fp32_bits(0.0), 254, 254),
        (FP6_E3M2, [0x0C] * 32, [0x0C] * 32, fp32_bits(0.0), E8M0_BIAS, E8M0_BIAS),
        (FP6_E3M2, [0x0C] + [0x00] * 31, [0x0C] + [0x00] * 31, fp32_bits(0.0), 128, 127),
        (FP6_E3M2, [0x01] + [0x00] * 31, [0x0C] + [0x00] * 31, fp32_bits(0.0), 126, 127),
        (FP6_E3M2, [0x1F] * 32, [0x1F] * 32, fp32_bits(0.0), 254, 254),
        (FP6_E3M2, [0x0C] * 32, [0x0C] * 32, 0x7FC00001, 127, 127),
        (FP6_E2M3, [0x08] + [0x00] * 31, [0x08] + [0x00] * 31, fp32_bits(0.0), 0xFF, 127),
    ]

    for index, (fp6_format, a_vec, b_vec, c_bits, a_scale, b_scale) in enumerate(fp6_mx_directed_cases):
        a_bits = pack_u6_lanes(a_vec)
        b_bits = pack_u6_lanes(b_vec)
        expected = golden(a_bits, b_bits, c_bits, FP8_E4M3, 1, a_scale, b_scale, 1, fp6_format)
        actual = await run_case(dut, a_bits, b_bits, c_bits, FP8_E4M3, 1, a_scale, b_scale, 1, fp6_format)
        assert actual == expected, (
            f"MXFP6 directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, c_bits, FP8_E4M3, 1, a_scale, b_scale, 1, fp6_format)}"
        )

    for a_type in F4F6F8_TYPES:
        for b_type in F4F6F8_TYPES:
            a_one, _a_two = one_two_by_type(a_type)
            _b_one, b_two = one_two_by_type(b_type)
            a_bits = pack_by_type([a_one] + [0] * 31, a_type)
            b_bits = pack_by_type([b_two] + [0] * 31, b_type)
            c_bits = fp32_bits(0.0)
            expected = golden(a_bits, b_bits, c_bits, FP8_E4M3, a_type=a_type, b_type=b_type)
            actual = await run_case(dut, a_bits, b_bits, c_bits, FP8_E4M3, a_type=a_type, b_type=b_type)
            assert actual == expected, (
                f"mixed directed case a={type_name(a_type)} b={type_name(b_type)} mismatch: "
                f"got 0x{actual:08x}, expected 0x{expected:08x}"
            )

            expected = golden(
                a_bits,
                b_bits,
                c_bits,
                FP8_E4M3,
                mxfp8_en=1,
                a_mx_scale=E8M0_BIAS,
                b_mx_scale=E8M0_BIAS,
                a_type=a_type,
                b_type=b_type,
            )
            actual = await run_case(
                dut,
                a_bits,
                b_bits,
                c_bits,
                FP8_E4M3,
                mxfp8_en=1,
                a_mx_scale=E8M0_BIAS,
                b_mx_scale=E8M0_BIAS,
                a_type=a_type,
                b_type=b_type,
            )
            assert actual == expected, (
                f"mixed MX directed case a={type_name(a_type)} b={type_name(b_type)} mismatch: "
                f"got 0x{actual:08x}, expected 0x{expected:08x}"
            )

    for fp8_format in [FP8_E4M3, FP8_E5M2]:
        for index in range(NUM_CASES):
            a_bits = pack_u8_lanes(random_fp8_vec(rng, fp8_format))
            b_bits = pack_u8_lanes(random_fp8_vec(rng, fp8_format))
            c_bits = fp32_bits(rng.uniform(-32.0, 32.0))
            expected = golden(a_bits, b_bits, c_bits, fp8_format)
            actual = await run_case(dut, a_bits, b_bits, c_bits, fp8_format)
            assert actual == expected, (
                f"random case fmt={fp8_format} idx={index} mismatch: "
                f"got 0x{actual:08x}, expected 0x{expected:08x}; "
                f"{case_dump(a_bits, b_bits, c_bits, fp8_format)}"
            )

    for fp6_format in [FP6_E2M3, FP6_E3M2]:
        for index in range(NUM_CASES):
            a_bits = pack_u6_lanes(random_fp6_vec(rng))
            b_bits = pack_u6_lanes(random_fp6_vec(rng))
            c_bits = fp32_bits(rng.uniform(-32.0, 32.0))
            expected = golden(a_bits, b_bits, c_bits, FP8_E4M3, fp6_en=1, fp6_format=fp6_format)
            actual = await run_case(dut, a_bits, b_bits, c_bits, FP8_E4M3, fp6_en=1, fp6_format=fp6_format)
            assert actual == expected, (
                f"FP6 random case fmt={fp6_format} idx={index} mismatch: "
                f"got 0x{actual:08x}, expected 0x{expected:08x}; "
                f"{case_dump(a_bits, b_bits, c_bits, FP8_E4M3, fp6_en=1, fp6_format=fp6_format)}"
            )

    mx_scale_values = [0, 1, 2, 63, 64, 96, 120, 126, 127, 128, 134, 160, 192, 252, 253, 254, 0xFF]
    for fp8_format in [FP8_E4M3, FP8_E5M2]:
        for index in range(NUM_CASES):
            a_bits = pack_u8_lanes(random_fp8_vec(rng, fp8_format))
            b_bits = pack_u8_lanes(random_fp8_vec(rng, fp8_format))
            c_bits = fp32_bits(rng.uniform(-32.0, 32.0))
            a_scale = rng.choice(mx_scale_values)
            b_scale = rng.choice(mx_scale_values)
            expected = golden(a_bits, b_bits, c_bits, fp8_format, 1, a_scale, b_scale)
            actual = await run_case(dut, a_bits, b_bits, c_bits, fp8_format, 1, a_scale, b_scale)
            assert actual == expected, (
                f"MX random case fmt={fp8_format} idx={index} mismatch: "
                f"got 0x{actual:08x}, expected 0x{expected:08x}; "
                f"{case_dump(a_bits, b_bits, c_bits, fp8_format, 1, a_scale, b_scale)}"
            )

    for fp6_format in [FP6_E2M3, FP6_E3M2]:
        for index in range(NUM_CASES):
            a_bits = pack_u6_lanes(random_fp6_vec(rng))
            b_bits = pack_u6_lanes(random_fp6_vec(rng))
            c_bits = fp32_bits(rng.uniform(-32.0, 32.0))
            a_scale = rng.choice(mx_scale_values)
            b_scale = rng.choice(mx_scale_values)
            expected = golden(a_bits, b_bits, c_bits, FP8_E4M3, 1, a_scale, b_scale, 1, fp6_format)
            actual = await run_case(dut, a_bits, b_bits, c_bits, FP8_E4M3, 1, a_scale, b_scale, 1, fp6_format)
            assert actual == expected, (
                f"MXFP6 random case fmt={fp6_format} idx={index} mismatch: "
                f"got 0x{actual:08x}, expected 0x{expected:08x}; "
                f"{case_dump(a_bits, b_bits, c_bits, FP8_E4M3, 1, a_scale, b_scale, 1, fp6_format)}"
            )

    for a_type in F4F6F8_TYPES:
        for b_type in F4F6F8_TYPES:
            for index in range(MIXED_NUM_CASES):
                a_bits = pack_by_type(random_vec_by_type(rng, a_type), a_type)
                b_bits = pack_by_type(random_vec_by_type(rng, b_type), b_type)
                c_bits = fp32_bits(rng.uniform(-32.0, 32.0))
                expected = golden(a_bits, b_bits, c_bits, FP8_E4M3, a_type=a_type, b_type=b_type)
                actual = await run_case(dut, a_bits, b_bits, c_bits, FP8_E4M3, a_type=a_type, b_type=b_type)
                assert actual == expected, (
                    f"mixed random case a={type_name(a_type)} b={type_name(b_type)} idx={index} mismatch: "
                    f"got 0x{actual:08x}, expected 0x{expected:08x}; "
                    f"a_vec_i=0x{a_bits:064x}, b_vec_i=0x{b_bits:064x}, c_i=0x{c_bits:08x}"
                )

                a_scale = rng.choice(mx_scale_values)
                b_scale = rng.choice(mx_scale_values)
                expected = golden(
                    a_bits,
                    b_bits,
                    c_bits,
                    FP8_E4M3,
                    1,
                    a_scale,
                    b_scale,
                    a_type=a_type,
                    b_type=b_type,
                )
                actual = await run_case(
                    dut,
                    a_bits,
                    b_bits,
                    c_bits,
                    FP8_E4M3,
                    1,
                    a_scale,
                    b_scale,
                    a_type=a_type,
                    b_type=b_type,
                )
                assert actual == expected, (
                    f"mixed MX random case a={type_name(a_type)} b={type_name(b_type)} idx={index} mismatch: "
                    f"got 0x{actual:08x}, expected 0x{expected:08x}; "
                    f"a_mx_scale=0x{a_scale:02x}, b_mx_scale=0x{b_scale:02x}, "
                    f"a_vec_i=0x{a_bits:064x}, b_vec_i=0x{b_bits:064x}, c_i=0x{c_bits:08x}"
                )
