#!/usr/bin/env python3
"""Independent optimistic cycle bound, not a model of NVIDIA private timing.

Input traffic counts must include scales, metadata, padding, repeated reads and
all competitors at each *shared* port. Output is a lower bound on cycles, not
a prediction that the RTL meets it. Usage: python3 ... workload.json
"""
import argparse
import json
from pathlib import Path


PEAK = {'tf32': 4096, 'f16': 8192, 'bf16': 8192, 'i8': 16384,
        'f8f6f4': 16384, 'mxf8f6f4': 16384, 'mxf4': 32768, 'mxf4nvf4': 32768}
PORTS = {'gmem_bytes': 128, 'smem_read_bytes': 128, 'smem_write_bytes': 128,
         'tmem_read_bytes': 2048, 'tmem_write_bytes': 2048, 'barrier_updates': 1}


def estimate(workload):
    kind = workload['kind']
    operations = workload['actual_operations']
    if kind not in PEAK or not isinstance(operations, int) or operations <= 0:
        raise ValueError('kind and positive actual_operations are required')
    terms = {'arithmetic': (operations + PEAK[kind] - 1) // PEAK[kind]}
    for port, bandwidth in PORTS.items():
        count = workload[port]
        if not isinstance(count, int) or count < 0:
            raise ValueError(f'{port} must be a nonnegative integer')
        terms[port] = (count + bandwidth - 1) // bandwidth
    latency = workload['gmem_latency_cycles']
    transactions = workload['gmem_transactions']
    if not isinstance(latency, int) or not isinstance(transactions, int) or min(latency,transactions)<0:
        raise ValueError('latency and transaction count must be nonnegative integers')
    # Little's law, for the planned aggregate window of 256 MSHRs.
    terms['gmem_window'] = (latency * transactions + 255) // 256
    cycles = max(terms.values())
    result = {'minimum_cycles': cycles, 'actual_ops_per_cycle_bound': operations/cycles,
              'resource_cycles': terms, 'bottlenecks': [k for k,v in terms.items() if v == cycles],
              'configuration': 'planned single-SM resources; not measured NVIDIA throughput'}
    if 'measured_cycles' in workload:
        measured = workload['measured_cycles']
        if not isinstance(measured, int) or measured < cycles:
            raise ValueError('measurement violates bound; check counters, resources and work definition')
        result['efficiency_to_bound'] = cycles/measured
        result['passes_85_percent'] = cycles/measured >= 0.85
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workload', type=Path)
    args = parser.parse_args()
    print(json.dumps(estimate(json.loads(args.workload.read_text())), indent=2))
