#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from collections import defaultdict, deque
from pathlib import Path


OUT_PINS = {"Y", "Q", "QN", "SN", "CON", "H", "L"}
CTRL_PINS = {"CLK", "RESETN", "RESET_B", "SETN", "SET_B"}


def norm(name: str) -> str:
    name = name.strip()
    if name.startswith("\\"):
        name = name[1:].rstrip()
    return name


def expand_decl(name: str, hi: str | None, lo: str | None) -> list[str]:
    name = norm(name.rstrip(";"))
    if hi is None:
        return [name]
    hi_i = int(hi)
    lo_i = int(lo)
    return [f"{name}[{idx}]" for idx in range(min(hi_i, lo_i), max(hi_i, lo_i) + 1)]


def parse_netlist(path: Path):
    lines = path.read_text().splitlines()
    instances = {}
    ports_in: set[str] = set()
    ports_out: set[str] = set()

    for line in lines:
        stripped = line.strip()
        match = re.match(r"input(?: \[(\d+):(\d+)\])? (\S+);", stripped)
        if match:
            ports_in.update(expand_decl(match.group(3), match.group(1), match.group(2)))
        match = re.match(r"output(?: \[(\d+):(\d+)\])? (\S+);", stripped)
        if match:
            ports_out.update(expand_decl(match.group(3), match.group(1), match.group(2)))

    inst_re = re.compile(r"\s*([A-Za-z0-9]+_ASAP7_[A-Za-z0-9_]+)\s+(.+?)\s*\((.*)$")

    idx = 0
    while idx < len(lines):
        match = inst_re.match(lines[idx])
        if not match:
            idx += 1
            continue

        cell = match.group(1)
        inst = norm(match.group(2))
        body = [match.group(3)]
        idx += 1
        while idx < len(lines) and ");" not in body[-1]:
            body.append(lines[idx])
            idx += 1

        pinmap = {}
        for pin_match in re.finditer(r"\.(\w+)\((.*?)\)", "\n".join(body), re.S):
            pinmap[pin_match.group(1)] = norm(pin_match.group(2))
        instances[inst] = {"cell": cell, "pins": pinmap}

    sinks = defaultdict(list)
    drivers = {}
    cell_outputs = defaultdict(list)

    for port in ports_in:
        drivers[port] = ("PORT", port, "input")

    for inst, rec in instances.items():
        cell = rec["cell"]
        for pin, net in rec["pins"].items():
            if not net or "'" in net:
                continue
            if pin in OUT_PINS:
                drivers.setdefault(net, (inst, pin, cell))
                cell_outputs[inst].append((pin, net))
            elif pin not in CTRL_PINS:
                sinks[net].append((inst, pin))

    for port in ports_out:
        sinks[port].append(("PORT", port))

    return instances, ports_out, sinks, drivers, cell_outputs


def reg_q_nets(instances, stage: int) -> list[str]:
    prefix = f"u_stage{stage}_reg.out_data["
    return [
        rec["pins"]["QN"]
        for inst, rec in instances.items()
        if inst.startswith(prefix) and "QN" in rec["pins"]
    ]


def stage_d_nets(instances, stage: int) -> list[str]:
    prefix = f"u_stage{stage}_reg.out_data["
    return [
        rec["pins"]["D"]
        for inst, rec in instances.items()
        if inst.startswith(prefix) and "D" in rec["pins"]
    ]


def input_data_sources() -> list[str]:
    specs = [
        ("a_vec_i", 256),
        ("b_vec_i", 256),
        ("c_i", 32),
        ("a_type_i", 3),
        ("b_type_i", 3),
        ("mxfp8_en_i", 1),
        ("a_mx_scale_i", 8),
        ("b_mx_scale_i", 8),
    ]
    sources = []
    for base, width in specs:
        if width == 1:
            sources.append(base)
        else:
            sources.extend(f"{base}[{idx}]" for idx in range(width))
    return sources


def is_dff(instances, inst: str) -> bool:
    return instances.get(inst, {}).get("cell", "").startswith("DFF")


def analyze_stage(stage, sources, targets, instances, sinks, drivers, cell_outputs):
    queue = deque(net for net in sources if net)
    seen_nets = set()
    seen_cells = set()
    reached_targets = set()

    while queue:
        net = queue.popleft()
        if net in seen_nets:
            continue
        seen_nets.add(net)

        if net in targets:
            reached_targets.add(net)
            if stage in ("OUT", "READY"):
                continue

        for inst, pin in sinks.get(net, []):
            if inst == "PORT":
                if net in targets:
                    reached_targets.add(net)
                continue
            if is_dff(instances, inst):
                if pin == "D":
                    reached_targets.add(net)
                continue
            if inst in seen_cells:
                continue
            seen_cells.add(inst)
            for _, out_net in cell_outputs.get(inst, []):
                if out_net not in seen_nets:
                    queue.append(out_net)

    top = []
    for net in seen_nets:
        top.append((len(sinks.get(net, [])), net, drivers.get(net, ("?", "?", "?")), sinks.get(net, [])[:8]))
    top.sort(reverse=True, key=lambda item: item[0])
    return len(seen_nets), len(seen_cells), len(reached_targets), top


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("netlist", type=Path)
    parser.add_argument("--top", type=int, default=5)
    args = parser.parse_args()

    instances, ports_out, sinks, drivers, cell_outputs = parse_netlist(args.netlist)

    stage_sources = {
        "S0": input_data_sources(),
        "S1": reg_q_nets(instances, 0),
        "S2": reg_q_nets(instances, 1),
        "S3": reg_q_nets(instances, 2),
        "S4": reg_q_nets(instances, 3),
        "S5": reg_q_nets(instances, 4),
        "OUT": reg_q_nets(instances, 5),
        "READY": ["out_rdy_i"],
    }
    stage_targets = {
        "S0": set(stage_d_nets(instances, 0)),
        "S1": set(stage_d_nets(instances, 1)),
        "S2": set(stage_d_nets(instances, 2)),
        "S3": set(stage_d_nets(instances, 3)),
        "S4": set(stage_d_nets(instances, 4)),
        "S5": set(stage_d_nets(instances, 5)),
        "OUT": {port for port in ports_out if port.startswith("d_o[")},
        "READY": {"in_rdy_o"},
    }

    print("stage,sources,nets,cells,targets_seen,targets_total,max_fanout,max_net,driver")
    for stage in ["S0", "S1", "S2", "S3", "S4", "S5", "OUT", "READY"]:
        nets, cells, targets_seen, top = analyze_stage(
            stage,
            stage_sources[stage],
            stage_targets[stage],
            instances,
            sinks,
            drivers,
            cell_outputs,
        )
        max_fo, max_net, driver, _ = top[0] if top else (0, "", ("", "", ""), [])
        driver_name = f"{driver[0]}/{driver[1]}"
        print(
            f"{stage},{len(stage_sources[stage])},{nets},{cells},"
            f"{targets_seen},{len(stage_targets[stage])},{max_fo},{max_net},{driver_name}"
        )
        for fanout, net, driver, sink_list in top[: args.top]:
            sink_text = " ".join(f"{sink_inst}/{sink_pin}" for sink_inst, sink_pin in sink_list[:4])
            print(f"  top,{stage},{fanout},{net},{driver[0]}/{driver[1]},{sink_text}")


if __name__ == "__main__":
    main()
