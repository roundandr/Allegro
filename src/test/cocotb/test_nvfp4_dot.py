from __future__ import annotations

import os
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from mma_sim_nvfp4_ref import (
    FP4_MODE_FP4,
    FP4_MODE_MXFP4,
    FP4_MODE_MXFP4_4X,
    FP4_MODE_NVFP4,
    NVFP4DotMmaSimGolden,
    pack_fp4_lanes,
    pack_u8_lanes,
)


NUM_CASES = int(os.getenv("NUM_CASES", "200"))
RANDOM_SEED = int(os.getenv("RANDOM_SEED", "20260422"))
LEGAL_UE4M3 = [x for x in range(0x80) if ((x >> 3) & 0xF) != 0xF or (x & 0x7) == 0]


def fp32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def rand_fp4_vec(rng: random.Random) -> list[int]:
    return [rng.randrange(16) for _ in range(64)]


def rand_ue4m3_vec(rng: random.Random) -> list[int]:
    return [rng.choice(LEGAL_UE4M3) for _ in range(4)]


def rand_e8m0_vec(rng: random.Random, lanes: int = 2) -> list[int]:
    return [rng.randrange(0xFF) for _ in range(lanes)]


def alternating_fp4_vec(pos: int, neg: int) -> list[int]:
    return [pos if (lane % 2) == 0 else neg for lane in range(64)]


def unpack_fp4_bits(word: int) -> list[int]:
    return [(word >> (4 * lane)) & 0xF for lane in range(64)]


def unpack_u8_bits(word: int) -> list[int]:
    return [(word >> (8 * lane)) & 0xFF for lane in range(4)]


def case_dump(
    a_bits: int,
    b_bits: int,
    a_sf_bits: int,
    b_sf_bits: int,
    c_bits: int,
    fp4_mode: int = FP4_MODE_NVFP4,
) -> str:
    return (
        f"fp4_mode_i={fp4_mode}, "
        f"a_fp4_i=0x{a_bits:064x}, "
        f"b_fp4_i=0x{b_bits:064x}, "
        f"a_sf_i=0x{a_sf_bits:08x}, "
        f"b_sf_i=0x{b_sf_bits:08x}, "
        f"c_fp32_i=0x{c_bits:08x}"
    )


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 1
    dut.a_fp4_i.value = 0
    dut.b_fp4_i.value = 0
    dut.fp4_mode_i.value = FP4_MODE_NVFP4
    dut.a_sf_i.value = 0
    dut.b_sf_i.value = 0
    dut.c_fp32_i.value = 0

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
    a_sf_bits: int,
    b_sf_bits: int,
    c_bits: int,
    fp4_mode: int = FP4_MODE_NVFP4,
    out_stall_cycles: int = 0,
) -> int:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    dut.a_fp4_i.value = a_bits
    dut.b_fp4_i.value = b_bits
    dut.fp4_mode_i.value = fp4_mode
    dut.a_sf_i.value = a_sf_bits
    dut.b_sf_i.value = b_sf_bits
    dut.c_fp32_i.value = c_bits
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0

    if out_stall_cycles:
        for _ in range(2):
            await RisingEdge(dut.clk)
        dut.out_rdy_i.value = 0
        for _ in range(out_stall_cycles):
            await RisingEdge(dut.clk)
        dut.out_rdy_i.value = 1

    while not int(dut.out_vld_o.value):
        await RisingEdge(dut.clk)

    result = int(dut.d_fp32_o.value)
    await RisingEdge(dut.clk)
    return result


