// =============================================================================
// activation_approx.sv - 激活函数近似单元（Chebyshev 多项式）
// =============================================================================
// Phase 5 Task 5.1.3 (v3 - 状态机重写 + Horner 组合逻辑)
//
// 功能：
// - 用 Chebyshev 多项式近似 ReLU/Sigmoid/Tanh
// - 分段拟合（[-1,0] 和 [0,1] 两段）
// - Horner 展开多项式求值（组合逻辑，单拍完成）
// - 支持向量处理：逐元素接收 N 个输入，逐元素输出 N 个结果
//
// v3 修复（2026-10-19）：
// - 重写状态机为 S_IDLE→S_LOAD→S_INPUT→S_OUTPUT→S_DONE→S_IDLE
// - s_ready 在 S_INPUT 状态有效（原为 S_IDLE && act_valid，导致无法接收输入）
// - Horner 改为组合逻辑（非阻塞赋值不链式传播，原实现计算错误）
// - 增加 result_buf[N] 存储逐元素计算结果
// - 修正 current_coeff 采样时机（在 S_INPUT 时从已加载的 coeffs 数组读取）
// - 修正 output_cnt 边界条件
// =============================================================================

`default_nettype none

module activation_approx #(
    parameter int Q_WIDTH = 45,
    parameter int N = 4096,
    parameter int LOG_N = 12,
    parameter int POLY_ORDER = 5,           // Chebyshev 阶数
    parameter int NUM_SEGMENTS = 2,          // 分段数
    parameter int COEFF_WIDTH = 30,          // 多项式系数位宽
    parameter int COEFF_SIGN = 1             // 系数带符号
) (
    input wire logic               clk,
    input wire logic               rst_n,

    // 控制
    input wire logic [1:0]         act_type,    // 00=ReLU, 01=Sigmoid, 10=Tanh, 11=Linear
    input wire logic               act_valid,   // 激活启动脉冲
    output logic               act_busy,    // 计算中
    output logic               act_done,    // 计算完成脉冲
    output logic               act_error,   // 错误标志

    // 输入多项式（AXI4-Stream）
    input wire logic [Q_WIDTH-1:0] s_tdata,
    input wire logic               s_valid,
    output logic               s_ready,
    input wire logic               s_last,

    // 输出多项式（AXI4-Stream）
    output logic [Q_WIDTH-1:0] m_tdata,
    output logic               m_valid,
    output logic               m_last,
    input wire logic               m_ready,

    // 多项式系数配置（来自 ml_model_config）
    input wire logic [1:0]         coeff_sel,   // 选择激活函数
    input wire logic [COEFF_WIDTH-1:0] coeff_data,
    input wire logic               coeff_valid,
    output logic               coeff_ready,
    input wire logic [7:0]         coeff_addr   // 系数索引
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam int COEFF_COUNT = (POLY_ORDER + 1);
    localparam int TOTAL_COEFFS = NUM_SEGMENTS * COEFF_COUNT;
    localparam int COEFF_DEPTH = 4 * TOTAL_COEFFS;  // 4 activation types (ReLU/Sigmoid/Tanh/Linear)

    // 状态机
    localparam logic [3:0] S_IDLE   = 4'd0;
    localparam logic [3:0] S_LOAD   = 4'd1;
    localparam logic [3:0] S_INPUT  = 4'd2;
    localparam logic [3:0] S_OUTPUT = 4'd3;
    localparam logic [3:0] S_DONE   = 4'd4;
    localparam logic [3:0] S_ERROR  = 4'd5;

    // =========================================================================
    // 状态寄存器
    // =========================================================================
    logic [3:0]                state;
    logic [3:0]                state_next;
    logic [11:0]               coeff_idx;
    logic [LOG_N:0]            input_cnt;
    logic [LOG_N:0]            output_cnt;

    // 多项式系数存储
    logic signed [COEFF_WIDTH-1:0] coeffs [0:COEFF_DEPTH-1];

    // 当前段系数（组合逻辑，从 coeffs 数组实时读取）
    logic signed [COEFF_WIDTH-1:0] current_coeff [0:COEFF_COUNT-1];

    // 结果缓冲（逐元素存储）
    logic signed [Q_WIDTH-1:0] result_buf [0:N-1];

    // 分段判断
    logic                       is_negative;
    logic [1:0]                 segment_sel;

    // Horner 展开结果（组合逻辑）
    logic signed [Q_WIDTH-1:0] horner_result;

    // 分段判断（根据 s_tdata 符号选择分段，组合逻辑）
    assign is_negative = s_tdata[Q_WIDTH-1];

    always_comb begin
        case (is_negative)
            1'b1: segment_sel = 2'd0;  // [-1, 0] 段
            1'b0: segment_sel = 2'd1;  // [0, 1] 段
            default: segment_sel = 2'd1;
        endcase
    end

    // =========================================================================
    // 当前段系数选择（组合逻辑，从 coeffs 数组读取）
    // =========================================================================
    always_comb begin
        current_coeff[0] = coeffs[coeff_sel * TOTAL_COEFFS + segment_sel * COEFF_COUNT + 0];
        current_coeff[1] = coeffs[coeff_sel * TOTAL_COEFFS + segment_sel * COEFF_COUNT + 1];
        current_coeff[2] = coeffs[coeff_sel * TOTAL_COEFFS + segment_sel * COEFF_COUNT + 2];
        current_coeff[3] = coeffs[coeff_sel * TOTAL_COEFFS + segment_sel * COEFF_COUNT + 3];
        current_coeff[4] = coeffs[coeff_sel * TOTAL_COEFFS + segment_sel * COEFF_COUNT + 4];
        if (POLY_ORDER >= 5) begin
            current_coeff[5] = coeffs[coeff_sel * TOTAL_COEFFS + segment_sel * COEFF_COUNT + 5];
        end
    end

    // =========================================================================
    // Horner 展开多项式求值（组合逻辑，单拍完成）
    // P(x) = c0 + c1*x + c2*x^2 + ... + c(order)*x^order
    // Horner: P(x) = c0 + x*(c1 + x*(c2 + ... x*(c(order-1) + x*c(order)) ...))
    //
    // 直接从 s_tdata 计算（不经过 input_buf 寄存器），
    // 避免非阻塞赋值不链式传播的问题。
    // =========================================================================
    always_comb begin
        automatic logic signed [Q_WIDTH-1:0] t;
        automatic logic signed [Q_WIDTH-1:0] x = $signed(s_tdata);
        t = current_coeff[POLY_ORDER];
        t = current_coeff[POLY_ORDER - 1] + x * t;
        t = current_coeff[POLY_ORDER - 2] + x * t;
        t = current_coeff[POLY_ORDER - 3] + x * t;
        t = current_coeff[POLY_ORDER - 4] + x * t;
        if (POLY_ORDER >= 5) begin
            t = current_coeff[POLY_ORDER - 5] + x * t;
        end
        horner_result = t;
    end

    // =========================================================================
    // 系数加载
    // =========================================================================
    assign coeff_ready = (state == S_LOAD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coeff_idx <= 12'd0;
        end else if (state == S_LOAD) begin
            if (coeff_valid && coeff_ready) begin
                coeffs[coeff_sel * TOTAL_COEFFS + coeff_idx] <= coeff_data;
                coeff_idx <= coeff_idx + 12'd1;
            end
        end else if (state == S_IDLE) begin
            coeff_idx <= 12'd0;
        end
    end

    // =========================================================================
    // 状态机 - 次态逻辑
    // =========================================================================
    always_comb begin
        state_next = state;

        case (state)
            S_IDLE: begin
                if (act_valid) begin
                    state_next = S_LOAD;
                end
            end

            S_LOAD: begin
                if (coeff_idx >= TOTAL_COEFFS) begin
                    state_next = S_INPUT;
                end
            end

            S_INPUT: begin
                if (input_cnt >= N[LOG_N:0]) begin
                    state_next = S_OUTPUT;
                end
            end

            S_OUTPUT: begin
                if (output_cnt >= N[LOG_N:0]) begin
                    state_next = S_DONE;
                end
            end

            S_DONE: begin
                state_next = S_IDLE;
            end

            S_ERROR: begin
                state_next = S_IDLE;
            end

            default: begin
                state_next = S_IDLE;
            end
        endcase
    end

    // =========================================================================
    // 状态机 - 状态寄存器
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= state_next;
        end
    end

    // =========================================================================
    // 逐元素计算与结果存储
    // =========================================================================
    assign s_ready = (state == S_INPUT);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_cnt <= 13'd0;
        end else if (state == S_INPUT) begin
            if (s_valid && s_ready && input_cnt < N[LOG_N:0]) begin
                result_buf[input_cnt] <= horner_result;
                input_cnt <= input_cnt + 13'd1;
            end
        end else if (state == S_IDLE) begin
            input_cnt <= 13'd0;
        end
    end

    // =========================================================================
    // 输出驱动
    // =========================================================================
    assign m_valid = (state == S_OUTPUT);
    assign m_last  = (state == S_OUTPUT) && (output_cnt >= (N[LOG_N:0] - 1));
    assign m_tdata = result_buf[output_cnt];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_cnt <= 13'd0;
        end else if (state == S_OUTPUT) begin
            if (m_valid && m_ready) begin
                output_cnt <= output_cnt + 13'd1;
            end
        end else if (state == S_DONE) begin
            output_cnt <= 13'd0;
        end else if (state == S_IDLE) begin
            output_cnt <= 13'd0;
        end
    end

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign act_busy  = (state != S_IDLE);
    assign act_done  = (state == S_DONE);
    assign act_error = (state == S_ERROR);

endmodule

`default_nettype wire
