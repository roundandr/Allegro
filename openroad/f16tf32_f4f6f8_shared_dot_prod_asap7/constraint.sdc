set sdc_version 2.0

set clk_name clk
set clk_port_name clk
set clk_period 1000

set clk_port [get_ports $clk_port_name]
create_clock -period $clk_period -waveform [list 0 [expr {$clk_period / 2}]] -name $clk_name $clk_port

set_false_path -from [get_ports rst_n]

set non_clk_inputs [lsearch -inline -all -not -exact [all_inputs -no_clocks] [get_ports rst_n]]

set_max_delay -ignore_clock_latency $clk_period -from $non_clk_inputs -to [all_registers]
set_max_delay -ignore_clock_latency $clk_period -from [all_registers] -to [all_outputs]
set_max_delay $clk_period -from $non_clk_inputs -to [all_outputs]

group_path -name in2reg -from $non_clk_inputs -to [all_registers]
group_path -name reg2reg -from [all_registers] -to [all_registers]
group_path -name reg2out -from [all_registers] -to [all_outputs]
group_path -name in2out -from $non_clk_inputs -to [all_outputs]
