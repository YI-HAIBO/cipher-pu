// ========================================================================= //
// Testbench: tb_neuroorphic_cipher                                          //
// Author: Yi (SZPU)                                                          //
// Description: 神经形态计算引擎功能验证                                       //
// Date: 2026-10-14                                                           //
// ========================================================================= //

`timescale 1ns / 1ps

module tb_neuroorphic_cipher;

    // --------------------------------------------------------------------- //
    // 参数定义                                                              //
    // --------------------------------------------------------------------- //
    parameter int LOG_N = 12;
    parameter int DAT_WIDTH = 7;
    parameter int ACT_THRESH = 3;
    parameter int EVENTS = 16;

    // --------------------------------------------------------------------- //
    // 逻辑信号                                                              //
    // --------------------------------------------------------------------- //
    logic        clk;
    logic        rst_n;

    logic [DAT_WIDTH-1:0] cis_tdata;
    logic                  cis_tvalid;
    logic                  cis_tready;

    logic [DAT_WIDTH-1:0] cos_tdata;
    logic                  cos_tvalid;
    logic                  cos_tready;

    logic                  ev_start;
    logic                  ev_done;

    // --------------------------------------------------------------------- //
    // DUT 实例化                                                              //
    // --------------------------------------------------------------------- //
    neuroomorphic_cipher #(
        .LAT_WIDTH(DAT_WIDTH),
        .ACT_THRESH(ACT_THRESH),
        .EVENTS(EVENTS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .cis_tdata(cis_tdata),
        .cis_tvalid(cis_tvalid),
        .cis_tready(cis_tready),

        .cos_tdata(cos_tdata),
        .cos_tvalid(cos_tvalid),
        .cos_tready(cos_tready),

        .ev_start(ev_start),
        .ev_done(ev_done)
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
        cis_tdata = 0;
        cis_tvalid = 0;
        ev_start = 0;

        // 复位
        @(posedge clk);
        #12;
        rst_n = 1;

        // 生成测试向量
        for (i = 0; i < 32; i = i + 1) begin
            @(posedge clk);
            cis_tdata = $urandom() % (1 << DAT_WIDTH);
            cis_tvalid = 1;

            // 等待输出
            while (!cos_tvalid) begin
                @(posedge clk);
            end

            // 采样输出
            $display("Time %0t: cis=H%0h, cos=H%0h", $time, cis_tdata, cos_tdata);

            cis_tvalid = 0;
            @(posedge clk);
        end

        $display("Simulation completed successfully.");
        $finish;
    end

endmodule
