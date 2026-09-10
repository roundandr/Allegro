#!/usr/bin/env bash
# Shared setup for the Blackwell subsystem checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT}/build/blackwell"
cd "${ROOT}"
export PYTHONDONTWRITEBYTECODE=1

require_blackwell_environment() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: run make lint-blackwell/test-blackwell on the configured RTX 5080 host; the local workstation is source-only." >&2
    return 1
  fi

  # Arithmetic RTL belongs to this checkout. Check source availability rather
  # than requiring a second Allegro checkout at a fixed historical HEAD.
  local filelist source
  for filelist in src/main/blackwell_tensor_filelist.f \
                  src/main/tma_mbarrier_filelist.f \
                  src/main/blackwell_subsystem_filelist.f; do
    if [[ ! -f "${filelist}" ]]; then
      echo "ERROR: missing Blackwell compilation filelist: ${filelist}" >&2
      return 1
    fi
    while IFS= read -r source || [[ -n "${source}" ]]; do
      [[ -z "${source}" || "${source}" == \#* ]] && continue
      source="${source#-f }"
      if [[ ! -f "${source}" ]]; then
        echo "ERROR: missing source ${source} referenced by ${filelist}; use a complete Allegro checkout." >&2
        return 1
      fi
    done < "${filelist}"
  done
  if ! command -v verilator >/dev/null 2>&1; then
    echo "ERROR: Verilator is required on the execution host." >&2
    return 1
  fi
}
