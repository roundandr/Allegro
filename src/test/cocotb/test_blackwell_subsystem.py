import random
import struct
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


TMA_REQ, MMA, COMMIT, WAIT, STORE, MBARRIER_WAIT = range(6)
A_BASE, B_BASE, DST0, DST1 = 0x1000, 0x3000, 0x8000, 0xA000


def pack_fp16(values):
    word = 0
    for idx, value in enumerate(values):
        bits = int(np.asarray(value, dtype=np.float16).view(np.uint16))
        word |= bits << (16 * idx)
    return word


def fp32_bits(value):
    return struct.unpack("<I", struct.pack("<f", np.float32(value)))[0]


async def drive_after_edge(signal, value):
    await Timer(1, units="ps")
    signal.value = value


async def smem_model(dut, memory, rng):
    a_pending = None
    b_pending = None
    wr_pending = None
    a_rsp = None
    b_rsp = None
    wr_rsp = None
    while True:
        await RisingEdge(dut.clk)

        a_rsp_fire = int(dut.smem_a_rsp_vld_i.value) and int(dut.smem_a_rsp_rdy_o.value)
        b_rsp_fire = int(dut.smem_b_rsp_vld_i.value) and int(dut.smem_b_rsp_rdy_o.value)
        wr_rsp_fire = int(dut.smem_wr_rsp_vld_i.value) and int(dut.smem_wr_rsp_rdy_o.value)
        a_req_fire = int(dut.smem_a_req_vld_o.value) and int(dut.smem_a_req_rdy_i.value)
        b_req_fire = int(dut.smem_b_req_vld_o.value) and int(dut.smem_b_req_rdy_i.value)
        wr_req_fire = int(dut.smem_wr_req_vld_o.value) and int(dut.smem_wr_req_rdy_i.value)

        if a_rsp_fire:
            a_rsp = None
        if b_rsp_fire:
            b_rsp = None
        if wr_rsp_fire:
            wr_rsp = None
        if a_req_fire:
            a_pending = (int(dut.smem_a_req_addr_o.value),
                         int(dut.smem_a_req_source_o.value), rng.randint(0, 2))
        if b_req_fire:
            b_pending = (int(dut.smem_b_req_addr_o.value),
                         int(dut.smem_b_req_source_o.value), rng.randint(0, 2))
        if wr_req_fire:
            addr = int(dut.smem_wr_req_addr_o.value)
            data = int(dut.smem_wr_req_data_o.value)
            mask = int(dut.smem_wr_req_mask_o.value)
            old = memory.get(addr, 0)
            merged = old
            for byte in range(32):
                if (mask >> byte) & 1:
                    merged &= ~(0xFF << (8 * byte))
                    merged |= ((data >> (8 * byte)) & 0xFF) << (8 * byte)
            memory[addr] = merged
            wr_pending = (int(dut.smem_wr_req_source_o.value), rng.randint(0, 2))

        if a_pending:
            addr, source, delay = a_pending
            if delay == 0 and a_rsp is None:
                a_rsp = (memory[addr], source)
                a_pending = None
            else:
                a_pending = (addr, source, max(delay - 1, 0))
        if b_pending:
            addr, source, delay = b_pending
            if delay == 0 and b_rsp is None:
                b_rsp = (memory[addr], source)
                b_pending = None
            else:
                b_pending = (addr, source, max(delay - 1, 0))
        if wr_pending:
            source, delay = wr_pending
            if delay == 0 and wr_rsp is None:
                wr_rsp = source
                wr_pending = None
            else:
                wr_pending = (source, max(delay - 1, 0))

        await Timer(1, units="ps")
        dut.smem_a_req_rdy_i.value = 1 if rng.random() > 0.15 else 0
        dut.smem_b_req_rdy_i.value = 1 if rng.random() > 0.15 else 0
        dut.smem_wr_req_rdy_i.value = 1 if rng.random() > 0.15 else 0
        dut.smem_a_rsp_vld_i.value = int(a_rsp is not None)
        dut.smem_a_rsp_data_i.value = a_rsp[0] if a_rsp else 0
        dut.smem_a_rsp_source_i.value = a_rsp[1] if a_rsp else 0
        dut.smem_a_rsp_status_i.value = 0
        dut.smem_b_rsp_vld_i.value = int(b_rsp is not None)
        dut.smem_b_rsp_data_i.value = b_rsp[0] if b_rsp else 0
        dut.smem_b_rsp_source_i.value = b_rsp[1] if b_rsp else 0
        dut.smem_b_rsp_status_i.value = 0
        dut.smem_wr_rsp_vld_i.value = int(wr_rsp is not None)
        dut.smem_wr_rsp_source_i.value = wr_rsp if wr_rsp is not None else 0
        dut.smem_wr_rsp_status_i.value = 0


