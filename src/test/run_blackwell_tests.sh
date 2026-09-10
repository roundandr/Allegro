#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/blackwell_common.sh"
require_blackwell_environment

# Check Python dependencies before compiling any RTL.
python3 -c 'import cocotb, numpy'
export PYTHONPATH="${ROOT}/src/test/cocotb:${PYTHONPATH:-}"
export COCOTB_RANDOM_SEED="${COCOTB_RANDOM_SEED:-20260813}"
export RANDOM_SEED="${COCOTB_RANDOM_SEED}"
mkdir -p "${BUILD_DIR}/logs" "${BUILD_DIR}/bin"

# Cocotb can be installed for Python without cocotb-config being on PATH.
printf '#!/usr/bin/env bash\nexec python3 -m cocotb.config "$@"\n' > "${BUILD_DIR}/bin/cocotb-config"
chmod +x "${BUILD_DIR}/bin/cocotb-config"
export PATH="${BUILD_DIR}/bin:${PATH}"
COCOTB_MAKEFILES="$(python3 -m cocotb.config --makefiles)"

bash src/test/lint_blackwell.sh

COMMON=(
  "${ROOT}/src/main/tcgen05_mma_pkg.sv"
  "${ROOT}/src/main/utils/dot_prod_pkg.sv"
  "${ROOT}/src/main/utils/dot_fp32_rz_norm_pack.sv"
  "${ROOT}/src/main/utils/dot_signed_reduce_tree.sv"
  "${ROOT}/src/main/utils/dot_emax_tree.sv"
  "${ROOT}/src/main/utils/dot_align_fixed_rz.sv"
  "${ROOT}/src/main/utils/pipeline_reg.sv"
  "${ROOT}/src/main/f16tf32_dot_prod.sv"
  "${ROOT}/src/main/f4f6f8_dot_prod.sv"
  "${ROOT}/src/main/int8_dot_prod.sv"
  "${ROOT}/src/main/fp4_dot_prod.sv"
  "${ROOT}/src/main/tcgen05_dot_adapter.sv"
)


run_cocotb_params() {
  local top="$1" module="$2" params="$3"
  shift 3
  local name="${top}${params:+_${params//[^A-Za-z0-9]/_}}"
  local work="${BUILD_DIR}/tests/${name}"
  mkdir -p "${work}"
  rm -f "${work}/results.xml"
  printf 'Running %s\n' "${name}"
  make -j "${JOBS:-4}" -C "${work}" -f "${COCOTB_MAKEFILES}/Makefile.sim" \
    SIM=verilator TOPLEVEL_LANG=verilog TOPLEVEL="${top}" \
    MODULE="${module}" SIM_BUILD="${work}/sim" \
    COCOTB_RESULTS_FILE="${work}/results.xml" \
    EXTRA_ARGS="--timing --gate-stmts 0 -Wno-fatal ${params}" \
    VERILOG_SOURCES="$*" 2>&1 | tee "${BUILD_DIR}/logs/${name}.log"

  python3 - "${work}/results.xml" <<'CHECK_RESULTS'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
root = ET.parse(path).getroot()
if not root.findall('.//testcase') or root.findall('.//failure') or root.findall('.//error'):
    raise SystemExit(f'ERROR: empty or failing Cocotb results: {path}')
CHECK_RESULTS
}

run_cocotb() {
  local top="$1" module="$2"
  shift 2
  run_cocotb_params "${top}" "${module}" "" "$@"
}

run_cocotb tma_mbarrier_tb test_tma_mbarrier \
  "${ROOT}/src/main/tma_mbarrier_pkg.sv" \
  "${ROOT}/src/main/tma_engine.sv" \
  "${ROOT}/src/main/mbarrier_unit.sv" \
  "${ROOT}/src/main/tma_mbarrier_subsystem.sv" \
  "${ROOT}/src/test/tma_mbarrier_tb.sv"

run_cocotb tmem_array_tb test_tmem_array \
  "${ROOT}/src/main/tmem_array.sv" \
  "${ROOT}/src/test/tmem_array_tb.sv"

TMEM_TEST_PORT_MODE=2 run_cocotb_params tmem_array_tb test_tmem_array "-GPORT_MODE=2" \
  "${ROOT}/src/main/tmem_array.sv" \
  "${ROOT}/src/test/tmem_array_tb.sv"

TMEM_TEST_PORT_MODE=1 run_cocotb_params tmem_array_tb test_tmem_array "-GPORT_MODE=1" \
  "${ROOT}/src/main/tmem_array.sv" \
  "${ROOT}/src/test/tmem_array_tb.sv"

run_cocotb tc_wrapper_tb test_tc_wrapper \
  "${COMMON[@]}" \
  "${ROOT}/src/main/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/src/test/tc_wrapper_tb.sv"

run_cocotb_params tc_wrapper_tb test_tc_wrapper "-GREG_SLICE=0" \
  "${COMMON[@]}" \
  "${ROOT}/src/main/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/src/test/tc_wrapper_tb.sv"

run_cocotb_params tc_wrapper_tb test_tc_wrapper "-GREG_SLICE=2" \
  "${COMMON[@]}" \
  "${ROOT}/src/main/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/src/test/tc_wrapper_tb.sv"

run_cocotb blackwell_subsystem_tb test_blackwell_subsystem \
  "${ROOT}/src/main/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/src/main/tmem_array.sv" \
  "${ROOT}/src/main/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/src/main/blackwell_tensor_subsystem.sv" \
  "${ROOT}/src/test/blackwell_subsystem_tb.sv"

# Exercise parameters that materially alter the integrated datapath: B reads
# share the A port, staging becomes single-entry, and TMEM uses shared 1RW.
run_cocotb_params blackwell_subsystem_tb test_blackwell_subsystem \
  "-GSTAGING_DEPTH=1 -GTC_REG_SLICE=0 -GTMEM_PORT_MODE=1 -GSMEM_READ_PORTS=1" \
  "${ROOT}/src/main/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/src/main/tmem_array.sv" \
  "${ROOT}/src/main/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/src/main/blackwell_tensor_subsystem.sv" \
  "${ROOT}/src/test/blackwell_subsystem_tb.sv"

# Validate the opposite latency/capacity corner of the integrated datapath.
run_cocotb_params blackwell_subsystem_tb test_blackwell_subsystem \
  "-GSTAGING_DEPTH=4 -GTC_REG_SLICE=2 -GTMEM_PORT_MODE=2" \
  "${ROOT}/src/main/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/src/main/tmem_array.sv" \
  "${ROOT}/src/main/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/src/main/blackwell_tensor_subsystem.sv" \
  "${ROOT}/src/test/blackwell_subsystem_tb.sv"

run_cocotb blackwell_tma_compat_tb test_blackwell_tma_compat \
  "${ROOT}/src/main/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/src/main/tmem_array.sv" \
  "${ROOT}/src/main/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/src/main/blackwell_tensor_subsystem.sv" \
  "${ROOT}/src/main/tma_mbarrier_pkg.sv" \
  "${ROOT}/src/main/tma_engine.sv" \
  "${ROOT}/src/main/mbarrier_unit.sv" \
  "${ROOT}/src/main/tma_mbarrier_subsystem.sv" \
  "${ROOT}/src/main/blackwell_tma_mbarrier_top.sv" \
  "${ROOT}/src/test/blackwell_tma_compat_tb.sv"

printf '%s\n' "All 11 standalone RTL configurations passed; results are under build/blackwell/."
