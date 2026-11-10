// =============================================================================
// e2e_slot_simd_wrapper.sv — 多 Slot SIMD 端到端推理包装器（Task #83）
//
// 集成三个模块：
//   1. slot_packer：N/2 样本 → N 系数（Hermitian 对称打包）
//   2. e2e_ckks_mult_ctrl_m4：CKKS 密文×明文乘法（含 keyswitch + rescale）
//   3. slot_unpacker：N 系数 → N/2 样本（解包）
//
// 数据流：
//   sample_in → [slot_packer] → b_channel → [E2E] → f0_channel → [slot_unpacker] → sample_out
//
// 参数：
//   USE_PACKER_FOR_B   = 1: packer poly 输出驱动 E2E b 通道（b_valid/b_data 悬空）
//   USE_UNPACKER_FOR_F0= 1: E2E f0 输出驱动 unpacker poly 输入（f0_valid/f0_data 悬空）
// =============================================================================

`timescale 1ns / 1ps

module e2e_slot_simd_wrapper #(
    parameter int LOG_N           = 4,
    parameter int N               = 16,
    parameter int Q_WIDTH         = 7,
    parameter logic [Q_WIDTH-1:0] Q_IN      = 7'd113,
    parameter logic [Q_WIDTH-1:0] Q_OUT     = 7'd97,
    parameter logic [Q_WIDTH-1:0] N_INV     = 7'd106,
    parameter int USE_FASTRED     = 0,
    parameter int B               = 2,
    parameter int NUM_SLOTS       = N / 2,
    parameter int ACC_W           = 64,
    parameter int IDX_W           = 5,
    parameter logic               USE_PACKER_FOR_B   = 1'b1,
    parameter logic               USE_UNPACKER_FOR_F0 = 1'b1,
    parameter string              TW_FILE   = "rtl/m5/tw/tw_omega_toy_n16.hex",
    parameter string              TW_INV_FILE = "rtl/m5/tw/tw_omegainv_toy_n16.hex"
) (
    input  logic                  clk,
    input  logic                  rst_n,
    // 控制
    input  logic                  start,
    output logic                  busy,
    output logic                  done,
    output logic                  error,
    // 样本输入（N/2 个）
    input  logic                  sample_in_valid,
    output logic                  sample_in_ready,
    input  logic [Q_WIDTH-1:0]    sample_in_data,
    // 样本输出（N/2 个）
    output logic                  sample_out_valid,
    input  logic                  sample_out_ready,
    output logic [Q_WIDTH-1:0]    sample_out_data,
    // 密文输入（c0_1, c1_1: 输入密文；c0_2, c1_2: 权重密文；a, b: 密钥）
    input  logic                  c0_1_valid,
    output logic                  c0_1_ready,
    input  logic [Q_WIDTH-1:0]    c0_1_data,
    input  logic                  c1_1_valid,
    output logic                  c1_1_ready,
    input  logic [Q_WIDTH-1:0]    c1_1_data,
    input  logic                  c0_2_valid,
    output logic                  c0_2_ready,
    input  logic [Q_WIDTH-1:0]    c0_2_data,
    input  logic                  c1_2_valid,
    output logic                  c1_2_ready,
    input  logic [Q_WIDTH-1:0]    c1_2_data,
    input  logic                  a_valid,
    output logic                  a_ready,
    input  logic [Q_WIDTH-1:0]    a_data,
    input  logic                  b_valid,
    output logic                  b_ready,
    input  logic [Q_WIDTH-1:0]    b_data,
    // 密文输出（f0, f1）
    output logic                  f0_valid,
    input  logic                  f0_ready,
    output logic [Q_WIDTH-1:0]    f0_data,
    output logic                  f1_valid,
    input  logic                  f1_ready,
    output logic [Q_WIDTH-1:0]    f1_data,
    // 噪声监测
    output logic [ACC_W-1:0]      energy_q2_int
);

    // =========================================================================
    // 内部信号：slot_packer → E2E b 通道连接（不通过 wrapper 端口）
    // =========================================================================
    logic                  packer_start, packer_busy, packer_done;
    logic                  packer_sample_valid, packer_sample_ready;
    logic [Q_WIDTH-1:0]    packer_sample_data;
    logic                  packer_poly_valid, packer_poly_ready;
    logic [Q_WIDTH-1:0]    packer_poly_data;
    // packer 的 poly_* 直接连 E2E 的 b_*（内部信号，不占用 wrapper 的 b_* 端口）
    logic                  e2e_b_valid;
    logic                  e2e_b_ready;
    logic [Q_WIDTH-1:0]    e2e_b_data;

    // =========================================================================
    // 内部信号：E2E f0 通道 → unpacker poly 输入
    // =========================================================================
    logic                  e2e_f0_valid;
    logic                  e2e_f0_ready;
    logic [Q_WIDTH-1:0]    e2e_f0_data;

    // =========================================================================
    // 内部信号：E2E 控制
    // =========================================================================
    logic                  e2e_busy, e2e_done, e2e_error;
    logic                  e2e_start_r = 1'b0;
    logic [2:0]            e2e_gear_sel = 3'd0;

    // =========================================================================
    // 内部信号：E2E → slot_unpacker 连接
    // =========================================================================
    logic                  unpacker_start, unpacker_busy, unpacker_done;
    logic                  unpacker_poly_valid, unpacker_poly_ready;
    logic [Q_WIDTH-1:0]    unpacker_poly_data;
    logic                  unpacker_sample_valid, unpacker_sample_ready;
    logic [Q_WIDTH-1:0]    unpacker_sample_data;

    // =========================================================================
    // 内部信号：E2E 输出缓冲
    // =========================================================================
    logic [Q_WIDTH-1:0]    f0_buf [0:N-1];
    logic [Q_WIDTH-1:0]    f1_buf [0:N-1];
    logic [IDX_W-1:0]      f0_cnt, f1_cnt;
    logic                  f0_buf_full, f1_buf_full;

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam logic [2:0] S_IDLE     = 3'd0;
    localparam logic [2:0] S_PACK     = 3'd1;   // slot_packer 工作
    localparam logic [2:0] S_E2E      = 3'd2;   // E2E 推理
    localparam logic [2:0] S_UNPACK   = 3'd3;   // slot_unpacker 工作
    localparam logic [2:0] S_DONE     = 3'd4;

    logic [2:0] state;

    // =========================================================================
    // slot_packer 实例化
    // =========================================================================
    slot_packer #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .NUM_SLOTS(NUM_SLOTS)
    ) u_packer (
        .clk(clk),
        .rst_n(rst_n),
        .start(packer_start),
        .sample_valid(packer_sample_valid),
        .sample_ready(packer_sample_ready),
        .sample_data(packer_sample_data),
        .poly_valid(packer_poly_valid),
        .poly_ready(packer_poly_ready),
        .poly_data(packer_poly_data),
        .done(packer_done)
    );

    // =========================================================================
    // e2e_ckks_mult_ctrl_m4 实例化
    // =========================================================================
    e2e_ckks_mult_ctrl_m4 #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_IN(Q_IN),
        .Q_OUT(Q_OUT),
        .N_INV(N_INV),
        .USE_FASTRED(USE_FASTRED),
        .TW_FILE(TW_FILE),
        .TW_INV_FILE(TW_INV_FILE)
    ) u_e2e (
        .clk(clk),
        .rst_n(rst_n),
        .gear_sel(e2e_gear_sel),
        .start(e2e_start_r),
        .busy(e2e_busy),
        .done(e2e_done),
        .error(e2e_error),
        .c0_1_valid(c0_1_valid),
        .c0_1_ready(c0_1_ready),
        .c0_1_data(c0_1_data),
        .c1_1_valid(c1_1_valid),
        .c1_1_ready(c1_1_ready),
        .c1_1_data(c1_1_data),
        .c0_2_valid(c0_2_valid),
        .c0_2_ready(c0_2_ready),
        .c0_2_data(c0_2_data),
        .c1_2_valid(c1_2_valid),
        .c1_2_ready(c1_2_ready),
        .c1_2_data(c1_2_data),
        .a_valid(a_valid),
        .a_ready(a_ready),
        .a_data(a_data),
        .b_valid(e2e_b_valid),
        .b_ready(e2e_b_ready),
        .b_data(e2e_b_data),
        .f0_valid(e2e_f0_valid),
        .f0_ready(e2e_f0_ready),
        .f0_data(e2e_f0_data),
        .f1_valid(f1_valid),
        .f1_ready(f1_ready),
        .f1_data(f1_data)
    );

    // =========================================================================
    // slot_unpacker 实例化
    // =========================================================================
    slot_unpacker #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .NUM_SLOTS(NUM_SLOTS)
    ) u_unpacker (
        .clk(clk),
        .rst_n(rst_n),
        .start(unpacker_start),
        .poly_valid(e2e_f0_valid),
        .poly_ready(e2e_f0_ready),
        .poly_data(e2e_f0_data),
        .sample_valid(unpacker_sample_valid),
        .sample_ready(unpacker_sample_ready),
        .sample_data(unpacker_sample_data),
        .done(unpacker_done)
    );

    // =========================================================================
    // 顶层接口连接：sample_in → packer
    //   sample_in_valid/data 是 input，连接到 packer 的 sample_valid/data 输入
    //   sample_in_ready 是 output，来自 packer 的 sample_ready 输出
    // =========================================================================
    assign packer_sample_valid = sample_in_valid;
    assign packer_sample_data  = sample_in_data;
    assign sample_in_ready     = packer_sample_ready;

    // 顶层接口连接：unpacker → sample_out
    //   sample_out_valid/data 是 output，来自 unpacker 的 sample_valid/data 输出
    //   sample_out_ready 是 input，连接到 unpacker 的 sample_ready 输入
    // =========================================================================
    assign sample_out_valid = unpacker_sample_valid;
    assign sample_out_data  = unpacker_sample_data;
    assign unpacker_sample_ready = sample_out_ready;

    // =========================================================================
    // packer → E2E b 通道连接（内部信号，不占用 wrapper 端口 b_*）
    // =========================================================================
    assign e2e_b_valid = packer_poly_valid;
    assign e2e_b_ready = packer_poly_ready;
    assign e2e_b_data  = packer_poly_data;

    // =========================================================================
    // E2E f0 输出 → unpacker poly 输入（内部信号，不占用 wrapper 端口 f0_*）
    // =========================================================================
    assign unpacker_poly_valid = e2e_f0_valid;
    assign unpacker_poly_ready = e2e_f0_ready;
    assign unpacker_poly_data  = e2e_f0_data;

    // =========================================================================
    // 噪声监测接口
    // =========================================================================
    assign energy_q2_int = '0;  // 简化：实际需要连接 noise_monitor

    // =========================================================================
    // 主状态机
    // =========================================================================
    logic packer_start = 1'b0;
    logic unpacker_start = 1'b0;
    logic unpacker_done_seen = 1'b0;  // 沿捕获：避免 unpacker_done 单拍脉冲被错过

    // 沿捕获 unpacker_done：只要 unpacker_done 曾拉高，就置位 unpacker_done_seen，
    // 直到 wrapper 进入 S_DONE 后清零。这样即使 unpacker_done 只拉高 1 拍，
    // wrapper 在 S_UNPACK 状态也能可靠检测到。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            unpacker_done_seen <= 1'b0;
        end else begin
            if (unpacker_done)
                unpacker_done_seen <= 1'b1;
            else if (state == S_DONE)
                unpacker_done_seen <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            busy           <= 1'b0;
            done           <= 1'b0;
            error          <= 1'b0;
            packer_start   <= 1'b0;
            unpacker_start <= 1'b0;
            e2e_start_r    <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        // 并行启动 packer 和 E2E：
                        //   - packer 负责把 N/2 样本打包为 b 多项式
                        //   - E2E 立即进入 S_LOAD_C1/S_LOAD_C2/S_LOAD_KEY 加载 c0_1/c1_1/c0_2/c1_2/a
                        //   - E2E 在 S_LOAD_KEY 阶段等待 b_valid（来自 packer）
                        state          <= S_PACK;
                        busy           <= 1'b1;
                        packer_start   <= 1'b1;
                        e2e_start_r    <= 1'b1;
                    end
                end

                S_PACK: begin
                    packer_start <= 1'b0;
                    e2e_start_r  <= 1'b0;
                    if (e2e_done) begin
                        // E2E 完成（此时 packer 必然已完成，因为 E2E 需要 b）
                        state          <= S_UNPACK;
                        unpacker_start <= 1'b1;
                    end
                end

                S_UNPACK: begin
                    unpacker_start <= 1'b0;
                    if (unpacker_done_seen) begin
                        state <= S_DONE;
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
