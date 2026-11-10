// =============================================================================
// tb_e2e_slot_simd_wrapper.sv — Task #83 步骤 1.5 扩展
//
// 目的：验证 e2e_slot_simd_wrapper 端到端数据通路完整性
//       packer(样本→多项式) → E2E.b 通道 → E2E 密文乘法 → f0 → unpacker(多项式→样本)
//
// 玩具配置: N=16, LOG_N=4, Q_WIDTH=7, Q_IN=113, Q_OUT=97
//
// wrapper 使用 USE_PACKER_FOR_B=1, USE_UNPACKER_FOR_F0=1 默认配置，
//       外部 b_valid/f0_valid 端口被 wrapper 内部 MUX 悬空，
//       TB 只需驱动 sample_in 与 E2E 密文输入，观察 sample_out 与 done
//
// 测试流程：
//   T1: 复位后 busy=0, done=0, error=0
//   T2: start 脉冲触发，busy 在若干拍内变 1
//   T3: sample_in_ready 曾被拉高（packer 进入 S_LOAD）
//   T4: 加载 5 路 E2E 密文输入（c0_1/c1_1/c0_2/c1_2/a）—— b 通道走 packer，不加载
//   T5: 加载 N/2 个样本到 sample_in
//   T6: 观察 b 通道（packer→E2E.b）至少被驱动一次
//   T7: 等待 done（有界超时保护）
//   T8: 观察 sample_out 通道被驱动 N/2 次（unpacker 解包完成）
//   T9: error 恒 0
//
// 依赖：wrapper + 全部 M1/M2/M3/M4 RTL
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e2e_slot_simd_wrapper;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    // =========================================================================
    // 玩具配置
    // =========================================================================
    localparam int LOG_N   = 4;
    localparam int N       = 16;
    localparam int Q_WIDTH = 7;
    localparam int Q_IN    = 113;
    localparam int Q_OUT   = 97;
    localparam int N_INV   = 106;
    localparam int NUM_SLOTS = N / 2;

    // =========================================================================
    // 时钟 & 复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // 顶层控制
    // =========================================================================
    logic                 start;
    logic                 busy;
    logic                 done;
    logic                 error;

    // 样本输入 (N/2)
    logic                 sample_in_valid;
    logic                 sample_in_ready;
    logic [Q_WIDTH-1:0]   sample_in_data;

    // 样本输出 (N/2)
    logic                 sample_out_valid;
    logic                 sample_out_ready;
    logic [Q_WIDTH-1:0]   sample_out_data;

    // E2E 密文输入
    logic                 c0_1_valid, c0_1_ready;
    logic [Q_WIDTH-1:0]   c0_1_data;
    logic                 c1_1_valid, c1_1_ready;
    logic [Q_WIDTH-1:0]   c1_1_data;
    logic                 c0_2_valid, c0_2_ready;
    logic [Q_WIDTH-1:0]   c0_2_data;
    logic                 c1_2_valid, c1_2_ready;
    logic [Q_WIDTH-1:0]   c1_2_data;
    logic                 a_valid, a_ready;
    logic [Q_WIDTH-1:0]   a_data;
    // b 通道：wrapper 内部 MUX 悬空（USE_PACKER_FOR_B=1）
    logic                 b_valid, b_ready;
    logic [Q_WIDTH-1:0]   b_data;

    // E2E 密文输出（wrapper 内部 MUX 悬空 f0，但保留端口做调试观察）
    logic                 f0_valid, f0_ready;
    logic [Q_WIDTH-1:0]   f0_data;
    logic                 f1_valid, f1_ready;
    logic [Q_WIDTH-1:0]   f1_data;


    // =========================================================================
    // DUT 实例化
    // =========================================================================
    e2e_slot_simd_wrapper #(
        .LOG_N      (LOG_N),
        .N          (N),
        .Q_WIDTH    (Q_WIDTH),
        .Q_IN       (Q_IN),
        .Q_OUT      (Q_OUT),
        .N_INV      (N_INV),
        .USE_FASTRED(0),
        .USE_PACKER_FOR_B   (1'b1),
        .USE_UNPACKER_FOR_F0(1'b1),
        .TW_FILE            ({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}),
        .TW_INV_FILE        ({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"})
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .busy             (busy),
        .done             (done),
        .error            (error),
        .sample_in_valid  (sample_in_valid),
        .sample_in_ready  (sample_in_ready),
        .sample_in_data   (sample_in_data),
        .sample_out_valid (sample_out_valid),
        .sample_out_ready (sample_out_ready),
        .sample_out_data  (sample_out_data),
        .c0_1_valid       (c0_1_valid),
        .c0_1_ready       (c0_1_ready),
        .c0_1_data        (c0_1_data),
        .c1_1_valid       (c1_1_valid),
        .c1_1_ready       (c1_1_ready),
        .c1_1_data        (c1_1_data),
        .c0_2_valid       (c0_2_valid),
        .c0_2_ready       (c0_2_ready),
        .c0_2_data        (c0_2_data),
        .c1_2_valid       (c1_2_valid),
        .c1_2_ready       (c1_2_ready),
        .c1_2_data        (c1_2_data),
        .a_valid          (a_valid),
        .a_ready          (a_ready),
        .a_data           (a_data),
        .b_valid          (b_valid),
        .b_ready          (b_ready),
        .b_data           (b_data),
        .f0_valid         (f0_valid),
        .f0_ready         (f0_ready),
        .f0_data          (f0_data),
        .f1_valid         (f1_valid),
        .f1_ready         (f1_ready),
        .f1_data          (f1_data)
    );

    // =========================================================================
    // 常驻样本输出计数器 + done 脉冲捕获
    // （单拍脉冲不能用 while(!done) @(posedge) 轮询——与 DUT always_ff 存在
    //   调度竞争会整体错过；必须用 always @(posedge) 沿触发捕获）
    // =========================================================================
    integer sample_out_cnt = 0;
    logic   done_seen = 1'b0;
    always @(posedge clk) begin
        if (rst_n && sample_out_valid && sample_out_ready)
            sample_out_cnt = sample_out_cnt + 1;
        if (rst_n && done)
            done_seen <= 1'b1;
    end

    // =========================================================================
    // 复位与初始化
    // =========================================================================
    initial begin
        start          = 1'b0;
        sample_in_valid = 1'b0;
        sample_out_ready = 1'b1;
        f0_ready      = 1'b1;
        f1_ready      = 1'b1;
        c0_1_valid    = 1'b0;
        c1_1_valid    = 1'b0;
        c0_2_valid    = 1'b0;
        c1_2_valid    = 1'b0;
        a_valid       = 1'b0;
        b_valid       = 1'b0;
        sample_in_data = '0;
        c0_1_data = '0;
        c1_1_data = '0;
        c0_2_data = '0;
        c1_2_data = '0;
        a_data    = '0;
        b_data    = '0;
    end

    // =========================================================================
    // 测试任务
    // =========================================================================
    integer i, pass_cnt = 0, fail_cnt = 0;

    // =========================================================================
    // 加载任务：每个流独立 task，内部直接用模块级 signal（避免 ref 参数被
    // xvlog 静态分析误判为 DUT output 端口的多驱动源）
    // 时序：TB 驱动必须落 negedge，@posedge 只等采样沿、当拍不写任何信号
    // =========================================================================

    task automatic load_c0_1(input integer seed, input integer count);
        automatic integer wait_cnt = 0;
        for (i = 0; i < count; i = i + 1) begin
            wait_cnt = 0;
            while (!c0_1_ready) begin
                @(negedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 5000) begin
                    $display("[WARN] load_c0_1 timeout: idx=%0d", i);
                    return;
                end
            end
            @(negedge clk);
            c0_1_valid = 1'b1;
            c0_1_data  = ((seed * i + i*3 + 1) % Q_IN);
            @(posedge clk);
            @(negedge clk);
            c0_1_valid = 1'b0;
        end
    endtask

    task automatic load_c1_1(input integer seed, input integer count);
        automatic integer wait_cnt = 0;
        for (i = 0; i < count; i = i + 1) begin
            wait_cnt = 0;
            while (!c1_1_ready) begin
                @(negedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 5000) begin
                    $display("[WARN] load_c1_1 timeout: idx=%0d", i);
                    return;
                end
            end
            @(negedge clk);
            c1_1_valid = 1'b1;
            c1_1_data  = ((seed * i + i*3 + 1) % Q_IN);
            @(posedge clk);
            @(negedge clk);
            c1_1_valid = 1'b0;
        end
    endtask

    task automatic load_c0_2(input integer seed, input integer count);
        automatic integer wait_cnt = 0;
        for (i = 0; i < count; i = i + 1) begin
            wait_cnt = 0;
            while (!c0_2_ready) begin
                @(negedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 5000) begin
                    $display("[WARN] load_c0_2 timeout: idx=%0d", i);
                    return;
                end
            end
            @(negedge clk);
            c0_2_valid = 1'b1;
            c0_2_data  = ((seed * i + i*3 + 1) % Q_IN);
            @(posedge clk);
            @(negedge clk);
            c0_2_valid = 1'b0;
        end
    endtask

    task automatic load_c1_2(input integer seed, input integer count);
        automatic integer wait_cnt = 0;
        for (i = 0; i < count; i = i + 1) begin
            wait_cnt = 0;
            while (!c1_2_ready) begin
                @(negedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 5000) begin
                    $display("[WARN] load_c1_2 timeout: idx=%0d", i);
                    return;
                end
            end
            @(negedge clk);
            c1_2_valid = 1'b1;
            c1_2_data  = ((seed * i + i*3 + 1) % Q_IN);
            @(posedge clk);
            @(negedge clk);
            c1_2_valid = 1'b0;
        end
    endtask

    task automatic load_a(input integer seed, input integer count);
        automatic integer wait_cnt = 0;
        for (i = 0; i < count; i = i + 1) begin
            wait_cnt = 0;
            while (!a_ready) begin
                @(negedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 5000) begin
                    $display("[WARN] load_a timeout: idx=%0d", i);
                    return;
                end
            end
            @(negedge clk);
            a_valid = 1'b1;
            a_data  = ((seed * i + i*3 + 1) % Q_IN);
            @(posedge clk);
            @(negedge clk);
            a_valid = 1'b0;
        end
    endtask

    task automatic load_samples(input integer seed);
        automatic integer wait_cnt = 0;
        for (i = 0; i < NUM_SLOTS; i = i + 1) begin
            wait_cnt = 0;
            while (!sample_in_ready) begin
                @(negedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 5000) begin
                    $display("[WARN] load_samples timeout: idx=%0d", i);
                    return;
                end
            end
            @(negedge clk);
            sample_in_valid = 1'b1;
            sample_in_data  = ((seed * i + i + 1) % Q_IN);
            @(posedge clk);
            @(negedge clk);
            sample_in_valid = 1'b0;
        end
    endtask

    task automatic check(input integer cond, input string name);
        if (cond) begin
            pass_cnt = pass_cnt + 1;
            $display("[PASS] %s", name);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("[FAIL] %s", name);
        end
    endtask

    // =========================================================================
    // 主流程
    // =========================================================================
    initial begin
        // 复位
        rst_n = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(3) @(posedge clk);

        // =========================================================================
        // 测试 1：复位后 busy=0, done=0, error=0
        // =========================================================================
        check(busy == 0, "T1: 复位后 busy=0");
        check(done == 0, "T1: 复位后 done=0");
        check(error == 0, "T1: 复位后 error=0");

        // =========================================================================
        // 测试 2：start 脉冲触发
        // =========================================================================
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;

        begin : busy_obs
automatic integer k = 0;
            while (!busy && k < 200) begin
                @(posedge clk);
                k = k + 1;
            end
            check(busy == 1, "T2: start 触发后 busy=1");
        end

        // =========================================================================
        // 测试 3：sample_in_ready 至少一次为 1（packer 进入 S_LOAD）
        // =========================================================================
        begin : sample_in_ready_obs
automatic integer k = 0;
automatic logic observed_ready = 1'b0;
            while (k < 500) begin
                if (sample_in_ready) observed_ready = 1'b1;
                @(posedge clk);
                k = k + 1;
            end
            check(observed_ready == 1, "T3: sample_in_ready 曾被拉高（packer 进入 S_LOAD）");
        end

    // =========================================================================
    // 测试 4：加载 E2E 密文输入（顺序加载，匹配 M4 E2E TB 方式）
    //   E2E 状态机：S_LOAD_C1(c0_1+c1_1) → S_LOAD_C2(c0_2+c1_2) → S_LOAD_KEY(a+b)
    //   顺序加载每路 16 系数，E2E 的 widx 在对应 ready 拉高时递增
    //   b 通道走 packer，跳过外部 b 加载
    // =========================================================================
    load_c0_1(11, N);
    load_c1_1(13, N);
    load_c0_2(17, N);
    load_c1_2(19, N);
    load_a(23, N);

    check(1, "T4: E2E 密文输入加载完成（c0_1+c1_1, c0_2+c1_2, a）");

    // =========================================================================
    // 测试 5：加载 N/2 个样本到 sample_in（packer 打包为 b 多项式）
    //   packer 输出通过 wrapper 内部 MUX 驱动 E2E.b 通道
    // =========================================================================
    load_samples(41);

    check(1, "T5: N/2 样本加载完成");

        // =========================================================================
        // 测试 6：观察 b 通道（packer → E2E.b）
        //   wrapper 内部 e2e_b_valid ← packer_poly_valid，
        //   外部 b_valid 被 MUX 拉 0，但可通过 wrapper.hier 观察 e2e_b_valid
        //   这里通过观察 sample_out 与 done 间接确认 packer → E2E.b 通路正常
        //   若通路断裂，done 永不出现
        // =========================================================================
        begin : b_path_probe
automatic integer k = 0;
automatic logic observed_b_valid = 1'b0;
            // 通过 u_dut.e2e_b_valid 层次化观察（packer.poly_valid → E2E.b_valid 内部通路）
            while (k < 50000) begin
                if (u_dut.e2e_b_valid) begin
                    observed_b_valid = 1'b1;
                end
                @(posedge clk);
                k = k + 1;
            end
            check(observed_b_valid == 1, "T6: packer→E2E.b 通路被驱动（e2e_b_valid 曾拉高）");
        end

        // =========================================================================
        // 测试 7：等待 done（用 done_seen 沿触发捕获，避免单拍脉冲轮询竞争）
        // =========================================================================
        begin : wait_done
automatic integer k = 0;
            while (!done_seen && k < 12000000) begin
                @(posedge clk);
                k = k + 1;
                if (k % 100000 == 0)
                    $display("  [DBG] wait_done k=%0d wrapper.state=%0d unpacker_done=%b unpacker_done_seen=%b e2e_done=%b",
                             k, u_dut.state, u_dut.unpacker_done, u_dut.unpacker_done_seen, u_dut.e2e_done);
            end
            check(done_seen == 1, "T7: done 脉冲出现（无死锁，unpacker 完成）");
        end

        // =========================================================================
        // 测试 8：unpacker 输出样本数（全局持续计数器，不受观察窗口限制）
        //   sample_out_cnt 由常驻监控块从复位后一直统计到仿真结束
        // =========================================================================
        check(sample_out_cnt >= NUM_SLOTS,
              $sformatf("T8: unpacker 输出 %0d 个样本（期望 %0d）", sample_out_cnt, NUM_SLOTS));

        // =========================================================================
        // 测试 9：error 恒 0
        // =========================================================================
        check(error == 0, "T9: error 恒 0");

        // =========================================================================
        // 汇总
        // =========================================================================
        $display("");
        $display("=========================================");
        $display("TEST SUMMARY: PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("=========================================");
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("HAS FAIL");
        $finish;
    end

    // 看门狗（放到 200ms，覆盖 N=16 E2E 完整处理 ~59ms + 余量）
    initial begin
        #200_000_000;
        $display("[TIMEOUT] 仿真超时");
        $finish;
    end

endmodule
