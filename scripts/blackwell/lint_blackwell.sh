#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/blackwell_common.sh"
require_blackwell_environment
mkdir -p "${BUILD_DIR}/logs" "${BUILD_DIR}/lint"

# Verilator 5.020 has a known internal V3Gate failure when eight copies of the
# locked Allegro pipeline are optimized together. Gate depth 0 preserves lint
# semantics while avoiding that optimizer pass.
{
for async_top in tcgen05_completion_tracker tcgen05_async_completion tcgen05_commit_bridge blackwell_banked_sram blackwell_tmem_bank blackwell_tmem_rf_map blackwell_tmem_rf_stage blackwell_tmem_rf_group blackwell_tmem_wait_tracker blackwell_tmem_shift_engine blackwell_tmem_rf_subsystem blackwell_smem_backend blackwell_smem_system blackwell_order_tracker blackwell_warp_collective; do
  verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
    --Mdir "${BUILD_DIR}/lint/${async_top}" --top-module "${async_top}" \
    -f filelists/blackwell_async_filelist.f
done

verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
  --Mdir "${BUILD_DIR}/lint/tensor" \
  --top-module blackwell_tensor_subsystem -f filelists/blackwell_tensor_filelist.f

verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
  --Mdir "${BUILD_DIR}/lint/f16_array" \
  --top-module blackwell_f16_dot_array -f filelists/blackwell_tensor_filelist.f

verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
  --Mdir "${BUILD_DIR}/lint/tma_mbarrier" \
  --top-module tma_mbarrier_subsystem -f filelists/tma_mbarrier_filelist.f

verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
  --Mdir "${BUILD_DIR}/lint/connected" \
  --top-module blackwell_tma_mbarrier_top \
  -f filelists/blackwell_subsystem_filelist.f
} 2>&1 | tee "${BUILD_DIR}/logs/verilator_lint.log"
