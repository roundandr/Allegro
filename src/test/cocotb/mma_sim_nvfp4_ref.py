from __future__ import annotations

import struct
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
MMA_SIM_ROOT = REPO_ROOT / "MMA-Sim"
if str(MMA_SIM_ROOT) not in sys.path:
    sys.path.insert(0, str(MMA_SIM_ROOT))

import torch
from mmasim.simulator.arithmetic import nv_fused_dot_add_with_block_scale


FP4_DECODE = {
    0x0: 0.0,
    0x1: 0.5,
    0x2: 1.0,
    0x3: 1.5,
    0x4: 2.0,
    0x5: 3.0,
    0x6: 4.0,
    0x7: 6.0,
}

NVFP4_FRACTIONAL_BITS = 35
CANONICAL_NAN_BITS = 0x7FFFFFFF
FP4_MODE_NVFP4 = 0
FP4_MODE_MXFP4 = 1
FP4_MODE_FP4 = 2
FP4_MODE_MXFP4_4X = 3


def float32_to_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def bits_to_float32(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def decode_nvfp4(nibble: int) -> float:
    nibble &= 0xF
    magnitude = FP4_DECODE[nibble & 0x7]
    if nibble & 0x8:
        return -magnitude
    return magnitude


def unpack_fp4_lanes(word: int, lanes: int = 64) -> list[float]:
    return [decode_nvfp4((word >> (4 * i)) & 0xF) for i in range(lanes)]


def unpack_u8_lanes(word: int, lanes: int = 4) -> list[int]:
    return [((word >> (8 * i)) & 0xFF) for i in range(lanes)]


def pack_fp4_lanes(values: list[int]) -> int:
    word = 0
    for i, value in enumerate(values):
        word |= (value & 0xF) << (4 * i)
    return word


def pack_u8_lanes(values: list[int]) -> int:
    word = 0
    for i, value in enumerate(values):
        word |= (value & 0xFF) << (8 * i)
    return word


def is_fp32_nan(bits: int) -> bool:
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    return exponent == 0xFF and fraction != 0


def is_fp32_inf(bits: int) -> bool:
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    return exponent == 0xFF and fraction == 0


def is_ue4m3_nan(raw: int) -> bool:
    raw &= 0x7F
    exponent = (raw >> 3) & 0xF
    fraction = raw & 0x7
    return exponent == 0xF and fraction != 0


def is_e8m0_nan(raw: int) -> bool:
    return (raw & 0xFF) == 0xFF


def decode_ue4m3_fallback(raw: int) -> float:
    raw &= 0x7F
    exponent = (raw >> 3) & 0xF
    fraction = raw & 0x7
    if exponent == 0:
        if fraction == 0:
            return 0.0
        return (fraction / 8.0) * (2.0 ** -6)
    if exponent == 0xF:
        if fraction != 0:
            return float("nan")
        return 1.875 * (2.0**8)
    return (1.0 + fraction / 8.0) * (2.0 ** (exponent - 7))


def ue4m3_tensor(raw_values: list[int]) -> torch.Tensor:
    sanitized = [value & 0x7F for value in raw_values]
    if hasattr(torch, "float8_e4m3fn"):
        packed = torch.tensor(sanitized, dtype=torch.uint8)
        return packed.view(torch.float8_e4m3fn).abs()
    decoded = [decode_ue4m3_fallback(value) for value in sanitized]
    return torch.tensor(decoded, dtype=torch.float32)


def e8m0_tensor(raw_values: list[int]) -> torch.Tensor:
    decoded = [2.0 ** ((value & 0xFF) - 127) for value in raw_values]
    return torch.tensor(decoded, dtype=torch.float32)


class NVFP4DotMmaSimGolden:
    def __init__(self, n_fractional_bits: int = NVFP4_FRACTIONAL_BITS):
        self.n_fractional_bits = n_fractional_bits

    def __call__(
        self,
        a_fp4_bits: int,
        b_fp4_bits: int,
        a_sf_bits: int,
        b_sf_bits: int,
        c_fp32_bits: int,
        fp4_mode: int = FP4_MODE_NVFP4,
    ) -> int:
        a_sf_raw = unpack_u8_lanes(a_sf_bits, lanes=4)
        b_sf_raw = unpack_u8_lanes(b_sf_bits, lanes=4)

        if fp4_mode == FP4_MODE_NVFP4:
            if any(is_ue4m3_nan(x) for x in a_sf_raw + b_sf_raw):
                return CANONICAL_NAN_BITS
        elif fp4_mode == FP4_MODE_MXFP4:
            if any(is_e8m0_nan(x) for x in a_sf_raw[:2] + b_sf_raw[:2]):
                return CANONICAL_NAN_BITS
        elif fp4_mode == FP4_MODE_MXFP4_4X:
            if any(is_e8m0_nan(x) for x in a_sf_raw + b_sf_raw):
                return CANONICAL_NAN_BITS
        if is_fp32_nan(c_fp32_bits):
            return CANONICAL_NAN_BITS
        if is_fp32_inf(c_fp32_bits):
            return c_fp32_bits & 0xFFFFFFFF

        a = torch.tensor(unpack_fp4_lanes(a_fp4_bits), dtype=torch.float32)
        b = torch.tensor(unpack_fp4_lanes(b_fp4_bits), dtype=torch.float32)
        c = torch.tensor(bits_to_float32(c_fp32_bits), dtype=torch.float32)
        if fp4_mode == FP4_MODE_MXFP4:
            scale_a = e8m0_tensor(a_sf_raw[:2])
            scale_b = e8m0_tensor(b_sf_raw[:2])
        elif fp4_mode == FP4_MODE_MXFP4_4X:
            scale_a = e8m0_tensor(a_sf_raw)
            scale_b = e8m0_tensor(b_sf_raw)
        elif fp4_mode == FP4_MODE_FP4:
            scale_a = torch.ones(4, dtype=torch.float32)
            scale_b = torch.ones(4, dtype=torch.float32)
        else:
            scale_a = ue4m3_tensor(a_sf_raw)
            scale_b = ue4m3_tensor(b_sf_raw)

        result = nv_fused_dot_add_with_block_scale(
            a=a,
            b=b,
            c=c,
            scale_a=scale_a,
            scale_b=scale_b,
            n_fractional_bits=self.n_fractional_bits,
        )
        return float32_to_bits(result.item())
