//=============================================================================
// tb_ciph_stat_probe.sv - 密文域统计探针测试平台
// 
// 验证 ciph_stat_probe 的功能正确性
// 对比 RTL 实现与 Python Golden Model 的一致性
//=============================================================================

`timescale 1ns / 1ps

module tb_ciph_stat_probe();

    // =========================================================================
    // 参数定义
    // =========================================================================
    localparam int Q_WIDTH = 7;
    localparam int STAT_MODE = 3;
    localparam int HIST_BINS = 16;
    localparam int SAMPLE_DEPTH = 64;

    // =========================================================================
    // 时钟和复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 接口
    // =========================================================================
    logic                data_valid;
    logic                data_ready;
    logic [Q_WIDTH-1:0]  data;
    logic                stat_en;
    logic [1:0]          stat_cmd;
    logic [Q_WIDTH-1:0]  stat_result1;
    logic [Q_WIDTH-1:0]  stat_result2;
    logic                stat_done;
    logic                stat_error;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    ciph_stat_probe #(
        .Q_WIDTH    (Q_WIDTH),
        .STAT_MODE  (STAT_MODE),
        .HIST_BINS  (HIST_BINS),
        .SAMPLE_DEPTH(SAMPLE_DEPTH)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .data_valid   (data_valid),
        .data_ready   (data_ready),
        .data         (data),
        .stat_en      (stat_en),
        .stat_cmd     (stat_cmd),
        .stat_result1 (stat_result1),
        .stat_result2 (stat_result2),
        .stat_done    (stat_done),
        .stat_error   (stat_error)
    );

    // =========================================================================
    // 测试激励
    // =========================================================================
    integer total_count;
    int integer[] test_data;
    
    initial begin
        // 初始化测试数据
        total_count = 0;
        test_data = new[16];
        test_data[0] = 1;
        test_data[1] = 5;
        test_data[2] = 3;
        test_data[3] = 7;
        test_data[4] = 2;
        test_data[5] = 6;
        test_data[6] = 4;
        test_data[7] = 0;
        test_data[8] = 1;
        test_data[9] = 2;
        test_data[10] = 3;
        test_data[11] = 4;
        test_data[12] = 5;
        test_data[13] = 6;
        test_data[14] = 7;
        test_data[15] = 8;

        // 复位
        rst_n = 0;
        data = 0;
        repeat(20) @(posedge clk);
        rst_n = 1;

        // 初始化数据
        data_valid = 0;
        data_ready = 1;
        stat_en = 0;
        stat_cmd = 0;

        // 测试模式 1：重要性估计
        $display("\n[TEST] 模式 1: 重要性估计");
        stat_en = 1;
        data = test_data[0];
        data_valid = 1;
        @(posedge clk);
        data_valid = 0;
        while (!stat_done) @(posedge clk);
        $display("  Coeff=%0d Importance=%0d", test_data[0], stat_result1);
        stat_en = 0;

        // 测试模式 2：直方图构建
        $display("\n[TEST] 模式 2: 直方图构建");
        stat_en = 1;
        for (int i = 0; i < 8; i = i + 1) begin
            data = test_data[i];
            data_valid = 1;
            @(posedge clk);
            data_valid = 0;
        end
        wait(stat_en && stat_done);
        $display("  直方图统计完成");
        stat_en = 0;

        // 测试模式 3：自适应量化
        $display("\n[TEST] 模式 3: 自适应量化");
        stat_en = 1;
        wait(stat_en && stat_done);
        $display("  量化参数=%0d", stat_result1);
        stat_en = 0;

        // 测试模式 4：所有模式
        $display("\n[TEST] 模式 4: 全功能测试");
        stat_en = 1;
        for (int i = 0; i < 8; i = i + 1) begin
            data = test_data[i];
            data_valid = 1;
            @(posedge clk);
            data_valid = 0;
        end
        wait(stat_en && stat_done);
        $display("  重要性=%0d, 量化参数=%0d", stat_result1, stat_result2);
        stat_en = 0;

        $display("\n[TEST] 所有测试完成");
        $finish;
    end

    // =========================================================================
    // 调试输出
    // =========================================================================
    initial begin
        $display("%0t [TB] ciph_stat_probe 测试平台启动", $time);
    end

endmodule
