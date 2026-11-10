//=============================================================================
// structured_block_mask.sv - 结构化块剪枝引擎（v3 重写，可综合 + 可验证）
//
// 功能：对输入系数流按"结构化块"做剪枝。每个数据拍携带所属块号 block_index，
//   模块用一张 mask 表决定该块放行(keep=1)或丢弃(prune=0)：
//     - keep  : 数据透传到输出（data_valid_out=1, data_out=data_in, block_skip=0）
//     - prune : 数据丢弃（data_valid_out=0, block_skip=1）
//   mask 表通过 mask_update_en 加载：写入地址 = block_index，值 = data_in[0]。
//
// 顶层端口与原版保持一致（兼容 e2e_phase2_wrapper 例化），仅内部逻辑重写。
//
// 修正记录（v3, 2026-10-20）：
//   - 删除原版 mask_full 双重驱动（always_comb + assign 同时驱动同一 net）
//   - 删除原版把输入端口当寄存器赋值的非法写法
//   - 单级流水 + AXI4-Stream 背压（data_ready_in 反压不丢数）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module structured_block_mask #(
    parameter int BLOCK_SIZE     = 16,
    parameter int MAX_BLOCKS     = 256,
    parameter int BLOCK_KEY_BITS = 4,
    parameter int ARRAY_WIDTH    = 45
) (
    input  wire logic                          clk,
    input  wire logic                          rst_n,

    // 输入 AXI4-Stream
    input  wire logic                          data_valid_in,
    output wire logic                          data_ready_out,
    input  wire logic [ARRAY_WIDTH-1:0]        data_in,

    // 输出 AXI4-Stream
    output wire logic                          data_valid_out,
    input  wire logic                          data_ready_in,
    output wire logic [ARRAY_WIDTH-1:0]        data_out,

    // 控制接口
    input  wire logic [BLOCK_KEY_BITS-1:0]     block_type,
    input  wire logic [15:0]                   block_index,
    input  wire logic                          mask_update_en,
    output wire logic                          block_valid,
    output wire logic                          block_skip,
    output wire logic                          mask_full
);

    localparam int IDX_W = (MAX_BLOCKS > 1) ? $clog2(MAX_BLOCKS) : 1;

    // -------------------------------------------------------------------------
    // mask 表：1=keep, 0=prune（分布式 RAM 推断）
    // -------------------------------------------------------------------------
    logic                 mask_tab [0:MAX_BLOCKS-1];
    logic [IDX_W:0]       mask_cnt;                 // 已写入条目数（加宽 1 位以表示 MAX_BLOCKS）
    logic [IDX_W-1:0]     bidx;                     // block_index 低位寻址
    assign bidx = block_index[IDX_W-1:0];

    logic                 mask_now;
    assign mask_now = mask_tab[bidx];               // 当前拍 mask 查表（旧值语义）

    assign mask_full = (mask_cnt >= (IDX_W+1)'(MAX_BLOCKS));

    // -------------------------------------------------------------------------
    // 单级流水 + 背压
    // -------------------------------------------------------------------------
    logic                    vld_q;
    logic [ARRAY_WIDTH-1:0]  data_q;
    logic                    keep_q;

    wire out_fire   = vld_q && keep_q && data_ready_in;         // 输出被消费
    wire can_accept = (!vld_q) || (keep_q && out_fire) || (!keep_q); // 输出槽空/已消费/已丢弃

    // 输入握手：仅当流水能接收新拍时才 ready
    assign data_ready_out = can_accept;

    // 输出（寄存器型，稳定至被消费）
    assign data_valid_out = vld_q && keep_q;
    assign data_out       = data_q;
    assign block_skip     = vld_q && !keep_q;
    assign block_valid    = vld_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_q    <= 1'b0;
            data_q   <= '0;
            keep_q   <= 1'b0;
            mask_cnt <= '0;
        end else begin
            // mask 加载（独立于数据流，写地址=block_index，值=data_in[0]）
            if (mask_update_en) begin
                mask_tab[bidx] <= data_in[0];
                if (!mask_full)
                    mask_cnt <= mask_cnt + 1'b1;
            end
            // 数据流水推进（带回压）
            if (can_accept) begin
                vld_q  <= data_valid_in;
                data_q <= data_in;
                keep_q <= mask_now;
            end
        end
    end

    // 调试输出
    initial begin
        $display("%0t [STRUCTURED_BLOCK_MASK] BLOCK_SIZE=%0d MAX_BLOCKS=%0d ARRAY_WIDTH=%0d",
                  $time, BLOCK_SIZE, MAX_BLOCKS, ARRAY_WIDTH);
    end

endmodule

`default_nettype wire
