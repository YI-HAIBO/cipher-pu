//=============================================================================
// ntt_butterfly.sv  —  单蝴蝶单元（密推芯 M1 Phase 3，生产版，素数模）
//
// 功能：
//   输入：a, b（两个多项式系数）+ omega（twiddle 因子）
//   输出：a' = (a + b*omega) mod q,  b' = (a - b*omega) mod q
//
// 实现：
//   复用 M1 mult_43x43_horner4（Horner 4-DSP，WIDTH 可参数化）
//   模运算：先对完整乘积取模，再对完整加法结果取模（禁止先截断！）
//   3-cycle 延迟（乘法器 1 cycle + 流水 1 cycle + 输出寄存 1 cycle）（乘法器 1 cycle 输出寄存 + 蝴蝶 1 cycle 输出寄存）
//
// 与旧版的关键差异（Phase 3 修复）：
//   旧版: prod_q = prod_raw[Q_WIDTH-1:0];  // 截断，仅支持 q = 2^Q_WIDTH
//   新版: prod_q = prod_raw % Q_VALUE;     // 素数模，CKKS 必需
//   旧版: neg_prod = ~prod_q + 1;          // 仅 q = 2^Q_WIDTH 成立
//   新版: q_minus_prod = Q_VALUE - prod_q; // 通用
//
// M2-a fast-red 集成（V3.0）：
//   新增 USE_FASTRED 参数。当 USE_FASTRED=1 且 Q_WIDTH=45、q=2^44+c 时，
//   prod_raw → prod_q 改用 mod45_fastred（0 DSP，纯 CARRY8）；
//   a_prime / b_prime 用单次条件减代替 %。
//   USE_FASTRED=0（默认）保留原始 `%` 路径，M1 回归完全不变。
//
// Task #70（2026-10-08）：流水寄存器（prod_q_r / valid_pipe_r）
//   在 fastred 取模后插入 1 级流水线，拆分关键路径：
//   原 49 级逻辑 / 12.422 ns -> 两段 ~33 级 + ~16 级
//   延迟从 2 cycles 增至 3 cycles，ntt_unit wait_cnt 2->3
//
// 参数化：
//   Q_WIDTH : 系数位宽（CKKS 常用 43~60）
//   Q_VALUE : 素数模数（必须满足 2^LOG_N | Q_VALUE - 1）
//   HI_W/LO_W : Horner 分解段（HI_W + LO_W == Q_WIDTH）
//   USE_FASTRED : 1 = 用 mod45_fastred（要求 Q_WIDTH=45 且 q=2^44+c）
//                 0 = 用 `%` 运算符（通用）
//
// 接口：AXI-Stream 风格 valid/ready
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module ntt_butterfly #(
    parameter int Q_WIDTH = 43,
    parameter logic [Q_WIDTH-1:0] Q_VALUE = '0,   // M2-a: int → logic 支持 45 bit 模数
    parameter int HI_W    = 24,         // 高位段
    parameter int LO_W    = 19,         // 低位段（HI_W + LO_W == Q_WIDTH）
    parameter bit INVERSE = 0,          // 预留（当前由外部提供 omega 决定）
    parameter bit USE_FASTRED = 0       // M2-a：1 启用 mod45_fastred
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    // 输入：2 个系数 + twiddle 因子
    input  wire logic              s_valid,
    input  wire logic [Q_WIDTH-1:0] s_a,
    input  wire logic [Q_WIDTH-1:0] s_b,
    input  wire logic [Q_WIDTH-1:0] s_omega,
    output logic              s_ready,

    // 输出：2 个变换后系数
    output logic              m_valid,
    output logic [Q_WIDTH-1:0] m_a,   // a' = (a + b*omega) mod q
    output logic [Q_WIDTH-1:0] m_b,   // b' = (a - b*omega) mod q
    input  wire logic              m_ready
);

    // =========================================================================
    // 1. 乘法器实例（Horner 4-DSP，WIDTH 参数化）
    //    s_valid 到 m_valid 延迟 1 cycle（含 1 级输出寄存）
    // =========================================================================
    wire [2*Q_WIDTH-1:0] prod_raw;
    wire mult_valid;
    wire mult_ready;

    mult_43x43_horner4 #(
        .WIDTH(Q_WIDTH),
        .HI_W(HI_W),
        .LO_W(LO_W),
        .PIPE_OUT(1)
    ) u_mult (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(s_valid),
        .s_a(s_b),          // 第一个操作数 = b
        .s_b(s_omega),      // 第二个操作数 = omega
        .s_ready(mult_ready),
        .m_valid(mult_valid),
        .m_p(prod_raw),     // 2*Q_WIDTH bit 原始乘积
        .m_ready(1'b1)      // 下游无条件接收
    );

    // =========================================================================
    // 2. 模运算（两条路径由 USE_FASTRED 选择）
    //    关键：对完整结果取模，禁止先截断到位宽再取模
    //    例：a=81, b*omega mod q=94, q=113
    //      sum = 81+94 = 175 -> 175 mod 113 = 62  (正确)
    //      若先截断: 175 & 127 = 47 (错误!)
    // =========================================================================

    wire [Q_WIDTH-1:0] prod_q;
    wire [Q_WIDTH-1:0] a_prime;
    wire [Q_WIDTH-1:0] b_prime;

    // =========================================================================
    // 2a. Task #70: 流水寄存器（fastred 后插 1 级，拆分关键路径）
    //      P&R 关键路径：p_reg -> fastred(33 CARRY8) -> add/sub(16 LUT) -> out_reg
    //      插入 prod_q_r / valid_pipe_r 后拆为两段：~33 级 + ~16 级
    // =========================================================================
    logic [Q_WIDTH-1:0] prod_q_r;
    logic               valid_pipe_r;

    always_ff @(posedge clk or negedge rst_n) begin
    // LINT-L7: async reset: fast reset for butterfly (pre-M5)
        if (!rst_n) begin
            prod_q_r     <= '0;
            valid_pipe_r <= 1'b0;
        end else begin
            prod_q_r     <= prod_q;
            valid_pipe_r <= mult_valid;
        end
    end

    generate
        if (USE_FASTRED) begin : g_fastred
            // M2-a fast-red 路径
            //   prod_raw (90 bit) → prod_q (45 bit)  通过 mod45_fastred
            //   a_prime / b_prime 通过单次条件减（prod_q_r < q 已保证）
            //   数学前提：q = 2^44 + c，c = 2^17 + 1（本项目的 q=17592186175489）
            //   验证：scripts/_verify_fastred.py（100,024 例 0 失败）
            //        + tb/tb_mod45_fastred.sv（1,026 例 100% PASS）
            mod45_fastred #(
                .WIDTH(Q_WIDTH),
                .Q_VALUE(Q_VALUE),
                .K(44),
                .SHIFT(2*Q_WIDTH),
                .PIPE(0)                       // E49: 蝴蝶保持纯组合（本模块在 NTT 流水线内）
            ) u_fastred (
                .clk(1'b0),                    // PIPE=0 不使用时钟
                .x(prod_raw),
                .r(prod_q)
            );

            // a' = (a + prod_q) mod q
            //    prod_q < q 且 s_a < q，故 sum < 2q，单次条件减即可
            wire [Q_WIDTH:0]   sum_ext_fr  = {1'b0, s_a} + {1'b0, prod_q_r};
            wire [Q_WIDTH:0]   q_wide_fr   = {1'b0, Q_VALUE};
            wire               sum_ge_q_fr = (sum_ext_fr >= q_wide_fr);
            wire [Q_WIDTH:0]   sum_red_fr  = sum_ext_fr - q_wide_fr;
            assign a_prime = sum_ge_q_fr ? sum_red_fr[Q_WIDTH-1:0] : sum_ext_fr[Q_WIDTH-1:0];

            // b' = (a - prod_q) mod q = (a + (q - prod_q)) mod q
            //    prod_q < q 故 q - prod_q >= 1，无下溢；和仍 < 2q
            wire [Q_WIDTH-1:0] q_minus_prod_fr = Q_VALUE - prod_q_r;
            wire [Q_WIDTH:0]   diff_ext_fr     = {1'b0, s_a} + {1'b0, q_minus_prod_fr};
            wire               diff_ge_q_fr    = (diff_ext_fr >= q_wide_fr);
            wire [Q_WIDTH:0]   diff_red_fr     = diff_ext_fr - q_wide_fr;
            assign b_prime = diff_ge_q_fr ? diff_red_fr[Q_WIDTH-1:0] : diff_ext_fr[Q_WIDTH-1:0];
        end else begin : g_pct
            // 原始 `%` 路径（通用，兼容 M1 的 7-bit q=113 测试）
            // prod_q = (b * omega) mod q
            assign prod_q = prod_raw[2*Q_WIDTH-1:0] % Q_VALUE;

            // a' = (a + prod_q) mod q
            wire [Q_WIDTH:0]   sum_ext      = {1'b0, s_a} + {1'b0, prod_q_r};
            wire [Q_WIDTH:0]   a_prime_full = sum_ext % Q_VALUE;
            assign a_prime      = a_prime_full[Q_WIDTH-1:0];

            // b' = (a - prod_q) mod q = (a + (q - prod_q)) mod q
            wire [Q_WIDTH-1:0] q_minus_prod = Q_VALUE - prod_q_r;
            wire [Q_WIDTH:0]   diff_ext     = {1'b0, s_a} + {1'b0, q_minus_prod};
            wire [Q_WIDTH:0]   b_prime_full = diff_ext % Q_VALUE;
            assign b_prime      = b_prime_full[Q_WIDTH-1:0];
        end
    endgenerate

    // =========================================================================
    // 3. 输出寄存（1 cycle，总延迟 3 cycles，Task #70 流水化后）
    // =========================================================================
    logic [Q_WIDTH-1:0] a_out_reg;
    logic [Q_WIDTH-1:0] b_out_reg;
    logic               valid_out_reg;

 // LINT-L7: async reset: fast reset for butterfly (pre-M5)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out_reg     <= '0;
            b_out_reg     <= '0;
            valid_out_reg <= 1'b0;
        end else begin
            a_out_reg     <= a_prime;
            b_out_reg     <= b_prime;
            valid_out_reg <= valid_pipe_r;
        end
    end

    assign m_a     = a_out_reg;
    assign m_b     = b_out_reg;
    assign m_valid = valid_out_reg;

    // =========================================================================
    // 4. 握手信号
    //    s_ready: 乘法器可接收且下游无背压
    // =========================================================================
    assign s_ready = mult_ready && m_ready;

endmodule

`default_nettype wire
