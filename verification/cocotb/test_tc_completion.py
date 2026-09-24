"""Independent set-based scoreboard for TC commit snapshots."""
import random
import cocotb
from cocotb.triggers import Timer


def identity(issuer, seq, epoch=1):
    return (((((issuer << 5) | (issuer//32)) << 16 | (seq & 65535)) << 64 | seq) << 16) | epoch


def issuer(key):
    return key >> 101


class Model:
    def __init__(self, dut):
        self.d = dut
        self.live = set()
        self.commits = {}
        self.poisoned = set()
        self.held = None
        self.arrivals = []

    async def tick(self, register=None, complete=None, commit=None, ready=True, status=0, domain=0):
        d = self.d
        d.clk.value = 0
        d.register_vld_i.value = register is not None
        d.register_i.value = register or 0
        d.complete_vld_i.value = complete is not None
        d.complete_i.value = ((complete or 0) << 75) | (domain << 72) | (status << 64)
        d.commit_vld_i.value = commit is not None
        d.commit_i.value = ((commit or 0) << 64) | 0x800
        d.arrival_rdy_i.value = ready
        await Timer(5, units='ns')
        reg_fire = register is not None and int(d.register_rdy_o.value)
        com_fire = commit is not None and int(d.commit_rdy_o.value)
        arrived = int(d.arrival_vld_o.value)
        packet = (int(d.arrival_o.value), int(d.arrival_status_o.value))
        if self.held is not None:
            assert arrived and packet == self.held
        self.held = packet if arrived and not ready else None
        if arrived and ready:
            key = packet[0] >> 64
            pending, error = self.commits.pop(key)
            assert not pending, ('premature arrival', key, pending)
            assert packet[1] == error, (packet, error)
            self.arrivals.append(key)
        bad = complete is not None and (complete not in self.live or domain != 0)
        assert int(d.protocol_error_o.value) == bad
        if complete is not None and not bad:
            self.live.remove(complete)
            for key, (pending, error) in list(self.commits.items()):
                depended_on_completion = complete in pending
                pending.discard(complete)
                if status and depended_on_completion:
                    self.commits[key] = (pending, 2)
            if status:
                self.poisoned.add(issuer(complete))
        if com_fire:
            self.commits[commit] = ({x for x in self.live if issuer(x) == issuer(commit)
                                    and x & 65535 == commit & 65535},
                                   2 if issuer(commit) in self.poisoned else 0)
        if reg_fire:
            assert register not in self.live
            self.live.add(register)
        d.clk.value = 1
        await Timer(5, units='ns')
        return reg_fire, com_fire

    async def send(self, **kw):
        for _ in range(1000):
            r, c = await self.tick(**kw)
            if (r if 'register' in kw else c):
                return
        raise AssertionError(('request blocked', kw))


@cocotb.test()
async def snapshots_pressure_epochs_and_errors(d):
    m = Model(d)
    d.rst_n.value = 0
    for _ in range(3): await m.tick()
    d.rst_n.value = 1
    # Another issuer's empty commit must bypass a blocked issuer's commit.
    a = identity(0,1)
    await m.send(register=a)
    c0,c1 = identity(0,10),identity(32,10)
    await m.send(commit=c0)
    await m.send(commit=c1)
    for _ in range(12): await m.tick()
    assert c1 in m.arrivals and c0 not in m.arrivals
    await m.tick(complete=a)
    for _ in range(12): await m.tick()
    assert c0 in m.arrivals
    # Repeat snapshots do not absorb later registrations or recycled slots.
    a,b = identity(0,20), identity(0,21)
    await m.send(register=a)
    await m.send(commit=identity(0,30))
    await m.send(commit=identity(0,31))
    await m.tick(complete=a, ready=False)
    await m.send(register=b, ready=False)
    for _ in range(8): await m.tick(ready=False)
    for _ in range(12): await m.tick()
    assert identity(0,30) in m.arrivals and identity(0,31) in m.arrivals
    assert b in m.live
    await m.tick(complete=b)
    # Stale epoch and wrong completion domain cannot release live work.
    new = identity(0,20,2)
    await m.send(register=new)
    await m.send(commit=identity(0,40,2))
    await m.tick(complete=a)
    await m.tick(complete=new,domain=3)
    for _ in range(8): await m.tick()
    assert new in m.live and identity(0,40,2) not in m.arrivals
    await m.tick(complete=new)
    for _ in range(8): await m.tick()
    # Exhaust both tables, return completions out of order under output stalls.
    rng = random.Random(917)
    reg_seq, com_seq = 100, 10000
    for tick in range(2500):
        reg = identity(rng.choice((0,32,64)),reg_seq) if rng.randrange(3) else None
        com = identity(rng.choice((0,32,64)),com_seq) if rng.randrange(3) else None
        done = rng.choice(sorted(m.live)) if m.live and rng.randrange(3) else None
        r,c = await m.tick(register=reg,commit=com,complete=done,ready=tick%101>50)
        reg_seq += int(r); com_seq += int(c)
    for key in sorted(m.live): await m.tick(complete=key)
    for _ in range(100): await m.tick()
    assert not m.live and not m.commits
    # An execution error produces a fault notification, including later commits.
    a=identity(64,30000)
    await m.send(register=a)
    await m.send(commit=identity(64,30001))
    await m.tick(complete=a,status=7)
    for _ in range(12): await m.tick()
    await m.send(commit=identity(64,30002))
    for _ in range(12): await m.tick()
    assert not m.commits
    # A later failing operation cannot retroactively poison an earlier empty
    # snapshot, including one held in the output register under backpressure.
    earlier=identity(96,40000)
    await m.send(commit=earlier,ready=False)
    for _ in range(4): await m.tick(ready=False)
    later=identity(96,40001)
    await m.send(register=later,ready=False)
    await m.tick(complete=later,status=3,ready=False)
    for _ in range(4): await m.tick(ready=False)
    for _ in range(4): await m.tick()
    assert earlier in m.arrivals
    await m.send(commit=identity(96,40002))
    for _ in range(8): await m.tick()
    assert not m.commits
