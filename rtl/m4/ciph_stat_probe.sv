//=============================================================================
// ciph_stat_probe.sv - 密文域统计探针主模块
// 
// 整合重要性估计、直方图构建、自适应量化控制的完整统计探针
// 支持多种统计模式、可配置的bin数和样本深度
//=============================================================================

`timescale 1ns / 1ps

module ciph_stat_probe #(
    parameter int Q_WIDTH = 45,
    parameter int STAT_MODE = 3, // [0: importance, 1: histogram, 2: adaptive_quant, 3: all]
    parameter int HIST_BINS = 64,
    parameter int SAMPLE_DEPTH = 256,
    parameter int BIN_WIDTH = 8
) (
    input  logic                clk,
    input  logic                rst_n,
    
    // 数据输入（密文系数流）
    input  logic                data_valid,
    input  logic                data_ready,
    input  logic [Q_WIDTH-1:0]  data,
    
    // 控制接口
    input  logic                stat_en,
    input  logic [1:0]          stat_cmd, // [0: clear, 1: start, 2: reset]
    output logic [Q_WIDTH-1:0]  stat_result1,
    output logic [Q_WIDTH-1:0]  stat_result2,
    output logic                stat_done,
    output logic                stat_error
);

    // =========================================================================
    // 子模块实例化
    // =========================================================================
    // 重要性估计器
    importance_estimator #(.Q_WIDTH(Q_WIDTH), .EST_MODE(STAT_MODE[1:0])) importance_estimator (
        .clk           (clk),
        .rst_n         (rst_n),
        .data_valid    (data_valid),
        .data_ready    (data_ready),
        .data          (data),
        .stat_en       (stat_en),
        .importance    (stat_result1),
        .stat_done     (importance_done),
        .stat_error    (importance_error)
    );

    // 直方图构建器
    histogram_builder #(.Q_WIDTH(Q_WIDTH), .HIST_BINS(HIST_BINS), .BIT_WIDTH(BIN_WIDTH)) histogram_builder (
        .clk           (clk),
        .rst_n         (rst_n),
        .data_valid    (data_valid),
        .data_ready    (data_ready),
        .data          (data),
        .hist_en       (stat_en),
        .bin           (stat_result2),
        .hist_done     (hist_done),
        .hist_error    (hist_error)
    );

    // 自适应量化控制器
    adaptive_quant_ctrl #(.Q_WIDTH(Q_WIDTH), .HIST_BINS(HIST_BINS), .BIT_WIDTH(BIN_WIDTH)) adaptive_quant_ctrl (
        .clk           (clk),
        .rst_n         (rst_n),
        .bin           (stat_result2),
        .hist_done     (hist_done),
        .quant_en      (hist_done),
        .quant_param   (stat_result1),
        .precision_loss(stat_result2),
        .quant_done    (quant_done),
        .quant_error   (quant_error)
    );

    // =========================================================================
    // 信号定义
    // =========================================================================
    logic importance_done, importance_error;
    logic hist_done, hist_error;
    logic quant_done, quant_error;
    
    logic [Q_WIDTH-1:0] result1_core, result2_core;

    // =========================================================================
    // 结果选择逻辑
    // =========================================================================
    always_comb begin
        stat_error = 1'b0;
        
        case (STAT_MODE)
            3'd0: begin  // 仅重要性估计
                result1_core = importance_estimator.importance;
                result2_core = '0;
                stat_done = importance_done;
                stat_error = importance_error;
            end
            
            3'd1: begin  // 仅直方图构建
                result1_core = '0;
                result2_core = hist_bin;
                stat_done = hist_done;
                stat_error = hist_error;
            end
            
            3'd2: begin  // 仅自适应量化
                result1_core = quant_ctrl.quant_param;
                result2_core = quant_ctrl.precision_loss;
                stat_done = quant_done;
                stat_error = quant_error;
            end
            
            3'd3: begin  // 全部模式
                result1_core = importance_estimator.importance;
                result2_core = quant_ctrl.quant_param;
                stat_done = importance_done & hist_done & quant_done;
                stat_error = importance_error | hist_error | quant_error;
            end
            
            default: stat_error = 1'b1;
        endcase
        
        stat_result1 = result1_core;
        stat_result2 = result2_core;
    end

    // =========================================================================
    // 控制逻辑
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_error <= 1'b0;
        end else if (stat_cmd[1:0] == 2'b10) begin  // reset
            stat_error <= 1'b1;
        end else begin
            stat_error <= 1'b0;
        end
    end

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [CIPH_STAT] MODE=%0d HIST_BINS=%0d 初始化完成", $time, STAT_MODE, HIST_BINS);
    end

endmodule
