"""Real TMEM SHIFT and TC commit through memory-backed mbarrier and shared SRAM."""
import cocotb

from test_tmem_shift_commit import tick, control, shift, commit


async def sw_bar(d, opcode, tag, addr, count=0, phase=0,
                 require_backing_read=False):
    d.sw_bar_opcode_i.value = opcode
    d.sw_bar_tag_i.value = tag
    d.sw_bar_addr_i.value = addr
    d.sw_bar_arrive_count_i.value = count
    d.sw_bar_phase_token_i.value = phase
    d.sw_bar_vld_i.value = 1
    for _ in range(100):
        got = await tick(d)
        if got["sw_bar_rdy_o"]:
            break
    else:
        raise AssertionError("software mbarrier command not accepted")
    d.sw_bar_vld_i.value = 0
    saw_backing_read = False
    for _ in range(300):
        got = await tick(d)
        saw_backing_read |= bool(got["backing_read_vld_o"])
        if got["sw_bar_rsp_vld_o"]:
            assert got["sw_bar_rsp_tag_o"] == tag
            if require_backing_read:
                assert saw_backing_read, "evicted barrier did not reload from physical SRAM"
            return (got["sw_bar_rsp_status_o"],
                    got["sw_bar_rsp_phase_o"],
                    got["sw_bar_rsp_wait_complete_o"])
    raise AssertionError("software mbarrier response missing")


@cocotb.test()
async def physical_shift_commit_arrival_waits_for_backing_ack(d):
    d.clk.value = 0
    d.rst_n.value = 0
    for name in ("ctx_vld_i", "alloc_vld_i", "shift_cmd_vld_i",
                 "commit_vld_i", "bar_rsp_vld_i", "sw_bar_vld_i"):
        getattr(d, name).value = 0
    for name in ("ctx_create_i", "ctx_id_i", "ctx_epoch_i", "ctx_tag_i",
                 "alloc_ctx_i", "alloc_epoch_i", "alloc_columns_i", "alloc_tag_i",
                 "shift_cmd_ctx_i", "shift_cmd_epoch_i", "shift_cmd_base_addr_i",
                 "shift_cmd_tag_i", "shift_cmd_issuer_i", "shift_cmd_warp_i",
                 "shift_cmd_seq_i", "commit_issuer_i", "commit_warp_i",
                 "commit_tag_i", "commit_seq_i", "commit_epoch_i",
                 "commit_barrier_i", "bar_rsp_tag_i", "bar_rsp_issuer_i",
                 "bar_rsp_status_i", "bar_rsp_phase_i", "sw_bar_opcode_i",
                 "sw_bar_tag_i", "sw_bar_addr_i", "sw_bar_arrive_count_i",
                 "sw_bar_phase_token_i"):
        getattr(d, name).value = 0
    d.ctrl_rsp_rdy_i.value = 1
    d.shift_done_rdy_i.value = 0
    d.bar_rdy_i.value = 0
    d.event_rdy_i.value = 0
    d.sw_bar_rsp_rdy_i.value = 1
    d.backing_ack_enable_i.value = 1
    for _ in range(4):
        await tick(d)
    d.rst_n.value = 1

    assert await sw_bar(d, opcode=0, tag=1, addr=0x100, count=1) == (0, 0, 0)
    await control(d, "ctx", 2, ctx_create_i=1, ctx_id_i=0, ctx_epoch_i=7)
    alloc = await control(d, "alloc", 3, alloc_ctx_i=0, alloc_epoch_i=7,
                          alloc_columns_i=512)
    assert alloc["ctrl_rsp_base_o"] == 0

    d.backing_ack_enable_i.value = 0
    await shift(d, issuer=5, tag=11, base=0)
    await commit(d, issuer=5, tag=12, barrier=0x100)
    saw_shift_done = False
    saw_backing_write = False
    for _ in range(400):
        got = await tick(d)
        saw_shift_done |= bool(got["shift_complete_vld_o"])
        saw_backing_write |= bool(got["backing_write_vld_o"])
        assert not got["event_vld_o"], "commit completed before SRAM backing acknowledgment"
        if int(d.backing_rsp_pending_o.value):
            break
    else:
        raise AssertionError("mbarrier SRAM write response did not become pending")
    assert saw_shift_done
    assert saw_backing_write
    for _ in range(8):
        got = await tick(d)
        assert int(d.backing_rsp_pending_o.value)
        assert not got["event_vld_o"]
    d.backing_ack_enable_i.value = 1
    for _ in range(100):
        got = await tick(d)
        if got["event_vld_o"]:
            assert got["event_tag_o"] == 12
            assert got["event_status_o"] == 0
            assert got["event_phase_o"] == 1
            break
    else:
        raise AssertionError("commit event missing after SRAM acknowledgment")
    # Evict the original object from the four-entry cache. The wait must
    # recover phase 1 from the shared SRAM, not from a forwarded cache entry.
    for i in range(4):
        assert await sw_bar(d, opcode=0, tag=20+i,
                            addr=0x200+8*i, count=1) == (0, 0, 0)
    assert await sw_bar(d, opcode=4, tag=4, addr=0x100, phase=0,
                        require_backing_read=True) == (0, 1, 1)
    assert not int(d.protocol_error_o.value)
    assert not int(d.backing_protocol_error_o.value)
