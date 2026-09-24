"""Warp RF/TMEM movement, checked through the real 256 KiB bank."""
import cocotb
from cocotb.triggers import Timer

CYCLES = 0


async def tick(d):
    global CYCLES
    d.clk.value = 0
    await Timer(5, units="ns")
    names = ("ctx_rdy_o", "alloc_rdy_o", "free_rdy_o", "cmd_rdy_o", "wait_rdy_o",
             "rf_src_rdy_o", "rf_dst_vld_o", "rf_dst_data_o",
             "rf_dst_index_o", "rf_dst_last_o", "done_vld_o",
             "done_status_o", "done_tag_o", "shift_cmd_rdy_o",
             "shift_done_vld_o", "shift_done_status_o", "shift_done_tag_o",
             "shift_register_vld_o", "shift_register_o",
             "shift_complete_vld_o", "shift_complete_o")
    before = {name: int(getattr(d, name).value) for name in names}
    d.clk.value = 1
    await Timer(5, units="ns")
    CYCLES += 1
    return before


async def control(d, port, fields, tag, base=None):
    for key, value in fields.items():
        getattr(d, key).value = value
    getattr(d, f"{port}_tag_i").value = tag
    getattr(d, f"{port}_vld_i").value = 1
    for _ in range(30):
        got = await tick(d)
        if got[f"{port}_rdy_o"]:
            break
    else:
        raise AssertionError(f"{port} stalled")
    getattr(d, f"{port}_vld_i").value = 0
    assert int(d.ctrl_rsp_vld_o.value)
    assert int(d.ctrl_rsp_status_o.value) == 0
    assert int(d.ctrl_rsp_tag_o.value) == tag
    if base is not None:
        assert int(d.ctrl_rsp_base_o.value) == base
    await tick(d)


def vector(values):
    return sum((v & 0xFFFFFFFF) << (32 * t) for t, v in enumerate(values))


def async_id(issuer, warp, tag, seq, epoch):
    return (((((issuer << 5) | warp) << 16 | tag) << 64 | seq) << 16) | epoch


async def issue(d, store, shape, repeat, base, tag, pack=0, half_offset=0,
                warp=0):
    d.cmd_store_i.value = store
    d.cmd_ctx_i.value = 0
    d.cmd_epoch_i.value = 7
    d.cmd_warp_i.value = warp
    d.cmd_shape_i.value = shape
    d.cmd_repeat_i.value = repeat
    d.cmd_pack16_i.value = pack
    d.cmd_base_addr_i.value = base
    d.cmd_half_offset_i.value = half_offset
    d.cmd_tag_i.value = tag
    d.cmd_vld_i.value = 1
    assert (await tick(d))["cmd_rdy_o"]
    d.cmd_vld_i.value = 0


async def finish(d, tag, status=0, limit=10000):
    for cycle in range(limit):
        got = await tick(d)
        if got["done_vld_o"]:
            assert got["done_status_o"] == status
            assert got["done_tag_o"] == tag
            return cycle + 1
    raise AssertionError("TMEM command did not finish")


async def store(d, shape, repeat, base, tag, payloads, pack=0, half_offset=0,
                warp=0):
    await issue(d, 1, shape, repeat, base, tag, pack, half_offset, warp)
    for j, payload in enumerate(payloads):
        d.rf_src_data_i.value = payload
        d.rf_src_last_i.value = int(j == len(payloads) - 1)
        d.rf_src_vld_i.value = 1
        assert (await tick(d))["rf_src_rdy_o"]
    d.rf_src_vld_i.value = 0
    d.rf_src_data_i.value = (1 << 1024) - 1
    return await finish(d, tag)


