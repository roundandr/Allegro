import random
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer


async def reset(dut):
    dut.clk.value = 0
    dut.rst_n.value = 0
    dut.rd_vld_i.value = 0
    dut.rsp_rdy_i.value = 0
    dut.row_wr_vld_i.value = 0
    dut.row_wr_mask_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def row_word(seed):
    return sum(((seed + lane) & 0xFFFFFFFF) << (32 * lane) for lane in range(8))


def drive_reads(dut, slot, row, cols):
    dut.rd_vld_i.value = (1 << len(cols)) - 1
    dut.rd_slot_i.value = sum(slot << idx for idx in range(len(cols)))
    dut.rd_row_i.value = sum(row << (6 * idx) for idx in range(len(cols)))
    dut.rd_col_i.value = sum(col << (3 * idx) for idx, col in enumerate(cols))
    dut.rd_tag_i.value = sum(idx << (4 * idx) for idx in range(len(cols)))


@cocotb.test()
async def mapping_slots_and_stable_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    for slot, row, seed in [(0, 3, 0x100), (1, 3, 0x200), (0, 63, 0x300)]:
        dut.row_wr_slot_i.value = slot
        dut.row_wr_row_i.value = row
        dut.row_wr_data_i.value = row_word(seed)
        dut.row_wr_mask_i.value = 0xFF
        dut.row_wr_vld_i.value = 1
        while True:
            await RisingEdge(dut.clk)
            if int(dut.row_wr_rdy_o.value):
                break
        dut.row_wr_vld_i.value = 0

    drive_reads(dut, 1, 3, list(range(8)))
    dut.rsp_rdy_i.value = 0
    while True:
        await RisingEdge(dut.clk)
        if int(dut.rd_rdy_o.value) == 0xFF:
            break
    dut.rd_vld_i.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.rsp_vld_o.value) == 0xFF
    held_data = int(dut.rsp_data_o.value)
    held_tag = int(dut.rsp_tag_o.value)
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.rsp_vld_o.value) == 0xFF
        assert int(dut.rsp_data_o.value) == held_data
        assert int(dut.rsp_tag_o.value) == held_tag
    assert held_data == row_word(0x200)

    await RisingEdge(dut.clk)
    dut.rsp_rdy_i.value = 0xFF
    await RisingEdge(dut.clk)


@cocotb.test()
async def deterministic_same_bank_conflict(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    dut.rsp_rdy_i.value = 0xFF
    # Ports 0 and 1 both request bank 0. Baseline 1R1W grants one; 2R1W grants
    # both and is separately compiled by the remote regression script.
    drive_reads(dut, 0, 0, [0, 0])
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.rd_rdy_o.value) & 0x1
    if int(os.environ.get("TMEM_TEST_PORT_MODE", "0")) == 2:
        assert int(dut.rd_rdy_o.value) & 0x2
        assert not (int(dut.rd_conflict_o.value) & 0x2)
    else:
        assert not (int(dut.rd_rdy_o.value) & 0x2)
        assert int(dut.rd_conflict_o.value) & 0x2


@cocotb.test()
async def simultaneous_read_write_port_semantics(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    mode = int(os.environ.get("TMEM_TEST_PORT_MODE", "0"))
    dut.rsp_rdy_i.value = 0xFF

    # Initialize row 5, then request a read while replacing the same row.
    dut.row_wr_slot_i.value = 0
    dut.row_wr_row_i.value = 5
    dut.row_wr_data_i.value = row_word(0x400)
    dut.row_wr_mask_i.value = 0xFF
    dut.row_wr_vld_i.value = 1
    await RisingEdge(dut.clk)
    dut.row_wr_vld_i.value = 0

    drive_reads(dut, 0, 5, [0])
    dut.row_wr_data_i.value = row_word(0x500)
    dut.row_wr_vld_i.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    if mode == 1:
        assert not (int(dut.rd_rdy_o.value) & 0x1)
        assert int(dut.rd_conflict_o.value) & 0x1
    else:
        assert int(dut.rd_rdy_o.value) & 0x1

    # In shared 1RW mode the blocked read must be accepted after the write.
    await Timer(1, units="ps")
    dut.row_wr_vld_i.value = 0
    if mode == 1:
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.rd_rdy_o.value) & 0x1
        await Timer(1, units="ps")
    dut.rd_vld_i.value = 0
