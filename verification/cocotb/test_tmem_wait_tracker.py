"""Independent TMEM wait snapshot oracle: classes, epochs, errors and pressure."""
import cocotb
from cocotb.triggers import Timer


async def tick(d):
    d.clk.value = 0
    await Timer(5, units="ns")
    sample = {n: int(getattr(d, n).value) for n in (
        "op_rdy_o", "finish_rdy_o", "wait_rdy_o", "rsp_vld_o",
        "rsp_ctx_o", "rsp_epoch_o", "rsp_warp_o", "rsp_store_o",
        "rsp_tag_o", "rsp_status_o", "protocol_error_o")}
    d.clk.value = 1
    await Timer(5, units="ns")
    return sample


async def operation(d, seq, *, store=0, epoch=7, tag=None, warp=1, ctx=2):
    d.op_ctx_i.value = ctx
    d.op_epoch_i.value = epoch
    d.op_warp_i.value = warp
    d.op_store_i.value = store
    d.op_tag_i.value = seq if tag is None else tag
    d.op_seq_i.value = seq
    d.op_vld_i.value = 1
    assert (await tick(d))["op_rdy_o"]
    d.op_vld_i.value = 0


async def finish(d, seq, *, store=0, epoch=7, tag=None, status=0,
                 warp=1, ctx=2, valid=True):
    d.finish_ctx_i.value = ctx
    d.finish_epoch_i.value = epoch
    d.finish_warp_i.value = warp
    d.finish_store_i.value = store
    d.finish_tag_i.value = seq if tag is None else tag
    d.finish_seq_i.value = seq
    d.finish_status_i.value = status
    d.finish_vld_i.value = 1
    got = await tick(d)
    assert got["finish_rdy_o"]
    assert got["protocol_error_o"] == (not valid)
    d.finish_vld_i.value = 0


async def wait_request(d, tag, *, store=0, epoch=7, warp=1, ctx=2):
    d.wait_ctx_i.value = ctx
    d.wait_epoch_i.value = epoch
    d.wait_warp_i.value = warp
    d.wait_store_i.value = store
    d.wait_tag_i.value = tag
    d.wait_vld_i.value = 1
    assert (await tick(d))["wait_rdy_o"]
    d.wait_vld_i.value = 0
    d.clear_ctx_vld_i.value = 0
    d.clear_ctx_i.value = 0


async def response(d, tag, *, status=0, store=0, epoch=7, warp=1, ctx=2):
    for _ in range(40):
        got = await tick(d)
        if got["rsp_vld_o"]:
            assert (got["rsp_ctx_o"], got["rsp_epoch_o"], got["rsp_warp_o"],
                    got["rsp_store_o"], got["rsp_tag_o"], got["rsp_status_o"]) == (
                    ctx, epoch, warp, store, tag, status), got
            return
    raise AssertionError(f"missing wait response {tag}")


