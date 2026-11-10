# ============================================================
# M6 Bring-up 顶层约束（XDC）
# 复用 M5 时钟约束 + 添加 ILA 探针 + 状态 LED
# ============================================================

# ---------- 时钟约束（与 M5 一致） ----------
create_clock -period 10.000 -name clk [get_ports clk]
set_clock_uncertainty 0.100 [get_clocks clk]

# ---------- JTAG 复位 ----------
set_false_path -to [get_ports rst_n]

# ---------- ILA 核约束 ----------
# ILA clk 应与主 clk 同源
set_property CARRY_SENSE true [get_pins ila_inst/clk]

# ---------- 状态 LED（可选，板卡有 LED 时才启用） ----------
# set_property PACKAGE_PIN <PIN> [get_ports led[0]]
# set_property PACKAGE_PIN <PIN> [get_ports led[1]]
# set_property PACKAGE_PIN <PIN> [get_ports led[2]]

# ---------- 位流加密（M6 首次不启用） ----------
# write_bitstream -encrypt -key_file secret.key -bitstream_file out.xbit
