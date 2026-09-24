"""Independent word-level checks for the 256 KiB TMEM physical/owner path."""
import cocotb
from cocotb.triggers import Timer


async def tick(d):
    d.clk.value = 0
    await Timer(5, units="ns")
    ready = {name: int(getattr(d, name).value) for name in
             ("ctx_rdy_o", "alloc_rdy_o", "free_rdy_o", "relinquish_rdy_o",
              "rd_rdy_o", "wr_rdy_o")}
    d.clk.value = 1
    await Timer(5, units="ns")
    return ready


async def control(d, port, fields, tag, expect=0, base=None):
    for name, value in fields.items():
        getattr(d, name).value = value
    getattr(d, f"{port}_tag_i").value = tag
    getattr(d, f"{port}_vld_i").value = 1
    for _ in range(100):
        got = await tick(d)
        if got[f"{port}_rdy_o"]:
            break
    else:
        raise AssertionError(f"{port} did not accept")
    getattr(d, f"{port}_vld_i").value = 0
    assert int(d.ctrl_rsp_vld_o.value)
    assert int(d.ctrl_rsp_tag_o.value) == tag
    assert int(d.ctrl_rsp_status_o.value) == expect
    if base is not None:
        assert int(d.ctrl_rsp_base_o.value) == base
    await tick(d)


async def data(d, op, ctx, epoch, column, tag, status=0, value=None,
               mask=None, ready=True):
    cols = sum(column << (16 * lane) for lane in range(128))
    getattr(d, f"{op}_ctx_i").value = ctx
    getattr(d, f"{op}_epoch_i").value = epoch
    getattr(d, f"{op}_column_i").value = cols
    getattr(d, f"{op}_tag_i").value = tag
    if op == "wr":
        d.wr_data_i.value = value
        d.wr_byte_mask_i.value = ((1 << 2048) - 1) if mask is None else mask
    else:
        d.rd_lane_mask_i.value = (1 << 128) - 1
    getattr(d, f"{op}_rsp_rdy_i").value = int(ready)
    getattr(d, f"{op}_vld_i").value = 1
    got = await tick(d)
    assert got[f"{op}_rdy_o"]
    getattr(d, f"{op}_vld_i").value = 0
    assert int(getattr(d, f"{op}_rsp_vld_o").value)
    assert int(getattr(d, f"{op}_rsp_tag_o").value) == tag
    assert int(getattr(d, f"{op}_rsp_status_o").value) == status
    if op == "rd" and status == 0 and value is not None:
        assert int(d.rd_rsp_data_o.value) == value
    return got


