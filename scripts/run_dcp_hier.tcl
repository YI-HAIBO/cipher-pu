# run_dcp_hier.tcl — 对已生成的 DCP 做层次化资源分析，定位 LUTRAM 来源
#
# 目的：
#   keyswitch_pipe / approx_poly_mult 综合后 "LUT as Memory" 高达 291,840 / 76,800，
#   占总 LUT 的 38.5% / 26%。本脚本不重新综合，直接读入已有 DCP，
#   输出层次化资源分布，定位 LUT-as-Distributed-RAM 集中在哪个子层次。
#
# 用法：
#   vivado -mode batch -source run_dcp_hier.tcl -nojournal
#   路径通过 ::env(DCP_DIR) / ::env(OUT_DIR) 传入

set DCP_DIR ""
if {[info exists ::env(DCP_DIR)]} { set DCP_DIR $::env(DCP_DIR) }
set OUT_DIR ""
if {[info exists ::env(OUT_DIR)]} { set OUT_DIR $::env(OUT_DIR) }

# 要分析的模块（逗号分隔）
set MODS "approx_poly_mult,keyswitch_pipe"
if {[info exists ::env(DCP_MODS)]} { set MODS $::env(DCP_MODS) }

puts ""
puts "###### DCP 层次化资源分析（定位 LUTRAM）######"
puts "DCP_DIR: $DCP_DIR"
puts "MODS:    $MODS"
puts ""

create_project dcp_hier ./dcp_hier -force

foreach m [split $MODS ","] {
    set dcp "$DCP_DIR/${m}.dcp"
    puts ""
    puts "============================================="
    puts "=== $m ==="
    puts "============================================="

    if {![file exists $dcp]} {
        puts "  [SKIP] DCP 不存在: $dcp"
        continue
    }

    catch { read_checkpoint $dcp } err_r
    if {[llength $err_r] > 0} { puts "  WARN read: $err_r" }
    catch { link_design } err_l
    if {[llength $err_l] > 0} { puts "  WARN link: $err_l" }

    # 1) 层次化资源（按子模块聚合）
    set hier "$OUT_DIR/${m}_util_hier.rpt"
    catch { report_utilization -hierarchical -file $hier } e1
    puts "  hierarchical report: $hier"

    # 2) 层次化 + 按 cell 类型（看 LUTRAM 原语分布）
    set hierc "$OUT_DIR/${m}_util_hier_cells.rpt"
    catch { report_utilization -hierarchical -hierarchical_depth 5 -file $hierc } e2
    puts "  hierarchical cells:  $hierc"

    # 3) 统计 LUTRAM 相关原语实例（SDP/SRL/LUTRAM）
    puts "  --- LUTRAM 原语统计 ---"
    foreach pat {LUTRAM_SDP LUTRAM_SSE LUTRAM_TDP SRL16E SRL32E RAM64M RAM256X1S RAMB36E1 RAMB18E1} {
        set n [llength [get_cells -quiet -hierarchical -filter "REF_NAME == $pat"]]
        if {$n > 0} { puts "    $pat : $n" }
    }

    # 4) 找所有 RAM/LUTRAM cell 的层次路径（前 30 条）
    puts "  --- LUTRAM/RAM cell 层次路径（前 30）---"
    set ramcells [get_cells -quiet -hierarchical -filter "REF_NAME =~ {LUTRAM*|SRL*|RAM*}"]
    set cnt 0
    foreach c [lsort $ramcells] {
        puts "    $c"
        incr cnt
        if {$cnt >= 30} { break }
    }
    puts "    (total LUTRAM/RAM cells: [llength $ramcells])"

    # 5) 搜索含内存的类比实例名模式
    puts "  --- 含关键词的 RAM 实例名（ram/mem/buf/stage/table）---"
    foreach p {ram mem buf stage table coef twid rot key} {
        set filt "NAME =~ *${p}*"
        set cs [get_cells -quiet -hierarchical -filter $filt]
        set nc [llength $cs]
        if {$nc > 0 && $nc < 40} {
            puts "    [$p] $nc:"
            foreach c [lsort $cs] {
                set rn [get_property REF_NAME $c]
                puts "       $c  ($rn)"
            }
        } elseif {$nc >= 40} {
            puts "    (${p}) $nc cells (略)"
        }
    }

    close_project -quiet
}

puts ""
puts "###### 分析完成 ######"
exit 0
