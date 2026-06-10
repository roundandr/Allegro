source $::env(SCRIPTS_DIR)/load.tcl

load_design 1_2_yosys.v 1_synth.sdc

set report_file "$::env(REPORTS_DIR)/dot_fp32_rz_norm_pack_timing_post_synth.rpt"
set detail_dir  "$::env(OBJECTS_DIR)/dot_fp32_rz_norm_pack_timing_details"
file delete -force $detail_dir
file mkdir $detail_dir

proc pack_obj_name {obj} {
  if {[catch {set name [get_full_name $obj]}]} {
    set name $obj
  }
  return $name
}

proc pack_filter_ports {ports pattern} {
  set matched {}
  foreach port $ports {
    set name [pack_obj_name $port]
    if {[regexp $pattern $name]} {
      lappend matched $port
    }
  }
  return $matched
}

proc pack_parse_check_report {text} {
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

proc pack_format_float {value digits} {
  if {$value == "N/A"} {
    return "N/A"
  }
  return [format "%.${digits}f" $value]
}

proc pack_capture_report {command path} {
  file delete -force $path
  eval "$command > $path"
  set fd [open $path r]
  set text [string trim [read $fd]]
  close $fd
  return $text
}

proc pack_report_stage {stage_name boundary from_objs to_objs target_period_ps detail_path} {
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

  lassign [pack_parse_check_report $text] startpoint endpoint arrival required slack status
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
    [pack_format_float $arrival 2] \
    [pack_format_float $required 2] \
    [pack_format_float $slack 2] \
    [pack_format_float $min_period 2] \
    [pack_format_float $fmax_ghz 3] \
    $status \
    $startpoint \
    $endpoint]
}

proc pack_append_stage {rows_var details_var stage_name boundary from_objs to_objs target_period_ps detail_dir detail_name} {
  upvar $rows_var rows
  upvar $details_var details
  set detail_path "$detail_dir/$detail_name.rpt"
  lappend rows [pack_report_stage $stage_name $boundary $from_objs $to_objs $target_period_ps $detail_path]
  lappend details $detail_path
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

set all_inputs      [all_inputs]
set all_outputs     [all_outputs]
set sum_inputs      [pack_filter_ports $all_inputs {sum_i}]
set exp_inputs      [pack_filter_ports $all_inputs {base_exp_i}]
set special_inputs  [pack_filter_ports $all_inputs {special_}]
set result_outputs  [pack_filter_ports $all_outputs {result_o}]

set stage_rows {}
set detail_paths {}

pack_append_stage stage_rows detail_paths \
  "ALL input-to-output" \
  "all inputs -> result_o" \
  $all_inputs $result_outputs $target_period_ps $detail_dir "ALL_inputs_to_result"

pack_append_stage stage_rows detail_paths \
  "SUM normalize/pack" \
  "sum_i -> result_o" \
  $sum_inputs $result_outputs $target_period_ps $detail_dir "SUM_to_result"

pack_append_stage stage_rows detail_paths \
  "EXP pack" \
  "base_exp_i -> result_o" \
  $exp_inputs $result_outputs $target_period_ps $detail_dir "EXP_to_result"

pack_append_stage stage_rows detail_paths \
  "SPECIAL bypass" \
  "special inputs -> result_o" \
  $special_inputs $result_outputs $target_period_ps $detail_dir "SPECIAL_to_result"

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

set wns_text [pack_capture_report {report_wns -digits 2} "$::env(OBJECTS_DIR)/dot_fp32_rz_norm_pack_report_wns.tmp"]
set tns_text [pack_capture_report {report_tns -digits 2} "$::env(OBJECTS_DIR)/dot_fp32_rz_norm_pack_report_tns.tmp"]

set fd [open $report_file w]
puts $fd "dot_fp32_rz_norm_pack post-synth timing"
puts $fd "Generated by OpenROAD on [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %Z}]"
puts $fd "Design: $::env(DESIGN_NAME)"
puts $fd "Target input-output delay: [format %.2f $target_period_ps] ps"
puts $fd "Netlist: $::env(RESULTS_DIR)/1_2_yosys.v"
puts $fd "SDC: $::env(RESULTS_DIR)/1_synth.sdc"
puts $fd ""
puts $fd "Global timing summary:"
puts $fd "  report_wns: $wns_text"
puts $fd "  report_tns: $tns_text"
puts $fd ""
puts $fd "Per-boundary setup timing. Delay is data arrival on the worst max path for the named boundary."
puts $fd ""
puts $fd [format "%-24s | %-30s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
  "Boundary" "Path" "Delay(ps)" "Required(ps)" "Slack(ps)" "MinDelay(ps)" "Fmax(GHz)" "Status" "Startpoint" "Endpoint"]
puts $fd [string repeat "-" 245]
foreach row $stage_rows {
  puts $fd [format "%-24s | %-30s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
    [lindex $row 0] [lindex $row 1] [lindex $row 2] [lindex $row 3] [lindex $row 4] \
    [lindex $row 5] [lindex $row 6] [lindex $row 7] [lindex $row 8] [lindex $row 9]]
}
puts $fd ""
puts $fd "Worst boundary slack: $min_slack ps ($min_stage)"
puts $fd ""
puts $fd "Matched object counts:"
foreach count_row [list \
  [list all_inputs $all_inputs] \
  [list all_outputs $all_outputs] \
  [list sum_inputs $sum_inputs] \
  [list exp_inputs $exp_inputs] \
  [list special_inputs $special_inputs] \
  [list result_outputs $result_outputs] \
] {
  puts $fd [format "  %-18s %6d" [lindex $count_row 0] [llength [lindex $count_row 1]]]
}
puts $fd ""
puts $fd "Detailed timing paths:"
foreach detail_path $detail_paths {
  puts $fd "  $detail_path"
}
close $fd

puts "Wrote $report_file"