async def load(d, shape, repeat, base, tag, expected, pack=0, half_offset=0,
               warp=0):
    await issue(d, 0, shape, repeat, base, tag, pack, half_offset, warp)
    got_values = []
    for _ in range(10000):
        d.rf_dst_rdy_i.value = 0
        got = await tick(d)
        if got["rf_dst_vld_o"]:
            assert got["rf_dst_index_o"] == 0
            assert not got["done_vld_o"]
            break
    else:
        raise AssertionError("load produced no RF result")
    # A stalled RF destination must keep the data stable and not complete LD.
    held = got["rf_dst_data_o"]
    for _ in range(3):
        got = await tick(d)
        assert got["rf_dst_vld_o"] and got["rf_dst_data_o"] == held
        assert not got["done_vld_o"]
    d.rf_dst_rdy_i.value = 1
    for _ in range(1000):
        got = await tick(d)
        if got["rf_dst_vld_o"]:
            assert got["rf_dst_index_o"] == len(got_values)
            assert got["rf_dst_last_o"] == (len(got_values) == len(expected) - 1)
            got_values.append(got["rf_dst_data_o"])
            if len(got_values) == len(expected):
                break
    assert got_values == expected
    await finish(d, tag)


@cocotb.test()
async def ordinary_packed_and_error_atomicity(d):
    d.clk.value = 0
    d.rst_n.value = 0
    for port in ("ctx", "alloc", "free", "relinquish", "cmd", "rf_src", "shift_cmd"):
        getattr(d, f"{port}_vld_i").value = 0
    d.ctrl_rsp_rdy_i.value = 1
    d.rf_dst_rdy_i.value = 0
    d.done_rdy_i.value = 0
    d.wait_vld_i.value = 0
    d.wait_rsp_rdy_i.value = 1
    d.shift_done_rdy_i.value = 0
    d.shift_register_rdy_i.value = 1
    d.shift_complete_rdy_i.value = 1
    for key in ("shift_cmd_ctx_i", "shift_cmd_epoch_i", "shift_cmd_base_addr_i",
                "shift_cmd_tag_i", "shift_cmd_issuer_i", "shift_cmd_warp_i",
                "shift_cmd_seq_i"):
        getattr(d, key).value = 0
    for key in ("ctx_create_i", "ctx_id_i", "ctx_epoch_i", "ctx_tag_i",
                "alloc_ctx_i", "alloc_epoch_i", "alloc_columns_i", "alloc_tag_i",
                "free_ctx_i", "free_epoch_i", "free_base_i", "free_columns_i", "free_tag_i",
                "relinquish_ctx_i", "relinquish_epoch_i", "relinquish_tag_i",
                "cmd_store_i", "cmd_ctx_i", "cmd_epoch_i", "cmd_warp_i",
                "cmd_shape_i", "cmd_repeat_i", "cmd_pack16_i", "cmd_base_addr_i",
                "cmd_half_offset_i", "cmd_tag_i", "rf_src_data_i", "rf_src_last_i"):
        getattr(d, key).value = 0
    for key in ("wait_ctx_i", "wait_epoch_i", "wait_warp_i", "wait_store_i", "wait_tag_i"):
        getattr(d, key).value = 0
    for _ in range(3):
        await tick(d)
    d.rst_n.value = 1
    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 0,
                             "ctx_epoch_i": 7}, 1)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 7,
                               "alloc_columns_i": 512}, 2, base=0)

    ordinary = [vector([(0x12340000 | (j << 8) | t) for t in range(32)])
                for j in range(2)]
    ordinary_store_cycles = await store(d, 0, 2, 0, 3, ordinary)
    assert ordinary_store_cycles < 20, ordinary_store_cycles
    # The completion response and allocation release are independently held.
    assert int(d.done_vld_o.value)
    d.free_ctx_i.value = 0
    d.free_epoch_i.value = 7
    d.free_base_i.value = 0
    d.free_columns_i.value = 512
    d.free_vld_i.value = 1
    assert not (await tick(d))["free_rdy_o"]
    d.free_vld_i.value = 0
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    await load(d, 0, 2, 0, 4, ordinary)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0

    # Split halves use the same 16 lanes, displaced by two columns. Packed
    # ST writes only each target cell's low half; packed LD reassembles RF.
    packed = [vector([(0xA000 + t) | ((0xB000 + t) << 16)
                      for t in range(32)])]
    packed_store_cycles = await store(d, 4, 1, 8, 5, packed, pack=1, half_offset=2)
    assert packed_store_cycles < 20, packed_store_cycles
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    await load(d, 4, 1, 8, 6, packed, pack=1, half_offset=2)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0

    # The other three shapes carry different thread/lane fanouts and multiple
    # registers per thread. Warp rank 1 exercises a nonzero lane partition.
    for shape, nregs, column, pack, tag in ((1, 2, 32, 0, 20),
                                             (2, 4, 48, 1, 22),
                                             (3, 8, 80, 0, 24)):
        values = [vector([0x34000000 | (shape << 20) | (j << 8) | t
                          for t in range(32)]) for j in range(nregs)]
        await store(d, shape, 2, (32 << 16) | column, tag, values,
                    pack=pack, warp=1)
        d.done_rdy_i.value = 1
        await tick(d)
        d.done_rdy_i.value = 0
        await load(d, shape, 2, (32 << 16) | column, tag + 1, values,
                   pack=pack, warp=1)
        d.done_rdy_i.value = 1
        await tick(d)
        d.done_rdy_i.value = 0

    upper = [vector([0xABCD0000 | t for t in range(32)]),
             vector([0xCDEF0000 | t for t in range(32)])]
    await store(d, 0, 2, 8, 30, upper)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    low = [vector([(0x2220 + t) << 16 | (0x1110 + t)
                   for t in range(32)])]
    await store(d, 0, 1, 8, 31, low, pack=1)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    preserved = [vector([0xABCD0000 | (0x1110 + t) for t in range(32)]),
                 vector([0xCDEF0000 | (0x2220 + t) for t in range(32)])]
    await load(d, 0, 2, 8, 32, preserved)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    # A late out-of-range cell is detected in the probe pass: no early cell
    # may be written. A later LD still observes the original values.
    sentinel = [vector([0x55AA0000 + t for t in range(32)])]
    await store(d, 0, 1, 0x1F4, 9, sentinel)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    bad_payloads = [vector([0xDEAD0000 + j * 32 + t for t in range(32)])
                    for j in range(16)]
    await issue(d, 1, 0, 16, 0x1F4, 7)
    for j, payload in enumerate(bad_payloads):
        d.rf_src_data_i.value = payload
        d.rf_src_last_i.value = int(j == 15)
        d.rf_src_vld_i.value = 1
        assert (await tick(d))["rf_src_rdy_o"]
    d.rf_src_vld_i.value = 0
    await finish(d, 7, status=5)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    await load(d, 0, 1, 0x1F4, 10, sentinel)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    await load(d, 0, 2, 0, 8, ordinary)
    d._log.info("TMEM RF vector issue: two-register ordinary ST %d cycles, packed split ST %d cycles",
                ordinary_store_cycles, packed_store_cycles)
    d._log.info("TMEM RF full-source ST, packed paths, RF ack and no-partial-write passed")


