set flow_home /OpenROAD-flow-scripts/flow
set run_home  /work/openroad/f4f6f8_dot_prod_asap7/run
set design_nickname f4f6f8_dot_prod

if {[info exists ::env(FLOW_VARIANT)] && $::env(FLOW_VARIANT) ne ""} {
    set flow_variant $::env(FLOW_VARIANT)
} else {
    set flow_variant base
}

if {[info exists ::env(ORFS_STAGE)] && $::env(ORFS_STAGE) ne ""} {
    set orfs_stage $::env(ORFS_STAGE)
} else {
    set orfs_stage 1_synth
}

set result_dir $run_home/results/asap7/$design_nickname/$flow_variant
set report_dir $run_home/reports/asap7/$design_nickname/$flow_variant

read_liberty $flow_home/platforms/asap7/lib/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.lib.gz
read_liberty $flow_home/platforms/asap7/lib/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib.gz
read_liberty $flow_home/platforms/asap7/lib/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.lib.gz
read_liberty $flow_home/platforms/asap7/lib/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib.gz
read_liberty $flow_home/platforms/asap7/lib/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib

read_db $result_dir/$orfs_stage.odb
if {[file exists $result_dir/$orfs_stage.sdc]} {
    read_sdc $result_dir/$orfs_stage.sdc
} elseif {[file exists $result_dir/3_place.sdc]} {
    read_sdc $result_dir/3_place.sdc
} elseif {[file exists $result_dir/2_floorplan.sdc]} {
    read_sdc $result_dir/2_floorplan.sdc
} else {
    read_sdc $result_dir/1_synth.sdc
}
source $flow_home/platforms/asap7/setRC.tcl

if {[string match "3_*" $orfs_stage] || [string match "4_*" $orfs_stage] || [string match "5_*" $orfs_stage]} {
    estimate_parasitics -placement
}

file mkdir $report_dir
if {[info exists ::env(WRITE_STAGE_NETLIST)] && $::env(WRITE_STAGE_NETLIST) ne "0"} {
    write_verilog $report_dir/$orfs_stage.v
}

set data_inputs [get_ports {a_vec_i b_vec_i c_i a_type_i b_type_i mxfp8_en_i a_mx_scale_i b_mx_scale_i}]

set s0_regs [get_cells *u_stage0_reg*out_data*]
set s1_regs [get_cells *u_stage1_reg*out_data*]
set s2_regs [get_cells *u_stage2_reg*out_data*]
set s3_regs [get_cells *u_stage3_reg*out_data*]
set s4_regs [get_cells *u_stage4_reg*out_data*]
set s5_regs [get_cells *u_stage5_reg*out_data*]
set d_ports [get_ports d_o*]

proc report_stage {stage_name stage_desc from_objs to_objs} {
    puts ""
    puts "================================================================================"
    puts "STAGE $stage_name : $stage_desc"
    puts "FROM_COUNT [llength $from_objs]"
    puts "TO_COUNT   [llength $to_objs]"
    puts "================================================================================"
    report_checks \
        -path_delay max \
        -fields {slew cap input fanout} \
        -from $from_objs \
        -to $to_objs \
        -group_path_count 1 \
        -endpoint_path_count 1
}

puts "Clock: 1000ps target, variant=$flow_variant, stage=$orfs_stage"
puts "Register counts:"
puts "  s0_regs [llength $s0_regs]"
puts "  s1_regs [llength $s1_regs]"
puts "  s2_regs [llength $s2_regs]"
puts "  s3_regs [llength $s3_regs]"
puts "  s4_regs [llength $s4_regs]"
puts "  s5_regs [llength $s5_regs]"

report_stage "S0" "input/decode/product/special -> u_stage0_reg" $data_inputs $s0_regs
report_stage "S1" "u_stage0_reg -> emax search -> u_stage1_reg" $s0_regs $s1_regs
report_stage "S2" "u_stage1_reg -> alignment/base_exp -> u_stage2_reg" $s1_regs $s2_regs
report_stage "S3" "u_stage2_reg -> 8+8+8+8+1 partial reduce -> u_stage3_reg" $s2_regs $s3_regs
report_stage "S4" "u_stage3_reg -> 5-term final reduce -> u_stage4_reg" $s3_regs $s4_regs
report_stage "S5" "u_stage4_reg -> FP32 pack -> u_stage5_reg" $s4_regs $s5_regs
report_stage "OUT" "u_stage5_reg -> d_o" $s5_regs $d_ports

puts ""
puts "================================================================================"
puts "READY PATH : out_rdy_i -> in_rdy_o"
puts "================================================================================"
report_checks \
    -path_delay max \
    -fields {slew cap input fanout} \
    -from [get_ports out_rdy_i] \
    -to [get_ports in_rdy_o] \
    -group_path_count 1 \
    -endpoint_path_count 1
