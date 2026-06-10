export PLATFORM        = asap7
export DESIGN_NAME     = dot_fp32_rz_norm_pack
export DESIGN_NICKNAME = dot_fp32_rz_norm_pack

export VERILOG_FILES = /work/src/main/utils/dot_prod_pkg.sv \
                       /work/src/main/utils/dot_fp32_rz_norm_pack.sv
export SDC_FILE      = /work/openroad/dot_fp32_rz_norm_pack_asap7/constraint.sdc

export SYNTH_HDL_FRONTEND = slang

# The packer contains add/negate/shift/priority-encode logic. Skip optional
# full-adder extraction so this standalone timing experiment stays quick.
export ADDER_MAP_FILE :=

export CORE_UTILIZATION = 55
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 2
export PLACE_DENSITY = 0.45

export TNS_END_PERCENT = 100
export SKIP_LAST_GASP ?= 1
