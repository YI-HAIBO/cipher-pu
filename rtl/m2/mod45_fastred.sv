//=============================================================================
// mod45_fastred.sv  —  90 bit 输入 / 45 bit 常数模的快速归约（q = 2^44 + c 形式）
//
// 用途：给 M2 规模可行性分析做「取模的低成本替代」实测探针。
//       生产 RTL 用 ntt_butterfly 里的 `prod_raw % Q_VALUE`；本模块证明
//       换成快速归约之后，单蝴蝶的 LUT 大幅下降且不额外吃 DSP，从而改变
//       并行度上限（原 P=64 判定为不可行）。
//
// 数学（已由 scripts/_verify_fastred.py 全量校验，100024 例 0 失败）：
//   前提：q = 2^44 + c，其中 c = q - 2^44 = 131073 = 2^17 + 1，且 x < 2^90
//     2^44 ≡ -c (mod q)
//
//     round 1 :  x = xh*2^44 + xl  →  r1 = xl - xh*c          (46 x 18)
//     split   :  r1 = h1*2^44 + l1 (Euclidean, h1 <= 0, 0<=l1<2^44)
//     round 2 :  r2 = l1 + (-h1)*c                           (20 x 18)
//     round 3 :  r2 = h2*2^44 + l2 (h2 ∈ {0,1}!) → r3 = l2 - h2*c
//     final   :  r  = r3 < 0 ? r3 + q : r3
//
//   因为 r3 ∈ (-c, 2^44) 且 2^44 < q，所以 r3 < q 恒成立，最终只需一次 +q、
//   永远不需要 -q。这一点与上一版 Barrett 的「3 次条件减」不同，是关键的
//   时序简化。
//
//   则 r == x % q  （精确，无例外）
//
// 与上一版 Barrett 的差别（也是本模块的全部价值）：
//   1. Barrett 的乘法是 45 x 46（91 bit 结果），单个 DSP48E2 只能吃 27 x 18，
//      于是被拆成 4~6 个 DSP，实测 25 DSP / 数据路径 17.4 ns。
//      本模块最大乘法是 46 x 18（64 bit 结果），且第三轮乘法退化成 1 bit
//      选择器，理论上 3 DSP 就够。
//   2. 更关键：c = 131073 = 2^17 + 1，所以「乘 c」= 「左移 17 位后加自身」。
//      本模块据此把两处乘法都写成移位+加法，**归约本身 0 DSP**，纯 CARRY8
//      实现。乘法器本体的 8 个 DSP 保持不变。
//   3. 上一版踩过的坑（V = floor(2^90/q) 是 46 bit 不是 45 bit）在这里不存在：
//      所有中间量的位宽都由 _verify_fastred.py 的断言逐条钉死。
//
// 实现注意（仿真时踩过的坑）：
//   所有中间量用 `wire` + `assign` 显式驱动，**不要**写成
//   `logic xh = expr;` 这种模块级变量初始化——综合器能接受，但 xsim 对
//   变量驱动的连续更新语义不稳，会整棵读出全 X。
//
// 端口：纯组合，无时钟（便于综合时隔离出归约本身的开销）
//   PIPE=1 时需接 clk：在 round-1（r1 = xl - xh*c）后插一拍流水线寄存器，
//   把 30 级 CARRY8 链劈成两半（E49，2026-10-25）。
//   PIPE=0（默认）保持纯组合，ntt_butterfly 等现有实例行为完全不变。
//=============================================================================

