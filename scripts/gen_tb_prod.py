"""gen_tb_prod.py - 从已验证的 tb_ntt_unit.sv 派生生产版 testbench

做法：读取 tb/tb_ntt_unit.sv，把 DUT 从 ntt_unit_test（测试版，组合乘法）
替换为 ntt_unit（生产版，Horner4 乘法器 + 素数模），其余时序/向量/比对逻辑不变。

这样能保证生产版与已验证的测试版走完全相同的测试流程（10 组向量 x NTT+INTT
往返 + 逐项比对），隔离变量到"乘法器+模运算实现"这一处。
"""
import os
import io

ROOT = str(Path(__file__).resolve().parents[1])
SRC = os.path.join(ROOT, "tb", "tb_ntt_unit.sv")
DST = os.path.join(ROOT, "tb", "tb_ntt_unit_prod.sv")

t = io.open(SRC, "r", encoding="utf-8").read()

# 1. 文件头注释标记
t = t.replace(
    "// tb_ntt_unit.sv  —  ntt_unit 完整测试平台（密推芯 M1 Phase 2c）",
    "// tb_ntt_unit_prod.sv  —  生产版 ntt_unit 完整测试平台（密推芯 M1 Phase 3）\n"
    "//\n"
    "// 与 tb_ntt_unit.sv（测试版 DUT）的唯一差异：DUT 换成生产版 ntt_unit\n"
    "// （Horner4 乘法器 + 素数模蝴蝶），用于验证生产版算法与测试版等价。",
    1,
)

# 2. DUT 名字替换
n1 = t.count("ntt_unit_test")
t = t.replace("ntt_unit_test", "ntt_unit")
n2 = t.count("ntt_unit")  # 包含注释里的，统计总数

# 3. module 名替换
n3 = t.count("module tb_ntt_unit;")
t = t.replace("module tb_ntt_unit;", "module tb_ntt_unit_prod;", 1)

# 4. 加一段说明：生产版 Q_WIDTH=7 时 Horner 分解为 HI_W=6/LO_W=1
#    在参数区插入注释
anchor = "    localparam real   CLK_PERIOD = 10.0;             // 100 MHz"
assert anchor in t, "anchor not found"
t = t.replace(
    anchor,
    anchor + "\n"
    "    // 生产版说明：Q_WIDTH=7 时 ntt_unit 自动取 BF_HI_W=6 / BF_LO_W=1\n"
    "    //   （localparam BF_HI_W = (Q_WIDTH>24)?24:(Q_WIDTH-1)），\n"
    "    //   Horner4 在 7-bit 下仍数学等价，只是用不到 DSP48E1。",
    1,
)

io.open(DST, "w", encoding="utf-8", newline="\n").write(t)

# 回读校验
back = io.open(DST, "r", encoding="utf-8").read()
print(f"SRC lines: {t.count(chr(10))}")
print(f"DST bytes: {len(back.encode('utf-8'))}")
print(f"DST tail200: {back[-200:]!r}")
print(f"ntt_unit_test replaced: {n1} occurrences -> 0 remaining: {back.count('ntt_unit_test')}")
print(f"module name replaced: {n3}")
print(f"DUT instance 'ntt_unit #(': {'ntt_unit #(' in back}")
print(f"module decl 'tb_ntt_unit_prod': {'module tb_ntt_unit_prod;' in back}")
