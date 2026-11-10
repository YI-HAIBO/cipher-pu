//=============================================================================
// histogram_builder.sv - 密文域系数直方图构建器
// 
// 实现密文系数分布统计，支持有符号/无符号量化
// 输出64-bin直方图，用于自适应量化和分布分析
//=============================================================================

`timescale 1ns / 1ps

module histogram_builder #(
    parameter int Q_WIDTH = 45,
    parameter int HIST_BINS = 64,
    parameter int BIT_WIDTH = 8  // histogram bin宽度
) (
    input  logic                clk,
    input  logic                rst_n,
    
    input  logic                data_valid,
    input  logic                data_ready,
    input  logic [Q_WIDTH-1:0]  data,
    
    input  logic                hist_en,
    output logic [BIT_WIDTH-1:0] bin[HIST_BINS-1:0],
    output logic                hist_done,
    output logic                hist_error
);

    // =========================================================================
    // 变量声明
    // =========================================================================
    logic [Q_WIDTH-1:0] data_reg;
    logic [Q_WIDTH-1:0] bin_center[HIST_BINS-1:0];
    int integer bin_idx;
    int integer i;
    
    // 状态机
    typedef enum logic [1:0] {
        IDLE,
        BIN_CENTER,
        COUNT,
        DONE
    } hist_state_e;
    
    hist_state_e state, next_state;

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
    // 中心值计算
    // =========================================================================
    initial begin
        for (i = 0; i < HIST_BINS; i = i + 1) begin
            // 均匀量化中心值
            bin_center[i] = (signed'(data) * (i * 2 + 1) * 2**(Q_WIDTH-HIST_BINS)) / 2**HIST_BINS;
        end
    end

    // =========================================================================
    // 状态组合逻辑
    // =========================================================================
    always_comb begin
        next_state = state;
        hist_done  = 1'b0;
        hist_error = 1'b0;

        case (state)
            IDLE: begin
                if (hist_en) next_state = BIN_CENTER;
            end
            
            BIN_CENTER: begin
                // 计算bin中心值
                next_state = COUNT;
            end
            
            COUNT: begin
                if (data_valid && data_ready) begin
                    // 找到对应的bin
                    bin_idx = 0;
                    for (i = 0; i < HIST_BINS; i = i + 1) begin
                        // 简单比较，实际需要更精确的区间判断
                        if (data >= |bin_center[i]) bin_idx = i;
                    end
                    
                    bin[bin_idx] = bin[bin_idx] + 1;
                    if (i == HIST_BINS) next_state = DONE;
                end
            end
            
            DONE: begin
                hist_done = 1'b1;
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [HISTOGRAM] HIST_BINS=%0d 初始化完成", $time, HIST_BINS);
    end

endmodule
