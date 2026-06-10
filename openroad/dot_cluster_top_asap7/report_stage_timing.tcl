source $::env(SCRIPTS_DIR)/load.tcl

load_design 1_2_yosys.v 1_synth.sdc

set report_file "$::env(REPORTS_DIR)/dot_cluster_stage_timing_post_synth.rpt"
set detail_dir  "$::env(OBJECTS_DIR)/dot_cluster_stage_timing_details"
file delete -force $detail_dir
file mkdir $detail_dir

proc cluster_obj_name {obj} {
  if {[catch {set name [get_full_name $obj]}]} {
    set name $obj
  }
  return $name
}

proc cluster_filter_registers {pattern} {
  set regs {}
  foreach reg [all_registers] {
    set name [cluster_obj_name $reg]
    if {[regexp $pattern $name]} {
      lappend regs $reg
    }
  }
  return $regs
}

proc cluster_filter_inputs {{exclude_reset 1}} {
  set ports {}
  foreach port [all_inputs -no_clocks] {
    set name [cluster_obj_name $port]
    if {$exclude_reset && $name == "rst_n"} {
      continue
    }
    lappend ports $port
  }
  return $ports
}

proc cluster_filter_outputs {{exclude_ready 0}} {
  set ports {}
  foreach port [all_outputs] {
    set name [cluster_obj_name $port]
    if {$exclude_ready && $name == "in_rdy_o"} {
      continue
    }
    lappend ports $port
  }
  return $ports
}

proc cluster_get_port_quiet {port_name} {
  set ports [get_ports -quiet $port_name]
  if {[llength $ports] == 0} {
    return {}
  }
  return $ports
}

proc cluster_parse_check_report {text} {
  set cur_startpoint "N/A"
  set cur_endpoint   "N/A"
  set cur_arrival    "N/A"
  set cur_required   "N/A"

  set best_startpoint "N/A"
  set best_endpoint   "N/A"
  set best_arrival    "N/A"
  set best_required   "N/A"
  set best_slack      "N/A"
  set best_status     "N/A"

  foreach line [split $text "\n"] {
    if {[regexp {^Startpoint:[ \t]+(.+)$} $line -> value]} {
      set cur_startpoint [string trim $value]
      set cur_endpoint   "N/A"
      set cur_arrival    "N/A"
      set cur_required   "N/A"
    }
    if {[regexp {^Endpoint:[ \t]+(.+)$} $line -> value]} {
      set cur_endpoint [string trim $value]
    }
    if {[regexp {^[ \t]*(-?[0-9]+(?:\.[0-9]+)?)[ \t]+data arrival time} $line -> arrival_value]} {
      if {double($arrival_value) >= 0.0} {
        set cur_arrival $arrival_value
      }
    }
    if {[regexp {^[ \t]*(-?[0-9]+(?:\.[0-9]+)?)[ \t]+data required time} $line -> required_value]} {
      set cur_required $required_value
    }
    if {[regexp {^[ \t]*(-?[0-9]+(?:\.[0-9]+)?)[ \t]+slack \((MET|VIOLATED)\)} $line -> slack_value status_value]} {
      if {$best_slack == "N/A" || double($slack_value) < double($best_slack)} {
        set best_startpoint $cur_startpoint
        set best_endpoint   $cur_endpoint
        set best_arrival    $cur_arrival
        set best_required   $cur_required
        set best_slack      $slack_value
        set best_status     $status_value
      }
    }
  }

  return [list $best_startpoint $best_endpoint $best_arrival $best_required $best_slack $best_status]
}

proc cluster_format_float {value digits} {
  if {$value == "N/A"} {
    return "N/A"
  }
  return [format "%.${digits}f" $value]
}

proc cluster_capture_report {command path} {
  file delete -force $path
  eval "$command > $path"
  set fd [open $path r]
  set text [string trim [read $fd]]
  close $fd
  return $text
}

