//=============================================================================
// histogram_adaptive_quant.sv - 基于直方图的自适应量化控制器
// 
// 根据密文系数的直方图分布，动态调整量化区间，在精度和压缩率间找到最优平衡
//=============================================================================

`timescale 1ns / 1ps

module histogram_adaptive_quant #(
    parameter int Q_WIDTH = 45,
    parameter int NUM_BINS = 64,
    parameter int HIST_WIDTH = 8,
    parameter int QUANT_BITS = 12
) (
    input  logic                clk,
    input  logic                rst_n,
    
    // 直方图输入
    input  logic [HIST_WIDTH-1:0] bin[NUM_BINS-1:0],
    input  logic                hist_valid,
    
    // 密文系数输入
    input  logic                data_valid_in,
    input  logic                data_ready_out,
    input  logic [Q_WIDTH-1:0]  data_in,
    
    // 输出
    output logic [QUANT_BITS-1:0]  quantized,
    output logic                data_valid_out,
    output logic                data_ready_in,
    output logic [Q_WIDTH-1:0]  quant_param,
    output logic                quant_done,
    output logic                quant_error
);

    // =========================================================================
    // 内部信号
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE,
        ANALYZE_BIN,
        CALC_INTERVAL,
        QUANTIZE,
        OUTPUT
    } fsm_state_e;
    
    fsm_state_e state, next_state;
    
    // 直方图统计
    logic [32-1:0] bin_sum;
    logic [7-1:0] max_bin;
    logic [7-1:0] min_bin;
    logic [7-1:0] bin_idx;

    // 量化参数
    logic [32-1:0] quant_range;
    logic [32-1:0] quant_offset;
    logic [7-1:0] quant_bits;
    logic [32-1:0] quant_step;
    
    // 输出寄存器
    logic [Q_WIDTH-1:0] data_reg;
    logic [QUANT_BITS-1:0] quantized_reg;
    logic [Q_WIDTH-1:0] quant_param_reg;
    logic quant_done_reg;
    logic quant_error_reg;
    
    // =========================================================================
    // 状态机
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            quant_done <= 1'b0;
            quant_error <= 1'b0;
        end else begin
            state <= next_state;
            quant_done <= quant_done_reg;
            quant_error <= quant_error_reg;
        end
    end

    // =========================================================================
    // 直方图分析
    // =========================================================================
    always_comb begin
        next_state = state;
        data_valid_out = 1'b0;
        data_ready_in = 1'b1;
        data_reg = data_in;
        quantized_reg = 0;
        quant_param_reg = 0;
        quant_done_reg = 1'b0;
        quant_error_reg = 1'b0;

        case (state)
            IDLE: begin
                data_valid_out = data_valid_in;
                if (data_valid_in && !data_ready_out && hist_valid) begin
                    next_state = ANALYZE_BIN;
                end
            end
            
            ANALYZE_BIN: begin
                bin_sum = 0;
                max_bin = 0;
                min_bin = NUM_BINS-1;
                for (bin_idx = 0; bin_idx < NUM_BINS; bin_idx = bin_idx + 1) begin
                    bin_sum = bin_sum + bin[bin_idx];
                    if (bin[bin_idx] > max_bin) max_bin = bin[bin_idx];
                    if (bin[bin_idx] < min_bin) min_bin = bin[bin_idx];
                end
                
                if (bin_sum == 0) begin
                    quant_error_reg = 1'b1;
                    next_state = IDLE;
                end else begin
                    next_state = CALC_INTERVAL;
                end
            end
            
            CALC_INTERVAL: begin
                // 计算量化范围
                quant_range = BIN_TO_INT(max_bin) - BIN_TO_INT(min_bin) + 1;
                
                // 根据数据分布选择合适的量化位宽
                // 使用对数来确定置信度
                quant_bits = QUANT_BITS;
                if (bin_sum > 1024) quant_bits = QUANT_BITS - 2; // 数据量多，降低位宽
                if (bin_sum < 100) quant_bits = QUANT_BITS + 1;  // 数据量少，提高位宽
                
                // 计算量化步长
                quant_step = (1 << Q_WIDTH) / (1 << quant_bits);
                quant_offset = BIN_TO_INT(min_bin);
                
                next_state = QUANTIZE;
            end
            
            QUANTIZE: begin
                // 执行量化
                if (data_reg >= quant_offset) begin
                    quantized_reg = (data_reg - quant_offset) >> quant_step[6:0];
                end else begin
                    quantized_reg = 0;
                end
                
                quant_param_reg = { quant_bits, quant_step };
                quant_done_reg = 1'b1;
                next_state = OUTPUT;
            end
            
            OUTPUT: begin
                data_valid_out = data_valid_in;
                if (data_valid_out && data_ready_in) begin
                    next_state = IDLE;
                end
            end
            
            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // 辅助函数 (整数转换)
    // =========================================================================
    function int BIN_TO_INT(input logic [15:0] bin);
        BIN_TO_INT = bin;
    endfunction

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [HIST_ADAPT_QUANT] NUM_BINS=%0d QUANT_BITS=%0d", 
                  $time, NUM_BINS, QUANT_BITS);
    end

endmodule
