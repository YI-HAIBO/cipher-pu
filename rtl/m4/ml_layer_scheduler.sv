// =============================================================================
// ml_layer_scheduler.sv - ML 层调度器
// =============================================================================
// Phase 5 Task 5.3.1
//
// 功能：
// - 调度 5 层 CNN 推理（Conv1→ReLU→MaxPool→Conv2→ReLU→MaxPool→FC1→ReLU→FC2）
// - 4 态 FSM：IDLE → LOAD_WEIGHT → INFER_LAYER → NEXT_LAYER → DONE
// - 噪声预算监测（4-bit 计数器，每次 poly_mult 递减）
// - 层类型编码：0001=Conv, 0010=ReLU, 0100=MaxPool, 1000=FC
//
// 接口：见 phase5_architecture.md §1.5
// =============================================================================

`default_nettype none

module ml_layer_scheduler #(
    parameter int NUM_LAYERS      = 7,
    parameter int LAYER_IDX_WIDTH = 4,
    parameter int NOISE_BUDGET_INIT = 8    // 初始噪声预算（4-bit）
) (
    input wire logic               clk,
    input wire logic               rst_n,

    // 顶层控制
    input wire logic               start,
    output logic               busy,
    output logic               done,
    output logic               error,

    // 层索引
    output logic [LAYER_IDX_WIDTH-1:0] layer_idx,
    output logic [3:0]         layer_type,  // 0001=Conv, 0010=ReLU, 0100=MaxPool, 1000=FC

    // 层启动/完成
    output logic               layer_start_cmd,
    input wire logic               layer_done_ack,
    input wire logic               layer_error,

    // 权重加载控制
    output logic               weight_load_en,
    output logic [LAYER_IDX_WIDTH-1:0] weight_layer_idx,

    // 噪声预算监测
    output logic [3:0]         noise_budget_remaining,
    input wire logic               noise_overflow,
    input wire logic               noise_decrement,  // 每次 poly_mult 递减 1

    // 状态回读
    output logic [3:0]         state
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam [3:0] S_IDLE        = 4'd0;
    localparam [3:0] S_LOAD_WEIGHT = 4'd1;
    localparam [3:0] S_INFER_LAYER = 4'd2;
    localparam [3:0] S_NEXT_LAYER  = 4'd3;
    localparam [3:0] S_DONE        = 4'd4;
    localparam [3:0] S_ERROR       = 4'd5;

    // 层类型编码
    localparam [3:0] TYPE_CONV    = 4'b0001;
    localparam [3:0] TYPE_RELU    = 4'b0010;
    localparam [3:0] TYPE_MAXPOOL = 4'b0100;
    localparam [3:0] TYPE_FC      = 4'b1000;

    // =========================================================================
    // 状态寄存器
    // =========================================================================
    // 状态寄存器（state 已在 ANSI 端口声明为 output logic，此处不再重复声明）
    logic [3:0]               state_next;
    logic [LAYER_IDX_WIDTH-1:0] layer_idx_reg;
    logic [3:0]               noise_budget;

    // =========================================================================
    // 层序列定义（7 层）
    // =========================================================================
    // Layer 0: Conv1
    // Layer 1: ReLU
    // Layer 2: MaxPool
    // Layer 3: Conv2
    // Layer 4: ReLU
    // Layer 5: MaxPool
    // Layer 6: FC1
    // Layer 7: FC2 (logits)
    //
    // 简化为 7 层（合并 ReLU+MaxPool）

    function automatic logic [3:0] get_layer_type (
        input logic [LAYER_IDX_WIDTH-1:0] idx
    );
        case (idx)
            4'd0: return TYPE_CONV;
            4'd1: return TYPE_RELU;
            4'd2: return TYPE_MAXPOOL;
            4'd3: return TYPE_CONV;
            4'd4: return TYPE_RELU;
            4'd5: return TYPE_MAXPOOL;
            4'd6: return TYPE_FC;
            4'd7: return TYPE_FC;
            default: return TYPE_FC;
        endcase
    endfunction

    assign layer_idx    = layer_idx_reg;
    assign layer_type   = get_layer_type(layer_idx_reg);
    assign weight_layer_idx = layer_idx_reg;
    assign noise_budget_remaining = noise_budget;

    // =========================================================================
    // 噪声预算递减
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_budget <= NOISE_BUDGET_INIT[3:0];
        end else if (start && state == S_IDLE) begin
            noise_budget <= NOISE_BUDGET_INIT[3:0];  // 重置
        end else if (noise_decrement && noise_budget > 4'd0) begin
            noise_budget <= noise_budget - 4'd1;
        end
    end

    // =========================================================================
    // 状态机跳转
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
                if (start) begin
                    layer_idx_reg <= '0;
                    state_next = S_LOAD_WEIGHT;
                end
            end

            S_LOAD_WEIGHT: begin
                // 等待权重加载完成（由外部模块通知）
                if (layer_done_ack) begin
                    state_next = S_INFER_LAYER;
                end
            end

            S_INFER_LAYER: begin
                if (layer_error) begin
                    state_next = S_ERROR;
                end else if (layer_done_ack) begin
                    state_next = S_NEXT_LAYER;
                end
            end

            S_NEXT_LAYER: begin
                if (layer_idx_reg < LAYER_IDX_WIDTH'(NUM_LAYERS - 1)) begin
                    layer_idx_reg <= layer_idx_reg + 1;
                    state_next = S_LOAD_WEIGHT;
                end else begin
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
    // 输出控制
    // =========================================================================
    assign weight_load_en = (state == S_LOAD_WEIGHT);
    assign layer_start_cmd = (state == S_INFER_LAYER);

    assign busy  = (state != S_IDLE) && (state != S_DONE);
    assign done  = (state == S_DONE);
    assign error = (state == S_ERROR) || noise_overflow;

    // 状态回读：state 本身即 ANSI output 端口，直接由状态寄存器驱动，无需额外 assign
endmodule
