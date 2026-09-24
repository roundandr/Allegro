"""SHIFT on the physical TMEM bank drives the shared TC commit controller."""
import cocotb
from cocotb.triggers import Timer


async def tick(d):
    d.clk.value = 0
    await Timer(5, units="ns")
    names = ("ctx_rdy_o", "alloc_rdy_o", "ctrl_rsp_vld_o",
             "ctrl_rsp_status_o", "ctrl_rsp_tag_o", "ctrl_rsp_base_o",
             "shift_cmd_rdy_o", "shift_complete_vld_o", "shift_done_vld_o",
             "shift_done_status_o", "bar_vld_o", "bar_opcode_o", "bar_tag_o",
             "bar_issuer_o", "bar_addr_o", "bar_arrive_count_o",
             "bar_rsp_rdy_o", "commit_rdy_o", "event_vld_o",
             "event_status_o", "event_tag_o", "event_issuer_o",
             "event_phase_o", "protocol_error_o", "sw_bar_rdy_o",
             "sw_bar_rsp_vld_o", "sw_bar_rsp_tag_o", "sw_bar_rsp_status_o",
             "sw_bar_rsp_phase_o", "sw_bar_rsp_wait_complete_o",
             "backing_write_vld_o", "backing_read_vld_o",
             "backing_rsp_pending_o")
    before = {n: int(getattr(d, n).value) for n in names}
    d.clk.value = 1
    await Timer(5, units="ns")
    return before


async def control(d, kind, tag, **values):
    for name, value in values.items():
        getattr(d, name).value = value
    getattr(d, f"{kind}_tag_i").value = tag
    getattr(d, f"{kind}_vld_i").value = 1
    for _ in range(20):
        got = await tick(d)
        if got[f"{kind}_rdy_o"]:
            break
    else:
        raise AssertionError(f"{kind} not accepted")
    getattr(d, f"{kind}_vld_i").value = 0
    got = await tick(d)
    assert got["ctrl_rsp_vld_o"] and got["ctrl_rsp_status_o"] == 0
    assert got["ctrl_rsp_tag_o"] == tag
    return got


async def shift(d, issuer, tag, base):
    d.shift_cmd_ctx_i.value = 0
    d.shift_cmd_epoch_i.value = 7
    d.shift_cmd_base_addr_i.value = base
    d.shift_cmd_tag_i.value = tag
    d.shift_cmd_issuer_i.value = issuer
    d.shift_cmd_warp_i.value = issuer // 32
    d.shift_cmd_seq_i.value = tag
    d.shift_cmd_vld_i.value = 1
    for _ in range(20):
        if (await tick(d))["shift_cmd_rdy_o"]:
            break
    else:
        raise AssertionError("SHIFT not registered")
    d.shift_cmd_vld_i.value = 0


async def commit(d, issuer, tag, barrier):
    d.commit_issuer_i.value = issuer
    d.commit_warp_i.value = issuer // 32
    d.commit_tag_i.value = tag
    d.commit_seq_i.value = tag
    d.commit_epoch_i.value = 7
    d.commit_barrier_i.value = barrier
    d.commit_vld_i.value = 1
    for _ in range(20):
        if (await tick(d))["commit_rdy_o"]:
            break
    else:
        raise AssertionError("COMMIT not accepted")
    d.commit_vld_i.value = 0