@cocotb.test()
async def steady_single_warp_store_4096_cycles(d):
    d.clk.value = 0
    d.rst_n.value = 0
    for port in ("ctx", "alloc", "free", "relinquish", "cmd", "rf_src", "shift_cmd"):
        getattr(d, f"{port}_vld_i").value = 0
    d.ctrl_rsp_rdy_i.value = 1
    d.done_rdy_i.value = 1
    d.rf_dst_rdy_i.value = 1
    d.wait_vld_i.value = 0
    d.wait_rsp_rdy_i.value = 1
    d.shift_done_rdy_i.value = 0
    d.shift_register_rdy_i.value = 1
    d.shift_complete_rdy_i.value = 1
    for key in ("shift_cmd_ctx_i", "shift_cmd_epoch_i", "shift_cmd_base_addr_i",
                "shift_cmd_tag_i", "shift_cmd_issuer_i", "shift_cmd_warp_i",
                "shift_cmd_seq_i"):
        getattr(d, key).value = 0
    for key in ("ctx_create_i", "ctx_id_i", "ctx_epoch_i", "ctx_tag_i",
                "alloc_ctx_i", "alloc_epoch_i", "alloc_columns_i", "alloc_tag_i",
                "free_ctx_i", "free_epoch_i", "free_base_i", "free_columns_i", "free_tag_i",
                "relinquish_ctx_i", "relinquish_epoch_i", "relinquish_tag_i",
                "cmd_store_i", "cmd_ctx_i", "cmd_epoch_i", "cmd_warp_i",
                "cmd_shape_i", "cmd_repeat_i", "cmd_pack16_i", "cmd_base_addr_i",
                "cmd_half_offset_i", "cmd_tag_i", "rf_src_data_i", "rf_src_last_i"):
        getattr(d, key).value = 0
    for key in ("wait_ctx_i", "wait_epoch_i", "wait_warp_i", "wait_store_i", "wait_tag_i"):
        getattr(d, key).value = 0
    for _ in range(3):
        await tick(d)
    d.rst_n.value = 1
    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 0,
                             "ctx_epoch_i": 7}, 1)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 7,
                               "alloc_columns_i": 512}, 2, base=0)
    payload = [vector([0x4A000000 | t for t in range(32)])]
    for tag in range(32):
        await store(d, 0, 1, 0, tag, payload)
    start = CYCLES
    completed = 0
    while CYCLES - start < 4096:
        await store(d, 0, 1, 0, completed + 32, payload)
        completed += 1
    elapsed = CYCLES - start
    effective_bytes_per_cycle = completed * 128 / elapsed
    assert elapsed >= 4096
    assert completed > 200, (completed, elapsed)
    d.done_rdy_i.value = 0
    await load(d, 0, 1, 0, 0x7FFE, payload)
    d._log.info("TMEM one-warp ST: %d completed 128-byte operations in %d steady cycles, %.3f payload B/cycle",
                completed, elapsed, effective_bytes_per_cycle)

