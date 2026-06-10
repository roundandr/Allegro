source $::env(SCRIPTS_DIR)/load.tcl

load_design 1_2_yosys.v 1_synth.sdc

set report_file "$::env(REPORTS_DIR)/shared_accum33_stage_timing_post_synth.rpt"
set detail_dir  "$::env(OBJECTS_DIR)/shared_accum33_stage_timing_details"
file delete -force $detail_dir
file mkdir $detail_dir

proc tree_obj_name {obj} {
  if {[catch {set name [get_full_name $obj]}]} {
    set name $obj
  }
  return $name
}

proc tree_filter_registers {pattern} {
  set regs {}
  foreach reg [all_registers] {
    set name [tree_obj_name $reg]
    if {[regexp $pattern $name]} {
      lappend regs $reg
    }
  }
  return $regs
}

proc tree_filter_ports {ports pattern} {
  set matched {}
  foreach port $ports {
    set name [tree_obj_name $port]
    if {[regexp $pattern $name]} {
      lappend matched $port
    }
  }
  return $matched
}

proc tree_filter_inputs {{exclude_reset 1}} {
  set ports {}
  foreach port [all_inputs -no_clocks] {
    set name [tree_obj_name $port]
    if {$exclude_reset && $name == "rst_n"} {
      continue
    }
    lappend ports $port
  }
  return $ports
}

proc tree_get_port_quiet {port_name} {
  set ports [get_ports -quiet $port_name]
  if {[llength $ports] == 0} {
    return {}
  }
  return $ports
}

proc tree_parse_check_report {text} {
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

proc tree_format_float {value digits} {
  if {$value == "N/A"} {
    return "N/A"
  }
  return [format "%.${digits}f" $value]
}

proc tree_capture_report {command path} {
  file delete -force $path
  eval "$command > $path"
  set fd [open $path r]
  set text [string trim [read $fd]]
  close $fd
  return $text
}

proc tree_report_stage {stage_name boundary from_objs to_objs target_period_ps detail_path} {
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

  lassign [tree_parse_check_report $text] startpoint endpoint arrival required slack status
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
    [tree_format_float $arrival 2] \
    [tree_format_float $required 2] \
    [tree_format_float $slack 2] \
    [tree_format_float $min_period 2] \
    [tree_format_float $fmax_ghz 3] \
    $status \
    $startpoint \
    $endpoint]
}

