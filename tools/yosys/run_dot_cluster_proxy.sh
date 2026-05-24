#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TOP="${TOP:-dot_cluster_top}"
TARGET_NS="${TARGET_NS:-0.667}"
REPORT_ROOT="${REPORT_ROOT:-${REPO_ROOT}/reports/yosys_proxy}"
REPORT_DIR="${REPORT_DIR:-${REPORT_ROOT}/${TOP}_${TARGET_NS}ns}"
LIBERTY_PATH="${LIBERTY_PATH:-}"
PROXY_LIB="${PROXY_LIB:-auto}"
ABC_PROBE="${ABC_PROBE:-1}"
ABC_CONSTR_PATH="${ABC_CONSTR_PATH:-}"
SV2V_OUT="${REPORT_DIR}/${TOP}.sv2v.v"
YOSYS_LOG="${REPORT_DIR}/${TOP}.yosys.log"
YOSYS_RPT="${REPORT_DIR}/${TOP}.stat.rpt"
TIMING_RPT="${REPORT_DIR}/${TOP}.timing.rpt"

mkdir -p "${REPORT_DIR}"

detect_lib_family() {
    local lib_path
    lib_path="$1"

    case "${lib_path}" in
        *asap7*|*ASAP7*)
            printf 'asap7\n'
            ;;
        *Nangate*|*nangate*|*freepdk45*)
            printf 'nangate45\n'
            ;;
        *)
            printf 'custom\n'
            ;;
    esac
}

fetch_proxy_lib() {
    local lib_kind
    lib_kind="$1"

    PROXY_LIB="${lib_kind}" "${SCRIPT_DIR}/fetch_proxy_lib.sh"
}

abc_liberty_probe() {
    local lib_path
    local probe_dir
    local probe_v
    local probe_log

    lib_path="$1"
    probe_dir="${REPORT_DIR}/.abc_probe"
    probe_v="${probe_dir}/abc_probe.v"
    probe_log="${probe_dir}/abc_probe.yosys.log"

    mkdir -p "${probe_dir}"
    printf 'module abc_probe(input a, input b, output y); assign y = a & b; endmodule\n' > "${probe_v}"

    yosys -q -l "${probe_log}" -p "
        read_verilog ${probe_v}
        hierarchy -check -top abc_probe
        proc; opt; techmap; opt
        abc -liberty ${lib_path} -D 1000
        clean
    " >/dev/null 2>&1
}

USE_GENERIC=0
LIBERTY_FAMILY="custom"
FALLBACK_REASON=""

if [[ "${LIBERTY_PATH}" == "generic" || "${LIBERTY_PATH}" == "none" ||
      "${PROXY_LIB}" == "generic" || "${PROXY_LIB}" == "none" ]]; then
    USE_GENERIC=1
    LIBERTY_PATH=""
    LIBERTY_FAMILY="generic"
fi

if [[ -z "${LIBERTY_PATH}" && "${USE_GENERIC}" -eq 0 ]]; then
    if [[ -x "${SCRIPT_DIR}/fetch_proxy_lib.sh" ]]; then
        LIBERTY_PATH="$(fetch_proxy_lib "${PROXY_LIB}")"
    fi
fi

if [[ -n "${LIBERTY_PATH}" && -s "${LIBERTY_PATH}" ]]; then
    LIBERTY_FAMILY="$(detect_lib_family "${LIBERTY_PATH}")"

    if [[ "${ABC_PROBE}" != "0" ]]; then
        if ! abc_liberty_probe "${LIBERTY_PATH}"; then
            if [[ "${PROXY_LIB}" == "auto" && "${LIBERTY_FAMILY}" == "asap7" ]]; then
                FALLBACK_REASON="ASAP7 liberty fails yosys-abc sanity probe; using Nangate45 for stable relative timing."
                LIBERTY_PATH="$(fetch_proxy_lib "nangate45")"
                LIBERTY_FAMILY="$(detect_lib_family "${LIBERTY_PATH}")"
                abc_liberty_probe "${LIBERTY_PATH}"
            else
                printf 'ERROR: liberty failed yosys-abc sanity probe: %s\n' "${LIBERTY_PATH}" >&2
                printf '       Use PROXY_LIB=auto/nangate45, LIBERTY_PATH=generic, or ABC_PROBE=0 to bypass the probe.\n' >&2
                exit 1
            fi
        fi
    fi