proc cluster_report_stage {stage_name boundary from_objs to_objs target_period_ps detail_path} {
  if {[llength $from_objs] == 0 || [llength $to_objs] == 0} {
    return [list $stage_name $boundary "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"]
  }

  file delete -force $detail_path
  report_checks -path_delay max \
    -from $from_objs \
    -to $to_objs \
    -fields {slew cap input net fanout} \
    -format full_clock_expanded \
    -group_path_count 1 \
    -endpoint_path_count 1 > $detail_path

  set fd [open $detail_path r]
  set text [read $fd]
  close $fd

  if {[string first "Startpoint:" $text] < 0} {
    return [list $stage_name $boundary "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"]
  }

  lassign [cluster_parse_check_report $text] startpoint endpoint arrival required slack status
  if {$slack == "N/A"} {
    set min_period "N/A"
    set fmax_ghz   "N/A"
  } else {
    set min_period [expr {$target_period_ps - double($slack)}]
    if {$min_period <= 0.0} {
      set fmax_ghz "N/A"
    } else {
      set fmax_ghz [expr {1000.0 / $min_period}]
    }
  }

  return [list \
    $stage_name \
    $boundary \
    [cluster_format_float $arrival 2] \
    [cluster_format_float $required 2] \
    [cluster_format_float $slack 2] \
    [cluster_format_float $min_period 2] \
    [cluster_format_float $fmax_ghz 3] \
    $status \
    $startpoint \
    $endpoint]
}

proc cluster_append_stage {rows_var details_var stage_name boundary from_objs to_objs target_period_ps detail_dir detail_name} {
  upvar $rows_var rows
  upvar $details_var details
  set detail_path "$detail_dir/$detail_name.rpt"
  lappend rows [cluster_report_stage $stage_name $boundary $from_objs $to_objs $target_period_ps $detail_path]
  lappend details $detail_path
}

proc cluster_meta_regs {pipe stage_idx} {
  return [cluster_filter_registers "${pipe}.*gen_stage.*${stage_idx}.*u_meta_reg\\.out_(data|valid)"]
}

set target_period_ps 1000.0
set clock_file "$::env(RESULTS_DIR)/clock_period.txt"
if {[file exists $clock_file]} {
  set fd [open $clock_file r]
  set clock_text [string trim [read $fd]]
  close $fd
  if {[string is double -strict $clock_text]} {
    set target_period_ps [expr {double($clock_text)}]
  }
}

set all_nonclk_inputs [cluster_filter_inputs 1]
set data_outputs      [cluster_filter_outputs 1]
set ready_output      [cluster_get_port_quiet in_rdy_o]

set ingress_payload_regs [cluster_filter_registers {ingress_payload_q}]
set ingress_regs         [cluster_filter_registers {(ingress_payload_q|ingress_vld_q)}]
set issue_payload_regs   [cluster_filter_registers {issue_payload_q}]
set issue_regs           [cluster_filter_registers {(issue_payload_q|issue_vld_q)}]
set err_regs             [cluster_filter_registers {err_(vld|d|status|tag)_q}]
set share_regs           [cluster_filter_registers {(outstanding_q|active_share_group_q)}]

set f16tf32_s0 [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*u_f16tf32_s0_s2_frontend.*u_stage0_reg\.out_data}]
set f16tf32_s1 [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*u_f16tf32_s0_s2_frontend.*u_stage1_reg\.out_data}]
set f16tf32_s2 [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*u_f16tf32_s0_s2_frontend.*u_stage2_reg\.out_data}]

set f4f6f8_s0 [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*u_f4f6f8_s0_s2_frontend.*u_stage0_reg\.out_data}]
set f4f6f8_s1 [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*u_f4f6f8_s0_s2_frontend.*u_stage1_reg\.out_data}]
set f4f6f8_s2 [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*u_f4f6f8_s0_s2_frontend.*u_stage2_reg\.out_data}]

set shared_fp_s3  [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*u_stage3_reg\.out_data}]
set shared_fp_s4  [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*f4_s4_q}]
set shared_fp_out [cluster_filter_registers {u_f16tf32_f4f6f8_shared_dot_prod.*out_(vld|d|meta)_q}]

set int8_s0 [cluster_filter_registers {u_int8_dot_prod.*u_stage0_reg\.out_data}]
set int8_s1 [cluster_filter_registers {u_int8_dot_prod.*u_stage1_reg\.out_data}]
set int8_s3 [cluster_filter_registers {u_int8_dot_prod.*u_stage3_reg\.out_data}]
set int8_last [cluster_filter_registers {u_int8_dot_prod.*u_stage3_reg\.}]

set fp4_s0 [cluster_filter_registers {u_fp4_dot_prod.*u_stage0_reg\.out_data}]
set fp4_s1 [cluster_filter_registers {u_fp4_dot_prod.*u_stage1_reg\.out_data}]
set fp4_s2 [cluster_filter_registers {u_fp4_dot_prod.*u_stage2_reg\.out_data}]
set fp4_s3 [cluster_filter_registers {u_fp4_dot_prod.*u_stage3_reg\.out_data}]
set fp4_s4 [cluster_filter_registers {u_fp4_dot_prod.*u_stage4_reg\.out_data}]
set fp4_last [cluster_filter_registers {u_fp4_dot_prod.*u_stage4_reg\.}]

