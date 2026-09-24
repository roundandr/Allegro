#!/usr/bin/env python3
"""Prove the planned four-by-64 arithmetic streams exist in the RTL netlist."""
import json
import re
import sys
from pathlib import Path

design = json.loads(Path(sys.argv[1]).read_text())
modules = design["modules"]
top = modules["blackwell_f16_dot_array"]
instances = [(name, c) for name, c in top["cells"].items()
             if c["type"] == "f16tf32_dot_prod"]
assert len(instances) == 256, f"expected 256 physical dot cores, got {len(instances)}"
by_partition = {p: set() for p in range(4)}
for name, _ in instances:
    match = re.fullmatch(r"gen_partition\[(\d+)\]\.gen_dot\[(\d+)\]\.arithmetic", name)
    assert match, f"unexpected arithmetic placement: {name}"
    partition, stream = map(int, match.groups())
    assert partition in by_partition and 0 <= stream < 64
    by_partition[partition].add(stream)
assert all(len(streams) == 64 for streams in by_partition.values())
core = modules["f16tf32_dot_prod"]
assert core.get("cells") and not core.get("attributes", {}).get("blackbox"), \
    "dot core is missing or black-boxed"
print(json.dumps({"top": "blackwell_f16_dot_array", "dot_instances": len(instances),
                  "partitions": 4, "dots_per_partition": 64,
                  "arithmetic_module": "f16tf32_dot_prod",
                  "blackboxed": False}, indent=2))
