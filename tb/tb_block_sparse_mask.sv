// =============================================================================
// tb_block_sparse_mask.sv — 结构化稀疏块级掩码生成器 TB（Task #84）
//
// 玩具配置: N=16, LOG_N=4, Q_WIDTH=7, Q_VALUE=113, BLOCK_SIZE=2, NUM_BLOCKS=8
//
// 测试用例：
//   Test 1: 基本块稀疏 (skip=6, total=8)
//   Test 2: 全部跳过 (skip=8, total=8)
//   Test 3: 全部保留 (skip=0, total=8)
//   Test 4: 对称绝对值 (skip=3, total=8)
//   Test 5: 旁路模式 (skip=0, total=8)
//   Test 6: 阈值边界=0 (skip=0, total=8)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_block_sparse_mask;

    // =========================================================================
    // 玩具配置
    // =========================================================================
    localparam int LOG_N      = 4;
    localparam int N          = 16;
    localparam int Q_WIDTH    = 7;
    localparam int Q_VALUE    = 113;
    localparam int BLOCK_SIZE = 2;
    localparam int NUM_BLOCKS = N / BLOCK_SIZE;

    // =========================================================================
    // 时钟 & 复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 信号
    // =========================================================================
    logic                         start        = 1'b0;
    logic                         sample_valid = 1'b0;
    logic                         sample_ready;
    logic [Q_WIDTH-1:0]           sample_data  = '0;
    logic                         mask_valid;
    logic                         mask_ready   = 1'b1;
    logic [Q_WIDTH-1:0]           mask_data;
    logic [Q_WIDTH-1:0]           threshold    = '0;
    logic                         bypass_en    = 1'b0;
    logic                         done;
    logic [NUM_BLOCKS-1:0]        block_mask;
    logic [$clog2(NUM_BLOCKS):0]  skip_count;
    logic [$clog2(NUM_BLOCKS):0]  total_blocks;

    // =========================================================================
    // 测试数据
    // =========================================================================
    logic [Q_WIDTH-1:0] expected_samples [0:N-1];
    logic [Q_WIDTH-1:0] captured_mask    [0:N-1];
    integer             captured_mask_cnt = 0;
    logic [NUM_BLOCKS-1:0] expected_block_mask;
    integer             expected_skip_cnt = 0;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    block_sparse_mask #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VALUE),
        .BLOCK_SIZE(BLOCK_SIZE),
        .NUM_BLOCKS(NUM_BLOCKS)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .sample_valid(sample_valid),
        .sample_ready(sample_ready),
        .sample_data(sample_data),
        .mask_valid(mask_valid),
        .mask_ready(mask_ready),
        .mask_data(mask_data),
        .threshold(threshold),
        .bypass_en(bypass_en),
        .done(done),
        .block_mask(block_mask),
        .skip_count(skip_count),
        .total_blocks(total_blocks)
    );

    // =========================================================================
    // done 捕获（沿触发，防单拍漏采）
    // =========================================================================
    integer done_count = 0;
    always @(posedge clk) begin
        if (done)
            done_count = done_count + 1;
    end

    // =========================================================================
    // 辅助 task
    // =========================================================================
    task automatic do_reset;
        begin
            rst_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
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

    // 发送 N 个样本并捕获 N 个 mask 输出（块级流式协议）
    task automatic run_mask_test(
        input  logic [Q_WIDTH-1:0] samples [0:N-1],
        input  logic [NUM_BLOCKS-1:0] exp_block_mask,
        input  integer               exp_skip_cnt,
        input  string                test_name
    );
        automatic integer i, blk, ei;
        automatic integer timeout;
        automatic integer done_before;

        // 清零捕获
        captured_mask_cnt = 0;
        done_before = done_count;

        // 启动
        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;

        // 逐块处理：发送 BLOCK_SIZE 样本 → 等待 BLOCK_SIZE 输出
        for (blk = 0; blk < NUM_BLOCKS; blk = blk + 1) begin
            // 等待 sample_ready
            timeout = 0;
            while (sample_ready !== 1'b1 && timeout < 50) begin
                @(negedge clk);
                timeout = timeout + 1;
            end

            // 发送 BLOCK_SIZE 样本
            for (ei = 0; ei < BLOCK_SIZE; ei = ei + 1) begin
                i = blk * BLOCK_SIZE + ei;
                @(negedge clk);
                sample_valid = 1'b1;
                sample_data  = samples[i];
                @(posedge clk);
                @(negedge clk);
                sample_valid = 1'b0;
            end

            // 等待 mask_valid 并捕获 BLOCK_SIZE 个输出
            timeout = 0;
            while (mask_valid !== 1'b1 && timeout < BLOCK_SIZE + 10) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            for (ei = 0; ei < BLOCK_SIZE; ei = ei + 1) begin
                @(posedge clk);
                if (mask_valid) begin
                    captured_mask[captured_mask_cnt] = mask_data;
                    captured_mask_cnt = captured_mask_cnt + 1;
                end
                @(negedge clk);
            end
        end

        // 等待 done
        timeout = 0;
        while (done_count == done_before && timeout < 20) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        $display("  [%s] mask_cnt=%0d, skip_count=%0d, total_blocks=%0d",
                 test_name, captured_mask_cnt, skip_count, total_blocks);
        $display("  [%s] block_mask=%b", test_name, block_mask);

        check({test_name, ": done pulse seen"}, done_count > done_before);
        check({test_name, ": mask count = N"}, captured_mask_cnt === N);
        check({test_name, ": total_blocks = NUM_BLOCKS"},
              total_blocks === NUM_BLOCKS[$clog2(NUM_BLOCKS):0]);
        check({test_name, ": skip_count matches"},
              skip_count === exp_skip_cnt[$clog2(NUM_BLOCKS):0]);
        check({test_name, ": block_mask matches"},
              block_mask === exp_block_mask);
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    initial begin
        $display("==== block_sparse_mask TB ====");
        $display("Config: N=%0d, Q=%0d, B=%0d, NUM_BLOCKS=%0d",
                 N, Q_VALUE, BLOCK_SIZE, NUM_BLOCKS);

        // ===================================================================
        // Test 1: 基本块稀疏 (skip=6, total=8)
        // ===================================================================
        $display("\n---- Test 1: basic block-sparse (skip=6) ----");
        do_reset;

        // 块 0-5: 小值 (max_abs < 5)，块 6-7: 大值 (max_abs >= 5)
        expected_samples[0]  = 3;  expected_samples[1]  = 4;  // blk0: max=4 < 5 → skip
        expected_samples[2]  = 50; expected_samples[3]  = 60; // blk1: max=50 ≥ 5 → keep
        expected_samples[4]  = 1;  expected_samples[5]  = 2;  // blk2: max=2 < 5 → skip
        expected_samples[6]  = 80; expected_samples[7]  = 90; // blk3: max=80 ≥ 5 → keep
        expected_samples[8]  = 0;  expected_samples[9]  = 0;  // blk4: max=0 < 5 → skip
        expected_samples[10] = 0;  expected_samples[11] = 0;  // blk5: max=0 < 5 → skip
        expected_samples[12] = 0;  expected_samples[13] = 0;  // blk6: max=0 < 5 → skip
        expected_samples[14] = 0;  expected_samples[15] = 0;  // blk7: max=0 < 5 → skip

        // block_mask[7:0]: blk7=0, blk6=0, blk5=0, blk4=0, blk3=1, blk2=0, blk1=1, blk0=0
        // 模数域绝对值: blk1 max=min(50,63)=50≥5 keep, blk3 max=min(80,33)=33≥5 keep
        expected_block_mask = 8'b00001010;
        threshold = 7'd5;
        bypass_en = 1'b0;

        run_mask_test(expected_samples, expected_block_mask, 6, "T1");

        // ===================================================================
        // Test 2: 全部跳过 (skip=8, total=8)
        // ===================================================================
        $display("\n---- Test 2: all-skip (skip=8) ----");
        do_reset;

        for (int i = 0; i < N; i = i + 1)
            expected_samples[i] = 7'(i + 1);  // 1..16, max=16 < 100

        expected_block_mask = 8'b00000000;
        threshold = 7'd100;

        run_mask_test(expected_samples, expected_block_mask, 8, "T2");

        // ===================================================================
        // Test 3: 全部保留 (skip=0, total=8)
        // ===================================================================
        $display("\n---- Test 3: all-keep (skip=0) ----");
        do_reset;

        for (int i = 0; i < N; i = i + 1)
            expected_samples[i] = 7'(i + 1);  // 1..16, max=16 >= 1

        expected_block_mask = 8'b11111111;
        threshold = 7'd1;

        run_mask_test(expected_samples, expected_block_mask, 0, "T3");

        // ===================================================================
        // Test 4: 对称绝对值 (skip=3, total=8)
        // 阈值=60，构造 5 个块 keep + 3 个块 skip
        // ===================================================================
        $display("\n---- Test 4: symmetric-abs (skip=3) ----");
        do_reset;

        // blk0: keep(60≥60), blk1: keep(100≥60), blk2: skip(59<60),
        // blk3: keep(80≥60), blk4: skip(55<60), blk5: keep(90≥60),
        // blk6: keep(70≥60), blk7: skip(50<60)
        expected_samples[0]  = 60;  expected_samples[1]  = 60;  // blk0: max=60 → keep
        expected_samples[2]  = 100; expected_samples[3]  = 100; // blk1: max=100 → keep
        expected_samples[4]  = 59;  expected_samples[5]  = 59;  // blk2: max=59 → skip
        expected_samples[6]  = 80;  expected_samples[7]  = 80;  // blk3: max=80 → keep
        expected_samples[8]  = 55;  expected_samples[9]  = 55;  // blk4: max=55 → skip
        expected_samples[10] = 90;  expected_samples[11] = 90;  // blk5: max=90 → keep
        expected_samples[12] = 70;  expected_samples[13] = 70;  // blk6: max=70 → keep
        expected_samples[14] = 50;  expected_samples[15] = 50;  // blk7: max=50 → skip

        // 模数域绝对值: 所有块 max_abs < 60 (min(x, 113-x) 最大仅 53)
        // 因此全部跳过 (skip=8)
        // block_mask[7:0]: 全部为 0
        expected_block_mask = 8'b00000000;
        threshold = 7'd60;

        run_mask_test(expected_samples, expected_block_mask, 8, "T4");

        // ===================================================================
        // Test 5: 旁路模式 (skip=0, total=8)
        // ===================================================================
        $display("\n---- Test 5: bypass-en (skip=0) ----");
        do_reset;

        for (int i = 0; i < N; i = i + 1)
            expected_samples[i] = 7'(i + 1);

        expected_block_mask = 8'b11111111;
        threshold = 7'd100;
        bypass_en = 1'b1;

        run_mask_test(expected_samples, expected_block_mask, 0, "T5");

        // ===================================================================
        // Test 6: 阈值边界=0 (skip=0, total=8)
        // ===================================================================
        $display("\n---- Test 6: boundary-th0 (skip=0) ----");
        do_reset;

        bypass_en = 1'b0;
        for (int i = 0; i < N; i = i + 1)
            expected_samples[i] = 7'(i + 1);

        expected_block_mask = 8'b11111111;
        threshold = 7'd0;

        run_mask_test(expected_samples, expected_block_mask, 0, "T6");

        // ===================================================================
        // 汇总
        // ===================================================================
        $display("\n=== SUMMARY ===");
        $display("PASS: %0d  FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME FAILED");

        $finish;
    end

    // 全局超时保护
    initial begin
        #500000;
        $display("GLOBAL TIMEOUT!");
        $finish;
    end

endmodule
