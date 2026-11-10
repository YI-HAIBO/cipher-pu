//=============================================================================
// rns_merge.sv  —  RNS 合并（CRT，密推芯 E37 Phase 2）
//
// 功能：
//   3 个 RNS 分量 (x1, x2, x3) → 单模数系数 x = CRT(x1, x2, x3) mod M
//
// 算法（CRT 标准）：
//   x = Σ (x_i * w_i) mod M,  w_i = M_i * T_i,  M_i = M/p_i,  T_i = M_i^{-1} mod p_i
//   验证：w_i mod p_j = 1 (i==j), 0 (i≠j)
//
// 用途：
//   RNS CKKS 的合并级：把 3 个素数分量的运算结果 CRT 合并回单模数域，
//   供 rescale 使用（系数域整数除 Δ → 重新分解）。
//
// 接口：纯 AXI-Stream 流式（无帧控制）
//   - 输入：s_valid/s_ready，3 个分量并行（s_data_p1/p2/p3）
//   - 输出：m_valid/m_ready，单模数系数（m_data，M_WIDTH bit）
//   - 延迟：3 cycle
//       第 1 cycle: 乘法 + 求和（s_data_pi * W_i → sum）
//       第 2 cycle: Barrett 第 1 拍 q = floor(sum_r * MU / 2^K)
//       第 3 cycle: Barrett 第 2 拍 r = sum_r - q*M（一次条件减）→ 输出
//
// 参数：
//   P_WIDTH : 素数分量位宽（max bit length of p_i，本设计 42）
//   M_WIDTH : 模数 M 的位宽（本设计 115）
//   W1, W2, W3 : CRT 权重（预计算，各约 115 bit）
//   M      : 模数乘积（115 bit）
//   MU     : Barrett 倒数 = floor(2^K / M)，K = ACC_WIDTH+2 = 159，45 bit
//            （必须与 M 配套；本设计 M 为固定常数）
//
// 依赖：无（乘法 + 加法 + Barrett 取模）
// 验证：scripts/tb_rns_merge.py（与 Python rns_decode 一致）
//
// 2026-11-06 修改（M-D' 时序收敛，rtl-designer 葛逻辑）：
//   原实现 `result = sum_r % M` 为行为级大组合除法（159-bit % 115-bit），
//   综合为 46 级（CARRY8=34）串行减法链，P&R 关键路径 10.387ns → WNS -0.415ns
//   （20 个违例端点全部来自这一条取模路径，DSP 级联链违例已在前轮修复）。
//   改用 Barrett 约减（2 级流水 + 1 级寄存器分隔），每级仅 1 次常数乘 +
//   加法/条件减，深度大幅下降，bit-exact 保持（Python 位精确验证 20 万随机）。
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module rns_merge #(
    parameter int P_WIDTH = 42,
    parameter int M_WIDTH = 115,
    parameter int ACC_WIDTH = M_WIDTH + P_WIDTH,  // 157 bit（中间累加）
    parameter logic [M_WIDTH-1:0] W1 = 115'h38477b0357aa2be2be3fa0154725f,
    parameter logic [M_WIDTH-1:0] W2 = 115'h47ffffffffa66666662622222222,
    parameter logic [M_WIDTH-1:0] W3 = 115'h287884fcb04d6db6db801dc896b81,
    parameter logic [M_WIDTH-1:0] M  = 115'h6540000007f200000022200000001,
    // Barrett 倒数 mu = floor(2^159 / M)，45 bit（必须与 M 配套）
    parameter logic [44:0] MU = 45'h143a2730aa57
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    // 输入流（3 个 RNS 分量并行）
    input  wire logic              s_valid,
    output logic              s_ready,
    input  wire logic [P_WIDTH-1:0] s_data_p1,
    input  wire logic [P_WIDTH-1:0] s_data_p2,
    input  wire logic [P_WIDTH-1:0] s_data_p3,

    // 输出流（单模数系数）
    output logic              m_valid,
    input  wire logic              m_ready,
    output logic [M_WIDTH-1:0] m_data
);

    // 内部宽度
    localparam int SUM_WIDTH = ACC_WIDTH + 2;   // 159 bit（sum/sum_r 宽）
    localparam int QW        = 45;              // q 的位宽（t_max = 45 bit）
    localparam int K         = SUM_WIDTH;       // Barrett 右移位数 = 159

    // 第 1 级：乘法 + 求和（组合）
    // 中间宽度 = M_WIDTH + P_WIDTH（两个最宽输入相乘）
    wire [ACC_WIDTH-1:0] prod1 = s_data_p1 * W1;
    wire [ACC_WIDTH-1:0] prod2 = s_data_p2 * W2;
    wire [ACC_WIDTH-1:0] prod3 = s_data_p3 * W3;
    wire [SUM_WIDTH-1:0] sum   = prod1 + prod2 + prod3;

    // 第 1 级寄存器
    logic [SUM_WIDTH-1:0] sum_r;
    logic                 s_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_r      <= '0;
            s_valid_r  <= 1'b0;
        end else begin
            sum_r      <= sum;
            s_valid_r  <= s_valid;
        end
    end

    // === Barrett 第 1 拍：q = floor(sum_r * MU / 2^K) ===
    // sum_r (159b) * MU (45b) → 204b；右移 K=159 位取高 45 bit。
    // 已验证：q ∈ {t-1, t}，t = floor(sum_r / M)。
    wire [SUM_WIDTH+QW-1:0] qwide = sum_r * MU;
    wire [QW-1:0] q = qwide[K +: QW];

    logic [QW-1:0] q_r;
    logic [SUM_WIDTH-1:0] sum_r2;   // 与 q_r 同拍对齐（背靠背流关键）
    logic          s_valid_r2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_r        <= '0;
            sum_r2     <= '0;
            s_valid_r2 <= 1'b0;
        end else begin
            q_r        <= q;
            sum_r2     <= sum_r;      // 与 q 同源、同拍 → r0 用它
            s_valid_r2 <= s_valid_r;
        end
    end

    // === Barrett 第 2 拍：r0 = sum_r2 - q_r * M，一次条件减 ===
    // q_r (45b) * M (115b) → 160b；q_r, sum_r2 同拍对齐（同一系数）。
    // 因 q_r ≤ t ⇒ q_r*M ≤ sum_r2 ⇒ r0 ≥ 0。已验证：r0 ∈ [0, 2M)。
    wire [QW+M_WIDTH-1:0] qM = q_r * M;
    wire [SUM_WIDTH:0] r0 = sum_r2 - qM[SUM_WIDTH-1:0];
    wire [M_WIDTH-1:0] result = (r0 >= M) ? (r0 - M) : r0;

    // 第 3 级寄存器（输出）——valid 链同步补到 3 拍，与 m_data 对齐
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_data  <= '0;
        end else begin
            m_valid <= s_valid_r2;
            m_data  <= result;
        end
    end

    assign s_ready = 1'b1;

endmodule
