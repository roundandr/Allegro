"""NVIDIA semantic acceptance tests, independent memory timing and golden vectors."""
import os
import random
import json
from pathlib import Path
from dataclasses import replace

from blackwell_backend_ref import apply_write

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from tma_mbarrier_ref import (TensorDescriptor, MBarrierModel, swizzle_address,
                            TILE, IM2COL, IM2COL_W, IM2COL_W128, IM2COL_NO_OFFS, GATHER4, SCATTER4)

LOAD_TENSOR, STORE_TENSOR, LOAD_LINEAR, STORE_LINEAR, DESC_INV, COMMIT, WAIT_GROUP = range(7)
INIT, ARRIVE, EXPECT_TX, ARRIVE_EXPECT_TX, TRY_WAIT, INVAL, TEST_WAIT, COMPLETE_TX, DROP, DROP_EXPECT_TX, PENDING_COUNT, CHECK_LAYOUT = range(12)
CP_ASYNC_ARRIVE, REPORT, PENDING_INC = 12, 29, 30
MBAR, BULK = range(2)


def write_bytes(memory, addr, data):
    memory.update((addr+i, b) for i, b in enumerate(data))


def read_bytes(memory, addr, size):
    return bytes(memory.get(addr+i, 0) for i in range(size))


def pack_coords(coords):
    return sum((x & 0xffffffff) << (32*d) for d, x in enumerate(coords))