fi

target_ps="$(python3 - <<PY
print(int(round(float("${TARGET_NS}") * 1000.0)))
PY
)"

rtl_files=(
    "${REPO_ROOT}/src/main/tcgen05_mma_pkg.sv"
    "${REPO_ROOT}/src/main/pipeline_reg.sv"
    "${REPO_ROOT}/src/main/mid_fp_dot_prod.sv"
    "${REPO_ROOT}/src/main/f4f6f8_dot_prod.sv"
    "${REPO_ROOT}/src/main/int8_dot_prod.sv"
    "${REPO_ROOT}/src/main/fp4_dot_prod.sv"
    "${REPO_ROOT}/src/main/dot_cluster_top.sv"
)

sv2v "${rtl_files[@]}" > "${SV2V_OUT}"

if [[ -n "${LIBERTY_PATH}" && -s "${LIBERTY_PATH}" ]]; then
    ABC_ARGS="-liberty ${LIBERTY_PATH} -D ${target_ps}"
    if [[ -z "${ABC_CONSTR_PATH}" && "${LIBERTY_FAMILY}" == "nangate45" ]]; then
        ABC_CONSTR_PATH="${REPORT_DIR}/abc.constr"
        printf 'set_driving_cell INV_X1\nset_load 10.0\n' > "${ABC_CONSTR_PATH}"
    elif [[ -z "${ABC_CONSTR_PATH}" && "${LIBERTY_FAMILY}" == "asap7" ]]; then
        ABC_CONSTR_PATH="${REPORT_DIR}/abc.constr"
        printf 'set_driving_cell BUFx2_ASAP7_75t_R\nset_load 10.0\n' > "${ABC_CONSTR_PATH}"
    fi

    if [[ -n "${ABC_CONSTR_PATH}" && -s "${ABC_CONSTR_PATH}" ]]; then
        ABC_ARGS="-liberty ${LIBERTY_PATH} -constr ${ABC_CONSTR_PATH} -D ${target_ps}"
    fi

    yosys -q -l "${YOSYS_LOG}" -p "
        read_verilog ${SV2V_OUT}
        hierarchy -check -top ${TOP}
        proc; opt; fsm; opt; memory; opt
        async2sync; opt
        techmap; opt
        abc ${ABC_ARGS}
        clean
        tee -o ${YOSYS_RPT} stat -liberty ${LIBERTY_PATH}
    "

    awk '
        /Extracting gate netlist of module/ {
            module_name = $0
            sub(/^.*module `/, "", module_name)
            sub(/\047 to .*$/, "", module_name)
        }
        /ABC: WireLoad/ && /Delay =/ {
            delay = $0
            area = $0
            gates = $0
            sub(/^.*Delay = */, "", delay)
            sub(/ ps.*$/, "", delay)
            sub(/^.*Area = */, "", area)
            sub(/ *\(.*/, "", area)
            sub(/^.*Gates = */, "", gates)
            sub(/ *\(.*/, "", gates)
            printf "%s delay_ps=%s area=%s gates=%s\n", module_name, delay, area, gates
        }
    ' "${YOSYS_LOG}" > "${TIMING_RPT}" || true
else
    yosys -q -l "${YOSYS_LOG}" -p "
        read_verilog ${SV2V_OUT}
        hierarchy -check -top ${TOP}
        async2sync
        synth -top ${TOP}
        abc -D ${target_ps}
        clean
        tee -o ${YOSYS_RPT} stat
    "
fi

printf 'report_dir=%s\n' "${REPORT_DIR}"
printf 'liberty=%s\n' "${LIBERTY_PATH:-generic}"
printf 'proxy_lib=%s\n' "${LIBERTY_FAMILY:-generic}"
if [[ -n "${FALLBACK_REASON}" ]]; then
    printf 'fallback=%s\n' "${FALLBACK_REASON}"
fi
if [[ -s "${TIMING_RPT}" ]]; then
    printf 'timing_report=%s\n' "${TIMING_RPT}"
fi
printf 'target_ns=%s\n' "${TARGET_NS}"
