#!/usr/bin/env python3
"""Check that the TMEM manager synthesis retains 128 uninitialized 1R1W banks."""
import json
import sys
from pathlib import Path

netlist = json.loads(Path(sys.argv[1]).read_text())
modules = netlist["modules"]
assert "blackwell_tmem_bank" in modules
memories = []


def walk(module_name):
    for cell_name, cell in modules[module_name].get("cells", {}).items():
        kind = cell["type"]
        if kind in modules:
            walk(kind)
        elif kind == "$mem_v2":
            p = cell["parameters"]
            width = int(p["WIDTH"], 2)
            size = int(p["SIZE"], 2)
            rd = int(p["RD_PORTS"], 2)
            wr = int(p["WR_PORTS"], 2)
            assert int(p["RD_CLK_ENABLE"], 2) == int(p["WR_CLK_ENABLE"], 2) == 1
            assert set(p["INIT"]) == {"x"}, (module_name, cell_name, "initialized")
            memories.append((module_name, cell_name, width, size, rd, wr))


walk("blackwell_tmem_bank")
assert len(memories) == 128, f"expected 128 lane banks, got {len(memories)}"
assert all((w, s, r, q) == (128, 128, 1, 1) for _, _, w, s, r, q in memories)
print(json.dumps({"top": "blackwell_tmem_bank", "banks": len(memories),
                  "width_bits": 128, "words_per_bank": 128,
                  "bytes": len(memories) * 128 * 128 // 8,
                  "read_ports_per_bank": 1, "write_ports_per_bank": 1,
                  "storage_reset_or_init": False}, indent=2))