async def wait_issue(d, tag, store, epoch=7):
    d.wait_ctx_i.value = 0
    d.wait_epoch_i.value = epoch
    d.wait_warp_i.value = 0
    d.wait_store_i.value = store
    d.wait_tag_i.value = tag
    d.wait_vld_i.value = 1
    assert (await tick(d))["wait_rdy_o"]
    d.wait_vld_i.value = 0


async def wait_result(d, tag, store, status=0, epoch=7):
    for _ in range(100):
        await tick(d)
        if int(d.wait_rsp_vld_o.value):
            assert int(d.wait_rsp_tag_o.value) == tag
            assert int(d.wait_rsp_store_o.value) == store
            assert int(d.wait_rsp_status_o.value) == status
            assert int(d.wait_rsp_epoch_o.value) == epoch
            assert int(d.wait_rsp_ctx_o.value) == 0
            assert int(d.wait_rsp_warp_o.value) == 0
            assert not int(d.wait_protocol_error_o.value)
            d.wait_rsp_rdy_i.value = 1
            await tick(d)
            d.wait_rsp_rdy_i.value = 0
            return
    raise AssertionError(f"wait {tag} never completed")


@cocotb.test()
async def wait_uses_real_rf_and_bank_completion(d):
    d.clk.value = 0
    d.rst_n.value = 0
    for port in ("ctx", "alloc", "free", "relinquish", "cmd", "rf_src", "wait", "shift_cmd"):
        getattr(d, f"{port}_vld_i").value = 0
    d.ctrl_rsp_rdy_i.value = 1
    d.done_rdy_i.value = 0
    d.rf_dst_rdy_i.value = 0
    d.wait_rsp_rdy_i.value = 0
    d.shift_done_rdy_i.value = 0
    d.shift_register_rdy_i.value = 1
    d.shift_complete_rdy_i.value = 1
    for key in ("ctx_create_i", "ctx_id_i", "ctx_epoch_i", "ctx_tag_i",
                "alloc_ctx_i", "alloc_epoch_i", "alloc_columns_i", "alloc_tag_i",
                "free_ctx_i", "free_epoch_i", "free_base_i", "free_columns_i", "free_tag_i",
                "relinquish_ctx_i", "relinquish_epoch_i", "relinquish_tag_i",
                "cmd_store_i", "cmd_ctx_i", "cmd_epoch_i", "cmd_warp_i",
                "cmd_shape_i", "cmd_repeat_i", "cmd_pack16_i", "cmd_base_addr_i",
                "cmd_half_offset_i", "cmd_tag_i", "rf_src_data_i", "rf_src_last_i",
                "wait_ctx_i", "wait_epoch_i", "wait_warp_i", "wait_store_i", "wait_tag_i",
                "shift_cmd_ctx_i", "shift_cmd_epoch_i", "shift_cmd_base_addr_i",
                "shift_cmd_tag_i", "shift_cmd_issuer_i", "shift_cmd_warp_i",
                "shift_cmd_seq_i"):
        getattr(d, key).value = 0
    for _ in range(3):
        await tick(d)
    d.rst_n.value = 1
    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 0,
                             "ctx_epoch_i": 7}, 1)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 7,
                               "alloc_columns_i": 512}, 2, base=0)
    await wait_issue(d, 80, store=0)
    await wait_result(d, 80, store=0)

    payload = vector([0x12340000 | t for t in range(32)])
    await issue(d, 1, 0, 1, 0, 10)
    d.rf_src_data_i.value = payload
    d.rf_src_last_i.value = 1
    d.rf_src_vld_i.value = 1
    assert (await tick(d))["rf_src_rdy_o"]
    d.rf_src_vld_i.value = 0
    await wait_issue(d, 81, store=1)
    for _ in range(100):
        await tick(d)
        if int(d.done_vld_o.value):
            break
    else:
        raise AssertionError("store failed to finish")
    assert int(d.done_tag_o.value) == 10
    await wait_result(d, 81, store=1)  # Independent of blocked DONE.
    assert int(d.done_vld_o.value)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0

    await issue(d, 0, 0, 1, 0, 11)
    await wait_issue(d, 82, store=0)
    for _ in range(100):
        await tick(d)
        if int(d.rf_dst_vld_o.value):
            break
    else:
        raise AssertionError("load failed to reach RF sink")
    for _ in range(5):
        await tick(d)
        assert int(d.rf_dst_vld_o.value)
        assert not int(d.wait_rsp_vld_o.value)
        assert not int(d.done_vld_o.value)
    d.rf_dst_rdy_i.value = 1
    await tick(d)
    d.rf_dst_rdy_i.value = 0
    await wait_result(d, 82, store=0)
    assert int(d.done_vld_o.value)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0

    # A failed LD poisons its own class/epoch, including waits submitted after
    # its data command finished. ST waits remain independent.
    await issue(d, 0, 7, 1, 0, 12)
    await wait_issue(d, 83, store=0)
    await wait_result(d, 83, store=0, status=16)
    d.done_rdy_i.value = 1
    await tick(d)
    d.done_rdy_i.value = 0
    await wait_issue(d, 84, store=0)
    await wait_result(d, 84, store=0, status=16)
    await wait_issue(d, 85, store=1)
    await wait_result(d, 85, store=1)
    await wait_issue(d, 86, store=0, epoch=8)
    await wait_result(d, 86, store=0, epoch=8)
    await control(d, "free", {"free_ctx_i": 0, "free_epoch_i": 7,
                              "free_base_i": 0, "free_columns_i": 512}, 20)
    await control(d, "ctx", {"ctx_create_i": 0, "ctx_id_i": 0,
                             "ctx_epoch_i": 7}, 21)
    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 0,
                             "ctx_epoch_i": 7}, 22)
    await wait_issue(d, 87, store=0, epoch=7)
    await wait_result(d, 87, store=0, epoch=7)