proc tree_append_stage {rows_var details_var stage_name boundary from_objs to_objs target_period_ps detail_dir detail_name} {
  upvar $rows_var rows
  upvar $details_var details
  set detail_path "$detail_dir/$detail_name.rpt"
  lappend rows [tree_report_stage $stage_name $boundary $from_objs $to_objs $target_period_ps $detail_path]
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

set all_nonclk_inputs [tree_filter_inputs 1]
set req_inputs        [tree_filter_ports $all_nonclk_inputs {(in_vld_i|mode_i|term_flat_i|meta_i)}]
set ready_inputs      [tree_filter_ports $all_nonclk_inputs {(f16tf32_out_rdy_i|f4f6f8_out_rdy_i)}]
set f16tf32_outputs       [tree_filter_ports [all_outputs] {f16tf32_}]
set f4_outputs        [tree_filter_ports [all_outputs] {f4f6f8_}]
set ready_output      [tree_get_port_quiet in_rdy_o]

set s0_regs           [tree_filter_registers {s0_.*_q}]
set s0_data_regs      [tree_filter_registers {s0_(mode|sum_lo|sum_hi|f16tf32_sum_sign|f16tf32_sum_abs|meta)_q}]
set s0_valid_regs     [tree_filter_registers {s0_vld_q}]
set s1_regs           [tree_filter_registers {s1_.*_q}]
set s1_data_regs      [tree_filter_registers {s1_(sum|meta)_q}]
set s1_valid_regs     [tree_filter_registers {s1_vld_q}]
set f16tf32_stage_regs    [tree_filter_registers {f16tf32_(sum_abs_o|meta_o)}]
set f4_stage_regs     [tree_filter_registers {f4f6f8_(sum_o|meta_o|out_vld_o)}]
set f4_sum_regs       [tree_filter_registers {f4f6f8_sum_o}]
set stage_a_regs      [concat $s0_regs $f16tf32_stage_regs]
set stage_b_regs      [concat $s1_regs $f4_stage_regs]
set stage_b_data_regs [concat $s1_data_regs $f4_sum_regs]

set ready_from_objs {}
foreach obj $ready_inputs {
  lappend ready_from_objs $obj
}
foreach reg [concat $s0_valid_regs $s1_valid_regs] {
  lappend ready_from_objs $reg
}
foreach reg [tree_filter_registers {f4f6f8_out_vld_o}] {
  lappend ready_from_objs $reg
}

set stage_rows {}
set detail_paths {}

tree_append_stage stage_rows detail_paths \
  "S0 17/16-term reduce" \
  "top inputs -> s0 regs" \
  $req_inputs $stage_a_regs $target_period_ps $detail_dir "S0_inputs_to_stageA"

tree_append_stage stage_rows detail_paths \
  "S1 2-term final add" \
  "s0 sum_lo/sum_hi -> s1 regs" \
  $s0_data_regs $stage_b_data_regs $target_period_ps $detail_dir "S1_stageA_to_stageB"

tree_append_stage stage_rows detail_paths \
  "F16TF32 output tap" \
  "s0 regs -> F16TF32 outputs" \
  $s0_regs $f16tf32_outputs $target_period_ps $detail_dir "F16TF32_stageA_to_outputs"

tree_append_stage stage_rows detail_paths \
  "F4F6F8 output" \
  "s1 regs -> F4F6F8 outputs" \
  $stage_b_regs $f4_outputs $target_period_ps $detail_dir "F4F6F8_stageB_to_outputs"

tree_append_stage stage_rows detail_paths \
  "READY/backpressure" \
  "output ready + valid regs -> in_rdy_o" \
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

set wns_text [tree_capture_report {report_wns -digits 2} "$::env(OBJECTS_DIR)/shared_accum33_report_wns.tmp"]
set tns_text [tree_capture_report {report_tns -digits 2} "$::env(OBJECTS_DIR)/shared_accum33_report_tns.tmp"]
set min_period_text [tree_capture_report {report_clock_min_period -digits 2} "$::env(OBJECTS_DIR)/shared_accum33_report_clock_min_period.tmp"]

set fd [open $report_file w]
puts $fd "shared_accum33_tree post-synth stage timing"
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
puts $fd "Per-stage setup timing. Delay is data arrival on the worst max path for the named boundary."
puts $fd ""
puts $fd [format "%-24s | %-38s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
  "Stage" "Boundary" "Delay(ps)" "Required(ps)" "Slack(ps)" "MinPeriod(ps)" "Fmax(GHz)" "Status" "Startpoint" "Endpoint"]
puts $fd [string repeat "-" 260]
foreach row $stage_rows {
  puts $fd [format "%-24s | %-38s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
    [lindex $row 0] [lindex $row 1] [lindex $row 2] [lindex $row 3] [lindex $row 4] \
    [lindex $row 5] [lindex $row 6] [lindex $row 7] [lindex $row 8] [lindex $row 9]]
}
puts $fd ""
puts $fd "Worst stage slack: $min_slack ps ($min_stage)"
puts $fd ""
puts $fd "Matched object counts:"
foreach count_row [list \
  [list all_nonclk_inputs $all_nonclk_inputs] \
  [list req_inputs $req_inputs] \
  [list ready_inputs $ready_inputs] \
  [list f16tf32_outputs $f16tf32_outputs] \
  [list f4_outputs $f4_outputs] \
  [list ready_output $ready_output] \
  [list s0_regs $s0_regs] \
  [list s0_data_regs $s0_data_regs] \
  [list s0_valid_regs $s0_valid_regs] \
  [list s1_regs $s1_regs] \
  [list s1_data_regs $s1_data_regs] \
  [list s1_valid_regs $s1_valid_regs] \
  [list f16tf32_stage_regs $f16tf32_stage_regs] \
  [list f4_stage_regs $f4_stage_regs] \
  [list f4_sum_regs $f4_sum_regs] \
  [list stage_a_regs $stage_a_regs] \
  [list stage_b_regs $stage_b_regs] \
  [list stage_b_data_regs $stage_b_data_regs] \
  [list ready_from_objs $ready_from_objs] \
] {
  puts $fd [format "  %-22s %6d" [lindex $count_row 0] [llength [lindex $count_row 1]]]
}
puts $fd ""
puts $fd "Detailed timing paths:"
foreach detail_path $detail_paths {
  puts $fd "  $detail_path"
}
close $fd

puts "Wrote $report_file"
