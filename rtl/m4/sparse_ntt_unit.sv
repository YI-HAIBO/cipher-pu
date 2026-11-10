// =============================================================================
// sparse_ntt_unit.sv — M4-b 稀疏 NTT 单元
//
// 功能：包裹 ntt_unit，在时域输入前检测低能量系数并置零。
//       输出稀疏统计信息（skip_count / total_count）供档位控制器反馈。
//
// 稀疏策略：
//   sparsity_en=0 (Gear 0/1): 直通，不做稀疏检测
//   sparsity_en=1 (Gear 2/3): |coeff| < threshold 则置零
//
// 数据流：
//   s_tdata → [稀疏检测] → ntt_unit.in_data → ntt_unit → m_tdata
//                        → skip_map (内部缓存)
//
// 接口：AXI-Stream 输入/输出 + 档位配置 + 稀疏统计
// =============================================================================

`timescale 1ns / 1ps

module sparse_ntt_unit #(
    parameter int LOG_N   = 14,
    parameter int N       = 1 << LOG_N,
    parameter int Q_WIDTH = 45,
    parameter int Q_VALUE = 45'd17592186175489,
    parameter logic [Q_WIDTH-1:0] N_INV   = 45'd17591112433657,
    parameter bit USE_FASTRED = 0
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // 档位配置
    input  logic [Q_WIDTH-1:0]    sparsity_threshold,
    input  logic                  sparsity_en,       // 0=不稀疏, 1=启用

    // 输入：时域系数（AXI-Stream）
    input  logic [Q_WIDTH-1:0]    s_tdata,
    input  logic                  s_valid,
    output logic                  s_ready,
    input  logic                  s_last,

    // 输出：NTT 结果（AXI-Stream）
    output logic [Q_WIDTH-1:0]    m_tdata,
    output logic                  m_valid,
    output logic                  m_last,
    input  logic                  m_ready,

    // 操作控制
    input  logic                  op_mode,           // 0=NTT, 1=INTT
    input  logic                  start,

    // 状态
    output logic                  busy,
    output logic                  done,
    output logic                  error,

    // 稀疏统计
    output logic [15:0]           skip_count,
    output logic [15:0]           total_count,

    // Twiddle 因子表
    input  logic [Q_WIDTH-1:0]    omega_table     [0:N/2-1],
    input  logic [Q_WIDTH-1:0]    omega_inv_table [0:N/2-1]
);

    // =========================================================================
    // 内部信号
    // =========================================================================
    logic [Q_WIDTH-1:0] filtered_data;
    logic               filtered_valid;
    logic               filtered_ready;
    logic               filtered_last;

    // ntt_unit 接口
    logic [Q_WIDTH-1:0] ntt_in_data;
    logic               ntt_in_valid;
    logic               ntt_in_ready;
    logic [Q_WIDTH-1:0] ntt_out_data;
    logic               ntt_out_valid;
    logic               ntt_out_last;
    logic               ntt_out_ready;
    logic               ntt_busy;
    logic               ntt_done;
    logic               ntt_error;

    // 稀疏检测
    logic               is_zero;
    logic [15:0]        skip_cnt_reg;
    logic [15:0]        total_cnt_reg;
    logic               input_active;

    // =========================================================================
    // 稀疏检测逻辑
    // =========================================================================
    // 判断系数是否低于阈值（对称绝对值比较）
    // 在模数域下，|coeff| < T 等价于 coeff < T 或 coeff > q - T
    // 简化：直接用 coeff < threshold 或 (q - coeff) < threshold

    logic [Q_WIDTH-1:0] coeff_neg;  // q - coeff（用于负方向比较）
    logic               below_threshold;
    logic               above_threshold_neg;

    assign coeff_neg = Q_VALUE - s_tdata;
    assign below_threshold   = (s_tdata < sparsity_threshold);
    assign above_threshold_neg = (coeff_neg < sparsity_threshold);
    assign is_zero = sparsity_en && (below_threshold || above_threshold_neg);

    // 稀疏过滤：低于阈值的系数置零
    assign filtered_data  = is_zero ? {Q_WIDTH{1'b0}} : s_tdata;
    assign filtered_valid = s_valid;
    assign s_ready        = filtered_ready;
    assign filtered_last  = s_last;

    // =========================================================================
    // ntt_unit 实例化
    // =========================================================================
    ntt_unit #(
        .LOG_N       (LOG_N),
        .N           (N),
        .Q_WIDTH     (Q_WIDTH),
        .Q_VALUE     (Q_VALUE),
        .N_INV       (N_INV),
        .USE_FASTRED (USE_FASTRED)
    ) u_ntt (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .op_mode       (op_mode),
        .busy          (ntt_busy),
        .done          (ntt_done),
        .error         (ntt_error),
        .in_data       (filtered_data),
        .in_valid      (filtered_valid),
        .in_ready      (filtered_ready),
        .out_data      (ntt_out_data),
        .out_valid     (ntt_out_valid),
        .out_last      (ntt_out_last),
        .out_ready     (ntt_out_ready),
        .omega_table   (omega_table),
        .omega_inv_table (omega_inv_table)
    );

    // =========================================================================
    // 输出直通
    // =========================================================================
    assign m_tdata  = ntt_out_data;
    assign m_valid  = ntt_out_valid;
    assign m_last   = ntt_out_last;
    assign ntt_out_ready = m_ready;
    assign busy     = ntt_busy;
    assign done     = ntt_done;
    assign error    = ntt_error;

    // =========================================================================
    // 稀疏统计
    // =========================================================================
    // 在输入阶段计数（ntt_unit 的 in_ready 为高时有效）
    assign input_active = filtered_valid && filtered_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skip_cnt_reg  <= 16'd0;
            total_cnt_reg <= 16'd0;
        end else if (start) begin
            // 新启动时清零
            skip_cnt_reg  <= 16'd0;
            total_cnt_reg <= 16'd0;
        end else if (input_active) begin
            total_cnt_reg <= total_cnt_reg + 16'd1;
            if (is_zero) begin
                skip_cnt_reg <= skip_cnt_reg + 16'd1;
            end
        end
    end

    assign skip_count  = skip_cnt_reg;
    assign total_count = total_cnt_reg;

endmodule
