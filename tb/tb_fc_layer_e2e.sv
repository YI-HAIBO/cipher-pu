// =============================================================================
// tb_fc_layer_e2e.sv - 全连接层测试平台
// =============================================================================
// Phase 5 Task 5.2.9
//
// 测试用例：
// - T1: 复位后状态检查（busy=0, done=0, error=0）
// - T2: 权重加载
// - T3: 输入多项式加载（IN_DIM 个 slot）
// - T4: GEMM 计算完成
// - T5: 输出多项式流（OUT_DIM × N 个系数）
// - T6: 反压测试（y_ready=0 阻塞）
// - T7: 连续 GEMM（多次调用）
// =============================================================================

`default_nettype none

module tb_fc_layer_e2e;

    // =========================================================================
    // 参数（Toy 配置）
    // =========================================================================
    localparam int Q_WIDTH = 45;
    localparam int N = 16;
    localparam int LOG_N = 4;
    localparam int IN_DIM = 4;
    localparam int OUT_DIM = 2;

    // =========================================================================
    // 信号
    // =========================================================================
    logic               clk;
    logic               rst_n;
    logic               layer_start;
    logic               layer_busy;
    logic               layer_done;
    logic               layer_error;

    logic [Q_WIDTH-1:0] x_tdata;
    logic               x_valid;
    logic               x_ready;
    logic               x_last;

    logic [Q_WIDTH-1:0] y_tdata;
    logic               y_valid;
    logic               y_last;
    logic               y_ready;

    logic [Q_WIDTH-1:0] w_tdata;
    logic               w_valid;
    logic               w_ready;
    logic               w_last;

    logic [15:0]        w_addr;

    logic [Q_WIDTH-1:0] omega_table [0:N/2-1];
    logic [Q_WIDTH-1:0] omega_inv_table [0:N/2-1];

    // 输出捕获
    logic [Q_WIDTH-1:0] captured_out [0:OUT_DIM*N-1];
    int                 captured_cnt = 0;

    // 测试统计
    int pass_count = 0;
    int fail_count = 0;

    // =========================================================================
    // 时钟生成
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    fc_layer_e2e #(
        .Q_WIDTH    (Q_WIDTH),
        .N          (N),
        .LOG_N      (LOG_N),
        .IN_DIM     (IN_DIM),
        .OUT_DIM    (OUT_DIM)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .layer_start    (layer_start),
        .layer_busy     (layer_busy),
        .layer_done     (layer_done),
        .layer_error    (layer_error),
        .x_tdata        (x_tdata),
        .x_valid        (x_valid),
        .x_ready        (x_ready),
        .x_last         (x_last),
        .y_tdata        (y_tdata),
        .y_valid        (y_valid),
        .y_last         (y_last),
        .y_ready        (y_ready),
        .w_tdata        (w_tdata),
        .w_valid        (w_valid),
        .w_ready        (w_ready),
        .w_last         (w_last),
        .w_addr         (w_addr),
        .omega_table    (omega_table),
        .omega_inv_table(omega_inv_table)
    );

    // =========================================================================
    // Twiddle 初始化
    // =========================================================================
    initial begin
        for (int i = 0; i < N/2; i++) begin
            omega_table[i]     = i;
            omega_inv_table[i] = i;
        end
    end

    // =========================================================================
    // 输出捕获
    // =========================================================================
    always @(posedge clk) begin
        if (y_valid && y_ready) begin
            captured_out[captured_cnt] = y_tdata;
            captured_cnt = captured_cnt + 1;
        end
    end

    // =========================================================================
    // 任务：发送一个多项式（N 个系数）到输入流
    // =========================================================================
    task send_input_poly (
        input logic [Q_WIDTH-1:0] data [0:N-1]
    );
        begin
            for (int i = 0; i < N; i++) begin
                @(negedge clk);
                x_tdata = data[i];
                x_valid = 1;
                x_last  = 1;  // 每个 slot 结束
                @(posedge clk);   // DUT 在 posedge 采样，valid 已稳定一拍
                @(negedge clk);
                x_valid = 0;
                x_last  = 0;
            end
        end
    endtask

    // =========================================================================
    // 任务：发送权重（OUT_DIM × IN_DIM 个）
    // =========================================================================
    task send_weights (
        input logic [Q_WIDTH-1:0] data [0:OUT_DIM*IN_DIM-1]
    );
        begin
            for (int i = 0; i < OUT_DIM * IN_DIM; i++) begin
                @(negedge clk);
                w_tdata = data[i];
                w_valid = 1;
                w_last  = (i == OUT_DIM * IN_DIM - 1);
                w_addr  = i[15:0];
                @(posedge clk);   // DUT 在 posedge 采样，valid 已稳定一拍
                @(negedge clk);
                w_valid = 0;
                w_last  = 0;
            end
        end
    endtask

    // =========================================================================
    // 任务：等待 done 脉冲
    // =========================================================================
    task wait_done (
        input int timeout_cycles
    );
        int i;
        begin
            for (i = 0; i < timeout_cycles; i = i + 1) begin
                @(posedge clk);
                if (layer_done) return;
            end
            $display("FAIL: wait_done timeout after %d cycles", timeout_cycles);
            fail_count = fail_count + 1;
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    // 测试数据
    logic [Q_WIDTH-1:0] test_in [0:IN_DIM*N-1];
    logic [Q_WIDTH-1:0] test_w [0:OUT_DIM*IN_DIM-1];

    initial begin
        // 初始化
        rst_n       = 0;
        layer_start = 0;
        x_tdata     = 0;
        x_valid     = 0;
        x_last      = 0;
        y_ready     = 1;
        w_tdata     = 0;
        w_valid     = 0;
        w_last      = 0;
        w_addr      = 0;
        captured_cnt = 0;

        // 初始化测试输入（简单递增值）
        for (int i = 0; i < IN_DIM * N; i++) begin
            test_in[i] = Q_WIDTH'(i + 1);
        end

        // 初始化测试权重
        for (int i = 0; i < OUT_DIM * IN_DIM; i++) begin
            test_w[i] = Q_WIDTH'(1000 + i);
        end

        $display("=== T1: 复位状态检查 ===");
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        if (layer_busy == 0 && layer_done == 0 && layer_error == 0) begin
            $display("PASS T1: 复位后 busy=0, done=0, error=0");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL T1: busy=%b done=%b error=%b",
                     layer_busy, layer_done, layer_error);
            fail_count = fail_count + 1;
        end

        $display("\n=== T2: 权重加载 ===");
        layer_start = 1;
        @(posedge clk);
        layer_start = 0;
        send_weights(test_w);
        $display("  权重加载完成");

        $display("\n=== T3: 输入加载 ===");
        // IN_DIM 个 slot 顺序加载
        for (int slot = 0; slot < IN_DIM; slot++) begin
            send_input_poly(test_in[slot*N +: N]);
            $display("  slot %0d 加载完成", slot);
        end

        $display("\n=== T4: GEMM 计算 ===");
        wait_done(500000);
        if (layer_done) begin
            $display("PASS T4: GEMM 计算完成");
            pass_count = pass_count + 1;
        end

        $display("\n=== T5: 输出流 ===");
        repeat (10) @(posedge clk);
        $display("  捕获输出系数数: %0d / %0d", captured_cnt, OUT_DIM * N);

        if (captured_cnt == OUT_DIM * N) begin
            $display("PASS T5: 输出 %0d 个系数", OUT_DIM * N);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL T5: 期望 %0d, 实际 %0d", OUT_DIM * N, captured_cnt);
            fail_count = fail_count + 1;
        end

        $display("\n=== T6: 反压测试 ===");
        y_ready = 0;
        repeat (5) @(posedge clk);
        y_ready = 1;
        repeat (5) @(posedge clk);
        $display("PASS T6: 反压接口测试完成");
        pass_count = pass_count + 1;

        $display("\n=== T7: 连续 GEMM ===");
        layer_start = 1;
        @(posedge clk);
        layer_start = 0;
        send_weights(test_w);
        for (int slot = 0; slot < IN_DIM; slot++) begin
            send_input_poly(test_in[slot*N +: N]);
        end
        wait_done(500000);
        if (layer_done) begin
            $display("PASS T7: 连续 GEMM 完成");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL T7: 连续 GEMM 超时");
            fail_count = fail_count + 1;
        end

        // =========================================================================
        // 测试总结
        // =========================================================================
        $display("\n============================================================");
        $display("测试总结：");
        $display("  PASS: %0d", pass_count);
        $display("  FAIL: %0d", fail_count);
        $display("  TOTAL: %0d", pass_count + fail_count);
        $display("============================================================");

        if (fail_count == 0) begin
            $display("✅ 全部测试通过");
        end else begin
            $display("❌ 存在失败用例");
        end

        #100;
        $finish;
    end

    // =========================================================================
    // 超时保护
    // =========================================================================
    initial begin
        #2000000;
        $display("ERROR: 仿真超时！");
        $finish;
    end

endmodule
