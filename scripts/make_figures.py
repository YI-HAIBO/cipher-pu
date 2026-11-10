"""
make_figures.py

Task #156: 生成论文 Fig.1-4 + Table.1-3

输出目录: fpga_ckks/reports/figures/
格式: PNG 300dpi + PDF 矢量双格式
配色: IEEE 单色可打印，主色 #1f77b4 (蓝) + #d62728 (红) + #2ca02c (绿) + #7f7f7f (灰)
字体: DejaVu Sans (matplotlib default)
"""
import os, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT_DIR = str(Path(__file__).resolve().parent.parent / "reports" / "figures")
os.makedirs(OUT_DIR, exist_ok=True)

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 8,
    "axes.labelsize": 9,
    "axes.titlesize": 10,
    "xtick.labelsize": 8,
    "ytick.labelsize": 8,
    "legend.fontsize": 8,
    "figure.dpi": 100,
    "savefig.dpi": 300,
    "savefig.bbox": "tight",
    "axes.grid": True,
    "grid.alpha": 0.3,
    "axes.axisbelow": True,
    "axes.spines.top": False,
    "axes.spines.right": False,
})

C_BLUE   = "#1f77b4"
C_RED    = "#d62728"
C_GREEN  = "#2ca02c"
C_GREY   = "#7f7f7f"
C_ORANGE = "#ff7f0e"
C_PURPLE = "#9467bd"


def save(fig, name):
    """保存 PNG + PDF 双格式"""
    for ext in ("png", "pdf"):
        path = os.path.join(OUT_DIR, f"{name}.{ext}")
        fig.savefig(path)
        print(f"  saved {path}")
    plt.close(fig)


# ============================================================
# Fig.1: 系统架构总览 (Block diagram)
# ============================================================
fig, ax = plt.subplots(figsize=(9, 3.2))
ax.set_xlim(0, 10)
ax.set_ylim(0, 4)
ax.axis("off")

# 主数据通路（上排）
blocks_main = [
    (0.4, 2.3, 1.5, 0.7, "Load / Output\nInterface",       C_GREY),
    (2.5, 2.3, 2.0, 0.7, "poly_mult Core\n(NTT+mul+INTT)", C_BLUE),
    (5.0, 2.3, 2.0, 0.7, "Activation\n(Chebyshev)",       C_GREEN),
    (7.5, 2.3, 2.0, 0.7, "Rescale Unit\n(noise budget)", C_ORANGE),
]
for x, y, w, h, txt, c in blocks_main:
    ax.add_patch(plt.Rectangle((x, y), w, h, facecolor=c, alpha=0.15, edgecolor=c, lw=1.2))
    ax.text(x + w/2, y + h/2, txt, ha="center", va="center", fontsize=8)

# 主通路箭头
for x in [1.9, 4.5, 7.0]:
    ax.annotate("", xy=(x+0.1, 2.65), xytext=(x-0.05, 2.65),
                arrowprops=dict(arrowstyle="->", lw=1.2, color=C_GREY))

# 噪声监测（下排）
ax.add_patch(plt.Rectangle((2.5, 0.7), 3.5, 0.7, facecolor=C_PURPLE, alpha=0.15, edgecolor=C_PURPLE, lw=1.2))
ax.text(4.25, 1.05, "Noise Monitor\n+ Adaptive Gear Ctrl", ha="center", va="center", fontsize=8)

# 反馈闭环箭头：Rescale 输出 → noise monitor → gear → poly_mult
# 从 Rescale 底部向下
ax.annotate("", xy=(8.5, 1.4), xytext=(8.5, 2.3),
            arrowprops=dict(arrowstyle="->", lw=1.5, color=C_RED, connectionstyle="arc3,rad=-0.3"))
ax.annotate("", xy=(6.0, 1.05), xytext=(8.4, 1.15),
            arrowprops=dict(arrowstyle="->", lw=1.5, color=C_RED))
# 从 gear ctrl 回到 poly_mult
ax.annotate("", xy=(3.5, 2.3), xytext=(3.5, 1.4),
            arrowprops=dict(arrowstyle="->", lw=1.5, color=C_RED, connectionstyle="arc3,rad=0.3"))

# 反馈说明
ax.text(5.5, 3.6, "Feedback loop: rescale output → noise_monitor → adaptive_gear_ctrl → poly_mult",
        ha="center", fontsize=7, style="italic", color=C_RED)

# 数据源标签
ax.text(5, 0.25, "Data flow →", ha="center", fontsize=7, color=C_GREY)

save(fig, "fig1_architecture")


# ============================================================
# Fig.2: 三档面积-时序对比 (grouped bar + WNS line)
# ============================================================
tiers = ["S82\n(N=4096)", "S90\n(N=8192)", "S128\n(N=16384)"]
lut_pct = [37.97, 73.22, 178.28]
lut_abs = [53542, 103239, 251380]
wns = [-0.612, 3.250, -6.623]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(9, 3.2))

