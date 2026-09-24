"""Independent byte memory, client credit isolation, real atomic contention."""
from collections import deque
import random

import cocotb
from cocotb.triggers import Timer

from blackwell_backend_ref import reduce_value, SHARED


class MemoryTest:
    def __init__(self, d):
        self.d = d
        self.clients = len(d.rd_vld_i)
        self.lines = 1824 if self.clients == 8 else 17
        self.memory = {}
        self.reads = [deque() for _ in range(self.clients)]
        self.writes = [deque() for _ in range(self.clients)]
        self.atomic = None
        self.cycles = self.nr = self.nw = 0

    async def tick(self, reads=None, writes=None, atomic=None, rr=None, wr=None, ar=True):
        d, n = self.d, self.clients
        reads = reads or [None]*n
        writes = writes or [None]*n
        rr = (1 << n)-1 if rr is None else rr
        wr = (1 << n)-1 if wr is None else wr
        d.clk.value = 0
        d.rd_vld_i.value = sum((r is not None) << c for c, r in enumerate(reads))
        d.wr_vld_i.value = sum((r is not None) << c for c, r in enumerate(writes))
        for name, width, values in (
            ('rd_addr_i',32,[r[0] if r else 0 for r in reads]),
            ('rd_tag_i',16,[r[1] if r else 0 for r in reads]),
            ('wr_addr_i',32,[r[0] if r else 0 for r in writes]),
            ('wr_tag_i',16,[r[1] if r else 0 for r in writes]),
            ('wr_data_i',1024,[r[2] if r else 0 for r in writes]),
            ('wr_mask_i',128,[r[3] if r else 0 for r in writes]),
        ):
            getattr(d,name).value = sum(v << (c*width) for c,v in enumerate(values))
        d.rd_rsp_rdy_i.value = rr; d.wr_rsp_rdy_i.value = wr
        d.atom_vld_i.value = atomic is not None
        for name,value in zip(('addr','tag','data','mask','dtype','op'), atomic or (0,0,0,0,0,0)):
            getattr(d,'atom_'+name+'_i').value = value
        d.atom_rsp_rdy_i.value = ar
        await Timer(5,units='ns')
        rv, wv = int(d.rd_rsp_vld_o.value), int(d.wr_rsp_vld_o.value)
        for c in range(n):
            if rv >> c & 1:
                assert self.reads[c], ('unexpected read response',c)
                expected = self.reads[c][0]
                actual = ((int(d.rd_tag_o.value)>>(c*16))&65535,
                          (int(d.rd_error_o.value)>>c)&1,
                          (int(d.rd_data_o.value)>>(c*1024))&((1<<1024)-1))
                assert actual == expected, (c,actual[:2],expected[:2])
                if rr >> c & 1: self.reads[c].popleft()
            if wv >> c & 1:
                assert self.writes[c], ('unexpected write response',c)
                assert ((int(d.wr_tag_o.value)>>(c*16))&65535,
                         (int(d.wr_error_o.value)>>c)&1) == self.writes[c][0]
                if wr >> c & 1: self.writes[c].popleft()
        if int(d.atom_rsp_vld_o.value):
            assert self.atomic == (int(d.atom_tag_o.value),int(d.atom_error_o.value))
            if ar: self.atomic = None
        rf = int(d.rd_rdy_o.value) & int(d.rd_vld_i.value)
        wf = int(d.wr_rdy_o.value) & int(d.wr_vld_i.value)
        af = atomic is not None and int(d.atom_rdy_o.value)
        assert rf.bit_count() <= 1 and wf.bit_count() <= 1
        for c,r in enumerate(reads):
            if rf >> c & 1:
                addr,tag = r; bad = int(addr%128 != 0 or addr//128 >= self.lines)
                value = 0 if bad else int.from_bytes(bytes(self.memory.get(addr+i,0) for i in range(128)),'little')
                self.reads[c].append((tag,bad,value))
        for c,r in enumerate(writes):
            if wf >> c & 1:
                addr,tag,data,mask = r; bad = int(addr%128 != 0 or addr//128 >= self.lines)
                self.writes[c].append((tag,bad))
                if not bad:
                    for i in range(128):
                        if mask>>i&1: self.memory[addr+i] = data>>(i*8)&255
        if af:
            assert self.atomic is None
            addr,tag,data,mask,dtype,op = atomic
            width = 8 if dtype == 4 else 4
            bad = (addr%128 != 0 or addr//128 >= self.lines or dtype not in SHARED.get(op,set()) or
                   any((mask>>i)&((1<<width)-1) not in (0,(1<<width)-1) for i in range(0,128,width)))
            self.atomic = (tag,int(bad))
            if not bad:
                for i in range(0,128,width):
                    if mask>>i&1:
                        old = int.from_bytes(bytes(self.memory.get(addr+i+j,0) for j in range(width)),'little')
                        val = reduce_value(old,data>>(8*i)&((1<<(8*width))-1),dtype,op)
                        for j in range(width): self.memory[addr+i+j] = val>>(8*j)&255
        self.nr += rf.bit_count(); self.nw += wf.bit_count(); self.cycles += 1
        d.clk.value = 1
        await Timer(5,units='ns')
        return rf,wf,af

    async def drain(self):
        for _ in range(100):
            await self.tick()
            if not any(self.reads+self.writes) and self.atomic is None: return
        assert False, 'response drain timed out'


@cocotb.test()
async def sharing_atomicity_credits_and_steady_bandwidth(d):
    t=MemoryTest(d); n=t.clients; full=(1<<128)-1; rng=random.Random(2317)
    d.rst_n.value=0
    for _ in range(3): await t.tick()
    d.rst_n.value=1
    # Initialize every byte read by the test. SRAM reset must not initialize it.
    for row in list(range(16))+[t.lines-1]:
        req=(row*128,row,rng.getrandbits(1024),full)
        while True:
            _,f,_=await t.tick(writes=[req]+[None]*(n-1))
            if f: break
    await t.drain()
    for addr in (t.lines*128,0xffff_ff80,1):
        await t.tick(reads=[(addr,21)]+[None]*(n-1),writes=[(addr,22,0,full)]+[None]*(n-1))
    await t.drain()
    # One stopped consumer fills only its own reserved credits.
    serviced=0
    for cycle in range(60):
        reads=[(0,cycle),(128,cycle)]+[None]*(n-2)
        rf,_,_=await t.tick(reads=reads,rr=((1<<n)-1)^1)
        serviced += (rf>>1)&1
    assert serviced>45, serviced
    await t.drain()
    # All shared-memory reduction legal pairs, extreme values and noncontiguous
    # whole-element masks. Contending loads must observe the complete update.
    tag=100
    for op,types in SHARED.items():
        for dtype in types:
            width=8 if dtype==4 else 4
            mask=sum(((1<<width)-1)<<i for i in range(0,128,width*2))
            atom=(0,tag,rng.getrandbits(1024),mask,dtype,op)
            while not (await t.tick(atomic=atom))[2]: pass
            tag+=1
            for _ in range(15): await t.tick(reads=[(0,tag),(128,tag)]+[None]*(n-2))
            await t.drain()
    # Rejected atomics cannot partially update storage.
    for dtype,op,mask,addr in ((2,0,1,0),(4,0,15,0),(7,0,full,0),(4,1,full,0),(2,0,full,1)):
        atom=(addr,tag,0,mask,dtype,op);tag+=1
        while not (await t.tick(atomic=atom))[2]: pass
        await t.drain()
        await t.tick(reads=[(0,tag)]+[None]*(n-1));await t.drain()
    # Persistent randomized contenders, with per-client response backpressure.
    reads=[None]*n;writes=[None]*n
    for cycle in range(1400):
        for c in range(n):
            if reads[c] is None: reads[c]=(rng.randrange(16)*128,tag&65535);tag+=1
            if writes[c] is None: writes[c]=(rng.randrange(16)*128,tag&65535,rng.getrandbits(1024),rng.getrandbits(128));tag+=1
        rf,wf,_=await t.tick(reads,writes,rr=rng.getrandbits(n),wr=rng.getrandbits(n))
        for c in range(n):
            if rf>>c&1:reads[c]=None
            if wf>>c&1:writes[c]=None
    await t.drain()
    # Two actual physical ports, 4096 steady cycles after warmup.
    for cycle in range(32+4096):
        rf,wf,_=await t.tick(reads=[(0,cycle)]+[None]*(n-1),
                            writes=[(128,cycle,cycle,full)]+[None]*(n-1))
        if cycle>=32: assert rf==wf==1
    await t.drain()
    d._log.info('Shared SMEM: 128 B/cycle read + 128 B/cycle write for 4096 steady cycles; %d clients',n)
