"""TMA/mbarrier using actual RTL SMEM; Python models only the GMEM endpoint."""
import cocotb
from cocotb.triggers import RisingEdge, Timer
from test_tma_mbarrier import (Harness, write_bytes, read_bytes, TensorDescriptor,
    INIT, ARRIVE_EXPECT_TX, TRY_WAIT, INVAL, LOAD_LINEAR, STORE_LINEAR,
    LOAD_TENSOR, STORE_TENSOR, COMMIT, WAIT_GROUP)


async def memory(h,addr,data=None,size=128):
    tag=h.next_tag;h.next_tag+=1
    if isinstance(data,bytes):data=int.from_bytes(data,'little')
    for field,value in dict(addr=addr,tag=tag,data=data or 0,mask=(1<<size)-1,kind=int(data is not None),dtype=2,op=0).items():
        h.set('debug_req_'+field+'_i',value)
    h.set('debug_req_vld_i',1)
    for _ in range(10000):
        await RisingEdge(h.d.clk)
        if h.get('debug_req_rdy_o'):
            await Timer(2,units='ps');h.set('debug_req_vld_i',0);break
    else:assert False,'generic SMEM request timeout'
    for _ in range(10000):
        if tag in h.debug_responses:
            status,value=h.debug_responses.pop(tag)
            assert status==0,(addr,tag,status)
            return value.to_bytes(128,'little')[:size]
        await h.tick()
    assert False,'generic SMEM response timeout'


@cocotb.test()
async def real_smem_tma_barrier_and_bulk_completion(dut):
    h=await Harness(dut,real_smem=True).start()
    payload=bytes((i*31+17)%256 for i in range(512))
    write_bytes(h.gmem,0x100000,payload)
    bar=0x100
    assert (await h.bar(INIT,bar,count=1))['status']==0
    assert (await h.bar(ARRIVE_EXPECT_TX,bar,tx=len(payload)))['status']==0
    # Stop the actual SMEM response path; completing GMEM reads alone must not
    # complete a TMA load or its byte-count barrier.
    h.set('real_smem_ack_enable_i',0)
    tag=await h.tma(LOAD_LINEAR,linear=0x100000,smem=0x1000,size=len(payload),barrier=bar,wait=False)
    await h.tick(120);assert tag not in h.responses['tma']
    h.set('real_smem_ack_enable_i',1)
    result=await h.result('tma',tag)
    assert result['status']==0 and result['bytes']==len(payload)
    assert (await h.bar(TRY_WAIT,bar,phase=0))['wait_complete']
    actual=b''
    for offset in range(0,len(payload),128):actual+=await memory(h,0x1000+offset)
    assert actual==payload
    # Source reads complete before the delayed GMEM write acknowledgement.
    h.gate=lambda bus,req:not(bus=='gmem' and req['write'])
    tag=await h.tma(STORE_LINEAR,linear=0x200000,smem=0x1000,size=len(payload),issuer=7,wait=False)
    assert (await h.tma(COMMIT,issuer=7))['status']==0
    assert (await h.tma(WAIT_GROUP,issuer=7,read=True))['status']==0
    assert tag not in h.responses['tma']
    full=await h.tma(WAIT_GROUP,issuer=7,wait=False)
    await h.tick(40);assert full not in h.responses['tma']
    h.gate=lambda bus,req:True
    assert (await h.result('tma',tag))['status']==0
    assert (await h.result('tma',full))['status']==0
    assert read_bytes(h.gmem,0x200000,len(payload))==payload
    assert not h.get('smem_protocol_error_o')


@cocotb.test()
async def real_smem_reduction_swizzle_and_store(dut):
    h=await Harness(dut,real_smem=True).start();bar=0x100
    await memory(h,0x1000,(3).to_bytes(4,'little')*32)
    await memory(h,0x2000,(5).to_bytes(4,'little')*32)
    await h.bar(INIT,bar,count=1);await h.bar(ARRIVE_EXPECT_TX,bar,tx=128)
    result=await h.tma(10,smem=0x1000,linear=0x2000,size=128,barrier=bar,dtype=2,reduce_op=0)
    assert result['status']==0 and result['bytes']==128
    assert (await h.bar(TRY_WAIT,bar,phase=0))['wait_complete']
    assert await memory(h,0x2000)==(8).to_bytes(4,'little')*32
    await h.bar(INVAL,bar)
    desc=TensorDescriptor(2,2,0x300000,(64,4),(2,128),(32,4),(1,1),swizzle=2)
    data=bytes((i*13+7)%256 for i in range(512));write_bytes(h.gmem,desc.base,data)
    ptr=0x80000;write_bytes(h.gmem,ptr,desc.encode())
    expected=desc.load(h.gmem,(0,0));total=len(expected)
    await h.bar(INIT,bar,count=1);await h.bar(ARRIVE_EXPECT_TX,bar,tx=total)
    result=await h.tma(LOAD_TENSOR,desc=ptr,coords=(0,0),smem=0x4000,barrier=bar)
    assert result['status']==0 and result['bytes']==total
    assert (await h.bar(TRY_WAIT,bar,phase=0))['wait_complete']
    # Read each needed physical line through the generic client of the same SRAM.
    lines={}
    for i in range(total):
        address=desc.smem_address(0x4000,i,0)
        if address//128 not in lines:lines[address//128]=await memory(h,address&~127)
        assert lines[address//128][address%128]==expected[i]
    # A tensor store must read the swizzled physical data and undo its layout.
    write_bytes(h.gmem,desc.base,bytes(512))
    result=await h.tma(STORE_TENSOR,desc=ptr,coords=(0,0),smem=0x4000)
    assert result['status']==0
    for row in range(4):assert read_bytes(h.gmem,desc.base+row*128,64)==data[row*128:row*128+64]
    assert not h.get('smem_protocol_error_o')
