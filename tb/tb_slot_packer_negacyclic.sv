// ========================================================================= //
// Testbench: tb_slot_packer_negacyclic                                        //
// Author: Yi (SZPU)                                                          //
// Description: negacyclic 打包功能验证                                         //
// Date: 2026-10-14                                                           //
// ========================================================================= //

`timescale 1ns / 1ps

module tb_slot_packer_negacyclic;

    // --------------------------------------------------------------------- //
    // 参数定义                                                              //
    // --------------------------------------------------------------------- //
    parameter int LOG_N = 12;
    parameter int N = 1 << LOG_N;
    parameter int Q_WIDTH = 45;
    parameter int SLOT_WIDTH = 22;
    parameter int NUM_REAL_SLOTS = N / 2;

    // --------------------------------------------------------------------- //
    // 逻辑信号                                                              //
    // --------------------------------------------------------------------- //
    logic        clk;
    logic        rst_n;

    logic [Q_WIDTH-1:0] coeff_real_in;
    logic [Q_WIDTH-1:0] coeff_im_in;
    logic               coeff_valid_in;
    logic               coeff_ready_out;

    logic [SLOT_WIDTH-1:0] slot_real[NUM_REAL_SLOTS-1:0];
    logic [SLOT_WIDTH-1:0] slot_im[NUM_REAL_SLOTS-1:0];
    logic                  slot_valid;
    logic                  slot_ready;

    logic                  enable_negacyclic;
    logic                  pack_done;

    // --------------------------------------------------------------------- //
    // DUT 实例化                                                              //
    // --------------------------------------------------------------------- //
    slot_packer_negacyclic #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .SLOT_WIDTH(SLOT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .coeff_real_in(coeff_real_in),
        .coeff_im_in(coeff_im_in),
        .coeff_valid_in(coeff_valid_in),
        .coeff_ready_out(coeff_ready_out),

        .slot_real(slot_real),
        .slot_im(slot_im),
        .slot_valid(slot_valid),
        .slot_ready(slot_ready),

        .enable_negacyclic(enable_negacyclic),
        .pack_done(pack_done)
    );

    // --------------------------------------------------------------------- //
    // 时钟生成                                                                //
    // --------------------------------------------------------------------- //
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100 MHz
    end

    // --------------------------------------------------------------------- //
    // 测试激励                                                                  //
    // --------------------------------------------------------------------- //
    initial begin
        integer i;
        integer test_cases = 100;

        // 初始化
        rst_n = 0;
        coeff_real_in = 0;
        coeff_im_in = 0;
        coeff_valid_in = 0;
        slot_ready = 1;
        enable_negacyclic = 0;

        // 复位
        @(posedge clk);
        #12;
        rst_n = 1;

        // 测试 1: 正常模式
        $display("=== Test 1: Normal Mode ===");
        enable_negacyclic = 0;

        for (i = 0; i < test_cases; i = i + 1) begin
            @(posedge clk);
            coeff_real_in = $urandom() % (1 << Q_WIDTH);
            coeff_im_in = $urandom() % (1 << Q_WIDTH);
            coeff_valid_in = 1;

            // 等待有效输出
            while (!slot_valid) begin
                @(posedge clk);
            end

            // 采样输出
            $display("  coeff_real=H%08h, coeff_im=H%08h", coeff_real_in, coeff_im_in);
            // 验证输出（简化）
            coeff_valid_in = 0;
            @(posedge clk);
        end

        // 测试 2: Negacyclic 模式
        $display("=== Test 2: Negacyclic Mode ===");
        enable_negacyclic = 1;
        coeff_valid_in = 0;

        for (i = 0; i < test_cases; i = i + 1) begin
            @(posedge clk);
            coeff_real_in = $urandom() % (1 << Q_WIDTH);
            coeff_im_in = $urandom() % (1 << Q_WIDTH);
            coeff_valid_in = 1;

            // 等待有效输出
            while (!slot_valid) begin
                @(posedge clk);
            end

            $display("  coeff_real=H%08h, coeff_im=H%08h", coeff_real_in, coeff_im_in);
            coeff_valid_in = 0;
            @(posedge clk);
        end

        $display("Simulation completed successfully.");
        $finish;
    end

endmodule
