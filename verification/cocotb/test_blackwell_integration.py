"""Unified TMA/mbarrier/Tensor integration, including the former 256B copy use case."""
import random
import cocotb
from cocotb.triggers import RisingEdge
from test_tma_mbarrier import (Harness, LOAD_LINEAR, STORE_LINEAR, INIT, ARRIVE_EXPECT_TX,
                              TRY_WAIT, COMMIT, WAIT_GROUP, write_bytes, read_bytes)
from test_blackwell_subsystem import (issue, smem_model, pack_fp16, expected_row, MMA, STORE,
                                     COMMIT as TENSOR_COMMIT, WAIT as TENSOR_WAIT)


async def start(dut):
    class MemoryPorts:
        def __getattr__(self, name):
            mapped='tma_'+name if name.startswith(('smem_req_','smem_rsp_')) else name
            return getattr(dut,mapped if hasattr(dut,mapped) else name)
    for name in ('cmd_vld_i','smem_a_req_rdy_i','smem_b_req_rdy_i','smem_wr_req_rdy_i',
                 'smem_a_rsp_vld_i','smem_b_rsp_vld_i','smem_wr_rsp_vld_i','perf_clear_i'):
        getattr(dut,name).value=0
    dut.completion_rdy_i.value=1
    return await Harness(MemoryPorts()).start()


@cocotb.test()
async def unified_copy_wait_then_tensor_compute(dut):
    h = await start(dut)
    source = bytes((index*13+5)&255 for index in range(256))
    write_bytes(h.gmem,0x12000,source)
    await h.bar(INIT,0x100,count=1)
    await h.bar(ARRIVE_EXPECT_TX,0x100,tx=256)
    r = await h.tma(LOAD_LINEAR,linear=0x12000,smem=0x22000,size=256,barrier=0x100,issuer=3)
    assert r['status']==0 and r['bytes']==256
    assert (await h.bar(TRY_WAIT,0x100,phase=0))['wait_complete']==1
    assert read_bytes(h.smem,0x22000,256)==source

    # Real data dependency: fill Tensor operands using TMA, explicitly acquire
    # the barrier, then execute the existing arithmetic path and validate FP32.
    a = pack_fp16([1.0]*16).to_bytes(32,'little')*64
    b = b''.join(pack_fp16([float(col+1)]*16).to_bytes(32,'little') for col in range(8))
    write_bytes(h.gmem,0x30000,a+b)
    await h.bar(ARRIVE_EXPECT_TX,0x100,tx=len(a)+len(b))
    for source_addr,dest,payload in ((0x30000,0x1000,a),(0x30800,0x3000,b)):
        assert (await h.tma(LOAD_LINEAR,linear=source_addr,smem=dest,size=len(payload),barrier=0x100))['status']==0
    assert (await h.bar(TRY_WAIT,0x100,phase=1))['wait_complete']==1

    class Words:
        def __getitem__(self,addr):
            return int.from_bytes(read_bytes(h.smem,addr,32),'little')
        def get(self,addr,default=0):
            return self[addr]
        def __setitem__(self,addr,value):
            write_bytes(h.smem,addr,value.to_bytes(32,'little'))
    memory=Words()
    cocotb.start_soon(smem_model(dut,memory,random.Random(20260813)))
    await issue(dut,MMA,0x900,a=0x1000,b=0x3000)
    await issue(dut,STORE,0x901,dst=0x8000)
    for row in range(64):
        assert memory[0x8000+row*32]==expected_row(1)


@cocotb.test()
async def unified_issuers_backpressure_and_tensor_wait(dut):
    h=await start(dut)
    data=bytes(range(256));write_bytes(h.smem,0x1000,data);write_bytes(h.gmem,0x30000,data)
    for round_id in range(2):
        h.gate=lambda bus,r:not(bus=='gmem' and r['write'])
        copies=[]
        for i in range(9):
            copies.append(await h.tma(STORE_LINEAR,linear=0x50000+128*i,smem=0x1000,size=128,issuer=7,wait=False))
        blocked=cocotb.start_soon(h.tma(STORE_LINEAR,linear=0x51000,smem=0x1000,size=128,issuer=7,wait=False))
        await h.tick(15)
        assert int(dut.tma_cmd_vld_i.value) and not int(dut.tma_cmd_rdy_o.value)
        # Tensor control proceeds despite stalled TMA. Its watermark contains
        # no TMA work; TMA group completion remains the caller's responsibility.
        commit=await issue(dut,TENSOR_COMMIT,0x900+2*round_id)
        await issue(dut,TENSOR_WAIT,0x901+2*round_id,token=commit[3])
        assert not blocked.done()
        h.gate=lambda bus,r:True
        copies.append(await blocked)
        for tag in copies:
            assert (await h.result('tma',tag))['status']==0
        await h.bar(INIT,0x100,count=1)
        await h.bar(ARRIVE_EXPECT_TX,0x100,tx=256)
        assert (await h.tma(LOAD_LINEAR,linear=0x30000,smem=0x40000,size=256,barrier=0x100,issuer=3))['status']==0
        assert (await h.bar(TRY_WAIT,0x100,phase=0))['wait_complete']==1
        assert read_bytes(h.smem,0x40000,256)==data
        await h.tma(COMMIT,issuer=7)
        assert (await h.tma(WAIT_GROUP,issuer=7))['status']==0
