from __future__ import annotations

import json
import random
import struct
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
MMA_SIM_ROOT = REPO_ROOT / "MMA-Sim"
if str(MMA_SIM_ROOT) not in sys.path:
    sys.path.insert(0, str(MMA_SIM_ROOT))

from mma_sim_f4f6f8_ref import (
    E8M0_BIAS,
    F4F6F8DotMmaSimGolden,
    F4F6F8_TYPE_E2M1,
    F4F6F8_TYPE_E2M3,
    F4F6F8_TYPE_E3M2,
    F4F6F8_TYPE_E4M3,
    F4F6F8_TYPE_E5M2,
    FP6_E2M3,
    FP6_E3M2,
    FP8_E4M3,
    FP8_E5M2,
    pack_u6_lanes,
    pack_u8_lanes,
)
from mma_sim_fp16_ref import BF16, FP16, FP16DotMmaSimGolden, pack_u16_lanes
from mma_sim_nvfp4_ref import (
    FP4_MODE_MXFP4,
    FP4_MODE_MXFP4_4X,
    FP4_MODE_NVFP4,
    NVFP4DotMmaSimGolden,
    pack_fp4_lanes,
)
from mma_sim_tf32_ref import TF32DotMmaSimGolden, pack_u32_lanes


TCGEN05_OP_MMA = 0
TCGEN05_OP_SP = 1
TCGEN05_OP_WS = 2
TCGEN05_OP_WS_SP = 3

TCGEN05_KIND_F16 = 0
TCGEN05_KIND_TF32 = 1
TCGEN05_KIND_F8F6F4 = 2
TCGEN05_KIND_I8 = 3
TCGEN05_KIND_MXF8F6F4 = 4
TCGEN05_KIND_MXF4 = 5
TCGEN05_KIND_MXF4NVF4 = 6

TCGEN05_TYPE_F32 = 0
TCGEN05_TYPE_F16 = 1
TCGEN05_TYPE_BF16 = 2
TCGEN05_TYPE_TF32 = 3
TCGEN05_TYPE_E4M3 = 4
TCGEN05_TYPE_E5M2 = 5
TCGEN05_TYPE_E2M3 = 6
TCGEN05_TYPE_E3M2 = 7
TCGEN05_TYPE_E2M1 = 8
TCGEN05_TYPE_S8 = 9
TCGEN05_TYPE_U8 = 10
TCGEN05_TYPE_S32 = 11

TCGEN05_SCALE_NONE = 0
TCGEN05_SCALE_UE8M0 = 1
TCGEN05_SCALE_UE4M3 = 2

TCGEN05_SCALE_VEC_NONE = 0
TCGEN05_SCALE_VEC_1X = 1
TCGEN05_SCALE_VEC_2X = 2
TCGEN05_SCALE_VEC_4X = 3
TCGEN05_SCALE_VEC_BLOCK16 = 4
TCGEN05_SCALE_VEC_BLOCK32 = 5

TCGEN05_STATUS_OK = 0x00
TCGEN05_STATUS_UNSUPPORTED = 0x01
TCGEN05_STATUS_INVALID_SPARSE_META = 0x02
TCGEN05_STATUS_INT_OVERFLOW = 0x04


KIND_CODE = {
    "f16": TCGEN05_KIND_F16,
    "tf32": TCGEN05_KIND_TF32,
    "f8f6f4": TCGEN05_KIND_F8F6F4,
    "i8": TCGEN05_KIND_I8,
    "mxf8f6f4": TCGEN05_KIND_MXF8F6F4,
    "mxf4": TCGEN05_KIND_MXF4,
    "mxf4nvf4": TCGEN05_KIND_MXF4NVF4,
}

TYPE_CODE = {
    "f32": TCGEN05_TYPE_F32,
    "f16": TCGEN05_TYPE_F16,
    "bf16": TCGEN05_TYPE_BF16,
    "tf32": TCGEN05_TYPE_TF32,
    "e4m3": TCGEN05_TYPE_E4M3,
    "e5m2": TCGEN05_TYPE_E5M2,
    "e2m3": TCGEN05_TYPE_E2M3,
    "e3m2": TCGEN05_TYPE_E3M2,
    "e2m1": TCGEN05_TYPE_E2M1,
    "s8": TCGEN05_TYPE_S8,
    "u8": TCGEN05_TYPE_U8,
    "s32": TCGEN05_TYPE_S32,
}

