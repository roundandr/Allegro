from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from mma_sim_tcgen05_ref import (
    KIND_CODE,
    OP_CODE,
    SCALE_CODE,
    SCALE_VEC_CODE,
    TCGEN05_KIND_F16,
    TCGEN05_KIND_TF32,
    TCGEN05_OP_MMA,
    TCGEN05_OP_SP,
    TCGEN05_SCALE_NONE,
    TCGEN05_SCALE_VEC_NONE,
    TCGEN05_STATUS_INVALID_SPARSE_META,
    TCGEN05_STATUS_OK,
    TCGEN05_STATUS_UNSUPPORTED,
    TYPE_CODE,
    Tcgen05AdapterGolden,
    adapter_supported,
    float32_to_bits,
    load_inventory,
    random_scalar_case_for_entry,
    scalar_case_for_entry,
)


NUM_CASES = int(os.getenv("NUM_CASES", "1"))
NUM_RANDOM_PER_COMBO = int(os.getenv("NUM_RANDOM_PER_COMBO", os.getenv("NUM_CASES", "1")))
RANDOM_SEED = int(os.getenv("RANDOM_SEED", os.getenv("COCOTB_RANDOM_SEED", "20260521")))
EXPECTED_INVENTORY_ROWS = int(os.getenv("EXPECTED_TCGEN05_ROWS", "592"))
EXPECTED_ADAPTER_ROWS = int(os.getenv("EXPECTED_TCGEN05_ADAPTER_ROWS", "592"))


async def reset_dut(dut) -> None:
    dut.in_vld_i.value = 0
    dut.tag_i.value = 0
    dut.out_rdy_i.value = 1
    dut.op_i.value = TCGEN05_OP_MMA
    dut.kind_i.value = TCGEN05_KIND_TF32
    dut.d_type_i.value = TYPE_CODE["f32"]
    dut.a_type_i.value = TYPE_CODE["tf32"]
    dut.b_type_i.value = TYPE_CODE["tf32"]
    dut.scale_type_i.value = TCGEN05_SCALE_NONE
    dut.scale_vec_i.value = TCGEN05_SCALE_VEC_NONE
    dut.cta_group_i.value = 0
    dut.enable_input_d_i.value = 1
    dut.scale_input_d_i.value = 0
    dut.a_vec_i.value = 0
    dut.b_vec_i.value = 0
    dut.sparse_meta_i.value = 0
    dut.c_i.value = 0
    dut.a_sf_i.value = 0
    dut.b_sf_i.value = 0

    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def run_case(
    dut,
    entry: dict,
    a_bits: int,
    b_bits: int,
    c_bits: int,
    sparse_meta: int,
    a_sf: int,
    b_sf: int,
    enable_input_d: int = 1,
    scale_input_d: int = 0,
    stall_output: bool = False,
) -> tuple[int, int]:
    while not int(dut.in_rdy_o.value):
        await RisingEdge(dut.clk)

    dut.op_i.value = OP_CODE[entry["opcode_family"]]
    dut.kind_i.value = KIND_CODE[entry["kind"]]
    dut.d_type_i.value = TYPE_CODE[entry["d_type"]]
    dut.a_type_i.value = TYPE_CODE[entry["a_type"]]
    dut.b_type_i.value = TYPE_CODE[entry["b_type"]]
    dut.scale_type_i.value = SCALE_CODE[entry["scale_type"]]
    dut.scale_vec_i.value = SCALE_VEC_CODE[entry["scale_vector"]]
    dut.cta_group_i.value = 1 if entry["cta_group"] == 2 else 0
    dut.enable_input_d_i.value = enable_input_d
    dut.scale_input_d_i.value = scale_input_d
    dut.a_vec_i.value = a_bits
    dut.b_vec_i.value = b_bits
    dut.sparse_meta_i.value = sparse_meta
    dut.c_i.value = c_bits
    dut.a_sf_i.value = a_sf
    dut.b_sf_i.value = b_sf
    dut.in_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.in_vld_i.value = 0

    if stall_output:
        dut.out_rdy_i.value = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
        dut.out_rdy_i.value = 1

    watchdog = 200
    while not int(dut.out_vld_o.value):
        await RisingEdge(dut.clk)
        watchdog -= 1
        assert watchdog > 0, f"timeout waiting for {entry}"

    result = int(dut.d_o.value)
    status = int(dut.status_o.value)
    await RisingEdge(dut.clk)
    return result, status


