#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

missing=0
for tool in yosys yosys-abc sv2v python3; do
    if command -v "${tool}" >/dev/null 2>&1; then
        printf '%-10s %s\n' "${tool}" "$(command -v "${tool}")"
    else
        printf '%-10s MISSING\n' "${tool}"
        missing=1
    fi
done

if command -v yosys >/dev/null 2>&1; then
    yosys -V
fi

if command -v sv2v >/dev/null 2>&1; then
    sv2v --version
fi

exit "${missing}"
