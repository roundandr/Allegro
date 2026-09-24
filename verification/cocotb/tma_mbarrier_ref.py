"""SM100a semantic reference. Internal descriptor encoding is NOT CUtensorMap.

Coordinates are fastest dimension first: C,W,H,D,N (omit unused spatial dims).
See doc/tma_spec.md for the PTX/Driver API sources and unsupported modes.
"""
from dataclasses import dataclass
from itertools import product

TILE, IM2COL, IM2COL_W, IM2COL_W128, IM2COL_NO_OFFS, GATHER4, SCATTER4 = range(7)
TYPE_BITS = (8,16,32,32,64,64,16,32,32,64,16,32,32,4,4,6)


def swizzle_address(address, mode):
    """PTX §5.5.7 byte permutation, including the absolute base offset."""
    if mode == 0:
        return address
    atom = {1: 16, 2: 16, 3: 16, 4: 32, 5: 32, 6: 64}[mode]
    span = {1: 32, 2: 64}.get(mode, 128)
    row = address // 128
    result = address ^ ((row % (span // atom)) * atom)
    if mode == 5 and row % 2:
        result ^= 8
    return result


@dataclass(frozen=True)
class TensorDescriptor:
    dims: int
    elem_bytes: int
    base: int
    sizes: tuple
    strides: tuple
    box: tuple
    traversal: tuple
    kind: int = 0  # tile=0, im2col=1, wide im2col=2
    swizzle: int = 0
    lower: tuple = (0, 0, 0)
    upper: tuple = (0, 0, 0)
    channels: int = 16
    pixels: int = 1
    dtype: int = None
    interleave: int = 0
    oob_fill: int = 0
    l2_promotion: int = 0
    cache_hint: int = 0
    cache_policy: int = 0

    @property
    def data_type(self):
        return {1:0,2:1,4:2,8:4}[self.elem_bytes] if self.dtype is None else self.dtype

    @property
    def element_bits(self):
        return TYPE_BITS[self.data_type]

    @property
    def slice_channels(self):
        return (16 if self.interleave == 1 else 32)*8//self.element_bits

    def encode(self):
        if not 1 <= self.dims <= 5 or not 0 <= self.data_type <= 15:
            raise ValueError('unsupported rank or element width')
        def unsigned(value, width, name):
            if not isinstance(value, int) or not 0 <= value < 1 << width:
                raise ValueError(f'{name} is not representable as u{width}')
        for name, value, width in [('base',self.base,64),('kind',self.kind,2),
                ('swizzle',self.swizzle,4),('channels',self.channels,16),('pixels',self.pixels,16)]:
            unsigned(value,width,name)
        for name, values, width in [('stride',self.strides,64),('box',self.box,16),
                                   ('traversal',self.traversal,16)]:
            if len(values) != self.dims:
                raise ValueError(f'{name}: expected rank entries')
            for v in values:
                unsigned(v,width,name)
        if len(self.sizes) != self.dims or len(self.lower) != 3 or len(self.upper) != 3:
            raise ValueError('dimension or corner vector length mismatch')
        if any(not -(1<<15) <= v < 1<<15 for v in (*self.lower,*self.upper)):
            raise ValueError('corner is not representable as s16')
        value = 3 | ((self.dims - 1) << 8)
        value |= self.kind << 14
        value |= self.base << 16
        for d in range(5):
            if d < self.dims:
                if not 1 <= self.sizes[d] <= 2**32:
                    raise ValueError('globalDim outside [1, 2^32]')
                value |= (self.sizes[d] - 1) << (80 + 32*d)
                value |= self.strides[d] << (240 + 64*d)
                value |= self.box[d] << (560 + 16*d)
                value |= self.traversal[d] << (640 + 16*d)
        value |= min(self.swizzle,3) << 720
        value |= max(0,self.swizzle-3) << 724
        for d in range(3):
            value |= (self.lower[d] & 0xffff) << (736 + 16*d)
            value |= (self.upper[d] & 0xffff) << (784 + 16*d)
        value |= self.channels << 832
        value |= self.pixels << 848
        for v,w,name in [(self.interleave,2,'interleave'),(self.oob_fill,1,'fill'),
                         (self.l2_promotion,2,'l2 promotion'),(self.cache_hint,1,'cache hint'),
                         (self.cache_policy,64,'cache policy')]: unsigned(v,w,name)
        value |= self.data_type << 864
        value |= self.interleave << 868
        value |= self.oob_fill << 870
        value |= self.l2_promotion << 871
        value |= self.cache_hint << 873
        value |= self.cache_policy << 880
        return value.to_bytes(128, 'little')

    @property
    def logical_bytes(self):
        return self.byte_count(TILE)

    def byte_count(self, mode=TILE, halo=0):
        if mode in (TILE, GATHER4, SCATTER4):
            n = 1
            for d in range(self.dims):
                step = self.traversal[d] if d or self.interleave else 1
                if self.interleave and d == 0:
                    n *= (self.box[d]+self.slice_channels*step-1)//(self.slice_channels*step)*self.slice_channels
                else:
                    n *= (self.box[d]+step-1)//step
            if mode in (GATHER4, SCATTER4): n *= 4
        else:
            channels = self.channels
            if self.interleave:
                channels = (channels+self.slice_channels-1)//self.slice_channels*self.slice_channels
            n = channels * ((128+4*halo) if mode == IM2COL_W128 else self.pixels+(halo if mode == IM2COL_W else 0))
        return n*self.element_bits//8

    def coordinates(self, start, mode=TILE, offsets=(0, 0, 0), halo=0, w_offset=0):
        if mode in (GATHER4, SCATTER4):
            for row in start[1:5]:
                for c in range(self.box[0]):
                    yield (start[0]+c,row)
            return
        if mode == TILE:
            if self.interleave:
                # Project coordinates remain C,W,H,D,N. The physical interleaved
                # order is C-inner,W,H,D,C-outer,N; partial C slices are padded.
                per = self.slice_channels
                ext = [range(0,self.box[d],self.traversal[d]) for d in range(1,self.dims)]
                groups = range(0,(self.box[0]+per-1)//per,self.traversal[0])
                for n in ext[-1]:
                    for cg in groups:
                        for rev in product(*reversed(ext[:-1])):
                            spatial = list(reversed(rev))
                            for ci in range(per):
                                yield (start[0]+cg*per+ci,*(start[d+1]+v for d,v in enumerate(spatial)),start[-1]+n)
                return
            ranges = [range(0, self.box[d], self.traversal[d] if d else 1)
                      for d in reversed(range(self.dims))]
            for rev in product(*ranges):
                yield tuple(start[d] + list(reversed(rev))[d] for d in range(self.dims))
            return
        wide = mode in (IM2COL_W, IM2COL_W128)
        effective_channels = ((self.channels+self.slice_channels-1)//self.slice_channels*self.slice_channels) if self.interleave else self.channels
        n_pixels = self.byte_count(mode, halo)*8 // self.element_bits // effective_channels
        # This model advances a coordinate cursor rather than duplicating the
        # RTL's quotient/remainder address calculation.
        position = list(start[:self.dims])
        if wide:
            position[1] += w_offset
        lower = list(self.lower)
        if wide:
            lower[0] += w_offset
        high = [self.sizes[d+1] + self.upper[d] + (w_offset if wide and d == 0 else 0)
                for d in range(self.dims - 2)]
        points = []
        needed = max(n_pixels, 128 + halo) if mode == IM2COL_W128 else n_pixels
        for _ in range(needed):
            points.append(position.copy())
            spatial = [1] if wide else range(1, self.dims - 1)
            for d in spatial:
                position[d] += self.traversal[d]
                if position[d] < high[d-1]:
                    break
                position[d] = lower[d-1]
            else:
                position[-1] += 1
        for p in range(n_pixels):
            # Four halo sets are appended after the 128 main pixels (PTX Fig.20).
            index = p if mode != IM2COL_W128 or p < 128 else (
                ((p-128)//halo + 1)*32 + (p-128) % halo)
            for c in range(effective_channels):
                q = points[index].copy()
                q[0] += c
                if not wide and mode != IM2COL_NO_OFFS:
                    for d in range(1, self.dims-1):
                        q[d] += offsets[d-1]
                yield tuple(q)

    def smem_address(self, base, logical, mode=TILE):
        inner_elements = self.box[0] if mode in (TILE,GATHER4,SCATTER4) else self.channels
        inner = inner_elements*self.element_bits//8
        storage = logical
        if self.data_type in (14,15):
            payload = 8 if self.data_type==14 else 12
            storage = (logical//payload)*16+logical%payload
            inner = inner_elements  # one 16B container per 16 channels
        if self.interleave:
            inner = 16 if self.interleave==1 else 32
        pitch = {1:32,2:64}.get(self.swizzle,128) if self.swizzle else inner
        return swizzle_address(base+(storage//inner)*pitch+storage%inner,self.swizzle)

    def global_bit_address(self, coords):
        if any(coords[d]<0 or coords[d]>=self.sizes[d] for d in range(self.dims)):
            return None
        if self.interleave:
            per = self.slice_channels
            return self.base*8+(coords[0]%per)*self.element_bits+(coords[0]//per)*self.strides[0]*8+sum(
                coords[d]*self.strides[d]*8 for d in range(1,self.dims))
        return self.base*8+coords[0]*self.element_bits+sum(coords[d]*self.strides[d]*8 for d in range(1,self.dims))

    def elements(self,start,mode=TILE,offsets=(0,0,0),halo=0,w_offset=0):
        for index,coords in enumerate(self.coordinates(start,mode,offsets,halo,w_offset)):
            bits=self.global_bit_address(coords)
            yield index*self.element_bits//8,None if bits is None else bits//8

    def load(self,memory,start,**kwargs):
        # Integer bitstream assembly is independent of the RTL's byte requests.
        result=0;count=0
        for coords in self.coordinates(start,**kwargs):
            bitaddr=self.global_bit_address(coords)
            bits=self.element_bits
            if bitaddr is None:
                value=int.from_bytes(bytes([0xf7,0x7f])*(bits//16),'little') if self.oob_fill else 0
            else:
                word=int.from_bytes(bytes(memory.get(bitaddr//8+b,0) for b in range((bits+7)//8+1)),'little')
                value=(word>>(bitaddr%8))&((1<<bits)-1)
                if self.data_type in (11,12): value=tf32_rne(value)
            result|=value<<count;count+=bits
        return result.to_bytes((count+7)//8,'little')

    def store(self,memory,start,source,**kwargs):
        bits=self.element_bits
        expected=self.byte_count(kwargs.get('mode',TILE),kwargs.get('halo',0))
        if len(source)!=expected:raise ValueError('source length mismatch')
        result=dict(memory);packed=int.from_bytes(source,'little')
        for index,coords in enumerate(self.coordinates(start,**kwargs)):
            bitaddr=self.global_bit_address(coords)
            if bitaddr is None:continue
            value=(packed>>(index*bits))&((1<<bits)-1)
            for b in range(bits):
                byte,shift=divmod(bitaddr+b,8)
                result[byte]=(result.get(byte,0)&~(1<<shift))|(((value>>b)&1)<<shift)
        return result


def tf32_rne(word):
    """RNE with explicit tie parity; the chosen NaN is project-defined.

    The SM120a oracle preserves f32(.ftz) transfer bits and uses the same tf32
    conversion for both descriptor variants. FTZ type attributes are retained
    for typed reduction backends; no arithmetic-consumer behavior is inferred.
    """
    if (word&0x7f800000)==0x7f800000:
        return 0x7fffe000 if word&0x7fffff else word
    sign=word&0x80000000
    magnitude=word&0x7fffffff
    quotient,remainder=divmod(magnitude,8192)
    if remainder>4096 or (remainder==4096 and quotient%2):quotient+=1
    return sign|(quotient<<13)


@dataclass(frozen=True)
class ArrivalToken:
    phase: int
    pending: int
    layout: int
    no_complete: bool


class MBarrierModel:
    """State semantics independent of the RTL's b64 backing or token encoding."""
    MAX_COUNT = (1 << 20) - 1

    def __init__(self):
        self.valid = self.locked = False
        self.phase = self.conditional = self.expected = self.remaining = self.tx_count = 0
        self.layout = 0
        self.reports = [0, 0]

    def init(self, expected, layout=0):
        if self.locked:
            raise ValueError('INVAL required after project fault')
        if layout not in (0, 1) or not 1 <= expected <= (511 if layout else self.MAX_COUNT):
            raise ValueError('arrival count or layout out of range')
        self.__init__()
        self.valid, self.layout = True, layout
        self.expected = self.remaining = expected

    def inval(self):
        self.__init__()

    def _advance(self):
        if self.remaining == self.tx_count == 0:
            if not self.reports[self.phase]:
                self.conditional ^= 1
            self.phase ^= 1
            self.reports[self.phase] = 0
            self.remaining = self.expected

    def report(self, value):
        if not self.layout or not 0 <= value <= 255:
            raise ValueError('report requires layout v1 and b8 producer value')
        # Project producer contract merges independent report bits with OR;
        # PTX does not prescribe an encoding for arbitrary external producers.
        self.reports[self.phase] |= value

    def pending_inc(self):
        if self.remaining == (511 if self.layout else self.MAX_COUNT):
            raise ValueError('pending count overflow')
        self.remaining += 1

    def expect(self, count):
        if not 0 <= count <= self.MAX_COUNT:
            raise ValueError('invalid expect count')
        self._tx(count)

    def complete(self, count):
        if not 0 <= count <= self.MAX_COUNT:
            raise ValueError('invalid complete count')
        self._tx(-count)

    def _tx(self, delta):
        if abs(self.tx_count + delta) > self.MAX_COUNT:
            self.locked = True
            raise OverflowError('tx-count outside signed PTX range')
        self.tx_count += delta
        self._advance()

    def arrive(self, count=1, expect_bytes=None, drop=False, no_complete=False):
        if expect_bytes is not None:
            if no_complete:
                raise ValueError('expect_tx/noComplete is not a legal combination')
            count = 1
        token = ArrivalToken(self.phase, self.remaining, self.layout, no_complete)
        tx = self.tx_count + (expect_bytes or 0)
        if expect_bytes is not None and not 0 <= expect_bytes <= self.MAX_COUNT:
            raise ValueError('invalid expectation')
        if abs(tx) > self.MAX_COUNT:
            raise OverflowError('tx-count outside range')
        if not 1 <= count <= self.remaining or (drop and count >= self.expected):
            raise ValueError('invalid arrival count')
        pending = self.remaining - count
        if no_complete and pending == tx == 0:
            raise ValueError('noComplete may not complete a phase')
        self.tx_count, self.remaining = tx, pending
        if drop:
            self.expected -= count
        self._advance()
        return token

    @staticmethod
    def pending_count(token):
        if token.layout or not token.no_complete:
            raise ValueError('pending_count requires a v0 noComplete token')
        return token.pending

    def wait_ready(self, phase, conditional=False):
        return self.valid and not self.locked and (self.conditional if conditional else self.phase) != phase

    def wait(self, phase, conditional=False):
        complete = self.wait_ready(phase, conditional)
        # Unsuccessful wait report is deliberately unspecified in the model.
        report = self.reports[phase] if complete and not conditional else None
        return complete, report
