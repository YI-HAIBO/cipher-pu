// =============================================================================
// noise_monitor.sv — CKKS 噪声能量监测器（M4-h）
//
// 算法：
//   对每个输入的模数系数 s_data ∈ [0, q_val-1]，计算其噪声幅度：
//     noise = min(s_data, q_val - s_data)   // 到最近"零端"的距离
//   累加平方和：
//     energy_sum = Σ noise²
//   load_start 脉冲触发除以 N 的恢复除法：
//     energy_q2 = energy_sum / N
//   输出单拍 flush_valid 脉冲 + energy_q2 + sample_count。
// =============================================================================

`timescale 1ns / 1ps

module noise_monitor #(
    parameter int Q_WIDTH = 7,
    parameter int N       = 16,
    parameter int ACC_W   = 106
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  load_start,
    input  logic                  s_valid,
    input  logic [Q_WIDTH-1:0]    s_data,
    input  logic [Q_WIDTH-1:0]    q_val,
    output logic [ACC_W-1:0]      energy_q2,
    output logic [Q_WIDTH+8:0]    sample_count,
    output logic                  flush_valid,
    output logic                  saturated
);

    // =========================================================================
    // 本地参数
    // =========================================================================
    localparam int NOISE_W = Q_WIDTH;
    localparam int SQ_W    = 2*Q_WIDTH;
    localparam int SUM_W   = ACC_W;
    localparam int CNT_W   = Q_WIDTH + 9;

    // =========================================================================
    // 噪声幅度计算：noise = min(s_data, q_val - s_data)
    // =========================================================================
    wire [Q_WIDTH-1:0] q_minus_s = q_val - s_data;
    wire [Q_WIDTH-1:0] noise_abs = (q_minus_s < s_data) ? q_minus_s : s_data;

    // =========================================================================
    // 平方：noise²
    // =========================================================================
    wire [SQ_W-1:0] noise_sq = noise_abs * noise_abs;

    // =========================================================================
    // 累加器（仅在 s_valid 时累加）
    // =========================================================================
    logic [SUM_W-1:0] energy_sum;
    logic [CNT_W-1:0] cnt;
    logic             sat;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            energy_sum <= '0;
            cnt        <= '0;
            sat        <= 1'b0;
        end else if (load_start) begin
            energy_sum <= '0;
            cnt        <= '0;
            sat        <= 1'b0;
        end else if (s_valid) begin
            if (!sat) begin
                energy_sum <= energy_sum + SUM_W'(noise_sq);
                cnt        <= cnt + CNT_W'(1);
                if (energy_sum + SUM_W'(noise_sq) < energy_sum)
                    sat <= 1'b1;
            end else begin
                cnt <= cnt + CNT_W'(1);
            end
        end
    end

    // =========================================================================
    // 除法：energy_sum / N（受控恢复除法，SUM_W 拍流水）
    // =========================================================================
    localparam int DIV_STAGES = SUM_W;
    localparam int STG_W     = $clog2(SUM_W + 1);

    logic [SUM_W-1:0] div_dividend;
    logic [SUM_W-1:0] div_remainder;
    logic [SUM_W-1:0] div_result;
    logic [SUM_W-1:0] div_N_reg;
    logic [STG_W-1:0] div_stage;
    logic             div_running;
    logic             div_done;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_dividend  <= '0;
            div_remainder <= '0;
            div_result    <= '0;
            div_N_reg     <= '0;
            div_stage     <= '0;
            div_running   <= 1'b0;
            div_done      <= 1'b0;
        end else if (load_start) begin
            div_dividend  <= SUM_W'(energy_sum);
            div_remainder <= '0;
            div_result    <= '0;
            div_N_reg     <= SUM_W'(N);
            div_stage     <= '0;
            div_running   <= 1'b1;
            div_done      <= 1'b0;
        end else if (div_running) begin
            div_done <= 1'b0;
            if (div_stage < DIV_STAGES[STG_W-1:0]) begin
                div_dividend <= {div_dividend[SUM_W-2:0], div_remainder[SUM_W-1]};
                if (div_dividend[SUM_W-1:0] >= div_N_reg) begin
                    div_dividend <= div_dividend - div_N_reg;
                    div_remainder <= {div_remainder[SUM_W-2:0], 1'b1};
                end else begin
                    div_remainder <= {div_remainder[SUM_W-2:0], 1'b0};
                end
                div_stage <= div_stage + 1'b1;
            end else begin
                div_running <= 1'b0;
                div_done    <= 1'b1;
            end
        end else if (div_done) begin
            div_done <= 1'b0;
        end
    end

    // =========================================================================
    // 输出
    // =========================================================================
    assign energy_q2    = div_result;
    assign sample_count = cnt;
    assign flush_valid  = div_done;
    assign saturated    = sat;

endmodule