async def shift_issue(d, base, tag, status=0, ctx=0):
    d.shift_cmd_ctx_i.value = ctx
    d.shift_cmd_epoch_i.value = 7
    d.shift_cmd_base_addr_i.value = base
    d.shift_cmd_tag_i.value = tag
    d.shift_cmd_issuer_i.value = 0
    d.shift_cmd_warp_i.value = 0
    d.shift_cmd_seq_i.value = tag
    d.shift_cmd_vld_i.value = 1
    got = await tick(d)
    assert got["shift_cmd_rdy_o"] and got["shift_register_vld_o"]
    assert got["shift_register_o"] == async_id(0, 0, tag, tag, 7)
    d.shift_cmd_vld_i.value = 0
    completed = False
    for _ in range(300):
        got = await tick(d)
        if got["shift_complete_vld_o"]:
            assert not completed
            completed = True
            assert got["shift_complete_o"] == (
                (async_id(0, 0, tag, tag, 7) << 75) | (status << 64))
            assert not got["shift_done_vld_o"]
        if got["shift_done_vld_o"]:
            assert completed
            assert got["shift_done_tag_o"] == tag
            assert got["shift_done_status_o"] == status
            return
    raise AssertionError("SHIFT never finished")


async def accept_done(d, shift=False):
    name = "shift_done_rdy_i" if shift else "done_rdy_i"
    getattr(d, name).value = 1
    await tick(d)
    getattr(d, name).value = 0


