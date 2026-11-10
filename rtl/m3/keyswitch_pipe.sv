// =============================================================================
// M3-c KeySwitch rotation=0 (ReLinearization) 模块 —— 完整实现版
//
// 公式：
//   f0 = (e0 + e2 * b) mod q
//   f1 = (e1 - e2 * a) mod q
//
// 其中：
//   - (e0, e1, e2)：3 元素密文（乘法后的中间结果）
//   - (a, b)：keyswitch key（b = a*s + e_ks，e_ks 为小误差）
//   - (f0, f1)：2 元素密文（重线性化后的结果）
//
// Python 数学等价验证：scripts/verify_keyswitch.py  ALL PASS
//
// 接口：AXI-Stream（单时钟域，同步复位，无 CDC）
// 吞吐：2 次 poly_mult 串行（e2*a, e2*b），约 2 × 164 μs @ 100 MHz
//
// 完整实现（2026-10-04 v2.0）：
//   - 接入 2 个 poly_mult 实例（u_pm_e2a, u_pm_e2b）
//   - COMPUTE 阶段从 e2a_buf/e2b_buf 直读（不依赖 ready）
//   - idx 在状态切换时重置
//   - 参数化 TW_FILE / TW_INV_FILE（twiddle ROM，从 wrapper 透传）
// =============================================================================

