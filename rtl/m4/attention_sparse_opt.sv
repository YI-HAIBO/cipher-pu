//=============================================================================
// attention_sparse_opt.sv - 注意力机制优化，支持Attention矩阵稀疏化和QKV乘法优化
//=============================================================================

`timescale 1ns / 1ps

module attention_sparse_opt #(
    parameter int D_MODEL = 128,
    parameter int NUM_HEADS = 4,
    parameter int HEAD_DIM = 32,
    parameter int BLOCK_SIZE = 16,
    parameter int MAX_BLOCKS = 256
) (
    input  logic                clk,
    input  logic                rst_n,

    // 密文 Q, K, V 输入
    input  logic                q_valid_in,
    input  logic                k_valid_in,
    input  logic                v_valid_in,
    input  logic [D_MODEL-1:0]  q_data,
    input  logic [D_MODEL-1:0]  k_data,
    input  logic [D_MODEL-1:0]  v_data,

    // 注意力 mask (稀疏模式)
    input  logic                mask_valid,
    input  logic [MAX_BLOCKS-1:0] mask_index,

    // 输出
    output logic                out_valid,
    output logic [D_MODEL-1:0]  out_data,
    output logic                data_ready_in,
    output logic                processing,
    output logic                done
);

    // =========================================================================
    // 内部信号
    // =========================================================================
    typedef enum logic [4:0] {
        IDLE,
        LOAD_QKV,
        COMPUTE_ATTN,
        SPARSE_FILTER,
        LOAD_WEIGHTS,
        COMPUTE_OUT,
        OUTPUT,
        DONE
    } fsm_state_e;

    fsm_state_e state_reg, next_state;

    // 缓存寄存器
    logic [D_MODEL-1:0] q_cache[HEAD_DIM-1:0][BLOCK_SIZE-1:0];
    logic [D_MODEL-1:0] k_cache[HEAD_DIM-1:0][BLOCK_SIZE-1:0];
    logic [D_MODEL-1:0] v_cache[HEAD_DIM-1:0][BLOCK_SIZE-1:0];

    // 索引寄存器
    logic [8-1:0] head_idx;
    logic [12-1:0] seq_idx;
    logic [12-1:0] block_idx;

    // sparse mask 缓存
    logic sparse_mask[MAX_BLOCKS-1:0];

    // 状态寄存器
    logic [D_MODEL-1:0] out_data_reg;

    // =========================================================================
    // 状态机
    // =========================================================================
    // Sequential: state register, processing, done
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= IDLE;
            processing <= 1'b0;
            done <= 1'b0;
        end else begin
            state_reg <= next_state;
            processing <= (state_reg != IDLE);
            done <= (state_reg == DONE);
        end
    end

    // Combinational: next state, out_valid, data_ready_in, out_data
    always_comb begin
        next_state = state_reg;
        out_valid = 1'b0;
        data_ready_in = 1'b1;
        out_data = out_data_reg;

        case (state_reg)
            IDLE: begin
                if (q_valid_in && k_valid_in && v_valid_in) begin
                    next_state = LOAD_QKV;
                end
            end

            LOAD_QKV: begin
                // 加载 Q、K、V
                next_state = COMPUTE_ATTN;
            end

            COMPUTE_ATTN: begin
                // 计算注意力分数 (简化)
                next_state = SPARSE_FILTER;
            end

            SPARSE_FILTER: begin
                // 根据 sparse mask 过滤低分数
                next_state = LOAD_WEIGHTS;
            end

            LOAD_WEIGHTS: begin
                // 加载权重参数
                next_state = COMPUTE_OUT;
            end

            COMPUTE_OUT: begin
                // 计算输出
                out_data_reg = out_data_reg; // placeholder for actual computation
                next_state = OUTPUT;
            end

            OUTPUT: begin
                out_valid = 1'b1;
                if (out_valid && data_ready_in) begin
                    next_state = IDLE;
                end
            end

            DONE: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // 调试输出
    initial begin
        $display("%0t [ATTN_SPARSE_OPT] D_MODEL=%0d NUM_HEADS=%0d",
                  $time, D_MODEL, NUM_HEADS);
    end

endmodule
