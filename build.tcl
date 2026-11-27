# ============================================================================
# DEPTH (CPE222 Group 17) - one-command Vivado build for the Nexys A7-100T
#
#   Full build  :  vivado -mode batch -source build.tcl
#   Project only:  vivado -mode batch -source build.tcl -tclargs project
#   Clean       :  vivado -mode batch -source build.tcl -tclargs clean
#   From the GUI:  Tools -> Run Tcl Script... -> build.tcl
#
# Outputs (next to this script):
#   Group17_DEPTH.bit          bitstream for Hardware Manager
#   Group17_DEPTH.bin          raw bitstream
#   Group17_DEPTH.mcs          Quad-SPI flash image (boots without a PC)
#   reports/synth_timing.txt   post-synthesis timing summary
#   reports/timing.txt         post-route timing summary
#   reports/utilization.txt    post-route resource usage
#   reports/route_status.txt   post-route routing status
#
# If timing is not met the script retries ONCE with a high-effort strategy
# before giving up, and never writes a bitstream it cannot stand behind.
# ============================================================================

set mode "build"
if {[info exists ::argc] && $::argc > 0} {
    set mode [lindex $::argv 0]
}

set root      [file normalize [file dirname [info script]]]
set proj_name Group17_DEPTH
set proj_dir  [file join $root vivado]
set part      xc7a100tcsg324-1
set top       top_depth
set rpt_dir   [file join $root reports]

# Use the machine's cores, but stay inside what this Vivado edition allows.
set jobs 4
catch {
    set jobs [expr {[numberOfCPUs] > 8 ? 8 : [numberOfCPUs]}]
}
if {$jobs < 1} { set jobs 1 }

# ---------------------------------------------------------------------------
proc depth_say {msg} { puts "=== DEPTH: $msg" }

proc depth_die {msg} {
    puts ""
    puts "############################################################"
    puts "## DEPTH BUILD FAILED"
    puts "## $msg"
    puts "############################################################"
    error $msg
}

# ---------------------------------------------------------------------------
if {$mode eq "clean"} {
    depth_say "removing $proj_dir and generated outputs"
    catch { file delete -force $proj_dir }
    foreach f [list $proj_name.bit $proj_name.bin $proj_name.mcs $proj_name.prm] {
        catch { file delete -force [file join $root $f] }
    }
    catch { file delete -force $rpt_dir }
    depth_say "clean done"
    return
}

# ---------------------------------------------------------------------------
# 0. Pre-flight: fail with a clear message instead of a black screen later.
# ---------------------------------------------------------------------------
set src_files  [lsort [glob -nocomplain [file join $root src *.v]]]
set hdr_files  [lsort [glob -nocomplain [file join $root src *.vh]]]
set mem_files  [lsort [glob -nocomplain [file join $root mem *.mem]]]
set xdc_files  [lsort [glob -nocomplain [file join $root constraints *.xdc]]]

if {[llength $src_files] == 0} { depth_die "no Verilog found in [file join $root src]" }
if {[llength $xdc_files] == 0} { depth_die "no .xdc found in [file join $root constraints]" }

foreach need {sin_lut.mem cos_lut.mem inv_lut.mem tile_map.mem hud_sprites.mem wave_rom.mem} {
    if {![file exists [file join $root mem $need]]} {
        depth_die "mem/$need is missing - the ROMs would synthesise as all-zero\
 (black screen, no sound) without Vivado reporting an error."
    }
}

depth_say "part $part, top $top, $jobs jobs"
depth_say "[llength $src_files] Verilog files, [llength $mem_files] ROM images"

# ---------------------------------------------------------------------------
# 1. Project
# ---------------------------------------------------------------------------
depth_say "creating project in $proj_dir"
create_project -force $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]

add_files -norecurse $src_files
if {[llength $hdr_files] > 0} {
    add_files -norecurse $hdr_files
    set_property file_type {Verilog Header} [get_files -filter {NAME =~ *.vh}]
}
set_property include_dirs [list [file join $root src]] [current_fileset]

# $readmemh in the RTL uses bare file names; adding the .mem files to the
# project makes Vivado place them where synthesis can resolve them.
add_files -norecurse $mem_files
set_property include_dirs [list [file join $root src] [file join $root mem]] [current_fileset]

add_files -fileset constrs_1 -norecurse $xdc_files

set_property top $top [current_fileset]
update_compile_order -fileset sources_1

if {$mode eq "project"} {
    depth_say "project created - open $proj_dir/$proj_name.xpr in Vivado"
    return
}

file mkdir $rpt_dir

