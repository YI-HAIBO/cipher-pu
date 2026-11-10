// =============================================================================
// block_sparse_mask.sv — 结构化稀疏块级掩码生成器（Task #84）
//
// 算法：
//   将 N 个系数分组为 NUM_BLOCKS 个块（每块 BLOCK_SIZE 个元素）
//   对每块计算模数域最大绝对值 max_abs = max(min(x_i, q-x_i))
//   若 max_abs < threshold → 跳过整块（mask=0）
//   若 max_abs >= threshold → 保留整块（mask=1）
//
// 流式协议（块级）：
//   输入：逐块送入 BLOCK_SIZE 个样本
//   输出：逐块输出 BLOCK_SIZE 个过滤后样本
//   done：所有块处理完毕后产生单拍脉冲
//
// 修复 (2026-10-18)：
//   1. done 信号从两个 always_ff 合并到状态机内部（消除多驱动）
//   2. keep/skip 决策使用 max_abs_next（含当前样本的 abs_val）
//   3. bypass_en 模式下正确流式透传
// =============================================================================

`timescale 1ns / 1ps

module block_sparse_mask #(
    parameter int LOG_N       = 4,
    parameter int N           = 16,
    parameter int Q_WIDTH     = 7,
    parameter int Q_VALUE     = 113,
    parameter int BLOCK_SIZE  = 2,
    parameter int NUM_BLOCKS  = N / BLOCK_SIZE
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start,
    // 输入：原始系数
    input  logic                  sample_valid,
    output logic                  sample_ready,
    input  logic [Q_WIDTH-1:0]    sample_data,
    // 输出：过滤后系数
    output logic                  mask_valid,
    input  logic                  mask_ready,
    output logic [Q_WIDTH-1:0]    mask_data,
    // 控制
    input  logic [Q_WIDTH-1:0]    threshold,
    input  logic                  bypass_en,
    output logic                  done,
    // 块级掩码
    output logic [NUM_BLOCKS-1:0] block_mask,
    // 统计
    output logic [$clog2(NUM_BLOCKS):0] skip_count,
    output logic [$clog2(NUM_BLOCKS):0] total_blocks
);

    // =========================================================================
    // 本地参数
    // =========================================================================
    localparam int BLOCK_IDX_W = $clog2(NUM_BLOCKS);
    localparam int BLOCK_ELEM_W = (BLOCK_SIZE > 1) ? $clog2(BLOCK_SIZE) : 1;
    localparam int BLOCK_ELEM_MAX = BLOCK_SIZE - 1;
    localparam int NUM_BLOCKS_MAX = NUM_BLOCKS - 1;

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam logic [1:0] S_IDLE     = 2'd0;
    localparam logic [1:0] S_COLLECT  = 2'd1;  // 收集块内元素，计算 max_abs
    localparam logic [1:0] S_OUTPUT   = 2'd2;  // 输出块数据（keep/skip）

    logic [1:0]                   state;
    logic [BLOCK_IDX_W-1:0]       blk_idx;
    logic [BLOCK_ELEM_W-1:0]      elem_idx;
    logic [Q_WIDTH-1:0]           block_elem [0:BLOCK_SIZE-1];  // 当前块缓冲
    logic [Q_WIDTH-1:0]           max_abs;
    logic                         keep_flag;
    logic [NUM_BLOCKS-1:0]        block_mask_r;
    logic [$clog2(NUM_BLOCKS):0]  skip_cnt_r;
    logic [$clog2(NUM_BLOCKS):0]  total_r;
    logic                         done_r;

    // =========================================================================
    // 模数域绝对值：min(x, q-x)
    // =========================================================================
    wire [Q_WIDTH-1:0] q_minus_s = Q_VALUE[Q_WIDTH-1:0] - sample_data;
    wire [Q_WIDTH-1:0] abs_val = (q_minus_s < sample_data) ? q_minus_s : sample_data;

    // 含当前样本的 max_abs（修复：决策时使用）
    wire [Q_WIDTH-1:0] max_abs_next = (abs_val > max_abs) ? abs_val : max_abs;

    // =========================================================================
    // 输出逻辑
    // =========================================================================
    assign sample_ready = (state == S_COLLECT);
    assign mask_valid   = (state == S_OUTPUT);
    assign mask_data    = block_elem[elem_idx];

    assign done         = done_r;
    assign block_mask   = block_mask_r;
    assign skip_count   = skip_cnt_r;
    assign total_blocks = total_r;

    // =========================================================================
    // 状态机
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            blk_idx     <= '0;
            elem_idx    <= '0;
            max_abs     <= '0;
            keep_flag   <= 1'b0;
            block_mask_r <= '0;
            skip_cnt_r  <= '0;
            total_r     <= '0;
            done_r      <= 1'b0;
        end else begin
            done_r <= 1'b0;  // 每拍清 0，仅在完成时置 1

            case (state)
                S_IDLE: begin
                    if (start) begin
                        blk_idx      <= '0;
                        elem_idx     <= '0;
                        max_abs      <= '0;
                        block_mask_r <= '0;
                        skip_cnt_r   <= '0;
                        total_r      <= NUM_BLOCKS[$clog2(NUM_BLOCKS):0];
                        if (bypass_en)
                            block_mask_r <= {NUM_BLOCKS{1'b1}};
                        state <= S_COLLECT;  // bypass 也走 S_COLLECT→S_OUTPUT
                    end
                end

                S_COLLECT: begin
                    if (sample_valid) begin
                        block_elem[elem_idx] <= sample_data;

                        if (!bypass_en) begin
                            if (abs_val > max_abs)
                                max_abs <= abs_val;
                        end

                        elem_idx <= elem_idx + BLOCK_ELEM_W'(1);

                        if (elem_idx == BLOCK_ELEM_MAX) begin
                            if (!bypass_en) begin
                                keep_flag <= (max_abs_next >= threshold);
                                block_mask_r[blk_idx] <= (max_abs_next >= threshold);
                                if (max_abs_next < threshold)
                                    skip_cnt_r <= skip_cnt_r + 1'b1;
                            end

                            elem_idx <= '0;
                            if (!bypass_en)
                                max_abs <= '0;

                            state <= S_OUTPUT;
                        end
                    end
                end

                S_OUTPUT: begin
                    if (mask_valid && mask_ready) begin
                        // bypass 模式直接透传 sample_data，非 bypass 输出 block_elem
                        if (!bypass_en) begin
                            if (!keep_flag)
                                block_elem[elem_idx] <= '0;
                        end

                        elem_idx <= elem_idx + BLOCK_ELEM_W'(1);

                        if (elem_idx == BLOCK_ELEM_MAX) begin
                            blk_idx <= blk_idx + BLOCK_IDX_W'(1);
                            elem_idx <= '0;

                            if (blk_idx == NUM_BLOCKS_MAX) begin
                                state  <= S_IDLE;
                                done_r <= 1'b1;
                            end else begin
                                state   <= S_COLLECT;
                                if (!bypass_en)
                                    max_abs <= '0;
                            end
                        end
                    end
                end

                default: begin
                    state  <= S_IDLE;
                    done_r <= 1'b0;
                end
            endcase
        end
    end

endmodule