set int8_meta {}
set prev $issue_payload_regs
for {set i 0} {$i < 3} {incr i} {
  set cur [cluster_meta_regs {u_int8_meta_pipe} $i]
  lappend int8_meta [list $i $prev $cur]
  set prev $cur
}
set fp4_meta {}
set prev $issue_payload_regs
for {set i 0} {$i < 5} {incr i} {
  set cur [cluster_meta_regs {u_fp4_meta_pipe} $i]
  lappend fp4_meta [list $i $prev $cur]
  set prev $cur
}

set ready_from_objs {}
foreach obj [cluster_get_port_quiet out_rdy_i] {
  lappend ready_from_objs $obj
}
foreach reg [cluster_filter_registers {(ingress_vld_q|issue_vld_q|err_vld_q|outstanding_q|active_share_group_q|out_valid|u_stage[0-9]_reg\.out_valid)}] {
  lappend ready_from_objs $reg
}

set stage_rows {}
set detail_paths {}

cluster_append_stage stage_rows detail_paths \
  "TOP0 ingress capture" \
  "top inputs -> ingress_payload_q" \
  $all_nonclk_inputs $ingress_regs $target_period_ps $detail_dir "TOP0_inputs_to_ingress"

cluster_append_stage stage_rows detail_paths \
  "TOP1 sparse/dispatch issue" \
  "ingress_payload_q -> issue_payload_q" \
  $ingress_payload_regs $issue_payload_regs $target_period_ps $detail_dir "TOP1_ingress_to_issue"

cluster_append_stage stage_rows detail_paths \
  "TOP2 issue status counters" \
  "issue_payload_q/core_rsp -> outstanding/share regs" \
  $issue_regs $share_regs $target_period_ps $detail_dir "TOP2_issue_to_share_regs"

cluster_append_stage stage_rows detail_paths \
  "F16TF32 S0 issue/decode/product" \
  "issue_payload_q -> f16tf32 frontend stage0" \
  $issue_payload_regs $f16tf32_s0 $target_period_ps $detail_dir "F16TF32_S0_issue_to_stage0"
cluster_append_stage stage_rows detail_paths \
  "F16TF32 S1 emax" \
  "f16tf32 frontend stage0 -> stage1" \
  $f16tf32_s0 $f16tf32_s1 $target_period_ps $detail_dir "F16TF32_S1_stage0_to_stage1"
cluster_append_stage stage_rows detail_paths \
  "F16TF32 S2 align" \
  "f16tf32 frontend stage1 -> stage2" \
  $f16tf32_s1 $f16tf32_s2 $target_period_ps $detail_dir "F16TF32_S2_stage1_to_stage2"
cluster_append_stage stage_rows detail_paths \
  "F16TF32 shared S3 reduce/pack input" \
  "f16tf32 frontend stage2 -> shared stage3" \
  $f16tf32_s2 $shared_fp_s3 $target_period_ps $detail_dir "F16TF32_S3_stage2_to_shared_s3"
cluster_append_stage stage_rows detail_paths \
  "F16TF32 shared FP32 pack/output" \
  "shared stage3 -> shared output regs" \
  $shared_fp_s3 $shared_fp_out $target_period_ps $detail_dir "F16TF32_PACK_shared_s3_to_out"

cluster_append_stage stage_rows detail_paths \
  "F4F6F8 S0 issue/decode/product" \
  "issue_payload_q -> f4f6f8 frontend stage0" \
  $issue_payload_regs $f4f6f8_s0 $target_period_ps $detail_dir "F4F6F8_S0_issue_to_stage0"
cluster_append_stage stage_rows detail_paths \
  "F4F6F8 S1 emax" \
  "f4f6f8 frontend stage0 -> stage1" \
  $f4f6f8_s0 $f4f6f8_s1 $target_period_ps $detail_dir "F4F6F8_S1_stage0_to_stage1"
cluster_append_stage stage_rows detail_paths \
  "F4F6F8 S2 align" \
  "f4f6f8 frontend stage1 -> stage2" \
  $f4f6f8_s1 $f4f6f8_s2 $target_period_ps $detail_dir "F4F6F8_S2_stage1_to_stage2"
cluster_append_stage stage_rows detail_paths \
  "F4F6F8 shared S3 reduce" \
  "f4f6f8 frontend stage2 -> shared stage3" \
  $f4f6f8_s2 $shared_fp_s3 $target_period_ps $detail_dir "F4F6F8_S3_stage2_to_shared_s3"
