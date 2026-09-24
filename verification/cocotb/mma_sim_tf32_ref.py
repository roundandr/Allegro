from __future__ import annotations

import struct
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MMA_SIM_ROOT = REPO_ROOT / "MMA-Sim"
if str(MMA_SIM_ROOT) not in sys.path:
    sys.path.insert(0, str(MMA_SIM_ROOT))

import torch
from mmasim.simulator.arithmetic import nv_fused_dot_add, truncate_to_tf32


ACC_FRAC_BITS = 25
CANONICAL_NAN_BITS = 0x7FFFFFFF


def float32_to_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def bits_to_float32(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def pack_u32_lanes(values: list[int]) -> int:
    word = 0
    for index, value in enumerate(values):
        word |= (value & 0xFFFFFFFF) << (32 * index)
    return word


def unpack_u32_lanes(word: int, lanes: int = 8) -> list[int]:
    return [((word >> (32 * index)) & 0xFFFFFFFF) for index in range(lanes)]


def is_fp32_nan(bits: int) -> bool:
    return ((bits >> 23) & 0xFF) == 0xFF and (bits & 0x7FFFFF) != 0


def is_fp32_inf(bits: int) -> bool:
    return ((bits >> 23) & 0xFF) == 0xFF and (bits & 0x7FFFFF) == 0


def tf32_is_zero(bits: int) -> bool:
    return ((bits >> 23) & 0xFF) == 0 and ((bits >> 13) & 0x3FF) == 0


def fp32_sign(bits: int) -> int:
    return (bits >> 31) & 1


def lane_tensor(raw_values: list[int]) -> torch.Tensor:
    raw = torch.tensor(raw_values, dtype=torch.uint32)
    return truncate_to_tf32(raw.view(torch.float32))


class TF32DotMmaSimGolden:
    def __init__(self, n_fractional_bits: int = ACC_FRAC_BITS):
        self.n_fractional_bits = n_fractional_bits

    def __call__(self, a_bits: int, b_bits: int, c_bits: int) -> int:
        a_raw = unpack_u32_lanes(a_bits)
        b_raw = unpack_u32_lanes(b_bits)

        if is_fp32_nan(c_bits):
            return CANONICAL_NAN_BITS

        has_pos_inf = is_fp32_inf(c_bits) and fp32_sign(c_bits) == 0
        has_neg_inf = is_fp32_inf(c_bits) and fp32_sign(c_bits) == 1
        has_nan = False
        has_zero_mul_inf = False

        for a_lane, b_lane in zip(a_raw, b_raw):
            a_is_zero = tf32_is_zero(a_lane)
            b_is_zero = tf32_is_zero(b_lane)
            a_is_inf = is_fp32_inf(a_lane)
            b_is_inf = is_fp32_inf(b_lane)
            a_is_nan = is_fp32_nan(a_lane)
            b_is_nan = is_fp32_nan(b_lane)

            has_nan |= a_is_nan or b_is_nan
            has_zero_mul_inf |= (a_is_zero and b_is_inf) or (a_is_inf and b_is_zero)

            lane_has_inf = ((a_is_inf and not b_is_zero and not b_is_nan) or
                            (b_is_inf and not a_is_zero and not a_is_nan))
            if lane_has_inf:
                lane_sign = fp32_sign(a_lane) ^ fp32_sign(b_lane)
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

        a = lane_tensor(a_raw)
        b = lane_tensor(b_raw)
        c = torch.tensor(bits_to_float32(c_bits), dtype=torch.float32)
        result = nv_fused_dot_add(
            a=a,
            b=b,
            c=c,
            n_fractional_bits=self.n_fractional_bits,
            output_type="f32",
        )
        return float32_to_bits(result.item())
