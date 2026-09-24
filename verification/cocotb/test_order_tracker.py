"""Admitted-work ordering with delayed real visibility/maintenance responses."""
import cocotb
from cocotb.triggers import Timer


FIELDS=(('id',16),('issuer',10),('seq',64),('kind',3),('scope',2),('from_proxy',2),('to_proxy',2),('addr',64),('bytes',64))
def pack_order(**kw):
    word=0
    for name,width in FIELDS:word=(word<<width)|kw.get(name,0)
    return word
def unpack_order(word):
    fields={}
    for name,width in reversed(FIELDS):fields[name]=word&((1<<width)-1);word>>=width
    return fields


class OrderTest:
    def __init__(self,d):
        self.d=d;self.maint=[];self.responses=[];self.held=None;self.rheld=None
    async def tick(self,reg=None,complete=None,order=None,ack=None,mready=True,rready=True):
        d=self.d;d.clk.value=0
        d.register_vld_i.value=reg is not None
        d.register_issuer_i.value=reg[0] if reg else 0;d.register_seq_i.value=reg[1] if reg else 0
        d.complete_vld_i.value=complete is not None
        d.complete_token_i.value=complete[0] if complete else 0;d.complete_error_i.value=complete[1] if complete else 0
        d.order_vld_i.value=order is not None;d.order_i.value=order or 0
        d.maintenance_rdy_i.value=mready;d.order_rsp_rdy_i.value=rready
        d.maintenance_rsp_vld_i.value=ack is not None
        d.maintenance_rsp_i.value=(ack[0]<<8)|ack[1] if ack else 0
        await Timer(5,units='ns')
        if self.held is not None:assert int(d.maintenance_vld_o.value) and int(d.maintenance_o.value)==self.held
        if int(d.maintenance_vld_o.value):
            value=int(d.maintenance_o.value)
            if mready:self.maint.append(unpack_order(value));self.held=None
            else:self.held=value
        if self.rheld is not None:assert int(d.order_rsp_vld_o.value) and int(d.order_rsp_o.value)==self.rheld
        if int(d.order_rsp_vld_o.value):
            value=int(d.order_rsp_o.value)
            if rready:self.responses.append((value>>8,value&255));self.rheld=None
            else:self.rheld=value
        registered=int(d.register_token_o.value) if reg is not None and int(d.register_rdy_o.value) else None
        accepted=order is not None and int(d.order_rdy_o.value)
        d.clk.value=1;await Timer(5,units='ns')
        return registered,accepted
    async def idle(self,n=4,**kw):
        for _ in range(n):await self.tick(**kw)


