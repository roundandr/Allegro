import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tma_mbarrier_ref import MBarrierModel, TensorDescriptor


LOAD_TENSOR, STORE_TENSOR, LOAD_LINEAR, STORE_LINEAR, DESC_INV = range(5)
INIT, ARRIVE, EXPECT_TX, ARRIVE_EXPECT_TX, TRY_WAIT = range(5)

TMA_OK = 0x00
TMA_BAD_DESC_ALIGN = 0x21
TMA_GMEM = 0x30
MBAR_OK = 0x00
MBAR_LOCKED = 0x42
MBAR_MEMORY = 0x45
MBAR_BAD_PHASE = 0x46


def write_bytes(memory, address, data):
    for offset, value in enumerate(data):
        memory[address + offset] = value


def read_bytes(memory, address, size):
    return bytes(memory.get(address + offset, 0) for offset in range(size))


def word_from_bytes(data):
    return int.from_bytes(data, byteorder="little")


def descriptor(*, dims, elem_bytes, base, sizes, strides, box, traversal):
    return TensorDescriptor(
        dims, elem_bytes, base, tuple(sizes), tuple(strides),
        tuple(box), tuple(traversal)
    ).encode()


def pack_coords(coords):
    value = 0
    for dim in range(5):
        coord = coords[dim] if dim < len(coords) else 0
        value |= (coord & 0xFFFF_FFFF) << (dim * 32)
    return value


class MemoryBackend:
    def __init__(self, dut, *, gmem, smem, rng):
        self.dut = dut
        self.gmem = gmem
        self.smem = smem
        self.rng = rng
        self.g_pending = []
        self.s_pending = []
        self.g_rsp = None
        self.s_rsp = None
        self.next_gmem_error = False
        self.next_barrier_write_error = False
        self.tma_smem_write_acks = 0
        self.cycle = 0
        self.gmem_requests = []
        self.smem_writes = []

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1

            g_rsp_fire = int(self.dut.gmem_rsp_vld_i.value) and int(
                self.dut.gmem_rsp_rdy_o.value)
            s_rsp_fire = int(self.dut.smem_rsp_vld_i.value) and int(
                self.dut.smem_rsp_rdy_o.value)
            g_req_fire = int(self.dut.gmem_req_vld_o.value) and int(
                self.dut.gmem_req_rdy_i.value)
            s_req_fire = int(self.dut.smem_req_vld_o.value) and int(
                self.dut.smem_req_rdy_i.value)

            if g_rsp_fire:
                self.g_rsp = None
            if s_rsp_fire:
                if self.s_rsp and self.s_rsp[4]:
                    self.tma_smem_write_acks += 1
                self.s_rsp = None

            if g_req_fire:
                address = int(self.dut.gmem_req_addr_o.value)
                req_id = int(self.dut.gmem_req_id_o.value)
                is_write = int(self.dut.gmem_req_write_o.value)
                self.gmem_requests.append((is_write, address, req_id))
                status = 1 if self.next_gmem_error else 0
                self.next_gmem_error = False
                if is_write:
                    data = int(self.dut.gmem_req_data_o.value)
                    mask = int(self.dut.gmem_req_mask_o.value)
                    if status == 0:
                        for byte in range(128):
                            if (mask >> byte) & 1:
                                self.gmem[address + byte] = (data >> (8 * byte)) & 0xFF
                    rsp_data = 0
                else:
                    rsp_data = word_from_bytes(read_bytes(self.gmem, address, 128))
                self.g_pending.append(
                    [self.rng.randint(0, 5), req_id, rsp_data, status]
                )

            if s_req_fire:
                address = int(self.dut.smem_req_addr_o.value)
                req_id = int(self.dut.smem_req_id_o.value)
                is_write = int(self.dut.smem_req_write_o.value)
                is_tma_write = is_write and ((req_id >> 5) == 0)
                is_barrier_write = is_write and ((req_id >> 5) != 0)
                status = 0
                if is_barrier_write and self.next_barrier_write_error:
                    status = 1
                    self.next_barrier_write_error = False
                if is_write:
                    data = int(self.dut.smem_req_data_o.value)
                    mask = int(self.dut.smem_req_mask_o.value)
                    if status == 0:
                        for byte in range(32):
                            if (mask >> byte) & 1:
                                self.smem[address + byte] = (
                                    data >> (8 * byte)
                                ) & 0xFF
                    self.smem_writes.append((address, mask, data, req_id))
                    rsp_data = 0
                else:
                    rsp_data = word_from_bytes(read_bytes(self.smem, address, 32))
                self.s_pending.append(
                    [self.rng.randint(0, 4), req_id, rsp_data, status,
                     is_tma_write]
                )

            for item in self.g_pending:
                item[0] = max(0, item[0] - 1)
            for item in self.s_pending:
                item[0] = max(0, item[0] - 1)

            if self.g_rsp is None:
                ready = [item for item in self.g_pending if item[0] == 0]
                if ready:
                    self.g_rsp = self.rng.choice(ready)
                    self.g_pending.remove(self.g_rsp)
            if self.s_rsp is None:
                ready = [item for item in self.s_pending if item[0] == 0]
                if ready:
                    self.s_rsp = self.rng.choice(ready)
                    self.s_pending.remove(self.s_rsp)

            await Timer(1, units="ps")
            self.dut.gmem_req_rdy_i.value = int(self.rng.random() >= 0.20)
            self.dut.smem_req_rdy_i.value = int(self.rng.random() >= 0.20)
            self.dut.gmem_rsp_vld_i.value = int(self.g_rsp is not None)
            self.dut.gmem_rsp_id_i.value = self.g_rsp[1] if self.g_rsp else 0
            self.dut.gmem_rsp_data_i.value = self.g_rsp[2] if self.g_rsp else 0
            self.dut.gmem_rsp_status_i.value = self.g_rsp[3] if self.g_rsp else 0
            self.dut.smem_rsp_vld_i.value = int(self.s_rsp is not None)
            self.dut.smem_rsp_id_i.value = self.s_rsp[1] if self.s_rsp else 0
            self.dut.smem_rsp_data_i.value = self.s_rsp[2] if self.s_rsp else 0
            self.dut.smem_rsp_status_i.value = self.s_rsp[3] if self.s_rsp else 0


