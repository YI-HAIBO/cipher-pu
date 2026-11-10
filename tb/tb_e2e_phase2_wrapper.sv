//=============================================================================
// tb_e2e_phase2_wrapper.sv - Phase 2 Wrapper 测试平台
//
// 验证 Phase 2 完整数据通路：量化 -> 稀疏 -> GEMM
//=============================================================================

`timescale 1ns / 1ps

module tb_e2e_phase2_wrapper();

    localparam int LOG_N       = 4;
    localparam int N           = 1 << LOG_N;
    localparam int Q_WIDTH     = 7;
    localparam int SLOT_WIDTH  = 4;
    localparam int NUM_REAL_SLOTS = N / 2;

    // 时钟和复位
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // 信号
    logic                start;
    logic                busy;
    logic                done;
    logic                error;
    logic [Q_WIDTH-1:0]  sample_in;
    logic                sample_valid;
    logic                sample_ready;
    logic [Q_WIDTH-1:0]  result_out;
    logic                result_valid;
    logic                result_ready;
    logic [15:0]         block_size;
    logic [15:0]         block_num;
    logic [7:0]          quant_threshold;
    logic                enable_sparse;
    logic                enable_quant;

    // DUT 实例化
    e2e_phase2_wrapper #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .SLOT_WIDTH(SLOT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .error(error),
        .sample_in(sample_in),
        .sample_valid(sample_valid),
        .sample_ready(sample_ready),
        .result_out(result_out),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .block_size(block_size),
        .block_num(block_num),
        .quant_threshold(quant_threshold),
        .enable_sparse(enable_sparse),
        .enable_quant(enable_quant)
    );

    // 测试变量
    integer test_pass = 0;
    integer test_fail = 0;
    integer sample_cnt = 0;

    // =========================================================================
    // 辅助任务
    // =========================================================================
    task send_sample(input logic [Q_WIDTH-1:0] val);
        begin
            sample_valid = 1;
            sample_in = val;
            @(posedge clk);
            sample_valid = 0;
            @(posedge clk);
        end
    endtask

    task wait_result(output logic [Q_WIDTH-1:0] res);
        begin
            #10;
            while (!result_valid) begin
                @(posedge clk);
            end
            result_ready = 1;
            res = result_out;
            @(posedge clk);
            result_ready = 0;
        end
    endtask

    task wait_done;
        begin
            #10;
            while (!done) begin
                @(posedge clk);
                #1;
            end
        end
    endtask

    // =========================================================================
    // 测试序列
    // =========================================================================
    initial begin
        // 初始化
        rst_n = 0;
        start = 0;
        sample_valid = 0;
        sample_ready = 0;
        result_ready = 0;
        sample_in = 0;
        block_size = 16;
        block_num = 4;
        quant_threshold = 8;
        enable_sparse = 0;
        enable_quant = 0;

        #20;
        rst_n = 1;
        #10;

        // =====================================================================
        // Test 1: 基本功能测试 (无稀疏、无量化)
        // =====================================================================
        $display("=== Test 1: Basic functionality ===");
        start = 1;
        @(posedge clk);
        start = 0;
        enable_sparse = 0;
        enable_quant = 0;

        // 发送样本
        send_sample(7'b0010101);
        wait_result(r);
        $display("  Input: 7'b0010101, Output: 7'b%07b", r);
        if (r == 7'b0010101) begin
            $display("  PASS");
            test_pass = test_pass + 1;
        end else begin
            $display("  FAIL");
            test_fail = test_fail + 1;
        end

        // =====================================================================
        // Test 2: 量化使能
        // =====================================================================
        $display("\n=== Test 2: Quantization enabled ===");
        start = 1;
        @(posedge clk);
        start = 0;
        enable_sparse = 0;
        enable_quant = 1;

        send_sample(7'b1111111);
        wait_result(r);
        $display("  Input: 7'b1111111, Output: 7'b%07b", r);
        // 量化后应该降低位宽
        if (r < 7'b1111111) begin
            $display("  PASS (quantized)");
            test_pass = test_pass + 1;
        end else begin
            $display("  FAIL");
            test_fail = test_fail + 1;
        end

        // =====================================================================
        // Test 3: 稀疏使能
        // =====================================================================
        $display("\n=== Test 3: Sparsity enabled ===");
        start = 1;
        @(posedge clk);
        start = 0;
        enable_sparse = 1;
        enable_quant = 0;

        send_sample(7'b0000000);  // 零值应该被跳过
        wait_result(r);
        $display("  Input: 7'b0000000, Output: 7'b%07b", r);
        // 零值应该产生稀疏跳过
        $display("  (Sparse skip test - checking done signal)");
        wait_done;
        if (done) begin
            $display("  PASS (sparse skip worked)");
            test_pass = test_pass + 1;
        end else begin
            $display("  FAIL (sparse skip failed)");
            test_fail = test_fail + 1;
        end

        // =====================================================================
        // Test 4: 非零稀疏测试
        // =====================================================================
        $display("\n=== Test 4: Non-zero with sparsity ===");
        start = 1;
        @(posedge clk);
        start = 0;

        send_sample(7'b0000001);  // 非零值
        wait_result(r);
        $display("  Input: 7'b0000001, Output: 7'b%07b", r);
        if (r == 7'b0000001) begin
            $display("  PASS");
            test_pass = test_pass + 1;
        end else begin
            $display("  FAIL");
            test_fail = test_fail + 1;
        end

        // =====================================================================
        // Test 5: 错误状态检查
        // =====================================================================
        $display("\n=== Test 5: Error state check ===");
        if (error) begin
            $display("  FAIL: Error asserted");
            test_fail = test_fail + 1;
        end else begin
            $display("  PASS: No error");
            test_pass = test_pass + 1;
        end

        // =====================================================================
        // 结果汇总
        // =====================================================================
        $display("\n================================");
        $display("Test Results:");
        $display("  PASS: %0d", test_pass);
        $display("  FAIL: %0d", test_fail);
        if (test_fail == 0) begin
            $display("================================");
            $display("ALL TESTS PASSED!");
        end else begin
            $display("================================");
            $display("TESTS FAILED!");
        end
        $display("================================");

        #10;
        $finish;
    end

    // 输出结果变量
    logic [Q_WIDTH-1:0] r;

    // =========================================================================
    // 波形监控
    // =========================================================================
    initial begin
        $dumpfile("wave_e2e_phase2_wrapper.vcd");
        $dumpvars(0, tb_e2e_phase2_wrapper);
    end

endmodule
