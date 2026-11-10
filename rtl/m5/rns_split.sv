//=============================================================================
// rns_split.sv  —  RNS 分解（密推芯 E37 Phase 2）
//
// 功能：
//   单模数系数 x → 3 个 RNS 分量：x_i = x mod p_i
//   对 3 个 NTT 友好素数 p1/p2/p3 分别取模。
//
// 用途：
//   RNS CKKS 的输入级：把单模数域（或更大域）的系数分解为各素数分量的
//   RNS 表示，供后续各分量独立执行 NTT/点乘/INTT。
//
// 算法：
//   x_i = x mod p_i（组合取模）
//   注意：输入按无符号处理（[0, 2^Q_IN_WIDTH-1]）。
//   若上游为居中表示（有符号），先由上层映射到无符号域。
//
// 接口：纯 AXI-Stream 流式（无帧控制，帧边界由上层负责）
//   - 输入：s_valid/s_ready/s_data（单模数系数）
//   - 输出：m_valid/m_ready/m_data_p1/p2/p3（3 个 RNS 分量并行）
//   - 延迟：1 cycle（输入寄存 + 组合取模 → 输出寄存）
//   - 吞吐：1 coefficient / cycle（背靠背）
//
// 参数：
//   Q_IN_WIDTH : 输入系数位宽（单模数域，通常 45~115 bit）
//   P_WIDTH    : 素数分量位宽（max bit length of p_i）
//   P1, P2, P3 : 三个素数模数
//
// 依赖：无
// 验证：scripts/tb_rns_split.py（与 Python rns 分解一致）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module rns_split #(
    parameter int Q_IN_WIDTH = 115,
    parameter int P_WIDTH    = 42,
    parameter logic [P_WIDTH-1:0] P1 = 42'd77309411329,     // 37 bit
    parameter logic [P_WIDTH-1:0] P2 = 42'd206158430209,    // 38 bit
    parameter logic [P_WIDTH-1:0] P3 = 42'd2061584302081    // 41 bit
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    // 输入流（单模数系数）
    input  wire logic              s_valid,
    output logic              s_ready,
    input  wire logic [Q_IN_WIDTH-1:0] s_data,

    // 输出流（3 个 RNS 分量，并行）
    output logic              m_valid,
    input  wire logic              m_ready,
    output logic [P_WIDTH-1:0] m_data_p1,
    output logic [P_WIDTH-1:0] m_data_p2,
    output logic [P_WIDTH-1:0] m_data_p3
);

    // 组合取模
    logic [P_WIDTH-1:0] p1_comb, p2_comb, p3_comb;
    assign p1_comb = s_data % P1;
    assign p2_comb = s_data % P2;
    assign p3_comb = s_data % P3;

    // 输出寄存（1 cycle 流水）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid   <= 1'b0;
            m_data_p1 <= '0;
            m_data_p2 <= '0;
            m_data_p3 <= '0;
        end else if (s_valid) begin
            m_data_p1 <= p1_comb;
            m_data_p2 <= p2_comb;
            m_data_p3 <= p3_comb;
            m_valid   <= 1'b1;
        end else begin
            m_valid   <= 1'b0;
        end
    end

    // 背靠背：只要不在复位，总是可接收
    assign s_ready = 1'b1;

endmodule
