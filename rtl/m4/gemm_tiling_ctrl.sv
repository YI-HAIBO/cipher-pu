//=============================================================================
// gemm_tiling_ctrl.sv - GEMM 分层优化控制器（v3 重写，可综合 + 可验证）
//
// 功能：密文 GEMM 的分块(tiling)计算控制器。对每个输出 tile (bm,bn)：
//   1) 从 A 流加载 A 子块 cache_a[TM*TK]（行主序 m,k）
//   2) 从 B 流加载 B 子块 cache_b[TK*TN]（行主序 k,n）
//   3) 计算 C 子块 cache_c[TM*TN]：C[m,n] = Σ_k A[m,k]*B[k,n]
//   4) 流式输出 C 子块（行主序 m,n）
//   tile 遍历顺序：bm 外层、bn 内层，全部完成后 done。
//
// 约束：本控制器按"单 K-tile"组织，要求 NTILE_K = K/TK = 1（K = TK）。
//   生产环境的多 K-tile 累加（跨 tile 部分和）留待上层 wrapper 组合。
//
// 顶层端口与原版一致（兼容 e2e_phase2_wrapper 例化），仅内部逻辑重写。
//
// 修正记录（v3, 2026-10-20）：
//   - 删除原版在 always_comb 中对输入端口 a_valid 自赋值的非法写法
//   - 删除原版在 always_comb 中使用非阻塞赋值(<=)写缓存的错误
//   - 补齐原版缺失的 COMPUTE 实际乘法累加（原版 cache_c 从不写入，输出恒 0）
//   - 修正 output_idx 在加载/计算/输出三阶段被混用的问题
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module gemm_tiling_ctrl #(
    parameter int M      = 256,
    parameter int K      = 256,
    parameter int N      = 256,
    parameter int TM     = 16,
    parameter int TK     = 16,
    parameter int TN     = 16,
    parameter int NTILE_M = M / TM,
    parameter int NTILE_K = K / TK,
    parameter int NTILE_N = N / TN,
    parameter int DATA_WIDTH = 45
) (
    input  wire logic                          clk,
    input  wire logic                          rst_n,

    // 输入 AXI4-Stream（A 矩阵，按 tile 行主序供给）
    input  wire logic                          a_valid,
    output wire logic                          a_ready,
    input  wire logic [DATA_WIDTH-1:0]         a_data,

    // 输入 AXI4-Stream（B 矩阵，按 tile 行主序供给）
    input  wire logic                          b_valid,
    output wire logic                          b_ready,
    input  wire logic [DATA_WIDTH-1:0]         b_data,

    // 输出 AXI4-Stream（C 矩阵，按 tile 行主序流出）
    output wire logic                          c_valid,
    input  wire logic                          c_ready,
    output wire logic [DATA_WIDTH-1:0]         c_data,

    // 控制接口
    input  wire logic                          start,
    output wire logic                          busy,
    output wire logic                          done,
    output wire logic                          error
);

    localparam int A_TILE = TM * TK;
    localparam int B_TILE = TK * TN;
    localparam int C_TILE = TM * TN;

    localparam int LA_W = (A_TILE > 1) ? $clog2(A_TILE) : 1;
    localparam int LB_W = (B_TILE > 1) ? $clog2(B_TILE) : 1;
    localparam int CM_W = (TM     > 1) ? $clog2(TM)     : 1;
    localparam int CN_W = (TN     > 1) ? $clog2(TN)     : 1;
    localparam int CK_W = (TK     > 1) ? $clog2(TK)     : 1;
    localparam int OI_W = (C_TILE > 1) ? $clog2(C_TILE) : 1;
    localparam int BM_W = (NTILE_M> 1) ? $clog2(NTILE_M): 1;
    localparam int BN_W = (NTILE_N> 1) ? $clog2(NTILE_N): 1;
    localparam int ACC_W = 2*DATA_WIDTH + 8;

    // FSM
    typedef enum logic [2:0] {
        S_IDLE, S_LOAD_A, S_LOAD_B, S_COMPUTE, S_OUTPUT, S_DONE
    } fsm_state_e;
    fsm_state_e state;

    // tile / 索引寄存器
    logic [BM_W-1:0] bm;
    logic [BN_W-1:0] bn;
    logic [LA_W-1:0] la;
    logic [LB_W-1:0] lb;
    logic [CM_W-1:0] cm;
    logic [CN_W-1:0] cn;
    logic [CK_W-1:0] ck;
    logic [OI_W-1:0] oidx;
    logic [ACC_W-1:0] acc;

    // tile 缓存
    logic [DATA_WIDTH-1:0] cache_a [0:A_TILE-1];
    logic [DATA_WIDTH-1:0] cache_b [0:B_TILE-1];
    logic [DATA_WIDTH-1:0] cache_c [0:C_TILE-1];

    // 组合 MAC 操作数
    logic [DATA_WIDTH-1:0] a_op, b_op;
    logic [ACC_W-1:0]      prod, acc_next;
    assign a_op     = cache_a[cm*TK + ck];
    assign b_op     = cache_b[ck*TN + cn];
    assign prod     = a_op * b_op;
    assign acc_next = acc + prod;

    // 握手（Mealy）
    assign a_ready = (state == S_LOAD_A);
    assign b_ready = (state == S_LOAD_B);
    assign c_valid = (state == S_OUTPUT);
    assign c_data  = cache_c[oidx];
    assign busy    = (state != S_IDLE) && (state != S_DONE);
    assign done    = (state == S_DONE);
    assign error   = 1'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            bm <= '0; bn <= '0; la <= '0; lb <= '0;
            cm <= '0; cn <= '0; ck <= '0; oidx <= '0; acc <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_LOAD_A;
                        bm <= '0; bn <= '0; la <= '0;
                    end
                end

                S_LOAD_A: begin
                    if (a_valid && a_ready) begin
                        cache_a[la] <= a_data;
                        if (la >= LA_W'(A_TILE-1)) begin
                            la <= '0;
                            lb <= '0;
                            state <= S_LOAD_B;
                        end else begin
                            la <= la + 1'b1;
                        end
                    end
                end

                S_LOAD_B: begin
                    if (b_valid && b_ready) begin
                        cache_b[lb] <= b_data;
                        if (lb >= LB_W'(B_TILE-1)) begin
                            lb <= '0;
                            cm <= '0; cn <= '0; ck <= '0; acc <= '0;
                            state <= S_COMPUTE;
                        end else begin
                            lb <= lb + 1'b1;
                        end
                    end
                end

                S_COMPUTE: begin
                    if (ck >= CK_W'(TK-1)) begin
                        // 结束当前 (cm,cn) 元素累加
                        cache_c[cm*TN + cn] <= acc_next[DATA_WIDTH-1:0];
                        acc <= '0;
                        ck  <= '0;
                        if (cn >= CN_W'(TN-1)) begin
                            cn <= '0;
                            if (cm >= CM_W'(TM-1)) begin
                                cm <= '0;
                                state    <= S_OUTPUT;
                                oidx     <= '0;
                            end else begin
                                cm <= cm + 1'b1;
                            end
                        end else begin
                            cn <= cn + 1'b1;
                        end
                    end else begin
                        acc <= acc_next;
                        ck  <= ck + 1'b1;
                    end
                end

                S_OUTPUT: begin
                    if (c_valid && c_ready) begin
                        if (oidx >= OI_W'(C_TILE-1)) begin
                            oidx <= '0;
                            // 推进到下一个输出 tile
                            if (bn >= BN_W'(NTILE_N-1)) begin
                                bn <= '0;
                                if (bm >= BM_W'(NTILE_M-1)) begin
                                    bm <= '0;
                                    state <= S_DONE;
                                end else begin
                                    bm <= bm + 1'b1;
                                    la  <= '0;
                                    state <= S_LOAD_A;
                                end
                            end else begin
                                bn <= bn + 1'b1;
                                la <= '0;
                                state <= S_LOAD_A;
                            end
                        end else begin
                            oidx <= oidx + 1'b1;
                        end
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // 调试输出
    initial begin
        $display("%0t [GEMM_TILING_CTRL] M=%0d K=%0d N=%0d TM=%0d TK=%0d TN=%0d NTILE=(%0d,%0d,%0d)",
                  $time, M, K, N, TM, TK, TN, NTILE_M, NTILE_K, NTILE_N);
    end

endmodule

`default_nettype wire
