# ASIC-proxy timing constraints for dot_cluster_top.
# This is a relative RTL optimization proxy, not signoff.

set CLOCK_PERIOD_NS 0.667
create_clock -name clk -period $CLOCK_PERIOD_NS [get_ports clk]

set INPUT_DELAY_NS  [expr {$CLOCK_PERIOD_NS * 0.20}]
set OUTPUT_DELAY_NS [expr {$CLOCK_PERIOD_NS * 0.20}]

set_input_delay  $INPUT_DELAY_NS  -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay $OUTPUT_DELAY_NS -clock clk [all_outputs]