SCALE_CODE = {
    "none": TCGEN05_SCALE_NONE,
    "ue8m0": TCGEN05_SCALE_UE8M0,
    "ue4m3": TCGEN05_SCALE_UE4M3,
}

SCALE_VEC_CODE = {
    "none": TCGEN05_SCALE_VEC_NONE,
    "scale_vec::1X": TCGEN05_SCALE_VEC_1X,
    "scale_vec::2X": TCGEN05_SCALE_VEC_2X,
    "scale_vec::4X": TCGEN05_SCALE_VEC_4X,
    "block16": TCGEN05_SCALE_VEC_BLOCK16,
    "block32": TCGEN05_SCALE_VEC_BLOCK32,
}

OP_CODE = {
    "mma": TCGEN05_OP_MMA,
    "sp": TCGEN05_OP_SP,
    "ws": TCGEN05_OP_WS,
    "ws.sp": TCGEN05_OP_WS_SP,
    "block_scale": TCGEN05_OP_MMA,
    "sp.block_scale": TCGEN05_OP_SP,
}


def load_inventory() -> list[dict]:
    path = REPO_ROOT / "doc" / "Blackwell_TCGen05_MMA.json"
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)["entries"]


def float32_to_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def bits_to_float32(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def pack_u8_scale(values: list[int]) -> int:
    word = 0
    for index, value in enumerate(values):
        word |= (value & 0xFF) << (8 * index)
    return word


def int32_signed(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def int8_value(raw: int, is_unsigned: bool) -> int:
    raw &= 0xFF
    return raw if is_unsigned else raw - 0x100 if raw & 0x80 else raw


def int8_dot_ref(
    a_vec: list[int],
    b_vec: list[int],
    c_bits: int,
    a_unsigned: bool,
    b_unsigned: bool,
) -> tuple[int, int]:
    acc = int32_signed(c_bits)
    for a_raw, b_raw in zip(a_vec, b_vec):
        acc += int8_value(a_raw, a_unsigned) * int8_value(b_raw, b_unsigned)
    overflow = int(acc > 0x7FFFFFFF or acc < -0x80000000)
    return acc & 0xFFFFFFFF, overflow


def unpack_packed(word: int, width: int, lanes: int) -> list[int]:
    mask = (1 << width) - 1
    return [(word >> (width * index)) & mask for index in range(lanes)]


def pack_packed(values: list[int], width: int) -> int:
    mask = (1 << width) - 1
    word = 0
    for index, value in enumerate(values):
        word |= (value & mask) << (width * index)
    return word


def make_2to4_meta(groups: int, pattern: int = 0b0011) -> int:
    meta = 0
    for group in range(groups):
        meta |= (pattern & 0xF) << (group * 4)
    return meta


def make_4to8_meta(groups: int = 16, pattern: int = 0x0F) -> int:
    meta = 0
    for group in range(groups):
        meta |= (pattern & 0xFF) << (group * 8)
    return meta


def sparse_full_from_compact(
    compact_values: list[int],
    meta: int,
    group_width: int,
    select_count: int,
    filler_values: list[int],
) -> list[int]:
    full: list[int] = []
    compact_index = 0
    groups = len(compact_values) // select_count
    for group in range(groups):
        mask = (meta >> (group * group_width)) & ((1 << group_width) - 1)
        selected_in_group = 0
        for lane in range(group_width):
            if mask & (1 << lane):
                full.append(compact_values[compact_index])
                compact_index += 1
                selected_in_group += 1
            else:
                fill_index = (group * group_width + lane) % len(filler_values)
                full.append(filler_values[fill_index])
        assert selected_in_group == select_count
    return full


def popcount(value: int) -> int:
    return int(value).bit_count()


def meta_2to4_valid(meta: int, groups: int) -> bool:
    return all(popcount((meta >> (group * 4)) & 0xF) == 2 for group in range(groups))


def meta_4to8_valid(meta: int) -> bool:
    return all(popcount((meta >> (group * 8)) & 0xFF) == 4 for group in range(16))


def select_by_meta(values: list[int], meta: int, group_width: int, select_count: int) -> list[int]:
    selected: list[int] = []
    groups = len(values) // group_width
    for group in range(groups):
        mask = (meta >> (group * group_width)) & ((1 << group_width) - 1)
        count = 0
        for lane in range(group_width):
            if mask & (1 << lane):
                if count < select_count:
                    selected.append(values[group * group_width + lane])
                count += 1
    return selected


def scale_fp32_pow2_rz(value_bits: int, shift: int) -> int:
    value_bits &= 0xFFFFFFFF
    sign = value_bits & 0x80000000
    exp_raw = (value_bits >> 23) & 0xFF
    frac_raw = value_bits & 0x7FFFFF
    if shift == 0 or exp_raw == 0xFF or (value_bits & 0x7FFFFFFF) == 0:
        return value_bits
    if exp_raw == 0:
        return sign | (frac_raw >> shift)
    new_exp = exp_raw - shift
    if new_exp > 0:
        return sign | (new_exp << 23) | frac_raw
    sig24 = (1 << 23) | frac_raw
    sub_shift = shift + 1 - exp_raw
    sub_sig = 0 if sub_shift >= 24 else sig24 >> sub_shift
    return sign | (sub_sig & 0x7FFFFF)


def fp32_bits_to_fp16_bits(value_bits: int) -> int:
    value = bits_to_float32(value_bits)
    return struct.unpack("<H", struct.pack("<e", value))[0]


def adapter_supported(entry: dict) -> bool:
    return bool(entry["adapter_supported"])


def sparse_meta_for_entry(entry: dict, pattern_index: int = 0) -> int:
    if entry["dense_or_sparse"] != "sparse":
        return 0
    if entry["kind"] in {"mxf4", "mxf4nvf4"}:
        patterns = [0x0F, 0xF0, 0x55, 0xAA]
        return make_4to8_meta(pattern=patterns[pattern_index % len(patterns)])
    patterns = [0b0011, 0b0101, 0b1010, 0b1100]
    if entry["kind"] == "tf32":
        groups = 4
    elif entry["kind"] == "f16":
        groups = 8
    else:
        groups = 16
    return make_2to4_meta(groups, patterns[pattern_index % len(patterns)])


def random_fp32_bits(rng: random.Random) -> int:
    pool = [-4.0, -2.0, -1.0, -0.25, 0.0, 0.25, 1.0, 2.0, 4.0]
    return float32_to_bits(rng.choice(pool))


def random_fp16_like(rng: random.Random, value_type: str) -> int:
    if value_type == "bf16":
        pool = [0x0000, 0x8000, 0x3F80, 0xBF80, 0x4000, 0xC000, 0x3E80, 0xBE80]
    else:
        pool = [0x0000, 0x8000, 0x3C00, 0xBC00, 0x4000, 0xC000, 0x3800, 0xB800]
    return rng.choice(pool)


def small_float_lanes(value_type: str) -> list[int]:
    if value_type == "e5m2":
        return [0x00, 0x3C, 0xBC, 0x40, 0xC0, 0x38, 0xB8]
    if value_type == "e4m3":
        return [0x00, 0x38, 0xB8, 0x40, 0xC0, 0x30, 0xB0]
    if value_type == "e3m2":
        return [0x00, 0x0C, 0x2C, 0x10, 0x30, 0x08, 0x28]
    if value_type == "e2m3":
        return [0x00, 0x08, 0x28, 0x10, 0x30, 0x04, 0x24]
    return [0x0, 0x2, 0xA, 0x4, 0xC, 0x1, 0x9]


def f4f6f8_type_code(value_type: str) -> int:
    if value_type == "e5m2":
        return F4F6F8_TYPE_E5M2
    if value_type == "e2m3":
        return F4F6F8_TYPE_E2M3
    if value_type == "e3m2":
        return F4F6F8_TYPE_E3M2
    if value_type == "e2m1":
        return F4F6F8_TYPE_E2M1
    return F4F6F8_TYPE_E4M3


def f4f6f8_lane_width(value_type: str) -> int:
    if value_type == "e2m1":
        return 4
    return 6 if value_type in {"e2m3", "e3m2"} else 8


def fp4_mode_for_entry(entry: dict) -> int:
    if entry["scale_type"] == "ue4m3":
        return FP4_MODE_NVFP4
    if entry["scale_type"] == "ue8m0" and entry["scale_vector"] in {"scale_vec::4X", "block16"}:
        return FP4_MODE_MXFP4_4X
    return FP4_MODE_MXFP4


def random_scale_fields(entry: dict, rng: random.Random) -> tuple[int, int]:
    if entry["scale_type"] == "none":
        return 0, 0
    if entry["scale_type"] == "ue4m3":
        pool = [0x38, 0x40, 0x30, 0x00, 0xB8]
    else:
        pool = [E8M0_BIAS - 1, E8M0_BIAS, E8M0_BIAS + 1, E8M0_BIAS + 2]
    return (
        pack_u8_scale([rng.choice(pool) for _ in range(4)]),
        pack_u8_scale([rng.choice(pool) for _ in range(4)]),
    )


def random_scalar_case_for_entry(
    entry: dict,
    rng: random.Random,
    case_index: int = 0,
) -> tuple[int, int, int, int, int, int]:
    kind = entry["kind"]
    a_type = entry["a_type"]
    sparse = entry["dense_or_sparse"] == "sparse"
    sparse_meta = sparse_meta_for_entry(entry, case_index)
    a_sf, b_sf = random_scale_fields(entry, rng)

    if kind == "tf32":
        a = [random_fp32_bits(rng) for _ in range(8)]
        b_compact = [random_fp32_bits(rng) for _ in range(8)]
        if sparse:
            b_full = sparse_full_from_compact(
                b_compact,
                sparse_meta,
                4,
                2,
                [float32_to_bits(3.0), float32_to_bits(-3.0)],
            )
            b_bits = pack_packed(b_full, 32)
        else:
            b_bits = pack_u32_lanes(b_compact)
        return pack_u32_lanes(a), b_bits, random_fp32_bits(rng), sparse_meta, a_sf, b_sf

    if kind == "f16":
        a = [random_fp16_like(rng, a_type) for _ in range(16)]
        b_compact = [random_fp16_like(rng, entry["b_type"]) for _ in range(16)]
        if sparse:
            b_full = sparse_full_from_compact(
                b_compact,
                sparse_meta,
                4,
                2,
                [random_fp16_like(rng, entry["b_type"]) for _ in range(4)],
            )
            b_bits = pack_packed(b_full, 16)
        else:
            b_bits = pack_u16_lanes(b_compact)
        return pack_u16_lanes(a), b_bits, random_fp32_bits(rng), sparse_meta, a_sf, b_sf

    if kind in {"f8f6f4", "mxf8f6f4"}:
        a_width = f4f6f8_lane_width(a_type)
        b_width = f4f6f8_lane_width(entry["b_type"])
        a_pool = small_float_lanes(a_type)
        b_pool = small_float_lanes(entry["b_type"])
        a = [rng.choice(a_pool) for _ in range(32)]
        b_compact = [rng.choice(b_pool) for _ in range(32)]
        if sparse:
            b_full = sparse_full_from_compact(b_compact, sparse_meta, 4, 2, b_pool)
            b_bits = pack_packed(b_full, b_width)
        else:
            b_bits = pack_packed(b_compact, b_width)
        return pack_packed(a, a_width), b_bits, random_fp32_bits(rng), sparse_meta, a_sf, b_sf

    if kind == "i8":
        a = [rng.randrange(256) for _ in range(32)]
        b_compact = [rng.randrange(256) for _ in range(32)]
        if sparse:
            b_full = sparse_full_from_compact(b_compact, sparse_meta, 4, 2, [0x7F, 0x80, 0x55, 0xAA])
            b_bits = pack_u8_lanes(b_full)
        else:
            b_bits = pack_u8_lanes(b_compact)
        return pack_u8_lanes(a), b_bits, rng.randrange(0x10000), sparse_meta, a_sf, b_sf

    a_pool = small_float_lanes("e2m1")
    a = [rng.choice(a_pool) for _ in range(64)]
    b_compact = [rng.choice(a_pool) for _ in range(64)]
    if sparse:
        b_full = sparse_full_from_compact(b_compact, sparse_meta, 8, 4, a_pool)
        b_bits = pack_fp4_lanes(b_full)
    else:
        b_bits = pack_fp4_lanes(b_compact)
    return pack_fp4_lanes(a), b_bits, random_fp32_bits(rng), sparse_meta, a_sf, b_sf


class Tcgen05AdapterGolden:
    def __init__(self) -> None:
        self.tf32 = TF32DotMmaSimGolden()
        self.fp16 = FP16DotMmaSimGolden()
        self.f4f6f8 = F4F6F8DotMmaSimGolden()
        self.fp4 = NVFP4DotMmaSimGolden()

    def metadata_valid(self, kind: str, a_type: str, sparse: bool, sparse_meta: int) -> bool:
        if not sparse:
            return True
        if kind in {"mxf4", "mxf4nvf4"}:
            return meta_4to8_valid(sparse_meta)
        if kind == "tf32":
            return meta_2to4_valid(sparse_meta, 4)
        if kind == "f16":
            return meta_2to4_valid(sparse_meta, 8)
        return meta_2to4_valid(sparse_meta, 16)

    def select_sparse_b(self, kind: str, b_type: str, b_bits: int, sparse_meta: int) -> int:
        if kind in {"mxf4", "mxf4nvf4"}:
            values = unpack_packed(b_bits, 4, 128)
            return pack_packed(select_by_meta(values, sparse_meta, 8, 4), 4)
        if kind == "tf32":
            values = unpack_packed(b_bits, 32, 16)
            return pack_packed(select_by_meta(values, sparse_meta, 4, 2), 32)
        if kind == "f16":
            values = unpack_packed(b_bits, 16, 32)
            return pack_packed(select_by_meta(values, sparse_meta, 4, 2), 16)
        if b_type == "e2m1":
            values = unpack_packed(b_bits, 4, 64)
            return pack_packed(select_by_meta(values, sparse_meta, 4, 2), 4)
        if b_type in {"e2m3", "e3m2"}:
            values = unpack_packed(b_bits, 6, 64)
            return pack_packed(select_by_meta(values, sparse_meta, 4, 2), 6)
        values = unpack_packed(b_bits, 8, 64)
        return pack_packed(select_by_meta(values, sparse_meta, 4, 2), 8)

    def __call__(
        self,
        entry: dict,
        a_bits: int,
        b_bits: int,
        c_bits: int,
        sparse_meta: int = 0,
        a_sf_bits: int = 0,
        b_sf_bits: int = 0,
        enable_input_d: int = 1,
        scale_input_d: int = 0,
    ) -> tuple[int, int]:
        kind = entry["kind"]
        a_type = entry["a_type"]
        b_type = entry["b_type"]
        d_type = entry["d_type"]
        sparse = entry["dense_or_sparse"] == "sparse"

        if not self.metadata_valid(kind, a_type, sparse, sparse_meta):
            return 0, TCGEN05_STATUS_INVALID_SPARSE_META
        if not adapter_supported(entry):
            return 0, TCGEN05_STATUS_UNSUPPORTED

        c_core = c_bits if enable_input_d else 0
        if enable_input_d and kind in {"f16", "tf32"}:
            c_core = scale_fp32_pow2_rz(c_core, scale_input_d)

        b_core = self.select_sparse_b(kind, b_type, b_bits, sparse_meta) if sparse else b_bits

        status = TCGEN05_STATUS_OK
        if kind == "tf32":
            result = self.tf32(a_bits, b_core, c_core)
        elif kind == "f16":
            fmt = BF16 if a_type == "bf16" else FP16
            b_fmt = BF16 if b_type == "bf16" else FP16
            result = self.fp16(a_bits, b_core, c_core, fmt, b_fmt)
        elif kind == "f8f6f4":
            result = self.f4f6f8(
                a_bits,
                b_core,
                c_core,
                FP8_E4M3,
                a_type=f4f6f8_type_code(a_type),
                b_type=f4f6f8_type_code(b_type),
            )
        elif kind == "mxf8f6f4":
            a_scale = a_sf_bits & 0xFF
            b_scale = b_sf_bits & 0xFF
            result = self.f4f6f8(
                a_bits,
                b_core,
                c_core,
                FP8_E4M3,
                mxfp8_en=1,
                a_mx_scale=a_scale,
                b_mx_scale=b_scale,
                a_type=f4f6f8_type_code(a_type),
                b_type=f4f6f8_type_code(b_type),
            )
        elif kind == "i8":
            a_vec = unpack_packed(a_bits, 8, 32)
            b_vec = unpack_packed(b_core, 8, 32)
            result, overflow = int8_dot_ref(
                a_vec,
                b_vec,
                c_core,
                a_unsigned=a_type == "u8",
                b_unsigned=b_type == "u8",
            )
            status = TCGEN05_STATUS_INT_OVERFLOW if overflow else TCGEN05_STATUS_OK
        else:
            result = self.fp4(
                a_bits,
                b_core,
                a_sf_bits,
                b_sf_bits,
                c_core,
                fp4_mode=fp4_mode_for_entry(entry),
            )

        if d_type == "f16":
            result = fp32_bits_to_fp16_bits(result)
        return result & 0xFFFFFFFF, status


def scalar_case_for_entry(entry: dict, index: int = 0) -> tuple[int, int, int, int, int, int]:
    kind = entry["kind"]
    a_type = entry["a_type"]
    sparse = entry["dense_or_sparse"] == "sparse"
    sparse_meta = 0
    a_sf = 0
    b_sf = 0
    c_bits = float32_to_bits(1.0 if kind != "i8" else 0.0)

    if kind == "tf32":
        a = [float32_to_bits(1.0)] + [0] * 7
        b_compact = [float32_to_bits(2.0)] + [0] * 7
        if sparse:
            sparse_meta = make_2to4_meta(4)
            b_full = []
            for group in range(4):
                b_full += [b_compact[group * 2], b_compact[group * 2 + 1], float32_to_bits(-3.0), float32_to_bits(4.0)]
            b_bits = pack_packed(b_full, 32)
        else:
            b_bits = pack_u32_lanes(b_compact)
        return pack_u32_lanes(a), b_bits, c_bits, sparse_meta, a_sf, b_sf

    if kind == "f16":
        one = 0x3F80 if a_type == "bf16" else 0x3C00
        two = 0x4000
        a = [one] + [0] * 15
        b_compact = [two] + [0] * 15
        if sparse:
            sparse_meta = make_2to4_meta(8)
            b_full = []
            for group in range(8):
                b_full += [b_compact[group * 2], b_compact[group * 2 + 1], one, one]
            b_bits = pack_packed(b_full, 16)
        else:
            b_bits = pack_u16_lanes(b_compact)
        return pack_u16_lanes(a), b_bits, c_bits, sparse_meta, a_sf, b_sf

    if kind in {"f8f6f4", "mxf8f6f4"}:
        if a_type == "e5m2":
            one, width = 0x3C, 8
        elif a_type == "e4m3":
            one, width = 0x38, 8
        elif a_type == "e3m2":
            one, width = 0x0C, 6
        elif a_type == "e2m3":
            one, width = 0x08, 6
        else:
            one, width = 0x02, 4
        if entry["b_type"] == "e5m2":
            two, b_width = 0x40, 8
        elif entry["b_type"] == "e4m3":
            two, b_width = 0x40, 8
        elif entry["b_type"] == "e3m2":
            two, b_width = 0x10, 6
        elif entry["b_type"] == "e2m3":
            two, b_width = 0x10, 6
        else:
            two, b_width = 0x04, 4
        a = [one] + [0] * 31
        b_compact = [two] + [0] * 31
        if sparse:
            sparse_meta = make_2to4_meta(16)
            b_full = []
            for group in range(16):
                b_full += [b_compact[group * 2], b_compact[group * 2 + 1], one, one]
            b_bits = pack_packed(b_full, b_width)
        else:
            b_bits = pack_packed(b_compact, b_width)
        a_sf = pack_u8_scale([E8M0_BIAS] * 4)
        b_sf = pack_u8_scale([E8M0_BIAS] * 4)
        return pack_packed(a, width), b_bits, c_bits, sparse_meta, a_sf, b_sf

    if kind == "i8":
        a = [1] + [0] * 31
        b_compact = [2] + [0] * 31
        if sparse:
            sparse_meta = make_2to4_meta(16)
            b_full = []
            for group in range(16):
                b_full += [b_compact[group * 2], b_compact[group * 2 + 1], 7, 9]
            b_bits = pack_u8_lanes(b_full)
        else:
            b_bits = pack_u8_lanes(b_compact)
        return pack_u8_lanes(a), b_bits, 0, sparse_meta, a_sf, b_sf

    one = 0x2
    two = 0x4
    a = [one] + [0] * 63
    b_compact = [two] + [0] * 63
    if sparse:
        sparse_meta = make_4to8_meta()
        b_full = []
        for group in range(16):
            b_full += b_compact[group * 4: group * 4 + 4] + [one, one, one, one]
        b_bits = pack_fp4_lanes(b_full)
    else:
        b_bits = pack_fp4_lanes(b_compact)
    if entry["scale_type"] == "ue4m3":
        a_sf = pack_u8_scale([0x38] * 4)
        b_sf = pack_u8_scale([0x38] * 4)
    else:
        a_sf = pack_u8_scale([E8M0_BIAS] * 4)
        b_sf = pack_u8_scale([E8M0_BIAS] * 4)
    return pack_fp4_lanes(a), b_bits, c_bits, sparse_meta, a_sf, b_sf
