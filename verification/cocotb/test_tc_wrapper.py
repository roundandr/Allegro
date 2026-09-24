import struct
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly


def pack_fp16(values):
    word = 0
    for idx, value in enumerate(values):
        bits = int(np.asarray(value, dtype=np.float16).view(np.uint16))
        word |= bits << (16 * idx)
    return word


def fp32_bits(value):
    return struct.unpack("<I", struct.pack("<f", np.float32(value)))[0]


@cocotb.test()
async def eight_lane_fp16_and_stalled_output(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    a = np.arange(1, 17, dtype=np.float16) / np.float16(8)
    b_cols = [np.full(16, col + 1, dtype=np.float16) for col in range(8)]
    dut.a_vec_i.value = pack_fp16(a)
    dut.b_vec_i.value = sum(pack_fp16(col) << (256 * idx) for idx, col in enumerate(b_cols))
    dut.c_vec_i.value = 0
    dut.accumulate_i.value = 0
    dut.tag_i.value = 0x53
    dut.in_vld_i.value = 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.in_rdy_o.value):
            break
    dut.in_vld_i.value = 0

    for _ in range(80):
        await RisingEdge(dut.clk)
        if int(dut.out_vld_o.value):
            break
    assert int(dut.out_vld_o.value)
    await ReadOnly()
    held = int(dut.d_vec_o.value)
    assert int(dut.tag_o.value) == 0x53
    assert int(dut.status_o.value) == 0
    for _ in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.out_vld_o.value)
        assert int(dut.d_vec_o.value) == held

    expected = sum(float(x) for x in a)
    for lane in range(8):
        got = (held >> (32 * lane)) & 0xFFFFFFFF
        assert got == fp32_bits(expected * (lane + 1)), (lane, hex(got))
    await RisingEdge(dut.clk)
    dut.out_rdy_i.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def streaming_tags_survive_stalls(dut):
    from cocotb.triggers import Timer
    import random
    rng = random.Random(917)
    dut.clk.value = 0
    dut.rst_n.value = 0
    dut.in_vld_i.value = 0
    dut.out_rdy_i.value = 0
    dut.a_vec_i.value = pack_fp16([1]*16)
    dut.b_vec_i.value = sum(pack_fp16([col+1]*16) << (256*col) for col in range(8))
    dut.c_vec_i.value = 0
    dut.accumulate_i.value = 0
    dut.tag_i.value = 0
    for _ in range(3):
        dut.clk.value=0; await Timer(5,units='ns')
        dut.clk.value=1; await Timer(5,units='ns')
    dut.rst_n.value=1
    issued=retired=0
    held=None
    for tick in range(5000):
        dut.clk.value=0
        dut.in_vld_i.value=int(issued<240)
        dut.tag_i.value=issued%128
        dut.c_vec_i.value=sum(fp32_bits(issued%16) << (32*i) for i in range(8))
        dut.accumulate_i.value=1
        ready=tick>100 and rng.randrange(4)!=0
        dut.out_rdy_i.value=ready
        await Timer(5,units='ns')
        ir=int(dut.in_rdy_o.value); ov=int(dut.out_vld_o.value)
        result=(int(dut.tag_o.value),int(dut.status_o.value),int(dut.d_vec_o.value))
        if held is not None: assert ov and held==result
        held=result if ov and not ready else None
        if ir and issued<240: issued+=1
        if ov and ready:
            assert result[0]==retired%128 and result[1]==0
            for lane in range(8):
                assert (result[2]>>(32*lane))&0xffffffff==fp32_bits(16*(lane+1)+retired%16)
            retired+=1
        dut.clk.value=1; await Timer(5,units='ns')
        if retired==240: break
    assert issued==retired==240