@cocotb.test()
async def nvfp4_dot_matches_mmasim(dut):
    required_ports = [
        "clk",
        "rst_n",
        "in_vld_i",
        "in_rdy_o",
        "a_fp4_i",
        "b_fp4_i",
        "fp4_mode_i",
        "a_sf_i",
        "b_sf_i",
        "c_fp32_i",
        "out_vld_o",
        "out_rdy_i",
        "d_fp32_o",
    ]
    for port in required_ports:
        assert hasattr(dut, port), f"missing DUT port: {port}"

    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(RANDOM_SEED)
    golden = NVFP4DotMmaSimGolden()

    directed_cases = [
        (
            [0x0] * 64,
            [0x0] * 64,
            [0x38, 0x38, 0x38, 0x38],
            [0x38, 0x38, 0x38, 0x38],
            fp32_bits(0.0),
        ),
        (
            [0x7] * 64,
            [0xF] * 64,
            [0x38, 0x30, 0x40, 0x28],
            [0x38, 0x38, 0x38, 0x38],
            fp32_bits(1.0),
        ),
        (
            [0x2, 0x3, 0x4, 0x5] * 16,
            [0x6, 0x7, 0x1, 0x2] * 16,
            [0xB8, 0xB0, 0xC0, 0xA8],
            [0xB8, 0xB8, 0xB8, 0xB8],
            fp32_bits(-2.0),
        ),
        (
            [rng.randrange(16) for _ in range(64)],
            [rng.randrange(16) for _ in range(64)],
            [0x7F, 0x38, 0x38, 0x38],
            [0x38, 0x38, 0x38, 0x38],
            fp32_bits(0.0),
        ),
        (
            [rng.randrange(16) for _ in range(64)],
            [rng.randrange(16) for _ in range(64)],
            [0x38, 0x38, 0x38, 0x38],
            [0x38, 0x38, 0x38, 0x38],
            0x7F800000,
        ),
        (
            [rng.randrange(16) for _ in range(64)],
            [rng.randrange(16) for _ in range(64)],
            [0x38, 0x38, 0x38, 0x38],
            [0x38, 0x38, 0x38, 0x38],
            0xFF800000,
        ),
        (
            [rng.randrange(16) for _ in range(64)],
            [rng.randrange(16) for _ in range(64)],
            [0x38, 0x38, 0x38, 0x38],
            [0x38, 0x38, 0x38, 0x38],
            0x7FC12345,
        ),
        (
            rand_fp4_vec(rng),
            rand_fp4_vec(rng),
            [0x38, 0x38, 0x38, 0x38],
            [0x38, 0xFF, 0x38, 0x38],
            fp32_bits(0.0),
        ),
        (
            [0x7] * 64,
            [0x7] * 64,
            [0x78, 0x78, 0x78, 0x78],
            [0x78, 0x78, 0x78, 0x78],
            fp32_bits(0.0),
        ),
        (
            [0x7] * 64,
            [0xF] * 64,
            [0x01, 0x01, 0x01, 0x01],
            [0x01, 0x01, 0x01, 0x01],
            0x00000001,
        ),
        (
            alternating_fp4_vec(0x7, 0xF),
            [0x7] * 64,
            [0x78, 0x01, 0x78, 0x01],
            [0x78, 0x78, 0x01, 0x01],
            fp32_bits(-0.0),
        ),
        (
            [0x0] * 64,
            [0x7] * 64,
            [0x00, 0x78, 0x01, 0x38],
            [0x78, 0x00, 0x38, 0x01],
            0x80800000,
        ),
        (
            unpack_fp4_bits(0xbd14f3f4e94a9dca3620e326c12759cbdbfda548cca12272cf7441caaa80c13a),
            unpack_fp4_bits(0xbb6f618880f00fa17939beedddab3b0fc0d7e1ecad666d6341b56e39bbb2daca),
            unpack_u8_bits(0x47362372),
            unpack_u8_bits(0x15291c6c),
            0x3FFC536B,
        ),
    ]

    for index, case in enumerate(directed_cases):
        a_vec, b_vec, a_sf_vec, b_sf_vec, c_bits = case
        a_bits = pack_fp4_lanes(a_vec)
        b_bits = pack_fp4_lanes(b_vec)
        a_sf_bits = pack_u8_lanes(a_sf_vec)
        b_sf_bits = pack_u8_lanes(b_sf_vec)
        expected = golden(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits)
        actual = await run_case(dut, a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits)
        assert actual == expected, (
            f"directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits)}"
        )

    a_bits = pack_fp4_lanes([0x2] * 64)
    b_bits = pack_fp4_lanes([0x2] * 64)
    a_sf_bits = pack_u8_lanes([0x7F, 0x80, 0x7E, 0x81])
    b_sf_bits = pack_u8_lanes([0x7F, 0x7F, 0x80, 0x7E])
    c_bits = fp32_bits(0.0)
    expected = golden(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, FP4_MODE_MXFP4_4X)
    actual = await run_case(dut, a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, FP4_MODE_MXFP4_4X)
    assert actual == expected, (
        f"MXFP4 4X mode mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
        f"{case_dump(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, FP4_MODE_MXFP4_4X)}"
    )

    for index in range(NUM_CASES):
        a_bits = pack_fp4_lanes(rand_fp4_vec(rng))
        b_bits = pack_fp4_lanes(rand_fp4_vec(rng))
        a_sf_bits = pack_u8_lanes(rand_ue4m3_vec(rng))
        b_sf_bits = pack_u8_lanes(rand_ue4m3_vec(rng))
        c_bits = fp32_bits(rng.uniform(-32.0, 32.0))

        expected = golden(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits)
        actual = await run_case(dut, a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits)
        assert actual == expected, (
            f"random case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits)}"
        )


