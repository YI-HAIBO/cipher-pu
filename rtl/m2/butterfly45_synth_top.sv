//=============================================================================
// butterfly45_synth_top.sv  —  N=2^14 / q=45bit 真实规模蝴蝶的综合顶层
//
// 用途：给 M2 规模可行性分析提供硬指标（一个 ntt_butterfly 在真实参数下的
//       LUT / FF / DSP 占用与最高可达时钟）。实际工程不例化本模块，
//       仅为综合时固定参数（否则 Q_VALUE 非常数，综合器无法优化模运算）。
//
// 参数来源：scripts/_gen_real_params.py（q 为素数，满足 2N | q-1）
//=============================================================================

// 注意：本文件不声明 `default_nettype none。
// Vivado 综合（Synth 8-6735）不接受 default_nettype none 下的 `input logic clk`，
// 必须显式写 `input wire logic；为免逐个端口改写，纯综合用 wrapper 直接关掉该检查。
// 生产 RTL（ntt_butterfly / ntt_unit）已按 input wire logic 改写，可正常综合。
`timescale 1ns / 1ps

// 这里两个生产 RTL 都被 read 过，而它们都执行了 `default_nettype none，
// 该指令是「编译单元级状态」、会跨文件带到本文件，故本 wrapper 的 input
// 也必须写 wire，否则 Synth 8-6735。（工程侧建议：带 default_nettype none
// 的文件在末尾补 `default_nettype wire 复位，见 report m2_scale_feasibility）
module butterfly45_synth_top (
    input  wire logic          clk,
    input  wire logic          rst_n,

    input  wire logic          s_valid,
    input  wire logic [44:0]   s_a,
    input  wire logic [44:0]   s_b,
    input  wire logic [44:0]   s_omega,
    output logic               s_ready,

    output logic               m_valid,
    output logic [44:0]        m_a,
    output logic [44:0]        m_b,
    input  wire logic          m_ready
);

    // N = 2^14, q = 17592186175489 (45 bit 素数, q-1 = 2^17 * 134217729)
    // 2N | q-1 成立, 故 omega 为 2N 次原根: omega^(2N)=1, omega^N=-1
    localparam int Q_WIDTH = 45;
    localparam logic [44:0] Q_VALUE = 45'd17592186175489;
    localparam int HI_W    = 24;   // 24 + 21 = 45（对齐 mult 的 Horner 分段）
    localparam int LO_W    = 21;

    ntt_butterfly #(
        .Q_WIDTH (Q_WIDTH),
        .Q_VALUE (Q_VALUE),
        .HI_W    (HI_W),
        .LO_W    (LO_W)
    ) u_bf (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_valid (s_valid),
        .s_a     (s_a),
        .s_b     (s_b),
        .s_omega (s_omega),
        .s_ready (s_ready),
        .m_valid (m_valid),
        .m_a     (m_a),
        .m_b     (m_b),
        .m_ready (m_ready)
    );

endmodule