async def reset(dut):
    dut.rst_n.value = 0
    dut.tma_cmd_vld_i.value = 0
    dut.tma_rsp_rdy_i.value = 1
    dut.bar_cmd_vld_i.value = 0
    dut.bar_rsp_rdy_i.value = 1
    dut.gmem_req_rdy_i.value = 0
    dut.gmem_rsp_vld_i.value = 0
    dut.smem_req_rdy_i.value = 0
    dut.smem_rsp_vld_i.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
    await Timer(1, units="ps")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_tma(dut, *, opcode, tag, desc=0, coords=(), smem=0,
                   linear=0, size=0, barrier=0, wait_response=True,
                   timeout=20000):
    dut.tma_cmd_opcode_i.value = opcode
    dut.tma_cmd_tag_i.value = tag
    dut.tma_cmd_desc_ptr_i.value = desc
    dut.tma_cmd_coord_i.value = pack_coords(coords)
    dut.tma_cmd_smem_addr_i.value = smem
    dut.tma_cmd_linear_addr_i.value = linear
    dut.tma_cmd_linear_bytes_i.value = size
    dut.tma_cmd_barrier_addr_i.value = barrier
    dut.tma_cmd_vld_i.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.tma_cmd_rdy_o.value):
            break
    else:
        raise AssertionError("TMA command handshake timeout")
    await Timer(1, units="ps")
    dut.tma_cmd_vld_i.value = 0
    if wait_response:
        return await wait_tma(dut, tag, timeout=timeout)
    return None


async def wait_tma(dut, tag, *, timeout=20000):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.tma_rsp_vld_o.value):
            result = (
                int(dut.tma_rsp_tag_o.value),
                int(dut.tma_rsp_status_o.value),
                int(dut.tma_rsp_bytes_o.value),
            )
            assert result[0] == tag, (tag, result)
            return result
    raise AssertionError(f"TMA response timeout for tag {tag:#x}")