def case_id(entry: dict) -> str:
    return (
        f"{entry['opcode_family']} kind={entry['kind']} cta={entry['cta_group']} "
        f"d={entry['d_type']} a={entry['a_type']} b={entry['b_type']} "
        f"scale={entry['scale_type']}/{entry['scale_vector']} k={entry['k']}"
    )


@cocotb.test()
async def tcgen05_inventory_manifest_is_complete(dut):
    inventory = load_inventory()
    supported = [entry for entry in inventory if adapter_supported(entry)]
    unsupported = [entry for entry in inventory if not adapter_supported(entry)]

    assert len(inventory) == EXPECTED_INVENTORY_ROWS, (
        f"TCGen05 inventory row count changed: got {len(inventory)}, "
        f"expected {EXPECTED_INVENTORY_ROWS}"
    )
    assert len(supported) == EXPECTED_ADAPTER_ROWS, (
        f"TCGen05 adapter-supported row count changed: got {len(supported)}, "
        f"expected {EXPECTED_ADAPTER_ROWS}"
    )
    assert len(unsupported) == EXPECTED_INVENTORY_ROWS - EXPECTED_ADAPTER_ROWS, (
        f"unsupported row count changed: got {len(unsupported)}, "
        f"expected {EXPECTED_INVENTORY_ROWS - EXPECTED_ADAPTER_ROWS}"
    )

    families = {entry["opcode_family"] for entry in inventory}
    kinds = {entry["kind"] for entry in inventory}
    assert {"mma", "sp", "ws", "ws.sp", "block_scale", "sp.block_scale"} <= families
    assert {"f16", "tf32", "f8f6f4", "i8", "mxf8f6f4", "mxf4", "mxf4nvf4"} <= kinds


@cocotb.test()
async def tcgen05_all_inventory_rows_classified_by_adapter(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    inventory = load_inventory()
    golden = Tcgen05AdapterGolden()
    ok_count = 0
    unsupported_count = 0

    for index, entry in enumerate(inventory):
        a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf = scalar_case_for_entry(entry, index)
        expected = golden(entry, a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf)
        actual = await run_case(
            dut,
            entry,
            a_bits,
            b_bits,
            c_bits,
            sparse_meta,
            a_sf,
            b_sf,
            stall_output=(index == 1),
        )
        assert actual == expected, (
            f"inventory classification mismatch for row {index} {case_id(entry)}: "
            f"got {actual}, expected {expected}"
        )
        ok_count += int(actual[1] == TCGEN05_STATUS_OK)
        unsupported_count += int(actual[1] == TCGEN05_STATUS_UNSUPPORTED)

    assert ok_count == EXPECTED_ADAPTER_ROWS, (
        f"OK row count changed: got {ok_count}, expected {EXPECTED_ADAPTER_ROWS}"
    )
    assert unsupported_count == EXPECTED_INVENTORY_ROWS - EXPECTED_ADAPTER_ROWS, (
        f"unsupported row count changed: got {unsupported_count}, "
        f"expected {EXPECTED_INVENTORY_ROWS - EXPECTED_ADAPTER_ROWS}"
    )


@cocotb.test()
async def tcgen05_inventory_supported_cases_match_mmasim(dut):
    required_ports = [
        "clk",
        "rst_n",
        "in_vld_i",
        "in_rdy_o",
        "op_i",
        "kind_i",
        "d_type_i",
        "a_type_i",
        "b_type_i",
        "scale_type_i",
        "scale_vec_i",
        "cta_group_i",
        "enable_input_d_i",
        "scale_input_d_i",
        "a_vec_i",
        "b_vec_i",
        "sparse_meta_i",
        "c_i",
        "a_sf_i",
        "b_sf_i",
        "out_vld_o",
        "out_rdy_i",
        "d_o",
        "status_o",
    ]
    for port in required_ports:
        assert hasattr(dut, port), f"missing DUT port: {port}"

    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)

    inventory = load_inventory()
    supported = [entry for entry in inventory if adapter_supported(entry)]
    assert supported, "generated inventory has no adapter-supported TCGen05 rows"
    golden = Tcgen05AdapterGolden()

    for index, entry in enumerate(supported):
        a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf = scalar_case_for_entry(entry, index)
        expected = golden(entry, a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf)
        actual = await run_case(
            dut,
            entry,
            a_bits,
            b_bits,
            c_bits,
            sparse_meta,
            a_sf,
            b_sf,
            stall_output=(index == 1),
        )
        assert actual == expected, (
            f"supported inventory case mismatch for {case_id(entry)}: "
            f"got {actual}, expected {expected}"
        )


