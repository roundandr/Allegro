"""Public byte endpoint against a byte dictionary, not RTL address formulas."""
import random
import cocotb
from cocotb.triggers import Timer
from blackwell_backend_ref import reduce_value, SHARED


class SystemTest:
    def __init__(self,d):
        self.d=d;self.n=len(d.req_vld_i)
        self.capacity=(1824 if self.n==8 else 17)*128
        self.memory={};self.expected=[{} for _ in range(self.n)]
        self.next_tag=1;self.accepted=0;self.completed=0
        self.previous=[None]*self.n

    def command(self,addr,kind,data=0,mask=(1<<128)-1,dtype=2,op=0):
        tag=self.next_tag;self.next_tag+=1
        return (addr,tag,data,mask,kind,dtype,op)

    async def tick(self,reqs=None,ready=None):
        d=self.d;n=self.n;reqs=reqs or [None]*n
        ready=(1<<n)-1 if ready is None else ready
        d.clk.value=0
        d.req_vld_i.value=sum((r is not None)<<c for c,r in enumerate(reqs))
        for index,(name,width) in enumerate((('addr',32),('tag',16),('data',1024),('mask',128),('kind',2),('dtype',4),('op',4))):
            getattr(d,'req_'+name+'_i').value=sum((r[index] if r else 0)<<(c*width) for c,r in enumerate(reqs))
        d.rsp_rdy_i.value=ready
        await Timer(5,units='ns')
        rv=int(d.rsp_vld_o.value)
        for c in range(n):
            if rv>>c&1:
                got=((int(d.rsp_tag_o.value)>>(c*16))&65535,(int(d.rsp_error_o.value)>>c)&1,
                     (int(d.rsp_data_o.value)>>(c*1024))&((1<<1024)-1))
                if self.previous[c] is not None:assert got==self.previous[c], 'unstable response'
                assert got[0] in self.expected[c], ('unrecognized response',c,got[0])
                exp=self.expected[c][got[0]]
                assert got[1:]==exp,(c,got,exp)
                if ready>>c&1:
                    del self.expected[c][got[0]];self.completed+=1;self.previous[c]=None
                else:self.previous[c]=got
            else:assert self.previous[c] is None
        fire=int(d.req_rdy_o.value)&int(d.req_vld_i.value)
        for c,r in enumerate(reqs):
            if fire>>c&1:
                addr,tag,data,mask,kind,dtype,op=r
                bad=kind>2 or any(mask>>i&1 and addr+i>=self.capacity for i in range(128))
                if kind==2:
                    width=8 if dtype==4 else 4
                    bad|=(addr%width!=0 or dtype not in SHARED.get(op,set()) or
                          any((mask>>i)&((1<<width)-1) not in (0,(1<<width)-1) for i in range(0,128,width)))
                result=0
                if not bad:
                    if kind==0:
                        result=sum(self.memory.get(addr+i,0)<<(i*8) for i in range(128) if mask>>i&1)
                    elif kind==1:
                        for i in range(128):
                            if mask>>i&1:self.memory[addr+i]=(data>>(i*8))&255
                    elif kind==2:
                        for i in range(0,128,width):
                            if mask>>i&1:
                                old=int.from_bytes(bytes(self.memory.get(addr+i+j,0) for j in range(width)),'little')
                                value=reduce_value(old,data>>(i*8)&((1<<(width*8))-1),dtype,op)
                                for j in range(width):self.memory[addr+i+j]=value>>(j*8)&255
                assert tag not in self.expected[c]
                self.expected[c][tag]=(int(bad),result);self.accepted+=1
        assert not int(d.protocol_error_o.value)
        d.clk.value=1
        await Timer(5,units='ns')
        return fire

    async def send(self,req,client=0):
        args=[None]*self.n;args[client]=req
        for _ in range(200):
            if (await self.tick(args))>>client&1:return
        assert False,'request timeout'

    async def drain(self):
        for _ in range(2000):
            await self.tick()
            if not any(self.expected):return
        assert False,'drain timeout'


