//=============================================================================
// rescale_rns.sv  —  RNS 系数域 rescale（密推芯 E37 Phase 2，Phase 3 流水化）
//
// 功能：
//   3 个 RNS 分量 (x1, x2, x3) → CRT 合并为单模数整数 x → 居中 → 除以 Δ
//   （四舍五入整数除法）→ 重新分解为 3 个 RNS 分量 (y1, y2, y3)。
//
// 算法（与 Python rns_rescale_coeff 一致，Phase 1 golden 已验证）：
//   x      = CRT(x1,x2,x3) mod M              （CRT 合并）
//   x_c    = x - M  若 x > M/2 否则 x         （居中到 [-M/2, M/2]）
//   y      = round(x_c / Δ)                   （四舍五入，整数除，全程整数）
//   y_i    = y mod p_i                        （重新分解）
//
// 用途：
//   RNS-CKKS 的 rescale 级：同态乘后每个密文系数需要除以 Δ 来恢复尺度。
//   单素数方案用模逆（Δ^{-1} mod q）近似，但 RNS 方案必须在整数域做
//   round(ct/Δ)（CRT 合并到整数后再除），否则跨分量精度损失。
//
// 接口：纯 AXI-Stream 流式（每 cycle 一个系数组的 3 分量并行）
//   - 输入：s_valid/s_ready，3 分量 s_data_p1/p2/p3
//   - 输出：m_valid/m_ready，3 分量 m_data_p1/p2/p3
//   - 延迟：9 cycle（Phase 4 时序收敛后；原 3 cycle，段1 内部再切 6 拍：
//     ① CRT 权重乘法 ② 三路求和 ③ Barrett 模归约（3 级：乘高/乘 M/减法+修正），
//     加原 ④ 居中 ⑤ round_div，段3 mod p_i 拆 2 拍（乘法逆元级A + 减法级B）
//     → 总 9 拍）
//   - 吞吐：1 系数组 / cycle
//   - s_ready 恒 1：本设计位于恒接收流式链路（e2e_rns_top 中 merge 恒接收、
//     pm 输出恒被消费），无反压需求；流水化前后 s_ready 语义不变。
//     m_ready 端口保留（继承原接口），未参与内部控制（与原版一致）。
//
// 参数：
//   P_WIDTH : 素数分量位宽（本设计 42）
//   M_WIDTH : 模数乘积位宽（本设计 115）
//   SCALE   : 尺度因子 Δ（rescale 除数）
//   W1/W2/W3: CRT 权重（与 rns_merge.sv 一致）
//   M       : 模数乘积
//   P1/P2/P3: 三个素数
//
// 流水化正确性（bit-exact 保持）：
//   九段寄存器只是把同一组合函数切片，每拍的输出值 = 9 拍前输入的组合函数值；
//   数据流无重叠/无丢弃（s_ready 恒 1，输入连续时输出连续，仅整体延迟 9 拍）。
//   两级回归（模块 20/20、e2e 玩具 3/3 + 生产 3/3 + M-C 真 RLWE 3/3）验证。
//
// 依赖：无（组合取模/除法）
// 验证：scripts/_e37_rescale_rns_tb.py（与 Python rns_rescale_coeff 一致）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module rescale_rns #(
    parameter int P_WIDTH = 42,
    parameter int M_WIDTH = 115,
    parameter int SCALE   = 1024,          // Δ = 2^10（玩具；生产 2^40 级）
    parameter logic [M_WIDTH-1:0] W1 = 115'h38477b0357aa2be2be3fa0154725f,
    parameter logic [M_WIDTH-1:0] W2 = 115'h47ffffffffa66666662622222222,
    parameter logic [M_WIDTH-1:0] W3 = 115'h287884fcb04d6db6db801dc896b81,
    parameter logic [M_WIDTH-1:0] M  = 115'h6540000007f200000022200000001,
    parameter logic [P_WIDTH-1:0] P1 = 42'd77309411329,
    parameter logic [P_WIDTH-1:0] P2 = 42'd206158430209,
    parameter logic [P_WIDTH-1:0] P3 = 42'd2061584302081,
    // Phase 4 段3 收敛：乘法逆元常数 inv = floor(2^BAR_N / p_i)（黄金模型验证）
    parameter int BAR_N = 107,
    parameter logic [70:0] INV1 = 71'h71c71c71c0ca4587e7,
    parameter logic [69:0] INV2 = 70'h2aaaaaaaa9c71c71c7,
    parameter logic [66:0] INV3 = 67'h44444444441fdb975,
    // Phase 4 段1c Barrett 模归约：MU = floor(2^(2*M_WIDTH) / M)（116-bit，黄金模型验证）
    parameter logic [115:0] MU = 116'hA1D1398552BFAE314025D657B8AD8
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    // 输入流（3 个 RNS 分量并行）
    input  wire logic              s_valid,
    output logic              s_ready,
    input  wire logic [P_WIDTH-1:0] s_data_p1,
    input  wire logic [P_WIDTH-1:0] s_data_p2,
    input  wire logic [P_WIDTH-1:0] s_data_p3,

    // 输出流（3 个 RNS 分量并行）
    output logic              m_valid,
    input  wire logic              m_ready,
    output logic [P_WIDTH-1:0] m_data_p1,
    output logic [P_WIDTH-1:0] m_data_p2,
    output logic [P_WIDTH-1:0] m_data_p3
);

    // ===================== 四舍五入整数除法 =====================
    // round(x/d)：x 为 signed [M_WIDTH:0]，d 为正。
    // 全程整数，避免 float 精度丢失（M ~ 115 bit >> float 53-bit 尾数）。
    function automatic logic signed [M_WIDTH:0] round_div(
        input logic signed [M_WIDTH:0] x,
        input integer d
    );
        logic signed [M_WIDTH:0] half;
        begin
            half = $signed(d) >>> 1;            // d/2
            if (x >= 0) begin
                round_div = (x + half) / d;
            end else begin
                round_div = -(((-x) + half) / d);
            end
        end
    endfunction

    // ===================== 正模（负结果转正）=====================
    // 注意：y 为 signed，p 为 unsigned。混合运算会把 signed 当 unsigned 解释，
    //       负 y 会变成 2^116-|y| 的大正数导致 % 错误。必须显式 $signed 转换。
    function automatic logic [P_WIDTH-1:0] mod_pos(
        input logic signed [M_WIDTH:0] y,
        input logic [P_WIDTH-1:0] p
    );
        logic signed [M_WIDTH:0] r;
        begin
            r = y % $signed({1'b0, p});
            if (r < 0) r = r + $signed({1'b0, p});
            mod_pos = r[P_WIDTH-1:0];
        end
    endfunction

    // ===================== 流水段 1a：CRT 权重乘法（DSP 级联）→ 寄存 =====================
    // Phase 4 时序收敛：原段1（乘法+加法+%M+居中）全组合，80 级逻辑 / 18.7ns。
    //   关键路径实测为 s_data_p1*W1（DSP48E2 级联 prod1__9→12）→ sum → sum%M
    //   （51 级 CARRY8）→ 居中 → xc_reg。此处切成 4 个纯切片子段，每段打一拍：
    //   1a 乘法→寄存、1b 求和→寄存、1c %M→寄存、1d 居中→寄存（原 xc_reg）。
    //   纯切片不改变每拍组合函数值，仅把整体延迟 3→6 拍，bit-exact 必然保持。
    //   乘法结果先打一拍，切断 DSP 级联链与后续加法/取模的长组合路径。
    //   注意：寄存器声明放在组合逻辑之前（"used before declaration" 告警会触发
    //   Vivado 生成次优网表，曾致综合后处理挂起）。
    logic [M_WIDTH+P_WIDTH-1:0] p1r, p2r, p3r;
    logic [M_WIDTH+P_WIDTH+1:0] sum_r;
    logic [M_WIDTH-1:0]         xm_r;
    logic                       v_a, v_b, v_c1, v_c2, v_c3;
    logic                       v1;
    logic signed [M_WIDTH:0]    xc_reg;

    wire [M_WIDTH+P_WIDTH-1:0] prod1 = s_data_p1 * W1;
    wire [M_WIDTH+P_WIDTH-1:0] prod2 = s_data_p2 * W2;
    wire [M_WIDTH+P_WIDTH-1:0] prod3 = s_data_p3 * W3;

    // ===================== 流水段 1b：三路乘积求和 → 寄存 =====================
    wire [M_WIDTH+P_WIDTH+1:0] sum   = p1r + p2r + p3r;

    // ===================== 流水段 1c：Barrett 模归约（3 级流水）=====================
    // Phase 4 时序收敛（2026-11-05）：原 `sum_r % M` 为 158-bit % 115-bit 长除法链
    //   （CARRY8=33，46 级，Data Path 10.558ns = 基线 P&R 关键路径，FINAL_WNS=-0.577ns）。
    //   替换为 Barrett 归约（黄金模型 20万+ 随机+边界 bad=0，maxcorr=1）：
    //     q1 = sum_r[M_WIDTH+P_WIDTH : M_WIDTH-1]        （高段，44-bit）
    //     q2 = q1 * MU                                   （160-bit 全精度，防截断）
    //     q3 = q2 >> (M_WIDTH+1)                         （44-bit）
    //     prod = q3 * M                                  （159-bit 全精度）
    //     r0 = sum_r3 - prod                             （< 2M，无回绕：q3 <= floor(sum_r/M)）
    //     x_merge = (r0 >= M) ? r0 - M : r0              （1 次修正，maxcorr=1）
    //   切成 3 级（段1c1 乘高 / 段1c2 乘 M / 段1c3 减法+修正），每级 <=7ns。
    //   注意：q2/q3 的乘法必须声明全精度位宽，禁止上下文截断（IEEE 1800 §11.6.1，
    //   与段3 qprod 同一教训——截断会致商完全错误）。
    localparam int K = M_WIDTH;                          // 115
    localparam int SUM_WIDTH = M_WIDTH + P_WIDTH + 1;    // 158
    localparam int SHIFT_Q1 = K - 1;                     // 114
    localparam int SHIFT_Q3 = K + 1;                     // 116
    localparam int Q1_WIDTH = SUM_WIDTH - SHIFT_Q1;      // 44
    localparam int MU_WIDTH = 2*K - M_WIDTH + 1;         // 116

    wire [Q1_WIDTH-1:0] q1 = sum_r[SUM_WIDTH-1 : SHIFT_Q1];   // 44-bit 高段
    wire [Q1_WIDTH+MU_WIDTH-1:0] q2 = q1 * MU;                // 160-bit 全精度
    wire [Q1_WIDTH-1:0] q3 = q2[SHIFT_Q3 + Q1_WIDTH - 1 : SHIFT_Q3];  // >>116

    logic [Q1_WIDTH-1:0]        q3bar_r;
    logic [SUM_WIDTH-1:0]       sum_r2, sum_r3;
    logic [Q1_WIDTH+M_WIDTH-1:0] prod_r;

    wire [Q1_WIDTH+M_WIDTH-1:0] prod = q3bar_r * M;               // 44x115 -> 159-bit
    wire [SUM_WIDTH-1:0] r0_full = sum_r3 - prod_r[SUM_WIDTH-1:0];  // <2M，无回绕（prod_r 与 sum_r3 同 stage-1c2 拍对齐）
    wire [M_WIDTH:0]     r0      = r0_full[M_WIDTH:0];        // 低 116-bit
    wire [M_WIDTH:0]     M_ext   = {1'b0, M};                 // 116-bit
    wire [M_WIDTH:0]     r0_corr = (r0 >= M_ext) ? (r0 - M_ext) : r0;
    wire [M_WIDTH-1:0]   x_merge = r0_corr[M_WIDTH-1:0];

    // ===================== 流水段 1d：居中（x > M/2 则 x -= M）→ 寄存 =====================
    wire [M_WIDTH-1:0] half_M = M >> 1;
    wire signed [M_WIDTH:0] x_centered =
        (xm_r > half_M) ? ($signed({1'b0, xm_r}) - $signed({1'b0, M}))
                        :  $signed({1'b0, xm_r});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1r <= '0; p2r <= '0; p3r <= '0;
            sum_r <= '0;
            q3bar_r <= '0; sum_r2 <= '0; prod_r <= '0; sum_r3 <= '0;
            xm_r  <= '0;
            v_a <= 1'b0; v_b <= 1'b0; v_c1 <= 1'b0; v_c2 <= 1'b0; v_c3 <= 1'b0;
            v1  <= 1'b0;
            xc_reg <= '0;
        end else begin
            p1r <= prod1; p2r <= prod2; p3r <= prod3;
            v_a <= s_valid;
            sum_r <= sum;
            v_b <= v_a;
            // 段1c1：Barrett 乘高
            q3bar_r <= q3; sum_r2 <= sum_r;
            v_c1 <= v_b;
            // 段1c2：Barrett 乘 M
            prod_r <= prod; sum_r3 <= sum_r2;
            v_c2 <= v_c1;
            // 段1c3：减法 + 1 次修正
            xm_r <= x_merge;
            v_c3 <= v_c2;
            v1 <= v_c3;
            xc_reg <= x_centered;
        end
    end

    // ===================== 流水段 2：四舍五入除以 Δ =====================
    wire signed [M_WIDTH:0] y = round_div(xc_reg, SCALE);

    logic                       v2;
    logic signed [M_WIDTH:0]    y_reg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v2    <= 1'b0;
            y_reg <= '0;
        end else begin
            v2    <= v1;
            y_reg <= y;
        end
    end

    // ===================== 流水段 3：重新分解（mod p_i）+ 输出寄存 =====================
    // Phase 4 时序收敛：原 `mod_pos(y_reg, P_i)` 是 116-bit signed % 42-bit 的
    //   长除法链（CARRY8=29，Data Path 11.67ns 是关键路径）。替换为乘法逆元法：
    //   y_abs = |y_reg|（105-bit，因 |y| < M/2/SCALE < 2^105）
    //   q     = (y_abs * INV_i) >> BAR_N      （INV_i = floor(2^BAR_N / P_i)，常数乘法走 DSP）
    //   r     = y_abs - q * P_i，修正（最多 2 次）
    //   负 y 补正：r = (-r) mod P_i
    //   拆两级：级A 乘法逆元算商 → 寄存；级B 减法+修正+符号 → 输出寄存。
    //   每级深度减半，bit-exact 保持（黄金模型 _mod_pos_mulinv_golden.py 20万x3 验证）。
    //   总延迟：6 拍 → 7 拍（段3 由 1 拍变 2 拍）。

    // y 取绝对值（115-bit 无符号；y_reg 符号位为 bit[M_WIDTH]）。
    // 注意：|y| < M/2/SCALE < 2^105 << 2^114，故负 y 用按位取反+1 求补，
    //       结果高位（bit[114:105]）恒为 0，数值正确（不能用 - 运算，会溢出）。
    wire [M_WIDTH-1:0] y_neg = ~y_reg[M_WIDTH-1:0] + 1'b1;
    wire [M_WIDTH-1:0] y_abs = y_reg[M_WIDTH] ? y_neg : y_reg[M_WIDTH-1:0];

    // ---- 级 A：q_i = (y_abs * INV_i) >> BAR_N ----
    // 关键修正（2026-11-02 定位）：y_abs(115) * INV_i(≤71) 必须全精度乘法。
    //   直接写 `(y_abs * INV1) >> BAR_N` 会被 q1_wide 的 115-bit 上下文截断
    //   成低 115 位乘积（IEEE 1800 §11.6.1 上下文尺寸规则），右移 107 后商
    //   完全错误（实测 _diag_seg3.py H2 20000/20000 错；xsim 4096/4096
    //   mismatch，r0 高估 >2*P 需 >2 次修正、且 r0 回绕）。
    //   改用 186-bit 中间线网强制全精度（H1 黄金模型 bad=0，bit-exact）。
    wire [M_WIDTH+70:0] qprod1 = y_abs * INV1;   // 115+71=186-bit 全精度
    wire [M_WIDTH+70:0] qprod2 = y_abs * INV2;
    wire [M_WIDTH+70:0] qprod3 = y_abs * INV3;
    wire [M_WIDTH-1:0] q1_wide = qprod1 >> BAR_N;   // 69-bit 商，高位填充
    wire [M_WIDTH-1:0] q2_wide = qprod2 >> BAR_N;
    wire [M_WIDTH-1:0] q3_wide = qprod3 >> BAR_N;

    logic [M_WIDTH-1:0] q1r, q2r, q3r;
    logic               v3a, v3b;
    // 关键对齐修正（2026-11-02 定位）：y1_f 同时依赖 y_reg(段2, 系数 k) 与
    //   q1r(段3A, 系数 k-1)。背靠背连续输入（e2e 里 pm 连续输出 N 系数）时两者
    //   错位 1 拍 → y1_f = f(y_k, q_{k-1}) 全错（xsim 4095/4096 mismatch，恰 1 个
    //   巧合匹配 = 1 拍错位签名）。独立探针逐个驱动掩盖了此错位（管线仅 1 系数在飞）。
    //   修复：把 y_abs 与符号位也放进段3A 寄存，段3B 只用同拍对齐的
    //   y_abs_r / q1r / y_neg_r。
    logic [M_WIDTH-1:0] y_abs_r;
    logic               y_neg_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1r <= '0; q2r <= '0; q3r <= '0;
            y_abs_r <= '0; y_neg_r <= 1'b0;
            v3a <= 1'b0;
        end else begin
            q1r <= q1_wide; q2r <= q2_wide; q3r <= q3_wide;
            y_abs_r <= y_abs; y_neg_r <= y_reg[M_WIDTH];
            v3a <= v2;
        end
    end

    // ---- 级 B：r_i = y_abs_r - q_i*P_i，修正（最多 2 次）----
    // 注意：q_i 实际 69-bit，P_i 42-bit，乘积 < 2^111；y_abs_r 105-bit。
    // r_i 值域 [0, 2*P_i)，一次修正足够（兜底 2 次）。
    wire [M_WIDTH-1:0] bprod1 = q1r * P1;
    wire [M_WIDTH-1:0] bprod2 = q2r * P2;
    wire [M_WIDTH-1:0] bprod3 = q3r * P3;
    wire [M_WIDTH-1:0] r0_1 = y_abs_r - bprod1;
    wire [M_WIDTH-1:0] r0_2 = y_abs_r - bprod2;
    wire [M_WIDTH-1:0] r0_3 = y_abs_r - bprod3;
    wire [M_WIDTH-1:0] r1_1 = (r0_1 >= P1) ? (r0_1 - P1) : r0_1;
    wire [M_WIDTH-1:0] r1_2 = (r0_2 >= P2) ? (r0_2 - P2) : r0_2;
    wire [M_WIDTH-1:0] r1_3 = (r0_3 >= P3) ? (r0_3 - P3) : r0_3;
    wire [M_WIDTH-1:0] r2_1 = (r1_1 >= P1) ? (r1_1 - P1) : r1_1;
    wire [M_WIDTH-1:0] r2_2 = (r1_2 >= P2) ? (r1_2 - P2) : r1_2;
    wire [M_WIDTH-1:0] r2_3 = (r1_3 >= P3) ? (r1_3 - P3) : r1_3;

    // 符号补正：负 y 时 r = (-r) mod P_i（即 P_i - r，若 r!=0）
    wire [P_WIDTH-1:0] y1_f = y_neg_r ? ((r2_1 == '0) ? '0 : (P1 - r2_1[P_WIDTH-1:0])) : r2_1[P_WIDTH-1:0];
    wire [P_WIDTH-1:0] y2_f = y_neg_r ? ((r2_2 == '0) ? '0 : (P2 - r2_2[P_WIDTH-1:0])) : r2_2[P_WIDTH-1:0];
    wire [P_WIDTH-1:0] y3_f = y_neg_r ? ((r2_3 == '0) ? '0 : (P3 - r2_3[P_WIDTH-1:0])) : r2_3[P_WIDTH-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid   <= 1'b0;
            m_data_p1 <= '0;
            m_data_p2 <= '0;
            m_data_p3 <= '0;
            v3b      <= 1'b0;
        end else begin
            m_valid   <= v3a;
            m_data_p1 <= y1_f;
            m_data_p2 <= y2_f;
            m_data_p3 <= y3_f;
            v3b      <= v3a;
        end
    end

    assign s_ready = 1'b1;

endmodule
