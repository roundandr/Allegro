from __future__ import annotations

import struct
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
MMA_SIM_ROOT = REPO_ROOT / "MMA-Sim"
if str(MMA_SIM_ROOT) not in sys.path:
    sys.path.insert(0, str(MMA_SIM_ROOT))

import torch
from mmasim.simulator.arithmetic import nv_fused_dot_add


ACC_FRAC_BITS = 25
CANONICAL_NAN_BITS = 0x7FFFFFFF
FP16 = 0
BF16 = 1


def float32_to_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def bits_to_float32(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def pack_u16_lanes(values: list[int]) -> int:
    word = 0
    for index, value in enumerate(values):
        word |= (value & 0xFFFF) << (16 * index)
    return word


def unpack_u16_lanes(word: int, lanes: int = 16) -> list[int]:
    return [((word >> (16 * index)) & 0xFFFF) for index in range(lanes)]


def is_fp32_nan(bits: int) -> bool:
    return ((bits >> 23) & 0xFF) == 0xFF and (bits & 0x7FFFFF) != 0


def is_fp32_inf(bits: int) -> bool:
    return ((bits >> 23) & 0xFF) == 0xFF and (bits & 0x7FFFFF) == 0


def fp32_sign(bits: int) -> int:
    return (bits >> 31) & 1


def fp16_is_zero(raw: int) -> bool:
    return (raw & 0x7FFF) == 0


def fp16_is_inf(raw: int) -> bool:
    return ((raw >> 10) & 0x1F) == 0x1F and (raw & 0x03FF) == 0


def fp16_is_nan(raw: int) -> bool:
    return ((raw >> 10) & 0x1F) == 0x1F and (raw & 0x03FF) != 0


def bf16_is_zero(raw: int) -> bool:
    return (raw & 0x7FFF) == 0


def bf16_is_inf(raw: int) -> bool:
    return ((raw >> 7) & 0xFF) == 0xFF and (raw & 0x007F) == 0


def bf16_is_nan(raw: int) -> bool:
    return ((raw >> 7) & 0xFF) == 0xFF and (raw & 0x007F) != 0


def fp16_bf16_sign(raw: int) -> int:
    return (raw >> 15) & 1


def lane_tensor(raw_values: list[int], fmt_is_bf16: int) -> torch.Tensor:
    packed = torch.tensor(raw_values, dtype=torch.uint16)
    if fmt_is_bf16:
        return packed.view(torch.bfloat16)
    return packed.view(torch.float16)


class FP16DotMmaSimGolden:
    def __init__(self, n_fractional_bits: int = ACC_FRAC_BITS):
        self.n_fractional_bits = n_fractional_bits

    def __call__(
        self,
        a_bits: int,
        b_bits: int,
        c_bits: int,
        fmt_is_bf16: int,
        b_fmt_is_bf16: int | None = None,
    ) -> int:
        a_raw = unpack_u16_lanes(a_bits)
        b_raw = unpack_u16_lanes(b_bits)
        a_fmt_is_bf16 = fmt_is_bf16
        if b_fmt_is_bf16 is None:
            b_fmt_is_bf16 = fmt_is_bf16

        if is_fp32_nan(c_bits):
            return CANONICAL_NAN_BITS

        has_pos_inf = is_fp32_inf(c_bits) and fp32_sign(c_bits) == 0
        has_neg_inf = is_fp32_inf(c_bits) and fp32_sign(c_bits) == 1
        has_nan = False
        has_zero_mul_inf = False

        for a_lane, b_lane in zip(a_raw, b_raw):
            if a_fmt_is_bf16:
                a_is_zero = bf16_is_zero(a_lane)
                a_is_inf = bf16_is_inf(a_lane)
                a_is_nan = bf16_is_nan(a_lane)
            else:
                a_is_zero = fp16_is_zero(a_lane)
                a_is_inf = fp16_is_inf(a_lane)
                a_is_nan = fp16_is_nan(a_lane)

            if b_fmt_is_bf16:
                b_is_zero = bf16_is_zero(b_lane)
                b_is_inf = bf16_is_inf(b_lane)
                b_is_nan = bf16_is_nan(b_lane)
            else:
                b_is_zero = fp16_is_zero(b_lane)
                b_is_inf = fp16_is_inf(b_lane)
                b_is_nan = fp16_is_nan(b_lane)

            has_nan |= a_is_nan or b_is_nan
            has_zero_mul_inf |= (a_is_zero and b_is_inf) or (a_is_inf and b_is_zero)

            lane_has_inf = ((a_is_inf and not b_is_zero and not b_is_nan) or
                            (b_is_inf and not a_is_zero and not a_is_nan))
            if lane_has_inf:
                lane_sign = fp16_bf16_sign(a_lane) ^ fp16_bf16_sign(b_lane)
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

        a = lane_tensor(a_raw, a_fmt_is_bf16)
        b = lane_tensor(b_raw, b_fmt_is_bf16)
        c = torch.tensor(bits_to_float32(c_bits), dtype=torch.float32)
        result = nv_fused_dot_add(
            a=a,
            b=b,
            c=c,
            n_fractional_bits=self.n_fractional_bits,
            output_type="f32",
        )
        return float32_to_bits(result.item())
