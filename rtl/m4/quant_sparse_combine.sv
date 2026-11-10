//=============================================================================
// quant_sparse_combine.sv - 低比特量化+稀疏组合引擎（v3 重写，可综合 + 可验证）
//
// 功能：对输入系数流做"低比特量化 + 稀疏跳过"联合处理。
//   量化：丢弃低 (INPUT_WIDTH-OUTPUT_WIDTH) 位，得到 OUTPUT_WIDTH 位量化值。
//   稀疏：若输入系数 <= threshold，判为稀疏，直接跳过（不出数，sparse_enable=1）；
//         否则输出量化值。每拍处理结果记入 mask_cache（1=保留,0=稀疏）。
//
// 顶层端口与原版一致（兼容 e2e_phase2_wrapper 例化），仅内部逻辑重写。
//
// 修正记录（v3, 2026-10-20）：
//   - 删除原版 quantized 双驱动（always_ff 保持 + always_comb 赋值形成组合环）
//   - 统一为单时钟域流水，量化在接收拍组合完成、寄存器输出
//   - AXI4-Stream 背压（data_ready_in 反压不丢数）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module quant_sparse_combine #(
    parameter int INPUT_WIDTH    = 45,
    parameter int OUTPUT_WIDTH   = 12,
    parameter int THRESHOLD_BITS = 8,
    parameter int MASK_DEPTH     = 256
) (
    input  wire logic                          clk,
    input  wire logic                          rst_n,

    // 输入 AXI4-Stream
    input  wire logic                          data_valid_in,
    output wire logic                          data_ready_out,
    input  wire logic [INPUT_WIDTH-1:0]        data_in,

    // 输出 AXI4-Stream
    output wire logic                          data_valid_out,
    input  wire logic                          data_ready_in,
    output wire logic [OUTPUT_WIDTH-1:0]       data_out,

    // 控制接口
    input  wire logic                          update_en,
    input  wire logic [THRESHOLD_BITS-1:0]     threshold,
    output wire logic                          sparse_enable,
    output wire logic                          quant_enable,
    output wire logic                          mask_valid
);

    localparam int SHIFT = (INPUT_WIDTH > OUTPUT_WIDTH) ? (INPUT_WIDTH - OUTPUT_WIDTH) : 0;
    localparam int MW    = (MASK_DEPTH > 1) ? $clog2(MASK_DEPTH) : 1;

    // 阈值扩展到输入宽度，用于满宽比较
    logic [INPUT_WIDTH-1:0] thr_ext;
    assign thr_ext = {{(INPUT_WIDTH-THRESHOLD_BITS){1'b0}}, threshold};

    // 当前拍的量化值 / 稀疏判定（组合）
    logic [OUTPUT_WIDTH-1:0] q_now;
    logic                    sp_now;
    assign q_now  = data_in >> SHIFT;          // 取高 OUTPUT_WIDTH 位
    assign sp_now = (data_in <= thr_ext);      // 低于阈值判稀疏

    // -------------------------------------------------------------------------
    // 单级流水 + 背压
    // -------------------------------------------------------------------------
    logic                      vld_q;
    logic [OUTPUT_WIDTH-1:0]   qval_q;
    logic                      sp_q;

    wire out_fire   = vld_q && !sp_q && data_ready_in;             // 非稀疏输出被消费
    wire can_accept = (!vld_q) || sp_q || out_fire;                // 空/稀疏不占输出/已消费

    assign data_ready_out = can_accept;
    assign data_valid_out = vld_q && !sp_q;
    assign data_out       = qval_q;
    assign sparse_enable  = vld_q && sp_q;
    assign quant_enable   = vld_q;            // 每处理一拍即完成一次量化
    assign mask_valid     = vld_q;            // 每拍一条 mask 记录

    // mask 记录缓存（1=保留, 0=稀疏）
    logic              mask_cache [0:MASK_DEPTH-1];
    logic [MW-1:0]     mask_wptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_q     <= 1'b0;
            qval_q    <= '0;
            sp_q      <= 1'b0;
            mask_wptr <= '0;
        end else begin
            if (can_accept && data_valid_in) begin
                mask_cache[mask_wptr] <= ~sp_now;   // 1=保留
                if (mask_wptr >= MW'(MASK_DEPTH-1))
                    mask_wptr <= '0;
                else
                    mask_wptr <= mask_wptr + 1'b1;
            end
            if (can_accept) begin
                vld_q  <= data_valid_in;
                qval_q <= q_now;
                sp_q   <= sp_now;
            end
        end
    end

    // update_en 预留：触发阈值重载（本实现阈值始终直连，故为空操作占位）
    // 保留端口以兼容上层 wrapper。

    // 调试输出
    initial begin
        $display("%0t [QUANT_SPARSE_COMBINE] INPUT=%0d OUTPUT=%0d THRESH_BITS=%0d MASK_DEPTH=%0d",
                  $time, INPUT_WIDTH, OUTPUT_WIDTH, THRESHOLD_BITS, MASK_DEPTH);
    end

endmodule

`default_nettype wire
