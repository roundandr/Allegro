from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


NUM_CASES = int(os.getenv("NUM_CASES", "2000"))
RANDOM_SEED = int(os.getenv("RANDOM_SEED", os.getenv("COCOTB_RANDOM_SEED", "20260429")))


def pack_u8_lanes(values: list[int]) -> int:
    word = 0
    for index, value in enumerate(values):
        word |= (value & 0xFF) << (8 * index)
    return word


def int32_signed(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def int8_value(raw: int, is_unsigned: int) -> int:
    raw &= 0xFF
    if is_unsigned:
        return raw
    return raw - 0x100 if raw & 0x80 else raw


def int8_dot_ref(
    a_vec: list[int],
    b_vec: list[int],
    c_bits: int,
    a_unsigned: int,
    b_unsigned: int,
    sat_en: int,
) -> tuple[int, int]:
    acc = int32_signed(c_bits)
    for a_raw, b_raw in zip(a_vec, b_vec):
        acc += int8_value(a_raw, a_unsigned) * int8_value(b_raw, b_unsigned)

    overflow = int(acc > 0x7FFFFFFF or acc < -0x80000000)
    if sat_en and acc > 0x7FFFFFFF:
        return 0x7FFFFFFF, overflow
    if sat_en and acc < -0x80000000:
        return 0x80000000, overflow
    return acc & 0xFFFFFFFF, overflow


def case_dump(
    a_vec: list[int],
    b_vec: list[int],
    c_bits: int,
    a_unsigned: int,
    b_unsigned: int,
    sat_en: int,
) -> str:
    return (
        f"a_unsigned={a_unsigned}, b_unsigned={b_unsigned}, sat_en={sat_en}, "
        f"a_vec={a_vec}, b_vec={b_vec}, c_i=0x{c_bits:08x}"
    )


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 1
    dut.a_vec_i.value = 0
    dut.b_vec_i.value = 0
    dut.c_i.value = 0
    dut.a_unsigned_i.value = 0
    dut.b_unsigned_i.value = 0
    dut.sat_en_i.value = 0

    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def run_case(
    dut,
    a_vec: list[int],
    b_vec: list[int],
    c_bits: int,
    a_unsigned: int,
    b_unsigned: int,
    sat_en: int,
    stall_output: bool = False,
) -> tuple[int, int]:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    dut.a_vec_i.value = pack_u8_lanes(a_vec)
    dut.b_vec_i.value = pack_u8_lanes(b_vec)
    dut.c_i.value = c_bits
    dut.a_unsigned_i.value = a_unsigned
    dut.b_unsigned_i.value = b_unsigned
    dut.sat_en_i.value = sat_en
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
    overflow = int(dut.overflow_o.value)
    await RisingEdge(dut.clk)
    return result, overflow


@cocotb.test()
async def int8_dot_matches_integer_golden(dut):
    required_ports = [
        "clk",
        "rst_n",
        "in_vld_i",
        "in_rdy_o",
        "a_vec_i",
        "b_vec_i",
        "c_i",
        "a_unsigned_i",
        "b_unsigned_i",
        "sat_en_i",
        "out_vld_o",
        "out_rdy_i",
        "d_o",
        "overflow_o",
    ]
    for port in required_ports:
        assert hasattr(dut, port), f"missing DUT port: {port}"

    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset_dut(dut)

    directed_cases = [
        ([0] * 32, [0] * 32, 0x00000000, 0, 0, 0),
        ([1] * 32, [1] * 32, 0x00000000, 0, 0, 0),
        ([0xFF] * 32, [1] * 32, 0x00000000, 0, 0, 0),
        ([0xFF] * 32, [1] * 32, 0x00000000, 1, 0, 0),
        ([0x80] * 32, [0x80] * 32, 0x00000000, 0, 0, 0),
        ([0xFF] * 32, [0xFF] * 32, 0x00000000, 1, 1, 0),
        ([0xFF] * 32, [0xFF] * 32, 0x7FF00000, 1, 1, 0),
        ([0xFF] * 32, [0xFF] * 32, 0x7FF00000, 1, 1, 1),
        ([0x80] * 32, [0x7F] * 32, 0x80010000, 0, 0, 0),
        ([0x80] * 32, [0x7F] * 32, 0x80010000, 0, 0, 1),
        ([0x01, 0x7F, 0x80, 0xFF] * 8, [0xFF, 0x80, 0x7F, 0x01] * 8, 0x12345678, 0, 1, 0),
    ]

    for index, (a_vec, b_vec, c_bits, a_unsigned, b_unsigned, sat_en) in enumerate(directed_cases):
        expected = int8_dot_ref(a_vec, b_vec, c_bits, a_unsigned, b_unsigned, sat_en)
        actual = await run_case(
            dut,
            a_vec,
            b_vec,
            c_bits,
            a_unsigned,
            b_unsigned,
            sat_en,
            stall_output=(index == 1),
        )
        assert actual == expected, (
            f"directed case {index} mismatch: got {actual}, expected {expected}; "
            f"{case_dump(a_vec, b_vec, c_bits, a_unsigned, b_unsigned, sat_en)}"
        )

    rng = random.Random(RANDOM_SEED)
    for index in range(NUM_CASES):
        a_vec = [rng.randrange(256) for _ in range(32)]
        b_vec = [rng.randrange(256) for _ in range(32)]
        c_bits = rng.randrange(0x100000000)
        a_unsigned = rng.randrange(2)
        b_unsigned = rng.randrange(2)
        sat_en = rng.randrange(2)
        expected = int8_dot_ref(a_vec, b_vec, c_bits, a_unsigned, b_unsigned, sat_en)
        actual = await run_case(dut, a_vec, b_vec, c_bits, a_unsigned, b_unsigned, sat_en)
        assert actual == expected, (
            f"random case {index} mismatch: got {actual}, expected {expected}; "
            f"{case_dump(a_vec, b_vec, c_bits, a_unsigned, b_unsigned, sat_en)}"
        )