async def send_bar(dut, *, opcode, tag, address, arrive=0, tx_bytes=0,
                   token=0, wait_response=True, timeout=20000):
    dut.bar_cmd_opcode_i.value = opcode
    dut.bar_cmd_tag_i.value = tag
    dut.bar_cmd_addr_i.value = address
    dut.bar_cmd_arrive_count_i.value = arrive
    dut.bar_cmd_tx_bytes_i.value = tx_bytes
    dut.bar_cmd_phase_token_i.value = token
    dut.bar_cmd_vld_i.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.bar_cmd_rdy_o.value):
            break
    else:
        raise AssertionError("barrier command handshake timeout")
    await Timer(1, units="ps")
    dut.bar_cmd_vld_i.value = 0
    if wait_response:
        return await wait_bar(dut, tag, timeout=timeout)
    return None


async def wait_bar(dut, tag, *, timeout=20000):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.bar_rsp_vld_o.value):
            result = (
                int(dut.bar_rsp_tag_o.value),
                int(dut.bar_rsp_status_o.value),
                int(dut.bar_rsp_phase_o.value),
                int(dut.bar_rsp_locked_o.value),
            )
            assert result[0] == tag, (tag, result)
            return result
    raise AssertionError(f"barrier response timeout for tag {tag:#x}")


async def collect_bar_responses(dut, tags, *, timeout=20000):
    expected = set(tags)
    responses = {}
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.bar_rsp_vld_o.value):
            tag = int(dut.bar_rsp_tag_o.value)
            assert tag in expected, (tag, expected)
            assert tag not in responses, f"duplicate barrier response {tag:#x}"
            responses[tag] = (
                int(dut.bar_rsp_status_o.value),
                int(dut.bar_rsp_phase_o.value),
                int(dut.bar_rsp_locked_o.value),
            )
            if len(responses) == len(expected):
                return responses
    missing = expected.difference(responses)
    raise AssertionError(f"barrier response timeout, missing {sorted(missing)}")


def row_major_strides(sizes, elem_bytes):
    result = []
    stride = elem_bytes
    for size in sizes:
        result.append(stride)
        stride *= size
    return result