@cocotb.test()
async def tcgen05_directed_modifiers_and_error_paths(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    await reset_dut(dut)
    inventory = load_inventory()
    golden = Tcgen05AdapterGolden()

    tf32_entry = next(
        entry for entry in inventory
        if entry["kind"] == "tf32" and entry["dense_or_sparse"] == "dense" and adapter_supported(entry)
    )
    a_bits, b_bits, _c_bits, sparse_meta, a_sf, b_sf = scalar_case_for_entry(tf32_entry)
    c_bits = float32_to_bits(8.0)
    expected = golden(tf32_entry, a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf, 1, 2)
    actual = await run_case(
        dut,
        tf32_entry,
        a_bits,
        b_bits,
        c_bits,
        sparse_meta,
        a_sf,
        b_sf,
        enable_input_d=1,
        scale_input_d=2,
    )
    assert actual == expected, f"scale-input-d mismatch: got {actual}, expected {expected}"

    expected = golden(tf32_entry, a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf, 0, 0)
    actual = await run_case(
        dut,
        tf32_entry,
        a_bits,
        b_bits,
        c_bits,
        sparse_meta,
        a_sf,
        b_sf,
        enable_input_d=0,
    )
    assert actual == expected, f"enable-input-d=0 mismatch: got {actual}, expected {expected}"

    sparse_entry = next(
        entry for entry in inventory
        if entry["kind"] == "f16"
        and entry["dense_or_sparse"] == "sparse"
        and entry["d_type"] == "f32"
        and entry["a_type"] == "f16"
        and adapter_supported(entry)
    )
    a_bits, b_bits, c_bits, _sparse_meta, a_sf, b_sf = scalar_case_for_entry(sparse_entry)
    actual = await run_case(
        dut,
        sparse_entry,
        a_bits,
        b_bits,
        c_bits,
        sparse_meta=0,
        a_sf=a_sf,
        b_sf=b_sf,
    )
    assert actual[1] == TCGEN05_STATUS_INVALID_SPARSE_META, (
        f"invalid sparse metadata did not fail for {case_id(sparse_entry)}: got {actual}"
    )

    illegal_entry = dict(next(
        entry for entry in inventory
        if adapter_supported(entry)
        and entry["kind"] == "mxf4nvf4"
        and entry["scale_type"] == "ue8m0"
        and entry["scale_vector"] in {"scale_vec::4X", "block16"}
    ))
    illegal_entry["d_type"] = "f16"
    illegal_entry["adapter_supported"] = False
    a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf = scalar_case_for_entry(illegal_entry)
    actual = await run_case(
        dut,
        illegal_entry,
        a_bits,
        b_bits,
        c_bits,
        sparse_meta,
        a_sf,
        b_sf,
    )
    assert actual == (0, TCGEN05_STATUS_UNSUPPORTED), (
        f"illegal non-inventory case did not report unsupported: got {actual}"
    )

    enabled = [entry for entry in inventory if adapter_supported(entry)]
    rng = random.Random(RANDOM_SEED)
    for entry_index, entry in enumerate(enabled):
        for random_index in range(NUM_RANDOM_PER_COMBO):
            case_index = entry_index * max(NUM_RANDOM_PER_COMBO, 1) + random_index
            a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf = random_scalar_case_for_entry(
                entry,
                rng,
                case_index,
            )
            expected = golden(entry, a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf)
            actual = await run_case(dut, entry, a_bits, b_bits, c_bits, sparse_meta, a_sf, b_sf)
            assert actual == expected, (
                f"random per-combo mismatch for {case_id(entry)} case={random_index}: "
                f"got {actual}, expected {expected}"
            )
