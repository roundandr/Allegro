#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/blackwell_common.sh"
require_blackwell_environment

# Check Python dependencies before compiling any RTL.
python3 -c 'import cocotb, numpy'
export PYTHONPATH="${ROOT}/verification/cocotb:${PYTHONPATH:-}"
export COCOTB_RANDOM_SEED="${COCOTB_RANDOM_SEED:-20260813}"
export RANDOM_SEED="${COCOTB_RANDOM_SEED}"
mkdir -p "${BUILD_DIR}/logs" "${BUILD_DIR}/bin"

# Cocotb can be installed for Python without cocotb-config being on PATH.
printf '#!/usr/bin/env bash\nexec python3 -m cocotb.config "$@"\n' > "${BUILD_DIR}/bin/cocotb-config"
chmod +x "${BUILD_DIR}/bin/cocotb-config"
export PATH="${BUILD_DIR}/bin:${PATH}"
COCOTB_MAKEFILES="$(python3 -m cocotb.config --makefiles)"

bash scripts/blackwell/lint_blackwell.sh

COMMON=(
  "${ROOT}/rtl/tensor_core/tcgen05_mma_pkg.sv"
  "${ROOT}/rtl/dot/dot_prod_pkg.sv"
  "${ROOT}/rtl/dot/dot_fp32_rz_norm_pack.sv"
  "${ROOT}/rtl/dot/dot_signed_reduce_tree.sv"
  "${ROOT}/rtl/dot/dot_emax_tree.sv"
  "${ROOT}/rtl/dot/dot_align_fixed_rz.sv"
  "${ROOT}/rtl/dot/pipeline_reg.sv"
  "${ROOT}/rtl/dot/f16tf32_dot_prod.sv"
  "${ROOT}/rtl/dot/f4f6f8_dot_prod.sv"
  "${ROOT}/rtl/dot/int8_dot_prod.sv"
  "${ROOT}/rtl/dot/fp4_dot_prod.sv"
  "${ROOT}/rtl/tensor_core/tcgen05_dot_adapter.sv"
)