async def arrival_and_ack(d, tag, issuer, barrier, opcode, status, phase=1,
                          wait_for_data=False):
    saw_completion = not wait_for_data
    for _ in range(300):
        got = await tick(d)
        if got["shift_complete_vld_o"]:
            saw_completion = True
        if got["bar_vld_o"]:
            assert saw_completion, "mbarrier arrival preceded TMEM bank completion"
            assert got["bar_opcode_o"] == opcode
            assert got["bar_tag_o"] == tag
            assert got["bar_issuer_o"] == issuer
            assert got["bar_addr_o"] == barrier
            assert got["bar_arrive_count_o"] == 1
            break
    else:
        raise AssertionError("COMMIT did not reach mbarrier")
    for _ in range(3):
        held = await tick(d)
        assert held["bar_vld_o"] and held["bar_tag_o"] == tag
        assert held["bar_addr_o"] == barrier
    d.bar_rdy_i.value = 1
    assert (await tick(d))["bar_vld_o"]
    d.bar_rdy_i.value = 0
    d.bar_rsp_tag_i.value = tag
    d.bar_rsp_issuer_i.value = issuer
    d.bar_rsp_status_i.value = 0
    d.bar_rsp_phase_i.value = phase
    d.bar_rsp_vld_i.value = 1
    for _ in range(10):
        if (await tick(d))["bar_rsp_rdy_o"]:
            break
    else:
        raise AssertionError("barrier response not accepted")
    d.bar_rsp_vld_i.value = 0
    for _ in range(10):
        got = await tick(d)
        if got["event_vld_o"]:
            assert got["event_tag_o"] == tag
            assert got["event_issuer_o"] == issuer
            assert got["event_status_o"] == status
            assert got["event_phase_o"] == phase
            assert not got["protocol_error_o"]
            return
    raise AssertionError("TC commit event missing")


@cocotb.test()
async def real_shift_commit_snapshot_empty_repeat_and_fault(d):
    d.clk.value = 0
    d.rst_n.value = 0
    for name in ("ctx_vld_i", "alloc_vld_i", "shift_cmd_vld_i",
                 "commit_vld_i", "bar_rsp_vld_i"):
        getattr(d, name).value = 0
    for name in ("ctx_create_i", "ctx_id_i", "ctx_epoch_i", "ctx_tag_i",
                 "alloc_ctx_i", "alloc_epoch_i", "alloc_columns_i", "alloc_tag_i",
                 "shift_cmd_ctx_i", "shift_cmd_epoch_i", "shift_cmd_base_addr_i",
                 "shift_cmd_tag_i", "shift_cmd_issuer_i", "shift_cmd_warp_i",
                 "shift_cmd_seq_i", "commit_issuer_i", "commit_warp_i",
                 "commit_tag_i", "commit_seq_i", "commit_epoch_i",
                 "commit_barrier_i", "bar_rsp_tag_i", "bar_rsp_issuer_i",
                 "bar_rsp_status_i", "bar_rsp_phase_i"):
        getattr(d, name).value = 0
    d.ctrl_rsp_rdy_i.value = 1
    d.shift_done_rdy_i.value = 0
    d.bar_rdy_i.value = 0
    d.event_rdy_i.value = 1
    for _ in range(3):
        await tick(d)
    d.rst_n.value = 1
    await control(d, "ctx", 1, ctx_create_i=1, ctx_id_i=0, ctx_epoch_i=7)
    got = await control(d, "alloc", 2, alloc_ctx_i=0, alloc_epoch_i=7,
                        alloc_columns_i=512)
    assert got["ctrl_rsp_base_o"] == 0

    await shift(d, issuer=5, tag=11, base=0)
    await commit(d, issuer=5, tag=12, barrier=0x100)
    await arrival_and_ack(d, 12, 5, 0x100, opcode=1, status=0,
                          wait_for_data=True)
    assert int(d.shift_done_vld_o.value), "TMEM command completion lost"
    d.shift_done_rdy_i.value = 1
    await tick(d)
    d.shift_done_rdy_i.value = 0

    # No new data work: each commit still produces its own arrival(1).
    for tag in (13, 14):
        await commit(d, issuer=5, tag=tag, barrier=0x100)
        await arrival_and_ack(d, tag, 5, 0x100, opcode=1, status=0)

    # A failed SHIFT reports a TC fault, never a successful arrival.
    await shift(d, issuer=6, tag=20, base=505)
    await commit(d, issuer=6, tag=21, barrier=0x200)
    await arrival_and_ack(d, 21, 6, 0x200, opcode=28, status=2,
                          wait_for_data=True)
    assert int(d.shift_done_vld_o.value)
    assert int(d.shift_done_status_o.value) == 5
    d.shift_done_rdy_i.value = 1
    await tick(d)
    d.shift_done_rdy_i.value = 0
    assert not int(d.protocol_error_o.value)
    d._log.info("Real TMEM SHIFT -> TC commit snapshots -> mbarrier arrival/fault passed")
