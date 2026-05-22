#!/usr/bin/env python3
from __future__ import annotations

import json
from dataclasses import dataclass, asdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DOC_MD = REPO_ROOT / "doc" / "Blackwell_TCGen05_MMA.md"
DOC_JSON = REPO_ROOT / "doc" / "Blackwell_TCGen05_MMA.json"


@dataclass(frozen=True)
class ShapeRule:
    cta_group: int
    m_values: tuple[int, ...]
    n_rule: str
    k_dense: int
    k_sparse: int | None
    notes: str = ""


@dataclass(frozen=True)
class InventoryEntry:
    mnemonic: str
    opcode_family: str
    kind: str
    dense_or_sparse: str
    ws: bool
    cta_group: int
    d_type: str
    a_type: str
    b_type: str
    scale_type: str
    scale_vector: str
    shape_m: tuple[int, ...]
    shape_n: str
    k: int
    canonical_ptx: str
    adapter_supported: bool
    mapping: str
    notes: str


SOURCES = [
    "NVIDIA PTX ISA 9.2, section 9.7.16 TensorCore 5th Generation Family Instructions",
    "NVIDIA PTX ISA 9.2, Table 39 Various combinations of .kind and shapes",
    "NVIDIA PTX ISA 9.2, section 9.7.16.10.7 Block Scaling for tcgen05.mma",
]


TYPE_ORDER = ["f16", "bf16", "tf32", "e4m3", "e5m2", "e2m3", "e3m2", "e2m1", "s8", "u8"]
F8F6F4_TYPES = ("e4m3", "e5m2", "e2m3", "e3m2", "e2m1")
ADAPTER_F8F6F4_TYPES = ("e4m3", "e5m2", "e2m3", "e3m2", "e2m1")


def ordered_pair_types(types: tuple[str, ...]) -> list[tuple[str, str]]:
    return [(a_type, b_type) for a_type in types for b_type in types]


def dense_shape_rules(kind: str, ws: bool) -> list[ShapeRule]:
    if ws:
        if kind in {"f16", "tf32", "f8f6f4", "i8"}:
            k_dense = {"tf32": 8, "f16": 16, "f8f6f4": 32, "i8": 32}[kind]
            return [
                ShapeRule(1, (32, 64, 128), "N in {64,128,256}", k_dense, k_dense * 2)
            ]
        return []
    if kind == "i8":
        return [
            ShapeRule(1, (64, 128), "N in {8,16,24,32,48,...,256}", 32, 64),
            ShapeRule(2, (128, 256), "N in {32,64,...,256}", 32, 64),
        ]
    k_dense = {"tf32": 8, "f16": 16, "f8f6f4": 32}[kind]
    return [
        ShapeRule(1, (64, 128), "N in {8,16,...,256}", k_dense, k_dense * 2),
        ShapeRule(2, (128, 256), "N in {16,32,...,256}", k_dense, k_dense * 2),
    ]


def block_shape_rules(kind: str, sparse: bool) -> list[ShapeRule]:
    if kind == "mxf8f6f4":
        return [
            ShapeRule(1, (128,), "N in {8,16,...,256}", 32, 64),
            ShapeRule(2, (128, 256), "N in {16,32,...,256}", 32, 64),
        ]
    if kind in {"mxf4", "mxf4nvf4"}:
        base_notes = "K=96 is an sm_103a dense-only extension for cta_group::2."
        if sparse:
            return [
                ShapeRule(1, (128,), "N in {8,16,...,256}", 64, 128),
                ShapeRule(2, (256,), "N in {16,32,...,256}", 64, 128),
            ]
        return [
            ShapeRule(1, (128,), "N in {8,16,...,256}", 64, 128),
            ShapeRule(2, (128, 256), "N in {16,32,...,256}", 64, 128, base_notes),
        ]
    return []


