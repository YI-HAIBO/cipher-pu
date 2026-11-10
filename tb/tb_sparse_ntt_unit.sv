// =============================================================================
// tb_sparse_ntt_unit.sv — M4-b 稀疏 NTT 单元 TB（含块级稀疏测试）
//
// 测试项（玩具配置 N=16, B=2, Q=113）：
//   元素级（block_sparse_en=0）：
//   1. sparsity_en=0: 直通模式
//   2. sparsity_en=1, threshold=1: 几乎全跳过
//   3. sparsity_en=1, threshold=10: 部分跳过
//   4. sparsity_en=1, threshold=5: 低阈值
//   5. 统计重置
//
//   块级（block_sparse_en=1）：
//   6. 基本块级稀疏 (threshold=5)
//   7. 全部跳过
//   8. 全部保留
//   9. 对称绝对值
//  10. 块级统计
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_sparse_ntt_unit;

    // =========================================================================
    // 参数（玩具配置）
    // =========================================================================
    localparam int LOG_N   = 4;
    localparam int N       = 1 << LOG_N;   // 16
    localparam int Q_WIDTH = 7;
    localparam int Q_VALUE = 113;
    localparam int N_INV   = 106;
    localparam int B       = 2;

    // =========================================================================
    // 信号
    // =========================================================================
    logic               clk;
    logic               rst_n;

    // 档位配置
    logic [Q_WIDTH-1:0] sparsity_threshold;
    logic               sparsity_en;
    logic               block_sparse_en;

    // 输入
    logic [Q_WIDTH-1:0] s_tdata;
    logic               s_valid;
    logic               s_ready;
    logic               s_last;

    // 输出
    logic [Q_WIDTH-1:0] m_tdata;
    logic               m_valid;
    logic               m_last;
    logic               m_ready;

    // 控制
    logic               op_mode;
    logic               start;
    logic               busy;
    logic               done;
    logic               error;

    // 统计
    logic [15:0]        skip_count;
    logic [15:0]        total_count;

    // Twiddle 表（玩具配置）
    logic [Q_WIDTH-1:0] omega_table [0:N/2-1];
    logic [Q_WIDTH-1:0] omega_inv_table [0:N/2-1];

    // =========================================================================
    // DUT
    // =========================================================================
    sparse_ntt_unit #(
        .LOG_N       (LOG_N),
        .N           (N),
        .Q_WIDTH     (Q_WIDTH),
        .Q_VALUE     (Q_VALUE),
        .N_INV       (N_INV),
        .USE_FASTRED (0),
        .B           (B)
    ) u_dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .sparsity_threshold (sparsity_threshold),
        .sparsity_en        (sparsity_en),
        .block_sparse_en    (block_sparse_en),
        .s_tdata            (s_tdata),
        .s_valid            (s_valid),
        .s_ready            (s_ready),
        .s_last             (s_last),
        .m_tdata            (m_tdata),
        .m_valid            (m_valid),
        .m_last             (m_last),
        .m_ready            (m_ready),
        .op_mode            (op_mode),
        .start              (start),
        .busy               (busy),
        .done               (done),
        .error              (error),
        .skip_count         (skip_count),
        .total_count        (total_count),
        .omega_table        (omega_table),
        .omega_inv_table    (omega_inv_table)
    );

    // =========================================================================
    // 时钟
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // 测试计数器
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    // =========================================================================
    // 辅助任务
    // =========================================================================
    task automatic check(
        input  string         name,
        input  logic          actual,
        input  logic          expected
    );
        if (actual === expected) begin
            $display("  [PASS] %s", name);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s: actual=%b expected=%b", name, actual, expected);
            fail_count = fail_count + 1;
        end
    endtask

    task automatic check_val(
        input  string         name,
        input  longint signed actual,
        input  longint signed expected
    );
        if (actual === expected) begin
            $display("  [PASS] %s: actual=%0d expected=%0d", name, actual, expected);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s: actual=%0d expected=%0d", name, actual, expected);
            fail_count = fail_count + 1;
        end
    endtask

    // 对称模绝对值
    function automatic logic [Q_WIDTH-1:0] sym_abs(input logic [Q_WIDTH-1:0] v);
        automatic logic [Q_WIDTH-1:0] neg;
        neg = Q_VALUE - v;
        sym_abs = (v <= neg) ? v : neg;
    endfunction

    // 发送一个系数（与原始 TB 一致，posedge 驱动）
    task automatic send_coeff(
        input logic [Q_WIDTH-1:0] data,
        input logic               last
    );
        s_tdata = data;
        s_valid = 1'b1;
        s_last  = last;
        @(posedge clk);
        #1;
        s_valid = 1'b0;
        s_last  = 1'b0;
    endtask

    // 发送一个系数（块级模式，negedge 驱动，等待 s_ready）
    task automatic send_coeff_block(
        input logic [Q_WIDTH-1:0] data,
        input logic               last
    );
        while (!s_ready) @(negedge clk);
        @(negedge clk);
        s_valid = 1'b1;
        s_tdata = data;
        s_last  = last;
        @(posedge clk);
        @(negedge clk);
        s_valid = 1'b0;
        s_last  = 1'b0;
    endtask

    // 等待 NTT 完成
    task automatic wait_done;
        automatic integer timeout;
        timeout = 0;
        wait (!busy);
    endtask

    // =========================================================================
    // 初始化
    // =========================================================================
    initial begin
        // 生成 omega_table（玩具配置）
        // omega = 40 (2^4 阶根 mod 113)
        for (int i = 0; i < N/2; i++) begin
            omega_table[i] = 0;
            omega_inv_table[i] = 0;
        end
        omega_table[0] = 7'd1;
        omega_table[1] = 7'd40;
        omega_table[2] = 7'd68;   // 40^2 mod 113 = 68
        omega_table[3] = 7'd61;   // 40^3 mod 113 = 61
        omega_inv_table[0] = 7'd1;
        omega_inv_table[1] = 7'd65;  // 40^-1 mod 113 = 65
        omega_inv_table[2] = 7'd78;  // 65^2 mod 113 = 78
        omega_inv_table[3] = 7'd34;  // 65^3 mod 113 = 34

        // 初始化信号
        rst_n = 1'b0;
        start = 1'b0;
        op_mode = 1'b0;
        s_valid = 1'b0;
        s_last  = 1'b0;
        m_ready = 1'b1;
        sparsity_en = 1'b0;
        block_sparse_en = 1'b0;
        sparsity_threshold = 7'd0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("=============================================================");
        $display("M4-b sparse_ntt_unit TB (N=%0d, B=%0d, Q=%0d)", N, B, Q_VALUE);
        $display("=============================================================");

        // -----------------------------------------------------------------
        // 元素级测试（block_sparse_en=0）
        // -----------------------------------------------------------------

        // Test 1: sparsity_en=0 (直通)
        $display("\n--- Test 1: sparsity_en=0 (bypass) ---");
        sparsity_en = 1'b0;
        block_sparse_en = 1'b0;
        sparsity_threshold = 7'd50;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        for (int i = 0; i < N; i++) begin
            send_coeff(7'd0, (i == N-1));
        end
        wait_done;

        check("error=0 (bypass zero)", error, 1'b0);
        check_val("skip_count=0 (bypass)", longint'(skip_count), longint'(0));
        check_val("total_count=%0d (bypass)", longint'(total_count), longint'(N));

        // Test 2: sparsity_en=1, threshold=1 (几乎全跳过)
        $display("\n--- Test 2: sparsity_en=1, threshold=1 ---");
        sparsity_en = 1'b1;
        block_sparse_en = 1'b0;
        sparsity_threshold = 7'd1;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        for (int i = 0; i < N; i++) begin
            send_coeff(7'(i), (i == N-1));
        end
        wait_done;

        check("error=0 (sparse)", error, 1'b0);
        check_val("skip_count >= 1", (longint'(skip_count) >= 1), longint'(1));

        // Test 3: sparsity_en=1, threshold=10 (部分跳过)
        $display("\n--- Test 3: sparsity_en=1, threshold=10 ---");
        sparsity_threshold = 7'd10;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        begin
            logic [Q_WIDTH-1:0] test_data [0:N-1];
            test_data[0] = 7'd0;    // skip (abs=0 < 10)
            test_data[1] = 7'd5;    // skip (abs=5 < 10)
            test_data[2] = 7'd10;   // keep (abs=10 >= 10)
            test_data[3] = 7'd15;   // keep (abs=15 >= 10)
            test_data[4] = 7'd50;   // keep
            test_data[5] = 7'd100;  // keep (abs=13 < 10? no, 100 < 103)
            test_data[6] = 7'd103;  // keep (abs=10 >= 10)
            test_data[7] = 7'd104;  // skip (abs=9 < 10)
            for (int i = 8; i < N; i++) test_data[i] = 7'd0;  // skip
            for (int i = 0; i < N; i++) begin
                send_coeff(test_data[i], (i == N-1));
            end
        end
        wait_done;

        check("error=0 (partial)", error, 1'b0);
        check_val("skip_count=11 (partial)", longint'(skip_count), longint'(11));
        check_val("total_count=16 (partial)", longint'(total_count), longint'(16));

        // Test 4: sparsity_en=1, threshold=5 (低阈值)
        $display("\n--- Test 4: sparsity_en=1, threshold=5 ---");
        sparsity_threshold = 7'd5;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        for (int i = 0; i < N; i++) begin
            send_coeff(7'(i * 7 % 113), (i == N-1));
        end
        wait_done;

        check("error=0 (low threshold)", error, 1'b0);
        check_val("skip_count=1 (low threshold)", longint'(skip_count), longint'(1));

        // Test 5: 统计重置
        $display("\n--- Test 5: Statistics reset on start ---");
        sparsity_en = 1'b1;
        block_sparse_en = 1'b0;
        sparsity_threshold = 7'd50;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        for (int i = 0; i < N; i++) begin
            send_coeff(7'd0, (i == N-1));
        end
        wait_done;
        check_val("count before reset > 0", (longint'(total_count) > 0), longint'(1));

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        check_val("total_count reset on start", (longint'(total_count) == 0), longint'(1));

        // -----------------------------------------------------------------
        // 块级测试（block_sparse_en=1）
        // -----------------------------------------------------------------

        // Test 6: 基本块级稀疏 (threshold=5, B=2)
        $display("\n--- Test 6: Block-level basic (threshold=5) ---");
        sparsity_en = 1'b1;
        block_sparse_en = 1'b1;
        sparsity_threshold = 7'd5;

        // 数据：{3,4, 50,60, 1,2, 80,90, 0,0, 0,0, 0,0, 0,0}
        // 块0: (3,4) max_abs=4 < 5 → skip
        // 块1: (50,60) max_abs=60 >= 5 → keep
        // 块2: (1,2) max_abs=2 < 5 → skip
        // 块3: (80,90) max_abs=90 >= 5 → keep
        // 块4-7: (0,0) max_abs=0 < 5 → skip
        // 预期 skip_count = 5 (块0,2,4,5,6,7 → 实际6块跳过)
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        begin
            logic [Q_WIDTH-1:0] td [0:N-1];
            td = '{3,4, 50,60, 1,2, 80,90, 0,0, 0,0, 0,0, 0,0};
            for (int i = 0; i < N; i++) begin
                send_coeff_block(td[i], (i == N-1));
            end
        end
        wait_done;

        check("error=0 (block basic)", error, 1'b0);
        // 块0 skip, 块1 keep, 块2 skip, 块3 keep, 块4-7 skip = 6 blocks skip
        check_val("skip_count=6 (block basic)", longint'(skip_count), longint'(6));
        check_val("total_count=8 (block basic)", longint'(total_count), longint'(8));

        // Test 7: 全部跳过 (threshold=100)
        $display("\n--- Test 7: Block-level all-skip (threshold=100) ---");
        sparsity_threshold = 7'd100;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        for (int i = 0; i < N; i++) begin
            send_coeff_block(7'(i+1), (i == N-1));  // 1-16, 全部 max_abs < 100
        end
        wait_done;

        check("error=0 (block all-skip)", error, 1'b0);
        check_val("skip_count=8 (block all-skip)", longint'(skip_count), longint'(8));
        check_val("total_count=8 (block all-skip)", longint'(total_count), longint'(8));

        // Test 8: 全部保留 (threshold=1, 数据均非零)
        $display("\n--- Test 8: Block-level all-keep (threshold=1) ---");
        sparsity_threshold = 7'd1;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        for (int i = 0; i < N; i++) begin
            send_coeff_block(7'(10 + i), (i == N-1));  // 10-25, 全部 max_abs >= 1
        end
        wait_done;

        check("error=0 (block all-keep)", error, 1'b0);
        check_val("skip_count=0 (block all-keep)", longint'(skip_count), longint'(0));
        check_val("total_count=8 (block all-keep)", longint'(total_count), longint'(8));

        // Test 9: 对称绝对值 (threshold=5)
        $display("\n--- Test 9: Block-level symmetric-abs (threshold=5) ---");
        sparsity_threshold = 7'd5;

        // 数据：{110,111, 100,105, 0,1, 50,60, 2,3, 4,5, 6,7, 8,9}
        // 块0: (110,111) abs=(3,2) max=3 < 5 → skip
        // 块1: (100,105) abs=(13,8) max=13 >= 5 → keep
        // 块2: (0,1) max=1 < 5 → skip
        // 块3: (50,60) max=60 >= 5 → keep
        // 块4: (2,3) max=3 < 5 → skip
        // 块5: (4,5) max=5 >= 5 → keep
        // 块6: (6,7) max=7 >= 5 → keep
        // 块7: (8,9) max=9 >= 5 → keep
        // 预期 skip_count = 3
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        begin
            logic [Q_WIDTH-1:0] td [0:N-1];
            td = '{110,111, 100,105, 0,1, 50,60, 2,3, 4,5, 6,7, 8,9};
            for (int i = 0; i < N; i++) begin
                send_coeff_block(td[i], (i == N-1));
            end
        end
        wait_done;

        check("error=0 (block sym-abs)", error, 1'b0);
        check_val("skip_count=3 (block sym-abs)", longint'(skip_count), longint'(3));
        check_val("total_count=8 (block sym-abs)", longint'(total_count), longint'(8));

        // Test 10: 块级统计重置
        $display("\n--- Test 10: Block-level statistics reset ---");
        sparsity_threshold = 7'd50;

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        for (int i = 0; i < N; i++) begin
            send_coeff_block(7'd0, (i == N-1));
        end
        wait_done;
        check_val("block count before reset > 0", (longint'(total_count) > 0), longint'(1));

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        check_val("block total_count reset on start", (longint'(total_count) == 0), longint'(1));

        // -----------------------------------------------------------------
        // 结果汇总
        // -----------------------------------------------------------------
        $display("\n=============================================================");
        $display("Results: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0) $display("ALL PASS");
        else $display("FAIL (%0d failures)", fail_count);
        $display("=============================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #100000;
        $display("TIMEOUT!");
        $finish;
    end

endmodule
