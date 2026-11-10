//=============================================================================
// adaptive_bitwidth.sv - 自适应位宽调度器
// 
// 根据系数的分布特性，动态调整每个系数的表示位宽，在存储和精度间优化
//=============================================================================

`timescale 1ns / 1ps

module adaptive_bitwidth #(
    parameter int Q_WIDTH = 45,
    parameter int MAX_BITS = 16,
    parameter int MIN_BITS = 8,
    parameter int NUM_LEVELS = 4
) (
    input  logic                clk,
    input  logic                rst_n,
    
    // 密文系数输入
    input  logic                data_valid_in,
    input  logic                data_ready_out,
    input  logic [Q_WIDTH-1:0]  data_in,
    
    // 输出
    output logic [Q_WIDTH-1:0]  data_out,
    output logic [MAX_BITS-1:0] actual_bits,
    output logic                data_valid_out,
    output logic                data_ready_in,
    output logic                bitwidth_update,
    output logic                bitwidth_done
);

    // =========================================================================
    // 内部信号
    // =========================================================================
    typedef enum logic [3:0] {
        IDLE,
        ANALYZE,
        CALC_BITS,
        QUANTIZE,
        OUTPUT
    } fsm_state_e;
    
    fsm_state_e state, next_state;
    
    // 分布统计
    logic [32-1:0] coefficient_count;
    logic [Q_WIDTH-1:0] max_value;
    logic [Q_WIDTH-1:0] min_value;
    logic [Q_WIDTH:0] range;

    // 位宽决策
    logic [7-1:0] current_bits;
    logic [7-1:0] bitwidth_level;
    
    // 输出寄存器
    logic [Q_WIDTH-1:0] data_reg;
    logic [Q_WIDTH-1:0] data_out_reg;
    logic [MAX_BITS-1:0] actual_bits_reg;
    logic bitwidth_update_reg;
    logic bitwidth_done_reg;
    
    // =========================================================================
    // 状态机
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            bitwidth_update <= 1'b0;
            bitwidth_done <= 1'b0;
        end else begin
            state <= next_state;
            bitwidth_update <= bitwidth_update_reg;
            bitwidth_done <= bitwidth_done_reg;
        end
    end

    // =========================================================================
    // 状态组合逻辑
    // =========================================================================
    always_comb begin
        next_state = state;
        data_valid_out = 1'b0;
        data_ready_in = 1'b1;
        data_reg = data_in;
        data_out_reg = data_in;
        actual_bits_reg = MAX_BITS;
        bitwidth_update_reg = 1'b0;
        bitwidth_done_reg = 1'b0;

        case (state)
            IDLE: begin
                data_valid_out = data_valid_in;
                if (data_valid_in && !data_ready_out) begin
                    next_state = ANALYZE;
                end
            end
            
            ANALYZE: begin
                // 分析系数分布（简化：假设已有统计信息）
                max_value = data_in[MAX_BITS-1:0];
                min_value = 0;
                range = max_value - min_value;
                coefficient_count = 1;
                
                // 根据范围决定位宽
                if (range < 256) begin
                    current_bits = MIN_BITS;
                end else if (range < 1024) begin
                    current_bits = MIN_BITS + 4;
                end else begin
                    current_bits = MAX_BITS;
                end
                
                bitwidth_update_reg = 1'b1;
                next_state = CALC_BITS;
            end
            
            CALC_BITS: begin
                // 计算具体的位宽级别
                bitwidth_level = (current_bits - MIN_BITS) / 4;
                actual_bits_reg = current_bits;
                
                // 量化到指定的位宽（右移截断）
                if (current_bits > 0 && current_bits <= Q_WIDTH) begin
                    data_out_reg = data_in[Q_WIDTH-1:0] >> (Q_WIDTH - current_bits);
                end else begin
                    data_out_reg = data_in;
                end
                
                bitwidth_done_reg = 1'b1;
                next_state = OUTPUT;
            end
            
            OUTPUT: begin
                data_valid_out = data_valid_in;
                data_out = data_out_reg;
                actual_bits = actual_bits_reg;
                if (data_valid_out && data_ready_in) begin
                    next_state = IDLE;
                end
            end
            
            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [ADAPT_BITWIDTH] LEVELS=%0d", $time, NUM_LEVELS);
    end

endmodule
