"""Elastic dot pipelines: mixed cores, metadata lifetime and sustained issue."""
import random
import struct
import cocotb
from cocotb.triggers import Timer


def bits(value, half=False):
    return int.from_bytes(struct.pack('<e' if half else '<f', value), 'little')


def repeat(value, width, count):
    return sum(value << (width*i) for i in range(count))


async def cycle(d):
    d.clk.value = 0
    await Timer(5, units='ns')
    result = (int(d.in_rdy_o.value), int(d.out_vld_o.value),
              int(d.d_o.value), int(d.status_o.value), int(d.tag_o.value))
    d.clk.value = 1
    await Timer(5, units='ns')
    return result


async def reset(d):
    for key in ('rst_n', 'in_vld_i', 'out_rdy_i', 'tag_i', 'op_i', 'kind_i',
                'd_type_i', 'a_type_i', 'b_type_i', 'scale_type_i', 'scale_vec_i',
                'cta_group_i', 'enable_input_d_i', 'scale_input_d_i', 'a_vec_i',
                'b_vec_i', 'sparse_meta_i', 'c_i', 'a_sf_i', 'b_sf_i'):
        getattr(d, key).value = 0
    for _ in range(3):
        await cycle(d)
    d.rst_n.value = 1


def case(index):
    kind, dtype, elem, width, count = [
        (0, 1, 0x3c00, 16, 16), (0, 2, 0x3f80, 16, 16),
        (1, 3, 0x3f800000, 32, 8), (2, 4, 0x38, 8, 32),
        (3, 9, 1, 8, 32), (5, 8, 2, 4, 64),
    ][index % 6]
    half = kind in (0, 2) and dtype != 2 and index % 13 == 0
    dt = 11 if kind == 3 else 1 if half else 0
    c = index % 8
    req = dict(op_i=0, kind_i=kind, d_type_i=dt, a_type_i=dtype, b_type_i=dtype,
               scale_type_i=1 if kind == 5 else 0, scale_vec_i=2 if kind == 5 else 0,
               enable_input_d_i=1, scale_input_d_i=0, a_vec_i=repeat(elem,width,count),
               b_vec_i=repeat(elem,width,count), sparse_meta_i=0,
               c_i=c if kind == 3 else bits(c), a_sf_i=0x7f7f7f7f, b_sf_i=0x7f7f7f7f,
               tag_i=index & 65535)
    expected = (count+c if kind == 3 else bits(count+c, half), 0, index & 65535)
    if index % 29 == 7:
        req['kind_i'] = 15
        expected = (0, 1, index & 65535)
    elif index % 31 == 3:
        req['op_i'] = 1
        expected = (0, 2, index & 65535)
    return req, expected


@cocotb.test()
async def mixed_core_metadata_and_backpressure(d):
    await reset(d)
    rng = random.Random(917)
    accepted, retired = 0, 0
    expected = []
    held = None
    for tick in range(30000):
        valid = accepted < 600
        req, answer = case(accepted)
        for key, value in req.items():
            getattr(d, key).value = value
        ready = tick > 150 and rng.randrange(4) != 0
        d.in_vld_i.value = valid
        d.out_rdy_i.value = ready
        ir, ov, data, status, tag = await cycle(d)
        if held is not None:
            assert ov and (data, status, tag) == held
        held = (data, status, tag) if ov and not ready else None
        if valid and ir:
            accepted += 1
            expected.append(answer)
        if ov and ready:
            assert (data, status, tag) == expected[retired], (tick, retired, data, status, tag)
            retired += 1
        if retired == 600:
            break
    assert retired == accepted == 600


@cocotb.test()
async def all_kinds_4096_cycle_steady_throughput(d):
    modes = [
        ('fp16',0,1,0x3c00,16,16,0,0,0),
        ('bf16',0,2,0x3f80,16,16,0,0,0),
        ('tf32',1,3,0x3f800000,32,8,0,0,0),
        ('fp8',2,4,0x38,8,32,0,0,0),
        ('int8',3,9,1,8,32,0,0,0),
        ('mxf8',4,4,0x38,8,32,1,1,0x7f7f7f7f),
        ('mxf4',5,8,2,4,64,1,2,0x7f7f7f7f),
        ('nvf4',6,8,2,4,64,2,3,0x38383838),
    ]
    for name,kind,dtype,elem,width,count,scale_type,scale_vec,scale in modes:
        await reset(d)
        req = dict(op_i=0,kind_i=kind,a_type_i=dtype,b_type_i=dtype,
                   d_type_i=11 if kind==3 else 0,c_i=0,enable_input_d_i=0,
                   a_vec_i=repeat(elem,width,count),b_vec_i=repeat(elem,width,count),
                   scale_type_i=scale_type,scale_vec_i=scale_vec,a_sf_i=scale,b_sf_i=scale)
        for key,value in req.items():
            getattr(d,key).value = value
        d.out_rdy_i.value = 1
        issued = retired = steady = 0
        for tick in range(4200+200):
            d.in_vld_i.value = tick < 4200
            d.tag_i.value = issued
            ir, ov, data, status, tag = await cycle(d)
            if tick < 4200 and ir:
                issued += 1
            if ov:
                assert data == (count if kind==3 else bits(count)) and status == 0 and tag == retired, name
                retired += 1
                if 64 <= tick < 4160:
                    steady += 1
        assert retired == issued == 4200, name
        assert steady >= 4096 * 0.95, (name,steady)
        d._log.info('%s dot steady throughput: %d/4096 cycles, %g ops/cycle', name, steady, 2*count*steady/4096)
