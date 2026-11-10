//=============================================================================
// momentum_momentum_sparse.sv - 动量近似稀疏化器
// 
// 实现动量驱动的动态稀疏mask
// 基于系数的重要性估计（动量值）动态调整mask
// 支持平滑度调整、内存效率和精度控制
//=============================================================================

`timescale 1ns / 1ps

module momentum_momentum_sparse #(
    parameter int Q_WIDTH = 45,
    parameter int MASK_DEPTH = 256,
    parameter int MOMENTUM_BITS = 16,
    parameter int SMOOTHING_FACTOR = 3
) (
    input  logic                clk,
    input  logic                rst_n,
    
    // 密文系数输入流
    input  logic                data_valid_in,
    input  logic                data_ready_out,
    input  logic [Q_WIDTH-1:0]  data_in,
    
    // 数据输出流
    output logic                data_valid_out,
    output logic                data_ready_in,
    output logic [Q_WIDTH-1:0]  data_out,
    
    // 控制接口
    input  logic                update_en,
    output logic                mask_valid,
    output logic [MASK_DEPTH-1:0] mask_index,
    output logic                mask_empty,
    output logic                mask_full
);

    // =========================================================================
    // 内部信号
    // =========================================================================
    logic [MOMENTUM_BITS-1:0] momentum_counter;
    logic [MASK_DEPTH-1:0] current_mask;
    int integer mask_idx;
    int integer smoothed_momentum;
    
    typedef enum logic [1:0] {
        STANDBY,     /* 空闲状态 */
        MOMENTUM,    /* 动量计算状态 */
        SMOOTH,      /* 平滑过滤状态 */
        MASK_UPDATE, /* 更新mask状态 */
        OUTPUT       /* 输出状态 */
    } fsm_state_e;
    
    fsm_state_e state, next_state;
    
    // =========================================================================
    // 状态机
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STANDBY;
            mask_idx <= 0;
            current_mask <= '0;
            momentum_counter <= 0;
        end else begin
            state <= next_state;
            mask_idx <= (state == MASK_UPDATE ||
                         data_ready_in && !data_valid_out) ? mask_idx + 1 : mask_idx;
            current_mask <= next_state == MASK_UPDATE ? current_mask | smoothed_momentum : current_mask;
        end
    end

    // =========================================================================
    // 动量估计
    // =========================================================================
    always_comb begin
        next_state = state;
        data_valid_out = 1'b0;
        data_ready_in = 1'b1;
        data_out = 0;
        
        case (state)
            STANDBY: begin
                data_valid_out = data_valid_in;
                data_out = data_in;
                if (update_en && !data_valid_out) begin
                    next_state = MOMENTUM;
                end
            end
            
            MOMENTUM: begin
                // 计算当前系数的动量
                momentum_counter = data_in[MOMENTUM_BITS-1:0];
                next_state = SMOOTH;
            end
            
            SMOOTH: begin
                // 动量平滑
                smoothed_momentum = (momentum_counter * SMOOTHING_FACTOR) >> 2;
                next_state = MASK_UPDATE;
            end
            
            MASK_UPDATE: begin
                // 更新mask并输出
                if (mask_idx == MASK_DEPTH - 1) begin
                    next_state = STANDBY;
                end else begin
                    next_state = MASK_UPDATE;
                end
            end
            
            OUTPUT: begin
                data_valid_out = data_valid_in;
                data_out = data_in;
                if (data_ready_out) begin
                    next_state = STANDBY;
                end
            end
            
            default: next_state = STANDBY;
        endcase
    end

    // =========================================================================
    // 掩码有效性
    // =========================================================================
    assign mask_valid = smooth_momentum != 0;
    assign mask_empty = mask_idx == 0;
    assign mask_full = mask_idx >= MASK_DEPTH - 1;

    // =========================================================================
    warden 结束
    initial begin
        $display("%0t [MOMENTUM_MOMENTUM] MODL=0x%x SMOOTH={%d} 初始化完成", 
                  $time, MOMENTUM_BITS, SMOOTHING_FACTOR);
    end

endmodule