@cocotb.test()
async def snapshot_class_epoch_failure_and_backpressure(d):
    d.clk.value = 0
    d.rst_n.value = 0
    d.op_vld_i.value = 0
    d.finish_vld_i.value = 0
    d.wait_vld_i.value = 0
    d.rsp_rdy_i.value = 1
    for name in ("op_ctx_i", "op_epoch_i", "op_warp_i", "op_store_i",
                 "op_tag_i", "op_seq_i", "finish_ctx_i", "finish_epoch_i",
                 "finish_warp_i", "finish_store_i", "finish_tag_i",
                 "finish_seq_i", "finish_status_i", "wait_ctx_i",
                 "wait_epoch_i", "wait_warp_i", "wait_store_i", "wait_tag_i"):
        getattr(d, name).value = 0
    for _ in range(3):
        await tick(d)
    d.rst_n.value = 1

    await wait_request(d, 100)
    await response(d, 100)  # Empty wait still completes.
    await operation(d, 1)
    await operation(d, 2, store=1)
    d.op_ctx_i.value = 2
    d.op_epoch_i.value = 7
    d.op_warp_i.value = 1
    d.op_store_i.value = 0
    d.op_tag_i.value = 99
    d.op_seq_i.value = 99
    d.op_vld_i.value = 1
    extra_accepted = (await tick(d))["op_rdy_o"]
    d.op_vld_i.value = 0
    if extra_accepted:
        await finish(d, 99)
    await wait_request(d, 101)
    await wait_request(d, 102, store=1)
    await finish(d, 2, store=1)
    await response(d, 102, store=1)  # ST does not wait for LD.
    await operation(d, 3)             # After wait 101's snapshot.
    await finish(d, 1)
    await response(d, 101)            # New LD 3 cannot extend wait 101.
    await wait_request(d, 103)
    await finish(d, 3, status=5)
    await response(d, 103, status=16)
    await wait_request(d, 104)
    await response(d, 104, status=16)  # Failure remains visible this epoch.
    d.clear_ctx_i.value = 2
    d.clear_ctx_vld_i.value = 1
    await tick(d)
    d.clear_ctx_vld_i.value = 0
    await wait_request(d, 109)
    await response(d, 109)             # Recreated context can reuse epoch.
    await wait_request(d, 105, store=1)
    await response(d, 105, store=1)   # LD failure cannot poison ST.
    await wait_request(d, 106, epoch=8)
    await response(d, 106, epoch=8)   # Epoch reuse cannot inherit poison.

    # Output pressure is independent of registration and completion credit.
    d.rsp_rdy_i.value = 0
    await wait_request(d, 107, epoch=8)
    for _ in range(3):
        got = await tick(d)
        if got["rsp_vld_o"]:
            break
    else:
        raise AssertionError("response not offered")
    assert got["rsp_tag_o"] == 107
    await operation(d, 4, epoch=8)
    await wait_request(d, 108, epoch=8)
    await finish(d, 4, epoch=8)
    for _ in range(3):
        got = await tick(d)
        assert got["rsp_vld_o"] and got["rsp_tag_o"] == 107
    d.rsp_rdy_i.value = 1
    await response(d, 107, epoch=8)
    await response(d, 108, epoch=8)

    await finish(d, 999, valid=False)
    await operation(d, 5, epoch=9)
    d.op_ctx_i.value = 2
    d.op_epoch_i.value = 9
    d.op_warp_i.value = 1
    d.op_store_i.value = 0
    d.op_tag_i.value = 5
    d.op_seq_i.value = 5
    d.op_vld_i.value = 1
    assert not (await tick(d))["op_rdy_o"]
    d.op_vld_i.value = 0
    await finish(d, 5, epoch=9)

    await operation(d, 6, epoch=10)
    await operation(d, 7, epoch=10)
    await wait_request(d, 110, epoch=10)
    await finish(d, 7, epoch=10)   # Out-of-order finish leaves 6 pending.
    for _ in range(3):
        assert not (await tick(d))["rsp_vld_o"]
    await finish(d, 6, epoch=10)
    await response(d, 110, epoch=10)

    await operation(d, 8, epoch=11)
    d.finish_ctx_i.value = 2
    d.finish_epoch_i.value = 11
    d.finish_warp_i.value = 1
    d.finish_store_i.value = 0
    d.finish_tag_i.value = 8
    d.finish_seq_i.value = 8
    d.finish_status_i.value = 5
    d.wait_ctx_i.value = 2
    d.wait_epoch_i.value = 11
    d.wait_warp_i.value = 1
    d.wait_store_i.value = 0
    d.wait_tag_i.value = 111
    d.finish_vld_i.value = 1
    d.wait_vld_i.value = 1
    assert (await tick(d))["wait_rdy_o"]
    d.finish_vld_i.value = 0
    d.wait_vld_i.value = 0
    await response(d, 111, status=16, epoch=11)
