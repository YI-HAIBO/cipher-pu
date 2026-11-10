//=============================================================================
// e2e_phase2_wrapper.sv - Phase 2 主体联合封装
//
// 集成 Phase 2 三大模块：
// - structured_block_mask: 结构化块剪枝
// - quant_sparse_combine: 低比特量化+稀疏
// - gemm_tiling_ctrl: GEMM 分层优化
//
// 数据流：
// Input Data -> quant_sparse_combine -> structured_block_mask -> gemm_tiling_ctrl -> Output
//
// 修正记录 (2026-10-14):
// - 创建完整的数据通路连接
// - 添加控制信号同步
// - 实现状态同步和错误处理
//=============================================================================

`timescale 1ns / 1ps

module e2e_phase2_wrapper #(
    parameter int LOG_N       = 12,
    parameter int N           = 1 << LOG_N,
    parameter int Q_WIDTH     = 45,
    parameter int SLOT_WIDTH  = 22,
    parameter int NUM_REAL_SLOTS = N / 2
) (
    input  logic                clk,
    input  logic                rst_n,

    // 全局控制
    input  logic                start,
    output logic                busy,
    output logic                done,
    output logic                error,

    // 输入数据 (明文样本)
    input  logic [Q_WIDTH-1:0]  sample_in,
    input  logic                sample_valid,
    output logic                sample_ready,

    // 输出结果
    output logic [Q_WIDTH-1:0]  result_out,
    output logic                result_valid,
    input  logic                result_ready,

    // 配置参数
    input  logic [15:0]         block_size,
    input  logic [15:0]         block_num,
    input  logic [7:0]          quant_threshold,
    input  logic                enable_sparse,
    input  logic                enable_quant
);

    // =========================================================================
    // 内部信号 — 模块间接口
    // =========================================================================
    // quant_sparse_combine 接口
    logic                          qsc_data_valid_out;
    logic                          qsc_data_ready_in;
    logic [Q_WIDTH-1:0]            qsc_data_out;
    logic                          qsc_sparse_enable;
    logic                          qsc_quant_enable;
    logic                          qsc_mask_valid;

    // structured_block_mask 接口
    logic                          sbm_data_valid_in;
    logic                          sbm_data_ready_out;
    logic [Q_WIDTH-1:0]            sbm_data_in;
    logic                          sbm_data_valid_out;
    logic                          sbm_data_ready_in;
    logic [Q_WIDTH-1:0]            sbm_data_out;
    logic [3:0]                    sbm_block_type;
    logic [15:0]                   sbm_block_index;
    logic                          sbm_block_valid;
    logic                          sbm_block_skip;
    logic                          sbm_mask_full;

    // gemm_tiling_ctrl 接口
    logic                          gtc_a_valid;
    logic                          gtc_a_ready;
    logic [Q_WIDTH-1:0]            gtc_a_data;
    logic                          gtc_b_valid;
    logic                          gtc_b_ready;
    logic [Q_WIDTH-1:0]            gtc_b_data;
    logic                          gtc_c_valid;
    logic                          gtc_c_ready;
    logic [Q_WIDTH-1:0]            gtc_c_data;
    logic                          gtc_busy;
    logic                          gtc_done;
    logic                          gtc_error;

    // 状态机
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_QUANT,
        ST_SPARSE,
        ST_GEMM,
        ST_OUTPUT,
        ST_DONE
    } state_e;

    state_e state, next_state;

    // =========================================================================
    // 时序逻辑 — 状态机
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= ST_IDLE;
            busy   <= 1'b0;
            done   <= 1'b0;
            error  <= 1'b0;
        end else begin
            state  <= next_state;
            busy   <= (state != ST_IDLE && state != ST_DONE) ? 1'b1 : 1'b0;
            done   <= (state == ST_DONE && next_state == ST_IDLE) ? 1'b1 : 1'b0;
            error  <= gtc_error;
        end
    end

    // =========================================================================
    // 组合逻辑 — FSM 次态
    // =========================================================================
    always_comb begin
        next_state = state;
        sample_ready   = 1'b1;
        result_valid   = 1'b0;
        result_out     = gtc_c_data;
        result_ready   = 1'b1;

        // 默认控制信号
        qsc_data_ready_in = 1'b0;
        qsc_data_valid_out = 1'b0;
        sbm_data_valid_in  = 1'b0;
        sbm_data_ready_out = 1'b0;
        sbm_block_type     = 4'b0000;
        sbm_block_index    = block_num;
        sbm_data_in        = 0;
        gtc_a_valid        = 1'b0;
        gtc_b_valid        = 1'b0;
        gtc_a_data         = 0;
        gtc_b_data         = 0;
        gtc_c_ready        = 1'b0;

        case (state)
            ST_IDLE: begin
                if (start && sample_valid) begin
                    next_state = ST_QUANT;
                end
            end

            ST_QUANT: begin
                // 输入数据到量化模块
                sample_ready   = 1'b1;
                qsc_data_ready_in = 1'b1;
                if (sample_valid && qsc_data_ready_in) begin
                    next_state = ST_SPARSE;
                end
            end

            ST_SPARSE: begin
                // 量化后数据到稀疏模块
                sbm_data_valid_in = qsc_data_valid_out;
                sbm_data_ready_out = sbm_data_valid_out;
                sbm_data_in = qsc_data_out;
                if (sbm_data_valid_in && sbm_data_ready_out) begin
                    next_state = ST_GEMM;
                end
            end

            ST_GEMM: begin
                // 稀疏后数据到 GEMM 模块
                gtc_a_valid = sbm_data_valid_out;
                gtc_a_data = sbm_data_out;
                gtc_c_ready = result_ready;
                if (gtc_done) begin
                    next_state = ST_OUTPUT;
                end
            end

            ST_OUTPUT: begin
                result_valid = gtc_c_valid;
                if (result_valid && result_ready) begin
                    next_state = ST_DONE;
                end
            end

            ST_DONE: begin
                next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    // =========================================================================
    // 实例化: quant_sparse_combine
    // =========================================================================
    quant_sparse_combine #(
        .INPUT_WIDTH    (Q_WIDTH),
        .OUTPUT_WIDTH   (SLOT_WIDTH),
        .THRESHOLD_BITS (8),
        .MASK_DEPTH     (256)
    ) u_quant_sparse (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_valid_in  (sample_valid),
        .data_ready_out (qsc_data_ready_in),
        .data_in        (sample_in),
        .data_valid_out (qsc_data_valid_out),
        .data_ready_in  (qsc_data_ready_in),
        .data_out       (qsc_data_out),
        .update_en      (enable_quant),
        .threshold      (quant_threshold),
        .sparse_enable  (qsc_sparse_enable),
        .quant_enable   (qsc_quant_enable),
        .mask_valid     (qsc_mask_valid)
    );

    // =========================================================================
    // 实例化: structured_block_mask
    // =========================================================================
    structured_block_mask #(
        .BLOCK_SIZE     (block_size),
        .MAX_BLOCKS     (block_num),
        .BLOCK_KEY_BITS (4),
        .ARRAY_WIDTH    (Q_WIDTH)
    ) u_block_mask (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_valid_in  (sbm_data_valid_in),
        .data_ready_out (sbm_data_ready_out),
        .data_in        (sbm_data_in),
        .data_valid_out (sbm_data_valid_out),
        .data_ready_in  (sbm_data_valid_out),
        .data_out       (sbm_data_out),
        .block_type     (sbm_block_type),
        .block_index    (sbm_block_index),
        .mask_update_en (enable_sparse),
        .block_valid    (sbm_block_valid),
        .block_skip     (sbm_block_skip),
        .mask_full      (sbm_mask_full)
    );

    // =========================================================================
    // 实例化: gemm_tiling_ctrl
    // =========================================================================
    gemm_tiling_ctrl #(
        .M              (256),
        .K              (256),
        .N              (256),
        .TM             (16),
        .TK             (16),
        .TN             (16),
        .DATA_WIDTH     (Q_WIDTH)
    ) u_gemm_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .a_valid        (gtc_a_valid),
        .a_ready        (gtc_a_ready),
        .a_data         (gtc_a_data),
        .b_valid        (gtc_b_valid),
        .b_ready        (gtc_b_ready),
        .b_data         (gtc_b_data),
        .c_valid        (gtc_c_valid),
        .c_ready        (gtc_c_ready),
        .c_data         (gtc_c_data),
        .start          (start),
        .busy           (gtc_busy),
        .done           (gtc_done),
        .error          (gtc_error)
    );

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [E2E_PHASE2_WRAPPER] LOG_N=%0d Q_WIDTH=%0d SLOT_WIDTH=%0d",
                  $time, LOG_N, Q_WIDTH, SLOT_WIDTH);
    end

endmodule
