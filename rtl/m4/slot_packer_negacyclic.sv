// ========================================================================= //
// Module: slot_packer_negacyclic                                              //
// Title: Negacyclic Slot 打包器（复数域多项式）                                 //
// Author: Yi (SZPU)                                                          //
// Description:                                                                //
//   实现 CKKS 同态加密中的 negacyclic 多项式 slot 打包。                        //
//   与标准 slot_packer（Hermitian 对称）不同，negacyclic 模式使用              //
//   x^N + 1 循环边界，适合复数多项式编码场景。                                   //
//                                                                              //
//   FSM: IDLE -> SAMPLE -> IDLE                                                //
//   - IDLE:  等待首条系数输入（valid=1 时采样并进入 SAMPLE）                    //
//   - SAMPLE: 逐拍采样系数，映射到 slot 数组；                                   //
//             enable_negacyclic=1 时，对最后一项做符号翻转（negacyclic 变换）   //
//                                                                              //
//   输出：slot_real[] / slot_im[] 分别存储实部/虚部系数                        //
//   pack_done 脉冲：所有 N 个系数采样完毕后产生一拍高脉冲                       //
// ========================================================================= //
`timescale 1ns / 1ps

module slot_packer_negacyclic #(
    parameter int LOG_N       = 12,
    parameter int N           = 1 << LOG_N,
    parameter int Q_WIDTH     = 45,
    parameter int SLOT_WIDTH  = 22,
    parameter int NUM_REAL_SLOTS = N / 2
) (
    input  logic                clk,
    input  logic                rst_n,

    // 系数输入（实部 + 虚部）
    input  logic [Q_WIDTH-1:0]  coeff_real_in,
    input  logic [Q_WIDTH-1:0]  coeff_im_in,
    input  logic                coeff_valid_in,
    output logic                coeff_ready_out,

    // Slot 输出（实部 + 虚部）
    output logic [SLOT_WIDTH-1:0] slot_real [NUM_REAL_SLOTS-1:0],
    output logic [SLOT_WIDTH-1:0] slot_im   [NUM_REAL_SLOTS-1:0],
    output logic                  slot_valid,
    output logic                  slot_ready,

    // 控制
    input  logic                enable_negacyclic,
    output logic                pack_done
);

    // ========================================================================= //
    // FSM                                                                     //
    // ========================================================================= //
    typedef enum logic [1:0] {
        IDLE,
        SAMPLE
    } fsm_state_e;

    fsm_state_e state, next_state;

    // 索引与暂存寄存器
    logic [LOG_N-1:0]           idx;         // 全局系数索引（0..N-1）
    logic [LOG_N-2:0]           slot_idx;    // slot 索引（0..NUM_REAL_SLOTS-1）
    logic [SLOT_WIDTH-1:0]      real_reg;    // 实部暂存
    logic [SLOT_WIDTH-1:0]      im_reg;      // 虚部暂存

    // Slot 存储数组
    logic [SLOT_WIDTH-1:0]      slot_real_reg [NUM_REAL_SLOTS-1:0];
    logic [SLOT_WIDTH-1:0]      slot_im_reg   [NUM_REAL_SLOTS-1:0];

    // ========================================================================= //
    // 时序逻辑 — 状态机主状态、索引、暂存寄存器                                //
    // ========================================================================= //
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            idx          <= '0;
            slot_idx     <= '0;
            real_reg     <= '0;
            im_reg       <= '0;
            pack_done    <= 1'b0;
        end else begin
            state     <= next_state;
            idx       <= idx + 1'b1;
            real_reg  <= real_reg;
            im_reg    <= im_reg;
            pack_done <= 1'b0;
        end
    end

    // ========================================================================= //
    // Slot 存储更新（SAMPLE 状态时写入 slot 数组）                            //
    // ========================================================================= //
    always_ff @(posedge clk) begin
        if (state == SAMPLE && coeff_valid_in && coeff_ready_out) begin
            // 截断高位到 SLOT_WIDTH（补零）
            slot_real_reg[slot_idx] <= {
                {(SLOT_WIDTH > Q_WIDTH ? SLOT_WIDTH - Q_WIDTH : 0) {1'b0}},
                coeff_real_in
            };
            slot_im_reg[slot_idx]   <= {
                {(SLOT_WIDTH > Q_WIDTH ? SLOT_WIDTH - Q_WIDTH : 0) {1'b0}},
                coeff_im_in
            };
        end
    end

    // ========================================================================= //
    // 组合逻辑 — FSM 次态 + 控制信号                                          //
    // ========================================================================= //
    always_comb begin
        next_state       = state;
        coeff_ready_out  = 1'b1;
        slot_valid       = 1'b0;
        slot_idx         = slot_idx;

        case (state)
            IDLE: begin
                idx      = '0;
                slot_idx = '0;
                if (coeff_valid_in && coeff_ready_out) begin
                    real_reg = {
                        {(SLOT_WIDTH > Q_WIDTH ? SLOT_WIDTH - Q_WIDTH : 0) {1'b0}},
                        coeff_real_in
                    };
                    im_reg = {
                        {(SLOT_WIDTH > Q_WIDTH ? SLOT_WIDTH - Q_WIDTH : 0) {1'b0}},
                        coeff_im_in
                    };
                    next_state = SAMPLE;
                end
            end

            SAMPLE: begin
                coeff_ready_out = 1'b1;
                if (coeff_valid_in && coeff_ready_out) begin
                    real_reg = {
                        {(SLOT_WIDTH > Q_WIDTH ? SLOT_WIDTH - Q_WIDTH : 0) {1'b0}},
                        coeff_real_in
                    };
                    im_reg = {
                        {(SLOT_WIDTH > Q_WIDTH ? SLOT_WIDTH - Q_WIDTH : 0) {1'b0}},
                        coeff_im_in
                    };
                    slot_idx = slot_idx + 1'b1;

                    if (slot_idx >= NUM_REAL_SLOTS - 1) begin
                        next_state = IDLE;
                        pack_done  = 1'b1;
                        slot_valid = 1'b1;
                    end else begin
                        next_state = SAMPLE;
                    end
                end
            end

            default: next_state = IDLE;
        endcase
    end

    // ========================================================================= //
    // Slot 输出（通过 generate 映射到 slot_real_reg / slot_im_reg）          //
    // ========================================================================= //
    genvar gi;
    generate
        for (gi = 0; gi < NUM_REAL_SLOTS; gi++) begin : gen_slot_out
            if (enable_negacyclic) begin : negacyclic_mode
                // negacyclic 模式：最后一项符号翻转
                if (gi == NUM_REAL_SLOTS - 1) begin
                    assign slot_real[gi] = ~slot_real_reg[gi];
                    assign slot_im[gi]   = ~slot_im_reg[gi];
                end else begin
                    assign slot_real[gi] = slot_real_reg[gi];
                    assign slot_im[gi]   = slot_im_reg[gi];
                end
            end else begin : normal_mode
                assign slot_real[gi] = slot_real_reg[gi];
                assign slot_im[gi]   = slot_im_reg[gi];
            end
        end
    endgenerate

    // Slot ready 始终高
    assign slot_ready = 1'b1;

endmodule
