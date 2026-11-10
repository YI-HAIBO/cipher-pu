//=============================================================================
// mult_43x43_horner4.sv  —  方案 B（主推）
//
// 43-bit × 43-bit 乘法器，Horner 分解为 4 个乘法项，映射到 4 个 DSP48E1。
//
// 分解：
//   A = A_hi (24b) << 19 | A_lo (19b)
//   B = B_hi (24b) << 19 | B_lo (19b)
//
//   P = A_hi * B_hi << 38
//     + (A_hi * B_lo + A_lo * B_hi) << 19
//     + A_lo * B_lo
//
// 4 个乘法项位宽：
//   A_hi*B_hi : 24×24 = 48 bit  (刚好填满 DSP48E1)
//   A_hi*B_lo : 24×19 = 43 bit
//   A_lo*B_hi : 19×24 = 43 bit
//   A_lo*B_lo : 19×19 = 38 bit
//
// 输出：86 bit 无符号结果
//
// 目标器件：xc7u25u (UltraScale+, DSP48E1)
// 预期资源：4 个 DSP48E1 + 少量 LUT/FF 用于加法树
// 预期延迟：2 cycles（含 1 级输出流水寄存器）
//
// 接口：AXI-Stream 风格 valid/ready 握手
//=============================================================================

`timescale 1ns / 1ps

module mult_43x43_horner4 #(
    parameter int WIDTH     = 43,   // 操作数位宽
    parameter int HI_W      = 24,   // 高位段
    parameter int LO_W      = 19,   // 低位段  (HI_W + LO_W == WIDTH)
    parameter int PIPE_OUT  = 1     // 1: 输出寄存（推荐）; 0: 组合
) (
    input  logic               clk,
    input  logic               rst_n,

    // Slava 输入
    input  logic               s_valid,
    input  logic [WIDTH-1:0]   s_a,
    input  logic [WIDTH-1:0]   s_b,
    output logic               s_ready,

    // Slava 输出
    output logic               m_valid,
    output logic [2*WIDTH-1:0] m_p,
    input  logic               m_ready
);

    // ---------------------------------------------------------------------
    // 分解
    // ---------------------------------------------------------------------
    wire [HI_W-1:0] A_hi = s_a[HI_W+LO_W-1 : LO_W];
    wire [LO_W-1:0] A_lo = s_a[LO_W-1 : 0];
    wire [HI_W-1:0] B_hi = s_b[HI_W+LO_W-1 : LO_W];
    wire [LO_W-1:0] B_lo = s_b[LO_W-1 : 0];

    // ---------------------------------------------------------------------
    // 4 个部分积
    // 用 [MSB:0] 显式标定位宽，防止综合器推断错误
    //
    // 位宽铁律：位宽必须等于「满积位数」，少 1 bit 会静默截掉最高位。
    //   n 位 x m 位 的乘积需 n+m bit（不是 n+m-1）
    //   24x24 = 48b -> [2*HI_W-1:0]     （曾误写 47b，bit47 丢失）
    //   24x19 = 43b -> [HI_W+LO_W-1:0]  （曾误写 42b，bit42 丢失）
    //   19x19 = 38b -> [2*LO_W-1:0]     （正确，无需改）
    // ---------------------------------------------------------------------
    wire [2*HI_W-1 : 0]       p_hi_hi = A_hi * B_hi;   // 24x24 = 48b
    wire [HI_W+LO_W-1 : 0]    p_hi_lo = A_hi * B_lo;   // 24x19 = 43b
    wire [HI_W+LO_W-1 : 0]    p_lo_hi = A_lo * B_hi;   // 19x24 = 43b
    wire [2*LO_W-1 : 0]       p_lo_lo = A_lo * B_lo;   // 19x19 = 38b

    // ---------------------------------------------------------------------
    // 加法树
    //   mid_sum = p_hi_lo + p_lo_hi  (加宽 1 bit 防进位丢失)
    //   P       = (p_hi_hi << 2*LO_W)
    //           + (p_hi_lo << LO_W)
    //           + (p_lo_hi << LO_W)
    //           + (p_lo_lo)
    //   最终 P 最大 86 bit (=(2^43-1)^2 = 2^86 - 2^44 + 1)
    // ---------------------------------------------------------------------
    wire [2*WIDTH-1 : 0] p_hi_hi_ext = { {(2*WIDTH - 2*HI_W){1'b0}}, p_hi_hi };
    wire [2*WIDTH-1 : 0] p_hi_lo_ext = { {(2*WIDTH - HI_W - LO_W){1'b0}}, p_hi_lo };
    wire [2*WIDTH-1 : 0] p_lo_hi_ext = { {(2*WIDTH - HI_W - LO_W){1'b0}}, p_lo_hi };
    wire [2*WIDTH-1 : 0] p_lo_lo_ext = { {(2*WIDTH - 2*LO_W){1'b0}}, p_lo_lo };

    wire [2*WIDTH-1 : 0] p_comb =
          (p_hi_hi_ext << (2*LO_W))
        + (p_hi_lo_ext << (LO_W))
        + (p_lo_hi_ext << (LO_W))
        +  (p_lo_lo_ext);

    // ---------------------------------------------------------------------
    // 输出流水（1 cycle 延迟）
    // ---------------------------------------------------------------------
    logic [2*WIDTH-1 : 0] p_reg;
    logic                 m_valid_reg;
    logic                 s_valid_in_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_reg       <= '0;
            m_valid_reg <= 1'b0;
            s_valid_in_q<= 1'b0;
        end else begin
            s_valid_in_q <= s_valid && s_ready;
            m_valid_reg  <= s_valid_in_q;
            p_reg        <= p_comb;
        end
    end

    assign s_ready = ~s_valid_in_q;         // 前一级未完成时不接新数据
    assign m_valid = m_valid_reg;
    assign m_p     = p_reg;

    // 允许下游随时接收
    // (若下游 m_ready 一直为高, 无背压；否则需扩展为 FIFO)

endmodule
