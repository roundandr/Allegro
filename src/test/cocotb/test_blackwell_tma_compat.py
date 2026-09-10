import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


TMA_REQ = 0
MBARRIER_WAIT = 5


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
    dut.tma_cmd_vld_i.value = 0
    dut.tma_rsp_rdy_i.value = 1
    dut.bar_cmd_vld_i.value = 0
    dut.bar_rsp_rdy_i.value = 1
    dut.gmem_req_rdy_i.value = 0
    dut.gmem_rsp_vld_i.value = 0
    dut.tma_smem_req_rdy_i.value = 0
    dut.tma_smem_rsp_vld_i.value = 0
    dut.perf_clear_i.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    dut.rst_n.value = 1


async def memory_model(dut, gmem, smem):
    g_pending = []
    s_pending = []
    g_rsp = None
    s_rsp = None
    while True:
        await RisingEdge(dut.clk)
        if int(dut.gmem_rsp_vld_i.value) and int(dut.gmem_rsp_rdy_o.value):
            g_rsp = None
        if int(dut.tma_smem_rsp_vld_i.value) and int(dut.tma_smem_rsp_rdy_o.value):
            s_rsp = None
        if int(dut.gmem_req_vld_o.value) and int(dut.gmem_req_rdy_i.value):
            address = int(dut.gmem_req_addr_o.value)
            req_id = int(dut.gmem_req_id_o.value)
            assert not int(dut.gmem_req_write_o.value)
            data = sum(gmem.get(address + byte, 0) << (8 * byte)
                       for byte in range(128))
            g_pending.append((req_id, data))
        if int(dut.tma_smem_req_vld_o.value) and int(dut.tma_smem_req_rdy_i.value):
            address = int(dut.tma_smem_req_addr_o.value)
            req_id = int(dut.tma_smem_req_id_o.value)
            assert int(dut.tma_smem_req_write_o.value)
            data = int(dut.tma_smem_req_data_o.value)
            mask = int(dut.tma_smem_req_mask_o.value)
            for byte in range(32):
                if (mask >> byte) & 1:
                    smem[address + byte] = (data >> (8 * byte)) & 0xFF
            s_pending.append(req_id)
        if g_rsp is None and g_pending:
            g_rsp = g_pending.pop(0)
        if s_rsp is None and s_pending:
            s_rsp = s_pending.pop(0)
        await Timer(1, units="ps")
        dut.gmem_req_rdy_i.value = 1
        dut.tma_smem_req_rdy_i.value = 1
        dut.gmem_rsp_vld_i.value = int(g_rsp is not None)
        dut.gmem_rsp_id_i.value = g_rsp[0] if g_rsp else 0
        dut.gmem_rsp_data_i.value = g_rsp[1] if g_rsp else 0
        dut.gmem_rsp_status_i.value = 0
        dut.tma_smem_rsp_vld_i.value = int(s_rsp is not None)
        dut.tma_smem_rsp_id_i.value = s_rsp if s_rsp is not None else 0
        dut.tma_smem_rsp_data_i.value = 0
        dut.tma_smem_rsp_status_i.value = 0


async def issue(dut, opcode, tag, *, source=0, destination=0,
                barrier=0, phase=0, timeout=20000):
    dut.cmd_opcode_i.value = opcode
    dut.cmd_tag_i.value = tag
    dut.cmd_a_base_i.value = source
    dut.cmd_b_base_i.value = 0
    dut.cmd_dst_base_i.value = destination
    dut.cmd_tile_slot_i.value = 0
    dut.cmd_accumulate_i.value = 0
    dut.cmd_barrier_id_i.value = barrier
    dut.cmd_barrier_phase_i.value = phase
    dut.cmd_wait_token_i.value = 0
    dut.cmd_vld_i.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.cmd_rdy_o.value):
            break
    else:
        raise AssertionError("legacy command handshake timeout")
    await Timer(1, units="ps")
    dut.cmd_vld_i.value = 0
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.completion_vld_o.value):
            result = (
                int(dut.completion_tag_o.value),
                int(dut.completion_opcode_o.value),
                int(dut.completion_status_o.value),
            )
            assert result == (tag, opcode, 0)
            return
    raise AssertionError("legacy completion timeout")


@cocotb.test()
async def legacy_tma_request_performs_real_copy(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    gmem = {}
    smem = {}
    source = bytes((index * 13 + 5) & 0xFF for index in range(256))
    for index, value in enumerate(source):
        gmem[0x12000 + index] = value
    cocotb.start_soon(memory_model(dut, gmem, smem))

    await issue(
        dut, TMA_REQ, 0x90, source=0x12000, destination=0x22000,
        barrier=3, phase=1
    )
    # The old command completion represents issue; barrier wait observes the
    # reconstructed tma_done only after all eight SMEM beats acknowledge.
    await issue(dut, MBARRIER_WAIT, 0x91, barrier=3, phase=1)
    copied = bytes(smem.get(0x22000 + index, 0) for index in range(256))
    assert copied == source
