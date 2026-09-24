from __future__ import annotations

import struct
import sys
import math
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MMA_SIM_ROOT = REPO_ROOT / "MMA-Sim"
if str(MMA_SIM_ROOT) not in sys.path:
    sys.path.insert(0, str(MMA_SIM_ROOT))

import torch
from mmasim.simulator.arithmetic import extract_significand_exponent, fused_sum


FP8_E4M3 = 0
FP8_E5M2 = 1
FP6_E2M3 = 0
FP6_E3M2 = 1
F4F6F8_TYPE_E4M3 = 0
F4F6F8_TYPE_E5M2 = 1
F4F6F8_TYPE_E2M3 = 2
F4F6F8_TYPE_E3M2 = 3
F4F6F8_TYPE_E2M1 = 4
FP8_ACC_FRAC_BITS = 25
CANONICAL_NAN_BITS = 0x7FFFFFFF
E8M0_BIAS = 127


def float32_to_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def bits_to_float32(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def unpack_u8_lanes(word: int, lanes: int = 32) -> list[int]:
    return [((word >> (8 * i)) & 0xFF) for i in range(lanes)]


def pack_u8_lanes(values: list[int]) -> int:
    word = 0
    for i, value in enumerate(values):
        word |= (value & 0xFF) << (8 * i)
    return word


def unpack_u6_lanes(word: int, lanes: int = 32) -> list[int]:
    return [((word >> (6 * i)) & 0x3F) for i in range(lanes)]


def pack_u6_lanes(values: list[int]) -> int:
    word = 0
    for i, value in enumerate(values):
        word |= (value & 0x3F) << (6 * i)
    return word


def unpack_u4_lanes(word: int, lanes: int = 32) -> list[int]:
    return [((word >> (4 * i)) & 0xF) for i in range(lanes)]


def pack_u4_lanes(values: list[int]) -> int:
    word = 0
    for i, value in enumerate(values):
        word |= (value & 0xF) << (4 * i)
    return word


def is_fp32_nan(bits: int) -> bool:
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    return exponent == 0xFF and fraction != 0


def is_fp32_inf(bits: int) -> bool:
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    return exponent == 0xFF and fraction == 0


def is_fp32_zero(bits: int) -> bool:
    return (bits & 0x7FFFFFFF) == 0


def fp32_sign(bits: int) -> int:
    return (bits >> 31) & 1


def e4m3_is_nan(raw: int) -> bool:
    return ((raw >> 3) & 0xF) == 0xF and (raw & 0x7) == 0x7


def e4m3_is_zero(raw: int) -> bool:
    return (raw & 0x7F) == 0


def e5m2_is_nan(raw: int) -> bool:
    return ((raw >> 2) & 0x1F) == 0x1F and (raw & 0x3) != 0


def e5m2_is_inf(raw: int) -> bool:
    return ((raw >> 2) & 0x1F) == 0x1F and (raw & 0x3) == 0


def e5m2_is_zero(raw: int) -> bool:
    return (raw & 0x7F) == 0


def fp8_sign(raw: int) -> int:
    return (raw >> 7) & 1


def f4f6f8_lane_width(value_type: int) -> int:
    if value_type == F4F6F8_TYPE_E2M1:
        return 4
    return 6 if value_type in {F4F6F8_TYPE_E2M3, F4F6F8_TYPE_E3M2} else 8


def f4f6f8_sign(raw: int, value_type: int) -> int:
    if value_type == F4F6F8_TYPE_E2M1:
        return (raw >> 3) & 1
    return (raw >> 5) & 1 if f4f6f8_lane_width(value_type) == 6 else (raw >> 7) & 1


def f4f6f8_is_zero(raw: int, value_type: int) -> bool:
    if value_type == F4F6F8_TYPE_E4M3:
        return e4m3_is_zero(raw)
    if value_type == F4F6F8_TYPE_E5M2:
        return e5m2_is_zero(raw)
    if value_type == F4F6F8_TYPE_E2M1:
        return (raw & 0x7) == 0
    return (raw & 0x1F) == 0


def f4f6f8_is_inf(raw: int, value_type: int) -> bool:
    return value_type == F4F6F8_TYPE_E5M2 and e5m2_is_inf(raw)


def f4f6f8_is_nan(raw: int, value_type: int) -> bool:
    if value_type == F4F6F8_TYPE_E4M3:
        return e4m3_is_nan(raw)
    if value_type == F4F6F8_TYPE_E5M2:
        return e5m2_is_nan(raw)
    return False


def fp8_tensor(raw_values: list[int], fp8_format: int) -> torch.Tensor:
    packed = torch.tensor(raw_values, dtype=torch.uint8)
    if fp8_format == FP8_E4M3:
        return packed.view(torch.float8_e4m3fn)
    return packed.view(torch.float8_e5m2)


def fp6_value(raw: int, fp6_format: int) -> float:
    sign = -1.0 if ((raw >> 5) & 1) else 1.0
    if fp6_format == FP6_E3M2:
        exponent = (raw >> 2) & 0x7
        mantissa = raw & 0x3
        bias = 3
        mantissa_bits = 2
    else:
        exponent = (raw >> 3) & 0x3
        mantissa = raw & 0x7
        bias = 1
        mantissa_bits = 3

    if exponent == 0 and mantissa == 0:
        return -0.0 if sign < 0.0 else 0.0
    if exponent == 0:
        return sign * (2.0 ** (1 - bias)) * (mantissa / (2.0 ** mantissa_bits))
    return sign * (2.0 ** (exponent - bias)) * (1.0 + mantissa / (2.0 ** mantissa_bits))


def fp6_tensor(raw_values: list[int], fp6_format: int) -> torch.Tensor:
    return torch.tensor([fp6_value(raw, fp6_format) for raw in raw_values], dtype=torch.float32)


def e2m1_value(raw: int) -> float:
    sign = -1.0 if ((raw >> 3) & 1) else 1.0
    magnitude = {
        0x0: 0.0,
        0x1: 0.5,
        0x2: 1.0,
        0x3: 1.5,
        0x4: 2.0,
        0x5: 3.0,
        0x6: 4.0,
        0x7: 6.0,
    }[raw & 0x7]
    if magnitude == 0.0:
        return -0.0 if sign < 0.0 else 0.0
    return sign * magnitude


def e2m1_tensor(raw_values: list[int]) -> torch.Tensor:
    return torch.tensor([e2m1_value(raw) for raw in raw_values], dtype=torch.float32)


def f4f6f8_tensor(raw_values: list[int], value_type: int) -> torch.Tensor:
    if value_type == F4F6F8_TYPE_E4M3:
        return fp8_tensor(raw_values, FP8_E4M3)
    if value_type == F4F6F8_TYPE_E5M2:
        return fp8_tensor(raw_values, FP8_E5M2)
    if value_type == F4F6F8_TYPE_E3M2:
        return fp6_tensor(raw_values, FP6_E3M2)
    if value_type == F4F6F8_TYPE_E2M1:
        return e2m1_tensor(raw_values)
    return fp6_tensor(raw_values, FP6_E2M3)


class F4F6F8DotMmaSimGolden:
    def __init__(self, n_fractional_bits: int = FP8_ACC_FRAC_BITS):
        self.n_fractional_bits = n_fractional_bits

    def __call__(
        self,
        a_bits: int,
        b_bits: int,
        c_bits: int,
        fp8_format: int,
        mxfp8_en: int = 0,
        a_mx_scale: int = E8M0_BIAS,
        b_mx_scale: int = E8M0_BIAS,
        fp6_en: int = 0,
        fp6_format: int = FP6_E2M3,
        a_type: int | None = None,
        b_type: int | None = None,
    ) -> int:
        if a_type is None:
            if fp6_en:
                a_type = F4F6F8_TYPE_E3M2 if fp6_format == FP6_E3M2 else F4F6F8_TYPE_E2M3
            else:
                a_type = F4F6F8_TYPE_E5M2 if fp8_format == FP8_E5M2 else F4F6F8_TYPE_E4M3
        if b_type is None:
            b_type = a_type

        a_width = f4f6f8_lane_width(a_type)
        b_width = f4f6f8_lane_width(b_type)
        a_raw = (
            unpack_u4_lanes(a_bits, lanes=32)
            if a_width == 4
            else unpack_u6_lanes(a_bits, lanes=32)
            if a_width == 6
            else unpack_u8_lanes(a_bits, lanes=32)
        )
        b_raw = (
            unpack_u4_lanes(b_bits, lanes=32)
            if b_width == 4
            else unpack_u6_lanes(b_bits, lanes=32)
            if b_width == 6
            else unpack_u8_lanes(b_bits, lanes=32)
        )

        if is_fp32_nan(c_bits) or (mxfp8_en and (a_mx_scale == 0xFF or b_mx_scale == 0xFF)):
            return CANONICAL_NAN_BITS

        has_pos_inf = is_fp32_inf(c_bits) and fp32_sign(c_bits) == 0
        has_neg_inf = is_fp32_inf(c_bits) and fp32_sign(c_bits) == 1
        has_nan = False
        has_zero_mul_inf = False

        for a_lane, b_lane in zip(a_raw, b_raw):
            a_is_nan = f4f6f8_is_nan(a_lane, a_type)
            b_is_nan = f4f6f8_is_nan(b_lane, b_type)
            a_is_inf = f4f6f8_is_inf(a_lane, a_type)
            b_is_inf = f4f6f8_is_inf(b_lane, b_type)
            a_is_zero = f4f6f8_is_zero(a_lane, a_type)
            b_is_zero = f4f6f8_is_zero(b_lane, b_type)

            has_nan |= a_is_nan or b_is_nan
            has_zero_mul_inf |= (a_is_zero and b_is_inf) or (a_is_inf and b_is_zero)

            lane_has_inf = ((a_is_inf and not b_is_zero and not b_is_nan) or
                            (b_is_inf and not a_is_zero and not a_is_nan))
            if lane_has_inf:
                lane_sign = f4f6f8_sign(a_lane, a_type) ^ f4f6f8_sign(b_lane, b_type)
                if lane_sign:
                    has_neg_inf = True
                else:
                    has_pos_inf = True

        if has_nan or has_zero_mul_inf or (has_pos_inf and has_neg_inf):
            return CANONICAL_NAN_BITS
        if has_pos_inf:
            return 0x7F800000
        if has_neg_inf:
            return 0xFF800000

        a = f4f6f8_tensor(a_raw, a_type)
        b = f4f6f8_tensor(b_raw, b_type)
        c = torch.tensor(bits_to_float32(c_bits), dtype=torch.float32)

        scale_exp_sum = (a_mx_scale - E8M0_BIAS) + (b_mx_scale - E8M0_BIAS) if mxfp8_en else 0
        significands = []
        exponents = []

        if not is_fp32_zero(c_bits):
            sc, ec = extract_significand_exponent(c, torch.float32)
            significands.append(sc)
            exponents.append(ec)

        for lane_idx, (a_lane, b_lane) in enumerate(zip(a_raw, b_raw)):
            if f4f6f8_is_zero(a_lane, a_type) or f4f6f8_is_zero(b_lane, b_type):
                continue

            sa, ea = extract_significand_exponent(a[lane_idx])
            sb, eb = extract_significand_exponent(b[lane_idx])
            significands.append(sa * sb)
            exponents.append(ea + eb + scale_exp_sum)

        if not significands:
            return 0

        s, e = fused_sum(significands, exponents, self.n_fractional_bits)
        if s != s:
            return CANONICAL_NAN_BITS
        if s + 1 == s:
            return float32_to_bits(torch.tensor(s, dtype=torch.float32).item())

        s, e = extract_significand_exponent(s * 2.0**e, torch.float32)
        s = math.trunc(s * 2.0**23) * 2.0**-23
        return float32_to_bits(torch.tensor(s * 2.0**e, dtype=torch.float32).item())
