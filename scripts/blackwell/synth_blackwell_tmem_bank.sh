#!/usr/bin/env bash
# Run on the configured remote CPU. Converts the complete TMEM owner/data
# module, then checks the hierarchy and inferred physical memories in Yosys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${ROOT}"
OUT="${ROOT}/build/blackwell/tmem-bank-synthesis"
mkdir -p "${OUT}"
SV2V_BIN="${SV2V:-${HOME}/.local/share/remote-rtx5080/envs/sv2v-0.0.13/sv2v}"
if [[ ! -x "${SV2V_BIN}" ]]; then
  echo "sv2v v0.0.13 is required in the isolated remote tool environment" >&2
  exit 1
fi
"${SV2V_BIN}" --version > "${OUT}/sv2v-version.txt"
"${SV2V_BIN}" --top=blackwell_tmem_bank \
  rtl/common/blackwell_banked_sram.sv rtl/tmem/blackwell_tmem_bank.sv \
  > "${OUT}/converted.v" 2> "${OUT}/sv2v.log"
docker run --rm --network none --user "$(id -u):$(id -g)" \
  -v "${ROOT}:/work" -w /work openroad/orfs:latest \
  /usr/local/bin/yosys -Q -T -l /work/build/blackwell/tmem-bank-synthesis/yosys.log -p \
  'read_verilog -sv /work/build/blackwell/tmem-bank-synthesis/converted.v; hierarchy -check -top blackwell_tmem_bank; proc; opt; memory_dff; memory_share; memory_collect; opt_clean; check -assert; stat; write_json /work/build/blackwell/tmem-bank-synthesis/netlist.json'
python3 verification/checks/check_blackwell_tmem_bank_netlist.py "${OUT}/netlist.json" > "${OUT}/structure.json"
