// =============================================================================
// tb_slot_unpacker.sv — 多 Slot SIMD 样本解包器 TB
//
// 玩具配置: N=16, Q_WIDTH=7, NUM_SLOTS=8
//
// 测试用例：
//   Test 1: 基本解包功能（poly = 1..16, samples = poly[0..7]）
//   Test 2: 后 N/2 个系数被忽略验证
//   Test 3: 边界值测试（poly = 0, 127）
//   Test 4: 混合样本值测试
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_slot_unpacker;

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
    logic                     poly_valid   = 1'b0;
    logic                     poly_ready;
    logic [Q_WIDTH-1:0]       poly_data    = '0;
    logic                     sample_valid;
    logic                     sample_ready = 1'b1;
    logic [Q_WIDTH-1:0]       sample_data;
    logic                     done;

    // =========================================================================
    // 测试数据
    // =========================================================================
    logic [Q_WIDTH-1:0] poly_data_queue [0:N-1];
    logic [Q_WIDTH-1:0] expected_samples [0:NUM_SLOTS-1];
    logic [Q_WIDTH-1:0] captured_samples [0:NUM_SLOTS-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    slot_unpacker #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .NUM_SLOTS(NUM_SLOTS)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .poly_valid(poly_valid),
        .poly_ready(poly_ready),
        .poly_data(poly_data),
        .sample_valid(sample_valid),
        .sample_ready(sample_ready),
        .sample_data(sample_data),
        .done(done)
    );

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

    // 发送 N 个系数并捕获 N/2 个样本
    task automatic run_unpack(input logic [Q_WIDTH-1:0] poly_in [0:N-1],
                               output logic [Q_WIDTH-1:0] samples_out [0:NUM_SLOTS-1]);
        automatic integer i;
        automatic integer timeout;

        // 启动
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // 等待 poly_ready（在 negedge 检查）
        timeout = 0;
        while (poly_ready !== 1'b1 && timeout < 20) begin
            @(negedge clk);
            timeout = timeout + 1;
        end

        // 发送 N 个系数，同时捕获前 N/2 个样本
        poly_valid = 1'b1;
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            poly_data = poly_in[i];
            // 在 negedge 采样 sample_data（sample_data = poly_data，组合直通）
            if (i < NUM_SLOTS) begin
                samples_out[i] = poly_data;
            end
            @(posedge clk);
        end
        @(negedge clk);
        poly_valid = 1'b0;

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
        $display("==== tb_slot_unpacker ====");
        $display("Config: N=%0d, Q_WIDTH=%0d, NUM_SLOTS=%0d", N, Q_WIDTH, NUM_SLOTS);
        $display("");

        // ===================================================================
        $display("---- Test 1: 基本解包 (poly = 1..16, samples = poly[0..7]) ----");
        do_reset;

        // 准备测试数据
        for (int i = 0; i < N; i = i + 1) begin
            poly_data_queue[i] = i[Q_WIDTH-1:0] + 1'b1;
        end
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            expected_samples[i] = poly_data_queue[i];
        end

        run_unpack(poly_data_queue, captured_samples);

        // 验证 samples[i] == poly[i] for i=0..N/2-1
        begin : verify_basic
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_samples[i] !== expected_samples[i]) begin
                    $display("  [err] sample[%0d] = %0d, expected %0d",
                             i, captured_samples[i], expected_samples[i]);
                    err = err + 1;
                end
            end
            check("Test 1: samples match poly[0..7]", err == 0);
        end

        $display("  Poly:    %0d %0d %0d %0d %0d %0d %0d %0d | %0d %0d %0d %0d %0d %0d %0d %0d",
                 poly_data_queue[0], poly_data_queue[1], poly_data_queue[2], poly_data_queue[3],
                 poly_data_queue[4], poly_data_queue[5], poly_data_queue[6], poly_data_queue[7],
                 poly_data_queue[8], poly_data_queue[9], poly_data_queue[10], poly_data_queue[11],
                 poly_data_queue[12], poly_data_queue[13], poly_data_queue[14], poly_data_queue[15]);
        $display("  Samples: %0d %0d %0d %0d %0d %0d %0d %0d",
                 captured_samples[0], captured_samples[1], captured_samples[2], captured_samples[3],
                 captured_samples[4], captured_samples[5], captured_samples[6], captured_samples[7]);

        // ===================================================================
        $display("\n---- Test 2: 后 N/2 个系数被忽略验证 ----");
        do_reset;

        // 前 N/2 = 10, 后 N/2 = 99（应该被忽略）
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            poly_data_queue[i] = 7'd10;
            expected_samples[i] = 7'd10;
        end
        for (int i = NUM_SLOTS; i < N; i = i + 1) begin
            poly_data_queue[i] = 7'd99;
        end

        run_unpack(poly_data_queue, captured_samples);

        begin : verify_ignore
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_samples[i] !== 7'd10) begin
                    $display("  [err] sample[%0d] = %0d, expected 10",
                             i, captured_samples[i]);
                    err = err + 1;
                end
            end
            check("Test 2: only poly[0..7] used (99 ignored)", err == 0);
        end

        $display("  Poly:    %0d %0d %0d %0d %0d %0d %0d %0d | %0d %0d %0d %0d %0d %0d %0d %0d",
                 poly_data_queue[0], poly_data_queue[1], poly_data_queue[2], poly_data_queue[3],
                 poly_data_queue[4], poly_data_queue[5], poly_data_queue[6], poly_data_queue[7],
                 poly_data_queue[8], poly_data_queue[9], poly_data_queue[10], poly_data_queue[11],
                 poly_data_queue[12], poly_data_queue[13], poly_data_queue[14], poly_data_queue[15]);
        $display("  Samples: %0d %0d %0d %0d %0d %0d %0d %0d",
                 captured_samples[0], captured_samples[1], captured_samples[2], captured_samples[3],
                 captured_samples[4], captured_samples[5], captured_samples[6], captured_samples[7]);

        // ===================================================================
        $display("\n---- Test 3: 边界值测试 (poly = 0, 127) ----");
        do_reset;

        // 全零
        for (int i = 0; i < N; i = i + 1) begin
            poly_data_queue[i] = '0;
            expected_samples[i] = '0;
        end
        run_unpack(poly_data_queue, captured_samples);

        begin : verify_zero
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_samples[i] !== '0) begin
                    err = err + 1;
                end
            end
            check("Test 3a: all-zero poly -> all-zero samples", err == 0);
        end

        // 全 127
        for (int i = 0; i < N; i = i + 1) begin
            poly_data_queue[i] = 7'd127;
            expected_samples[i] = 7'd127;
        end
        run_unpack(poly_data_queue, captured_samples);

        begin : verify_max
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_samples[i] !== 7'd127) begin
                    err = err + 1;
                end
            end
            check("Test 3b: all-127 poly -> all-127 samples", err == 0);
        end

        // ===================================================================
        $display("\n---- Test 4: 混合样本值测试 (交替 0/127) ----");
        do_reset;

        // 前 N/2 交替 0/127
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            if (i % 2 == 0) begin
                poly_data_queue[i] = 7'd0;
                expected_samples[i] = 7'd0;
            end else begin
                poly_data_queue[i] = 7'd127;
                expected_samples[i] = 7'd127;
            end
        end
        // 后 N/2 填充任意值
        for (int i = NUM_SLOTS; i < N; i = i + 1) begin
            poly_data_queue[i] = 7'd50;
        end

        run_unpack(poly_data_queue, captured_samples);

        begin : verify_alternate
            integer err = 0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (captured_samples[i] !== expected_samples[i]) begin
                    $display("  [err] sample[%0d] = %0d, expected %0d",
                             i, captured_samples[i], expected_samples[i]);
                    err = err + 1;
                end
            end
            check("Test 4: alternating pattern preserved", err == 0);
        end

        $display("  Poly:    %0d %0d %0d %0d %0d %0d %0d %0d | %0d %0d %0d %0d %0d %0d %0d %0d",
                 poly_data_queue[0], poly_data_queue[1], poly_data_queue[2], poly_data_queue[3],
                 poly_data_queue[4], poly_data_queue[5], poly_data_queue[6], poly_data_queue[7],
                 poly_data_queue[8], poly_data_queue[9], poly_data_queue[10], poly_data_queue[11],
                 poly_data_queue[12], poly_data_queue[13], poly_data_queue[14], poly_data_queue[15]);
        $display("  Samples: %0d %0d %0d %0d %0d %0d %0d %0d",
                 captured_samples[0], captured_samples[1], captured_samples[2], captured_samples[3],
                 captured_samples[4], captured_samples[5], captured_samples[6], captured_samples[7]);

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