run_cocotb_params() {
  local top="$1" module="$2" params="$3"
  shift 3
  if [[ -n "${BLACKWELL_TEST_TOP:-}" && ",${BLACKWELL_TEST_TOP}," != *",${top},"* ]]; then return; fi
  local name="${top}${params:+_${params//[^A-Za-z0-9]/_}}"
  local work="${BUILD_DIR}/tests/${name}"
  mkdir -p "${work}"
  rm -f "${work}/results.xml"
  printf 'Running %s\n' "${name}"
  make -j "${JOBS:-4}" -C "${work}" -f "${COCOTB_MAKEFILES}/Makefile.sim" \
    SIM=verilator TOPLEVEL_LANG=verilog TOPLEVEL="${top}" \
    MODULE="${module}" SIM_BUILD="${work}/sim" \
    COCOTB_RESULTS_FILE="${work}/results.xml" \
    EXTRA_ARGS="--timing --assert --gate-stmts 0 -Wno-fatal -CFLAGS -DVL_VALUE_STRING_MAX_WORDS=4096 ${params}" \
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

run_cocotb tcgen05_completion_tracker test_tc_completion \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv"
run_cocotb_params tcgen05_completion_tracker test_tc_completion "-GOPERATIONS=3 -GCOMMITS=3" \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv"
run_cocotb blackwell_banked_sram test_banked_sram "${ROOT}/rtl/common/blackwell_banked_sram.sv"
run_cocotb blackwell_tmem_bank test_tmem_bank \
  "${ROOT}/rtl/common/blackwell_banked_sram.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_bank.sv"
run_cocotb blackwell_tmem_rf_map test_tmem_rf_map \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_map.sv"
run_cocotb blackwell_tmem_rf_group test_tmem_rf_group \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_group.sv"
run_cocotb blackwell_tmem_wait_tracker test_tmem_wait_tracker \
  "${ROOT}/rtl/tmem/blackwell_tmem_wait_tracker.sv"
run_cocotb_params blackwell_tmem_wait_tracker test_tmem_wait_tracker \
  "-GOPERATIONS=2 -GWAITS=2" \
  "${ROOT}/rtl/tmem/blackwell_tmem_wait_tracker.sv"
run_cocotb blackwell_tmem_rf_subsystem test_tmem_rf_subsystem \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/blackwell_banked_sram.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_bank.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_map.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_stage.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_group.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_wait_tracker.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_shift_engine.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_subsystem.sv"
run_cocotb blackwell_tmem_shift_commit_tb test_tmem_shift_commit \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_commit_bridge.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_async_completion.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_unit.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_tc_arbiter.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_frontend.sv" \
  "${ROOT}/rtl/common/blackwell_fifo.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_backend.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_port.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_system.sv" \
  "${ROOT}/rtl/smem/blackwell_tma_smem_bridge.sv" \
  "${ROOT}/rtl/common/blackwell_banked_sram.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_bank.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_map.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_stage.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_group.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_wait_tracker.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_shift_engine.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_subsystem.sv" \
  "${ROOT}/verification/tb/blackwell_tmem_shift_commit_tb.sv"
run_cocotb_params blackwell_tmem_shift_commit_tb test_tmem_shift_mbarrier \
  "-GREAL_BACKING=1" \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_commit_bridge.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_async_completion.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_unit.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_tc_arbiter.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_frontend.sv" \
  "${ROOT}/rtl/common/blackwell_fifo.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_backend.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_port.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_system.sv" \
  "${ROOT}/rtl/smem/blackwell_tma_smem_bridge.sv" \
  "${ROOT}/rtl/common/blackwell_banked_sram.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_bank.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_map.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_stage.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_group.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_wait_tracker.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_shift_engine.sv" \
  "${ROOT}/rtl/tmem/blackwell_tmem_rf_subsystem.sv" \
  "${ROOT}/verification/tb/blackwell_tmem_shift_commit_tb.sv"
run_cocotb_params blackwell_banked_sram test_banked_sram "-GBANKS=32 -GDATA_W=32 -GDEPTH=1824" \
  "${ROOT}/rtl/common/blackwell_banked_sram.sv"

run_cocotb tcgen05_dot_adapter "${BLACKWELL_DOT_TEST_MODULES:-test_tc_pipeline}" "${COMMON[@]}"
run_cocotb_params blackwell_f16_dot_array test_f16_dot_array "-GDOTS=4" \
  "${ROOT}/rtl/dot/dot_prod_pkg.sv" \
  "${ROOT}/rtl/dot/dot_fp32_rz_norm_pack.sv" \
  "${ROOT}/rtl/dot/dot_signed_reduce_tree.sv" \
  "${ROOT}/rtl/dot/dot_emax_tree.sv" \
  "${ROOT}/rtl/dot/dot_align_fixed_rz.sv" \
  "${ROOT}/rtl/dot/pipeline_reg.sv" \
  "${ROOT}/rtl/dot/f16tf32_dot_prod.sv" \
  "${ROOT}/rtl/common/blackwell_fifo.sv" \
  "${ROOT}/rtl/dot/blackwell_f16_dot_array.sv"
run_cocotb_params blackwell_f16_dot_array test_f16_dot_array "-GDOTS=256" \
  "${ROOT}/rtl/dot/dot_prod_pkg.sv" \
  "${ROOT}/rtl/dot/dot_fp32_rz_norm_pack.sv" \
  "${ROOT}/rtl/dot/dot_signed_reduce_tree.sv" \
  "${ROOT}/rtl/dot/dot_emax_tree.sv" \
  "${ROOT}/rtl/dot/dot_align_fixed_rz.sv" \
  "${ROOT}/rtl/dot/pipeline_reg.sv" \
  "${ROOT}/rtl/dot/f16tf32_dot_prod.sv" \
  "${ROOT}/rtl/common/blackwell_fifo.sv" \
  "${ROOT}/rtl/dot/blackwell_f16_dot_array.sv"
run_cocotb blackwell_smem_backend test_smem_backend \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/common/blackwell_fifo.sv" \
  "${ROOT}/rtl/common/blackwell_banked_sram.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_backend.sv"
run_cocotb_params blackwell_smem_backend test_smem_backend "-GCLIENTS=3 -GRESPONSE_DEPTH=3 -GLINES=17" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/common/blackwell_fifo.sv" \
  "${ROOT}/rtl/common/blackwell_banked_sram.sv" \
  "${ROOT}/rtl/smem/blackwell_smem_backend.sv"
SMEM_SOURCES=(
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv"
  "${ROOT}/rtl/common/blackwell_fifo.sv"
  "${ROOT}/rtl/common/blackwell_banked_sram.sv"
  "${ROOT}/rtl/smem/blackwell_smem_backend.sv"
  "${ROOT}/rtl/smem/blackwell_smem_port.sv"
  "${ROOT}/rtl/smem/blackwell_smem_system.sv"
)
run_cocotb blackwell_smem_system test_smem_system "${SMEM_SOURCES[@]}"
run_cocotb_params blackwell_smem_system test_smem_system "-GCLIENTS=3 -GENTRIES=3 -GRESPONSE_DEPTH=3 -GLINES=17" "${SMEM_SOURCES[@]}"
run_cocotb blackwell_order_tracker test_order_tracker \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" "${ROOT}/rtl/common/blackwell_order_tracker.sv"
run_cocotb_params blackwell_order_tracker test_order_tracker "-GOPERATIONS=3 -GFENCES=3" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" "${ROOT}/rtl/common/blackwell_order_tracker.sv"
run_cocotb blackwell_warp_collective test_warp_collective "${ROOT}/rtl/common/blackwell_warp_collective.sv"
run_cocotb_params blackwell_warp_collective test_warp_collective "-GWARPS=3 -GPAYLOAD_W=64" "${ROOT}/rtl/common/blackwell_warp_collective.sv"

run_cocotb tma_mbarrier_tb test_tma_mbarrier \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_commit_bridge.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_async_completion.sv" \
  "${ROOT}/rtl/tma/tma_tensor_map.sv" \
  "${ROOT}/rtl/tma/tma_map_control.sv" \
  "${ROOT}/rtl/tma/tma_data_engine.sv" \
  "${ROOT}/rtl/tma/tma_copy_engine.sv" \
  "${ROOT}/rtl/tma/tma_engine.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_unit.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_tc_arbiter.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_frontend.sv" \
  "${ROOT}/rtl/top/tma_mbarrier_subsystem.sv" \
  "${SMEM_SOURCES[@]:1}" \
  "${ROOT}/rtl/smem/blackwell_tma_smem_bridge.sv" \
  "${ROOT}/verification/tb/tma_mbarrier_tb.sv"

run_cocotb_params tma_mbarrier_tb test_tma_shared_memory "-GREAL_SMEM=1" \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_commit_bridge.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_async_completion.sv" \
  "${ROOT}/rtl/tma/tma_tensor_map.sv" \
  "${ROOT}/rtl/tma/tma_map_control.sv" \
  "${ROOT}/rtl/tma/tma_data_engine.sv" \
  "${ROOT}/rtl/tma/tma_copy_engine.sv" \
  "${ROOT}/rtl/tma/tma_engine.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_unit.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_tc_arbiter.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_frontend.sv" \
  "${ROOT}/rtl/top/tma_mbarrier_subsystem.sv" \
  "${SMEM_SOURCES[@]:1}" \
  "${ROOT}/rtl/smem/blackwell_tma_smem_bridge.sv" \
  "${ROOT}/verification/tb/tma_mbarrier_tb.sv"

# Small, non-power-of-two queues and a single wait entry exercise backpressure.
TMA_TEST_QUEUE_DEPTH=3 TMA_TEST_WRITE_DEPTH=2 TMA_TEST_WAIT_ENTRIES=1 run_cocotb_params tma_mbarrier_tb test_tma_mbarrier \
  "-GCMD_QUEUE_DEPTH=3 -GDESC_CACHE_ENTRIES=1 -GMSHR_ENTRIES=3 -GWAIT_ENTRIES=1 -GWRITE_BUF_DEPTH=2 -GBAR_CLOCK_PERIOD_NS=5" \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_commit_bridge.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_async_completion.sv" \
  "${ROOT}/rtl/tma/tma_tensor_map.sv" \
  "${ROOT}/rtl/tma/tma_map_control.sv" \
  "${ROOT}/rtl/tma/tma_data_engine.sv" \
  "${ROOT}/rtl/tma/tma_copy_engine.sv" \
  "${ROOT}/rtl/tma/tma_engine.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_unit.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_tc_arbiter.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_frontend.sv" \
  "${ROOT}/rtl/top/tma_mbarrier_subsystem.sv" \
  "${SMEM_SOURCES[@]:1}" \
  "${ROOT}/rtl/smem/blackwell_tma_smem_bridge.sv" \
  "${ROOT}/verification/tb/tma_mbarrier_tb.sv"

# Minimal asynchronous table and two data MSHRs exercise independent completion progress.
TMA_TEST_QUEUE_DEPTH=2 TMA_TEST_WRITE_DEPTH=3 TMA_TEST_ASYNC_ENTRIES=6 TMA_TEST_WAIT_ENTRIES=2 run_cocotb_params tma_mbarrier_tb test_tma_mbarrier \
  "-GCMD_QUEUE_DEPTH=2 -GDESC_CACHE_ENTRIES=2 -GMSHR_ENTRIES=2 -GWAIT_ENTRIES=2 -GWRITE_BUF_DEPTH=3 -GBAR_ASYNC_ENTRIES=6" \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_commit_bridge.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_async_completion.sv" \
  "${ROOT}/rtl/tma/tma_tensor_map.sv" \
  "${ROOT}/rtl/tma/tma_map_control.sv" \
  "${ROOT}/rtl/tma/tma_data_engine.sv" \
  "${ROOT}/rtl/tma/tma_copy_engine.sv" \
  "${ROOT}/rtl/tma/tma_engine.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_unit.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_tc_arbiter.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_frontend.sv" \
  "${ROOT}/rtl/top/tma_mbarrier_subsystem.sv" \
  "${SMEM_SOURCES[@]:1}" \
  "${ROOT}/rtl/smem/blackwell_tma_smem_bridge.sv" \
  "${ROOT}/verification/tb/tma_mbarrier_tb.sv"

run_cocotb tmem_array_tb test_tmem_array \
  "${ROOT}/rtl/tmem/tmem_array.sv" \
  "${ROOT}/verification/tb/tmem_array_tb.sv"

TMEM_TEST_PORT_MODE=2 run_cocotb_params tmem_array_tb test_tmem_array "-GPORT_MODE=2" \
  "${ROOT}/rtl/tmem/tmem_array.sv" \
  "${ROOT}/verification/tb/tmem_array_tb.sv"

TMEM_TEST_PORT_MODE=1 run_cocotb_params tmem_array_tb test_tmem_array "-GPORT_MODE=1" \
  "${ROOT}/rtl/tmem/tmem_array.sv" \
  "${ROOT}/verification/tb/tmem_array_tb.sv"

run_cocotb tc_wrapper_tb test_tc_wrapper \
  "${COMMON[@]}" \
  "${ROOT}/rtl/tensor_core/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/verification/tb/tc_wrapper_tb.sv"

run_cocotb_params tc_wrapper_tb test_tc_wrapper "-GREG_SLICE=0" \
  "${COMMON[@]}" \
  "${ROOT}/rtl/tensor_core/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/verification/tb/tc_wrapper_tb.sv"

run_cocotb_params tc_wrapper_tb test_tc_wrapper "-GREG_SLICE=2" \
  "${COMMON[@]}" \
  "${ROOT}/rtl/tensor_core/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/verification/tb/tc_wrapper_tb.sv"

run_cocotb blackwell_subsystem_tb test_blackwell_subsystem \
  "${ROOT}/rtl/tensor_core/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/rtl/tmem/tmem_array.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/rtl/tensor_core/blackwell_tensor_subsystem.sv" \
  "${ROOT}/verification/tb/blackwell_subsystem_tb.sv"

# Exercise parameters that materially alter the integrated datapath: B reads
# share the A port, staging becomes single-entry, and TMEM uses shared 1RW.
run_cocotb_params blackwell_subsystem_tb test_blackwell_subsystem \
  "-GSTAGING_DEPTH=1 -GTC_REG_SLICE=0 -GTMEM_PORT_MODE=1 -GSMEM_READ_PORTS=1" \
  "${ROOT}/rtl/tensor_core/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/rtl/tmem/tmem_array.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/rtl/tensor_core/blackwell_tensor_subsystem.sv" \
  "${ROOT}/verification/tb/blackwell_subsystem_tb.sv"

# Validate the opposite latency/capacity corner of the integrated datapath.
run_cocotb_params blackwell_subsystem_tb test_blackwell_subsystem \
  "-GSTAGING_DEPTH=4 -GTC_REG_SLICE=2 -GTMEM_PORT_MODE=2" \
  "${ROOT}/rtl/tensor_core/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/rtl/tmem/tmem_array.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/rtl/tensor_core/blackwell_tensor_subsystem.sv" \
  "${ROOT}/verification/tb/blackwell_subsystem_tb.sv"

run_cocotb blackwell_integration_tb test_blackwell_integration \
  "${ROOT}/rtl/tensor_core/blackwell_pkg.sv" \
  "${COMMON[@]}" \
  "${ROOT}/rtl/tmem/tmem_array.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_tensor_wrapper.sv" \
  "${ROOT}/rtl/tensor_core/blackwell_tensor_subsystem.sv" \
  "${ROOT}/rtl/common/blackwell_async_pkg.sv" \
  "${ROOT}/rtl/common/tma_mbarrier_pkg.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_completion_tracker.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_commit_bridge.sv" \
  "${ROOT}/rtl/tensor_core/tcgen05_async_completion.sv" \
  "${ROOT}/rtl/tma/tma_tensor_map.sv" \
  "${ROOT}/rtl/tma/tma_map_control.sv" \
  "${ROOT}/rtl/tma/tma_data_engine.sv" \
  "${ROOT}/rtl/tma/tma_copy_engine.sv" \
  "${ROOT}/rtl/tma/tma_engine.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_unit.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_tc_arbiter.sv" \
  "${ROOT}/rtl/mbarrier/mbarrier_frontend.sv" \
  "${ROOT}/rtl/top/tma_mbarrier_subsystem.sv" \
  "${ROOT}/rtl/top/blackwell_tma_mbarrier_top.sv" \
  "${ROOT}/verification/tb/blackwell_integration_tb.sv"

printf '%s\n' "Selected standalone RTL configurations passed; results are under build/blackwell/."
