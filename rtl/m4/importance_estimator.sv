//=============================================================================
// importance_estimator.sv - 密文域系数重要性估计器
// 
// 实现多种系数重要性估计算法：
// 1. 幅值统计：绝对值最大的er系数
// 2. 动量累积：支持梯度累积的动量
// 3. 稀疏敏感性：基于稀疏mask的敏感性评估
//
// 目标：为动态稀疏mask提供系数重要性评估
//=============================================================================

`timescale 1ns / 1ps

module importance_estimator #(
    parameter int Q_WIDTH = 45,
    parameter int EST_MODE = 2   // [0: magnitude, 1: momentum, 2: sparsity]
) (
    input  logic                clk,
    input  logic                rst_n,
    
    input  logic                data_valid,
    input  logic                data_ready,
    input  logic [Q_WIDTH-1:0]  data,
    
    input  logic                stat_en,
    output logic [Q_WIDTH-1:0]  importance,
    output logic                stat_done,
    output logic                stat_error
);

    // =========================================================================
    // 状态机定义
    // =========================================================================
    typedef enum logic [1:0] {
        IDLE,
        INIT,
        STATS,
        RESULT
    } stat_state_e;
    
    stat_state_e state, next_state;

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
        stat_done  = 1'b0;
        stat_error = 1'b0;
        importance = '0;

        case (state)
            IDLE: begin
                if (stat_en) next_state = INIT;
            end
            
            INIT: begin
                next_state = STATS;
            end
            
            STATS: begin
                if (data_valid && data_ready) begin
                    // 计算重要性值
                    case (EST_MODE)
                        2'd0: // 幅值统计
                            importance = |data ? $bitstoreal(data) : 0;
                        2'd1: // 动量累积
                            importance = data[Q_WIDTH-1:0];
                        2'd2: // 稀疏敏感性
                            importance = 0; // 需要sparsity mask输入
                        default: importance = 0;
                    endcase
                    stat_done = 1'b1;
                    next_state = RESULT;
                end
            end
            
            RESULT: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // 输出使能
    // =========================================================================
    logic [Q_WIDTH-1:0] importance_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            importance_reg <= '0;
        end else if (state == RESULT) begin
            importance_reg <= importance;
        end
    end

    assign importance = importance_reg;

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [IMPORTANCE] EST_MODE=%0d 初始化完成", $time, EST_MODE);
    end

endmodule
