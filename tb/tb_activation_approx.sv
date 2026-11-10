// =============================================================================
// tb_activation_approx.sv - 激活近似单元测试平台
// =============================================================================
// Phase 5 Task 5.1.4
//
// v3 修复（2026-10-19）：
// - 合并 wait_done + check_output 为单一 check_and_wait 任务
//   （原分离导致 S_DONE→S_IDLE 跳变后 m_valid 已为 0，输出检查超时）
// - 修正测试顺序：act_valid → 系数 → m_ready → 输入 → 检查输出+等待完成
// - 修正系数数量：12 个（TOTAL_COEFFS = NUM_SEGMENTS * COEFF_COUNT = 2 * 6）
// - 所有任务增加超时保护
// - VCD 转储改为 +DUMP_WAVE 控制
// =============================================================================

`default_nettype none

module tb_activation_approx;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam int Q_WIDTH = 45;
    localparam int N = 16;
    localparam int LOG_N = 4;
    localparam int POLY_ORDER = 5;
    localparam int NUM_SEGMENTS = 2;
    localparam int COEFF_WIDTH = 30;
    localparam int TOTAL_COEFFS = NUM_SEGMENTS * (POLY_ORDER + 1);

    // =========================================================================
    // 信号
    // =========================================================================
    logic               clk;
    logic               rst_n;
    logic [1:0]         act_type;
    logic               act_valid;
    logic               act_busy;
    logic               act_done;
    logic               act_error;

    logic [Q_WIDTH-1:0] s_tdata;
    logic               s_valid;
    logic               s_ready;
    logic               s_last;

    logic [Q_WIDTH-1:0] m_tdata;
    logic               m_valid;
    logic               m_last;
    logic               m_ready;

    logic [1:0]         coeff_sel;
    logic [COEFF_WIDTH-1:0] coeff_data;
    logic               coeff_valid;
    logic               coeff_ready;
    logic [7:0]         coeff_addr;

    int pass_count = 0;
    int fail_count = 0;

    // =========================================================================
    // 时钟生成
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    activation_approx #(
        .Q_WIDTH(Q_WIDTH),
        .N(N),
        .LOG_N(LOG_N),
        .POLY_ORDER(POLY_ORDER),
        .NUM_SEGMENTS(NUM_SEGMENTS),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .act_type(act_type),
        .act_valid(act_valid),
        .act_busy(act_busy),
        .act_done(act_done),
        .act_error(act_error),
        .s_tdata(s_tdata),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_last(s_last),
        .m_tdata(m_tdata),
        .m_valid(m_valid),
        .m_last(m_last),
        .m_ready(m_ready),
        .coeff_sel(coeff_sel),
        .coeff_data(coeff_data),
        .coeff_valid(coeff_valid),
        .coeff_ready(coeff_ready),
        .coeff_addr(coeff_addr)
    );

    // =========================================================================
    // 任务：加载系数（12 个）
    // =========================================================================
    task automatic load_coefficients(
        input logic [1:0] sel,
        input logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1]
    );
        begin
            coeff_sel = sel;
            for (int i = 0; i < TOTAL_COEFFS; i = i + 1) begin
                coeff_data = coeffs[i];
                coeff_valid = 1;
                coeff_addr = i[7:0];
                @(posedge clk);
                if (!coeff_ready) begin
                    $display("ERROR: coeff_ready not asserted at idx %0d (state=%0d)", i, dut.state);
                    fail_count = fail_count + 1;
                end
                @(negedge clk);
                coeff_valid = 0;
            end
            coeff_valid = 0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // 任务：发送多项式输入（N 个元素）
    // =========================================================================
    task automatic send_polynomial(
        input logic [Q_WIDTH-1:0] input_data [0:N-1]
    );
        begin
            for (int i = 0; i < N; i = i + 1) begin
                s_tdata = input_data[i];
                s_valid = 1;
                s_last = (i == N - 1);
                @(posedge clk);
                if (!s_ready) begin
                    $display("ERROR: s_ready not asserted at idx %0d (state=%0d)", i, dut.state);
                    fail_count = fail_count + 1;
                end
                @(negedge clk);
                s_valid = 0;
            end
            s_valid = 0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // 任务：检查输出并等待完成（合并 check_output + wait_done）
    //   关键修复：S_DONE→S_IDLE 只持续 1 拍，必须在 S_OUTPUT 期间接收输出，
    //   不能等 act_done 断言后再检查（那时 m_valid 已为 0）。
    // =========================================================================
    task automatic check_and_wait(
        input logic [Q_WIDTH-1:0] expected [0:N-1],
        input string test_name
    );
        int output_cnt = 0;
        int error_cnt = 0;
        int timeout = 0;
        begin
            output_cnt = 0;
            error_cnt = 0;

            // 在 S_OUTPUT 期间接收并检查输出
            while (output_cnt < N) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 3000) begin
                    $display("[%s] TIMEOUT waiting for output %0d (state=%0d)", test_name, output_cnt, dut.state);
                    fail_count = fail_count + 1;
                    return;
                end
                if (m_valid) begin
                    if (m_tdata !== expected[output_cnt]) begin
                        $display("[%s] ERROR at %0d: got %0d, expected %0d",
                                 test_name, output_cnt, m_tdata, expected[output_cnt]);
                        error_cnt = error_cnt + 1;
                        fail_count = fail_count + 1;
                    end
                    output_cnt = output_cnt + 1;
                    if (m_last && output_cnt >= N) begin
                        // 所有输出已接收
                        break;
                    end
                end
            end

            // 等待 act_done（输出已接收，确认完成脉冲）
            while (!act_done) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 3000) begin
                    $display("[%s] TIMEOUT waiting for act_done (state=%0d)", test_name, dut.state);
                    fail_count = fail_count + 1;
                    return;
                end
            end
            @(posedge clk);
            if (act_error) begin
                $display("[%s] ERROR: act_error asserted", test_name);
                fail_count = fail_count + 1;
            end

            if (error_cnt == 0) begin
                $display("[%s] PASS: %0d/%0d outputs correct", test_name, N, N);
                pass_count = pass_count + 1;
            end else begin
                $display("[%s] FAIL: %0d/%0d errors", test_name, error_cnt, N);
            end
        end
    endtask

    // =========================================================================
    // 测试用例
    // =========================================================================
    initial begin
        rst_n = 0;
        act_type = 2'b00;
        act_valid = 0;
        s_tdata = '0;
        s_valid = 0;
        s_last = 0;
        m_ready = 0;
        coeff_sel = 2'b00;
        coeff_data = '0;
        coeff_valid = 0;
        coeff_addr = 8'd0;

        // T1: 复位后状态检查
        $display("\n=== T1: 复位后状态检查 ===");
        repeat (10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        if (!act_busy && !act_done && !act_error) begin
            $display("T1: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("T1: FAIL");
            fail_count = fail_count + 1;
        end

        // T2: Sigmoid
        $display("\n=== T2: Sigmoid 近似测试 ===");
        begin : sigmoid_test
            logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1];
            logic [Q_WIDTH-1:0] input_data [0:N-1];
            logic [Q_WIDTH-1:0] expected [0:N-1];
            for (int i = 0; i < TOTAL_COEFFS; i++) coeffs[i] = '0;
            for (int i = 0; i < N; i++) begin input_data[i] = '0; expected[i] = '0; end

            act_type = 2'd1;
            act_valid = 1;
            @(posedge clk);
            act_valid = 0;
            load_coefficients(2'd1, coeffs);
            m_ready = 1;
            send_polynomial(input_data);
            check_and_wait(expected, "T2");
            m_ready = 0;
        end

        // T3: Tanh
        $display("\n=== T3: Tanh 近似测试 ===");
        begin : tanh_test
            logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1];
            logic [Q_WIDTH-1:0] input_data [0:N-1];
            logic [Q_WIDTH-1:0] expected [0:N-1];
            for (int i = 0; i < TOTAL_COEFFS; i++) coeffs[i] = '0;
            for (int i = 0; i < N; i++) begin input_data[i] = '0; expected[i] = '0; end

            act_type = 2'd2;
            act_valid = 1;
            @(posedge clk);
            act_valid = 0;
            load_coefficients(2'd2, coeffs);
            m_ready = 1;
            send_polynomial(input_data);
            check_and_wait(expected, "T3");
            m_ready = 0;
        end

        // T4: ReLU
        $display("\n=== T4: ReLU 近似测试 ===");
        begin : relu_test
            logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1];
            logic [Q_WIDTH-1:0] input_data [0:N-1];
            logic [Q_WIDTH-1:0] expected [0:N-1];
            for (int i = 0; i < TOTAL_COEFFS; i++) coeffs[i] = '0;
            for (int i = 0; i < N; i++) begin input_data[i] = '0; expected[i] = '0; end

            act_type = 2'd0;
            act_valid = 1;
            @(posedge clk);
            act_valid = 0;
            load_coefficients(2'd0, coeffs);
            m_ready = 1;
            send_polynomial(input_data);
            check_and_wait(expected, "T4");
            m_ready = 0;
        end

        // T5: Linear
        $display("\n=== T5: Linear 直通测试 ===");
        begin : linear_test
            logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1];
            logic [Q_WIDTH-1:0] input_data [0:N-1];
            logic [Q_WIDTH-1:0] expected [0:N-1];
            for (int i = 0; i < TOTAL_COEFFS; i++) coeffs[i] = '0;
            for (int i = 0; i < N; i++) begin input_data[i] = '0; expected[i] = '0; end

            act_type = 2'd3;
            act_valid = 1;
            @(posedge clk);
            act_valid = 0;
            load_coefficients(2'd3, coeffs);
            m_ready = 1;
            send_polynomial(input_data);
            check_and_wait(expected, "T5");
            m_ready = 0;
        end

        // T6: 分段判断（负输入）
        $display("\n=== T6: 分段判断测试 ===");
        begin : segment_test
            logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1];
            logic [Q_WIDTH-1:0] input_data [0:N-1];
            logic [Q_WIDTH-1:0] expected [0:N-1];
            for (int i = 0; i < TOTAL_COEFFS; i++) coeffs[i] = '0;
            for (int i = 0; i < N; i++) begin input_data[i] = '1; expected[i] = '0; end

            act_type = 2'd1;
            act_valid = 1;
            @(posedge clk);
            act_valid = 0;
            load_coefficients(2'd1, coeffs);
            m_ready = 1;
            send_polynomial(input_data);
            check_and_wait(expected, "T6");
            m_ready = 0;
        end

        // T7: 连续多项式输入
        $display("\n=== T7: 连续多项式输入测试 ===");
        begin : cont_test
            logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1];
            logic [Q_WIDTH-1:0] input_data [0:N-1];
            logic [Q_WIDTH-1:0] expected [0:N-1];
            for (int i = 0; i < TOTAL_COEFFS; i++) coeffs[i] = '0;
            for (int i = 0; i < N; i++) begin input_data[i] = 16'(i); expected[i] = '0; end

            act_type = 2'd1;
            act_valid = 1;
            @(posedge clk);
            act_valid = 0;
            load_coefficients(2'd1, coeffs);
            m_ready = 1;
            send_polynomial(input_data);
            check_and_wait(expected, "T7");
            m_ready = 0;
        end

        // T8: 边界条件
        $display("\n=== T8: 边界条件测试 ===");
        begin : boundary_test
            logic [COEFF_WIDTH-1:0] coeffs [0:TOTAL_COEFFS-1];
            logic [Q_WIDTH-1:0] input_data [0:N-1];
            logic [Q_WIDTH-1:0] expected [0:N-1];
            for (int i = 0; i < TOTAL_COEFFS; i++) coeffs[i] = '0;
            for (int i = 0; i < N; i++) begin input_data[i] = '0; expected[i] = '0; end

            act_type = 2'd1;
            act_valid = 1;
            @(posedge clk);
            act_valid = 0;
            load_coefficients(2'd1, coeffs);
            m_ready = 1;
            send_polynomial(input_data);
            check_and_wait(expected, "T8");
            m_ready = 0;
        end

        // =========================================================================
        // 结果汇总
        // =========================================================================
        $display("\n========================================");
        $display("测试结果汇总:");
        $display("  PASS: %0d", pass_count);
        $display("  FAIL: %0d", fail_count);
        $display("  总计: %0d", pass_count + fail_count);
        $display("========================================");

        if (fail_count == 0) begin
            $display("✅ 所有测试通过！");
        end else begin
            $display("❌ 有测试失败！");
        end

        $finish;
    end

    // =========================================================================
    // 波形转储（默认关闭）
    // =========================================================================
    initial begin
        if ($test$plusargs("DUMP_WAVE")) begin
            $dumpfile("activation_approx.vcd");
            $dumpvars(0, tb_activation_approx);
        end
    end

endmodule