@cocotb.test()
async def mxfp4_and_fp4_modes_match_golden(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(RANDOM_SEED + 1)
    golden = NVFP4DotMmaSimGolden()

    directed_cases = [
        (
            FP4_MODE_MXFP4,
            [0x2] * 64,
            [0x2] * 64,
            [0x7F, 0x7F, 0x00, 0xFE],
            [0x7F, 0x7F, 0x00, 0xFE],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_MXFP4,
            [0x2] * 32 + [0x4] * 32,
            [0x2] * 64,
            [0x80, 0x7F, 0x12, 0x34],
            [0x7F, 0x80, 0x56, 0x78],
            fp32_bits(1.0),
        ),
        (
            FP4_MODE_MXFP4,
            rand_fp4_vec(rng),
            rand_fp4_vec(rng),
            [0xFF, 0x7F, 0x00, 0x00],
            [0x7F, 0x7F, 0x00, 0x00],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_MXFP4,
            rand_fp4_vec(rng),
            rand_fp4_vec(rng),
            [0x7F, 0xFF, 0x00, 0x00],
            [0x7F, 0x7F, 0x00, 0x00],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_MXFP4,
            [0x7] * 64,
            [0x7] * 64,
            [0x00, 0xFE, 0xFF, 0xFF],
            [0x00, 0x01, 0xFF, 0xFF],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_MXFP4,
            [0x2] + [0x0] * 63,
            [0x2] + [0x0] * 63,
            [0x00, 0x00, 0xFF, 0xFF],
            [0x00, 0x00, 0xFF, 0xFF],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_MXFP4,
            [0x0] * 64,
            [0x0] * 64,
            [0x00, 0x00, 0xFF, 0xFF],
            [0x00, 0x00, 0xFF, 0xFF],
            0x00000001,
        ),
        (
            FP4_MODE_MXFP4,
            [0x2] * 32 + [0x0] * 32,
            [0x2] * 64,
            [0x80, 0x01, 0xFF, 0xFF],
            [0x80, 0xFE, 0xFF, 0xFF],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_MXFP4,
            [0x0] * 32 + [0x2] * 32,
            [0x2] * 64,
            [0xFE, 0x80, 0xFF, 0xFF],
            [0x01, 0x80, 0xFF, 0xFF],
            fp32_bits(-1.0),
        ),
        (
            FP4_MODE_MXFP4,
            rand_fp4_vec(rng),
            rand_fp4_vec(rng),
            [0x7F, 0x7F, 0xFF, 0xFF],
            [0x7F, 0x7F, 0xFF, 0xFF],
            0x7FC12345,
        ),
        (
            FP4_MODE_MXFP4,
            rand_fp4_vec(rng),
            rand_fp4_vec(rng),
            [0x7F, 0x7F, 0xFF, 0xFF],
            [0x7F, 0x7F, 0xFF, 0xFF],
            0xFF800000,
        ),
        (
            FP4_MODE_MXFP4_4X,
            [0x2] * 16 + [0x4] * 16 + [0x6] * 16 + [0x7] * 16,
            [0x2] * 64,
            [0x7F, 0x80, 0x7E, 0x81],
            [0x7F, 0x7F, 0x80, 0x7E],
            fp32_bits(1.0),
        ),
        (
            FP4_MODE_MXFP4_4X,
            rand_fp4_vec(rng),
            rand_fp4_vec(rng),
            [0x7F, 0x7F, 0xFF, 0x7F],
            [0x7F, 0x7F, 0x7F, 0x7F],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_MXFP4_4X,
            rand_fp4_vec(rng),
            rand_fp4_vec(rng),
            [0x7F, 0x7F, 0x7F, 0x7F],
            [0x7F, 0x7F, 0x7F, 0xFF],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_FP4,
            [0x2] * 64,
            [0x2] * 64,
            [0xFF, 0xFF, 0xFF, 0xFF],
            [0xFF, 0xFF, 0xFF, 0xFF],
            fp32_bits(0.0),
        ),
        (
            FP4_MODE_FP4,
            alternating_fp4_vec(0x7, 0xF),
            [0x7] * 64,
            [0x12, 0x34, 0x56, 0x78],
            [0x87, 0x65, 0x43, 0x21],
            fp32_bits(3.0),
        ),
        (
            FP4_MODE_FP4,
            [0x7] * 64,
            [0x7] * 64,
            [0xFF, 0x7F, 0xFE, 0x00],
            [0xFF, 0x7F, 0xFE, 0x00],
            0x7FC12345,
        ),
        (
            FP4_MODE_FP4,
            [0x7] * 64,
            [0xF] * 64,
            [0xFF, 0x7F, 0xFE, 0x00],
            [0xFF, 0x7F, 0xFE, 0x00],
            0xFF800000,
        ),
    ]

    for index, case in enumerate(directed_cases):
        fp4_mode, a_vec, b_vec, a_sf_vec, b_sf_vec, c_bits = case
        a_bits = pack_fp4_lanes(a_vec)
        b_bits = pack_fp4_lanes(b_vec)
        a_sf_bits = pack_u8_lanes(a_sf_vec)
        b_sf_bits = pack_u8_lanes(b_sf_vec)
        expected = golden(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)
        actual = await run_case(dut, a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)
        assert actual == expected, (
            f"mode directed case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)}"
        )

    for index in range(NUM_CASES):
        mode_choices = [FP4_MODE_MXFP4, FP4_MODE_MXFP4_4X, FP4_MODE_FP4]
        fp4_mode = mode_choices[index % len(mode_choices)]
        a_bits = pack_fp4_lanes(rand_fp4_vec(rng))
        b_bits = pack_fp4_lanes(rand_fp4_vec(rng))
        if fp4_mode == FP4_MODE_MXFP4:
            a_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng) + [rng.randrange(256), rng.randrange(256)])
            b_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng) + [rng.randrange(256), rng.randrange(256)])
        elif fp4_mode == FP4_MODE_MXFP4_4X:
            a_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng, lanes=4))
            b_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng, lanes=4))
        else:
            a_sf_bits = pack_u8_lanes([rng.randrange(256) for _ in range(4)])
            b_sf_bits = pack_u8_lanes([rng.randrange(256) for _ in range(4)])
        c_bits = fp32_bits(rng.uniform(-32.0, 32.0))

        expected = golden(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)
        actual = await run_case(dut, a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)
        assert actual == expected, (
            f"mode random case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)}"
        )


