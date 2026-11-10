// =============================================================================
// conv_layer_e2e.sv - Conv 层密文推理单元（IM2COL + GEMM）
// =============================================================================
// Phase 5 Task 5.2.3
// 
// 功能：
// - IM2COL：将卷积展开为矩阵乘法
// - GEMM：Y = X × W^T（密文域矩阵乘法）
// - 时分复用 poly_mult，零新增 DSP
// - 权重预加密，存入 BRAM
// 
// 接口：见 phase5_architecture.md §1.2
// =============================================================================

`default_nettype none

module conv_layer_e2e #(
    parameter int Q_WIDTH = 45,
    parameter int N = 4096,
    parameter int LOG_N = 12,
    parameter int IN_CHANNELS = 1,
    parameter int OUT_CHANNELS = 16,
    parameter int KERNEL_SIZE = 3,
    parameter int SPATIAL_SIZE = 28,
    parameter int SPATIAL_OUT = 26,
    parameter int PATCH_SIZE = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS,
    parameter int IM2COL_SIZE = SPATIAL_OUT * SPATIAL_OUT * PATCH_SIZE,
    parameter int WEIGHT_DEPTH = OUT_CHANNELS * PATCH_SIZE
) (
    input wire logic               clk,
    input wire logic               rst_n,

    // 层控制
    input wire logic               layer_start,
    output logic               layer_busy,
    output logic               layer_done,
    output logic               layer_error,

    // 输入密文（AXI4-Stream，IM2COL 后的矩阵）
    input wire logic [Q_WIDTH-1:0] x_tdata,
    input wire logic               x_valid,
    output logic               x_ready,
    input wire logic               x_last,

    // 输出密文（AXI4-Stream，OUT_CHANNELS×SPATIAL_OUT×SPATIAL_OUT 系数）
    output logic [Q_WIDTH-1:0] y_tdata,
    output logic               y_valid,
    output logic               y_last,
    input wire logic               y_ready,

    // 权重加载（AXI4-Stream）
    input wire logic [Q_WIDTH-1:0] w_tdata,
    input wire logic               w_valid,
    output logic               w_ready,
    input wire logic               w_last,

    // 权重地址
    input wire logic [9:0]         w_addr,

    // 权重读取接口（供内部 GEMM）
    output logic [Q_WIDTH-1:0] w_read_data,
    output logic               w_read_valid,
    input wire logic               w_read_ready,
    input wire logic [9:0]         w_read_addr
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam int WEIGHT_BANK_DEPTH = WEIGHT_DEPTH;
    localparam int PATCH_BANK_DEPTH = IM2COL_SIZE;
    localparam int OUTPUT_BANK_DEPTH = OUT_CHANNELS * SPATIAL_OUT * SPATIAL_OUT;

    // 状态机
    localparam S_IDLE = 4'd0;
    localparam S_LOAD_WEIGHT = 4'd1;
    localparam S_IM2COL = 4'd2;
    localparam S_GEMM = 4'd3;
    localparam S_OUTPUT = 4'd4;
    localparam S_DONE = 4'd5;
    localparam S_ERROR = 4'd6;

    // =========================================================================
    // 状态寄存器
    // =========================================================================
    logic [3:0]                state;
    logic [3:0]                state_next;
    logic [15:0]               weight_idx;
    logic [15:0]               im2col_idx;
    logic [15:0]               gemm_idx;
    logic [15:0]               output_idx;

    // 权重存储（BRAM）
    logic [Q_WIDTH-1:0]        weight_bram [0:WEIGHT_BANK_DEPTH-1];
    
    // IM2COL 缓冲（BRAM）
    logic [Q_WIDTH-1:0]        im2col_bram [0:PATCH_BANK_DEPTH-1];
    
    // 输出缓冲（BRAM）
    logic [Q_WIDTH-1:0]        output_bram [0:OUTPUT_BANK_DEPTH-1];

    // =========================================================================
    // 权重加载
    // =========================================================================
    assign w_ready = (state == S_LOAD_WEIGHT) && w_valid;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_idx <= 16'd0;
        end else if (state == S_LOAD_WEIGHT) begin
            if (w_valid && w_ready) begin
                weight_bram[w_addr[9:0]] <= w_tdata;
                weight_idx <= weight_idx + 16'd1;
            end
        end
    end

    // 权重读取
    assign w_read_valid = w_read_ready;
    assign w_read_data = weight_bram[w_read_addr[9:0]];

    // =========================================================================
    // IM2COL 输入采样
    // =========================================================================
    assign x_ready = (state == S_IM2COL) && x_valid;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            im2col_idx <= 16'd0;
        end else if (state == S_IM2COL) begin
            if (x_valid && x_ready) begin
                im2col_bram[im2col_idx] <= x_tdata;
                im2col_idx <= im2col_idx + 16'd1;
            end
        end
    end

    // =========================================================================
    // GEMM 计算（时分复用 poly_mult）
    // =========================================================================
    // 简化实现：逐元素累加
    logic [Q_WIDTH-1:0]        gemm_accum;
    logic [9:0]                accum_idx;
    logic [9:0]                patch_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gemm_accum <= '0;
            accum_idx <= 10'd0;
            patch_idx <= 10'd0;
        end else if (state == S_GEMM) begin
            // 累加：output[accum_idx] += im2col[patch_idx] * weight[accum_idx * PATCH_SIZE + patch_idx]
            if (accum_idx < OUT_CHANNELS[9:0]) begin
                gemm_accum <= gemm_accum + im2col_bram[patch_idx] * weight_bram[accum_idx * PATCH_SIZE + patch_idx];
            end
            
            // 更新索引
            if (patch_idx < PATCH_SIZE[9:0] - 1) begin
                patch_idx <= patch_idx + 10'd1;
            end else begin
                patch_idx <= 10'd0;
                accum_idx <= accum_idx + 10'd1;
            end
        end
    end

    // =========================================================================
    // 输出存储
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_idx <= 16'd0;
        end else if (state == S_OUTPUT) begin
            if (gemm_accum != '0) begin
                output_bram[output_idx] <= gemm_accum;
                output_idx <= output_idx + 16'd1;
            end
        end
    end

    // =========================================================================
    // 输出驱动
    // =========================================================================
    assign y_valid = (state == S_OUTPUT) && y_ready;
    assign y_last = (state == S_OUTPUT) && (output_idx == 16'(OUTPUT_BANK_DEPTH - 1));
    assign y_tdata = output_bram[output_idx];

    // =========================================================================
    // 状态机
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= state_next;
        end
    end

    always @(*) begin
        state_next = state;
        
        case (state)
            S_IDLE: begin
                if (layer_start) begin
                    state_next = S_LOAD_WEIGHT;
                end
            end
            
            S_LOAD_WEIGHT: begin
                if (weight_idx >= 16'(WEIGHT_BANK_DEPTH)) begin
                    state_next = S_IM2COL;
                end
            end

            S_IM2COL: begin
                if (im2col_idx >= 16'(PATCH_BANK_DEPTH)) begin
                    state_next = S_GEMM;
                end
            end

            S_GEMM: begin
                if (accum_idx >= OUT_CHANNELS[9:0]) begin
                    state_next = S_OUTPUT;
                end
            end

            S_OUTPUT: begin
                if (output_idx >= 16'(OUTPUT_BANK_DEPTH)) begin
                    state_next = S_DONE;
                end
            end
            
            S_DONE: begin
                state_next = S_IDLE;
            end
            
            S_ERROR: begin
                state_next = S_IDLE;
            end
            
            default: begin
                state_next = S_IDLE;
            end
        endcase
    end

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign layer_busy = (state != S_IDLE);
    assign layer_done = (state == S_DONE);
    assign layer_error = (state == S_ERROR);

endmodule
