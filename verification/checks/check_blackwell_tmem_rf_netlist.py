#!/usr/bin/env python3
"""Verify the RF executor retains the complete TMEM SRAM hierarchy."""
import json
import sys
from pathlib import Path

modules = json.loads(Path(sys.argv[1]).read_text())["modules"]
top = "blackwell_tmem_rf_subsystem"
assert top in modules
seen = []


def walk(name):
    for cell in modules[name].get("cells", {}).values():
        kind = cell["type"]
        if kind in modules:
            walk(kind)
        elif kind == "$mem_v2":
            params = cell["parameters"]
            seen.append({k: int(params[k], 2) for k in
                         ("WIDTH", "SIZE", "RD_PORTS", "WR_PORTS")}
                        | {"uninitialized": set(params["INIT"]) == {"x"}})


walk(top)
physical = [m for m in seen if m["WIDTH"] == 128 and m["SIZE"] == 128]
assert len(physical) == 128, f"TMEM lane banks: {len(physical)}"
assert all(m["RD_PORTS"] == m["WR_PORTS"] == 1 and m["uninitialized"]
           for m in physical)
staging = [m for m in seen if m["WIDTH"] == 32 and m["SIZE"] == 128]
assert len(staging) == 32, f"RF staging banks: {len(staging)}"
assert all(m["RD_PORTS"] == m["WR_PORTS"] == 1 and m["uninitialized"]
           for m in staging)
top_flop_bits = sum(len(cell["connections"]["Q"])
                    for cell in modules[top].get("cells", {}).values()
                    if cell["type"] in {"$dff", "$dffe", "$adff", "$adffe",
                                        "$sdff", "$sdffe"})
assert top_flop_bits < 8192, f"RF staging expanded to flops: {top_flop_bits}"
print(json.dumps({"top": top, "physical_bank_count": len(physical),
                  "physical_capacity_bytes": 262144,
                  "staging_bank_count": len(staging),
                  "staging_capacity_bytes": 16384,
                  "top_flop_bits": top_flop_bits,
                  "all_memories_uninitialized": all(m["uninitialized"] for m in seen)},
                 indent=2))
