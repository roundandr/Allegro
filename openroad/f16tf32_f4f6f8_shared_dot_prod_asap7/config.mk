export PLATFORM        = asap7
export DESIGN_NAME     = f16tf32_f4f6f8_shared_dot_prod
export DESIGN_NICKNAME = f16tf32_f4f6f8_shared_dot_prod

export VERILOG_FILES = /work/src/main/utils/dot_prod_pkg.sv \
                       /work/src/main/utils/dot_fp32_rz_norm_pack.sv \
                       /work/src/main/utils/dot_signed_reduce_tree.sv \
                       /work/src/main/utils/dot_emax_tree.sv \
                       /work/src/main/utils/dot_align_fixed_rz.sv \
                       /work/src/main/utils/pipeline_reg.sv \
                       /work/src/main/f16tf32_s0_s2_frontend.sv \
                       /work/src/main/f4f6f8_s0_s2_frontend.sv \
                       /work/src/main/f16tf32_f4f6f8_shared_dot_prod.sv
export SDC_FILE      = /work/openroad/f16tf32_f4f6f8_shared_dot_prod_asap7/constraint.sdc

export SYNTH_HDL_FRONTEND = slang

export ADDER_MAP_FILE :=

export CORE_UTILIZATION = 55
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 2
export PLACE_DENSITY = 0.45

export TNS_END_PERCENT = 100
export SKIP_LAST_GASP ?= 1