@cocotb.test()
async def snapshots_independent_credits_and_visibility(d):
    t=OrderTest(d);d.rst_n.value=0;await t.idle();d.rst_n.value=1
    a,_=await t.tick(reg=(3,1));b,_=await t.tick(reg=(3,2));c,_=await t.tick(reg=(5,1))
    assert None not in (a,b,c)
    _,ok=await t.tick(order=pack_order(id=1,issuer=3,seq=10,kind=0,scope=3,addr=128,bytes=8));assert ok
    _,ok=await t.tick(order=pack_order(id=2,issuer=5,seq=10,kind=2,from_proxy=0,to_proxy=1));assert ok
    _,ok=await t.tick(order=pack_order(id=3,issuer=6,seq=1,kind=1));assert ok
    await t.idle(8)
    assert len(t.maint)==1 and t.maint[0]['issuer']==6 and not t.responses
    # Even an empty acquire waits for endpoint confirmation, not elapsed cycles.
    await t.idle(50);assert not t.responses
    await t.tick(ack=(t.maint[0]['id'],0));await t.idle();assert t.responses==[(3,0)]
    await t.tick(complete=(c,0));await t.idle()
    assert len(t.maint)==2 and t.maint[1]['issuer']==5
    later,_=await t.tick(reg=(3,11));assert later is None
    independent,_=await t.tick(reg=(7,1));assert independent is not None
    await t.tick(ack=(t.maint[1]['id'],0));await t.idle();assert t.responses[-1]==(2,0)
    await t.tick(complete=(b,0));await t.idle();assert len(t.maint)==2
    await t.tick(complete=(a,0));await t.idle(8,mready=False)
    assert len(t.maint)==2 and t.held is not None
    await t.tick();assert len(t.maint)==3
    assert t.maint[2]['scope']==3 and t.maint[2]['addr']==128
    await t.tick(ack=(t.maint[2]['id'],0));await t.idle(8,rready=False)
    later,_=await t.tick(reg=(3,11),rready=False);assert later is None
    await t.tick();later,_=await t.tick(reg=(3,11));assert later is not None
    await t.tick(complete=(independent,0));await t.tick(complete=(later,0));await t.idle()
    # Same-edge registration of a prior operation is part of the fence snapshot.
    early,ok=await t.tick(reg=(9,5),order=pack_order(id=9,issuer=9,seq=6,kind=2,to_proxy=2));assert early is not None and ok
    before=len(t.maint);await t.idle(8);assert len(t.maint)==before
    await t.tick(complete=(early,0));await t.idle();assert len(t.maint)==before+1
    await t.tick(ack=(t.maint[-1]['id'],0));await t.idle()
    assert not int(d.protocol_error_o.value)


@cocotb.test()
async def fault_epoch_and_proxy_views(d):
    t=OrderTest(d);d.rst_n.value=0;await t.idle();d.rst_n.value=1
    # Model distinct visibility views, deliberately stale until acknowledged
    # publication/acquisition. Completion is not a write into all dictionaries.
    generic={0:17};published={0:9};asynchronous={0:9}
    token,_=await t.tick(reg=(1,1));generic[0]=42
    await t.tick(order=pack_order(id=11,issuer=1,seq=2,kind=2,from_proxy=0,to_proxy=1))
    await t.idle(12);assert not t.maint and asynchronous[0]==9
    await t.tick(complete=(token,0));await t.idle();assert len(t.maint)==1 and asynchronous[0]==9
    published.update(generic)
    await t.tick(ack=(t.maint[-1]['id'],0));await t.idle();assert t.responses==[(11,0)]
    await t.tick(order=pack_order(id=12,issuer=2,seq=1,kind=1,from_proxy=0,to_proxy=1))
    await t.idle();assert len(t.maint)==2 and asynchronous[0]==9
    asynchronous.update(published)
    await t.tick(ack=(t.maint[-1]['id'],0));await t.idle();assert asynchronous[0]==42 and t.responses[-1]==(12,0)
    # Reused slots have a new token. A stale completion cannot release them.
    new,_=await t.tick(reg=(1,3));assert new!=token
    await t.tick(order=pack_order(id=13,issuer=1,seq=4));before=len(t.maint)
    await t.tick(complete=(token,0));await t.idle();assert len(t.maint)==before and int(d.protocol_error_o.value)
    await t.tick(complete=(new,1));await t.idle()
    await t.tick(ack=(t.maint[-1]['id'],0));await t.idle();assert t.responses[-1]==(13,1)
    await t.tick(order=pack_order(id=14,issuer=1,seq=5));await t.idle()
    await t.tick(ack=(t.maint[-1]['id'],0));await t.idle();assert t.responses[-1]==(14,1)
    # A maintenance failure also reaches a fence already queued behind it.
    await t.tick(order=pack_order(id=21,issuer=4,seq=1));await t.idle()
    first=t.maint[-1]['id']
    await t.tick(order=pack_order(id=22,issuer=4,seq=2));await t.idle()
    await t.tick(ack=(first,1));await t.idle(8);assert t.responses[-1]==(21,1)
    await t.tick(ack=(t.maint[-1]['id'],0));await t.idle();assert t.responses[-1]==(22,1)