@cocotb.test()
async def fp4_pipeline_backpressure_matches_golden(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(RANDOM_SEED + 2)
    golden = NVFP4DotMmaSimGolden()

    modes = [FP4_MODE_NVFP4, FP4_MODE_MXFP4, FP4_MODE_FP4, FP4_MODE_MXFP4_4X]
    for index in range(32):
        fp4_mode = modes[index % len(modes)]
        a_bits = pack_fp4_lanes(rand_fp4_vec(rng))
        b_bits = pack_fp4_lanes(rand_fp4_vec(rng))
        if fp4_mode == FP4_MODE_MXFP4:
            a_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng) + [0xFF, rng.randrange(256)])
            b_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng) + [rng.randrange(256), 0xFF])
        elif fp4_mode == FP4_MODE_MXFP4_4X:
            a_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng, lanes=4))
            b_sf_bits = pack_u8_lanes(rand_e8m0_vec(rng, lanes=4))
        elif fp4_mode == FP4_MODE_FP4:
            a_sf_bits = pack_u8_lanes([0xFF, 0x7F, rng.randrange(256), rng.randrange(256)])
            b_sf_bits = pack_u8_lanes([0xFF, 0x7F, rng.randrange(256), rng.randrange(256)])
        else:
            a_sf_bits = pack_u8_lanes(rand_ue4m3_vec(rng))
            b_sf_bits = pack_u8_lanes(rand_ue4m3_vec(rng))
        c_bits = fp32_bits(rng.uniform(-8.0, 8.0))

        expected = golden(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)
        actual = await run_case(
            dut,
            a_bits,
            b_bits,
            a_sf_bits,
            b_sf_bits,
            c_bits,
            fp4_mode,
            out_stall_cycles=(index % 7) + 1,
        )
        assert actual == expected, (
            f"backpressure case {index} mismatch: got 0x{actual:08x}, expected 0x{expected:08x}; "
            f"{case_dump(a_bits, b_bits, a_sf_bits, b_sf_bits, c_bits, fp4_mode)}"
        )