@cocotb.test()
async def patent_semantic_directed_and_randomized(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    seed = int(os.environ.get("COCOTB_RANDOM_SEED", "20260827"))
    rng = random.Random(seed)
    gmem = {}
    smem = {}
    backend = MemoryBackend(dut, gmem=gmem, smem=smem, rng=rng)
    cocotb.start_soon(backend.run())

    # Linear load/store cross both 128-byte GMEM lines and 32-byte SMEM beats.
    linear_source = bytes((index * 17 + 3) & 0xFF for index in range(256))
    write_bytes(gmem, 0x1080, linear_source)
    result = await send_tma(
        dut, opcode=LOAD_LINEAR, tag=0x10, smem=0x8000,
        linear=0x1080, size=len(linear_source)
    )
    assert result == (0x10, TMA_OK, 256)
    assert read_bytes(smem, 0x8000, 256) == linear_source

    store_source = bytes((index * 29 + 7) & 0xFF for index in range(173))
    write_bytes(smem, 0x9000, store_source)
    result = await send_tma(
        dut, opcode=STORE_LINEAR, tag=0x11, smem=0x9000,
        linear=0x31F0, size=len(store_source)
    )
    assert result == (0x11, TMA_OK, len(store_source))
    assert read_bytes(gmem, 0x31F0, len(store_source)) == store_source

    # 2-D signed-coordinate load: negative x is zero-filled, valid elements
    # retain packed logical order in SMEM.
    desc_addr = 0x4000
    tensor_base = 0x5000
    tensor_data = bytes(range(24))
    write_bytes(gmem, tensor_base, tensor_data)
    desc = descriptor(
        dims=2, elem_bytes=2, base=tensor_base,
        sizes=[4, 3], strides=[2, 8], box=[5, 2], traversal=[1, 1]
    )
    write_bytes(gmem, desc_addr, desc)
    result = await send_tma(
        dut, opcode=LOAD_TENSOR, tag=0x20, desc=desc_addr,
        coords=[-1, 1], smem=0xA000
    )
    ref_desc = TensorDescriptor(
        2, 2, tensor_base, (4, 3), (2, 8), (5, 2), (1, 1)
    )
    expected = ref_desc.load(gmem, (-1, 1))
    assert result == (0x20, TMA_OK, 20)
    tensor_actual = read_bytes(smem, 0xA000, 20)
    assert tensor_actual == expected, (
        tensor_actual, expected, backend.gmem_requests[-16:],
        [(hex(a), hex(m), hex(d), i)
         for a, m, d, i in backend.smem_writes[-16:]]
    )

    # Descriptor cache is explicitly noncoherent and changes only after INV.
    replacement_base = 0x6000
    replacement_data = bytes((0xE0 + index) & 0xFF for index in range(24))
    write_bytes(gmem, replacement_base, replacement_data)
    write_bytes(gmem, desc_addr, descriptor(
        dims=2, elem_bytes=2, base=replacement_base,
        sizes=[4, 3], strides=[2, 8], box=[5, 2], traversal=[1, 1]
    ))
    await send_tma(
        dut, opcode=LOAD_TENSOR, tag=0x21, desc=desc_addr,
        coords=[-1, 1], smem=0xA100
    )
    assert read_bytes(smem, 0xA100, 20) == expected
    assert await send_tma(dut, opcode=DESC_INV, tag=0x22, desc=desc_addr) == (
        0x22, TMA_OK, 0
    )
    await send_tma(
        dut, opcode=LOAD_TENSOR, tag=0x23, desc=desc_addr,
        coords=[-1, 1], smem=0xA200
    )
    expected_new = TensorDescriptor(
        2, 2, replacement_base, (4, 3), (2, 8), (5, 2), (1, 1)
    ).load(gmem, (-1, 1))
    assert read_bytes(smem, 0xA200, 20) == expected_new

    # Exercise every dimensionality and element width with a dense box.  The
    # backend returns IDs out of order and independently backpressures requests.
    for dims in range(1, 6):
        elem_bytes = 1 << (dims - 1)
        sizes = [2] * dims
        strides = row_major_strides(sizes, elem_bytes)
        count = 2 ** dims
        byte_count = count * elem_bytes
        daddr = 0x7000 + dims * 0x80
        base = 0x10_000 + dims * 0x1000
        saddr = 0xB000 + dims * 0x400
        payload = bytes((dims * 31 + index) & 0xFF for index in range(byte_count))
        write_bytes(gmem, base, payload)
        write_bytes(gmem, daddr, descriptor(
            dims=dims, elem_bytes=elem_bytes, base=base,
            sizes=sizes, strides=strides, box=sizes, traversal=[1] * dims
        ))
        rsp = await send_tma(
            dut, opcode=LOAD_TENSOR, tag=0x30 + dims, desc=daddr,
            coords=[0] * dims, smem=saddr
        )
        assert rsp == (0x30 + dims, TMA_OK, byte_count)
        assert read_bytes(smem, saddr, byte_count) == payload

    # Tensor store skips its negative-coordinate element without touching GMEM.
    store_desc = 0x7E00
    store_base = 0x1A000
    write_bytes(gmem, store_base, b"\xAA" * 16)
    write_bytes(gmem, store_desc, descriptor(
        dims=1, elem_bytes=4, base=store_base,
        sizes=[4], strides=[4], box=[5], traversal=[1]
    ))
    store_tensor_data = bytes(range(20))
    write_bytes(smem, 0xD000, store_tensor_data)
    rsp = await send_tma(
        dut, opcode=STORE_TENSOR, tag=0x40, desc=store_desc,
        coords=[-1], smem=0xD000
    )
    assert rsp == (0x40, TMA_OK, 20)
    assert read_bytes(gmem, store_base, 16) == store_tensor_data[4:20]

    # expectation-before-completion: phase cannot flip until both components
    # reach zero.  The waiter carries the old phase token.
    barrier = 0xE000
    barrier_ref = MBarrierModel()
    assert barrier_ref.init(1) == 0
    assert await send_bar(
        dut, opcode=INIT, tag=0x50, address=barrier, arrive=1
    ) == (0x50, MBAR_OK, 0, 0)
    assert await send_bar(
        dut, opcode=ARRIVE_EXPECT_TX, tag=0x51, address=barrier,
        arrive=1, tx_bytes=64, token=0
    ) == (0x51, MBAR_OK, 0, 0)
    assert barrier_ref.arrive(1, 0, expect_bytes=64) == 0
    await send_bar(
        dut, opcode=TRY_WAIT, tag=0x52, address=barrier,
        token=0, wait_response=False
    )
    # Hold the independent waiter response so it cannot retire before the TMA
    # command response is sampled below.
    dut.bar_rsp_rdy_i.value = 0
    ack_count = backend.tma_smem_write_acks
    await send_tma(
        dut, opcode=LOAD_LINEAR, tag=0x53, smem=0xF000,
        linear=0x1080, size=64, barrier=barrier, wait_response=False
    )
    tma_rsp = await wait_tma(dut, 0x53)
    assert backend.tma_smem_write_acks > ack_count
    assert tma_rsp == (0x53, TMA_OK, 64)
    assert barrier_ref.complete(64) == 1
    assert barrier_ref.wait_ready(0)
    for _ in range(20000):
        await RisingEdge(dut.clk)
        if int(dut.bar_rsp_vld_o.value):
            wait_rsp = (
                int(dut.bar_rsp_tag_o.value),
                int(dut.bar_rsp_status_o.value),
                int(dut.bar_rsp_phase_o.value),
                int(dut.bar_rsp_locked_o.value),
            )
            break
    else:
        raise AssertionError("queued barrier wait response timeout")
    assert wait_rsp == (0x52, MBAR_OK, 1, 0)
    dut.bar_rsp_rdy_i.value = 1
    await RisingEdge(dut.clk)

    # completion-before-expectation is legal: positive balance is later
    # cancelled atomically with the arrival.
    barrier2 = 0xE100
    barrier2_ref = MBarrierModel()
    barrier2_ref.init(1)
    assert await send_bar(
        dut, opcode=INIT, tag=0x60, address=barrier2, arrive=1
    ) == (0x60, MBAR_OK, 0, 0)
    assert await send_tma(
        dut, opcode=LOAD_LINEAR, tag=0x61, smem=0xF100,
        linear=0x1080, size=32, barrier=barrier2
    ) == (0x61, TMA_OK, 32)
    assert barrier2_ref.complete(32) == 0
    assert await send_bar(
        dut, opcode=ARRIVE_EXPECT_TX, tag=0x62, address=barrier2,
        arrive=1, tx_bytes=32, token=0
    ) == (0x62, MBAR_OK, 1, 0)
    assert barrier2_ref.arrive(1, 0, expect_bytes=32) == 1

    # Reusing an old arrival phase locks the state; INIT is the sole recovery.
    bad_phase = await send_bar(
        dut, opcode=ARRIVE, tag=0x63, address=barrier2,
        arrive=1, token=0
    )
    assert bad_phase == (0x63, MBAR_BAD_PHASE, 1, 1)
    assert await send_bar(
        dut, opcode=INIT, tag=0x64, address=barrier2, arrive=1
    ) == (0x64, MBAR_OK, 0, 0)
    assert await send_bar(
        dut, opcode=TRY_WAIT, tag=0x65, address=barrier2, token=1
    ) == (0x65, MBAR_OK, 0, 0)

    # Directed frontend and backend errors report status and still retire.
    assert await send_tma(
        dut, opcode=LOAD_TENSOR, tag=0x70, desc=0x4001,
        smem=0x10000
    ) == (0x70, TMA_BAD_DESC_ALIGN, 0)
    backend.next_gmem_error = True
    error_rsp = await send_tma(
        dut, opcode=LOAD_LINEAR, tag=0x71, smem=0x10100,
        linear=0x1080, size=32
    )
    assert error_rsp == (0x71, TMA_GMEM, 32)
    assert read_bytes(smem, 0x10100, 32) == b"\x00" * 32

    # Fill the complete 32-entry wait CAM.  A thirty-third wait must remain
    # backpressured until the phase change wakes all resident waiters.
    cam_barrier = 0x12000
    assert await send_bar(
        dut, opcode=INIT, tag=0x100, address=cam_barrier, arrive=1
    ) == (0x100, MBAR_OK, 0, 0)
    cam_tags = list(range(0x110, 0x130))
    for tag in cam_tags:
        await send_bar(
            dut, opcode=TRY_WAIT, tag=tag, address=cam_barrier,
            token=0, wait_response=False
        )
    dut.bar_cmd_opcode_i.value = TRY_WAIT
    dut.bar_cmd_tag_i.value = 0x130
    dut.bar_cmd_addr_i.value = cam_barrier
    dut.bar_cmd_arrive_count_i.value = 0
    dut.bar_cmd_tx_bytes_i.value = 0
    dut.bar_cmd_phase_token_i.value = 0
    dut.bar_cmd_vld_i.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
        assert not int(dut.bar_cmd_rdy_o.value), "full wait CAM accepted entry 33"
    await Timer(1, units="ps")
    dut.bar_cmd_vld_i.value = 0

    arrive_tag = 0x131
    await send_bar(
        dut, opcode=ARRIVE, tag=arrive_tag, address=cam_barrier,
        arrive=1, token=0, wait_response=False
    )
    cam_responses = await collect_bar_responses(
        dut, cam_tags + [arrive_tag], timeout=40000
    )
    assert cam_responses[arrive_tag] == (MBAR_OK, 1, 0)
    for tag in cam_tags:
        assert cam_responses[tag] == (MBAR_OK, 1, 0)

    # Hold the response sink to block one backing write response, then fill
    # the eight-entry FIFO behind it.  The following operation occupies the
    # serialized op register and backpressures one further command.  Distinct
    # addresses also force repeated replacement of the four-entry cache.
    dut.bar_rsp_rdy_i.value = 0
    write_tags = list(range(0x200, 0x20B))
    for index, tag in enumerate(write_tags):
        await send_bar(
            dut, opcode=INIT, tag=tag,
            address=0x13000 + index * 0x20,
            arrive=1, wait_response=False
        )
    dut.bar_cmd_opcode_i.value = INIT
    dut.bar_cmd_tag_i.value = 0x20B
    dut.bar_cmd_addr_i.value = 0x13200
    dut.bar_cmd_arrive_count_i.value = 1
    dut.bar_cmd_tx_bytes_i.value = 0
    dut.bar_cmd_phase_token_i.value = 0
    dut.bar_cmd_vld_i.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
        assert not int(dut.bar_cmd_rdy_o.value), (
            "write-buffer saturation did not backpressure the frontend"
        )
    await Timer(1, units="ps")
    dut.bar_cmd_vld_i.value = 0
    dut.bar_rsp_rdy_i.value = 1
    write_responses = await collect_bar_responses(
        dut, write_tags, timeout=40000
    )
    for tag in write_tags:
        assert write_responses[tag] == (MBAR_OK, 0, 0)

    # A failing write-through update locks the cache line and wakes its waiter
    # with an error; INIT remains the sole recovery operation.
    error_barrier = 0x14000
    assert await send_bar(
        dut, opcode=INIT, tag=0x300, address=error_barrier, arrive=1
    ) == (0x300, MBAR_OK, 0, 0)
    await send_bar(
        dut, opcode=TRY_WAIT, tag=0x301, address=error_barrier,
        token=0, wait_response=False
    )
    backend.next_barrier_write_error = True
    await send_bar(
        dut, opcode=ARRIVE, tag=0x302, address=error_barrier,
        arrive=1, token=0, wait_response=False
    )
    error_responses = await collect_bar_responses(dut, [0x301, 0x302])
    assert error_responses[0x302] == (MBAR_MEMORY, 1, 1)
    assert error_responses[0x301] == (MBAR_LOCKED, 1, 1)
    assert await send_bar(
        dut, opcode=EXPECT_TX, tag=0x303, address=error_barrier,
        tx_bytes=1
    ) == (0x303, MBAR_LOCKED, 1, 1)
    assert await send_bar(
        dut, opcode=INIT, tag=0x304, address=error_barrier, arrive=1
    ) == (0x304, MBAR_OK, 0, 0)
