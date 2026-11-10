// =============================================================================
// tb_slot_packer.sv — 多 Slot SIMD 样本打包器 TB
//
// 玩具配置: N=16, Q_WIDTH=7, NUM_SLOTS=8
//
// 测试用例：
//   Test 1: 基本打包功能（samples = 1..8）
//   Test 2: Hermitian 对称验证（poly[i] == poly[N-1-i]）
//   Test 3: 不同样本值测试（samples = 100, 200, ...）
//   Test 4: 边界值测试（samples = 0, 127）
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_slot_packer;

    // =========================================================================
    // 玩具配置
    // =========================================================================
    localparam int LOG_N     = 4;
    localparam int N         = 16;
    localparam int Q_WIDTH   = 7;
    localparam int NUM_SLOTS = N / 2;

    // =========================================================================
    // 时钟 & 复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 信号
    // =========================================================================
    logic                     start        = 1'b0;
    logic                     sample_valid = 1'b0;
    logic                     sample_ready;
    logic [Q_WIDTH-1:0]       sample_data  = '0;
    logic                     poly_valid;
    logic                     poly_ready   = 1'b1;
    logic [Q_WIDTH-1:0]       poly_data;
    logic                     done;

    // =========================================================================
    // 测试数据
    // =========================================================================
    logic [Q_WIDTH-1:0] expected_samples [0:NUM_SLOTS-1];
    logic [Q_WIDTH-1:0] captured_coeffs [0:N-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    slot_packer #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .NUM_SLOTS(NUM_SLOTS)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .sample_valid(sample_valid),
        .sample_ready(sample_ready),
        .sample_data(sample_data),
        .poly_valid(poly_valid),
        .poly_ready(poly_ready),
        .poly_data(poly_data),
        .done(done)
    );

    // =========================================================================
    // 调试：打印 DUT 内部状态
    // =========================================================================
    // =========================================================================
    // 测试辅助 task
    // =========================================================================
    task automatic do_reset;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    task automatic check(input string name, input logic cond);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("[PASS] %s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %s", name);
            end
        end
    endtask

    // 发送 N/2 个样本并捕获 N 个系数
    task automatic run_pack(input logic [Q_WIDTH-1:0] samples [0:NUM_SLOTS-1],
                            output logic [Q_WIDTH-1:0] coeffs [0:N-1]);
        automatic integer i;
        automatic integer timeout;

        // 启动
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // 等待 sample_ready（在 negedge 检查）
        timeout = 0;
        while (sample_ready !== 1'b1 && timeout < 20) begin
            @(negedge clk);
            timeout = timeout + 1;
        end

        // 发送 N/2 个样本
        // 在 negedge 设置 sample_data 和 sample_valid，确保 DUT 在下一个 posedge 采样到正确的值
        @(negedge clk);
        sample_valid = 1'b1;
        sample_data = samples[0];  // 预加载第一个样本
        for (i = 0; i < NUM_SLOTS; i = i + 1) begin
            @(posedge clk);  // DUT 采样 sample_data
            @(negedge clk);  // 在 negedge 设置下一个样本
            if (i < NUM_SLOTS - 1)
                sample_data = samples[i+1];  // 为下一拍准备
        end
        sample_valid = 1'b0;

        // 等待 poly_valid
        timeout = 0;
        while (poly_valid !== 1'b1 && timeout < 30) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        // 捕获 N 个系数（在 posedge 后采样，确保数据稳定）
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            coeffs[i] = poly_data;
        end

        // 等待 done
        timeout = 0;
        while (done !== 1'b1 && timeout < 10) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    initial begin
        $display("==== tb_slot_packer ====");
        $display("Config: N=%0d, Q_WIDTH=%0d, NUM_SLOTS=%0d", N, Q_WIDTH, NUM_SLOTS);
        $display("");

        // ===================================================================
        $display("---- Test 1: 基本打包 (samples = 1..8) ----");
        do_reset;

        // 准备测试数据
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            expected_samples[i] = 7'(i + 1);
        end

        // 运行打包
        run_pack(expected_samples, captured_coeffs);

        // 验证 poly[0..N/2-1] == samples[0..N/2-1]
        begin : verify_fwd
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_coeffs[i] !== expected_samples[i]) begin
                    $display("  [err] poly[%0d] = %0d, expected %0d",
                             i, captured_coeffs[i], expected_samples[i]);
                    err = err + 1;
                end
            end
            check("Test 1a: poly[0..7] matches samples", err == 0);
        end

        // 验证 poly[N-1-i] == samples[i]（Hermitian 对称）
        begin : verify_rev
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_coeffs[N-1-i] !== expected_samples[i]) begin
                    $display("  [err] poly[%0d] = %0d, expected %0d (mirror)",
                             N-1-i, captured_coeffs[N-1-i], expected_samples[i]);
                    err = err + 1;
                end
            end
            check("Test 1b: poly[8..15] is Hermitian mirror", err == 0);
        end

        $display("  Samples: %0d %0d %0d %0d %0d %0d %0d %0d",
                 expected_samples[0], expected_samples[1], expected_samples[2], expected_samples[3],
                 expected_samples[4], expected_samples[5], expected_samples[6], expected_samples[7]);
        $display("  Coeffs:  %0d %0d %0d %0d %0d %0d %0d %0d | %0d %0d %0d %0d %0d %0d %0d %0d",
                 captured_coeffs[0], captured_coeffs[1], captured_coeffs[2], captured_coeffs[3],
                 captured_coeffs[4], captured_coeffs[5], captured_coeffs[6], captured_coeffs[7],
                 captured_coeffs[8], captured_coeffs[9], captured_coeffs[10], captured_coeffs[11],
                 captured_coeffs[12], captured_coeffs[13], captured_coeffs[14], captured_coeffs[15]);

        // ===================================================================
        $display("\n---- Test 2: Hermitian 对称验证 (poly[i] == poly[N-1-i]) ----");
        do_reset;

        // 使用不同的样本值
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            expected_samples[i] = (i * 13) % 128;
        end

        run_pack(expected_samples, captured_coeffs);

        // 验证 Hermitian 对称
        begin : verify_hermitian
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_coeffs[i] !== captured_coeffs[N-1-i]) begin
                    $display("  [err] poly[%0d]=%0d != poly[%0d]=%0d",
                             i, captured_coeffs[i], N-1-i, captured_coeffs[N-1-i]);
                    err = err + 1;
                end
            end
            check("Test 2: Hermitian symmetry (poly[i]==poly[N-1-i])", err == 0);
        end

        $display("  Samples: %0d %0d %0d %0d %0d %0d %0d %0d",
                 expected_samples[0], expected_samples[1], expected_samples[2], expected_samples[3],
                 expected_samples[4], expected_samples[5], expected_samples[6], expected_samples[7]);
        $display("  Coeffs:  %0d %0d %0d %0d %0d %0d %0d %0d | %0d %0d %0d %0d %0d %0d %0d %0d",
                 captured_coeffs[0], captured_coeffs[1], captured_coeffs[2], captured_coeffs[3],
                 captured_coeffs[4], captured_coeffs[5], captured_coeffs[6], captured_coeffs[7],
                 captured_coeffs[8], captured_coeffs[9], captured_coeffs[10], captured_coeffs[11],
                 captured_coeffs[12], captured_coeffs[13], captured_coeffs[14], captured_coeffs[15]);

        // ===================================================================
        $display("\n---- Test 3: 边界值测试 (samples = 0, 127) ----");
        do_reset;

        // 全零
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            expected_samples[i] = '0;
        end
        run_pack(expected_samples, captured_coeffs);

        begin : verify_zero
            integer err = 0;
            for (int i = 0; i < N; i = i + 1) begin
                if (captured_coeffs[i] !== '0) begin
                    err = err + 1;
                end
            end
            check("Test 3a: all-zero samples -> all-zero coeffs", err == 0);
        end

        // 全 127
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            expected_samples[i] = 7'd127;
        end
        run_pack(expected_samples, captured_coeffs);

        begin : verify_max
            integer err = 0;
            for (int i = 0; i < N; i = i + 1) begin
                if (captured_coeffs[i] !== 7'd127) begin
                    err = err + 1;
                end
            end
            check("Test 3b: all-127 samples -> all-127 coeffs", err == 0);
        end

        // ===================================================================
        $display("\n---- Test 4: 混合样本值测试 ----");
        do_reset;

        // 混合值：偶数位=0, 奇数位=127
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            if (i % 2 == 0)
                expected_samples[i] = 7'd0;
            else
                expected_samples[i] = 7'd127;
        end

        run_pack(expected_samples, captured_coeffs);

        // 验证交替模式
        begin : verify_alternate
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                // 正序
                if (captured_coeffs[i] !== expected_samples[i]) begin
                    err = err + 1;
                end
                // 逆序
                if (captured_coeffs[N-1-i] !== expected_samples[i]) begin
                    err = err + 1;
                end
            end
            check("Test 4: alternating pattern preserved", err == 0);
        end

        $display("  Samples: %0d %0d %0d %0d %0d %0d %0d %0d",
                 expected_samples[0], expected_samples[1], expected_samples[2], expected_samples[3],
                 expected_samples[4], expected_samples[5], expected_samples[6], expected_samples[7]);
        $display("  Coeffs:  %0d %0d %0d %0d %0d %0d %0d %0d | %0d %0d %0d %0d %0d %0d %0d %0d",
                 captured_coeffs[0], captured_coeffs[1], captured_coeffs[2], captured_coeffs[3],
                 captured_coeffs[4], captured_coeffs[5], captured_coeffs[6], captured_coeffs[7],
                 captured_coeffs[8], captured_coeffs[9], captured_coeffs[10], captured_coeffs[11],
                 captured_coeffs[12], captured_coeffs[13], captured_coeffs[14], captured_coeffs[15]);

        // ===================================================================
        $display("\n==== SUMMARY ====");
        $display("PASS: %0d  FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL PASS");
        end else begin
            $display("SOME FAILED");
        end
        $finish;
    end

    // 全局超时保护
    initial begin
        #500000;
        $display("GLOBAL TIMEOUT!");
        $finish;
    end

endmodule