def dtype_combos(kind: str) -> list[tuple[str, str, str]]:
    if kind == "tf32":
        return [("f32", "tf32", "tf32")]
    if kind == "f16":
        combos = [("f16", "f16", "f16")]
        combos += [("f32", a_type, b_type) for a_type, b_type in ordered_pair_types(("f16", "bf16"))]
        return combos
    if kind == "f8f6f4":
        return [(d_type, a_type, b_type) for d_type in ("f32", "f16")
                for a_type, b_type in ordered_pair_types(F8F6F4_TYPES)]
    if kind == "i8":
        return [("s32", a_type, b_type) for a_type, b_type in ordered_pair_types(("s8", "u8"))]
    if kind == "mxf8f6f4":
        return [("f32", a_type, b_type) for a_type, b_type in ordered_pair_types(F8F6F4_TYPES)]
    if kind in {"mxf4", "mxf4nvf4"}:
        return [("f32", "e2m1", "e2m1")]
    raise ValueError(kind)


def scale_combos(kind: str) -> list[tuple[str, str]]:
    if kind == "mxf8f6f4":
        return [("ue8m0", "scale_vec::1X")]
    if kind == "mxf4":
        return [("ue8m0", "scale_vec::2X")]
    if kind == "mxf4nvf4":
        return [
            ("ue8m0", "scale_vec::2X"),
            ("ue8m0", "scale_vec::4X"),
            ("ue4m3", "scale_vec::4X"),
        ]
    return [("none", "none")]


def scale_aliases(kind: str, scale_type: str, scale_vector: str) -> list[str]:
    aliases = [scale_vector]
    if kind == "mxf8f6f4" and scale_vector == "scale_vec::1X":
        aliases.append("block32")
    if kind in {"mxf4", "mxf4nvf4"} and scale_vector == "scale_vec::2X":
        aliases.append("block32")
    if kind == "mxf4nvf4" and scale_vector == "scale_vec::4X":
        aliases.append("block16")
    return aliases


def opcode_mnemonic(kind: str, sparse: bool, ws: bool, scale_vector: str) -> str:
    name = "tcgen05.mma"
    if ws:
        name += ".ws"
    if sparse:
        name += ".sp"
    name += ".cta_group.kind"
    if scale_vector != "none":
        name += ".block_scale"
    return name


def canonical_ptx(kind: str, sparse: bool, ws: bool, scale_vector: str, cta_group: int) -> str:
    name = "tcgen05.mma"
    if ws:
        name += ".ws"
    if sparse:
        name += ".sp"
    name += f".cta_group::{cta_group}.kind::{kind}"
    if scale_vector != "none":
        name += f".block_scale.{scale_vector}"
    args = "[d_tmem], a_desc, b_desc"
    if sparse:
        args += ", [sp_meta_tmem]"
    args += ", idesc"
    if scale_vector != "none":
        args += ", [scale_a_tmem], [scale_b_tmem], enable_input_d"
    else:
        args += ", disable_output_lane, enable_input_d"
    return f"{name} {args};"


def adapter_supported(kind: str, d_type: str, a_type: str, b_type: str, scale_type: str, scale_vector: str) -> bool:
    if kind == "tf32":
        return d_type == "f32" and a_type == b_type == "tf32"
    if kind == "f16":
        if d_type == "f16":
            return a_type == b_type == "f16"
        return (
            d_type == "f32"
            and a_type in {"f16", "bf16"}
            and b_type in {"f16", "bf16"}
        )
    if kind == "f8f6f4":
        return (
            d_type in {"f32", "f16"}
            and a_type in ADAPTER_F8F6F4_TYPES
            and b_type in ADAPTER_F8F6F4_TYPES
        )
    if kind == "i8":
        return d_type == "s32" and a_type in {"s8", "u8"} and b_type in {"s8", "u8"}
    if kind == "mxf8f6f4":
        return (
            d_type == "f32"
            and scale_type == "ue8m0"
            and a_type in ADAPTER_F8F6F4_TYPES
            and b_type in ADAPTER_F8F6F4_TYPES
        )
    if kind == "mxf4":
        return (
            d_type == "f32"
            and a_type == b_type == "e2m1"
            and scale_type == "ue8m0"
            and scale_vector in {"scale_vec::2X", "block32"}
        )
    if kind == "mxf4nvf4":
        return (
            d_type == "f32"
            and a_type == b_type == "e2m1"
            and (
                (scale_type == "ue8m0" and scale_vector in {"scale_vec::2X", "scale_vec::4X", "block16", "block32"})
                or (scale_type == "ue4m3" and scale_vector in {"scale_vec::4X", "block16"})
            )
        )
    return False