`timescale 1ns / 1ps

module mod45_fastred #(
    parameter int WIDTH = 45,
    parameter logic [WIDTH-1:0] Q_VALUE = 45'd17592186175489,
    parameter int K     = 44,                    // 2^K <= Q < 2^(K+1)
    parameter int SHIFT = 90,                    // = 2*WIDTH
    parameter int PIPE  = 0                      // 0=纯组合（默认）, 1=round-1 后插拍
) (
    input  wire logic               clk,         // PIPE=1 时使用；PIPE=0 时接 1'b0 即可
    input  wire logic [SHIFT-1:0]   x,           // 90 bit 输入
    output wire logic [WIDTH-1:0]   r            // x mod Q
);

    // c = q - 2^44 = 131073 = 2^17 + 1  →  乘 c 退化为移位+加法
    localparam int SC = 17;
    localparam logic [17:0] C_VALUE = 18'd131073;

    // ============ round 1 : p1 = xh * c = (xh << 17) + xh ===============
    wire [45:0]  xh = x[SHIFT-1 : K];            // 46 bit
    wire [K-1:0] xl = x[K-1 : 0];                // 44 bit

    // xh<<17 是 63 bit，加回 xh 最多 64 bit（实测最大 63 bit）
    // 注意：拼接宽度必须写字面常量，Vivado 不接受 parameter 名作基数后缀
    wire [64:0]  p1 = {xh, 17'b0} + {19'b0, xh};

    // r1 = xl - p1，可负，需要 65 bit 有符号
    // 注意：两个操作数必须补齐到同一宽度再相减，否则宽端会截掉符号位
    wire signed [64:0] r1_comb = {21'b0, xl} - p1;

    // ============ E49（2026-10-25）：round-1 流水线寄存器 ============
    //   PIPE=1 时把 30 级 CARRY8 链在 round-1 处劈开：
    //     段1（prod_r → r1_pipe）：p1 加法链 + r1 减法链 ≈ 16 级
    //     段2（r1_pipe → BRAM）：round2/3 + final ≈ 14 级
    //   流水线寄存器常拍更新（乱序数据由调用方 wr_en 门控丢弃），
    //   输出延迟 1 拍，调用方（poly_mult）相应把写地址/写使能再延 1 拍。
    wire signed [64:0] r1;

    generate
    if (PIPE) begin : g_r1_pipe
        logic signed [64:0] r1_pipe;
        always_ff @(posedge clk) begin
            r1_pipe <= r1_comb;
        end
        assign r1 = r1_pipe;
    end
    else begin : g_r1_comb
        assign r1 = r1_comb;
    end
    endgenerate

    // Euclidean 在 bit K 处拆分：
    //   h1 = floor(r1 / 2^44)（算术右移），l1 = r1 的低 44 位
    // r1 < 2^44 恒成立（xl < 2^44 且 p1 >= 0），所以 h1 <= 0 恒成立
    wire signed [20:0] h1 = r1 >> K;             // 21 bit 有符号，h1 <= 0
    wire [K-1:0]       l1 = r1[K-1:0];           // 44 bit，0 <= l1 < 2^44

    // ============ round 2 : p2 = (-h1) * c = (m1 << 17) + m1 ============
    wire [20:0]  m1 = -h1;                       // h1 <= 0 → m1 >= 0（<= 524249）
    wire [39:0]  p2 = {m1, 17'b0} + {18'b0, m1}; // 实测最大 36 bit

    // r2 = l1 + p2，恒非负；l1 < 2^44, p2 < 2^37 → r2 < 2^45
    wire [K:0]   r2 = {1'b0, l1} + {5'b0, p2};   // 45 bit

    // ============ round 3 : h2 只有 1 bit，乘 c 退化成选择器 =============
    wire         h2 = r2[K];                     // ∈ {0, 1}
    wire [K-1:0] l2 = r2[K-1:0];                 // 44 bit
    wire [17:0]  p3 = h2 ? C_VALUE : 18'd0;      // 无需乘法器

    wire signed [44:0] r3 = {1'b0, l2} - {26'b0, p3};

    // ============ final : r3 < q 恒成立，只需一次 +q =====================
    // r3 ∈ (-c, 2^44)；r3 + q < q + c < 2^45，且 r3 < 2^44 < q，
    // 所以 r3 恒小于 q，只有负值需要 +q（见模块头证明）
    assign r = r3[WIDTH-1] ? r3[WIDTH-1:0] + Q_VALUE
                           : r3[WIDTH-1:0];

endmodule
