source $::env(SCRIPTS_DIR)/load.tcl

load_design 1_2_yosys.v 1_synth.sdc

set report_file "$::env(REPORTS_DIR)/int8_stage_timing_post_synth.rpt"
set detail_dir  "$::env(OBJECTS_DIR)/int8_stage_timing_details"
file delete -force $detail_dir
file mkdir $detail_dir

proc int8_obj_name {obj} {
  if {[catch {set name [get_full_name $obj]}]} {
    set name $obj
  }
  return $name
}

proc int8_filter_registers {pattern} {
  set regs {}
  foreach reg [all_registers] {
    set name [int8_obj_name $reg]
    if {[regexp $pattern $name]} {
      lappend regs $reg
    }
  }
  return $regs
}

proc int8_filter_inputs {{exclude_reset 1}} {
  set ports {}
  foreach port [all_inputs -no_clocks] {
    set name [int8_obj_name $port]
    if {$exclude_reset && $name == "rst_n"} {
      continue
    }
    lappend ports $port
  }
  return $ports
}

proc int8_filter_outputs {{exclude_ready 0}} {
  set ports {}
  foreach port [all_outputs] {
    set name [int8_obj_name $port]
    if {$exclude_ready && $name == "in_rdy_o"} {
      continue
    }
    lappend ports $port
  }
  return $ports
}

proc int8_get_port_quiet {port_name} {
  set ports [get_ports -quiet $port_name]
  if {[llength $ports] == 0} {
    return {}
  }
  return $ports
}

proc int8_parse_check_report {text} {
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

proc int8_format_float {value digits} {
  if {$value == "N/A"} {
    return "N/A"
  }
  return [format "%.${digits}f" $value]
}

proc int8_report_stage {stage_name boundary from_objs to_objs target_period_ps detail_path} {
  if {[llength $from_objs] == 0 || [llength $to_objs] == 0} {
    return [list $stage_name $boundary "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"]
  }

  file delete -force $detail_path
  report_checks -path_delay max \
    -from $from_objs \
    -to $to_objs \
    -fields {slew cap input net fanout} \
    -format full_clock_expanded > $detail_path

  set fd [open $detail_path r]
  set text [read $fd]
  close $fd

  if {[string first "Startpoint:" $text] < 0} {
    return [list $stage_name $boundary "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"]
  }

  lassign [int8_parse_check_report $text] startpoint endpoint arrival required slack status
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
    [int8_format_float $arrival 2] \
    [int8_format_float $required 2] \
    [int8_format_float $slack 2] \
    [int8_format_float $min_period 2] \
    [int8_format_float $fmax_ghz 3] \
    $status \
    $startpoint \
    $endpoint]
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

set all_nonclk_inputs [int8_filter_inputs 1]
set stage0_data_regs  [int8_filter_registers {u_stage0_reg\.out_data}]
set stage1_data_regs  [int8_filter_registers {u_stage1_reg\.out_data}]
set stage3_data_regs  [int8_filter_registers {u_stage3_reg\.out_data}]

set stage3_all_regs   [int8_filter_registers {u_stage3_reg\.}]
set data_outputs      [int8_filter_outputs 1]

set ready_from_objs {}
foreach obj [int8_get_port_quiet out_rdy_i] {
  lappend ready_from_objs $obj
}
foreach reg [int8_filter_registers {u_stage[013]_reg\.out_valid}] {
  lappend ready_from_objs $reg
}
set ready_to_objs [int8_get_port_quiet in_rdy_o]

set stage_rows {}
lappend stage_rows [int8_report_stage \
  "S0 input/decode/product" \
  "inputs -> u_stage0_reg.out_data" \
  $all_nonclk_inputs $stage0_data_regs $target_period_ps \
  "$detail_dir/S0_input_to_stage0.rpt"]
lappend stage_rows [int8_report_stage \
  "S1/S2 product reduction" \
  "u_stage0_reg.out_data -> u_stage1_reg.out_data" \
  $stage0_data_regs $stage1_data_regs $target_period_ps \
  "$detail_dir/S1_stage0_to_stage1.rpt"]
lappend stage_rows [int8_report_stage \
  "S3 add C/overflow/pack" \
  "u_stage1_reg.out_data -> u_stage3_reg.out_data" \
  $stage1_data_regs $stage3_data_regs $target_period_ps \
  "$detail_dir/S3_stage1_to_stage3.rpt"]
lappend stage_rows [int8_report_stage \
  "output" \
  "u_stage3_reg -> outputs" \
  $stage3_all_regs $data_outputs $target_period_ps \
  "$detail_dir/output_stage3_to_outputs.rpt"]
lappend stage_rows [int8_report_stage \
  "ready/backpressure" \
  "out_rdy_i + valid regs -> in_rdy_o" \
  $ready_from_objs $ready_to_objs $target_period_ps \
  "$detail_dir/ready_backpressure.rpt"]

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

set fd [open $report_file w]
puts $fd "INT8 dot product post-synth stage timing"
puts $fd "Generated by OpenROAD on [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %Z}]"
puts $fd "Design: $::env(DESIGN_NAME)"
puts $fd "Target period: [format %.2f $target_period_ps] ps"
puts $fd "Netlist: $::env(RESULTS_DIR)/1_2_yosys.v"
puts $fd "SDC: $::env(RESULTS_DIR)/1_synth.sdc"
puts $fd ""
puts $fd [format "%-32s | %-47s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
  "Stage" "Boundary" "Delay(ps)" "Required(ps)" "Slack(ps)" "MinPeriod(ps)" "Fmax(GHz)" "Status" "Startpoint" "Endpoint"]
puts $fd [string repeat "-" 300]
foreach row $stage_rows {
  puts $fd [format "%-32s | %-47s | %10s | %11s | %10s | %13s | %9s | %-8s | %-58s | %-58s" \
    [lindex $row 0] [lindex $row 1] [lindex $row 2] [lindex $row 3] [lindex $row 4] \
    [lindex $row 5] [lindex $row 6] [lindex $row 7] [lindex $row 8] [lindex $row 9]]
}
puts $fd ""
puts $fd "Worst stage slack: $min_slack ps ($min_stage)"
puts $fd ""
puts $fd "Matched object counts:"
puts $fd [format "  %-24s %5d" "all_nonclk_inputs" [llength $all_nonclk_inputs]]
puts $fd [format "  %-24s %5d" "stage0_data_regs"  [llength $stage0_data_regs]]
puts $fd [format "  %-24s %5d" "stage1_data_regs"  [llength $stage1_data_regs]]
puts $fd [format "  %-24s %5d" "stage3_data_regs"  [llength $stage3_data_regs]]
puts $fd [format "  %-24s %5d" "stage3_all_regs"   [llength $stage3_all_regs]]
puts $fd [format "  %-24s %5d" "data_outputs"      [llength $data_outputs]]
puts $fd [format "  %-24s %5d" "ready_from_objs"   [llength $ready_from_objs]]
puts $fd [format "  %-24s %5d" "ready_to_objs"     [llength $ready_to_objs]]
puts $fd ""
puts $fd "Detailed report snippets:"
puts $fd "  $detail_dir/S0_input_to_stage0.rpt"
puts $fd "  $detail_dir/S1_stage0_to_stage1.rpt"
puts $fd "  $detail_dir/S3_stage1_to_stage3.rpt"
puts $fd "  $detail_dir/output_stage3_to_outputs.rpt"
puts $fd "  $detail_dir/ready_backpressure.rpt"
close $fd

puts "Wrote $report_file"