def mapping_text(sparse: bool, ws: bool, cta_group: int, kind: str) -> str:
    parts = []
    if cta_group == 1:
        parts.append("single CTA owns the TMEM row-lane range")
    else:
        parts.append("two CTA ranks split the M rows and share the B/scale descriptor view")
    parts.append("N is issued as 8-column dot groups")
    if sparse:
        parts.append("A is K/2 compressed and metadata selects the matching B lanes")
    else:
        parts.append("A and B use dense K lanes")
    if ws:
        parts.append("collector/ashift changes operand source only")
    if kind in {"mxf8f6f4", "mxf4", "mxf4nvf4"}:
        parts.append("scale matrices are chunked by scale-vector size")
    return "; ".join(parts)


def build_inventory() -> list[InventoryEntry]:
    entries: list[InventoryEntry] = []

    for ws in (False, True):
        for sparse in (False, True):
            opcode = "ws.sp" if ws and sparse else "ws" if ws else "sp" if sparse else "mma"
            for kind in ("f16", "tf32", "f8f6f4", "i8"):
                for rule in dense_shape_rules(kind, ws):
                    k = rule.k_sparse if sparse else rule.k_dense
                    assert k is not None
                    for d_type, a_type, b_type in dtype_combos(kind):
                        entries.append(
                            InventoryEntry(
                                mnemonic=opcode_mnemonic(kind, sparse, ws, "none"),
                                opcode_family=opcode,
                                kind=kind,
                                dense_or_sparse="sparse" if sparse else "dense",
                                ws=ws,
                                cta_group=rule.cta_group,
                                d_type=d_type,
                                a_type=a_type,
                                b_type=b_type,
                                scale_type="none",
                                scale_vector="none",
                                shape_m=rule.m_values,
                                shape_n=rule.n_rule,
                                k=k,
                                canonical_ptx=canonical_ptx(kind, sparse, ws, "none", rule.cta_group),
                                adapter_supported=adapter_supported(kind, d_type, a_type, b_type, "none", "none"),
                                mapping=mapping_text(sparse, ws, rule.cta_group, kind),
                                notes=rule.notes,
                            )
                        )

    for sparse in (False, True):
        opcode = "sp.block_scale" if sparse else "block_scale"
        for kind in ("mxf8f6f4", "mxf4", "mxf4nvf4"):
            for rule in block_shape_rules(kind, sparse):
                k = rule.k_sparse if sparse else rule.k_dense
                assert k is not None
                for d_type, a_type, b_type in dtype_combos(kind):
                    for scale_type, scale_vector in scale_combos(kind):
                        for scale_alias in scale_aliases(kind, scale_type, scale_vector):
                            entries.append(
                                InventoryEntry(
                                    mnemonic=opcode_mnemonic(kind, sparse, False, scale_alias),
                                    opcode_family=opcode,
                                    kind=kind,
                                    dense_or_sparse="sparse" if sparse else "dense",
                                    ws=False,
                                    cta_group=rule.cta_group,
                                    d_type=d_type,
                                    a_type=a_type,
                                    b_type=b_type,
                                    scale_type=scale_type,
                                    scale_vector=scale_alias,
                                    shape_m=rule.m_values,
                                    shape_n=rule.n_rule,
                                    k=k,
                                    canonical_ptx=canonical_ptx(kind, sparse, False, scale_alias, rule.cta_group),
                                    adapter_supported=adapter_supported(kind, d_type, a_type, b_type, scale_type, scale_alias),
                                    mapping=mapping_text(sparse, False, rule.cta_group, kind),
                                    notes=rule.notes,
                                )
                            )

    entries.sort(
        key=lambda e: (
            e.opcode_family,
            e.kind,
            e.cta_group,
            e.dense_or_sparse,
            e.d_type,
            TYPE_ORDER.index(e.a_type) if e.a_type in TYPE_ORDER else 99,
            TYPE_ORDER.index(e.b_type) if e.b_type in TYPE_ORDER else 99,
            e.scale_type,
            e.scale_vector,
            e.k,
            e.shape_m,
        )
    )
    return entries