def strides(sizes, elem):
    result = [elem]
    for d in range(1, len(sizes)):
        result.append((result[-1]*sizes[d-1] + 15)//16*16)
    return tuple(result)


class Harness:
    def __init__(self, dut, real_smem=False):
        self.d = dut
        self.real_smem = real_smem
        self.debug_responses = {}
        self.rng = random.Random(int(os.getenv('COCOTB_RANDOM_SEED', '20260813')))
        self.gmem, self.smem = {}, {}
        self.pending = {'gmem': [], 'smem': []}
        self.active = {'gmem': None, 'smem': None}
        self.responses = {'tma': {}, 'bar': {}, 'report': {}}
        self.async_responses = {}
        self.order_pending = []
        self.order_active = None
        self.tma_order_pending = []
        self.tma_order_active = None
        self.tma_order_requests = []
        self.tma_order_gate = lambda r: True
        self.tma_order_error = lambda r: 0
        self.order_requests = []
        self.order_gate = lambda r: True
        self.order_error = lambda r: 0
        self.seen = {'tma': set(), 'bar': set(), 'report': set()}
        self.next_tag = 1
        self.cycle = 0
        self.gate = lambda bus, request: True
        self.error = lambda bus, request: False
        self.requests, self.acks = [], []
        self.stalled = {}
        self.random_rsp_backpressure = True
        self.multimem = [{}, {}]
        self.target_gate = lambda target, request: True
        self.before_atomic = lambda bus, memory, request: None

    def set(self, name, value):
        getattr(self.d, name).value = value

    def get(self, name):
        if self.real_smem and name == 'smem_req_rdy_i': name = 'real_smem_req_rdy_o'
        return int(getattr(self.d, name).value)

    async def start(self):
        cocotb.start_soon(Clock(self.d.clk, 10, units='ns').start())
        self.set('rst_n', 0)
        if self.real_smem:
            self.set('real_smem_ack_enable_i',1)
            self.set('debug_req_vld_i',0)
            self.set('debug_rsp_rdy_i',1)
        self.set('tc_arrive_vld_i', 0)
        self.set('tc_arrive_rsp_rdy_i', 1)
        if hasattr(self.d, 'tc_control_enable_i'):
            for signal in ('tc_control_enable_i','register_vld_i','complete_vld_i','commit_vld_i'):
                self.set(signal, 0)
            self.set('event_rdy_i', 1)
        for name in ('tma_cmd_vld_i', 'bar_cmd_vld_i', 'gmem_rsp_vld_i', 'smem_rsp_vld_i',
                     'gmem_req_rdy_i', 'smem_req_rdy_i', 'tma_rsp_rdy_i', 'bar_rsp_rdy_i',
                     'async_req_vld_i','async_cpl_req_vld_i','report_req_vld_i','bar_order_req_rdy_i','bar_order_rsp_vld_i', 'tma_order_req_rdy_i', 'tma_order_rsp_vld_i'):
            self.set(name, 0)
        self.set('async_rsp_rdy_i',1)
        self.set('report_rsp_rdy_i',1)
        for _ in range(6):
            await RisingEdge(self.d.clk)
        await Timer(1, units='ps')
        self.set('rst_n', 1)
        cocotb.start_soon(self.run())
        await self.tick(2)
        return self

    async def tick(self, n=1):
        for _ in range(n):
            await RisingEdge(self.d.clk)
            await Timer(2, units='ps')

    async def run(self):
        while True:
            await RisingEdge(self.d.clk)
            self.cycle += 1
            if self.real_smem and self.get('debug_rsp_vld_o') and self.get('debug_rsp_rdy_i'):
                self.debug_responses[self.get('debug_rsp_tag_o')] = (self.get('debug_rsp_error_o'),self.get('debug_rsp_data_o'))
            for channel, fields in (
                ('gmem_req', ('write_o','addr_o','data_o','mask_o','id_o','kind_o','dtype_o','reduce_op_o','multimem_o','atomic128_o','issuer_o','seq_o','scope_o','proxy_o','cache_hint_o','cache_policy_o','l2_promotion_o')),
                ('smem_req', ('write_o','addr_o','data_o','mask_o','id_o','kind_o','dtype_o','reduce_op_o','multimem_o','atomic128_o','issuer_o','seq_o','scope_o','proxy_o','cache_hint_o','cache_policy_o','l2_promotion_o')),
                ('tma_rsp', ('tag_o','issuer_o','status_o','bytes_o')),
                ('tma_order_req', ('id_o','issuer_o','seq_o','kind_o','scope_o','from_proxy_o','to_proxy_o','addr_o','bytes_o')),
                ('bar_order_req', ('id_o','issuer_o','seq_o','kind_o','scope_o','from_proxy_o','to_proxy_o','addr_o','bytes_o')),
                ('bar_rsp', ('tag_o','status_o','phase_o','locked_o','state_o','wait_complete_o','value_o','predicate_o','report_o','report_predicate_o'))):
                valid = self.get(channel+'_vld_o')
                ready = self.get(channel+'_rdy_i')
                payload = tuple(self.get(channel+'_'+f) for f in fields)
                if channel in self.stalled:
                    assert valid and payload == self.stalled[channel], ('unstable channel', channel)
                if valid and not ready:
                    self.stalled[channel] = payload
                else:
                    self.stalled.pop(channel, None)
            if self.get('bar_order_rsp_vld_i') and self.get('bar_order_rsp_rdy_o'):
                self.order_active = None
            if self.get('bar_order_req_vld_o') and self.get('bar_order_req_rdy_i'):
                r = {k:self.get('bar_order_req_'+k+'_o') for k in
                     ('id','issuer','seq','kind','scope','from_proxy','to_proxy','addr','bytes')}
                r['due'] = self.cycle + self.rng.randint(2, 9)
                r['status'] = self.order_error(r)
                self.order_requests.append((r.copy(), self.cycle))
                self.order_pending.append(r)
            if self.get('tma_order_rsp_vld_i') and self.get('tma_order_rsp_rdy_o'):
                self.tma_order_active = None
            if self.get('tma_order_req_vld_o') and self.get('tma_order_req_rdy_i'):
                r = {k:self.get('tma_order_req_'+k+'_o') for k in
                     ('id','issuer','seq','kind','scope','from_proxy','to_proxy','addr','bytes')}
                r['due'] = self.cycle + self.rng.randint(2, 9)
                r['status'] = self.tma_order_error(r)
                self.tma_order_requests.append((r.copy(), self.cycle))
                self.tma_order_pending.append(r)
            if self.get('async_rsp_vld_o') and self.get('async_rsp_rdy_i'):
                key = (self.get('async_rsp_issuer_o'), self.get('async_rsp_seq_o'))
                self.async_responses.setdefault(key, []).append(self.get('async_rsp_status_o'))
            for bus, width, memory in (('gmem',128,self.gmem), ('smem',32,self.smem)):
                if self.real_smem and bus == 'smem': continue
                if self.get(bus+'_rsp_vld_i') and self.get(bus+'_rsp_rdy_o'):
                    self.acks.append((bus, self.active[bus], self.cycle))
                    self.active[bus] = None
                if self.get(bus+'_req_vld_o') and self.get(bus+'_req_rdy_i'):
                    r = {k: self.get(bus+'_req_'+k+'_o') for k in ('write','addr','data','mask','id')}
                    r.update({k: self.get(bus+'_req_'+k+'_o') for k in ('kind','dtype','reduce_op','multimem','atomic128','issuer','seq','scope','proxy','cache_hint','cache_policy','l2_promotion')})
                    r['status'] = int(self.error(bus, r))
                    r['due'] = self.cycle + self.rng.randint(1, 8)
                    self.requests.append((bus, r.copy(), self.cycle))
                    if r['write']:
                        if r['status'] == 0:
                            if r['multimem']:
                                r['targets'] = list(range(len(self.multimem)))
                            else:
                                if r['kind']==2:self.before_atomic(bus,memory,r)
                                apply_write(memory,r,width)
                        r['rsp_data'] = 0
                    else:
                        r['rsp_data'] = int.from_bytes(bytes(memory.get(r['addr']+b,0) if r['mask']>>b&1 else 0 for b in range(width)), 'little')
                    self.pending[bus].append(r)
            for channel in ('tma', 'bar', 'report'):
                if self.get(channel+'_rsp_vld_o') and self.get(channel+'_rsp_rdy_i'):
                    fields = ('tag','status','bytes','issuer') if channel == 'tma' else (
                        'tag','status','phase','locked','state','wait_complete','value','predicate','report','report_predicate')
                    r = {k:self.get(channel+'_rsp_'+k+'_o') for k in fields}
                    assert r['tag'] not in self.seen[channel], ('duplicate response',channel,r)
                    self.seen[channel].add(r['tag'])
                    self.responses[channel][r['tag']] = r
            await Timer(1, units='ps')
            if self.order_active is None:
                due = [r for r in self.order_pending if r['due'] <= self.cycle and self.order_gate(r)]
                if due:
                    self.order_active = self.rng.choice(due)
                    self.order_pending.remove(self.order_active)
            r = self.order_active
            self.set('bar_order_rsp_vld_i',int(r is not None))
            if r is not None:
                self.set('bar_order_rsp_id_i',r['id'])
                self.set('bar_order_rsp_status_i',r['status'])
            self.set('bar_order_req_rdy_i',int(self.rng.randrange(4) != 0))
            if self.tma_order_active is None:
                due = [r for r in self.tma_order_pending if r['due'] <= self.cycle and self.tma_order_gate(r)]
                if due:
                    self.tma_order_active = self.rng.choice(due)
                    self.tma_order_pending.remove(self.tma_order_active)
            r = self.tma_order_active
            self.set('tma_order_rsp_vld_i',int(r is not None))
            if r is not None:
                self.set('tma_order_rsp_id_i',r['id'])
                self.set('tma_order_rsp_status_i',r['status'])
            self.set('tma_order_req_rdy_i',int(self.rng.randrange(4) != 0))
            for bus in ('gmem','smem'):
                if self.real_smem and bus == 'smem': continue
                for pending in self.pending[bus]:
                    for target in list(pending.get('targets',[])):
                        if self.target_gate(target,pending):
                            if pending['kind']==2:self.before_atomic(bus,self.multimem[target],pending)
                            apply_write(self.multimem[target],pending,128)
                            pending['targets'].remove(target)
                if self.active[bus] is None:
                    candidates = [r for r in self.pending[bus] if r['due'] <= self.cycle and not r.get('targets') and self.gate(bus,r)]
                    if candidates:
                        r = self.rng.choice(candidates)
                        self.pending[bus].remove(r)
                        self.active[bus] = r
                r = self.active[bus]
                self.set(bus+'_rsp_vld_i', int(r is not None))
                if r is not None:
                    self.set(bus+'_rsp_data_i', r['rsp_data'])
                    self.set(bus+'_rsp_id_i', r['id'])
                    self.set(bus+'_rsp_status_i', r['status'])
                self.set(bus+'_req_rdy_i', int(self.rng.randrange(5) != 0))
            for channel in ('tma','bar'):
                self.set(channel+'_rsp_rdy_i', int(not self.random_rsp_backpressure or self.rng.randrange(4) != 0))

    async def command(self, channel, fields):
        tag = self.next_tag
        self.next_tag += 1
        fields['tag'] = tag
        for key, value in fields.items():
            self.set(channel+'_cmd_'+key+'_i', value)
        self.set(channel+'_cmd_vld_i', 1)
        for _ in range(100000):
            await RisingEdge(self.d.clk)
            if self.get(channel+'_cmd_rdy_o'):
                await Timer(2, units='ps')
                self.set(channel+'_cmd_vld_i', 0)
                return tag
        raise AssertionError(('issue timeout',channel,fields))

    async def result(self, channel, tag, timeout=200000):
        for _ in range(timeout):
            if tag in self.responses[channel]:
                return self.responses[channel].pop(tag)
            await self.tick()
        raise AssertionError(('response timeout', channel,tag))

    async def bar(self, op, address, count=0, tx=0, phase=0, state=None, hint=0, wait=True, layout=0, no_complete=False, conditional=False, report=0, issuer=0, seq=None, sem=None, scope=0, noinc=False):
        if op == REPORT:
            return await self.report(address, report, wait=wait)
        if sem is None:
            sem = 1 if op in (ARRIVE,ARRIVE_EXPECT_TX,DROP,DROP_EXPECT_TX) else 2 if op in (TRY_WAIT,TEST_WAIT) else 0
        tag = await self.command('bar',dict(opcode=op,addr=address,arrive_count=count,tx_bytes=tx,
            phase_token=phase,wait_parity=int(state is None),state=state or 0,time_hint=hint,layout=layout,no_complete=int(no_complete),
            conditional=int(conditional),report=report,issuer=issuer,seq=self.next_tag if seq is None else seq,
            sem=sem,scope=scope,noinc=int(noinc)))
        return await self.result('bar',tag) if wait else tag

    async def report(self, address, value, wait=True):
        tag = self.next_tag; self.next_tag += 1
        for k,v in dict(addr=address,value=value,tag=tag).items():
            self.set('report_req_'+k+'_i',v)
        self.set('report_req_vld_i',1)
        for _ in range(100000):
            await RisingEdge(self.d.clk)
            if self.get('report_req_rdy_o'):
                await Timer(2,units='ps'); self.set('report_req_vld_i',0); break
        else: raise AssertionError('report handshake timeout')
        return await self.result('report',tag) if wait else tag

    async def async_event(self, issuer, seq, complete=False, status=0, wait=True):
        channel = 'async_cpl' if complete else 'async'
        for k,v in dict(issuer=issuer,seq=seq,complete=int(complete),status=status).items():
            if k!='complete' or not complete:self.set(channel+'_req_'+k+'_i',v)
        self.set(channel+'_req_vld_i',1)
        for _ in range(100000):
            await RisingEdge(self.d.clk)
            if self.get(channel+'_req_rdy_o'):
                await Timer(2,units='ps'); self.set(channel+'_req_vld_i',0); break
        else: raise AssertionError('async registration handshake timeout')
        if wait:
            for _ in range(100000):
                if self.async_responses.get((issuer,seq)):
                    return self.async_responses[(issuer,seq)].pop(0)
                await self.tick()
            raise AssertionError('async registration response timeout')


    async def tma(self, op, *, desc=0, coords=(), smem=0, linear=0, size=0, barrier=0,
                  issuer=0, mode=TILE, offsets=(0,0,0), halo=0, woffset=0, completion=None,
                  multi=0, n=0, read=False, wait=True, **extra):
        if completion is None:
            completion = BULK if op in (STORE_LINEAR, STORE_TENSOR) else MBAR
        info = sum(x << (16*d) for d,x in enumerate(offsets)) | (halo << 48) | (woffset << 64)
        options = dict(seq=self.next_tag,dtype=0,reduce_op=0,multimem=0,cp_mask_enable=0,cp_mask=65535,ignore_oob=0,oob_start=0,oob_end=0,atomic128=0,sem=0,scope=0,cache_hint=0,cache_policy=0,map_shared=0,replace_field=0,replace_ord=0,replace_value=0,from_proxy=0,to_proxy=0,warp_converged=0)
        options.update(extra)
        tag = await self.command('tma',dict(opcode=op,desc_ptr=desc,coord=pack_coords(coords),
            smem_addr=smem,linear_addr=linear,linear_bytes=size,barrier_addr=barrier,
            issuer=issuer,mode=mode,im2col=info,completion=completion,multi_cta=multi,wait_n=n,wait_read=int(read),**options))
        return await self.result('tma',tag) if wait else tag

    async def tensor(self, descriptor, start, *, mode=TILE, offsets=(0,0,0), halo=0, woffset=0, store=False, smem=0x18000):
        address = 0x80000 + self.next_tag*128
        write_bytes(self.gmem,address,descriptor.encode())
        total = descriptor.byte_count(mode,halo)
        if store:
            payload = bytes((i*31+7)%256 for i in range(total))
            for i,b in enumerate(payload):
                self.smem[descriptor.smem_address(smem,i,mode)] = b
            expected = descriptor.store(self.gmem,start,payload,mode=mode,offsets=offsets,halo=halo,w_offset=woffset)
        else:
            expected = descriptor.load(self.gmem,start,mode=mode,offsets=offsets,halo=halo,w_offset=woffset)
            # Barrier address zero is a valid shared-memory address.
            assert (await self.bar(INIT,0,count=1))['status'] == 0
            assert (await self.bar(ARRIVE_EXPECT_TX,0,tx=total))['status'] == 0
        r = await self.tma(STORE_TENSOR if store else LOAD_TENSOR,desc=address,coords=start,smem=smem,
                           mode=mode,offsets=offsets,halo=halo,woffset=woffset)
        assert r['status'] == 0 and r['bytes'] == total, (descriptor,mode,r)
        if store:
            assert self.gmem == expected
        else:
            actual = bytes(self.smem.get(descriptor.smem_address(smem,i,mode),0) for i in range(total))
            assert actual == expected, (descriptor,mode,actual[:64],expected[:64])
            assert (await self.bar(TRY_WAIT,0,phase=0))['wait_complete'] == 1
            await self.bar(INVAL,0)
        return total


@cocotb.test()
async def mbarrier_objects_counts_tokens(dut):
    h = await Harness(dut).start()
    write_bytes(h.smem, 0x100, bytes([0xa5])*64)
    for i in range(4):
        assert (await h.bar(INIT,0x100+8*i,count=1+i))['status'] == 0
    before = read_bytes(h.smem,0x100,64)
    r = await h.bar(ARRIVE,0x100,count=1,phase=1) # input parity is irrelevant for arrive
    assert r['status'] == 0 and r['phase'] == 1 and ((r['state'] >> 1)&1) == 0
    assert read_bytes(h.smem,0x108,56) == before[8:]
    assert (await h.bar(TRY_WAIT,0x100,state=r['state']))['wait_complete'] == 1
    assert (await h.bar(TRY_WAIT,0x100,phase=1,hint=20))['wait_complete'] == 0
    writes = [r for bus,r,_ in h.requests if bus=='smem' and r['write']]
    assert all(r['addr'] == 0x100 and r['mask'] in (0xff,0xff00,0xff0000,0xff000000) for r in writes)
    assert (await h.bar(INIT,0x200,count=(1<<20)-1))['status'] == 0
    r = await h.bar(ARRIVE,0x200,count=(1<<20)-1)
    assert r['phase'] == 1 and ((r['state'] >> 1)&1) == 0
    assert (await h.bar(INIT,0x208,count=1<<20))['status'] == 0x44
    assert (await h.bar(INIT,0x210,count=0))['status'] == 0x44
    assert (await h.bar(INIT,0x213,count=1))['status'] == 0x47


@cocotb.test()
async def mbarrier_transaction_order_timeout_recovery(dut):
    h = await Harness(dut).start()
    model = MBarrierModel(); model.init(2)
    await h.bar(INIT,0x100,count=2)
    write_bytes(h.gmem,0x1000,bytes(range(32)))
    # Completion may precede expectation while arrivals keep the phase open.
    assert (await h.tma(LOAD_LINEAR,linear=0x1000,smem=0x2000,size=32,barrier=0x100))['status'] == 0
    model.complete(32)
    await h.bar(EXPECT_TX,0x100,tx=32); model.expect(32)
    # Combined operation always arrives once, regardless of the unrelated count field.
    r = await h.bar(ARRIVE_EXPECT_TX,0x100,count=123,tx=0)
    model.arrive(expect_bytes=0)
    assert r['phase'] == model.phase == 0
    wait = await h.bar(TRY_WAIT,0x100,phase=0,hint=10000,wait=False)
    r = await h.bar(ARRIVE,0x100,count=1)
    model.arrive()
    assert r['phase'] == model.phase == 1
    assert (await h.result('bar',wait))['wait_complete'] == 1
    timeout = await h.bar(TRY_WAIT,0x100,phase=1,hint=30)
    assert timeout['status'] == 0 and timeout['wait_complete'] == 0
    await h.bar(EXPECT_TX,0x100,tx=(1<<20)-1)
    assert (await h.bar(EXPECT_TX,0x100,tx=1))['status'] == 0x43
    assert (await h.bar(ARRIVE,0x100,count=1))['status'] == 0x42
    await h.bar(INVAL,0x100)
    assert (await h.bar(TRY_WAIT,0x100))['status'] == 0x41
    assert (await h.bar(INIT,0x100,count=1))['status'] == 0
    # Failed backing writes return an error; cached failure remains pinned until INVAL.
    used = False
    def error(bus,r):
        nonlocal used
        if not used and bus=='smem' and r['write'] and r['id'] & 32:
            used=True; return True
        return False
    h.error=error
    assert (await h.bar(ARRIVE,0x100,count=1))['status'] == 0x45
    assert (await h.bar(TRY_WAIT,0x100,phase=0))['status'] == 0x42
    await h.bar(INVAL,0x100); await h.bar(INIT,0x100,count=1)
    assert (await h.bar(ARRIVE,0x100,count=1))['status'] == 0

    # Timeout must remain finite even when a prior phase-changing write has
    # not been acknowledged. It must not report speculative success.
    await h.bar(INVAL,0x100); await h.bar(INIT,0x100,count=1)
    h.gate=lambda bus,r: not(bus=='smem' and r['write'] and r['addr']==0x100)
    arrival=await h.bar(ARRIVE,0x100,count=1,wait=False)
    pending=await h.bar(TRY_WAIT,0x100,phase=0,hint=30)
    assert pending['status']==0 and pending['wait_complete']==0
    assert arrival not in h.responses['bar']
    h.gate=lambda bus,r:True
    assert (await h.result('bar',arrival))['status']==0
    assert (await h.bar(TRY_WAIT,0x100,phase=0))['wait_complete']==1


@cocotb.test()
async def tiled_ranks_widths_strides_oob(dut):
    h = await Harness(dut).start()
    for rank in range(1,6):
        for elem in (1,2,4,8):
            sizes = (32,)+(4,)*(rank-1)
            stride = strides(sizes,elem)
            desc = TensorDescriptor(rank,elem,0x100000,sizes,stride,(32,)+(3,)*(rank-1),(1,)+(2,)*(rank-1))
            extent = stride[-1]*sizes[-1]
            write_bytes(h.gmem,desc.base,bytes((i*13+rank)%256 for i in range(extent)))
            for start in ((0,)*rank,(-16//elem,)+(2,)*(rank-1)):
                await h.tensor(desc,start)
            await h.tensor(desc,(16//elem,)+(3,)*(rank-1),store=True)
    # Encoded globalDim=2^32 must not wrap to zero. Sparse backing avoids huge allocations.
    desc = TensorDescriptor(1,1,0x100000,(2**32,),(1,),(16,),(1,))
    await h.tensor(desc,(0,))


@cocotb.test()
async def swizzle_official_rows_and_roundtrip(dut):
    h = await Harness(dut).start()
    # Independent PTX tables: row permutations of 16B cells, not the model's bit formula.
    tables={1:[[0,1,2,3,4,5,6,7],[1,0,3,2,5,4,7,6]],
            2:[[0,1,2,3,4,5,6,7],[1,0,3,2,5,4,7,6],[2,3,0,1,6,7,4,5],[3,2,1,0,7,6,5,4]],
            3:[[i ^ r for i in range(8)] for r in range(8)],
            4:[[i ^ (2*r) for i in range(8)] for r in range(4)],
            5:[[i ^ (2*r) for i in range(8)] for r in range(4)],
            6:[[i ^ (4*r) for i in range(8)] for r in range(2)]}
    for mode in range(1,7):
        span={1:32,2:64}.get(mode,128)
        desc=TensorDescriptor(2,2,0x100000,(64,8),(2,128),(span//2,8),(1,1),swizzle=mode)
        data=bytes((i*7+3)%256 for i in range(1024)); write_bytes(h.gmem,desc.base,data)
        for base in (0x18000,0x18080,0x18100):
            await h.tensor(desc,(0,0),smem=base)
            logical=desc.load(h.gmem,(0,0))
            for index,value in enumerate(logical):
                addr=base+index; row=addr//128; cell=(addr%128)//16; byte=addr%16
                if mode==5 and row%2: byte ^= 8
                expected_addr=(addr//128)*128+tables[mode][row%len(tables[mode])][cell]*16+byte
                assert h.smem[expected_addr] == value
            if mode!=5: await h.tensor(desc,(0,0),smem=base,store=True)


@cocotb.test()
async def im2col_spatial_wide_halo(dut):
    h = await Harness(dut).start()
    for rank in (3,4,5):
        sizes=(16,)+(5,)*(rank-2)+(8,)
        desc=TensorDescriptor(rank,1,0x100000,sizes,strides(sizes,1),(16,)+(1,)*(rank-1),
            (1,)+(2,)*(rank-2)+(1,),kind=1,lower=(-1,)*3,upper=(-1,)*3,channels=16,pixels=13)
        write_bytes(h.gmem,desc.base,bytes((i*17+rank)%256 for i in range(desc.strides[-1]*sizes[-1])))
        start=(0,)+(1,)*(rank-2)+(0,)
        await h.tensor(desc,start,mode=IM2COL,offsets=(1,1,1))
        valid=replace(desc,lower=(0,0,0),upper=(0,0,0))
        await h.tensor(valid,(0,)*rank,mode=IM2COL_NO_OFFS,store=True)
        wide=replace(desc,kind=2,swizzle=3,lower=(0,0,0),upper=(0,0,0),pixels=35,
                     traversal=(1,)+(1,)*(rank-1))
        await h.tensor(wide,(0,1)+(0,)*(rank-2),mode=IM2COL_W,halo=2,woffset=1)
        await h.tensor(replace(wide,pixels=0),(0,1)+(0,)*(rank-2),mode=IM2COL_W128,halo=2,woffset=1)
    # Literal 3D coordinate sequence: box W=[0,4), start W=2, stride 1.
    d=TensorDescriptor(3,1,0x100000,(16,4,64),(1,16,64),(16,1,1),(1,1,1),kind=2,swizzle=3,pixels=8,channels=16)
    points=list(d.coordinates((0,2,0),IM2COL_W128,halo=2))
    for group in range(4):
        for j in range(2):
            expected_pixel=(group+1)*32+j
            n,w=divmod(2+expected_pixel,4)
            assert points[(128+group*2+j)*16] == (0,w,n)
    await h.tensor(d,(0,2,0),mode=IM2COL_W128,halo=2)
    # Wide mode uniquely permits a first W left of the bounding box.
    await h.tensor(d,(0,-2,0),mode=IM2COL_W,halo=1,woffset=1)


@cocotb.test()
async def bulk_groups_read_visibility_and_issuers(dut):
    h = await Harness(dut).start()
    write_bytes(h.smem,0x1000,bytes(range(128)))
    h.gate=lambda bus,r: not (bus=='gmem' and r['write'])
    # Two beats fit even the 3-entry MSHR configuration. Holding every write
    # ack of a larger copy would legitimately prevent its remaining reads.
    a=await h.tma(STORE_LINEAR,linear=0x4000,smem=0x1000,size=64,issuer=7,wait=False)
    assert (await h.tma(COMMIT,issuer=7))['status']==0
    read=await h.tma(WAIT_GROUP,issuer=7,read=True)
    assert read['status']==0 and a not in h.responses['tma']
    full=await h.tma(WAIT_GROUP,issuer=7,wait=False)
    assert (await h.tma(COMMIT,issuer=9))['status']==0 # empty group of another thread
    assert (await h.tma(WAIT_GROUP,issuer=9))['status']==0
    b=await h.tma(STORE_LINEAR,linear=0x5000,smem=0x1000,size=64,issuer=7,wait=False)
    await h.tma(COMMIT,issuer=7)
    skip_newest=await h.tma(WAIT_GROUP,issuer=7,n=1,wait=False)
    all_groups=await h.tma(WAIT_GROUP,issuer=7,wait=False)
    await h.tick(40)
    assert full not in h.responses['tma'] and skip_newest not in h.responses['tma']
    h.gate=lambda bus,r: not(bus=='gmem' and r['write'] and r['addr']>=0x5000)
    assert (await h.result('tma',a))['status']==0
    assert (await h.result('tma',full))['status']==0
    assert (await h.result('tma',skip_newest))['status']==0
    await h.tick(30)
    assert all_groups not in h.responses['tma'] and b not in h.responses['tma']
    h.gate=lambda bus,r: True
    assert (await h.result('tma',b))['status']==0
    assert (await h.result('tma',all_groups))['status']==0
    assert not [r for bus,r,_ in h.requests if bus=='smem' and r['write']] # stores never touch a barrier
    for _ in range(12): await h.tma(COMMIT,issuer=7)
    assert (await h.tma(WAIT_GROUP,issuer=7,n=0xffffffff))['status']==0


@cocotb.test()
async def descriptor_completion_and_invalidation(dut):
    h = await Harness(dut).start()
    d=TensorDescriptor(1,1,0x1000,(32,),(1,),(32,),(1,))
    write_bytes(h.gmem,0x8000,d.encode()); write_bytes(h.gmem,0x1000,bytes(range(32)))
    await h.bar(INIT,0x100,count=1); await h.bar(ARRIVE_EXPECT_TX,0x100,tx=32)
    h.gate=lambda bus,r: not(bus=='smem' and r['write'] and r['addr']>=0x2000)
    tag=await h.tma(LOAD_TENSOR,desc=0x8000,coords=(0,),smem=0x2000,barrier=0x100,issuer=2,wait=False)
    await h.tma(COMMIT,issuer=2)
    assert (await h.tma(WAIT_GROUP,issuer=2,read=True))['status']==0
    assert tag not in h.responses['tma']
    assert (await h.bar(TRY_WAIT,0x100,phase=0,hint=20))['wait_complete']==0
    h.gate=lambda bus,r: True
    assert (await h.result('tma',tag))['status']==0
    assert (await h.bar(TRY_WAIT,0x100,phase=0))['wait_complete']==1
    write_bytes(h.gmem,0x8000,replace(d,base=0x1100).encode())
    write_bytes(h.gmem,0x1100,bytes([0xee])*32)
    # Cache retains old descriptor until explicit invalidation.
    await h.bar(ARRIVE_EXPECT_TX,0x100,tx=32)
    assert (await h.tma(LOAD_TENSOR,desc=0x8000,coords=(0,),smem=0x2000,barrier=0x100))['status']==0
    assert read_bytes(h.smem,0x2000,32)==bytes(range(32))
    assert (await h.bar(TRY_WAIT,0x100,phase=1))['wait_complete']==1
    await h.tma(DESC_INV,desc=0x8000)
    await h.bar(ARRIVE_EXPECT_TX,0x100,tx=32)
    assert (await h.tma(LOAD_TENSOR,desc=0x8000,coords=(0,),smem=0x2000,barrier=0x100))['status']==0
    assert read_bytes(h.smem,0x2000,32)==bytes([0xee])*32


@cocotb.test()
async def nvidia_hardware_layout_golden(dut):
    """Compare physical bytes directly with captured GPU output, not the model."""
    h=await Harness(dut).start()
    fixture=json.loads((Path(__file__).parent/'golden/nvidia_tma_sm120a.json').read_text())
    payload=b''.join((i+1).to_bytes(4,'little') for i in range((1<<20)//4))
    write_bytes(h.gmem,0x100000,payload)
    for a in fixture['cases']:
        d=TensorDescriptor(a['rank'],4,0x100000,tuple(a['dims']),tuple(a['strides']),
            tuple(a['box']),tuple(a['step']),kind=min(a['mode'],2),swizzle=a['swizzle'],
            lower=tuple(a['lower']),upper=tuple(a['upper']),channels=a['channels'],pixels=a['pixels'])
        write_bytes(h.gmem,0x80000,d.encode())
        await h.tma(DESC_INV,desc=0x80000)
        write_bytes(h.smem,0x10000,bytes([0xcd])*16384)
        await h.bar(INIT,0x100,count=1)
        await h.bar(ARRIVE_EXPECT_TX,0x100,tx=a['bytes'])
        r=await h.tma(LOAD_TENSOR,desc=0x80000,coords=a['coords'],smem=0x10000+a['base'],
            barrier=0x100,mode=a['mode'],offsets=a['offsets'],halo=a['halo'],woffset=a['woffset'])
        assert r['status']==0 and r['bytes']==a['bytes'],a['id']
        expected=bytearray([0xcd])*16384
        for offset,word in a['words']:
            expected[offset:offset+4]=word.to_bytes(4,'little')
        assert read_bytes(h.smem,0x10000,16384)==expected,('GPU layout',a['id'])
        assert (await h.bar(TRY_WAIT,0x100,phase=0))['wait_complete']==1
        await h.bar(INVAL,0x100)


@cocotb.test()
async def queue_pressure_and_barrier_recovery(dut):
    h=await Harness(dut).start()
    depth=int(os.getenv('TMA_TEST_QUEUE_DEPTH','8'))
    write_bytes(h.smem,0x1000,bytes(range(128)))
    h.gate=lambda bus,r: not(bus=='gmem' and r['write'])
    copies=[]
    for i in range(depth+1):
        copies.append(await h.tma(STORE_LINEAR,linear=0x4000+128*i,smem=0x1000,size=128,issuer=1023,wait=False))
    # A full copy FIFO must not prevent commit and wait from being accepted.
    assert (await h.tma(COMMIT,issuer=1023))['status']==0
    waiter=await h.tma(WAIT_GROUP,issuer=1023,wait=False)
    await h.tick(20)
    assert waiter not in h.responses['tma']
    h.gate=lambda bus,r: True
    for tag in copies:
        assert (await h.result('tma',tag))['status']==0
    assert (await h.result('tma',waiter))['status']==0
    for i in range(depth+1):
        assert read_bytes(h.gmem,0x4000+128*i,128)==bytes(range(128))
    await h.bar(INIT,0x100,count=64)
    for _ in range(3):
        assert (await h.bar(TRY_WAIT,0x100,hint=100))['wait_complete']==0
    h.gate=lambda bus,r: not(bus=='smem' and r['write'] and r['addr']==0x100)
    h.error=lambda bus,r: bus=='smem' and r['write'] and r['addr']==0x100
    before=len(h.requests)
    tags=[]
    for _ in range(int(os.getenv('TMA_TEST_WRITE_DEPTH','8'))+1):
        tags.append(await h.bar(ARRIVE,0x100,count=1,wait=False))
    for _ in range(200):
        if any(bus=='smem' and r['write'] and r['addr']==0x100 for bus,r,_ in h.requests[before:]):
            break
        await h.tick()
    else:
        raise AssertionError('faulted write was never accepted')
    h.gate=lambda bus,r: True
    h.error=lambda bus,r: False
    responses=[await h.result('bar',tag) for tag in tags]
    assert responses[0]['status']==0x45
    assert all(r['status'] in (0x42,0x45) for r in responses[1:])
    assert (await h.bar(INIT,0x100,count=1))['status']==0x42
    assert (await h.bar(INVAL,0x100))['status']==0
    assert (await h.bar(INIT,0x100,count=1))['status']==0
    r=await h.bar(ARRIVE,0x100,count=1)
    assert r['status']==0 and (await h.bar(TRY_WAIT,0x100,state=r['state']))['wait_complete']==1
    for op in (13,28):
        assert (await h.bar(op,0x100))['status']==0x40


@cocotb.test()
async def illegal_operands_and_backend_failure(dut):
    h=await Harness(dut).start()
    for fields in (dict(linear=0x1001,size=16),dict(linear=0x1000,size=17),dict(linear=0x1000,size=16,smem=1)):
        assert (await h.tma(LOAD_LINEAR,**fields))['status'] != 0
    for op,cpl in ((STORE_LINEAR,MBAR),(LOAD_LINEAR,BULK)):
        assert (await h.tma(op,linear=0x1000,size=16,completion=cpl))['status']==0x27
    assert (await h.tma(LOAD_LINEAR,linear=0x1000,size=16,multi=1))['status']==0x27
    d=TensorDescriptor(1,1,0x1000,(64,),(1,),(16,),(1,))
    await h.tensor(replace(d,traversal=(2,)),(0,))  # ignored dimension-zero step
    cases=[replace(d,box=(257,)),replace(d,base=0x1001),replace(d,swizzle=7)]
    for desc in cases:
        addr=0x80000+h.next_tag*128; write_bytes(h.gmem,addr,desc.encode())
        assert (await h.tma(LOAD_TENSOR,desc=addr,coords=(0,),smem=0x2000))['status'] != 0
    for bitfield in ((int.from_bytes(d.encode(),'little') & ~255) | 1,
                     int.from_bytes(d.encode(),'little') | (4<<11)):
        addr=0x80000+h.next_tag*128; write_bytes(h.gmem,addr,bitfield.to_bytes(128,'little'))
        assert (await h.tma(LOAD_TENSOR,desc=addr,coords=(0,),smem=0x2000))['status'] != 0
    assert (await h.tma(LOAD_TENSOR,desc=0x80001,coords=(0,),smem=0x2000))['status']==0x21
    await h.bar(INIT,0x100,count=1); await h.bar(ARRIVE_EXPECT_TX,0x100,tx=16)
    h.error=lambda bus,r: bus=='gmem'
    assert (await h.tma(LOAD_LINEAR,linear=0x1000,size=16,smem=0x2000,barrier=0x100))['status']==0x30
    assert (await h.bar(TRY_WAIT,0x100,phase=0,hint=20))['wait_complete']==0


@cocotb.test()
async def parameter_limits_and_invalid_combinations(dut):
    h=await Harness(dut).start()
    base=TensorDescriptor(2,1,0x100000,(256,8),(1,256),(16,3),(1,1))
    write_bytes(h.gmem,base.base,bytes((i*7)%256 for i in range(2048)))
    await h.tensor(replace(base,box=(256,8),traversal=(1,8)),(0,0))
    bad=[(replace(base,traversal=(1,0)),{},0x22),
         (replace(base,traversal=(1,9)),{},0x22),
         (replace(base,strides=(1,255)),{},0x22),
         (replace(base,strides=(1,128)),{},0x22),
         (replace(base,strides=(1,1<<40)),{},0x22),
         (replace(base,box=(0,3)),{},0x22),
         (replace(base,box=(15,3)),{},0x22),
         (replace(base,box=(48,3),swizzle=1),{},0x22),
         (replace(base,swizzle=4),dict(smem=0x20010),0x25),
         (replace(base,swizzle=6),dict(smem=0x20020),0x25),
         (replace(base,swizzle=5),dict(store=True),0x27),
         (base,dict(store=True,start=(-16,0)),0x22),
         (base,dict(start=(1,0)),0x25)]
    im=TensorDescriptor(3,1,0x100000,(16,4,4),(1,16,64),(16,1,1),(1,1,1),kind=1,channels=16,pixels=4)
    bad += [(replace(im,pixels=1025),dict(mode=IM2COL),0x22),
            (replace(im,channels=257),dict(mode=IM2COL),0x22),
            (replace(im,upper=(-4,0,0)),dict(mode=IM2COL),0x22),
            (replace(im,kind=0),dict(mode=IM2COL),0x22),
            (replace(im,lower=(-1,0,0)),dict(mode=IM2COL_NO_OFFS,store=True),0x22),
            (im,dict(mode=IM2COL_NO_OFFS),0x27)]
    wide=replace(im,kind=2,swizzle=3)
    bad += [(wide,dict(mode=IM2COL_W,halo=512),0x22),
            (wide,dict(mode=IM2COL_W128,halo=32),0x22),
            (wide,dict(mode=IM2COL_W,woffset=32),0x22),
            (replace(wide,swizzle=0),dict(mode=IM2COL_W),0x27),
            (replace(wide,swizzle=5),dict(mode=IM2COL_W),0x27)]
    for d,kw,status in bad:
        ptr=0x80000+h.next_tag*128
        write_bytes(h.gmem,ptr,d.encode())
        args=dict(kw)
        op=STORE_TENSOR if args.pop('store',False) else LOAD_TENSOR
        start=args.pop('start',(0,)*d.dims)
        smem=args.pop('smem',0x20000)
        result=await h.tma(op,desc=ptr,coords=start,smem=smem,**args)
        assert result['status']==status,(d,kw,result)
    for rank,limit in ((4,256),(5,32)):
        d=TensorDescriptor(rank,1,0x100000,(16,)+(4,)*(rank-1),strides((16,)+(4,)*(rank-1),1),
            (16,)+(1,)*(rank-1),(1,)*rank,kind=1,channels=16,pixels=4)
        ptr=0x80000+h.next_tag*128;write_bytes(h.gmem,ptr,d.encode())
        assert (await h.tma(LOAD_TENSOR,desc=ptr,coords=(0,)*rank,smem=0x20000,mode=IM2COL,
                           offsets=(limit,0,0)))['status']==0x22
    for fields in (dict(linear=(1<<64)-16,size=32,smem=0x2000),
                   dict(linear=0x100000,size=32,smem=(1<<32)-16)):
        assert (await h.tma(STORE_LINEAR,**fields))['status']==0x26


@cocotb.test()
async def mbarrier_extended_layout_lifecycle(dut):
    h = await Harness(dut).start()
    # One SMEM bus line mixes both layouts. Querying one never changes another.
    for slot, layout in enumerate((0, 1, 0, 1)):
        addr = 0x180 + 8*slot
        await h.bar(INIT, addr, count=4, layout=layout)
        assert (await h.bar(CHECK_LAYOUT, addr, layout=layout))['predicate'] == 1
        assert (await h.bar(CHECK_LAYOUT, addr, layout=1-layout))['predicate'] == 0
    line = read_bytes(h.smem, 0x180, 32)
    r = await h.bar(DROP, 0x180, count=2, no_complete=True)
    assert r['status'] == 0 and r['phase'] == 0
    # Token keeps PRE-arrival pending count, usable even after INVAL/reinit.
    assert ((r['state'] >> 4) & 0xfffff) == 4
    token = r['state']
    assert read_bytes(h.smem, 0x188, 24) == line[8:]
    assert (await h.bar(ARRIVE, 0x180, count=2))['phase'] == 1
    assert (await h.bar(ARRIVE, 0x180, count=2))['phase'] == 0  # expected permanently became 2
    await h.bar(INVAL, 0x180)
    before = len(h.requests)
    assert (await h.bar(PENDING_COUNT, 3, state=token))['value'] == 4  # no object access/alignment
    assert len(h.requests) == before
    assert (await h.bar(PENDING_COUNT, 0, state=token & ~(1<<3)))['status'] == 0x48
    assert (await h.bar(INIT, 0x180, count=1, layout=1))['status'] == 0
    r = await h.bar(ARRIVE, 0x180, count=1, no_complete=True)
    assert r['status'] == 0x44
    await h.bar(INVAL, 0x180)
    assert (await h.bar(INIT, 0x180, count=512, layout=1))['status'] == 0x44
    await h.bar(INVAL, 0x180)
    assert (await h.bar(INIT, 0x180, count=511, layout=1))['status'] == 0
    assert (await h.bar(ARRIVE, 0x180, count=511))['phase'] == 1
    assert (await h.bar(DROP, 0x180, count=511))['status'] == 0x44
    await h.bar(INVAL, 0x180)
    # noComplete may consume the last pending arrival while transactions prevent completion.
    await h.bar(INIT, 0x180, count=1)
    await h.bar(EXPECT_TX, 0x180, tx=16)
    r = await h.bar(ARRIVE, 0x180, count=1, no_complete=True)
    assert r['status'] == 0 and r['phase'] == 0
    assert (await h.bar(TEST_WAIT, 0x180, state=r['state']))['wait_complete'] == 0
    assert (await h.bar(COMPLETE_TX, 0x180, tx=16))['phase'] == 1
    assert (await h.bar(TEST_WAIT, 0x180, state=r['state']))['wait_complete'] == 1


@cocotb.test()
async def mbarrier_primary_conditional_reports(dut):
    h = await Harness(dut).start()
    for layout in (0,1):
        m = MBarrierModel(); m.init(3, layout)
        await h.bar(INIT, 0x100, count=3, layout=layout)
        # The report for the previous phase survives updates to the next phase.
        for report in ((0,0,0) if not layout else (0x12,0,0x80,0)):
            phase, conditional = m.phase, m.conditional
            if report:
                assert (await h.bar(REPORT,0x100,report=report))['status'] == 0
                m.report(report)
            await h.bar(COMPLETE_TX,0x100,tx=7); m.complete(7)
            # Last arrival cannot complete until the earlier completion is balanced.
            r = await h.bar(ARRIVE,0x100,count=3); m.arrive(3)
            assert r['phase'] == phase
            assert (await h.bar(TEST_WAIT,0x100,phase=phase))['wait_complete'] == 0
            await h.bar(EXPECT_TX,0x100,tx=7); m.expect(7)
            got = await h.bar(TEST_WAIT,0x100,state=r['state'])
            assert got['status'] == 0 and got['wait_complete'] == 1
            assert got['report'] == report and got['report_predicate'] == bool(report)
            got = await h.bar(TEST_WAIT,0x100,phase=conditional,conditional=True)
            assert got['wait_complete'] == (not report)
            if layout:
                await h.bar(REPORT,0x100,report=4); m.report(4)
                assert (await h.bar(TEST_WAIT,0x100,phase=phase))['report'] == report
                # Complete the next phase with a nonzero report, then start afresh.
                await h.bar(ARRIVE,0x100,count=3); m.arrive(3)
            assert (await h.bar(TEST_WAIT,0x100,state=r['state'],conditional=True))['status'] == 0x48
        await h.bar(INVAL,0x100)
    # A nonblocking check does not occupy the sole wait-CAM entry in the small configuration.
    await h.bar(INIT,0x100,count=2)
    pending=await h.bar(TRY_WAIT,0x100,phase=0,hint=1000,wait=False)
    assert (await h.bar(TEST_WAIT,0x100,phase=0))['wait_complete'] == 0
    await h.bar(DROP_EXPECT_TX,0x100,count=99,tx=16)
    await h.bar(ARRIVE,0x100,count=1)
    await h.bar(COMPLETE_TX,0x100,tx=16)
    assert (await h.result('bar',pending))['wait_complete'] == 1


@cocotb.test()
async def mbarrier_ordering_acknowledgements(dut):
    h=await Harness(dut).start()
    await h.bar(INIT,0x100,count=1)
    initial=read_bytes(h.smem,0x100,8)
    h.order_gate=lambda r:False
    arrival=await h.bar(ARRIVE,0x100,count=1,issuer=11,seq=42,scope=1,wait=False)
    await h.tick(40)
    assert read_bytes(h.smem,0x100,8)==initial and arrival not in h.responses['bar']
    assert any(r['kind']==0 and r['issuer']==11 and r['seq']==42 and r['scope']==1 for r,_ in h.order_requests)
    # Another issuer can access unrelated barriers while the release is held.
    assert (await h.bar(INIT,0x108,count=1,issuer=12))['status']==0
    h.order_gate=lambda r:True
    arrived=await h.result('bar',arrival)
    h.order_gate=lambda r:r['kind']!=1
    waiter=await h.bar(TEST_WAIT,0x100,state=arrived['state'],issuer=12,wait=False)
    await h.tick(40)
    assert waiter not in h.responses['bar']
    assert (await h.bar(TEST_WAIT,0x108,phase=0,sem=0))['wait_complete']==0
    h.order_gate=lambda r:True
    assert (await h.result('bar',waiter))['wait_complete']==1
    # Error acknowledgements cannot turn a failed release or acquire into success.
    h.order_error=lambda r:1
    before=read_bytes(h.smem,0x108,8)
    assert (await h.bar(ARRIVE,0x108,count=1))['status']==0x45
    assert read_bytes(h.smem,0x108,8)==before
    r=await h.bar(TEST_WAIT,0x100,phase=0)
    assert r['status']==0x45 and r['wait_complete']==0
    assert (await h.bar(COMPLETE_TX,0x100,tx=0,sem=1))['status']==0x49


@cocotb.test()
async def ordinary_cp_async_prior_sequence_and_noinc(dut):
    h=await Harness(dut).start()
    for noinc in (False,True):
        for issuer,addr in ((3,0x100),(7,0x108)):
            await h.bar(INIT,addr,count=2 if noinc else 1)
            assert await h.async_event(issuer,100+int(noinc)*100)==0
            assert await h.async_event(issuer,101+int(noinc)*100)==0
            assert (await h.bar(CP_ASYNC_ARRIVE,addr,issuer=issuer,seq=102+int(noinc)*100,noinc=noinc))['status']==0
            # Later ordinary cp.async is outside the captured prefix.
            assert await h.async_event(issuer,103+int(noinc)*100)==0
            await h.bar(ARRIVE,addr,count=1)
        assert await h.async_event(7,101+int(noinc)*100,complete=True)==0
        assert await h.async_event(3,101+int(noinc)*100,complete=True)==0
        for addr in (0x100,0x108):
            assert (await h.bar(TEST_WAIT,addr,phase=0))['wait_complete']==0
        assert await h.async_event(3,100+int(noinc)*100,complete=True)==0
        assert (await h.bar(TRY_WAIT,0x100,phase=0,hint=10000))['wait_complete']==1
        assert (await h.bar(TEST_WAIT,0x108,phase=0))['wait_complete']==0
        assert await h.async_event(7,100+int(noinc)*100,complete=True)==0
        assert (await h.bar(TRY_WAIT,0x108,phase=0,hint=10000))['wait_complete']==1
        for issuer in (3,7):
            assert await h.async_event(issuer,103+int(noinc)*100,complete=True)==0
            assert await h.async_event(issuer,103+int(noinc)*100,complete=True)==0x48
    # Empty prior prefix still contributes the reserved arrival exactly once.
    await h.bar(INIT,0x110,count=2)
    await h.bar(CP_ASYNC_ARRIVE,0x110,issuer=13,seq=1,noinc=True)
    await h.bar(ARRIVE,0x110,count=1)
    assert (await h.bar(TRY_WAIT,0x110,phase=0,hint=10000))['wait_complete']==1
    # Failed asynchronous work locks its barrier rather than generating report or success.
    await h.bar(INIT,0x118,count=1,layout=1)
    await h.async_event(14,1)
    await h.bar(CP_ASYNC_ARRIVE,0x118,issuer=14,seq=2)
    await h.bar(ARRIVE,0x118,count=1)
    assert await h.async_event(14,1,complete=True,status=0x35)==0x35
    assert (await h.bar(TRY_WAIT,0x118,phase=0,hint=10000))['status']==0x42
    await h.bar(INVAL,0x118)
    assert (await h.bar(INIT,0x118,count=1))['status']==0


@cocotb.test()
async def v3_nvidia_format_golden(dut):
    h=await Harness(dut).start()
    fixture=json.loads((Path(__file__).parent/'golden/nvidia_tma_formats_sm120a.json').read_text())
    sample=[0x3f801001,0x3f803000,0x3f805000,0x80000001,1,0x7fffff,0x7f800001,0x7fc00001,0xff800001,0x7f800000,0xff800000,0xbf801000,0x3fffffff,0x2000,0x80000000,0]
    for case in fixture['cases']:
        dtype=case['dtype']; elem={0:1,1:2,2:4,3:4,4:8,5:8,6:2,7:4,8:4,9:8,10:2,11:4,12:4}.get(dtype,1)
        sizes=tuple(case['sizes']);box=tuple(case['box']);start=tuple(case['coords'][:case['rank']]);stride=(0 if dtype>=13 else elem,*case['strides'])
        if case['mode']==GATHER4:start=tuple(case['coords'])
        if case['interleave']:
            per=(16 if case['interleave']==1 else 32)//elem
            sizes=(sizes[1]*per,sizes[0],sizes[2]);box=(per,box[0],box[2]);start=(case['coords'][1]*per,case['coords'][0],case['coords'][2])
            stride=(case['strides'][0],per*elem,case['strides'][1])
        desc=TensorDescriptor(case['rank'],elem,0x100000,sizes,stride,box,(1,)*case['rank'],dtype=dtype,interleave=case['interleave'],swizzle=case['swizzle'],oob_fill=case['fill'])
        for i in range(4096):write_bytes(h.gmem,desc.base+4*i,(sample[i%16] if 8<=case['id']<18 else i+1).to_bytes(4,'little'))
        write_bytes(h.smem,0x18000,b'\xcd'*4096)
        ptr=0x80000+128*h.next_tag;write_bytes(h.gmem,ptr,desc.encode())
        assert desc.byte_count(case['mode'])==case['bytes']
        await h.bar(INIT,0,count=1);await h.bar(ARRIVE_EXPECT_TX,0,tx=case['bytes'])
        r=await h.tma(LOAD_TENSOR,desc=ptr,coords=start,smem=0x18000,mode=case['mode'])
        assert r['status']==0 and r['bytes']==case['bytes'],(case['id'],r)
        for offset,word in case['words']:
            assert int.from_bytes(read_bytes(h.smem,0x18000+offset,4),'little')==word,(case['id'],offset,word)
        assert (await h.bar(TRY_WAIT,0,phase=0))['wait_complete']
        await h.bar(INVAL,0)


@cocotb.test()
async def v3_packing_interleave_scatter(dut):
    h=await Harness(dut).start()
    write_bytes(h.gmem,0x100000,bytes((i*37+11)%256 for i in range(32768)))
    # Explicit bitstream for 6-bit store: each source element occupies one byte;
    # high two bits are ignored, destination packs four elements into three bytes.
    desc=TensorDescriptor(2,1,0x100000,(256,2),(0,192),(128,2),(1,1),dtype=15)
    ptr=0x80000;write_bytes(h.gmem,ptr,desc.encode())
    values=[(i*13+7)%64 for i in range(256)]
    write_bytes(h.smem,0x18000,bytes(v|0xc0 for v in values))
    expected=dict(h.gmem)
    for row in range(2):
        bits=sum(values[row*128+i]<<(6*i) for i in range(128))
        write_bytes(expected,desc.base+row*192,bits.to_bytes(96,'little'))
    r=await h.tma(STORE_TENSOR,desc=ptr,coords=(0,0),smem=0x18000)
    assert r['status']==0 and r['bytes']==192,r
    assert h.gmem==expected
    # Partial final b4 group is byte-masked OOB, not an entire 16-element guess.
    d4=TensorDescriptor(2,1,0x100000,(18,2),(0,16),(32,2),(1,1),dtype=13)
    await h.tensor(d4,(0,0));await h.tensor(d4,(0,0),store=True)
    for rank in (3,4,5):
        for interleave in (1,2):
            per=(16 if interleave==1 else 32)//2
            sizes=(per*3,4)+(2,)*(rank-2)
            strides_c=(per*2*4*2**(rank-3),per*2)+tuple(per*2*4*2**d for d in range(rank-3))+(per*2*4*2**(rank-3)*3,)
            box=(per*2,3)+(1,)*(rank-2)
            d=TensorDescriptor(rank,2,0x100000,sizes,strides_c,box,(1,)*rank,interleave=interleave,swizzle=1 if interleave==2 else 0)
            await h.tensor(d,(per,1)+(0,)*(rank-2));await h.tensor(d,(0,0)+(0,)*(rank-2),store=True)
    scatter=TensorDescriptor(2,4,0x100000,(32,4),(4,128),(8,1),(1,1))
    await h.tensor(scatter,(4,2,0,3,1),mode=SCATTER4,store=True)
    # Both former descriptor versions must be rejected on the unified path.
    for old in (1,2):
        raw=bytearray(scatter.encode());raw[0]=old;write_bytes(h.gmem,ptr,raw)
        await h.tma(DESC_INV,desc=ptr)
        assert (await h.tma(LOAD_TENSOR,desc=ptr,coords=(0,0),smem=0x18000))['status']==0x22


@cocotb.test()
async def bulk_masks_shared_prefetch_and_release(dut):
    h=await Harness(dut).start()
    payload=bytes(range(64));write_bytes(h.smem,0x4000,payload)
    write_bytes(h.gmem,0x100000,b'\xa5'*64)
    r=await h.tma(STORE_LINEAR,linear=0x100000,smem=0x4000,size=64,cp_mask_enable=1,cp_mask=0xa55a)
    assert r['status']==0 and r['bytes']==64
    assert read_bytes(h.gmem,0x100000,64)==bytes(payload[i] if 0xa55a>>(i%16)&1 else 0xa5 for i in range(64))
    assert (await h.tma(STORE_LINEAR,linear=0x100000,smem=0x4000,size=0))['status']==0
    # ignore_oob does not issue reads for ignored bytes and zero-fills them.
    await h.bar(INIT,0,count=1);await h.bar(ARRIVE_EXPECT_TX,0,tx=32)
    write_bytes(h.gmem,0x110000,bytes(range(32)))
    h.tma_order_gate=lambda r:False
    tag=await h.tma(LOAD_LINEAR,linear=0x110000,smem=0x5000,size=32,ignore_oob=1,oob_start=3,oob_end=5,wait=False)
    for _ in range(500):
        if h.tma_order_pending:break
        await h.tick()
    assert h.tma_order_pending
    assert (await h.bar(TEST_WAIT,0,phase=0))['wait_complete']==0
    assert tag not in h.responses['tma']
    h.tma_order_gate=lambda r:True
    assert (await h.result('tma',tag))['status']==0
    assert read_bytes(h.smem,0x5000,32)==b'\0'*3+bytes(range(3,27))+b'\0'*5
    assert (await h.bar(TRY_WAIT,0,phase=0))['wait_complete']
    await h.bar(INVAL,0);await h.bar(INIT,0,count=1);await h.bar(ARRIVE_EXPECT_TX,0,tx=64)
    r=await h.tma(7,linear=0x6000,smem=0x4000,size=64,completion=MBAR)
    assert r['status']==0 and read_bytes(h.smem,0x6000,64)==payload
    assert (await h.bar(TRY_WAIT,0,phase=0))['wait_complete']
    # Prefetch requests carry hints but do not write data or complete a barrier.
    before=dict(h.smem);n=len(h.requests)
    r=await h.tma(11,linear=0x110000,size=64,completion=2,cache_hint=1,cache_policy=0x123456789)
    assert r['status']==0 and r['bytes']==0 and h.smem==before
    requests=[x[1] for x in h.requests[n:]]
    assert requests and all(x['kind']==3 and x['cache_policy']==0x123456789 for x in requests)
    desc=TensorDescriptor(2,4,0x100000,(32,4),(4,128),(8,1),(1,1),l2_promotion=3)
    write_bytes(h.gmem,0x80000,desc.encode());n=len(h.requests)
    r=await h.tma(12,desc=0x80000,coords=(0,1),completion=2)
    assert r['status']==0 and r['bytes']==0 and h.smem==before
    assert any(x[1]['kind']==3 and x[1]['l2_promotion']==3 for x in h.requests[n:])


@cocotb.test()
async def typed_reduction_all_combinations_and_contention(dut):
    from blackwell_backend_ref import LINEAR,SHARED,TENSOR,WIDTH,FLOAT,reduce_value
    h=await Harness(dut).start()
    for opcode,table in ((8,LINEAR),(10,SHARED),(9,TENSOR)):
        for op,types in table.items():
            for dtype in sorted(types):
                width=WIDTH[dtype];dst=0x6000 if opcode==10 else 0x100000
                if dtype in FLOAT:
                    exp,frac=FLOAT[dtype];bias=(1<<(exp-1))-1
                    a=bias<<frac;b=(bias+1)<<frac # 1 + 2, exact in every format
                else:a=(1<<(width*8-1))+7;b=11
                payload=b.to_bytes(width,'little')*(16//width)
                initial=a.to_bytes(width,'little')*(16//width)
                memory=h.smem if opcode==10 else h.gmem
                write_bytes(h.smem,0x4000,payload);write_bytes(memory,dst,initial)
                expected=reduce_value(a,b,dtype,op).to_bytes(width,'little')*(16//width)
                options=dict(linear=dst,smem=0x4000,size=16,dtype=dtype,reduce_op=op,completion=MBAR if opcode==10 else BULK,scope=1 if opcode==10 else 3)
                if opcode==10:
                    await h.bar(INIT,0,count=1);await h.bar(ARRIVE_EXPECT_TX,0,tx=16)
                if opcode==9:
                    desc=TensorDescriptor(1,width,dst,(16//width,),(width,),(16//width,),(1,),dtype=dtype)
                    ptr=0x80000+128*h.next_tag;write_bytes(h.gmem,ptr,desc.encode());options.update(desc=ptr,coords=(0,))
                n=len(h.requests);r=await h.tma(opcode,**options)
                assert r['status']==0 and r['bytes']==16,(opcode,op,dtype,r)
                assert read_bytes(memory,dst,16)==expected,(opcode,op,dtype)
                atomics=[req for _,req,_ in h.requests[n:] if req['write'] and req['kind']==2]
                assert atomics and all(req['dtype']==dtype and req['reduce_op']==op for req in atomics)
                if opcode==10:await h.bar(INVAL,0)
    # Another LSU client changes the destination immediately before the atomic
    # backend transaction. The result must use that value, never a prior load.
    write_bytes(h.smem,0x4000,(3).to_bytes(4,'little')*4)
    def contender(bus,memory,r):
        for b in range(0,128 if bus=='gmem' else 32,4):
            if r['mask']>>b&1:write_bytes(memory,r['addr']+b,(17).to_bytes(4,'little'))
    h.before_atomic=contender
    assert (await h.tma(8,linear=0x100000,smem=0x4000,size=16,dtype=2,reduce_op=0,completion=BULK))['status']==0
    assert read_bytes(h.gmem,0x100000,16)==(20).to_bytes(4,'little')*4
    for op,dtype in ((0,0),(0,5),(1,7),(3,4),(5,6)):
        assert (await h.tma(8,linear=0x100000,smem=0x4000,size=16,dtype=dtype,reduce_op=op,completion=BULK))['status']==0x27


@cocotb.test()
async def multimem_all_targets_and_order_failure(dut):
    h=await Harness(dut).start()
    payload=bytes(range(32));write_bytes(h.smem,0x4000,payload)
    h.target_gate=lambda target,r:target==0
    copy=await h.tma(STORE_LINEAR,linear=0x100000,smem=0x4000,size=32,multimem=1,atomic128=1,issuer=3,scope=3,wait=False)
    assert (await h.tma(COMMIT,issuer=3))['status']==0
    assert (await h.tma(WAIT_GROUP,issuer=3,read=True))['status']==0
    wait=await h.tma(WAIT_GROUP,issuer=3,wait=False)
    await h.tick(30)
    assert copy not in h.responses['tma'] and wait not in h.responses['tma']
    assert read_bytes(h.multimem[0],0x100000,32)==payload
    assert not h.multimem[1]
    h.target_gate=lambda target,r:True
    assert (await h.result('tma',copy))['status']==0
    assert (await h.result('tma',wait))['status']==0
    assert read_bytes(h.multimem[1],0x100000,32)==payload
    assert all(r['atomic128'] for _,r,_ in h.requests if r['multimem'])
    # A release acknowledgement failure leaves the mbarrier pending.
    h.tma_order_error=lambda r:1
    await h.bar(INIT,0,count=1);await h.bar(ARRIVE_EXPECT_TX,0,tx=16)
    r=await h.tma(LOAD_LINEAR,linear=0x100000,smem=0x5000,size=16)
    assert r['status']==0x28
    assert (await h.bar(TRY_WAIT,0,phase=0,hint=30))['wait_complete']==0

    # Reduction is also multicast by the backend and ordinary waits retain a
    # failed group diagnostic even after its copy response has been consumed.
    h.tma_order_error=lambda r:0
    write_bytes(h.smem,0x4000,(3).to_bytes(4,'little')*4)
    for memory in h.multimem:write_bytes(memory,0x100000,(7).to_bytes(4,'little')*4)
    assert (await h.tma(8,linear=0x100000,smem=0x4000,size=16,multimem=1,dtype=2,reduce_op=0,completion=BULK))['status']==0
    for memory in h.multimem:assert read_bytes(memory,0x100000,16)==(10).to_bytes(4,'little')*4
    h.tma_order_error=lambda r:1
    assert (await h.tma(STORE_LINEAR,linear=0x100000,smem=0x4000,size=16,issuer=8))['status']==0x28
    await h.tma(COMMIT,issuer=8)
    assert (await h.tma(WAIT_GROUP,issuer=8))['status']==0x28
    assert (await h.tma(WAIT_GROUP,issuer=9))['status']==0


@cocotb.test()
async def descriptor_replace_publish_and_reread(dut):
    h=await Harness(dut).start()
    desc=TensorDescriptor(2,4,0x100000,(32,4),(4,128),(8,1),(1,1))
    ptr=0x80040 # 64B-aligned descriptor straddles two 128B backend lines
    write_bytes(h.gmem,ptr,desc.encode())
    write_bytes(h.gmem,desc.base,bytes(range(128)))
    async def load_expected(payload):
        await h.bar(INIT,0,count=1);await h.bar(ARRIVE_EXPECT_TX,0,tx=32)
        r=await h.tma(LOAD_TENSOR,desc=ptr,coords=(0,0),smem=0x18000)
        assert r['status']==0 and read_bytes(h.smem,0x18000,32)==payload,r
        await h.bar(INVAL,0)
    await load_expected(bytes(range(32)))
    new_base=0x110000;write_bytes(h.gmem,new_base,b'\xa7'*128)
    r=await h.tma(13,desc=ptr,replace_field=0,replace_value=new_base,completion=2)
    assert r['status']==0
    assert read_bytes(h.gmem,ptr,128)==replace(desc,base=new_base).encode()
    r=await h.tma(15,desc=ptr,size=128,sem=2,scope=2,from_proxy=0,to_proxy=2,completion=2)
    assert r['status']==0
    await load_expected(b'\xa7'*32)
    # Shared replacement followed by one converged warp publication.
    write_bytes(h.smem,0x4040,desc.encode())
    assert (await h.tma(13,desc=0x4040,map_shared=1,replace_field=0,replace_value=new_base,completion=2))['status']==0
    h.tma_order_gate=lambda r:False
    publish=await h.tma(14,desc=ptr,smem=0x4040,size=128,sem=1,scope=3,warp_converged=1,completion=2,wait=False)
    for _ in range(300):
        if h.tma_order_pending:break
        await h.tick()
    assert h.tma_order_pending and publish not in h.responses['tma']
    req=h.tma_order_pending[0]
    assert req['addr']==ptr and req['bytes']==128 and req['from_proxy']==0 and req['to_proxy']==2
    pending=cocotb.start_soon(h.tma(15,desc=ptr,size=128,sem=2,scope=3,from_proxy=0,to_proxy=2,completion=2))
    await h.tick(20);assert not pending.done()
    h.tma_order_gate=lambda r:True
    assert (await h.result('tma',publish))['status']==0
    assert (await pending)['status']==0
    await load_expected(b'\xa7'*32)
    # All replacement fields are encoded independently in the Python encoder.
    for field,ordinal,value,expected in [
        (1,0,2,replace(desc,dims=3,sizes=(32,4,1),strides=(4,128,0),box=(8,1,0),traversal=(1,1,0))),
        (2,0,16,replace(desc,box=(16,1))),
        (3,1,8,replace(desc,sizes=(32,8))),
        (3,1,0,replace(desc,sizes=(32,1<<32))),
        (4,0,256,replace(desc,strides=(4,256))),
        (5,1,2,replace(desc,traversal=(1,2))),
        (6,0,7,replace(desc,dtype=7)),
        (7,0,1,replace(desc,interleave=1)),
        (8,0,3,replace(desc,swizzle=3)),
        (10,0,1,replace(desc,oob_fill=1))]:
        write_bytes(h.smem,0x4040,desc.encode())
        r=await h.tma(13,desc=0x4040,map_shared=1,replace_field=field,replace_ord=ordinal,replace_value=value,completion=2)
        assert r['status']==0,(field,r)
        actual=read_bytes(h.smem,0x4040,128)
        if field==1:
            raw=int.from_bytes(desc.encode(),'little');raw=(raw&~(7<<8))|(2<<8)
            assert actual==raw.to_bytes(128,'little')
        else:assert actual==expected.encode(),field
    for atom,swizzle in enumerate((3,4,5,6)):
        write_bytes(h.smem,0x4040,replace(desc,swizzle=3).encode())
        assert (await h.tma(13,desc=0x4040,map_shared=1,replace_field=9,replace_value=atom,completion=2))['status']==0
        assert read_bytes(h.smem,0x4040,128)==replace(desc,swizzle=swizzle).encode()
    assert (await h.tma(14,desc=ptr,smem=0x4040,size=128,warp_converged=0,completion=2))['status']!=0
    assert (await h.tma(13,desc=ptr,replace_field=8,replace_value=4,completion=2))['status']!=0


@cocotb.test()
async def async_registration_capacity_and_independent_completion(dut):
    h=await Harness(dut).start()
    capacity=int(os.getenv('TMA_TEST_ASYNC_ENTRIES','16'))
    for seq in range(1,capacity+1):assert await h.async_event(31,seq)==0
    pending=cocotb.start_soon(h.async_event(31,capacity+1))
    await h.tick(10);assert not pending.done()
    # The blocked registration holds its payload while a separate completion
    # channel frees a slot. A shared valid-ready request would deadlock here.
    assert await h.async_event(31,capacity,complete=True)==0
    assert await pending==0
    for seq in range(capacity-1,0,-1):assert await h.async_event(31,seq,complete=True)==0
    assert await h.async_event(31,capacity+1,complete=True)==0
    assert await h.async_event(31,1,complete=True)==0x48 # duplicate completion
    # Explicitly acknowledged source failure cannot become an arrival or report.
    await h.bar(INIT,0,count=1)
    assert await h.async_event(32,1)==0
    submit=await h.bar(CP_ASYNC_ARRIVE,0,issuer=32,seq=2,noinc=True)
    assert submit['status']==0
    assert await h.async_event(32,1,complete=True,status=1)==1
    await h.tick(100)
    r=await h.bar(TEST_WAIT,0,phase=0)
    assert r['status']==0x42 and not r['wait_complete'] and not r['report_predicate']
    await h.bar(INVAL,0)


@cocotb.test()
async def strong_copy_and_extended_layout_boundaries(dut):
    h=await Harness(dut).start()
    await h.bar(INIT,0,count=1);await h.bar(ARRIVE_EXPECT_TX,0,tx=32)
    write_bytes(h.gmem,0x100000,bytes(range(32)))
    r=await h.tma(LOAD_LINEAR,linear=0x100000,smem=0x6000,size=32,atomic128=1,ignore_oob=1,oob_start=5,oob_end=3,scope=3)
    assert r['status']==0 and read_bytes(h.smem,0x6000,32)==b'\0'*5+bytes(range(5,29))+b'\0'*3
    assert (await h.bar(TRY_WAIT,0,phase=0))['wait_complete'];await h.bar(INVAL,0)
    reqs=[r for bus,r,_ in h.requests if bus=='gmem']
    assert len(reqs)==2 and all(r['atomic128'] for r in reqs)
    assert reqs[0]['mask']==0xffe0 and reqs[1]['mask']==0x1fff0000
    for interleave in (1,2):
        per=16 if interleave==1 else 32
        d=TensorDescriptor(3,1,0x100000,(per*2-2,4,2),(per*4,per,per*8),(per,3,1),(1,2,1),interleave=interleave,swizzle=1 if interleave==2 else 0)
        write_bytes(h.gmem,0x100000,bytes((i*7+3)%256 for i in range(4096)))
        await h.tensor(d,(per,1,0))
        await h.tensor(replace(d,kind=1,channels=per,pixels=3),(per,1,0),mode=IM2COL,offsets=(1,0,0))
    # Packed formats with every legal load swizzle and nonzero absolute base.
    for dtype in (13,14,15):
        d=TensorDescriptor(2,1,0x100000,(256,2),(0,256),(128,2),(1,1),dtype=dtype)
        for sw in ((0,1,2,3,4,5,6) if dtype==13 else (0,3,4,6)):
            box=(64 if sw==1 else 128,2)
            await h.tensor(replace(d,box=box,swizzle=sw),(0,0),smem=0x18040)

    for dtype in (14,15):
        d=TensorDescriptor(2,1,0x100000,(256,2),(0,256),(128,2),(1,1),dtype=dtype)
        ptr=0x80000;write_bytes(h.gmem,ptr,d.encode());await h.tma(DESC_INV,desc=ptr)
        assert (await h.tma(LOAD_TENSOR,desc=ptr,coords=(32 if dtype==14 else 64,0),smem=0x18000))['status']==0x22


@cocotb.test()
async def tc_arrival_is_one_count_not_tx_bytes(dut):
    h = await Harness(dut).start()
    address=0x980
    assert (await h.bar(INIT,address,count=2))['status']==0
    assert (await h.bar(EXPECT_TX,address,tx=32))['status']==0
    # One SW arrival and one TC arrival exhaust pending, but not tx bytes.
    assert (await h.bar(ARRIVE,address,count=1))['status']==0
    dut.tc_arrive_rsp_rdy_i.value=0
    dut.tc_arrive_addr_i.value=address
    dut.tc_arrive_tag_i.value=0xf159
    dut.tc_arrive_vld_i.value=1
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if int(dut.tc_arrive_rdy_o.value):
            await Timer(2,units='ps'); dut.tc_arrive_vld_i.value=0; break
    else: raise AssertionError('TC arrival blocked')
    for _ in range(2000):
        if int(dut.tc_arrive_rsp_vld_o.value): break
        await h.tick()
    else: raise AssertionError('TC response missing')
    assert int(dut.tc_arrive_status_o.value)==0
    assert int(dut.tc_arrive_tag_o.value)==0xf159
    for _ in range(12):
        await h.tick()
        assert int(dut.tc_arrive_rsp_vld_o.value)
        assert int(dut.tc_arrive_tag_o.value)==0xf159
    wait=await h.bar(TEST_WAIT,address,phase=0)
    assert not wait['wait_complete']
    assert (await h.bar(COMPLETE_TX,address,tx=32))['status']==0
    wait=await h.bar(TEST_WAIT,address,phase=0)
    assert wait['wait_complete']
    dut.tc_arrive_rsp_rdy_i.value=1
    await h.tick(2)


@cocotb.test()
async def tc_commit_snapshot_to_backed_barrier(dut):
    from test_tc_completion import identity
    h=await Harness(dut).start()
    dut.tc_control_enable_i.value=1
    dut.event_rdy_i.value=0
    address=0x9c0
    assert (await h.bar(INIT,address,count=2))['status']==0
    async def send(channel,payload):
        getattr(dut,channel+'_i').value=payload
        getattr(dut,channel+'_vld_i').value=1
        for _ in range(1000):
            await RisingEdge(dut.clk)
            if int(getattr(dut,channel+'_rdy_o').value):
                await Timer(2,units='ps')
                getattr(dut,channel+'_vld_i').value=0
                return
        raise AssertionError(('TC control blocked',channel))
    async def event(key,status=0):
        for _ in range(3000):
            if int(dut.event_vld_o.value): break
            await h.tick()
        else: raise AssertionError('TC commit event missing')
        value=int(dut.event_o.value)
        assert value>>75==key
        assert (value>>64)&255==status
        for _ in range(6):
            await h.tick()
            assert int(dut.event_vld_o.value) and int(dut.event_o.value)==value
        dut.event_rdy_i.value=1
        await h.tick()
        dut.event_rdy_i.value=0
    a,b,later=identity(7,10),identity(7,11),identity(7,12)
    c0,c1=identity(7,20),identity(7,21)
    await send('register',a);await send('register',b)
    await send('commit',(c0<<64)|address)
    await send('commit',(c1<<64)|address)
    await send('register',later)
    await send('complete',b<<75)
    await h.tick(20)
    assert not int(dut.event_vld_o.value)
    # Data completion permits the arrival, but its backing write must also ack.
    h.gate=lambda bus,r:not(bus=='smem' and r['write'])
    await send('complete',a<<75)
    await h.tick(50)
    assert not int(dut.event_vld_o.value)
    assert any(bus=='smem' and r['write'] for bus,r,_ in h.requests)
    h.gate=lambda bus,r:True
    await event(c0);await event(c1)
    assert (await h.bar(TEST_WAIT,address,phase=0))['wait_complete']
    # Execution faults must not turn into successful barrier arrivals.
    c2=identity(7,22)
    await send('commit',(c2<<64)|address)
    await send('complete',(later<<75)|(9<<64))
    await event(c2,2)
    response=await h.bar(TEST_WAIT,address,phase=1)
    assert response['locked'] and not response['wait_complete']
    dut.tc_control_enable_i.value=0


@cocotb.test()
async def tc_arrival_bypasses_full_software_wait_table(dut):
    h=await Harness(dut).start()
    address=0xa40
    assert (await h.bar(INIT,address,count=1))['status']==0
    waiters=int(os.getenv('TMA_TEST_WAIT_ENTRIES','32'))
    tags=[]
    for _ in range(waiters+2):
        tags.append(await h.bar(TRY_WAIT,address,phase=0,hint=1_000_000_000,wait=False))
    await h.tick(150)
    assert all(tag not in h.responses['bar'] for tag in tags)
    dut.tc_arrive_rsp_rdy_i.value=0
    dut.tc_arrive_addr_i.value=address
    dut.tc_arrive_tag_i.value=0xeffe
    dut.tc_arrive_vld_i.value=1
    for _ in range(500):
        await RisingEdge(dut.clk)
        if int(dut.tc_arrive_rdy_o.value):
            await Timer(2,units='ps');dut.tc_arrive_vld_i.value=0;break
    else:raise AssertionError('TC admission blocked by full software table')
    for _ in range(2000):
        if int(dut.tc_arrive_rsp_vld_o.value):break
        await h.tick()
    else:raise AssertionError('Blocked software TRY_WAIT hid TC arrival from state unit')
    assert int(dut.tc_arrive_status_o.value)==0
    assert int(dut.tc_arrive_tag_o.value)==0xeffe
    dut.tc_arrive_rsp_rdy_i.value=1
    for tag in tags:
        response=await h.result('bar',tag)
        assert response['status']==0 and response['wait_complete']