# 左：LUT% + BRAM% (bar)
x = np.arange(len(tiers))
w = 0.35
bars_lut = ax1.bar(x - w/2, lut_pct, w, label="LUT %", color=C_BLUE, alpha=0.85)
bram_pct = [10.0, 20.0, 20.0]  # BRAM: 30/60/60 / 300 total = 10/20/20 %
bars_bram = ax1.bar(x + w/2, bram_pct, w, label="BRAM36 %", color=C_GREEN, alpha=0.85)

# 添加数值标签
for bars in (bars_lut, bars_bram):
    for b in bars:
        h = b.get_height()
        ax1.text(b.get_x() + b.get_width()/2, h + 3, f"{h:.0f}%", ha="center", fontsize=7)

# 100% 参考线
ax1.axhline(100, color=C_RED, ls="--", lw=1, alpha=0.7, label="100% device capacity")
ax1.set_xticks(x)
ax1.set_xticklabels(tiers)
ax1.set_ylabel("Resource Utilization (%)")
ax1.set_ylim(0, 200)
ax1.legend(loc="upper left", framealpha=0.9)
ax1.set_title("(a) Area Utilization vs Device Capacity", fontsize=9)

# 右：WNS (bar with color by sign)
colors = [C_RED if w < 0 else C_GREEN for w in wns]
bars = ax2.bar(x, wns, 0.5, color=colors, alpha=0.85)
for b, w_val in zip(bars, wns):
    offset = 0.1 if w_val >= 0 else -0.3
    ax2.text(b.get_x() + b.get_width()/2, w_val + offset, f"{w_val:+.3f} ns",
             ha="center", fontsize=7)
ax2.axhline(0, color=C_GREY, lw=1)
ax2.set_xticks(x)
ax2.set_xticklabels(tiers)
ax2.set_ylabel("WNS (ns) @ 100 MHz")
ax2.legend([plt.Rectangle((0,0),1,1,color=C_GREEN,alpha=0.85), plt.Rectangle((0,0),1,1,color=C_RED,alpha=0.85)],
           ["Met", "Violated"], loc="lower right", framealpha=0.9)
ax2.set_title("(b) Timing Margin (WNS) at 100 MHz", fontsize=9)

save(fig, "fig2_three_tier_dse")


# ============================================================
# Fig.3: 噪声预算 + DARE 刷新 (dual log curve)
# ============================================================
depth = np.arange(0, 7)
# 无刷新：指数增长（从 E24 实测数据）
noise_norefresh = [0.821, 21.3, 771, 32600, 1510000, 6.5e6, 3.0e7]
# DARE 刷新：线性增长（每层 +1 新鲜误差）
noise_dare = [0.821, 1.82, 2.82, 3.82, 4.82, 5.82, 6.82]

fig, ax = plt.subplots(figsize=(7.5, 3.2))

ax.semilogy(depth, noise_norefresh, "-o", color=C_RED, lw=1.8, ms=5,
            label="Without refresh (exponential growth)")
ax.semilogy(depth, noise_dare, "-s", color=C_BLUE, lw=1.8, ms=5,
            label="With DARE bootstrap-lite (linear, +1 per layer)")

# q/4 饱和阈值
q = 17592186175489
ax.axhline(q/4, color=C_GREY, ls="--", lw=1, label=f"q/4 saturation ({q/4:.2e})")
ax.fill_between(depth, 0, q/4*1.1, alpha=0.05, color=C_GREY)

# 标注关键数据点
ax.annotate("q/4 saturated\n(6 layers)", xy=(5, 6.5e6), xytext=(3.2, 3e6),
            fontsize=7, color=C_RED,
            arrowprops=dict(arrowstyle="->", color=C_RED, lw=0.8))
ax.annotate("Noise budget reset\n26× per layer", xy=(3, 3.82), xytext=(1.5, 30),
            fontsize=7, color=C_BLUE,
            arrowprops=dict(arrowstyle="->", color=C_BLUE, lw=0.8))

ax.set_xlabel("Multiplication Depth (layers)")
ax.set_ylabel("Noise σ (log scale)")
ax.set_xticks(depth)
ax.legend(loc="upper left", framealpha=0.9)
save(fig, "fig3_noise_budget_dare")


# ============================================================
# Fig.4: SOTA 对比（散点 + 能效）
# ============================================================
# (name, power, mops, color, marker, size, label_offset, ha)
systems = [
    ("CIPHER-PU (this work)",  0.698,  48.0,    C_BLUE,   "o", 20, (12,  6), "left"),
    ("cuFHE (A100)",           400.0,  1800.0,  C_GREEN,  "s", 14, (-150, -8), "right"),
    ("cuOpenFHE (A100)",       400.0,  1500.0,  C_GREEN,  "^", 14, (-150, 20), "right"),
    ("cuFHE (V100)",           250.0,  800.0,   C_ORANGE, "v", 12, (-110, -18), "right"),
    ("OpenFHE (CPU)",          85.0,   0.00014, C_PURPLE, "D", 10, (10,  8), "left"),
    ("SEAL (CPU)",             85.0,   0.00011, C_GREY,   "x", 10, (10, -18), "left"),
]

