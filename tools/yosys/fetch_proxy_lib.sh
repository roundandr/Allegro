#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

CACHE_DIR="${ALLEGRO_PDK_CACHE:-${HOME}/.cache/allegro-pdk}"
ASAP7_TAG="${ASAP7_TAG:-v0.2.9}"
ASAP7_ARCHIVE="${CACHE_DIR}/lambdapdk-${ASAP7_TAG}.tar.gz"
ASAP7_DIR="${CACHE_DIR}/lambdapdk-${ASAP7_TAG#v}"
ASAP7_MERGED_LIB="${CACHE_DIR}/asap7sc7p5t_rvt_tt_merged.lib"
NANGATE_LIB="${CACHE_DIR}/NangateOpenCellLibrary_typical.lib"
PROXY_LIB="${PROXY_LIB:-auto}"

mkdir -p "${CACHE_DIR}"

ensure_lambdapdk() {
    if [[ ! -s "${ASAP7_ARCHIVE}" ]]; then
        curl -L \
            "https://github.com/siliconcompiler/lambdapdk/archive/refs/tags/${ASAP7_TAG}.tar.gz" \
            -o "${ASAP7_ARCHIVE}"
    fi

    if [[ ! -d "${ASAP7_DIR}" ]]; then
        tar -xzf "${ASAP7_ARCHIVE}" -C "${CACHE_DIR}"
    fi
}

emit_nangate() {
    local bundled_nangate
    bundled_nangate="${ASAP7_DIR}/lambdapdk/freepdk45/libs/nangate45/nldm/NangateOpenCellLibrary_typical.lib"

    ensure_lambdapdk

    if [[ -s "${bundled_nangate}" ]]; then
        printf '%s\n' "${bundled_nangate}"
        exit 0
    fi

    if [[ -s "${NANGATE_LIB}" ]]; then
        printf '%s\n' "${NANGATE_LIB}"
        exit 0
    fi

    curl -k -L \
        "https://raw.githubusercontent.com/The-OpenROAD-Project/alpha-release/master/flow/platforms/nangate45/NangateOpenCellLibrary_typical.lib" \
        -o "${NANGATE_LIB}"

    printf '%s\n' "${NANGATE_LIB}"
    exit 0
}

if [[ "${PROXY_LIB}" == "nangate45" || "${PROXY_LIB}" == "nangate" ]]; then
    emit_nangate
fi

if [[ ! -s "${ASAP7_MERGED_LIB}" ]]; then
    ensure_lambdapdk

    asap7_libs=()
    while IFS= read -r lib; do
        asap7_libs+=("${lib}")
    done < <(
        find "${ASAP7_DIR}" -type f \
            -path '*/asap7/libs/asap7sc7p5t_rvt/nldm/*RVT_TT_nldm.lib.gz' | sort
    )

    if (( ${#asap7_libs[@]} > 0 )); then
        : > "${ASAP7_MERGED_LIB}"
        for lib in "${asap7_libs[@]}"; do
            gzip -cd "${lib}" >> "${ASAP7_MERGED_LIB}"
            printf '\n' >> "${ASAP7_MERGED_LIB}"
        done
        printf '%s\n' "${ASAP7_MERGED_LIB}"
        exit 0
    fi
fi

if [[ -s "${ASAP7_MERGED_LIB}" ]]; then
    printf '%s\n' "${ASAP7_MERGED_LIB}"
    exit 0
fi

if [[ "${PROXY_LIB}" == "asap7" ]]; then
    printf 'ASAP7 liberty not found under %s\n' "${ASAP7_DIR}" >&2
    exit 1
fi

emit_nangate