def render_markdown(entries: list[InventoryEntry]) -> str:
    supported = sum(1 for entry in entries if entry.adapter_supported)
    lines = [
        "# Blackwell TCGen05 MMA Inventory",
        "",
        "Generated by `tools/gen_tcgen05_mma_inventory.py`.",
        "",
        "## Sources",
        "",
    ]
    lines += [f"- {source}" for source in SOURCES]
    lines += [
        "",
        "## Summary",
        "",
        f"- Semantic instruction rows: {len(entries)}",
        f"- Rows covered by the scalar dot RTL adapter: {supported}",
        "- Full adapter validation report: `doc/Blackwell_TCGen05_MMA_validation.md`",
        "- SASS opcode bytes are intentionally omitted until `ptxas`/`nvdisasm` for Blackwell is available.",
        "- M/N are grouped as rules because the scalar dot adapter validates one `(row, column)` dot at a time.",
        "",
        "## Thread Mapping",
        "",
        "- `cta_group::1`: one CTA owns the target TMEM row lanes. M=32/64/128 uses the low row-lane range, and each N slice is verified as an 8-column dot group.",
        "- `cta_group::2`: two CTA ranks split the M rows. Each rank verifies its own rows while sharing the same B descriptor and scale descriptor view.",
        "- Dense K uses the dtype-defined K. Sparse K uses compressed A with K/2 lanes plus metadata-selected B lanes.",
        "- Block-scale instructions apply scale chunks according to `scale_vec`/`block16`/`block32`; the adapter maps supported chunks onto the current MXFP8/MXFP4/NVFP4 dot units.",
        "- `.ws` and collector/ashift variants change operand source and lifetime only, so arithmetic verification reuses the same dot lattice.",
        "",
        "## Inventory",
        "",
        "| Family | Kind | CTA | D | A | B | Scale | Shape | K | Adapter | Canonical PTX |",
        "| --- | --- | ---: | --- | --- | --- | --- | --- | ---: | --- | --- |",
    ]
    for entry in entries:
        scale = "none" if entry.scale_type == "none" else f"{entry.scale_type}/{entry.scale_vector}"
        shape = f"M={list(entry.shape_m)}, {entry.shape_n}"
        adapter = "yes" if entry.adapter_supported else "no"
        ptx = entry.canonical_ptx.replace("|", "\\|")
        lines.append(
            f"| {entry.opcode_family} | {entry.kind} | {entry.cta_group} | {entry.d_type} | "
            f"{entry.a_type} | {entry.b_type} | {scale} | {shape} | {entry.k} | {adapter} | `{ptx}` |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    entries = build_inventory()
    DOC_JSON.write_text(
        json.dumps(
            {
                "sources": SOURCES,
                "entries": [asdict(entry) for entry in entries],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    DOC_MD.write_text(render_markdown(entries), encoding="utf-8")
    print(f"wrote {DOC_JSON}")
    print(f"wrote {DOC_MD}")


if __name__ == "__main__":
    main()
