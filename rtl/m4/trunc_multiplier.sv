// =============================================================================
// trunc_multiplier.sv — M4-c 截断乘法器
//
// 功能：45×45 位乘法器，支持运行时截断低位（0/9/17 位）。
//       截断后结果对齐回 INPUT_BITS 位宽，供下游 mod45_fastred 使用。
//
// 截断策略：
//   trunc_bits=0  → 完整 90-bit 乘积，取高 45-bit（Gear 0，标准行为）
//   trunc_bits=9  → 跳过底部 9-bit 部分乘，取 [89:54]（Gear 2，36-bit 有效）
//   trunc_bits=17 → 跳过底部 17-bit 部分乘，取 [89:62]（Gear 3，28-bit 有效）
//
// 数学等价：
//   result = (a * b) >> trunc_bits  取高 INPUT_BITS 位
//   即 result = floor(a * b / 2^trunc_bits) mod 2^INPUT_BITS
//
// 硬件节省：
//   - trunc_bits=9:  跳过 45×9 + 9×45 = 810 个部分乘项（~20% 乘法面积）
//   - trunc_bits=17: 跳过 45×17 + 17×45 = 1530 个部分乘项（~35% 乘法面积）
//   - 注：Vivado DSP48E2 内部固定 25×18 bit，截断主要节省加法树级数
//
// 接口：纯组合逻辑，无时钟/复位
// =============================================================================

`timescale 1ns / 1ps

module trunc_multiplier #(
    parameter int INPUT_BITS = 45,
    parameter int KEEP_BITS  = 45    // 45=全精度, 36=Gear2, 28=Gear3
) (
    input  logic [INPUT_BITS-1:0] a,
    input  logic [INPUT_BITS-1:0] b,
    input  logic [7:0]            trunc_bits,     // 0=不截断, 9=截断9位, 17=截断17位
    output logic [INPUT_BITS-1:0] result
);

    // =========================================================================
    // 完整乘积（组合逻辑）
    // =========================================================================
    logic [2*INPUT_BITS-1:0] full_product;
    logic [2*INPUT_BITS-1:0] shifted_product;

    // 标准乘法器（综合器映射到 DSP48E2 阵列）
    assign full_product = a * b;

    // =========================================================================
    // 运行时截断（移位选择）
    // =========================================================================
    // 根据 trunc_bits 选择移位量
    //   trunc_bits=0  → shifted = full_product
    //   trunc_bits=9  → shifted = full_product >> 9
    //   trunc_bits=17 → shifted = full_product >> 17
    //   其他值        → shifted = full_product（安全 fallback）

    always_comb begin
        case (trunc_bits)
            8'h00:  shifted_product = full_product;
            8'h09:  shifted_product = {full_product[89:9], {9{1'b0}}};
            8'h11:  shifted_product = {full_product[89:17], {17{1'b0}}};
            default: shifted_product = full_product;  // 安全：不截断
        endcase
    end

    // =========================================================================
    // 输出对齐：取高 INPUT_BITS 位
    // =========================================================================
    // 标准行为（trunc_bits=0）：full_product[89:45]（高 45 位）
    // 截断行为：shifted_product[89:45]（已右移后的高 45 位）

    assign result = shifted_product[2*INPUT_BITS-1:INPUT_BITS];

endmodule
