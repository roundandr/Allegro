include /work/openroad/dot_cluster_top_asap7/config.mk

# The full dot_cluster_top contains all dot-product add trees. ORFS' ASAP7
# adder extraction can dominate runtime on this top, so this analysis variant
# skips the optional full-adder mapping pass and keeps the rest of the ASAP7
# synthesis/STA flow unchanged.
export ADDER_MAP_FILE :=