async def issue(dut, opcode, tag, *, a=0, b=0, dst=0, slot=0,
                accumulate=0, barrier=0, phase=0, token=0, timeout=20000):
    dut.cmd_opcode_i.value = opcode
    dut.cmd_tag_i.value = tag
    dut.cmd_a_base_i.value = a
    dut.cmd_b_base_i.value = b
    dut.cmd_dst_base_i.value = dst
    dut.cmd_tile_slot_i.value = slot
    dut.cmd_accumulate_i.value = accumulate
    dut.cmd_barrier_id_i.value = barrier
    dut.cmd_barrier_phase_i.value = phase
    dut.cmd_wait_token_i.value = token
    dut.cmd_vld_i.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.cmd_rdy_o.value):
            break
    else:
        raise AssertionError("command handshake timeout")
    await Timer(1, units="ps")
    dut.cmd_vld_i.value = 0

    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.completion_vld_o.value):
            result = (int(dut.completion_tag_o.value),
                      int(dut.completion_opcode_o.value),
                      int(dut.completion_status_o.value),
                      int(dut.completion_token_o.value))
            assert result[0] == tag and result[1] == opcode and result[2] == 0, result
            return result
    raise AssertionError("completion timeout")


async def reset(dut):
    dut.rst_n.value = 0
    dut.cmd_vld_i.value = 0
    dut.completion_rdy_i.value = 1
    dut.smem_a_req_rdy_i.value = 0
    dut.smem_b_req_rdy_i.value = 0
    dut.smem_wr_req_rdy_i.value = 0
    dut.smem_a_rsp_vld_i.value = 0
    dut.smem_b_rsp_vld_i.value = 0
    dut.smem_wr_rsp_vld_i.value = 0
    dut.tma_req_rdy_i.value = 1
    dut.tma_done_vld_i.value = 0
    dut.perf_clear_i.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def expected_row(scale=1):
    return sum(fp32_bits(16.0 * (lane + 1) * scale) << (32 * lane)
               for lane in range(8))


@cocotb.test()
async def full_tile_overwrite_accumulate_slots_sync(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    memory = {}
    ones = pack_fp16([1.0] * 16)
    for row in range(64):
        memory[A_BASE + 32 * row] = ones
    for col in range(8):
        memory[B_BASE + 32 * col] = pack_fp16([float(col + 1)] * 16)
    cocotb.start_soon(smem_model(dut, memory, random.Random(20260813)))

    await issue(dut, MMA, 0x10, a=A_BASE, b=B_BASE, slot=0)
    await issue(dut, STORE, 0x11, dst=DST0, slot=0)
    for row in range(64):
        assert memory[DST0 + 32 * row] == expected_row(1), row

    await issue(dut, MMA, 0x12, a=A_BASE, b=B_BASE, slot=0, accumulate=1)
    commit = await issue(dut, COMMIT, 0x13)
    await issue(dut, WAIT, 0x14, token=commit[3])
    await issue(dut, STORE, 0x15, dst=DST1, slot=0)
    for row in range(64):
        assert memory[DST1 + 32 * row] == expected_row(2), row

    # Independent second tile slot must not alias slot zero.
    await issue(dut, MMA, 0x16, a=A_BASE, b=B_BASE, slot=1)
    await issue(dut, STORE, 0x17, dst=DST0, slot=1)
    for row in range(64):
        assert memory[DST0 + 32 * row] == expected_row(1), row

    # TMA proxy completion updates the barrier phase and retires its token.
    tma = await issue(dut, TMA_REQ, 0x20, a=0x100000, dst=0x200000,
                      barrier=3, phase=1)
    await Timer(1, units="ps")
    dut.tma_done_tag_i.value = 0x20
    dut.tma_done_barrier_id_i.value = 3
    dut.tma_done_phase_i.value = 1
    dut.tma_done_status_i.value = 0
    dut.tma_done_vld_i.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    dut.tma_done_vld_i.value = 0
    await issue(dut, MBARRIER_WAIT, 0x21, barrier=3, phase=1)
    await issue(dut, WAIT, 0x22, token=tma[3])

    assert int(dut.perf_issued_o.value) >= 11
    assert int(dut.perf_completed_o.value) >= 10
    assert int(dut.perf_smem_stall_o.value) > 0