@cocotb.test()
async def shift_down_real_bank_and_full_footprint_preflight(d):
    d.clk.value = 0
    d.rst_n.value = 0
    for port in ("ctx", "alloc", "free", "relinquish", "cmd", "rf_src",
                 "wait", "shift_cmd"):
        getattr(d, f"{port}_vld_i").value = 0
    d.ctrl_rsp_rdy_i.value = 1
    d.done_rdy_i.value = 0
    d.shift_done_rdy_i.value = 0
    d.shift_register_rdy_i.value = 1
    d.shift_complete_rdy_i.value = 1
    d.rf_dst_rdy_i.value = 0
    d.wait_rsp_rdy_i.value = 0
    for key in ("ctx_create_i", "ctx_id_i", "ctx_epoch_i", "ctx_tag_i",
                "alloc_ctx_i", "alloc_epoch_i", "alloc_columns_i", "alloc_tag_i",
                "free_ctx_i", "free_epoch_i", "free_base_i", "free_columns_i", "free_tag_i",
                "relinquish_ctx_i", "relinquish_epoch_i", "relinquish_tag_i",
                "cmd_store_i", "cmd_ctx_i", "cmd_epoch_i", "cmd_warp_i",
                "cmd_shape_i", "cmd_repeat_i", "cmd_pack16_i", "cmd_base_addr_i",
                "cmd_half_offset_i", "cmd_tag_i", "rf_src_data_i", "rf_src_last_i",
                "wait_ctx_i", "wait_epoch_i", "wait_warp_i", "wait_store_i", "wait_tag_i",
                "shift_cmd_ctx_i", "shift_cmd_epoch_i", "shift_cmd_base_addr_i",
                "shift_cmd_tag_i", "shift_cmd_issuer_i", "shift_cmd_warp_i",
                "shift_cmd_seq_i"):
        getattr(d, key).value = 0
    for _ in range(3):
        await tick(d)
    d.rst_n.value = 1
    await control(d, "ctx", {"ctx_create_i": 1, "ctx_id_i": 0,
                             "ctx_epoch_i": 7}, 1)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 7,
                               "alloc_columns_i": 512}, 2, base=0)

    for lane_base, col_base, warp in ((0, 16, 0), (32, 40, 1)):
        base = (lane_base << 16) | col_base
        original = [vector([(0x51000000 | (col << 8) | lane) for lane in range(32)])
                    for col in range(8)]
        expected = [vector([(0x51000000 | (col << 8) | min(lane + 1, 31))
                            for lane in range(32)]) for col in range(8)]
        await store(d, 0, 8, base, 10 + warp, original, warp=warp)
        await accept_done(d)
        await shift_issue(d, base, 20 + warp)
        for _ in range(3):
            got = await tick(d)
            assert got["shift_done_vld_o"] and got["shift_done_tag_o"] == 20 + warp
            assert got["shift_done_status_o"] == 0
            assert not got["cmd_rdy_o"] and not got["free_rdy_o"]
        await accept_done(d, shift=True)
        await load(d, 0, 8, base, 30 + warp, expected, warp=warp)
        await accept_done(d)

    # SHIFT can register while a prior LD is blocked at the RF sink. A
    # following commit may snapshot it before its bank dispatch starts.
    d.rf_dst_rdy_i.value = 0
    await issue(d, 0, 0, 1, 16, 70)
    for _ in range(100):
        if (await tick(d))["rf_dst_vld_o"]:
            break
    else:
        raise AssertionError("LD did not reach RF sink")
    d.shift_cmd_ctx_i.value = 0
    d.shift_cmd_epoch_i.value = 7
    d.shift_cmd_base_addr_i.value = 16
    d.shift_cmd_tag_i.value = 71
    d.shift_cmd_issuer_i.value = 0
    d.shift_cmd_warp_i.value = 0
    d.shift_cmd_seq_i.value = 71
    d.shift_cmd_vld_i.value = 1
    got = await tick(d)
    assert got["shift_cmd_rdy_o"] and got["shift_register_vld_o"]
    d.shift_cmd_vld_i.value = 0
    for _ in range(5):
        got = await tick(d)
        assert got["rf_dst_vld_o"] and not got["shift_complete_vld_o"]
    d.rf_dst_rdy_i.value = 1
    await tick(d)
    d.rf_dst_rdy_i.value = 0
    await finish(d, 70)
    for _ in range(5):
        assert not (await tick(d))["shift_complete_vld_o"]
    await accept_done(d)
    completed = False
    for _ in range(300):
        got = await tick(d)
        if got["shift_complete_vld_o"]:
            assert got["shift_complete_o"] == async_id(0, 0, 71, 71, 7) << 75
            completed = True
        if got["shift_done_vld_o"]:
            assert completed and got["shift_done_tag_o"] == 71
            break
    else:
        raise AssertionError("queued SHIFT did not finish")
    await accept_done(d, shift=True)
    twice = [vector([0x51000000 | (col << 8) | min(lane + 2, 31)
                     for lane in range(32)]) for col in range(8)]
    await load(d, 0, 8, 16, 72, twice)
    await accept_done(d)

    # A bad base is rejected before any bank request; SHIFT never enters the
    # LD/ST wait snapshot domain.
    await wait_issue(d, 50, store=0)
    await wait_result(d, 50, store=0)
    await shift_issue(d, 505, 51, status=5)
    await accept_done(d, shift=True)
    await shift_issue(d, (1 << 16) | 16, 52, status=5)
    await accept_done(d, shift=True)
    await wait_issue(d, 53, store=0)
    await wait_result(d, 53, store=0)

    # Registration and completion use separate credit. Neither a queued
    # operation nor its DONE response may bypass an unaccepted TC event.
    d.shift_cmd_ctx_i.value = 0
    d.shift_cmd_epoch_i.value = 7
    d.shift_cmd_base_addr_i.value = 16
    d.shift_cmd_tag_i.value = 54
    d.shift_cmd_issuer_i.value = 35
    d.shift_cmd_warp_i.value = 1
    d.shift_cmd_seq_i.value = 900
    d.shift_register_rdy_i.value = 0
    d.shift_cmd_vld_i.value = 1
    for _ in range(4):
        got = await tick(d)
        assert got["shift_register_vld_o"] and not got["shift_cmd_rdy_o"]
        assert got["shift_register_o"] == async_id(35, 1, 54, 900, 7)
    d.shift_register_rdy_i.value = 1
    got = await tick(d)
    assert got["shift_cmd_rdy_o"] and got["shift_register_vld_o"]
    d.shift_cmd_vld_i.value = 0
    d.shift_complete_rdy_i.value = 0
    d.shift_done_rdy_i.value = 1
    for _ in range(300):
        got = await tick(d)
        if got["shift_complete_vld_o"]:
            assert not got["shift_done_vld_o"]
            held = got["shift_complete_o"]
            assert held == async_id(35, 1, 54, 900, 7) << 75
            break
    else:
        raise AssertionError("SHIFT TC completion missing")
    for _ in range(5):
        got = await tick(d)
        assert got["shift_complete_vld_o"] and got["shift_complete_o"] == held
        assert not got["shift_done_vld_o"] and not got["cmd_rdy_o"]
    d.shift_complete_rdy_i.value = 1
    assert (await tick(d))["shift_complete_vld_o"]
    assert (await tick(d))["shift_done_vld_o"]
    d.shift_done_rdy_i.value = 0

    await control(d, "free", {"free_ctx_i": 0, "free_epoch_i": 7,
                              "free_base_i": 0, "free_columns_i": 512}, 60)
    await control(d, "alloc", {"alloc_ctx_i": 0, "alloc_epoch_i": 7,
                               "alloc_columns_i": 32}, 61, base=0)
    sentinel = [vector([0x76000000 | (col << 8) | lane for lane in range(32)])
                for col in range(4)]
    await store(d, 0, 4, 28, 62, sentinel)
    await accept_done(d)
    # Columns 28..31 are owned, 32..35 are not. Probe must fail before the
    # first column moves, including when the error appears late in the range.
    await shift_issue(d, 28, 63, status=6)
    await accept_done(d, shift=True)
    await load(d, 0, 4, 28, 64, sentinel)
    await accept_done(d)
    d._log.info("SHIFT 32x8 real-bank data, held completion, two lane partitions and atomic preflight passed")
