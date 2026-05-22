# Blackwell TCGen05 MMA Validation Report

Date: 2026-05-22

## Scope

This validation covers the repo-local TCGen05 scalar-dot adapter:

- RTL: `src/main/tcgen05_dot_adapter.sv`
- Package: `src/main/tcgen05_mma_pkg.sv`
- Inventory: `doc/Blackwell_TCGen05_MMA.json`
- Cocotb tests: `src/test/cocotb/test_tcgen05_mma.py`
- Golden model: `src/test/cocotb/mma_sim_tcgen05_ref.py`

The adapter validates one `(A row, B column, C)` scalar dot selected from each
TCGen05 semantic MMA row. It does not model TMEM allocation, TMA, commit/wait,
mbarrier, or hardware SASS encoding.

## Coverage

- Inventory rows checked: 592 / 592
- Adapter arithmetic rows checked with MMA-Sim/local golden: 592 / 592
- Explicit unsupported inventory rows checked through DUT status: 0 / 0
- Random arithmetic stress: 16 random cases per adapter-supported row
- Directed modifier/error cases:
  - `scale-input-d`
  - `enable-input-d=0`
  - invalid sparse metadata
  - illegal non-inventory request reported as unsupported

Total TCGen05 DUT transactions in the full run:

- 592 inventory classification transactions
- 592 deterministic supported arithmetic transactions
- 9472 random supported arithmetic transactions
- 4 directed modifier/error transactions
- 10660 total transactions

## Command

```bash
cd /Users/liuyuxuan/work/Allegro/src/test/cocotb
PYTHONPATH=/Users/liuyuxuan/Library/Python/3.13/lib/python/site-packages \
make SIM=verilator \
  TOPLEVEL=tcgen05_dot_adapter \
  COCOTB_TEST_MODULES=test_tcgen05_mma \
  NUM_RANDOM_PER_COMBO=16 \
  SIM_BUILD=sim_build_tcgen05_all_supported_592 \
  PYTHON_BIN=/opt/anaconda3/bin/python3.13 \
  COCOTB_CONFIG='/opt/anaconda3/bin/python3.13 -m cocotb_tools.config'
```

## Result

```text
TESTS=4 PASS=4 FAIL=0 SKIP=0
```

Passing tests:

- `tcgen05_inventory_manifest_is_complete`
- `tcgen05_all_inventory_rows_classified_by_adapter`
- `tcgen05_inventory_supported_cases_match_mmasim`
- `tcgen05_directed_modifiers_and_error_paths`

## FP4 Direct Regression

The FP4 dot unit was also run directly against the MMA-Sim NVFP4/MXFP4 golden,
including the new `FP4_MODE_MXFP4_4X` block16 path:

```bash
cd /Users/liuyuxuan/work/Allegro/src/test/cocotb
COMPILE_ARGS='-Wno-fatal -CFLAGS -isystem/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1' \
PYTHONPATH=/Users/liuyuxuan/Library/Python/3.13/lib/python/site-packages \
make SIM=verilator \
  TOPLEVEL=fp4_dot_prod \
  COCOTB_TEST_MODULES=test_nvfp4_dot \
  NUM_CASES=1000 \
  SIM_BUILD=sim_build_fp4_mxfp4_4x \
  PYTHON_BIN=/opt/anaconda3/bin/python3.13 \
  COCOTB_CONFIG='/opt/anaconda3/bin/python3.13 -m cocotb_tools.config'
```

```text
TESTS=3 PASS=3 FAIL=0 SKIP=0
```

## Known Limits

- All 592 generated semantic rows are claimed as adapter arithmetic-pass rows.
  Unsupported-status coverage is retained through an intentionally illegal
  non-inventory request.
- Full tile/TMEM/TMA/commit/wait/mbarrier behavior is outside this adapter.
- SASS opcode validation is blocked until a Blackwell-capable CUDA toolchain
  with `ptxas`/`nvdisasm` is available.
