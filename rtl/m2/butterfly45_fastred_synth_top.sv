//=============================================================================
// butterfly45_fastred_synth_top.sv  —  用 fast-red（q = 2^44 + c）替换 `%` 的对照蝴蝶
//
// 与 butterfly45_synth_top.sv（生产版 ntt_butterfly，`%` 实现）一一对照：
//   唯一差别：prod_q 用 mod45_fastred 算，而不是 prod_raw % Q_VALUE。
//   另外两次廉价的 45 bit 取模（a+prod_q、a+q-prod_q）改成条件减——
//   这两个操作数上界是 2q，一次条件减即为精确解，也是真实设计该写的写法。
//
// 用途：给 M2 规模分析提供「fast-red 之后单蝴蝶还剩多少 LUT / DSP」的实测数，
//       从而重新判定并行度上限（原来 P=64 判定为不可行）。
//
// 注：本文件同样不写 `default_nettype none`，且所有 input 显式 wire，
//     与 butterfly45_synth_top / butterfly45_barrett_synth_top 保持同一综合
//     设置，保证三路 A/B 可比。
//=============================================================================

`timescale 1ns / 1ps

module butterfly45_fastred_synth_top (
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

    localparam int Q_WIDTH = 45;
    localparam logic [44:0] Q_VALUE = 45'd17592186175489;
    localparam int HI_W    = 24;
    localparam int LO_W    = 21;

    wire [2*Q_WIDTH-1:0] prod_raw;
    wire                 mult_valid;
    wire                 mult_ready;

    mult_43x43_horner4 #(
        .WIDTH    (Q_WIDTH),
        .HI_W     (HI_W),
        .LO_W     (LO_W),
        .PIPE_OUT (1)
    ) u_mult (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_valid (s_valid),
        .s_a     (s_b),
        .s_b     (s_omega),
        .s_ready (mult_ready),
        .m_valid (mult_valid),
        .m_p     (prod_raw),
        .m_ready (1'b1)
    );

    // ---- 唯一差别：这里原来是 `prod_raw % Q_VALUE` ------------------------
    wire [Q_WIDTH-1:0] prod_q;
    mod45_fastred #(
        .Q_VALUE (Q_VALUE),
        .PIPE    (0)                            // E49: 探针顶层保持纯组合
    ) u_mod (
        .clk (1'b0),
        .x (prod_raw),
        .r (prod_q)
    );

    // ---- 廉价归约：操作数上界 2q，一次条件减即精确 -------------------------
    wire [Q_WIDTH:0]   sum_ext      = {1'b0, s_a} + {1'b0, prod_q};
    wire [Q_WIDTH-1:0] a_prime      = (sum_ext >= {1'b0, Q_VALUE})
                                      ? sum_ext[Q_WIDTH-1:0] - Q_VALUE
                                      : sum_ext[Q_WIDTH-1:0];
    wire [Q_WIDTH-1:0] q_minus_prod = Q_VALUE - prod_q;
    wire [Q_WIDTH:0]   diff_ext     = {1'b0, s_a} + {1'b0, q_minus_prod};
    wire [Q_WIDTH-1:0] b_prime      = (diff_ext >= {1'b0, Q_VALUE})
                                      ? diff_ext[Q_WIDTH-1:0] - Q_VALUE
                                      : diff_ext[Q_WIDTH-1:0];

    logic [Q_WIDTH-1:0] a_out_reg;
    logic [Q_WIDTH-1:0] b_out_reg;
    logic               valid_out_reg;

    always_ff @(posedge clk or negedge rst_n) begin
    // LINT-L7: async reset: synth top probe (not in E2E)
        if (!rst_n) begin
            a_out_reg     <= '0;
            b_out_reg     <= '0;
            valid_out_reg <= 1'b0;
        end else begin
            a_out_reg     <= a_prime;
            b_out_reg     <= b_prime;
            valid_out_reg <= mult_valid;
        end
    end

    assign m_a     = a_out_reg;
    assign m_b     = b_out_reg;
    assign m_valid = valid_out_reg;
    assign s_ready = mult_ready && m_ready;

endmodule
