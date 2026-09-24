"""Physical capacity, byte enables, 1R1W collisions and elastic responses."""
import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def capacity_masks_conflicts_and_bandwidth(d):
    banks = len(d.rd_mask_i)
    width = len(d.wr_data_i)//banks
    aw = len(d.rd_addr_i)//banks
    depth = 128 if banks == 128 else 1824
    wordmask = (1 << width)-1
    rng=random.Random(917)
    memory={}
    rd_pending=wr_pending=None
    def addresses(row):
        return sum(row << (b*aw) for b in range(banks))
    async def tick(read=None, write=None, read_ready=True, write_ready=True):
        nonlocal rd_pending,wr_pending
        d.clk.value=0
        d.rd_vld_i.value=read is not None
        d.wr_vld_i.value=write is not None
        d.rd_mask_i.value=(1<<banks)-1
        d.rd_addr_i.value=addresses(read[0]) if read else 0
        d.rd_tag_i.value=read[1] if read else 0
        d.wr_addr_i.value=addresses(write[0]) if write else 0
        d.wr_tag_i.value=write[1] if write else 0
        d.wr_data_i.value=write[2] if write else 0
        d.wr_mask_i.value=write[3] if write else 0
        d.rd_rsp_rdy_i.value=read_ready
        d.wr_rsp_rdy_i.value=write_ready
        await Timer(5,units='ns')
        if rd_pending is not None:
            assert int(d.rd_rsp_vld_o.value)
            assert (int(d.rd_tag_o.value), int(d.rd_error_o.value), int(d.rd_data_o.value))==rd_pending
            if read_ready: rd_pending=None
        else: assert not int(d.rd_rsp_vld_o.value)
        if wr_pending is not None:
            assert int(d.wr_rsp_vld_o.value)
            assert (int(d.wr_tag_o.value),int(d.wr_error_o.value))==wr_pending
            if write_ready: wr_pending=None
        else: assert not int(d.wr_rsp_vld_o.value)
        rf=read is not None and int(d.rd_rdy_o.value)
        wf=write is not None and int(d.wr_rdy_o.value)
        if rf:
            row,tag=read
            value=sum(memory[(b,row)] << (b*width) for b in range(banks)) if row<depth else 0
            rd_pending=(tag,int(row>=depth),value)
        if wf:
            row,tag,data,mask=write
            wr_pending=(tag,int(row>=depth))
            if row<depth:
                for b in range(banks):
                    val=memory.get((b,row),0)
                    for byte in range(width//8):
                        index=b*width//8+byte
                        if (mask>>index)&1:
                            val=(val & ~(255<<(byte*8))) | (((data>>(index*8))&255)<<(byte*8))
                    memory[(b,row)]=val
        d.clk.value=1
        await Timer(5,units='ns')
        return rf,wf
    d.rst_n.value=0
    for _ in range(3): await tick()
    d.rst_n.value=1
    fullmask=(1<<(banks*width//8))-1
    # Every physical word, including the final column/lane and full SMEM depth.
    for row in range(depth):
        data=sum(((row<<16)|b) << (b*width) for b in range(banks))
        _,wf=await tick(write=(row,row,data,fullmask))
        assert wf
    for row in range(depth):
        rf,_=await tick(read=(row,row)); assert rf
    await tick()
    # Masked writes collide with reads. The reference samples pre-write data.
    for n in range(500):
        row=rng.randrange(depth)
        await tick(read=(row,n),write=(row,n,rng.getrandbits(banks*width),rng.getrandbits(banks*width//8)),
                   read_ready=rng.randrange(4)!=0,write_ready=rng.randrange(4)!=0)
    for _ in range(3): await tick()
    if depth != 1<<aw:
        await tick(read=(depth,65535),write=(depth,65535,0,fullmask))
        await tick()
    reads=writes=0
    for n in range(4096):
        rf,wf=await tick(read=(n%depth,n),write=((n+1)%depth,n,0,fullmask))
        reads+=rf; writes+=wf
    await tick()
    assert reads==writes==4096
    sentinel=sum(0xdeadcafe << (b*width) for b in range(banks))
    await tick(write=(depth-1,13,sentinel,fullmask)); await tick()
    # Reset control state must not erase or require resetting SRAM contents.
    d.rst_n.value=0
    for _ in range(3): await tick()
    d.rst_n.value=1
    await tick(read=(depth-1,12)); await tick()
    d._log.info('Physical SRAM: %d bytes; steady read/write %d bytes/cycle each',
                banks*depth*width//8,banks*width//8)
