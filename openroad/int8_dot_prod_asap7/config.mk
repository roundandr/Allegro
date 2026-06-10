export PLATFORM        = asap7
export DESIGN_NAME     = int8_dot_prod
export DESIGN_NICKNAME = int8_dot_prod

export VERILOG_FILES = /work/src/main/utils/dot_prod_pkg.sv \
                       /work/src/main/utils/pipeline_reg.sv \
                       /work/src/main/int8_dot_prod.sv
export SDC_FILE      = /work/openroad/int8_dot_prod_asap7/constraint.sdc

# Native Yosys preserves the 9-bit INT8 operand multiply before techmapping.
export SYNTH_HDL_FRONTEND =

export CORE_UTILIZATION = 55
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 2
export PLACE_DENSITY = 0.45

export TNS_END_PERCENT = 100
export SKIP_LAST_GASP ?= 1
