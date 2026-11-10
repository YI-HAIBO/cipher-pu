// =============================================================================
// adaptive_gear_ctrl.sv — CKKS 自适应档位控制器（M4-h）
//
// 根据噪声能量 energy_q2 选择推理档位：
//   gear_sel = 0 → 能量最高（最嘈杂，使用最高精度档位）
//   gear_sel = 3 → 能量最低（最干净，使用最低精度档位）
//
// 阈值：
//   energy >= THRESH_G1 → gear=0
//   energy >= THRESH_G2 → gear=1
//   energy >= THRESH_G3 → gear=2
//   energy <  THRESH_G3 → gear=3
//
// 迟滞模式（hysteresis_en=1）：
//   升档（gear 增大，噪声降低）需要 HYST_CNT 次连续候选才生效
//   降档（gear 减小，噪声升高）立即生效
// =============================================================================

`timescale 1ns / 1ps

module adaptive_gear_ctrl #(
    parameter int ACC_W         = 106,
    parameter logic [ACC_W-1:0] THRESH_G1 = 64'd500,
    parameter logic [ACC_W-1:0] THRESH_G2 = 64'd200,
    parameter logic [ACC_W-1:0] THRESH_G3 = 64'd50,
    parameter int HYST_CNT      = 3
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic [ACC_W-1:0]      energy_q2,
    input  logic                  flush_valid,
    input  logic                  hysteresis_en,
    input  logic [2:0]            manual_gear,
    input  logic                  manual_en,
    output logic [2:0]            gear_sel,
    output logic [2:0]            gear_raw
);

    // =========================================================================
    // 原始档位判定（组合逻辑）
    // =========================================================================
    logic [2:0] raw_sel;
    always_comb begin
        if      (energy_q2 >= THRESH_G1) raw_sel = 3'd0;
        else if (energy_q2 >= THRESH_G2) raw_sel = 3'd1;
        else if (energy_q2 >= THRESH_G3) raw_sel = 3'd2;
        else                              raw_sel = 3'd3;
    end

    // =========================================================================
    // 迟滞计数器
    // =========================================================================
    localparam int HYST_W = $clog2(HYST_CNT + 1);
    logic [HYST_W-1:0] hyst_counter;
    logic [2:0]        hyst_candidate;

    // =========================================================================
    // 档位寄存器
    // =========================================================================
    logic [2:0] gear_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            gear_r        <= 3'd3;
            hyst_counter  <= '0;
            hyst_candidate <= 3'd3;
        end else if (flush_valid) begin
            if (manual_en) begin
                gear_r <= manual_gear;
                hyst_counter <= '0;
            end else if (hysteresis_en) begin
                if (raw_sel > gear_r) begin
                    // 升档候选（噪声降低，档位升高）
                    if (raw_sel == hyst_candidate) begin
                        hyst_counter <= hyst_counter + 1'b1;
                    end else begin
                        hyst_candidate <= raw_sel;
                        hyst_counter   <= 1'b1;
                    end
                    if (hyst_counter >= HYST_CNT[HYST_W-1:0]) begin
                        gear_r       <= raw_sel;
                        hyst_counter <= '0;
                        hyst_candidate <= gear_r;
                    end
                end else if (raw_sel < gear_r) begin
                    // 降档（噪声升高）：立即生效
                    gear_r         <= raw_sel;
                    hyst_counter   <= '0;
                    hyst_candidate <= raw_sel;
                end else begin
                    // 同档：重置计数器
                    hyst_counter   <= '0;
                    hyst_candidate <= raw_sel;
                end
            end else begin
                // 无迟滞：直接更新
                gear_r <= raw_sel;
            end
        end
    end

    // =========================================================================
    // 输出
    // =========================================================================
    assign gear_sel = (manual_en) ? manual_gear : gear_r;
    assign gear_raw = raw_sel;

endmodule
