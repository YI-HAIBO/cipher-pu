//=============================================================================
// ntt_butterfly_test.sv  —  测试用蝴蝶单元（支持任意素数 q）
//
// 功能：
//   输入：a, b, omega
//   输出：a' = (a + b*omega) mod q, b' = (a - b*omega) mod q
//
// 与 ntt_butterfly.sv 的区别：
//   - 支持任意素数 q（不仅是 2^Q_WIDTH）
//   - 组合逻辑（无流水），便于测试
//   - 使用 Q_VALUE 参数定义模数
//
// 用途：M1 测试 NTT 正确性，验证通过后集成 M1 乘法器
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module ntt_butterfly_test #(
    parameter int Q_WIDTH = 7,
    parameter logic [Q_WIDTH-1:0] Q_VALUE = 113     // 素数模数
) (
    input  logic              clk,
    input  logic              rst_n,

    // 输入
    input  logic [Q_WIDTH-1:0] a_in,
    input  logic [Q_WIDTH-1:0] b_in,
    input  logic [Q_WIDTH-1:0] omega,
    input  logic              valid,

    // 输出（1 cycle 延迟，同步输出）
    output logic [Q_WIDTH-1:0] a_out,
    output logic [Q_WIDTH-1:0] b_out,
    output logic              valid_out
);

    // =========================================================================
    // 组合逻辑计算
    // =========================================================================
    // 乘法：b * omega
    wire [2*Q_WIDTH-1:0] prod_raw = b_in * omega;
    
    // 取模：(b * omega) mod q
    // 对于小 q，可以用循环减法或硬件除法器
    // M1 简化：用 Verilog 的 % 运算符（综合时需自定义）
    wire [Q_WIDTH-1:0] prod_q = prod_raw % Q_VALUE;

    // a' = (a + prod_q) mod q
    // 注意：必须先对完整加法结果取模，不能先截断到 Q_WIDTH bit
    // 因为 a + prod_q 可能 >= Q_VALUE（例如 81+94=175, 175 mod 113=62，但 175&127=47）
    wire [Q_WIDTH:0] sum_ext = {1'b0, a_in} + {1'b0, prod_q};
    wire [Q_WIDTH:0] a_prime_full = sum_ext % Q_VALUE;
    wire [Q_WIDTH-1:0] a_prime = a_prime_full[Q_WIDTH-1:0];

    // b' = (a - prod_q) mod q = (a + q - prod_q) mod q
    wire [Q_WIDTH-1:0] q_minus_prod = Q_VALUE - prod_q;
    wire [Q_WIDTH:0] diff_ext = {1'b0, a_in} + {1'b0, q_minus_prod};
    wire [Q_WIDTH:0] b_prime_full = diff_ext % Q_VALUE;
    wire [Q_WIDTH-1:0] b_prime = b_prime_full[Q_WIDTH-1:0];

    // =========================================================================
    // 输出寄存（1 cycle 延迟）
    // =========================================================================
    logic [Q_WIDTH-1:0] a_out_reg, b_out_reg;
    logic               valid_out_reg;

    always_ff @(posedge clk or negedge rst_n) begin
    // LINT-L7: async reset: testbench (not synthesized)
        if (!rst_n) begin
            a_out_reg     <= '0;
            b_out_reg     <= '0;
            valid_out_reg <= 1'b0;
        end else begin
            a_out_reg     <= a_prime;
            b_out_reg     <= b_prime;
            valid_out_reg <= valid;
        end
    end

    assign a_out     = a_out_reg;
    assign b_out     = b_out_reg;
    assign valid_out = valid_out_reg;

endmodule
