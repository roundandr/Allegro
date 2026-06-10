set sdc_version 2.0

set clk_name clk
set clk_period 1000

create_clock -period $clk_period -waveform [list 0 [expr {$clk_period / 2}]] -name $clk_name

set data_inputs [all_inputs]
set data_outputs [all_outputs]

set_max_delay $clk_period -from $data_inputs -to $data_outputs

group_path -name in2out -from $data_inputs -to $data_outputs
