//=============================================================================
// tb_gemm_tiling_ctrl.sv - GEMM 分层优化控制器测试平台（v3 重写）
//
// 配置：M=4, K=2, N=4, TM=TK=TN=2  =>  NTILE=(2,1,2)，共 4 个输出 tile。
//   A: 4x2, B: 2x4, C: 4x4；控制器逐 tile 加载 A/B 子块、MAC 计算 C、流式输出。
// 验证点：
//   T1 复位状态（busy=0, done=0）
//   T2 GEMM 正确性：C = A x B，16 个输出逐位比对
//   T3 done 断言 + busy 行为
//   T4 连续第二轮 GEMM（tile 遍历复位后再次正确）
// 喂数约定：a_data/b_data 由全局计数 a_cnt/b_cnt 按 tile 结构推导（negedge 驱动），
//          控制器在 LOAD_A/LOAD_B 期间自动拉取；输出在 posedge 采集。
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_gemm_tiling_ctrl;

    localparam int M = 4, K = 2, N = 4;
    localparam int TM = 2, TK = 2, TN = 2;
    localparam int NTILE_M = M / TM;
    localparam int NTILE_K = K / TK;
    localparam int NTILE_N = N / TN;
    localparam int DATA_WIDTH = 32;
    localparam int A_TILE = TM * TK;
    localparam int B_TILE = TK * TN;
    localparam int C_TILE = TM * TN;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic                  a_valid, a_ready;
    logic [DATA_WIDTH-1:0] a_data;
    logic                  b_valid, b_ready;
    logic [DATA_WIDTH-1:0] b_data;
    logic                  c_valid, c_ready;
    logic [DATA_WIDTH-1:0] c_data;
    logic                  start, busy, done, error;

    gemm_tiling_ctrl #(
        .M(M), .K(K), .N(N), .TM(TM), .TK(TK), .TN(TN), .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .a_valid(a_valid), .a_ready(a_ready), .a_data(a_data),
        .b_valid(b_valid), .b_ready(b_ready), .b_data(b_data),
        .c_valid(c_valid), .c_ready(c_ready), .c_data(c_data),
        .start(start), .busy(busy), .done(done), .error(error)
    );

    // 源矩阵与期望
    logic [DATA_WIDTH-1:0] A [0:M-1][0:K-1];
    logic [DATA_WIDTH-1:0] B [0:K-1][0:N-1];
    logic [DATA_WIDTH-1:0] C [0:M-1][0:N-1];
    logic [DATA_WIDTH-1:0] expected_out [0:M*N-1];

    int a_cnt, b_cnt, c_cnt;
    logic [DATA_WIDTH-1:0] c_buf [0:M*N-1];
    logic run;

    // 依据全局 A 计数推导应喂的 A 值
    function automatic logic [DATA_WIDTH-1:0] a_val(input int acnt);
        int t, ain, bn_, bm_, m, k;
        begin
            t   = acnt / A_TILE;
            ain = acnt % A_TILE;
            bn_ = t % NTILE_N;
            bm_ = t / NTILE_N;
            m   = ain / TK;
            k   = ain % TK;
            a_val = A[bm_*TM + m][k];
        end
    endfunction

    // 依据全局 B 计数推导应喂的 B 值
    function automatic logic [DATA_WIDTH-1:0] b_val(input int bcnt);
        int t, bin, bn_, bm_, k, n;
        begin
            t   = bcnt / B_TILE;
            bin = bcnt % B_TILE;
            bn_ = t % NTILE_N;
            bm_ = t / NTILE_N;
            k   = bin / TN;
            n   = bin % TN;
            b_val = B[k][bn_*TN + n];
        end
    endfunction

    // 驱动（negedge）：run 期间持续供给 A/B
    always @(negedge clk) begin
        if (run) begin
            a_valid = 1'b1;
            b_valid = 1'b1;
            a_data  = a_val(a_cnt);
            b_data  = b_val(b_cnt);
        end else begin
            a_valid = 1'b0;
            b_valid = 1'b0;
        end
    end

    // 监控（posedge）：累计 A/B 消耗计数，采集 C 输出
    always @(posedge clk) begin
        if (rst_n && run) begin
            if (a_valid && a_ready) a_cnt <= a_cnt + 1;
            if (b_valid && b_ready) b_cnt <= b_cnt + 1;
            if (c_valid && c_ready) begin
                c_buf[c_cnt] <= c_data;
                c_cnt <= c_cnt + 1;
            end
        end
    end

    int pass_count = 0;
    int fail_count = 0;

    // 跑一轮 GEMM 并校验输出
    task run_and_check(input string tag);
        int g, t, o, bn_, bm_, row, col, tmo;
        logic got_done;
        begin
            a_cnt = 0; b_cnt = 0; c_cnt = 0;
            run = 1;
            // start 脉冲（negedge 置位，保持一个 posedge）
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            // 等待 done（done 仅持续一拍，退出后立即锁存）
            tmo = 0;
            while (!done && tmo < 20000) begin @(posedge clk); tmo = tmo + 1; end
            got_done = done;
            run = 0;
            @(posedge clk);
            if (!got_done) begin
                $display("  FAIL %s: done 未断言 (tmo=%0d)", tag, tmo);
                fail_count = fail_count + 1;
                return;
            end
            if (c_cnt != M*N) begin
                $display("  FAIL %s: 输出数 %0d 期望 %0d", tag, c_cnt, M*N);
                fail_count = fail_count + 1;
                return;
            end
            for (g = 0; g < M*N; g++) begin
                t   = g / C_TILE; o = g % C_TILE;
                bn_ = t % NTILE_N; bm_ = t / NTILE_N;
                row = bm_*TM + o/TN; col = bn_*TN + o%TN;
                if (c_buf[g] !== C[row][col]) begin
                    $display("  FAIL %s: out[%0d]=%0d expected C[%0d][%0d]=%0d",
                             tag, g, c_buf[g], row, col, C[row][col]);
                    fail_count = fail_count + 1;
                    return;
                end
            end
            $display("  PASS %s: %0d 个输出与 A x B 逐位一致, done 断言", tag, M*N);
            pass_count = pass_count + 1;
        end
    endtask

    initial begin
        run = 0; a_valid = 0; b_valid = 0; a_data = 0; b_data = 0;
        start = 0; c_ready = 1;

        // 构造 A/B 并计算 C = A x B
        for (int r = 0; r < M; r++)
            for (int k = 0; k < K; k++)
                A[r][k] = DATA_WIDTH'(r*K + k + 1);
        for (int k = 0; k < K; k++)
            for (int c = 0; c < N; c++)
                B[k][c] = DATA_WIDTH'(k*N + c + 1);
        for (int r = 0; r < M; r++)
            for (int c = 0; c < N; c++) begin
                int acc;
                acc = 0;
                for (int k = 0; k < K; k++) acc = acc + A[r][k]*B[k][c];
                C[r][c] = DATA_WIDTH'(acc);
            end

        $display("=== T1: 复位状态 ===");
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        if (!busy && !done && !error) begin
            $display("  PASS T1: busy=0 done=0 error=0"); pass_count++;
        end else begin
            $display("  FAIL T1: busy=%b done=%b error=%b", busy, done, error); fail_count++;
        end

        $display("=== T2: GEMM 正确性 (4x2 * 2x4 = 4x4) ===");
        run_and_check("T2");

        $display("=== T3: busy/done 行为（运行中 busy=1）===");
        a_cnt = 0; b_cnt = 0; c_cnt = 0; run = 1;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        repeat (3) @(posedge clk);
        if (busy) begin $display("  PASS T3: 运行中 busy=1"); pass_count++; end
        else begin $display("  FAIL T3: busy=0"); fail_count++; end
        // 等这轮结束
        begin : waitfin
            int tmo; tmo = 0;
            while (!done && tmo < 20000) begin @(posedge clk); tmo++; end
        end
        run = 0;
        @(posedge clk);

        $display("=== T4: 连续第二轮 GEMM ===");
        run_and_check("T4");

        $display("\n============================================================");
        $display("测试总结：PASS: %0d  FAIL: %0d  TOTAL: %0d", pass_count, fail_count, pass_count+fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("✅ 全部测试通过");
        else                 $display("❌ 存在失败用例");
        #100; $finish;
    end

    initial begin
        #500000; $display("ERROR: 仿真超时！"); $finish;
    end

endmodule

`default_nettype wire