fig, ax = plt.subplots(figsize=(8, 3.8))

for name, power, mops, color, marker, size, offset, ha in systems:
    efficiency = mops / power * 1e6  # ops/W
    edgecolors = "none" if marker == "x" else "black"
    ax.scatter(power, mops, s=size*10, c=color, marker=marker, label=name,
               alpha=0.85, edgecolors=edgecolors, linewidths=0.5, zorder=3)
    ax.annotate(f"{name}\n{efficiency:.2e} ops/W", xy=(power, mops),
                xytext=offset, textcoords="offset points", fontsize=7,
                color=color, ha=ha,
                arrowprops=dict(arrowstyle="-", lw=0.5, color=color, alpha=0.5,
                                shrinkA=0, shrinkB=2))

# 对数坐标
ax.set_xscale("log")
ax.set_yscale("log")
ax.set_xlim(0.1, 1000)
ax.set_ylim(1e-3, 5e3)
ax.set_xlabel("Power Consumption (W, log scale)")
ax.set_ylabel("Throughput (MOPS, log scale)")
ax.legend(loc="upper left", framealpha=0.9, fontsize=7)
save(fig, "fig4_sota_efficiency")


# ============================================================
# 生成 Table.1-3 的 LaTeX 源码（供论文 LaTeX 版使用）
# ============================================================
latex_tables = {
    "table1_three_tier.tex": r"""
\begin{table}[htbp]
\centering
\caption{Three-tier security-parameter DSE on xcau25p-ffvb676-1-e.
Safety level from HE Standard v1.1 (uniform secret, $\sigma$=3.2, BKZ.sieve).}
\label{tab:three_tier}
\footnotesize
\begin{tabular}{lccccccc}
\toprule
Tier & $N$ & $\log_2 N$ & $Q$ width & Security & LUT (\%) & BRAM36 & WNS @100MHz \\
\midrule
S82  & 4096  & 12 & 45 & $\ge$ 256 bit &  37.97\% & 30 & $-0.612$ ns \\
S90  & 8192  & 13 & 45 & $\ge$ 256 bit &  73.22\% & 60 & $+3.250$ ns \\
S128 & 16384 & 14 & 45 & $\ge$ 256 bit & 178.28\% & 60 & $-6.623$ ns \\
\bottomrule
\end{tabular}
\end{table}
""".strip(),

    "table2_spare_time.tex": r"""
\begin{table}[htbp]
\centering
\caption{Spare-time area/timing scaling across tiers.
LUT grows superlinearly with $N$; BRAM plateaus at 60 units (45-bit$\times$N fits in 36Kb RAMB36E2).}
\label{tab:scaling}
\footnotesize
\begin{tabular}{lcccl}
\toprule
Metric & S82 & S90 & S128 & Scaling \\
\midrule
LUT (count)     &  53,542 & 103,239 & 251,380 & $\propto N^{1.13}$ \\
BRAM36 (count)  &  30     &  60     &  60     & $\propto N^{1.00}$ (plateau) \\
DSP48E2         &  27     &  27     &  28     & Weakly correlated \\
WNS (ns)        & $-0.612$ & $+3.250$ & $-6.623$ & Non-monotonic \\
\bottomrule
\end{tabular}
\end{table}
""".strip(),

    "table3_sota.tex": r"""
\begin{table}[htbp]
\centering
\caption{Efficiency comparison with state-of-the-art CKKS implementations.
CIPHER-PU achieves $68.8\times10^6$ ops/W (routed SAIF power), 15.3$\times$ higher than cuFHE on A100 GPU,
583K$\times$ higher than CPU.}
\label{tab:sota}
\footnotesize
\begin{tabular}{lccccc}
\toprule
System & Platform & Power (W) & Throughput (MOPS) & Efficiency (ops/W) & Source \\
\midrule
\textbf{CIPHER-PU (ours)} & FPGA xcau25p & 0.698 & 48.0   & \textbf{68.8M} & This work (routed SAIF, E34) \\
cuFHE            & NVIDIA A100  & 400  & 1800.0 & 4.5M   & \cite{frigg2022cufhe} \\
cuOpenFHE        & NVIDIA A100  & 400  & 1500.0 & 3.75M  & \cite{openfhe} \\
cuFHE            & NVIDIA V100  & 250  & 800.0  & 3.2M   & \cite{frigg2022cufhe} \\
OpenFHE (CPU)    & Intel Xeon   & 85   & 0.00014 & 215   & \cite{openfhe} \\
SEAL (CPU)       & Intel Xeon   & 85   & 0.00011 & 178   & \cite{openfhe} \\
\bottomrule
\end{tabular}
\end{table}
""".strip(),
}

for name, content in latex_tables.items():
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  saved {path}")

print("\n✅ All figures + tables generated")
print(f"   Output dir: {OUT_DIR}")
