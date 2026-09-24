import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def real_threads_uniformity_release_and_reuse(d):
    issued=[];done=[];ihold=dhold=None
    async def tick(lane=None,release=None,ir=True,dr=True):
        nonlocal ihold,dhold
        d.clk.value=0;d.lane_vld_i.value=lane is not None;d.release_vld_i.value=release is not None
        for name,value in zip(('warp','thread','ticket','epoch','payload'),lane or (0,0,0,0,0)):
            getattr(d,'lane_'+name+'_i').value=value
        for name,value in zip(('warp','ticket','epoch','status'),release or (0,0,0,0)):
            getattr(d,'release_'+name+'_i').value=value
        d.issue_rdy_i.value=ir;d.done_rdy_i.value=dr
        await Timer(5,units='ns')
        iv=int(d.issue_vld_o.value);dv=int(d.done_vld_o.value)
        ip=tuple(int(getattr(d,'issue_'+n+'_o').value) for n in ('warp','ticket','epoch','payload'))
        dp=tuple(int(getattr(d,'done_'+n+'_o').value) for n in ('warp','ticket','epoch','status'))
        if ihold is not None:assert iv and ip==ihold
        if dhold is not None:assert dv and dp==dhold
        ihold=ip if iv and not ir else None;dhold=dp if dv and not dr else None
        if iv and ir:issued.append(ip)
        if dv and dr:done.append(dp)
        accepted=lane is not None and int(d.lane_rdy_o.value)
        d.clk.value=1;await Timer(5,units='ns')
        return accepted
    d.rst_n.value=0
    for _ in range(3):await tick()
    d.rst_n.value=1
    lanes=list(range(32));random.Random(2519).shuffle(lanes)
    for lane in lanes[:-1]:assert await tick((0,lane,10,1,0x123456))
    for _ in range(10):await tick()
    assert not issued and not done
    assert not await tick((0,lanes[0],10,1,0x123456)), 'a thread arrived twice'
    for lane in lanes:assert await tick((1,lane,11,1,0xdeadbeef),ir=False)
    for _ in range(10):await tick(ir=False)
    assert ihold==(1,11,1,0xdeadbeef) and not issued
    await tick();assert issued==[(1,11,1,0xdeadbeef)]
    for _ in range(10):await tick()
    assert not done,'issue is not permission to resume the warp'
    await tick(release=(1,11,1,0),dr=False)
    for _ in range(10):await tick(dr=False)
    assert dhold==(1,11,1,0)
    await tick();assert done==[(1,11,1,0)]
    # One differing operand rejects the collective; it never reaches execution.
    assert await tick((0,lanes[-1],10,1,0x123457))
    await tick();assert done[-1]==(0,10,1,1) and len(issued)==1
    # A new epoch requires a fresh 32-thread rendezvous and a matching release.
    for lane in lanes:assert await tick((1,lane,12,2,0xbead))
    await tick();assert issued[-1]==(1,12,2,0xbead)
    await tick(release=(1,11,1,0))
    for _ in range(6):await tick()
    assert len(done)==2 and int(d.protocol_error_o.value)
    await tick(release=(1,12,2,7));await tick()
    assert done[-1]==(1,12,2,7)
