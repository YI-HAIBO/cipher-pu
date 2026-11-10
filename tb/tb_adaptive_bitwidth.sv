// ========================================================================= //
// Testbench: tb_adaptive_bitwidth                                           //
// Author: Yi (SZPU)                                                          //
// Description: 自适应位宽调度功能验证                                         //
// Date: 2026-10-14                                                           //
// ========================================================================= //

`timescale 1ns / 1ps

module tb_adaptive_bitwidth;

    // --------------------------------------------------------------------- //
    // 参数定义                                                              //
    // --------------------------------------------------------------------- //
    parameter int Q_WIDTH = 45;
    parameter int MAX_BITS = 16;
    parameter int MIN_BITS = 8;
    parameter int NUM_LEVELS = 4;

    // --------------------------------------------------------------------- //
    // 逻辑信号                                                              //
    // --------------------------------------------------------------------- //
    logic        clk;
    logic        rst_n;

    logic        data_valid_in;
    logic        data_ready_out;
    logic [Q_WIDTH-1:0] data_in;

    logic [Q_WIDTH-1:0] data_out;
    logic [MAX_BITS-1:0] actual_bits;
    logic        data_valid_out;
    logic        data_ready_in;
    logic        bitwidth_update;
    logic        bitwidth_done;

    // --------------------------------------------------------------------- //
    // DUT 实例化                                                              //
    // --------------------------------------------------------------------- //
    adaptive_bitwidth #(
        .Q_WIDTH(Q_WIDTH),
        .MAX_BITS(MAX_BITS),
        .MIN_BITS(MIN_BITS),
        .NUM_LEVELS(NUM_LEVELS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .data_valid_in(data_valid_in),
        .data_ready_out(data_ready_out),
        .data_in(data_in),

        .data_out(data_out),
        .actual_bits(actual_bits),
        .data_valid_out(data_valid_out),
        .data_ready_in(data_ready_in),
        .bitwidth_update(bitwidth_update),
        .bitwidth_done(bitwidth_done)
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

        // 初始化
        rst_n = 0;
        data_valid_in = 0;
        data_in = 0;

        // 复位
        @(posedge clk);
        #12;
        rst_n = 1;

        // 生成测试向量
        for (i = 0; i < 50; i = i + 1) begin
            @(posedge clk);
            data_in = $urandom() % (1 << Q_WIDTH);
            data_valid_in = 1;

            // 等待输出
            while (!data_valid_out) begin
                @(posedge clk);
            end

            // 采样输出
            $display("Time %0t: input=H%0h, output=H%0h, bits=%0d", $time, data_in, data_out, actual_bits);

            data_valid_in = 0;
            @(posedge clk);
        end

        $display("Simulation completed successfully.");
        $finish;
    end

endmodule
