export PLATFORM        = asap7
export DESIGN_NAME     = shared_accum33_tree
export DESIGN_NICKNAME = shared_accum33_tree

export VERILOG_FILES = /work/src/main/utils/dot_signed_reduce_tree.sv \
                       /work/src/main/shared_accum33_tree.sv
export SDC_FILE      = /work/openroad/shared_accum33_tree_asap7/constraint.sdc

export SYNTH_HDL_FRONTEND = slang

# Skip optional full-adder extraction for this timing experiment. On these
# add-heavy blocks it can dominate runtime without changing the question being
# measured here: stage boundary timing after generic ASAP7 synthesis.
export ADDER_MAP_FILE :=

export CORE_UTILIZATION = 55
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 2
export PLACE_DENSITY = 0.45

export TNS_END_PERCENT = 100
export SKIP_LAST_GASP ?= 1