@cocotb.test()
async def byte_masks_crossings_aliases_and_contention(d):
    t=SystemTest(d);rng=random.Random(583);full=(1<<128)-1
    d.rst_n.value=0
    for _ in range(3):await t.tick()
    d.rst_n.value=1
    # All clients share this backing store. Explicit completion establishes the
    # cross-client publication boundary for initialization.
    for row in range(16):await t.send(t.command(row*128,1,rng.getrandbits(1024)))
    await t.send(t.command(t.capacity-128,1,rng.getrandbits(1024)))
    await t.drain()
    # Every possible byte displacement and the complete two-line reassembly.
    # Read is queued immediately behind the overlapping write, no software wait.
    for offset in range(128):
        await t.send(t.command(offset,1,rng.getrandbits(1024),rng.getrandbits(128)))
        await t.send(t.command(offset,0,mask=rng.getrandbits(128)))
    await t.drain()
    # Out-of-range active byte faults the entire write. Unselected bytes beyond
    # the end are legal; high address bits must never alias the memory's start.
    for addr,mask in ((t.capacity-4,full),(0xfffffff0,full),(t.capacity-4,15),(0xffffffff,0)):
        await t.send(t.command(addr,1,rng.getrandbits(1024),mask))
        await t.send(t.command(addr,0,mask=mask))
    await t.drain()
    await t.send(t.command(t.capacity-128,0));await t.drain()
    # Arbitrary offsets that preserve element alignment, including a 128 B
    # reduction vector crossing a line. Invalid masks cannot partially modify.
    for op,types in SHARED.items():
        for dtype in types:
            width=8 if dtype==4 else 4
            mask=sum(((1<<width)-1)<<i for i in range(0,128,width*2))
            await t.send(t.command(128-width,2,rng.getrandbits(1024),mask,dtype,op))
            await t.send(t.command(128-width,0))
    await t.send(t.command(124,2,0,15,4,0))
    await t.send(t.command(124,0));await t.drain()
    # Each client has a disjoint byte range, permitting an independent serial
    # program reference while requests/responses interleave unpredictably.
    reqs=[None]*t.n
    for cycle in range(2500):
        for c in range(t.n):
            if reqs[c] is None:
                base=c*256+rng.randrange(64)
                kind=rng.randrange(3)
                if kind==2:
                    base &= ~3
                    reqs[c]=t.command(base,2,rng.getrandbits(1024),full,2,rng.randrange(8))
                else:reqs[c]=t.command(base,kind,rng.getrandbits(1024),rng.getrandbits(128))
        fire=await t.tick(reqs,ready=rng.getrandbits(t.n))
        for c in range(t.n):
            if fire>>c&1:reqs[c]=None
    # Withdraw never-accepted requests; accepted work must still drain under full
    # credits, including reductions whose source client stopped submitting.
    await t.drain()
    # Concurrent reductions to the SAME word commute. No read until all real
    # write acknowledgements arrive; a plain RMW backend loses these increments.
    await t.send(t.command(0,1,0,15));await t.drain()
    for _ in range(30):
        reqs=[t.command(0,2,1,15) for _ in range(t.n)]
        while any(reqs):
            fire=await t.tick(reqs)
            for c in range(t.n):
                if fire>>c&1:reqs[c]=None
    await t.drain()
    await t.send(t.command(0,0,mask=15),client=t.n-1);await t.drain()


@cocotb.test()
async def aligned_4096_cycle_read_and_write_bandwidth(d):
    t=SystemTest(d);full=(1<<128)-1
    d.rst_n.value=0
    for _ in range(3):await t.tick()
    d.rst_n.value=1
    await t.send(t.command(0,1,0));await t.drain()
    # Requests remain in flight. Disjoint writes rotate through eight lines so
    # a single address dependency cannot conceal the available port bandwidth.
    reqs=[None]*t.n;reads=writes=0;readfire=writefire=0
    for cycle in range(64+4096):
        if reqs[0] is None:reqs[0]=t.command(0,0)
        if reqs[1] is None:
            reqs[1]=t.command(128*(1+writes%8),1,writes,full)
        fire=await t.tick(reqs)
        if fire&1:
            reqs[0]=None;reads+=1
            if cycle>=64:readfire+=1
        if fire&2:
            reqs[1]=None;writes+=1
            if cycle>=64:writefire+=1
    await t.drain()
    # Three-entry corner deliberately undersizes the latency-hiding window.
    threshold=.9 if t.n==8 else .4
    assert min(readfire,writefire)>=4096*threshold,(readfire,writefire)
    d._log.info('Byte endpoint steady %d cycles: read %.2f B/cycle, write %.2f B/cycle',4096,readfire*128/4096,writefire*128/4096)
