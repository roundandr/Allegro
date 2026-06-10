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

puts "================================================================================"
puts "CHECK TYPES variant=$flow_variant stage=$orfs_stage"
puts "================================================================================"
report_check_types -max_slew -max_capacitance -max_fanout -violators -max_count 80
