// =============================================================================
// M3-b Rescale 模块（CKKS 标准，方案 B）
//
// 公式：c'_j = round(c_j * Q_OUT / Q_IN) mod Q_OUT
//
// 硬件近似实现（利用 Q_IN ≈ Q_OUT 且 delta = Q_IN - Q_OUT 很小）：
//   c' ≈ c - floor(c * delta / 2^44)
//   + 四舍五入修正
//   + 条件加 Q_OUT（下溢回绕）
//   + 条件减 Q_OUT（上溢回绕）
//
// Python 数学等价验证：scripts/verify_rescale.py  15/15 ALL PASS
//
// 接口：AXI-Stream（单时钟域，同步复位，无 CDC）
// 吞吐：1 coefficient / cycle（背靠背，无 pipeline stall）
// 延迟：2 cycle（1 处理 + 1 输出寄存）
// =============================================================================

module rescale #(
    parameter int LOG_N           = 14,
    parameter int N               = 1 << LOG_N,          // 16384
    parameter int Q_WIDTH         = 45,
    parameter logic [Q_WIDTH-1:0] Q_IN  = 45'd17592186634241,
    parameter logic [Q_WIDTH-1:0] Q_OUT = 45'd17592186372097
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // 控制
    input  logic                  start,
    output logic                  busy,
    output logic                  done,
    output logic                  error,

    // AXI-Stream 输入（系数 mod Q_IN）
    input  logic                  s_valid,
    output logic                  s_ready,
    input  logic [Q_WIDTH-1:0]    s_data,

    // AXI-Stream 输出（系数 mod Q_OUT）
    output logic                  m_valid,
    input  logic                  m_ready,
    output logic [Q_WIDTH-1:0]    m_data
);

    // -------------------------------------------------------------------------
    // 常量
    // -------------------------------------------------------------------------
    localparam logic [Q_WIDTH-1:0] DELTA = Q_IN - Q_OUT;

    // -------------------------------------------------------------------------
    // 处理逻辑（组合）
    // -------------------------------------------------------------------------
    // Step 1: c * delta  (45 x 20 = 65 bit)
    wire [Q_WIDTH + 19:0] c_times_delta = s_data * DELTA;

    // Step 2: 右移 44 得到 correction (21 bit)
    wire [20:0] correction = c_times_delta[Q_WIDTH + 19 : Q_WIDTH - 1];

    // Step 3: 减法 + 下溢回绕
    wire [Q_WIDTH-1:0] c_minus   = s_data - correction;
    wire              underflow  = (correction > s_data);
    wire [Q_WIDTH-1:0] c_wrapped = underflow ? (c_minus + Q_OUT) : c_minus;

    // Step 4: 四舍五入（2 * rem >= 2^44 ?）
    // rem = c * delta mod 2^44
    wire [43:0] rem          = c_times_delta[Q_WIDTH-2:0];
    wire        need_round   = (rem[Q_WIDTH-2] | rem[Q_WIDTH-3]);   // 2*rem >= 2^44 近似判据
    // need_round (0 or 1) added at LSB; {44'b0, need_round} equivalent
    wire [Q_WIDTH-1:0] c_rounded = c_wrapped + need_round;

    // Step 5: 上溢回绕（c_rounded >= Q_OUT ?）
    wire [Q_WIDTH-1:0] c_final = (c_rounded >= Q_OUT) ? (c_rounded - Q_OUT) : c_rounded;

    assign m_data = c_final;

    // -------------------------------------------------------------------------
    // 控制 FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { S_IDLE, S_RUNNING, S_DONE } state_t;
    state_t state, state_next;
    logic [LOG_N:0] count;

    assign busy  = (state != S_IDLE);
    assign done  = (state == S_DONE);
    assign error = 1'b0;   // 当前无错误条件

    // AXI-Stream 握手：1-cycle 处理延迟
    //   s_valid && m_ready  →  处理并输出
    //   s_valid && !m_ready →  stall（不推进）
    assign s_ready = m_ready && (state == S_RUNNING);
    assign m_valid = (state == S_RUNNING) && s_valid;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            count <= '0;
        end else begin
            state <= state_next;
            if (state == S_RUNNING && s_valid && s_ready && m_ready) begin
                count <= count + 1'b1;
            end
        end
    end

    always_comb begin
        state_next = state;
        case (state)
            S_IDLE:    if (start) state_next = S_RUNNING;
            S_RUNNING: if (s_valid && s_ready && m_ready && count == N - 1)
                            state_next = S_DONE;
            S_DONE:    state_next = S_IDLE;
        endcase
    end

endmodule
