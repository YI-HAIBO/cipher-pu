// ========================================================================= //
// Testbench: tb_histogram_adaptive_quant                                    //
// Author: Yi (SZPU)                                                          //
// Description: 直方图统计 + 自适应量化功能验证                                //
// Date: 2026-10-14                                                           //
// ========================================================================= //

`timescale 1ns / 1ps

module tb_histogram_adaptive_quant;

    // --------------------------------------------------------------------- //
    // 参数定义 - 与 DUT 参数匹配                                               //
    // --------------------------------------------------------------------- //
    parameter int Q_WIDTH = 45;
    parameter int NUM_BINS = 64;
    parameter int HIST_WIDTH = 8;
    parameter int QUANT_BITS = 12;

    // --------------------------------------------------------------------- //
    // 逻辑信号                                                              //
    // --------------------------------------------------------------------- //
    logic        clk;
    logic        rst_n;

    // histogram input (not used for this simple test)
    logic [HIST_WIDTH-1:0] bin[NUM_BINS-1:0];
    logic                hist_valid;

    // input stream
    logic                data_valid_in;
    logic                data_ready_out;
    logic [Q_WIDTH-1:0]  data_in;

    // output
    logic [QUANT_BITS-1:0]  quantized;
    logic                data_valid_out;
    logic                data_ready_in;
    logic [Q_WIDTH-1:0]  quant_param;
    logic                quant_done;
    logic                quant_error;

    // --------------------------------------------------------------------- //
    // DUT 实例化                                                              //
    // --------------------------------------------------------------------- //
    histogram_adaptive_quant #(
        .Q_WIDTH(Q_WIDTH),
        .NUM_BINS(NUM_BINS),
        .HIST_WIDTH(HIST_WIDTH),
        .QUANT_BITS(QUANT_BITS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .bin(bin),
        .hist_valid(hist_valid),

        .data_valid_in(data_valid_in),
        .data_ready_out(data_ready_out),
        .data_in(data_in),

        .quantized(quantized),
        .data_valid_out(data_valid_out),
        .data_ready_in(data_ready_in),
        .quant_param(quant_param),
        .quant_done(quant_done),
        .quant_error(quant_error)
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
        for (integer k = 0; k < NUM_BINS; k = k + 1) bin[k] = 0;
        hist_valid = 0;

        // 复位
        @(posedge clk);
        #12;
        rst_n = 1;

        // 生成测试向量
        for (i = 0; i < 100; i = i + 1) begin
            @(posedge clk);
            data_in = $urandom() % (1 << Q_WIDTH);
            data_valid_in = 1;

            // 等待输出
            while (!data_valid_out) begin
                @(posedge clk);
            end

            // 采样输出
            $display("Time %0t: input=H%0h, output=H%0h, param=H%0h", $time, data_in, quantized, quant_param);

            data_valid_in = 0;
            @(posedge clk);
        end

        $display("Simulation completed successfully.");
        $finish;
    end

endmodule
