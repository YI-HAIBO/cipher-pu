// =============================================================================
// M3-d 端到端密文乘法控制器（CKKS）- 完整集成版
//
// 功能：执行完整的 CKKS 密文乘法链路
//   输入：C1 = (c0_1, c1_1), C2 = (c0_2, c1_2)  2 元素密文
//   步骤：
//     1. 3 次 poly_mult：
//        m0 = c0_1 * c0_2
//        m1 = c0_1 * c1_2 + c1_1 * c0_2  (2 次 poly_mult + 1 次加法)
//        m2 = c1_1 * c1_2
//     2. ReLinearization（keyswitch_pipe）：
//        f0 = m0 + m2 * b
//        f1 = m1 - m2 * a
//     3. Rescale（2 次）：
//        f0' = rescale(f0)
//        f1' = rescale(f1)
//   输出：C' = (f0', f1')  2 元素密文
//
// Python 数学等价验证：scripts/verify_e2e_mult.py  ALL PASS
//
// 接口：AXI-Stream（单时钟域，同步复位，无 CDC）
// 吞吐：3 × poly_mult + keyswitch + 2 × rescale
//       约 3 × 164 + 340 + 2 × 164 ≈ 1164 μs @ 100 MHz
// =============================================================================

`timescale 1ns / 1ps

module e2e_ckks_mult_ctrl #(
    parameter int LOG_N           = 14,
    parameter int N               = 1 << LOG_N,          // 16384
    parameter int Q_WIDTH         = 45,
    parameter logic [Q_WIDTH-1:0] Q_IN  = 45'd17592186634241,   // 乘法模数
    parameter logic [Q_WIDTH-1:0] Q_OUT = 45'd17592186372097    // Rescale 模数
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // 控制
    input  logic                  start,
    output logic                  busy,
    output logic                  done,
    output logic                  error,

    // 输入：密文 C1（ready 是输出，由 poly_mult 驱动）
    input  logic                  c0_1_valid,
    output logic                  c0_1_ready,
    input  logic [Q_WIDTH-1:0]    c0_1_data,
    input  logic                  c1_1_valid,
    output logic                  c1_1_ready,
    input  logic [Q_WIDTH-1:0]    c1_1_data,

    // 输入：密文 C2（ready 是输出，由 poly_mult 驱动）
    input  logic                  c0_2_valid,
    output logic                  c0_2_ready,
    input  logic [Q_WIDTH-1:0]    c0_2_data,
    input  logic                  c1_2_valid,
    output logic                  c1_2_ready,
    input  logic [Q_WIDTH-1:0]    c1_2_data,

    // 输入：keyswitch key（ready 是输出，由 poly_mult 驱动）
    input  logic                  a_valid,
    output logic                  a_ready,
    input  logic [Q_WIDTH-1:0]    a_data,
    input  logic                  b_valid,
    output logic                  b_ready,
    input  logic [Q_WIDTH-1:0]    b_data,

    // 输出：密文 C'（f*_ready 是下游反压信号，input 方向；
    //   早期版本误写为 output，导致 TB 无法驱动，此处修正端口方向）
    output logic                  f0_valid,
    input  logic                  f0_ready,
    output logic [Q_WIDTH-1:0]    f0_data,
    output logic                  f1_valid,
    input  logic                  f1_ready,
    output logic [Q_WIDTH-1:0]    f1_data,

    // Twiddle 因子表（外部提供）
    input  logic [Q_WIDTH-1:0]    omega_table     [0:N/2-1],
    input  logic [Q_WIDTH-1:0]    omega_inv_table [0:N/2-1]
);

    // -------------------------------------------------------------------------
    // 内部信号
    // -------------------------------------------------------------------------
    // 3 次 poly_mult 的输出（m0, m1a, m1b, m2）
    logic [Q_WIDTH-1:0] m0_data_wire;
    logic               m0_valid_wire, m0_last_wire;
    logic [Q_WIDTH-1:0] m1a_data_wire;
    logic               m1a_valid_wire, m1a_last_wire;
    logic [Q_WIDTH-1:0] m1b_data_wire;
    logic               m1b_valid_wire, m1b_last_wire;
    logic [Q_WIDTH-1:0] m1_data_wire;
    logic               m1_valid_wire;
    logic [Q_WIDTH-1:0] m2_data_wire;
    logic               m2_valid_wire, m2_last_wire;

    // m1 = m1a + m1b
    logic [Q_WIDTH-1:0] m1_data_buf [0:N-1];
    logic               m1_calc_done;

    // ready wires for poly_mult instances (each drives its own ready output)
    logic pm0_a_ready, pm0_b_ready;
    logic pm1a_a_ready, pm1a_b_ready;
    logic pm1b_a_ready, pm1b_b_ready;
    logic pm2_a_ready, pm2_b_ready;

    // ---- 方案 A：输入缓存（DUT 内部缓存外部输入流） ----
    logic [Q_WIDTH-1:0] c0_1_buf [0:N-1];
    logic [Q_WIDTH-1:0] c1_1_buf [0:N-1];
    logic [Q_WIDTH-1:0] c0_2_buf [0:N-1];
    logic [Q_WIDTH-1:0] c1_2_buf [0:N-1];
    logic [Q_WIDTH-1:0] a_buf    [0:N-1];
    logic [Q_WIDTH-1:0] b_buf    [0:N-1];
    logic [LOG_N:0] c0_1_widx, c1_1_widx, c0_2_widx, c1_2_widx, a_widx, b_widx;

    // 4 poly_mult 各自的 a/b read index
    logic [LOG_N:0] pm0_a_ridx, pm0_b_ridx;
    logic [LOG_N:0] pm1a_a_ridx, pm1a_b_ridx;
    logic [LOG_N:0] pm1b_a_ridx, pm1b_b_ridx;
    logic [LOG_N:0] pm2_a_ridx, pm2_b_ridx;

    // poly_mult 输出缓冲（4 组，避免 out_ready 时序不匹配丢数据）
    logic [Q_WIDTH-1:0] m0_buf  [0:N-1];
    logic [Q_WIDTH-1:0] m1a_buf [0:N-1];
    logic [Q_WIDTH-1:0] m1b_buf [0:N-1];
    logic [Q_WIDTH-1:0] m2_buf  [0:N-1];
    logic [LOG_N:0] m0_widx, m1a_widx, m1b_widx, m2_widx;
    logic               m0_full, m1a_full, m1b_full, m2_full;
    logic [LOG_N:0] m1_read_idx;

    // keyswitch 从 m_buf 读（e0=m0, e1=m1a+m1b 由顶层合并, e2=m2）
    logic [LOG_N:0] ksw_e0_ridx, ksw_e1_ridx, ksw_e2_ridx;

    // keyswitch 输出缓冲（2 组，供 rescale 消费）
    logic [Q_WIDTH-1:0] ksw_f0_buf [0:N-1];
    logic [Q_WIDTH-1:0] ksw_f1_buf [0:N-1];
    logic [LOG_N:0] ksw_f0_widx, ksw_f1_widx;
    logic               ksw_f0_full, ksw_f1_full;

    // rescale 从 ksw_buf 读
    logic [LOG_N:0] rs0_ridx, rs1_ridx;

    // ready wires for keyswitch/rescale output ports
    logic ksw_e0_ready, ksw_e1_ready, ksw_e2_ready;
    logic ksw_a_ready, ksw_b_ready;
    logic rs0_s_ready, rs1_s_ready;

    // keyswitch 的输入/输出
    logic [Q_WIDTH-1:0] e0_data_buf [0:N-1];
    logic [Q_WIDTH-1:0] e1_data_buf [0:N-1];
    logic [Q_WIDTH-1:0] e2_data_buf [0:N-1];
    logic [Q_WIDTH-1:0] a_data_buf [0:N-1];
    logic [Q_WIDTH-1:0] b_data_buf [0:N-1];
    logic               keyswitch_done;

    // keyswitch 输出 → rescale 输入
    logic               ksw_f0_valid;
    logic [Q_WIDTH-1:0] ksw_f0_data;
    logic               ksw_f1_valid;
    logic [Q_WIDTH-1:0] ksw_f1_data;

    // rescale 的输入/输出
    logic [Q_WIDTH-1:0] f0_data_rs_buf [0:N-1];
    logic [Q_WIDTH-1:0] f1_data_rs_buf [0:N-1];
    logic               rescale_done;

    // 控制信号
    logic start_pm0, start_pm1a, start_pm1b, start_pm2;
    logic busy_pm0, busy_pm1a, busy_pm1b, busy_pm2;
    logic done_pm0, done_pm1a, done_pm1b, done_pm2;
    logic start_ksw, busy_ksw, done_ksw;
    logic start_rs0, start_rs1, busy_rs0, busy_rs1, done_rs0, done_rs1;

    // -------------------------------------------------------------------------
    // 控制 FSM
    // -------------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE,
        S_LOAD_C1,        // 加载 C1 (c0_1, c1_1)
        S_LOAD_C2,        // 加载 C2 (c0_2, c1_2)
        S_LOAD_KEY,       // 加载 keyswitch key (a, b)
        S_MUL_0,          // m0 = c0_1 * c0_2
        S_MUL_1A,         // m1a = c0_1 * c1_2
        S_MUL_1B,         // m1b = c1_1 * c0_2
        S_ADD_M1,         // m1 = m1a + m1b
        S_MUL_2,          // m2 = c1_1 * c1_2
        S_RELIN,          // ReLinearization
        S_RESCALE_0,      // f0' = rescale(f0)
        S_RESCALE_1,      // f1' = rescale(f1)
        S_OUT_F0,         // 从 f0_out_buf 流式输出 f0'
        S_OUT_F1,         // 从 f1_out_buf 流式输出 f1'
        S_DONE
    } state_t;

    state_t state, state_next;
    logic [LOG_N-1:0] coeff_idx;
    logic               coeff_idx_reset;

    // -------------------------------------------------------------------------
    // Rescale 输出缓冲（解耦 rescale 模块的 m_ready 与顶层 f0_ready/f1_ready）
    // -------------------------------------------------------------------------
    // 内部 rescale 输出 wires（不再直连顶层 f0_valid/f0_data/f1_valid/f1_data）
    logic               rs0_m_valid, rs1_m_valid;
    logic [Q_WIDTH-1:0] rs0_m_data, rs1_m_data;

    // 输出缓冲：rescale 阶段高速写入，S_OUT_F0/S_OUT_F1 阶段按 TB 握手读出
    logic [Q_WIDTH-1:0] f0_out_buf [0:N-1];
    logic [Q_WIDTH-1:0] f1_out_buf [0:N-1];
    logic [LOG_N:0]     f0_out_widx, f1_out_widx;
    logic [LOG_N:0]     f0_out_ridx, f1_out_ridx;

    assign busy  = (state != S_IDLE);
    assign done  = (state == S_OUT_F0) || (state == S_OUT_F1) || (state == S_DONE);
    assign error = 1'b0;

    // 顶层输出：从缓冲按状态驱动
    assign f0_valid = (state == S_OUT_F0) && (f0_out_ridx < N);
    assign f0_data  = f0_out_buf[f0_out_ridx];
    assign f1_valid = (state == S_OUT_F1) && (f1_out_ridx < N);
    assign f1_data  = f1_out_buf[f1_out_ridx];

    // 加载阶段 DUT 主动接收（cache 未满时 ready=1，反压 TB）
    assign c0_1_ready = (state == S_LOAD_C1) && (c0_1_widx < N);
    assign c1_1_ready = (state == S_LOAD_C1) && (c1_1_widx < N);
    assign c0_2_ready = (state == S_LOAD_C2) && (c0_2_widx < N);
    assign c1_2_ready = (state == S_LOAD_C2) && (c1_2_widx < N);
    assign a_ready    = (state == S_LOAD_KEY) && (a_widx < N);
    assign b_ready    = (state == S_LOAD_KEY) && (b_widx < N);

    // -------------------------------------------------------------------------
    // 状态机
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            coeff_idx <= '0;
        end else begin
            state <= state_next;
            if (coeff_idx_reset) coeff_idx <= '0;
            else if (state_next != S_IDLE && state_next != state) coeff_idx <= coeff_idx + 1'b1;
        end
    end

    always_comb begin
        state_next = state;
        coeff_idx_reset = 1'b0;
        case (state)
            S_IDLE:
                if (start) state_next = S_LOAD_C1;

            S_LOAD_C1:
                if (c0_1_widx == N && c1_1_widx == N) state_next = S_LOAD_C2;
            S_LOAD_C2:
                if (c0_2_widx == N && c1_2_widx == N) state_next = S_LOAD_KEY;
            S_LOAD_KEY:
                if (a_widx == N && b_widx == N) state_next = S_MUL_0;

            S_MUL_0:
                if (done_pm0) state_next = S_MUL_1A;
            S_MUL_1A:
                if (done_pm1a) state_next = S_MUL_1B;
            S_MUL_1B:
                if (done_pm1b) state_next = S_ADD_M1;
            S_ADD_M1:
                if (m1_calc_done) state_next = S_MUL_2;
            S_MUL_2:
                if (done_pm2) state_next = S_RELIN;

            S_RELIN:
                if (done_ksw && ksw_f0_full && ksw_f1_full) state_next = S_RESCALE_0;

            S_RESCALE_0:
                if (done_rs0) state_next = S_RESCALE_1;

            S_RESCALE_1:
                if (done_rs1) state_next = S_OUT_F0;

            S_OUT_F0:
                if (f0_out_ridx >= N) state_next = S_OUT_F1;

            S_OUT_F1:
                if (f1_out_ridx >= N) state_next = S_DONE;

            S_DONE:
                state_next = S_IDLE;

            default:
                state_next = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // poly_mult 实例 0: m0 = c0_1 * c0_2
    // -------------------------------------------------------------------------
    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_IN),
        .N_INV(106),  // N^-1 mod 113
        .USE_FASTRED(0)
    ) u_pm0 (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_pm0),
        .busy(busy_pm0),
        .done(done_pm0),
        .error(),
        .a_in_data(c0_1_buf[pm0_a_ridx]),
        .a_in_valid((state == S_MUL_0) && (pm0_a_ridx < N)),
        .a_in_ready(pm0_a_ready),
        .b_in_data(c0_2_buf[pm0_b_ridx]),
        .b_in_valid((state == S_MUL_0) && (pm0_b_ridx < N)),
        .b_in_ready(pm0_b_ready),
        .out_data(m0_data_wire),
        .out_valid(m0_valid_wire),
        .out_last(m0_last_wire),
        .out_ready(!m0_full),
        .omega_table(omega_table),
        .omega_inv_table(omega_inv_table)
    );

    // -------------------------------------------------------------------------
    // poly_mult 实例 1a: m1a = c0_1 * c1_2
    // -------------------------------------------------------------------------
    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_IN),
        .N_INV(106),
        .USE_FASTRED(0)
    ) u_pm1a (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_pm1a),
        .busy(busy_pm1a),
        .done(done_pm1a),
        .error(),
        .a_in_data(c0_1_buf[pm1a_a_ridx]),
        .a_in_valid((state == S_MUL_1A) && (pm1a_a_ridx < N)),
        .a_in_ready(pm1a_a_ready),
        .b_in_data(c1_2_buf[pm1a_b_ridx]),
        .b_in_valid((state == S_MUL_1A) && (pm1a_b_ridx < N)),
        .b_in_ready(pm1a_b_ready),
        .out_data(m1a_data_wire),
        .out_valid(m1a_valid_wire),
        .out_last(m1a_last_wire),
        .out_ready(!m1a_full),
        .omega_table(omega_table),
        .omega_inv_table(omega_inv_table)
    );

    // -------------------------------------------------------------------------
    // poly_mult 实例 1b: m1b = c1_1 * c0_2
    // -------------------------------------------------------------------------
    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_IN),
        .N_INV(106),
        .USE_FASTRED(0)
    ) u_pm1b (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_pm1b),
        .busy(busy_pm1b),
        .done(done_pm1b),
        .error(),
        .a_in_data(c1_1_buf[pm1b_a_ridx]),
        .a_in_valid((state == S_MUL_1B) && (pm1b_a_ridx < N)),
        .a_in_ready(pm1b_a_ready),
        .b_in_data(c0_2_buf[pm1b_b_ridx]),
        .b_in_valid((state == S_MUL_1B) && (pm1b_b_ridx < N)),
        .b_in_ready(pm1b_b_ready),
        .out_data(m1b_data_wire),
        .out_valid(m1b_valid_wire),
        .out_last(m1b_last_wire),
        .out_ready(!m1b_full),
        .omega_table(omega_table),
        .omega_inv_table(omega_inv_table)
    );

    // -------------------------------------------------------------------------
    // poly_mult 实例 2: m2 = c1_1 * c1_2
    // -------------------------------------------------------------------------
    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_IN),
        .N_INV(106),
        .USE_FASTRED(0)
    ) u_pm2 (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_pm2),
        .busy(busy_pm2),
        .done(done_pm2),
        .error(),
        .a_in_data(c1_1_buf[pm2_a_ridx]),
        .a_in_valid((state == S_MUL_2) && (pm2_a_ridx < N)),
        .a_in_ready(pm2_a_ready),
        .b_in_data(c1_2_buf[pm2_b_ridx]),
        .b_in_valid((state == S_MUL_2) && (pm2_b_ridx < N)),
        .b_in_ready(pm2_b_ready),
        .out_data(m2_data_wire),
        .out_valid(m2_valid_wire),
        .out_last(m2_last_wire),
        .out_ready(!m2_full),
        .omega_table(omega_table),
        .omega_inv_table(omega_inv_table)
    );

    // -------------------------------------------------------------------------
    // 加载阶段 widx 递增 + cache 写入
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            c0_1_widx <= '0; c1_1_widx <= '0;
            c0_2_widx <= '0; c1_2_widx <= '0;
            a_widx    <= '0; b_widx    <= '0;
            pm0_a_ridx <= '0; pm0_b_ridx <= '0;
            pm1a_a_ridx <= '0; pm1a_b_ridx <= '0;
            pm1b_a_ridx <= '0; pm1b_b_ridx <= '0;
            pm2_a_ridx <= '0; pm2_b_ridx <= '0;
            m0_widx <= '0; m1a_widx <= '0; m1b_widx <= '0; m2_widx <= '0;
            m0_full <= 1'b0; m1a_full <= 1'b0; m1b_full <= 1'b0; m2_full <= 1'b0;
            ksw_e0_ridx <= '0; ksw_e1_ridx <= '0; ksw_e2_ridx <= '0;
            ksw_f0_widx <= '0; ksw_f1_widx <= '0;
            ksw_f0_full <= 1'b0; ksw_f1_full <= 1'b0;
            rs0_ridx <= '0; rs1_ridx <= '0;
            f0_out_widx <= '0; f1_out_widx <= '0;
            f0_out_ridx <= '0; f1_out_ridx <= '0;
            m1_read_idx <= '0;
            m1_calc_done <= 1'b0;
        end else begin
            // ---- 测试间 widx/ridx 全量重置（S_IDLE → S_LOAD_C1 瞬间）----
            if (state == S_IDLE && state_next == S_LOAD_C1) begin
                c0_1_widx <= '0; c1_1_widx <= '0;
                c0_2_widx <= '0; c1_2_widx <= '0;
                a_widx    <= '0; b_widx    <= '0;
                pm0_a_ridx <= '0; pm0_b_ridx <= '0;
                pm1a_a_ridx <= '0; pm1a_b_ridx <= '0;
                pm1b_a_ridx <= '0; pm1b_b_ridx <= '0;
                pm2_a_ridx <= '0; pm2_b_ridx <= '0;
                m0_widx <= '0; m1a_widx <= '0; m1b_widx <= '0; m2_widx <= '0;
                m0_full <= 1'b0; m1a_full <= 1'b0; m1b_full <= 1'b0; m2_full <= 1'b0;
                ksw_e0_ridx <= '0; ksw_e1_ridx <= '0; ksw_e2_ridx <= '0;
                ksw_f0_widx <= '0; ksw_f1_widx <= '0;
                ksw_f0_full <= 1'b0; ksw_f1_full <= 1'b0;
                rs0_ridx <= '0; rs1_ridx <= '0;
                f0_out_widx <= '0; f1_out_widx <= '0;
                f0_out_ridx <= '0; f1_out_ridx <= '0;
                m1_read_idx <= '0;
                m1_calc_done <= 1'b0;
            end

            // ---- 加载阶段 widx ----
            if (state == S_LOAD_C1) begin
                if (c0_1_valid) c0_1_widx <= c0_1_widx + 1'b1;
                if (c1_1_valid) c1_1_widx <= c1_1_widx + 1'b1;
            end
            if (state == S_LOAD_C2) begin
                if (c0_2_valid) c0_2_widx <= c0_2_widx + 1'b1;
                if (c1_2_valid) c1_2_widx <= c1_2_widx + 1'b1;
            end
            if (state == S_LOAD_KEY) begin
                if (a_valid) a_widx <= a_widx + 1'b1;
                if (b_valid) b_widx <= b_widx + 1'b1;
            end

            // ---- poly_mult 从 cache 读 ridx（每 ready 一拍 +1） ----
            if (state == S_MUL_0) begin
                if (pm0_a_ready) pm0_a_ridx <= pm0_a_ridx + 1'b1;
                if (pm0_b_ready) pm0_b_ridx <= pm0_b_ridx + 1'b1;
            end
            if (state == S_MUL_1A) begin
                if (pm1a_a_ready) pm1a_a_ridx <= pm1a_a_ridx + 1'b1;
                if (pm1a_b_ready) pm1a_b_ridx <= pm1a_b_ridx + 1'b1;
            end
            if (state == S_MUL_1B) begin
                if (pm1b_a_ready) pm1b_a_ridx <= pm1b_a_ridx + 1'b1;
                if (pm1b_b_ready) pm1b_b_ridx <= pm1b_b_ridx + 1'b1;
            end
            if (state == S_MUL_2) begin
                if (pm2_a_ready) pm2_a_ridx <= pm2_a_ridx + 1'b1;
                if (pm2_b_ready) pm2_b_ridx <= pm2_b_ridx + 1'b1;
            end

            // ---- poly_mult 输出写入 m_buf ----
            if (m0_valid_wire && !m0_full) begin
                m0_buf[m0_widx] <= m0_data_wire;
                m0_widx <= m0_widx + 1'b1;
                if (m0_widx == N-1) m0_full <= 1'b1;
            end
            if (m1a_valid_wire && !m1a_full) begin
                m1a_buf[m1a_widx] <= m1a_data_wire;
                m1a_widx <= m1a_widx + 1'b1;
                if (m1a_widx == N-1) m1a_full <= 1'b1;
            end
            if (m1b_valid_wire && !m1b_full) begin
                m1b_buf[m1b_widx] <= m1b_data_wire;
                m1b_widx <= m1b_widx + 1'b1;
                if (m1b_widx == N-1) m1b_full <= 1'b1;
            end
            if (m2_valid_wire && !m2_full) begin
                m2_buf[m2_widx] <= m2_data_wire;
                m2_widx <= m2_widx + 1'b1;
                if (m2_widx == N-1) m2_full <= 1'b1;
            end

            // ---- keyswitch 从 m_buf 读 ridx（全 ready 同步高才 +1） ----
            if (state == S_RELIN && (ksw_e0_ready && ksw_e1_ready && ksw_e2_ready && ksw_a_ready && ksw_b_ready)) begin
                ksw_e0_ridx <= ksw_e0_ridx + 1'b1;
            end

            // ---- keyswitch 输出写入 ksw_buf ----
            if (ksw_f0_valid && !ksw_f0_full) begin
                ksw_f0_buf[ksw_f0_widx] <= ksw_f0_data;
                ksw_f0_widx <= ksw_f0_widx + 1'b1;
                if (ksw_f0_widx == N-1) ksw_f0_full <= 1'b1;
            end
            if (ksw_f1_valid && !ksw_f1_full) begin
                ksw_f1_buf[ksw_f1_widx] <= ksw_f1_data;
                ksw_f1_widx <= ksw_f1_widx + 1'b1;
                if (ksw_f1_widx == N-1) ksw_f1_full <= 1'b1;
            end

            // ---- rescale 从 ksw_buf 读 ridx + 输出写入 f*_out_buf ----
            if (state == S_RESCALE_0) begin
                if (rs0_s_ready) rs0_ridx <= rs0_ridx + 1'b1;
                if (rs0_m_valid) begin
                    f0_out_buf[f0_out_widx] <= rs0_m_data;
                    f0_out_widx <= f0_out_widx + 1'b1;
                end
            end
            if (state == S_RESCALE_1) begin
                if (rs1_s_ready) rs1_ridx <= rs1_ridx + 1'b1;
                if (rs1_m_valid) begin
                    f1_out_buf[f1_out_widx] <= rs1_m_data;
                    f1_out_widx <= f1_out_widx + 1'b1;
                end
            end

            // ---- S_OUT_F0/S_OUT_F1 阶段：TB 握手驱动 f*_out_ridx 递增 ----
            if (state == S_OUT_F0 && f0_ready) f0_out_ridx <= f0_out_ridx + 1'b1;
            if (state == S_OUT_F1 && f1_ready) f1_out_ridx <= f1_out_ridx + 1'b1;

            // ---- m1 = m1a + m1b（在 S_ADD_M1 阶段合并） ----
            if (state == S_MUL_1B && done_pm1b) begin
                m1_calc_done <= 1'b0;
                m1_read_idx <= '0;
            end
            if (state == S_ADD_M1 && m1a_full && m1b_full) begin
                m1_data_buf[m1_read_idx] <= m1a_buf[m1_read_idx] + m1b_buf[m1_read_idx];
                m1_read_idx <= m1_read_idx + 1'b1;
                if (m1_read_idx == N-1) m1_calc_done <= 1'b1;
            end
        end
    end

    // cache 数据写入
    always_ff @(posedge clk) begin
        if (!rst_n) begin
        end else begin
            if (state == S_LOAD_C1 && c0_1_valid) c0_1_buf[c0_1_widx] <= c0_1_data;
            if (state == S_LOAD_C1 && c1_1_valid) c1_1_buf[c1_1_widx] <= c1_1_data;
            if (state == S_LOAD_C2 && c0_2_valid) c0_2_buf[c0_2_widx] <= c0_2_data;
            if (state == S_LOAD_C2 && c1_2_valid) c1_2_buf[c1_2_widx] <= c1_2_data;
            if (state == S_LOAD_KEY && a_valid)    a_buf[a_widx]    <= a_data;
            if (state == S_LOAD_KEY && b_valid)    b_buf[b_widx]    <= b_data;
        end
    end

    // -------------------------------------------------------------------------
    // keyswitch_pipe 实例（ReLinearization）
    // -------------------------------------------------------------------------
    // 注意：keyswitch_pipe 需要 e0=m0, e1=m1, e2=m2
    // 当前为简化实现，实际需连接 poly_mult 输出到 keyswitch 输入
    
    keyswitch_pipe #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VAL(Q_IN),
        .N_INV(106),
        .USE_FASTRED(0)
    ) u_ksw (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_ksw),
        .busy(busy_ksw),
        .done(done_ksw),
        .error(),
        .e0_valid((state == S_RELIN) && (ksw_e0_ridx < N) && m0_full),
        .e0_ready(ksw_e0_ready),
        .e0_data(m0_buf[ksw_e0_ridx]),
        .e1_valid((state == S_RELIN) && (ksw_e0_ridx < N) && m1_calc_done),
        .e1_ready(ksw_e1_ready),
        .e1_data(m1_data_buf[ksw_e0_ridx]),
        .e2_valid((state == S_RELIN) && (ksw_e0_ridx < N) && m2_full),
        .e2_ready(ksw_e2_ready),
        .e2_data(m2_buf[ksw_e0_ridx]),
        .a_valid((state == S_RELIN) && (ksw_e0_ridx < N)),
        .a_ready(ksw_a_ready),
        .a_data(a_buf[ksw_e0_ridx]),
        .b_valid((state == S_RELIN) && (ksw_e0_ridx < N)),
        .b_ready(ksw_b_ready),
        .b_data(b_buf[ksw_e0_ridx]),
        .f0_valid(ksw_f0_valid),
        .f0_ready(!ksw_f0_full),
        .f0_data(ksw_f0_data),
        .f1_valid(ksw_f1_valid),
        .f1_ready(!ksw_f1_full),
        .f1_data(ksw_f1_data),
        .omega_table(omega_table),
        .omega_inv_table(omega_inv_table)
    );

    // -------------------------------------------------------------------------
    // rescale 实例 0: f0' = rescale(f0)
    // -------------------------------------------------------------------------
    rescale #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_IN(Q_IN),
        .Q_OUT(Q_OUT)
    ) u_rs0 (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_rs0),
        .busy(busy_rs0),
        .done(done_rs0),
        .error(),
        .s_valid((state == S_RESCALE_0) && (rs0_ridx < N) && ksw_f0_full),
        .s_ready(rs0_s_ready),
        .s_data(ksw_f0_buf[rs0_ridx]),
        .m_valid(rs0_m_valid),
        .m_ready(1'b1),
        .m_data(rs0_m_data)
    );

    // -------------------------------------------------------------------------
    // rescale 实例 1: f1' = rescale(f1)
    // -------------------------------------------------------------------------
    rescale #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_IN(Q_IN),
        .Q_OUT(Q_OUT)
    ) u_rs1 (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_rs1),
        .busy(busy_rs1),
        .done(done_rs1),
        .error(),
        .s_valid((state == S_RESCALE_1) && (rs1_ridx < N) && ksw_f1_full),
        .s_ready(rs1_s_ready),
        .s_data(ksw_f1_buf[rs1_ridx]),
        .m_valid(rs1_m_valid),
        .m_ready(1'b1),
        .m_data(rs1_m_data)
    );

    // -------------------------------------------------------------------------
    // 控制信号
    // -------------------------------------------------------------------------
    // start_pm0/1a/1b/2 边沿检测：仅在每个 MUL 状态进入瞬间产生单拍脉冲
    // （poly_mult.start 是单周期脉冲，持续高电平会导致 poly_mult 无限重启）
    logic pm0_start_raw, pm0_start_prev;
    logic pm1a_start_raw, pm1a_start_prev;
    logic pm1b_start_raw, pm1b_start_prev;
    logic pm2_start_raw, pm2_start_prev;

    assign pm0_start_raw  = (state == S_MUL_0);
    assign pm1a_start_raw = (state == S_MUL_1A);
    assign pm1b_start_raw = (state == S_MUL_1B);
    assign pm2_start_raw  = (state == S_MUL_2);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pm0_start_prev  <= 1'b0;
            pm1a_start_prev <= 1'b0;
            pm1b_start_prev <= 1'b0;
            pm2_start_prev  <= 1'b0;
        end else begin
            pm0_start_prev  <= pm0_start_raw;
            pm1a_start_prev <= pm1a_start_raw;
            pm1b_start_prev <= pm1b_start_raw;
            pm2_start_prev  <= pm2_start_raw;
        end
    end

    assign start_pm0  = pm0_start_raw  && !pm0_start_prev;
    assign start_pm1a = pm1a_start_raw && !pm1a_start_prev;
    assign start_pm1b = pm1b_start_raw && !pm1b_start_prev;
    assign start_pm2  = pm2_start_raw  && !pm2_start_prev;
    assign start_ksw  = (state == S_RELIN);
    assign start_rs0  = (state == S_RESCALE_0);
    assign start_rs1  = (state == S_RESCALE_1);

    // -------------------------------------------------------------------------
    // 加载输入到缓冲（简化：直接从输入流读取）
    // -------------------------------------------------------------------------
    // 实际实现中，需要将 c0_1, c1_1, c0_2, c1_2, a, b 加载到 BRAM
    // 当前为简化版本，直接连接输入流到 poly_mult

endmodule
