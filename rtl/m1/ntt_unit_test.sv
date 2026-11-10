//=============================================================================
// ntt_unit_test.sv  —  测试版 NTT 核（支持任意素数 q）
//
// 与 ntt_unit.sv 的区别：
//   - 使用 ntt_butterfly_test.sv（支持任意素数 q）
//   - 增加 Q_VALUE 参数
//   - 便于 M1 测试（q=113）
//
// 用途：M1 测试 NTT 正确性，验证通过后集成 M1 乘法器
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module ntt_unit_test #(
    parameter int LOG_N   = 4,       // M1 测试：N=16
    parameter int N       = 1 << LOG_N,
    parameter int Q_WIDTH = 7,       // q=113 需 7 bit
    parameter logic [Q_WIDTH-1:0] Q_VALUE = 113,     // 素数模数
    parameter int N_INV   = 106      // N 在 q 下的逆元 (16^-1 mod 113 = 106)，INTT 输出缩放
) (
    input  logic              clk,
    input  logic              rst_n,

    // 控制
    input  logic              start,
    input  logic              op_mode,
    output logic              busy,
    output logic              done,
    output logic              error,

    // 输入流
    input  logic [Q_WIDTH-1:0] in_data,
    input  logic              in_valid,
    output logic              in_ready,

    // 输出流
    output logic [Q_WIDTH-1:0] out_data,
    output logic              out_valid,
    output logic              out_last,
    input  logic              out_ready,

    // Twiddle 因子表
    input  logic [Q_WIDTH-1:0] omega_table     [0:N/2-1],   // ω^k     (op_mode=0, NTT)
    input  logic [Q_WIDTH-1:0] omega_inv_table [0:N/2-1]    // (ω^-1)^k (op_mode=1, INTT)
);

    // =========================================================================
    // 寄存器文件
    // =========================================================================
    logic [Q_WIDTH-1:0] mem [0:N-1];

    // =========================================================================
    // Bit-reversal 函数（Cooley-Tukey DIT 需要输入端 bit-reversal 置换）
    // =========================================================================
    function automatic logic [$clog2(N)-1:0] bit_reverse(input logic [$clog2(N)-1:0] x);
        automatic logic [$clog2(N)-1:0] y;
        for (int b = 0; b < LOG_N; b = b + 1) begin
            y[LOG_N - 1 - b] = x[b];
        end
        return y;
    endfunction

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam S_IDLE    = 4'd0;
    localparam S_INPUT   = 4'd1;
    localparam S_COMPUTE = 4'd2;
    localparam S_OUTPUT  = 4'd3;
    localparam S_DONE    = 4'd4;

    logic [3:0] state;

    // 计数器
    logic [$clog2(N)-1:0] coeff_idx;
    logic [$clog2(LOG_N+1)-1:0] stage_idx;
    logic [$clog2(N/2)-1:0] bf_idx;

    // 蝴蝶地址
    logic [$clog2(N)-1:0] bf_addr_a, bf_addr_b;
    logic [$clog2(N/2)-1:0] twiddle_exp;

    // 子状态机
    localparam C_ISSUE    = 2'd0;
    localparam C_WAIT     = 2'd1;
    localparam C_WRITEBACK = 2'd2;

    logic [1:0] comp_state;
    logic [1:0] wait_cnt;

    // =========================================================================
    // 测试蝴蝶实例
    // =========================================================================
    logic [Q_WIDTH-1:0] bf_a_in, bf_b_in, bf_omega_in;
    logic [Q_WIDTH-1:0] bf_a_out, bf_b_out;
    logic bf_valid, bf_m_valid;

    ntt_butterfly_test #(
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VALUE)
    ) u_butterfly (
        .clk(clk),
        .rst_n(rst_n),
        .a_in(bf_a_in),
        .b_in(bf_b_in),
        .omega(bf_omega_in),
        .valid(bf_valid),
        .a_out(bf_a_out),
        .b_out(bf_b_out),
        .valid_out(bf_m_valid)
    );

    // =========================================================================
    // 地址计算（Cooley-Tukey DIT）
    //   Stage s: stride = 2^s, 每组 2*stride 个元素
    //   第 i 个蝴蝶: a = group*2*stride + j, b = a + stride
    //   twiddle = root^(j * N/(2*stride))
    // =========================================================================
    wire [$clog2(N)-1:0] stride = 1 << stage_idx;  // 1, 2, 4, ..., N/2
    wire [$clog2(N/2)-1:0] bf_idx_div = bf_idx / stride;  // 组号
    wire [$clog2(N/2)-1:0] bf_idx_mod = bf_idx % stride;   // 组内位置
    wire [$clog2(N)-1:0] a_addr_calc = bf_idx_div * (2*stride) + bf_idx_mod;
    wire [$clog2(N)-1:0] b_addr_calc = a_addr_calc + stride;
    wire [$clog2(N/2)-1:0] twiddle_exp_calc = bf_idx_mod * (N / (2*stride));

    // =========================================================================
    // INTT 输出缩放（op_mode=1）
    //   DIT 结构下 INTT = bit-reversal 输入 + ω^-1 蝴蝶 + 输出乘 N^-1
    //   N_INV_VAL 显式收窄为 Q_WIDTH bit 无符号，避免 int 参与的符号扩展
    //   结果 < Q_VALUE < 2^Q_WIDTH，截断安全
    // =========================================================================
    localparam [Q_WIDTH-1:0] N_INV_VAL = N_INV;
    wire [2*Q_WIDTH-1:0] out_scale_prod = mem[coeff_idx] * N_INV_VAL;
    wire [Q_WIDTH-1:0]   out_scaled     = out_scale_prod % Q_VALUE;

    // =========================================================================
    // 主状态机
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
    // LINT-L7: async reset: test module (not synthesized)
        if (!rst_n) begin
            state       <= S_IDLE;
            comp_state  <= C_ISSUE;
            coeff_idx   <= '0;
            stage_idx   <= '0;
            bf_idx      <= '0;
            wait_cnt    <= '0;
            bf_addr_a   <= '0;
            bf_addr_b   <= '0;
            twiddle_exp <= '0;
            bf_a_in     <= '0;
            bf_b_in     <= '0;
            bf_omega_in <= '0;
            bf_valid    <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
            error       <= 1'b0;
            in_ready    <= 1'b0;
            out_data    <= '0;
            out_valid   <= 1'b0;
            out_last    <= 1'b0;
        end else begin
            done     <= 1'b0;
            in_ready <= 1'b0;
            out_valid <= 1'b0;
            bf_valid  <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        coeff_idx <= '0;
                        stage_idx <= '0;
                        bf_idx    <= '0;
                        comp_state <= C_ISSUE;
                        state     <= S_INPUT;
                    end
                end

                S_INPUT: begin
                    in_ready <= 1'b1;
                    if (in_valid && in_ready) begin
                        // Bit-reversal permutation: 输入存到 bit-reversed 位置
                        mem[bit_reverse(coeff_idx)] <= in_data;
                        coeff_idx <= coeff_idx + 1'b1;
                        if (coeff_idx == N - 1) begin
                            in_ready <= 1'b0;
                            stage_idx <= '0;
                            bf_idx    <= '0;
                            comp_state <= C_ISSUE;
                            state     <= S_COMPUTE;
                        end
                    end
                end

                S_COMPUTE: begin
                    case (comp_state)
                        C_ISSUE: begin
                            bf_addr_a   <= a_addr_calc;
                            bf_addr_b   <= b_addr_calc;
                            twiddle_exp <= twiddle_exp_calc;
                            bf_a_in     <= mem[a_addr_calc];
                            bf_b_in     <= mem[b_addr_calc];
                            // op_mode=0 (NTT): 用 ω^k；op_mode=1 (INTT): 用 ω^(-k)
                            bf_omega_in <= op_mode ? omega_inv_table[twiddle_exp_calc]
                                                    : omega_table[twiddle_exp_calc];
                            
                            bf_valid <= 1'b1;
                            comp_state <= C_WAIT;
                            wait_cnt <= 2'd2;
                        end

                        C_WAIT: begin
                            if (wait_cnt > 0) begin
                                wait_cnt <= wait_cnt - 1;
                            end else begin
                                comp_state <= C_WRITEBACK;
                            end
                        end

                        C_WRITEBACK: begin
                            mem[bf_addr_a] <= bf_a_out;
                            mem[bf_addr_b] <= bf_b_out;
                            
                            bf_idx <= bf_idx + 1'b1;
                            comp_state <= C_ISSUE;
                            
                            if (bf_idx == N/2 - 1) begin
                                bf_idx <= '0;
                                stage_idx <= stage_idx + 1'b1;
                                if (stage_idx == LOG_N - 1) begin
                                    coeff_idx <= '0;
                                    comp_state <= C_ISSUE;
                                    state <= S_OUTPUT;
                                end
                            end
                        end

                        default: comp_state <= C_ISSUE;
                    endcase
                end

                S_OUTPUT: begin
                    // op_mode=0 (NTT) : 直接输出系数
                    // op_mode=1 (INTT): 输出前乘 N^-1 完成缩放
                    out_data  <= op_mode ? out_scaled : mem[coeff_idx];
                    out_valid <= 1'b1;
                    out_last  <= (coeff_idx == N - 1);
                    if (out_ready) begin
                        coeff_idx <= coeff_idx + 1'b1;
                        if (coeff_idx == N - 1) begin
                            out_valid <= 1'b0;
                            out_last  <= 1'b0;
                            state     <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