`timescale 1ns / 1ps

module keyswitch_pipe #(
    parameter int LOG_N           = 14,
    parameter int N               = 1 << LOG_N,          // 16384
    parameter int Q_WIDTH         = 45,
    parameter logic [Q_WIDTH-1:0] Q_VAL   = 45'd17592186634241,
    parameter logic [Q_WIDTH-1:0] N_INV   = 45'd17591112433657,
    parameter int USE_FASTRED     = 0,
    // Twiddle ROM init files (transparent to inner poly_mult, M-D')
    parameter string TW_FILE     = "rtl/m5/tw/tw_omega_p1_n16.hex",
    parameter string TW_INV_FILE = "rtl/m5/tw/tw_omegainv_p1_n16.hex"
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // 控制
    input  logic                  start,
    output logic                  busy,
    output logic                  done,
    output logic                  error,

    // 输入：3 元素密文（AXI-Stream sink：valid=input, ready=output）
    input  logic                  e0_valid,
    output logic                  e0_ready,
    input  logic [Q_WIDTH-1:0]    e0_data,
    input  logic                  e1_valid,
    output logic                  e1_ready,
    input  logic [Q_WIDTH-1:0]    e1_data,
    input  logic                  e2_valid,
    output logic                  e2_ready,
    input  logic [Q_WIDTH-1:0]    e2_data,

    // 输入：keyswitch key
    input  logic                  a_valid,
    output logic                  a_ready,
    input  logic [Q_WIDTH-1:0]    a_data,
    input  logic                  b_valid,
    output logic                  b_ready,
    input  logic [Q_WIDTH-1:0]    b_data,

    // 输出：2 元素密文（AXI-Stream source：valid=output, ready=input）
    output logic                  f0_valid,
    input  logic                  f0_ready,
    output logic [Q_WIDTH-1:0]    f0_data,
    output logic                  f1_valid,
    input  logic                  f1_ready,
    output logic [Q_WIDTH-1:0]    f1_data

);

    // -------------------------------------------------------------------------
    // 内部缓冲
    // -------------------------------------------------------------------------
    logic [Q_WIDTH-1:0] e0_buf [0:N-1];
    logic [Q_WIDTH-1:0] e1_buf [0:N-1];
    logic [Q_WIDTH-1:0] e2_buf [0:N-1];
    logic [Q_WIDTH-1:0] a_buf  [0:N-1];
    logic [Q_WIDTH-1:0] b_buf  [0:N-1];
    logic [Q_WIDTH-1:0] e2a_buf[0:N-1];   // e2 * a 结果
    logic [Q_WIDTH-1:0] e2b_buf[0:N-1];   // e2 * b 结果
    logic [Q_WIDTH-1:0] f0_buf [0:N-1];
    logic [Q_WIDTH-1:0] f1_buf [0:N-1];

    // -------------------------------------------------------------------------
    // 控制 FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD_ALL,       // e0/e1/e2/a/b 并行加载
        S_MUL_E2A,        // e2 * a
        S_MUL_E2B,        // e2 * b
        S_COMPUTE_F0,     // f0 = e0 + e2*b
        S_COMPUTE_F1,     // f1 = e1 - e2*a
        S_OUTPUT_F0,
        S_OUTPUT_F1,
        S_DONE
    } state_t;

    state_t state, state_next;
    logic [LOG_N-1:0] idx;           // 系数索引（LOAD/COMPUTE/OUTPUT 阶段）

    assign busy  = (state != S_IDLE);
    assign done  = (state == S_DONE);
    assign error = 1'b0;

    // -------------------------------------------------------------------------
    // poly_mult 内部信号
    // -------------------------------------------------------------------------
    logic start_pm_e2a, busy_pm_e2a, done_pm_e2a;
    logic start_pm_e2b, busy_pm_e2b, done_pm_e2b;

    // 边沿检测：仅在 S_MUL_E2A/S_MUL_E2B 进入瞬间产生单拍 start 脉冲
    // （poly_mult 的 start 端口是单周期脉冲，持续高电平会导致 poly_mult 无限重启）
    logic pm_e2a_start_raw, pm_e2a_start_prev;
    logic pm_e2b_start_raw, pm_e2b_start_prev;

    assign pm_e2a_start_raw = (state == S_MUL_E2A);
    assign pm_e2b_start_raw = (state == S_MUL_E2B);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pm_e2a_start_prev <= 1'b0;
            pm_e2b_start_prev <= 1'b0;
        end else begin
            pm_e2a_start_prev <= pm_e2a_start_raw;
            pm_e2b_start_prev <= pm_e2b_start_raw;
        end
    end

    assign start_pm_e2a = pm_e2a_start_raw && !pm_e2a_start_prev;
    assign start_pm_e2b = pm_e2b_start_raw && !pm_e2b_start_prev;

    logic pm_e2a_a_ready, pm_e2a_b_ready;
    logic pm_e2b_a_ready, pm_e2b_b_ready;

    logic [Q_WIDTH-1:0] e2a_out_data;
    logic               e2a_out_valid, e2a_out_last;
    logic [Q_WIDTH-1:0] e2b_out_data;
    logic               e2b_out_valid, e2b_out_last;

    // poly_mult 内部 ridx/widx（a 和 b 各自独立）
    logic [LOG_N:0] ridx_e2a_a, ridx_e2a_b, widx_e2a;
    logic [LOG_N:0] ridx_e2b_a, ridx_e2b_b, widx_e2b;
    logic           e2a_full, e2b_full;

    // start_pm_e2a/start_pm_e2b 由上方的边沿检测逻辑驱动

    // -------------------------------------------------------------------------
    // poly_mult 实例 1: e2a = e2 * a
    // -------------------------------------------------------------------------
    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VAL),
        .N_INV(N_INV),
        .USE_FASTRED(USE_FASTRED),
        .TW_FILE(TW_FILE),
        .TW_INV_FILE(TW_INV_FILE)
    ) u_pm_e2a (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_pm_e2a),
        .busy(busy_pm_e2a),
        .done(done_pm_e2a),
        .error(),
        .a_in_data(e2_buf[ridx_e2a_a]),
        .a_in_valid((state == S_MUL_E2A) && (ridx_e2a_a < N)),
        .a_in_ready(pm_e2a_a_ready),
        .b_in_data(a_buf[ridx_e2a_b]),
        .b_in_valid((state == S_MUL_E2A) && (ridx_e2a_b < N)),
        .b_in_ready(pm_e2a_b_ready),
        .out_data(e2a_out_data),
        .out_valid(e2a_out_valid),
        .out_last(e2a_out_last),
        .out_ready(!e2a_full)
    );

    // -------------------------------------------------------------------------
    // poly_mult 实例 2: e2b = e2 * b
    // -------------------------------------------------------------------------
    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VAL),
        .N_INV(N_INV),
        .USE_FASTRED(USE_FASTRED),
        .TW_FILE(TW_FILE),
        .TW_INV_FILE(TW_INV_FILE)
    ) u_pm_e2b (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_pm_e2b),
        .busy(busy_pm_e2b),
        .done(done_pm_e2b),
        .error(),
        .a_in_data(e2_buf[ridx_e2b_a]),
        .a_in_valid((state == S_MUL_E2B) && (ridx_e2b_a < N)),
        .a_in_ready(pm_e2b_a_ready),
        .b_in_data(b_buf[ridx_e2b_b]),
        .b_in_valid((state == S_MUL_E2B) && (ridx_e2b_b < N)),
        .b_in_ready(pm_e2b_b_ready),
        .out_data(e2b_out_data),
        .out_valid(e2b_out_valid),
        .out_last(e2b_out_last),
        .out_ready(!e2b_full)
    );

    // -------------------------------------------------------------------------
    // FSM 组合逻辑
    // -------------------------------------------------------------------------
    always_comb begin
        state_next = state;
        case (state)
            S_IDLE:
                if (start) state_next = S_LOAD_ALL;

            S_LOAD_ALL:   if (idx == N-1) state_next = S_MUL_E2A;

            S_MUL_E2A: if (done_pm_e2a && e2a_full) state_next = S_MUL_E2B;
            S_MUL_E2B: if (done_pm_e2b && e2b_full) state_next = S_COMPUTE_F0;

            S_COMPUTE_F0: if (idx == N-1) state_next = S_COMPUTE_F1;
            S_COMPUTE_F1: if (idx == N-1) state_next = S_OUTPUT_F0;
            S_OUTPUT_F0:  if (idx == N-1) state_next = S_OUTPUT_F1;
            S_OUTPUT_F1:  if (idx == N-1) state_next = S_DONE;

            S_DONE: state_next = S_IDLE;

            default: state_next = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // FSM 时序逻辑（state/idx 寄存器）
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            idx   <= '0;
        end else begin
            state <= state_next;
            if (state_next != state) begin
                // 状态切换：重置 idx
                case (state_next)
                    S_LOAD_ALL,
                    S_COMPUTE_F0, S_COMPUTE_F1, S_OUTPUT_F0, S_OUTPUT_F1:
                        idx <= '0;
                    default: idx <= '0;
                endcase
            end else begin
                // 同状态内：idx 递增（LOAD/COMPUTE/OUTPUT 阶段）
                case (state)
                    S_LOAD_ALL,
                    S_COMPUTE_F0, S_COMPUTE_F1, S_OUTPUT_F0, S_OUTPUT_F1:
                        idx <= idx + 1'b1;
                    default: idx <= idx;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // LOAD 阶段：5 路并行 ready + buf 写入
    // -------------------------------------------------------------------------
    assign e0_ready = (state == S_LOAD_ALL);
    assign e1_ready = (state == S_LOAD_ALL);
    assign e2_ready = (state == S_LOAD_ALL);
    assign a_ready  = (state == S_LOAD_ALL);
    assign b_ready  = (state == S_LOAD_ALL);

    always_ff @(posedge clk) begin
        if (state == S_LOAD_ALL) begin
            if (e0_valid) e0_buf[idx] <= e0_data;
            if (e1_valid) e1_buf[idx] <= e1_data;
            if (e2_valid) e2_buf[idx] <= e2_data;
            if (a_valid)  a_buf[idx]  <= a_data;
            if (b_valid)  b_buf[idx]  <= b_data;
        end
    end

    // -------------------------------------------------------------------------
    // poly_mult ridx/widx 管理 + e2a_buf/e2b_buf 写入
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ridx_e2a_a <= '0; ridx_e2a_b <= '0; widx_e2a <= '0; e2a_full <= 1'b0;
            ridx_e2b_a <= '0; ridx_e2b_b <= '0; widx_e2b <= '0; e2b_full <= 1'b0;
        end else begin
            // 状态切换时重置 ridx/widx/full
            if (state_next != state) begin
                if (state_next == S_MUL_E2A) begin
                    ridx_e2a_a <= '0;
                    ridx_e2a_b <= '0;
                    widx_e2a   <= '0;
                    e2a_full   <= 1'b0;
                end
                if (state_next == S_MUL_E2B) begin
                    ridx_e2b_a <= '0;
                    ridx_e2b_b <= '0;
                    widx_e2b   <= '0;
                    e2b_full   <= 1'b0;
                end
            end else begin
                // poly_mult a/b ridx 分别递增
                if (state == S_MUL_E2A) begin
                    if (pm_e2a_a_ready) ridx_e2a_a <= ridx_e2a_a + 1'b1;
                    if (pm_e2a_b_ready) ridx_e2a_b <= ridx_e2a_b + 1'b1;
                end
                if (state == S_MUL_E2B) begin
                    if (pm_e2b_a_ready) ridx_e2b_a <= ridx_e2b_a + 1'b1;
                    if (pm_e2b_b_ready) ridx_e2b_b <= ridx_e2b_b + 1'b1;
                end

                // poly_mult 输出写入 e2a_buf/e2b_buf
                if (state == S_MUL_E2A && e2a_out_valid && !e2a_full) begin
                    e2a_buf[widx_e2a] <= e2a_out_data;
                    widx_e2a <= widx_e2a + 1'b1;
                    if (widx_e2a == N-1) e2a_full <= 1'b1;
                end
                if (state == S_MUL_E2B && e2b_out_valid && !e2b_full) begin
                    e2b_buf[widx_e2b] <= e2b_out_data;
                    widx_e2b <= widx_e2b + 1'b1;
                    if (widx_e2b == N-1) e2b_full <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // COMPUTE 阶段：f0 = e0 + e2*b, f1 = e1 - e2*a
    // 直接从 buf 读，不依赖 ready
    // -------------------------------------------------------------------------
    logic [Q_WIDTH:0] sum_tmp;
    logic [Q_WIDTH:0] diff_tmp;

    always_ff @(posedge clk) begin
        if (state == S_COMPUTE_F0) begin
            sum_tmp = {1'b0, e0_buf[idx]} + {1'b0, e2b_buf[idx]};
            f0_buf[idx] = (sum_tmp >= {1'b0, Q_VAL}) ? (sum_tmp - {1'b0, Q_VAL}) : sum_tmp;
        end
        if (state == S_COMPUTE_F1) begin
            diff_tmp = {1'b0, e1_buf[idx]} - {1'b0, e2a_buf[idx]};
            f1_buf[idx] = (e1_buf[idx] < e2a_buf[idx]) ?
                          (diff_tmp + {1'b0, Q_VAL}) : diff_tmp;
        end
    end

    // -------------------------------------------------------------------------
    // 输出
    // -------------------------------------------------------------------------
    assign f0_valid = (state == S_OUTPUT_F0);
    assign f1_valid = (state == S_OUTPUT_F1);
    assign f0_data  = f0_buf[idx];
    assign f1_data  = f1_buf[idx];

endmodule
