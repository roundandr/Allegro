#!/usr/bin/env bash
# Structural synthesis of the standalone 256-dot FP16/BF16 arithmetic array.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${ROOT}"
OUT="${ROOT}/build/blackwell/f16-array-synthesis"
mkdir -p "${OUT}"
SV2V_BIN="${SV2V:-${HOME}/.local/share/remote-rtx5080/envs/sv2v-0.0.13/sv2v}"
if [[ ! -x "${SV2V_BIN}" ]]; then
  echo "sv2v v0.0.13 is required in the isolated remote tool environment" >&2
  exit 1
fi
"${SV2V_BIN}" --version > "${OUT}/sv2v-version.txt"
"${SV2V_BIN}" --top=blackwell_f16_dot_array \
  rtl/dot/dot_prod_pkg.sv \
  rtl/dot/dot_fp32_rz_norm_pack.sv \
  rtl/dot/dot_signed_reduce_tree.sv \
  rtl/dot/dot_emax_tree.sv \
  rtl/dot/dot_align_fixed_rz.sv \
  rtl/dot/pipeline_reg.sv \
  rtl/dot/f16tf32_dot_prod.sv \
  rtl/common/blackwell_fifo.sv \
  rtl/dot/blackwell_f16_dot_array.sv \
  > "${OUT}/converted.v" 2> "${OUT}/sv2v.log"
docker run --rm --network none --user "$(id -u):$(id -g)" \
  -v "${ROOT}:/work" -w /work openroad/orfs:latest \
  /usr/local/bin/yosys -Q -T -l /work/build/blackwell/f16-array-synthesis/yosys.log -p \
  'read_verilog -sv /work/build/blackwell/f16-array-synthesis/converted.v; hierarchy -check -top blackwell_f16_dot_array; proc; opt_clean; check -assert; stat; write_json /work/build/blackwell/f16-array-synthesis/netlist.json'
python3 verification/checks/check_blackwell_f16_array_netlist.py "${OUT}/netlist.json" > "${OUT}/structure.json"
