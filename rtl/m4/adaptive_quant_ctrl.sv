//=============================================================================
// adaptive_quant_ctrl.sv - 自适应量化控制器
// 
// 基于直方图统计，为密文系数动态分配量化位宽
// 支持精度损失评估和位宽调度策略
//=============================================================================

`timescale 1ns / 1ps

module adaptive_quant_ctrl #(
    parameter int Q_WIDTH = 45,
    parameter int HIST_BINS = 64,
    parameter int BIT_WIDTH = 8
) (
    input  logic                clk,
    input  logic                rst_n,
    
    input  logic [BIT_WIDTH-1:0] bin[HIST_BINS-1:0],
    input  logic                hist_done,
    
    input  logic                quant_en,
    output logic [Q_WIDTH-1:0]  quant_param,
    output logic [Q_WIDTH-1:0]  precision_loss,
    output logic                quant_done,
    output logic                quant_error
);

    // =========================================================================
    // 变量声明
    // =========================================================================
    int integer i;
    int integer total_count;
    int integer max_bin;
    int integer quant_bits;
    int integer error_estimate;
    
    // 状态机
    typedef enum logic [1:0] {
        IDLE,
        ANALYSIS,
        PARAM_CALC,
        DONE
    } quant_state_e;
    
    quant_state_e state, next_state;

    // =========================================================================
    // 状态寄存器
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    // =========================================================================
    // 状态组合逻辑
    // =========================================================================
    always_comb begin
        next_state = state;
        quant_done = 1'b0;
        quant_error = 1'b0;

        case (state)
            IDLE: begin
                if (hist_done) next_state = ANALYSIS;
            end
            
            ANALYSIS: begin
                // 统计直方图分布在
                total_count = 0;
                max_bin = 0;
                for (i = 0; i < HIST_BINS; i = i + 1) begin
                    total_count = total_count + bin[i];
                    if (bin[i] > max_bin) max_bin = bin[i] + 1;
                end
                
                // 根据分布决定量化位宽
                quant_bits = Q_WIDTH - $clog2(max_bin + 1);
                precision_loss = (total_count > 0) ? (max_bin * total_count) / (Q_WIDTH * 2) : 0;
                
                next_state = PARAM_CALC;
            end
            
            PARAM_CALC: begin
                // 计算最终的量化参数
                quant_param = { quant_bits, 0 };
                quant_done  = 1'b1;
                next_state  = DONE;
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [ADAPT_QUANT] 初始化完成", $time);
    end

endmodule
