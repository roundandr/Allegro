#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/blackwell_common.sh"
require_blackwell_environment
mkdir -p "${BUILD_DIR}/logs" "${BUILD_DIR}/lint"

# Verilator 5.020 has a known internal V3Gate failure when eight copies of the
# locked Allegro pipeline are optimized together. Gate depth 0 preserves lint
# semantics while avoiding that optimizer pass.
{
verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
  --Mdir "${BUILD_DIR}/lint/tensor" \
  --top-module blackwell_tensor_subsystem -f src/main/blackwell_tensor_filelist.f

verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
  --Mdir "${BUILD_DIR}/lint/tma_mbarrier" \
  --top-module tma_mbarrier_subsystem -f src/main/tma_mbarrier_filelist.f

verilator --lint-only --timing --gate-stmts 0 -Wall -Wno-fatal \
  --Mdir "${BUILD_DIR}/lint/connected" \
  --top-module blackwell_tma_mbarrier_top \
  -f src/main/blackwell_subsystem_filelist.f
} 2>&1 | tee "${BUILD_DIR}/logs/verilator_lint.log"