# ---------------------------------------------------------------------------
# 2. Build attempt (run twice at most: defaults, then high effort)
# ---------------------------------------------------------------------------
proc depth_run_flow {attempt jobs rpt_dir} {
    if {$attempt == 1} {
        set synth_strat "Vivado Synthesis Defaults"
        set impl_strat  "Vivado Implementation Defaults"
    } else {
        set synth_strat "Flow_PerfOptimized_high"
        set impl_strat  "Performance_ExplorePostRoutePhysOpt"
    }
    depth_say "attempt $attempt - synth: $synth_strat / impl: $impl_strat"

    if {$attempt > 1} {
        reset_run synth_1
        reset_run impl_1
        set_property strategy $synth_strat [get_runs synth_1]
        set_property strategy $impl_strat  [get_runs impl_1]
    }

    # --- synthesis ---------------------------------------------------------
    depth_say "synthesis"
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        depth_die "synthesis FAILED - see [get_property DIRECTORY [get_runs synth_1]]/runme.log"
    }

    open_run synth_1 -name synth_1
    report_timing_summary -max_paths 10 -file [file join $rpt_dir synth_timing.txt]
    set synth_wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
    if {$synth_wns eq ""} { set synth_wns 0 }
    depth_say "post-synthesis WNS = $synth_wns ns (estimate; routing adds delay)"
    close_design

    # --- implementation ----------------------------------------------------
    depth_say "implementation (place + route[expr {$attempt > 1 ? " + post-route phys opt" : ""}])"
    if {$attempt == 1} {
        set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
    }
    launch_runs impl_1 -jobs $jobs
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        depth_die "implementation FAILED - see [get_property DIRECTORY [get_runs impl_1]]/runme.log"
    }

    open_run impl_1

    report_timing_summary -max_paths 20 -report_unconstrained -file [file join $rpt_dir timing.txt]
    report_utilization                                        -file [file join $rpt_dir utilization.txt]
    report_route_status                                       -file [file join $rpt_dir route_status.txt]

    set setup_path [get_timing_paths -setup -max_paths 1 -nworst 1]
    set hold_path  [get_timing_paths -hold  -max_paths 1 -nworst 1]
    if {[llength $setup_path] == 0} {
        depth_die "no constrained timing paths found - is create_clock still in the XDC?"
    }
    set wns [get_property SLACK $setup_path]
    set whs [expr {[llength $hold_path] ? [get_property SLACK $hold_path] : 0}]
    if {$wns eq ""} { set wns -999 }
    if {$whs eq ""} { set whs 0 }

    set bad_nets [get_nets -hierarchical -quiet -filter \
        {ROUTE_STATUS == UNROUTED || ROUTE_STATUS == PARTIAL || ROUTE_STATUS == CONFLICTS}]
    set n_bad [llength $bad_nets]

    set worst ""
    catch { set worst [get_property NAME $setup_path] }

    return [list $wns $whs $n_bad $worst]
}

set result [depth_run_flow 1 $jobs $rpt_dir]
lassign $result wns whs n_bad worst

if {$wns < 0 || $whs < 0 || $n_bad > 0} {
    depth_say "timing not met on the default strategy (WNS=$wns ns) - retrying at high effort"
    close_design
    set result [depth_run_flow 2 $jobs $rpt_dir]
    lassign $result wns whs n_bad worst
}

# ---------------------------------------------------------------------------
# 3. Summary
# ---------------------------------------------------------------------------
puts ""
puts "------------------------------------------------------------"
puts " DEPTH build summary"
puts "   Worst setup slack (WNS) : $wns ns"
puts "   Worst hold slack  (WHS) : $whs ns"
puts "   Unrouted/conflict nets  : $n_bad"
if {[file exists [file join $rpt_dir utilization.txt]]} {
    set fh [open [file join $rpt_dir utilization.txt] r]
    set util [read $fh]
    close $fh
    foreach row {"Slice LUTs" "Slice Registers" "Block RAM Tile" "DSPs" "Bonded IOB"} {
        foreach line [split $util "\n"] {
            if {[string match "*| $row*|*" $line]} {
                puts "   [string trim [string map {"|" " "} $line]]"
                break
            }
        }
    }
}
puts "------------------------------------------------------------"
puts ""

if {$wns < 0 || $whs < 0 || $n_bad > 0} {
    depth_die "TIMING/ROUTING GATE FAILED (WNS=$wns ns, WHS=$whs ns, bad nets=$n_bad).\
 No bitstream written.  Worst setup path: $worst .\
 Send reports/timing.txt and reports/utilization.txt back to the developer."
}

# ---------------------------------------------------------------------------
# 4. Bitstream + flash image
# ---------------------------------------------------------------------------
set bit_file [file join $root $proj_name.bit]
depth_say "timing met - writing bitstream"
write_bitstream -force -bin_file $bit_file

# Quad-SPI image so the board can boot DEPTH on its own.
catch {
    write_cfgmem -force -format MCS -interface SPIx4 -size 16 \
        -loadbit "up 0x00000000 $bit_file" \
        -file [file join $root $proj_name.mcs]
    depth_say "flash image: $proj_name.mcs"
}

depth_say "DONE -> $bit_file"
puts "    Program now : Open Hardware Manager -> Open Target -> Auto Connect -> Program Device"
puts "    Program flash: Add Configuration Memory Device -> s25fl128sxxxxxx0-spi-x1_x2_x4 -> $proj_name.mcs"
