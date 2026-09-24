"""Reference LSU contract for typed Blackwell requests (not a hardware LSU).

An atomic request is executed against the current destination in one operation.
Acknowledgement represents all writes/targets at the requested scope. An external
producer can contend before this indivisible operation; plain read/modify/write
requests never acquire atomic semantics just because their addresses match.
"""
from fractions import Fraction

# Independently transcribed PTX 9.4 combination tables. b32/b64 map to the
# unsigned descriptor width for bitwise operations in the project command ABI.
LINEAR = {0:{2,3,4,6,7,9,10},1:{2,3,4,5,6,10},2:{2,3,4,5,6,10},
          3:{2},4:{2},5:{2,4},6:{2,4},7:{2,4}}
SHARED = {0:{2,3,4},1:{2,3},2:{2,3},3:{2},4:{2},5:{2},6:{2},7:{2}}
TENSOR = {op:types-({9} if op==0 else set()) for op,types in LINEAR.items()}
TENSOR[0] = TENSOR[0] | {8}
WIDTH = {2:4,3:4,4:8,5:8,6:2,7:4,8:4,9:8,10:2}
FLOAT = {6:(5,10),7:(8,23),8:(8,23),9:(11,52),10:(8,7)}


def _decode(bits, exponent, fraction, ftz=False):
    exp=(bits>>fraction)&((1<<exponent)-1);mant=bits&((1<<fraction)-1)
    sign=-1 if bits>>(exponent+fraction) else 1
    if exp==(1<<exponent)-1:return ('nan' if mant else 'inf',sign)
    if ftz and exp==0:mant=0
    if exp:mant+=1<<fraction
    power=(exp if exp else 1)-((1<<(exponent-1))-1)-fraction
    return Fraction(sign*mant)*(Fraction(2)**power)


def _rne(value):
    q,r=divmod(value.numerator,value.denominator)
    return q+int(2*r>value.denominator or (2*r==value.denominator and q%2))


def _encode(value, exponent, fraction, zero_sign=0, ftz=False):
    if not value:return zero_sign<<(exponent+fraction)
    sign=int(value<0);x=abs(value);bias=(1<<(exponent-1))-1
    power=x.numerator.bit_length()-x.denominator.bit_length()
    if x<Fraction(2)**power:power-=1
    exp=max(0,power+bias)
    scale=(exp if exp else 1)-bias-fraction
    mant=_rne(x/(Fraction(2)**scale))
    if exp and mant>=1<<(fraction+1):mant>>=1;exp+=1
    if not exp and mant>=1<<fraction:exp=1
    if exp>=(1<<exponent)-1:return (sign<<(exponent+fraction))|(((1<<exponent)-1)<<fraction)
    if ftz and not exp:mant=0
    return (sign<<(exponent+fraction))|(exp<<fraction)|(mant&((1<<fraction)-1))


def reduce_value(old, source, dtype, op):
    width=WIDTH[dtype]*8;mask=(1<<width)-1
    if dtype in FLOAT:
        exp,frac=FLOAT[dtype];ftz=dtype==8
        a=_decode(old,exp,frac,ftz);b=_decode(source,exp,frac,ftz)
        nan=(((1<<exp)-1)<<frac)|(1<<(frac-1))
        if isinstance(a,tuple) and a[0]=='nan':return source if op in (1,2) else nan
        if isinstance(b,tuple) and b[0]=='nan':return old if op in (1,2) else nan
        if op==0:
            if isinstance(a,tuple) or isinstance(b,tuple):
                if isinstance(a,tuple) and isinstance(b,tuple) and a[1]!=b[1]:return nan
                return old if isinstance(a,tuple) else source
            zsign=int(old>>(width-1) and source>>(width-1))
            return _encode(a+b,exp,frac,zsign,ftz)
        # min/max: signed-zero tie preserves the PTX ordering of -0 and +0.
        def key(v,bits):
            if isinstance(v,tuple):return (0 if v[1]<0 else 2,Fraction(0),0)
            return (1,v,-int(bits>>(width-1)))
        take_old=key(a,old)<=key(b,source) if op==1 else key(a,old)>=key(b,source)
        return old if take_old else source
    signed=dtype in (3,5)
    a=old-(1<<width) if signed and old>>(width-1) else old
    b=source-(1<<width) if signed and source>>(width-1) else source
    if op==0:value=a+b
    elif op==1:value=min(a,b)
    elif op==2:value=max(a,b)
    elif op==3:value=0 if old>=source else old+1
    elif op==4:value=source if old==0 or old>source else old-1
    elif op==5:value=old&source
    elif op==6:value=old|source
    elif op==7:value=old^source
    else:raise ValueError('unknown reduction')
    return value&mask


def apply_write(memory, request, beat_bytes):
    addr=request['addr'];mask=request['mask'];data=request['data']
    if request['kind']==2:
        dtype=request['dtype'];width=WIDTH[dtype]
        for offset in range(0,beat_bytes,width):
            selected=(mask>>offset)&((1<<width)-1)
            if not selected:continue
            assert selected==(1<<width)-1, 'reduction must select whole elements'
            old=int.from_bytes(bytes(memory.get(addr+offset+i,0) for i in range(width)),'little')
            source=(data>>(8*offset))&((1<<(8*width))-1)
            result=reduce_value(old,source,dtype,request['reduce_op'])
            for i in range(width):memory[addr+offset+i]=(result>>(8*i))&255
    else:
        for i in range(beat_bytes):
            if mask>>i&1:memory[addr+i]=(data>>(8*i))&255