@cocotb.test()
async def capacity_ownership_backpressure_and_release(d):
    d.clk.value = 0
    d.rst_n.value = 0
    for port in ("ctx", "alloc", "free", "relinquish", "rd", "wr"):
        getattr(d, f"{port}_vld_i").value = 0
    d.ctrl_rsp_rdy_i.value = 1
    d.rd_rsp_rdy_i.value = 1
    d.wr_rsp_rdy_i.value = 1
    for name in ("ctx_create_i", "ctx_id_i", "ctx_epoch_i", "ctx_tag_i",
                 "alloc_ctx_i", "alloc_epoch_i", "alloc_columns_i", "alloc_tag_i",
                 "free_ctx_i", "free_epoch_i", "free_base_i", "free_columns_i", "free_tag_i",
                 "relinquish_ctx_i", "relinquish_epoch_i", "relinquish_tag_i",
                 "rd_ctx_i", "rd_epoch_i", "rd_lane_mask_i", "rd_column_i", "rd_tag_i",
                 "wr_ctx_i", "wr_epoch_i", "wr_column_i", "wr_data_i", "wr_byte_mask_i", "wr_tag_i"):
        getattr(d, name).value = 0
    for _ in range(3):
        await tick(d)
    d.rst_n.value = 1

    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 0, "ctx_epoch_i": 7}, 1)
    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 1, "ctx_epoch_i": 8}, 2)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 7,
                                "alloc_columns_i": 512}, 3, base=0)
    # All 128 lane banks and all 128 physical words are addressable.
    for word in range(128):
        payload = sum(((word << 16) | lane) << (128 * lane) for lane in range(128))
        await data(d, "wr", 0, 7, word * 4, word, value=payload)
        await tick(d)
    for word in range(128):
        payload = sum(((word << 16) | lane) << (128 * lane) for lane in range(128))
        await data(d, "rd", 0, 7, word * 4, word, value=payload)
        await tick(d)

    # Resource-starved alloc cannot block a deallocation on its own channel.
    d.alloc_ctx_i.value = 1
    d.alloc_epoch_i.value = 8
    d.alloc_columns_i.value = 256
    d.alloc_tag_i.value = 4
    d.alloc_vld_i.value = 1
    assert (await tick(d))["alloc_rdy_o"] == 0
    d.free_ctx_i.value = 0
    d.free_epoch_i.value = 7
    d.free_base_i.value = 0
    d.free_columns_i.value = 256
    d.free_tag_i.value = 5
    d.free_vld_i.value = 1
    got = await tick(d)
    assert got["free_rdy_o"] and not got["alloc_rdy_o"]
    d.free_vld_i.value = 0
    assert int(d.ctrl_rsp_tag_o.value) == 5
    got = await tick(d)
    assert got["alloc_rdy_o"]
    d.alloc_vld_i.value = 0
    assert int(d.ctrl_rsp_tag_o.value) == 4
    assert int(d.ctrl_rsp_base_o.value) == 0
    await tick(d)

    await data(d, "rd", 0, 7, 0, 6, status=6)
    await tick(d)
    await data(d, "rd", 1, 8, 0, 7)
    await tick(d)
    await data(d, "rd", 1, 8, 511, 8, status=5)
    await tick(d)
    # A stopped response keeps the allocation live; free cannot overtake it.
    await data(d, "rd", 1, 8, 0, 9, ready=False)
    d.free_ctx_i.value = 1
    d.free_epoch_i.value = 8
    d.free_base_i.value = 0
    d.free_columns_i.value = 256
    d.free_tag_i.value = 10
    d.free_vld_i.value = 1
    assert not (await tick(d))["free_rdy_o"]
    d.rd_rsp_rdy_i.value = 1
    assert not (await tick(d))["free_rdy_o"]
    assert (await tick(d))["free_rdy_o"]
    d.free_vld_i.value = 0
    assert int(d.ctrl_rsp_status_o.value) == 0
    await tick(d)

    await control(d, "relinquish", {"relinquish_ctx_i": 1,
                                    "relinquish_epoch_i": 8}, 11)
    await control(d, "alloc", {"alloc_ctx_i": 1, "alloc_epoch_i": 8,
                                "alloc_columns_i": 32}, 12, expect=8)
    await control(d, "free", {"free_ctx_i": 0, "free_epoch_i": 7,
                               "free_base_i": 256, "free_columns_i": 256}, 13)
    await control(d, "ctx", {"ctx_create_i": 0, "ctx_id_i": 0,
                              "ctx_epoch_i": 7}, 14)
    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 0,
                              "ctx_epoch_i": 9}, 15)
    await data(d, "rd", 0, 7, 256, 16, status=3)
    await tick(d)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 9,
                                "alloc_columns_i": 128}, 17, base=0)
    await data(d, "wr", 0, 9, 0, 18, value=0x12345678)
    await tick(d)
    # A rejected whole-vector write must leave every lane unchanged.
    await data(d, "wr", 1, 8, 0, 19, status=6,
               value=(1 << 16384) - 1)
    await tick(d)
    await data(d, "rd", 0, 9, 0, 20, value=0x12345678)
    await tick(d)
    await data(d, "wr", 0, 9, 0, 21, value=0xAA, mask=1)
    await tick(d)
    await data(d, "rd", 0, 9, 0, 22, value=0x123456AA)
    await tick(d)
    # Same-word 1R1W arbitration serializes the operations. The first read
    # returns the old value, then the stalled write becomes visible.
    d.rd_ctx_i.value = 0
    d.rd_epoch_i.value = 9
    d.rd_column_i.value = 0
    d.rd_lane_mask_i.value = 1
    d.rd_tag_i.value = 23
    d.wr_ctx_i.value = 0
    d.wr_epoch_i.value = 9
    d.wr_column_i.value = 0
    d.wr_byte_mask_i.value = 1
    d.wr_data_i.value = 0xBB
    d.wr_tag_i.value = 24
    d.rd_vld_i.value = 1
    d.wr_vld_i.value = 1
    grant = await tick(d)
    assert grant["rd_rdy_o"] != grant["wr_rdy_o"]
    if grant["rd_rdy_o"]:
        assert int(d.rd_rsp_data_o.value) & 0xFFFFFFFF == 0x123456AA
        d.rd_vld_i.value = 0
        assert (await tick(d))["wr_rdy_o"]
        d.wr_vld_i.value = 0
    else:
        d.wr_vld_i.value = 0
        assert (await tick(d))["rd_rdy_o"]
        d.rd_vld_i.value = 0
    await tick(d)
    await data(d, "rd", 0, 9, 0, 25, value=0x123456BB)
    await tick(d)
    await control(d, "ctx", {"ctx_create_i": 0, "ctx_id_i": 0,
                              "ctx_epoch_i": 9}, 26, expect=17)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 9,
                                "alloc_columns_i": 256}, 27, expect=7)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 9,
                                "alloc_columns_i": 64}, 28, base=128)
    # Physical bandwidth only: one 128-bit word per lane bank for both 1R
    # and 1W, after setup. This does not imply LD/ST or MMA instruction rate.
    d.rd_ctx_i.value = d.wr_ctx_i.value = 0
    d.rd_epoch_i.value = d.wr_epoch_i.value = 9
    d.rd_column_i.value = 0
    d.wr_column_i.value = sum(4 << (16 * lane) for lane in range(128))
    d.rd_lane_mask_i.value = (1 << 128) - 1
    d.wr_byte_mask_i.value = (1 << 2048) - 1
    d.wr_data_i.value = 0
    d.rd_vld_i.value = d.wr_vld_i.value = 1
    reads = writes = 0
    for cycle in range(4096):
        d.rd_tag_i.value = d.wr_tag_i.value = cycle & 0xFFFF
        grant = await tick(d)
        reads += grant["rd_rdy_o"]
        writes += grant["wr_rdy_o"]
        assert int(d.rd_rsp_status_o.value) == 0
        assert int(d.wr_rsp_status_o.value) == 0
    d.rd_vld_i.value = d.wr_vld_i.value = 0
    await tick(d)
    assert reads == writes == 4096
    d._log.info("TMEM physical port: %d steady cycles at 2048 B/cycle read and write", reads)
    d._log.info("TMEM full capacity, ownership, backpressure, partial release verified")
