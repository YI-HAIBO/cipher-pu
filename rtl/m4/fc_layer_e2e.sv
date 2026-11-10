// =============================================================================
// fc_layer_e2e.sv - 全连接层密文推理单元（GEMM）v3 逐 slot 点算版
// =============================================================================
// 2026-10-19 重写：原版 v2 用 poly_mult 做 GEMM，但 poly_mult 算的是循环卷积
//   A(x)*B(x) mod (x^N-1)，而 GEMM 需要的是逐 slot 标量乘 + 累加。常量权重
//   多项式 [w,w,...,w] 的 NTT 为 [Nw,0,...,0]，卷积结果 = w*(Σ_j x_j) 重复 N 次，
//   语义完全错误。另有 6 处缺陷：
//
//   (E1) poly_mult 连接错误：pm_a_data = x_buf[pm_out_idx]（用输出索引读输入）
//   (E2) x_ready = (state==S_LOAD_INPUT) && x_valid —— valid 门控 ready → 死锁
//   (E3) w_ready = (state==S_LOAD_WEIGHT) && w_valid —— 同上 → 死锁
//   (E4) y_valid = (state==S_OUTPUT) && y_ready —— consumer 决定 producer valid
//   (E5) 无 in_dim_idx 循环：只处理 1 个输入多项式，其余 IN_DIM-1 个丢失
//   (E6) Q_VALUE 声明为 parameter bit（1-bit 截 45-bit）→ 取模结果错误
//
// v3 设计（纯逐 slot 点算，不例化 poly_mult）：
//
//   Y[k, j] = Σ_i X[i, j] × W[k, i] mod Q
//
//   对每个输出通道 k（0..OUT_DIM-1）和每个 slot j（0..N-1）：
//     acc = 0
//     for i = 0..IN_DIM-1:
//       acc = (acc + X[i, j] × W[k, i]) mod Q
//     Y[k, j] = acc
//
//   时序：每 (k,j) 对需 IN_DIM 拍累加 + 1 拍写回，总 (OUT_DIM×N×IN_DIM + OUT_DIM×N) 拍。
//
//   面积（生产 N=4096, Q_WIDTH=45, IN_DIM=512, OUT_DIM=128）：
//     x_buf:    512×4096×45 = 225 MB（流式加载，不存全量——需分块）
//     w_bram:   512×128×45 = 3.3 MB
//     acc_bram: 128×4096×45 = 24 MB
//   注：玩具 N=16 全量存储仅 2880 bit，落分布式 RAM 或寄存器。
//
//   接口：保持与原版一致（batch_idx / batch_done / omega_table / omega_inv_table
//         保留以兼容上层 wrapper，本实现不使用）。
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module fc_layer_e2e #(
    parameter int Q_WIDTH         = 45,
    parameter int N               = 4096,
    parameter int LOG_N           = 12,
    parameter int IN_DIM          = 512,
    parameter int OUT_DIM         = 10,
    parameter int ACC_BATCH_SIZE  = 8,
    // 修正 (E6)：原为 parameter bit（1-bit 截 45-bit），改为参数化位宽
    parameter logic [Q_WIDTH-1:0] Q_VALUE = 45'd17592186175489,
    parameter logic [Q_WIDTH-1:0] N_INV   = 45'd17587891208161,
    parameter int USE_FASTRED     = 1
) (
    input  wire logic               clk,
    input  wire logic               rst_n,

    // 层控制
    input  wire logic               layer_start,
    output logic               layer_busy,
    output logic               layer_done,
    output logic               layer_error,

    // 批次控制（保留端口，本实现不使用）
    input  wire logic [7:0]         batch_idx,
    output logic               batch_done,

    // 输入密文（AXI4-Stream，IN_DIM 个多项式顺序流式加载）
    input  wire logic [Q_WIDTH-1:0] x_tdata,
    input  wire logic               x_valid,
    output logic               x_ready,
    input  wire logic               x_last,

    // 输出密文（AXI4-Stream，OUT_DIM × N 个系数）
    output logic [Q_WIDTH-1:0] y_tdata,
    output logic               y_valid,
    output logic               y_last,
    input  wire logic               y_ready,

    // 权重加载（AXI4-Stream）
    input  wire logic [Q_WIDTH-1:0] w_tdata,
    input  wire logic               w_valid,
    output logic               w_ready,
    input  wire logic               w_last,

    // 权重地址
    input  wire logic [15:0]        w_addr,

    // Twiddle 因子（保留端口，本实现不使用）
    input  wire logic [Q_WIDTH-1:0] omega_table     [0:N/2-1],
    input  wire logic [Q_WIDTH-1:0] omega_inv_table [0:N/2-1]
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam int IDX_W      = $clog2(N);
    localparam int TOTAL_IN   = IN_DIM * N;
    localparam int TOTAL_W    = IN_DIM * OUT_DIM;
    localparam int TOTAL_OUT  = OUT_DIM * N;

    localparam int IN_IDX_W   = $clog2(TOTAL_IN);
    localparam int W_IDX_W    = $clog2(TOTAL_W);
    localparam int OUT_IDX_W  = $clog2(TOTAL_OUT);

    // 状态机编码
    localparam [3:0] S_IDLE        = 4'd0;
    localparam [3:0] S_LOAD_WEIGHT = 4'd1;
    localparam [3:0] S_LOAD_INPUT  = 4'd2;
    localparam [3:0] S_GEMM        = 4'd3;
    localparam [3:0] S_OUTPUT      = 4'd4;
    localparam [3:0] S_DONE        = 4'd5;

    // =========================================================================
    // 数据存储
    // =========================================================================
    // 输入缓冲（IN_DIM 个多项式顺序加载，共 IN_DIM × N 个系数）
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] x_buf  [0:TOTAL_IN-1];
    // 权重（OUT_DIM × IN_DIM）
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] w_bram [0:TOTAL_W-1];
    // 累加器输出（OUT_DIM × N）
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] acc_bram [0:TOTAL_OUT-1];

    // =========================================================================
    // 状态寄存器
    // =========================================================================
    logic [3:0]              state;
    logic [W_IDX_W-1:0]     w_idx;
    logic [IN_IDX_W-1:0]    x_idx;
    logic [$clog2(OUT_DIM)-1:0] gemm_k;
    logic [IDX_W-1:0]       gemm_j;
    logic [$clog2(IN_DIM)-1:0]  gemm_i;
    logic [OUT_IDX_W-1:0]   out_idx;
    logic [Q_WIDTH-1:0]     acc_reg;

    // =========================================================================
    // 模 Q 算术（组合）
    // =========================================================================
    // 乘法器：x_val × w_val → 90-bit 满积
    wire [Q_WIDTH-1:0] x_val = x_buf[gemm_i * N + gemm_j];
    wire [Q_WIDTH-1:0] w_val = w_bram[gemm_k * IN_DIM + gemm_i];
    wire [2*Q_WIDTH-1:0] prod_raw = x_val * w_val;

    // Barrett 归约（生产 Q=2^44+2^17+1）：prod_raw → prod_mod
    // 玩具 Q=113 用 % 运算符
    wire [Q_WIDTH-1:0] prod_mod;
    generate
        if (USE_FASTRED && Q_WIDTH == 45) begin : g_barrett
            // Barrett: V = floor(2^(2*W) / Q)，W = Q_WIDTH
            // 用组合 % 运算符（仿真正确，综合由工具优化）
            assign prod_mod = prod_raw % Q_VALUE;
        end else begin : g_pct
            assign prod_mod = prod_raw % Q_VALUE;
        end
    endgenerate

    // 累加：acc_reg + prod_mod → acc_new（单次条件减收敛）
    wire [Q_WIDTH:0] acc_sum  = {1'b0, acc_reg} + {1'b0, prod_mod};
    wire [Q_WIDTH-1:0] acc_sub = acc_sum[Q_WIDTH-1:0] - Q_VALUE[Q_WIDTH-1:0];
    wire [Q_WIDTH-1:0] acc_new =
        (acc_sum >= {1'b0, Q_VALUE}) ? acc_sub : acc_sum[Q_WIDTH-1:0];

    // =========================================================================
    // 握手信号（修正 E2/E3/E4：valid 不依赖 ready）
    // =========================================================================
    assign x_ready = (state == S_LOAD_INPUT);
    assign w_ready = (state == S_LOAD_WEIGHT);
    assign y_valid = (state == S_OUTPUT);
    assign y_last  = (state == S_OUTPUT) && (out_idx == OUT_IDX_W'(TOTAL_OUT - 1));
    assign y_tdata = acc_bram[out_idx];

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign layer_busy  = (state != S_IDLE) && (state != S_DONE);
    assign layer_done  = (state == S_DONE);
    assign layer_error = 1'b0;
    assign batch_done  = 1'b0;

    // =========================================================================
    // 主 FSM（单一 always 块）
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            w_idx    <= '0;
            x_idx    <= '0;
            gemm_k   <= '0;
            gemm_j   <= '0;
            gemm_i   <= '0;
            out_idx  <= '0;
            acc_reg  <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (layer_start) begin
                        state <= S_LOAD_WEIGHT;
                        w_idx <= '0;
                    end
                end

                S_LOAD_WEIGHT: begin
                    if (w_valid && w_ready) begin
                        w_bram[w_addr[W_IDX_W-1:0]] <= w_tdata;
                        if (w_last) begin
                            state <= S_LOAD_INPUT;
                            x_idx <= '0;
                        end else begin
                            w_idx <= w_idx + W_IDX_W'(1);
                        end
                    end
                end

                S_LOAD_INPUT: begin
                    if (x_valid && x_ready) begin
                        x_buf[x_idx] <= x_tdata;
                        if (x_idx >= IN_IDX_W'(TOTAL_IN - 1)) begin
                            state   <= S_GEMM;
                            gemm_k  <= '0;
                            gemm_j  <= '0;
                            gemm_i  <= '0;
                            acc_reg <= '0;
                        end else begin
                            x_idx <= x_idx + IN_IDX_W'(1);
                        end
                    end
                end

                S_GEMM: begin
                    // 累加 x_buf[i,j] × w_bram[k,i] → acc_reg
                    if (gemm_i >= $clog2(IN_DIM)'(IN_DIM - 1)) begin
                        // 最后一个 i：写回累加结果，清零 acc_reg
                        acc_bram[gemm_k * N + gemm_j] <= acc_new;
                        acc_reg <= '0;

                        if (gemm_j >= IDX_W'(N - 1)) begin
                            if (gemm_k >= $clog2(OUT_DIM)'(OUT_DIM - 1)) begin
                                // 全部 (k,j,i) 完成
                                state   <= S_OUTPUT;
                                out_idx <= '0;
                            end else begin
                                gemm_k <= gemm_k + 1;
                                gemm_j <= '0;
                                gemm_i <= '0;
                            end
                        end else begin
                            gemm_j <= gemm_j + IDX_W'(1);
                            gemm_i <= '0;
                        end
                    end else begin
                        // 非最后一个 i：累加
                        acc_reg  <= acc_new;
                        gemm_i   <= gemm_i + 1;
                    end
                end

                S_OUTPUT: begin
                    if (y_valid && y_ready) begin
                        if (out_idx >= OUT_IDX_W'(TOTAL_OUT - 1)) begin
                            state <= S_DONE;
                        end else begin
                            out_idx <= out_idx + OUT_IDX_W'(1);
                        end
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
