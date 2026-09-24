#!/usr/bin/env bash
# Run on the configured remote CPU, using the retained ORFS Yosys image.
# These checks cover physical memories, not an entire Tensor Core synthesis.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${ROOT}"
OUT="${ROOT}/build/blackwell/synthesis"
mkdir -p "${OUT}"
docker run --rm --network none --user "$(id -u):$(id -g)" \
  -v "${ROOT}:/work" -w /work openroad/orfs:latest \
  /usr/local/bin/yosys -V > "${OUT}/yosys-version.txt"
for geometry in tmem smem; do
  params=""
  if [[ "${geometry}" == smem ]]; then
    params="chparam -set BANKS 32 -set DEPTH 1824 -set DATA_W 32 blackwell_banked_sram;"
  fi
  docker run --rm --network none --user "$(id -u):$(id -g)" \
    -v "${ROOT}:/work" -w /work openroad/orfs:latest \
    /usr/local/bin/yosys -Q -T -l "/work/build/blackwell/synthesis/${geometry}.log" -p \
    "read_verilog -sv rtl/common/blackwell_banked_sram.sv; ${params} hierarchy -check -top blackwell_banked_sram; proc; opt; memory_dff; memory_share; memory_collect; opt_clean; check -assert; stat; write_json /work/build/blackwell/synthesis/${geometry}.json"
done
python3 verification/checks/check_blackwell_sram_netlist.py "${OUT}"