cluster_append_stage stage_rows detail_paths \
  "F4F6F8 shared S4 final add" \
  "shared stage3 -> shared f4 stage4" \
  $shared_fp_s3 $shared_fp_s4 $target_period_ps $detail_dir "F4F6F8_S4_shared_s3_to_s4"
cluster_append_stage stage_rows detail_paths \
  "F4F6F8 shared FP32 pack/output" \
  "shared f4 stage4 -> shared output regs" \
  $shared_fp_s4 $shared_fp_out $target_period_ps $detail_dir "F4F6F8_PACK_s4_to_out"

cluster_append_stage stage_rows detail_paths \
  "INT8 S0 issue/product" \
  "issue_payload_q -> int8 u_stage0_reg" \
  $issue_payload_regs $int8_s0 $target_period_ps $detail_dir "INT8_S0_issue_to_stage0"
cluster_append_stage stage_rows detail_paths \
  "INT8 S1/S2 reduction" \
  "int8 stage0 -> stage1" \
  $int8_s0 $int8_s1 $target_period_ps $detail_dir "INT8_S1_stage0_to_stage1"
cluster_append_stage stage_rows detail_paths \
  "INT8 S3 add C/pack" \
  "int8 stage1 -> stage3" \
  $int8_s1 $int8_s3 $target_period_ps $detail_dir "INT8_S3_stage1_to_stage3"

cluster_append_stage stage_rows detail_paths \
  "FP4 S0 issue/decode/product" \
  "issue_payload_q -> fp4 u_stage0_reg" \
  $issue_payload_regs $fp4_s0 $target_period_ps $detail_dir "FP4_S0_issue_to_stage0"
cluster_append_stage stage_rows detail_paths \
  "FP4 S1 emax" \
  "fp4 stage0 -> stage1" \
  $fp4_s0 $fp4_s1 $target_period_ps $detail_dir "FP4_S1_stage0_to_stage1"
cluster_append_stage stage_rows detail_paths \
  "FP4 S2 align" \
  "fp4 stage1 -> stage2" \
  $fp4_s1 $fp4_s2 $target_period_ps $detail_dir "FP4_S2_stage1_to_stage2"
cluster_append_stage stage_rows detail_paths \
  "FP4 S3 accumulate" \
  "fp4 stage2 -> stage3" \
  $fp4_s2 $fp4_s3 $target_period_ps $detail_dir "FP4_S3_stage2_to_stage3"
cluster_append_stage stage_rows detail_paths \
  "FP4 S4 FP32 pack" \
  "fp4 stage3 -> stage4" \
  $fp4_s3 $fp4_s4 $target_period_ps $detail_dir "FP4_S4_stage3_to_stage4"

foreach item $int8_meta {
  lassign $item i from_objs to_objs
  cluster_append_stage stage_rows detail_paths \
    "INT8 META$i" \
    "int8 meta stage $i" \
    $from_objs $to_objs $target_period_ps $detail_dir "INT8_META${i}"
}
foreach item $fp4_meta {
  lassign $item i from_objs to_objs
  cluster_append_stage stage_rows detail_paths \
    "FP4 META$i" \
    "fp4 meta stage $i" \
    $from_objs $to_objs $target_period_ps $detail_dir "FP4_META${i}"
}

cluster_append_stage stage_rows detail_paths \
  "ERR response capture" \
  "issue_payload_q -> err_*_q" \
  $issue_payload_regs $err_regs $target_period_ps $detail_dir "ERR_issue_to_err_regs"
cluster_append_stage stage_rows detail_paths \
  "RSP shared FP output mux" \
  "shared FP output regs -> top outputs" \
  $shared_fp_out $data_outputs $target_period_ps $detail_dir "RSP_SHARED_FP_to_outputs"
cluster_append_stage stage_rows detail_paths \
  "RSP INT8 output mux" \
  "int8 last regs/meta -> top outputs" \
  [concat $int8_last [lindex [lindex $int8_meta 2] 2]] $data_outputs $target_period_ps $detail_dir "RSP_INT8_to_outputs"
cluster_append_stage stage_rows detail_paths \
  "RSP FP4 output mux" \
  "fp4 last regs/meta -> top outputs" \
  [concat $fp4_last [lindex [lindex $fp4_meta 4] 2]] $data_outputs $target_period_ps $detail_dir "RSP_FP4_to_outputs"
cluster_append_stage stage_rows detail_paths \
  "RSP ERR output mux" \
  "err regs -> top outputs" \
  $err_regs $data_outputs $target_period_ps $detail_dir "RSP_ERR_to_outputs"
cluster_append_stage stage_rows detail_paths \
  "READY/backpressure" \
  "out_rdy_i + valid regs -> in_rdy_o" \
  $ready_from_objs $ready_output $target_period_ps $detail_dir "READY_backpressure"

set min_slack "N/A"
set min_stage "N/A"
foreach row $stage_rows {
  set stage [lindex $row 0]
  set slack [lindex $row 4]
  if {$slack != "N/A"} {
    if {$min_slack == "N/A" || double($slack) < double($min_slack)} {
      set min_slack $slack
      set min_stage $stage
    }
  }
}

set wns_text [cluster_capture_report {report_wns -digits 2} "$::env(OBJECTS_DIR)/dot_cluster_report_wns.tmp"]
set tns_text [cluster_capture_report {report_tns -digits 2} "$::env(OBJECTS_DIR)/dot_cluster_report_tns.tmp"]
set min_period_text [cluster_capture_report {report_clock_min_period -digits 2} "$::env(OBJECTS_DIR)/dot_cluster_report_clock_min_period.tmp"]

set fd [open $report_file w]
puts $fd "dot_cluster_top post-synth stage timing"
puts $fd "Generated by OpenROAD on [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %Z}]"
puts $fd "Design: $::env(DESIGN_NAME)"
puts $fd "Target period: [format %.2f $target_period_ps] ps"
puts $fd "Netlist: $::env(RESULTS_DIR)/1_2_yosys.v"
puts $fd "SDC: $::env(RESULTS_DIR)/1_synth.sdc"
puts $fd ""
puts $fd "Global timing summary:"
puts $fd "  report_wns: $wns_text"
puts $fd "  report_tns: $tns_text"
puts $fd "  report_clock_min_period: $min_period_text"
puts $fd ""
puts $fd "Per-stage setup timing. Delay is reported data arrival on the worst max path for the named boundary."
puts $fd ""
puts $fd [format "%-32s | %-46s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
  "Stage" "Boundary" "Delay(ps)" "Required(ps)" "Slack(ps)" "MinPeriod(ps)" "Fmax(GHz)" "Status" "Startpoint" "Endpoint"]
puts $fd [string repeat "-" 300]
foreach row $stage_rows {
  puts $fd [format "%-32s | %-46s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
    [lindex $row 0] [lindex $row 1] [lindex $row 2] [lindex $row 3] [lindex $row 4] \
    [lindex $row 5] [lindex $row 6] [lindex $row 7] [lindex $row 8] [lindex $row 9]]
}
puts $fd ""
puts $fd "Worst stage slack: $min_slack ps ($min_stage)"
puts $fd ""
puts $fd "Matched object counts:"
foreach count_row [list \
  [list all_nonclk_inputs $all_nonclk_inputs] \
  [list data_outputs $data_outputs] \
  [list ingress_payload_regs $ingress_payload_regs] \
  [list ingress_regs $ingress_regs] \
  [list issue_payload_regs $issue_payload_regs] \
  [list issue_regs $issue_regs] \
  [list share_regs $share_regs] \
  [list err_regs $err_regs] \
  [list f16tf32_s0 $f16tf32_s0] [list f16tf32_s1 $f16tf32_s1] [list f16tf32_s2 $f16tf32_s2] \
  [list f4f6f8_s0 $f4f6f8_s0] [list f4f6f8_s1 $f4f6f8_s1] [list f4f6f8_s2 $f4f6f8_s2] \
  [list shared_fp_s3 $shared_fp_s3] [list shared_fp_s4 $shared_fp_s4] [list shared_fp_out $shared_fp_out] \
  [list int8_s0 $int8_s0] [list int8_s1 $int8_s1] [list int8_s3 $int8_s3] \
  [list fp4_s0 $fp4_s0] [list fp4_s1 $fp4_s1] [list fp4_s2 $fp4_s2] [list fp4_s3 $fp4_s3] [list fp4_s4 $fp4_s4] \
  [list ready_from_objs $ready_from_objs] [list ready_output $ready_output] \
] {
  puts $fd [format "  %-24s %6d" [lindex $count_row 0] [llength [lindex $count_row 1]]]
}
foreach pipe_row [list \
  [list int8_meta $int8_meta] \
  [list fp4_meta $fp4_meta] \
] {
  set pipe_name [lindex $pipe_row 0]
  foreach item [lindex $pipe_row 1] {
    lassign $item i from_objs to_objs
    puts $fd [format "  %-24s %6d" "${pipe_name}${i}_regs" [llength $to_objs]]
  }
}
puts $fd ""
puts $fd "Detailed timing paths:"
foreach detail_path $detail_paths {
  puts $fd "  $detail_path"
}
close $fd

puts "Wrote $report_file"
