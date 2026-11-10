//=============================================================================
// tb_poly_mult.sv  —  poly_mult 功能测试平台（密推芯 M2-c）
//
// 测试目标：
//   对 10 组 (A, B) 向量，验证 poly_mult 输出的 C = A*B mod (x^N-1, q) 与
//   Python 参考（tb/ref/gen_poly_mult_vectors.py 双路自校验）逐系数对齐。
//
// 配置：
//   N = 16, LOG_N = 4, q = 113, Q_WIDTH = 7
//   omega = 40, omega_inv = 65, N_INV = 106（与 M1 NTT/INTT 完全一致）
//
// 向量文件（与 xsim 工作目录同目录）：
//   poly_a.hex, poly_b.hex, poly_expected.hex
//   各 160 行（NUM_TESTS=10 * N=16），row-major 平铺
//
// 关键握手约定（沿用 M1 TB 已验证）：
//   - @(posedge clk) 后必须 #1 等 NBA 更新
//   - 最后一个数据不等握手，只等 1 posedge 让 DUT 采样
//   - start 单周期脉冲
//
// 预期总耗时：约 700 cycles/向量 * 10 = ~7000 cycles * 10ns = 70us，
//            仿真 2,000,000 ns（2ms）绰绰有余
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_poly_mult;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    // =========================================================================
    // 参数
    // =========================================================================
    localparam int    LOG_N       = 4;
    localparam int    N           = 1 << LOG_N;
    localparam int    Q_WIDTH     = 7;
    localparam int    Q_VALUE     = 113;
    localparam int    N_INV       = 106;
    localparam int    NUM_TESTS   = 10;
    localparam real   CLK_PERIOD  = 10.0;   // 100 MHz

    // 向量目录
    string tbdir = ".";

    // =========================================================================
    // 顶层信号
    // =========================================================================
    logic clk;
    logic rst_n;

    logic start;
    logic busy;
    logic done;
    logic error;

    // A 输入
    logic [Q_WIDTH-1:0] a_in_data;
    logic               a_in_valid;
    logic               a_in_ready;

    // B 输入
    logic [Q_WIDTH-1:0] b_in_data;
    logic               b_in_valid;
    logic               b_in_ready;

    // C 输出
    logic [Q_WIDTH-1:0] out_data;
    logic               out_valid;
    logic               out_last;
    logic               out_ready;


    // 参考向量
    logic [Q_WIDTH-1:0] ref_a  [0:NUM_TESTS*N-1];
    logic [Q_WIDTH-1:0] ref_b  [0:NUM_TESTS*N-1];
    logic [Q_WIDTH-1:0] ref_c  [0:NUM_TESTS*N-1];

    // 收集输出
    logic [Q_WIDTH-1:0] out_buf [0:N-1];

    // 统计
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // 时钟
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 复位
    // =========================================================================
    initial begin
        rst_n = 0;
        #20;
        rst_n = 1;
    end

    // =========================================================================
    // DUT
    // =========================================================================
    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VALUE),
        .N_INV(N_INV),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"})
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .error(error),
        .a_in_data(a_in_data),
        .a_in_valid(a_in_valid),
        .a_in_ready(a_in_ready),
        .b_in_data(b_in_data),
        .b_in_valid(b_in_valid),
        .b_in_ready(b_in_ready),
        .out_data(out_data),
        .out_valid(out_valid),
        .out_last(out_last),
        .out_ready(out_ready)
    );


    // =========================================================================
    // 向量加载
    // =========================================================================
    initial begin
        if (!$value$plusargs("tbdir=%s", tbdir)) begin
            tbdir = ".";
        end
        $display("[TB] Loading reference vectors from: %s", tbdir);
        $readmemh($sformatf("%s/poly_a.hex",        tbdir), ref_a);
        $readmemh($sformatf("%s/poly_b.hex",        tbdir), ref_b);
        $readmemh($sformatf("%s/poly_expected.hex", tbdir), ref_c);
    end

    // =========================================================================
    // A 输入任务（参数 v：当前测试向量索引）
    //   关键：posedge active region 立即采样 in_ready（与 DUT always_ff 采样时机一致）
    //        —— 因为 DUT 的 b_in_ready 是寄存输出（NBA 更新），若用 posedge+#1
    //           读到的是 NBA 后的值，与 DUT 采样错开 1 拍，会跳过首个系数。
    //        break 后 #1 跳到新 time step，再阻塞赋值 a_in_data（不与 DUT 采样冲突）。
    // =========================================================================
    task automatic input_A(int v);
        automatic integer i;
        begin
            a_in_valid = 1'b1;
            a_in_data  = ref_a[v*N + 0];
            for (i = 0; i < N; i = i + 1) begin
                forever begin
                    @(posedge clk);
                    if (a_in_ready) break;   // active region 立即采样
                end
                if (i < N - 1) begin
                    #1;                      // 新 time step
                    a_in_data = ref_a[v*N + i + 1];
                end
            end
            #1;
            a_in_valid = 1'b0;
        end
    endtask

    // =========================================================================
    // B 输入任务（参数 v：当前测试向量索引）
    // =========================================================================
    task automatic input_B(int v);
        automatic integer i;
        begin
            b_in_valid = 1'b1;
            b_in_data  = ref_b[v*N + 0];
            for (i = 0; i < N; i = i + 1) begin
                forever begin
                    @(posedge clk);
                    if (b_in_ready) break;   // active region 立即采样
                end
                if (i < N - 1) begin
                    #1;
                    b_in_data = ref_b[v*N + i + 1];
                end
            end
            #1;
            b_in_valid = 1'b0;
        end
    endtask

    // =========================================================================
    // C 输出任务
    //   关键约束：
    //     1. TB 必须保持 out_ready=1 让 poly_mult 的 S_INTT_COLLECT 推进，
    //        否则 DUT 会在 INTT 阶段永久阻塞（ntt_unit 输出等待 out_ready）。
    //     2. out_valid 只在 DUT 完成一次 out_data 装载后拉高 1 cycle；
    //        下一次 posedge 被默认清零，因此 TB 必须在 @(posedge clk) 的
    //        active region 内立即采样 out_valid（不做 #1，否则读到 NBA 后的 0）。
    //     3. out_data 是 always_ff 输出，在 posedge 到 #1 之间仍是上一拍值，
    //        active region 内读到的是本次装载的数据。
    // =========================================================================
    task automatic output_C;
        automatic integer i;
        begin
            out_ready = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                forever begin
                    @(posedge clk);
                    if (out_valid) break;    // active region 采样，NBA 前
                end
                out_buf[i] = out_data;       // active region 内读，NBA 前的值
                if (out_last) out_ready = 1'b0;
            end
        end
    endtask

    // =========================================================================
    // DEBUG 状态机跟踪（仅状态变化时打印，避免 500 cycle 刷屏）
    // =========================================================================
    initial begin
        $dumpvars(0, u_dut);
        $dumpfile("poly_mult.vcd");
    end

    logic [2:0] prev_state = 'x;
    // 采样时延 #1，读到的是 NBA 更新后的真实信号值
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            // 只在 state 变化，或 INTT/NTT_B 阶段的前 30 cycles 打印
            if (u_dut.state !== prev_state || u_dut.state == 6 || u_dut.state == 4) begin
                $display("t=%0t SM=%0d(%s) ph=%b feed=%0d col=%0d nttSM=%0d nInV=%b nInR=%b nOutV=%b nOutR=%b outV=%b outR=%b done=%b",
                    $time, u_dut.state,
                    (u_dut.state==0 ? "IDLE"    : u_dut.state==1 ? "IN_A"   :
                     u_dut.state==2 ? "IN_B"    : u_dut.state==3 ? "NTT_A"  :
                     u_dut.state==4 ? "NTT_B"   : u_dut.state==5 ? "MUL"    :
                     u_dut.state==6 ? "INTT"    : u_dut.state==7 ? "DONE"   : "?"),
                    u_dut.ntt_phase,
                    u_dut.ntt_feeder_idx, u_dut.ntt_collector_idx,
                    u_dut.u_ntt.state,
                    u_dut.ntt_in_valid, u_dut.ntt_in_ready,
                    u_dut.ntt_out_valid, u_dut.ntt_out_ready,
                    u_dut.out_valid, out_ready, u_dut.done);
                prev_state = u_dut.state;
            end
        end
    end

    // =========================================================================
    // 主测试流程
    // =========================================================================
    initial begin
        $display("========================================================");
        $display("Poly Mult Testbench (M2-c)");
        $display("N=%0d, LOG_N=%0d, q=%0d, omega=40, omega_inv=65, N_INV=%0d",
                 N, LOG_N, Q_VALUE, N_INV);
        $display("Vectors: %0d  |  Coeffs/vector: %0d", NUM_TESTS, N);
        $display("========================================================");

        start     = 1'b0;
        a_in_valid= 1'b0;
        b_in_valid= 1'b0;
        a_in_data = '0;
        b_in_data = '0;
        out_ready = 1'b0;

        wait (rst_n === 1'b1);
        @(posedge clk);
        #50;

        for (integer v = 0; v < NUM_TESTS; v = v + 1) begin
            // 启动
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            // 三路并行：灌 A、灌 B、收 C（output_C 必须提前激活，
            // 否则 out_ready=0 会让 poly_mult 在 INTT_COLLECT 死锁）
            fork
                input_A(v);
                input_B(v);
                output_C;
            join

            // 兜底：若 wait 完成前 done 已经拉高则立即跳出；否则阻塞
            wait (done === 1'b1);
            // done 拉高那拍 out_valid 已拉低，out_buf 已收齐

            // 比较
            begin : cmp_blk
                integer i, errs;
                errs = 0;
                for (i = 0; i < N; i = i + 1) begin
                    if (out_buf[i] !== ref_c[v*N + i]) begin
                        errs = errs + 1;
                        if (errs <= 3) begin
                            $display("  [MISMATCH] vec%0d idx=%0d got=%0d want=%0d",
                                     v, i, out_buf[i], ref_c[v*N + i]);
                        end
                    end
                end
                if (errs == 0) begin
                    $display("  vec%0d: PASS (%0d/%0d)", v, N, N);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("  vec%0d: FAIL (%0d/%0d mismatches)", v, errs, N);
                    fail_cnt = fail_cnt + 1;
                end
            end

            // 让 start 与 a/b_valid 在 idle 拍
            @(posedge clk);
        end

        // =========================================================================
        // 汇总
        // =========================================================================
        $display("");
        $display("========================================================");
        $display("SUMMARY - M2-c poly_mult");
        $display("========================================================");
        $display("  PASS: %0d/%0d", pass_cnt, NUM_TESTS);
        $display("  FAIL: %0d/%0d", fail_cnt, NUM_TESTS);
        $display("========================================================");

        if (fail_cnt == 0) begin
            $display("*** ALL TESTS PASSED (%0d vectors, %0d coeffs each) ***",
                     NUM_TESTS, N);
        end else begin
            $display("*** %0d/%0d FAILED ***", fail_cnt, NUM_TESTS);
        end
        $display("========================================================");

        #100;
        $finish;
    end

    // =========================================================================
    // 看门狗
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 200000);
        $display("");
        $display("*** TIMEOUT - Test did not complete ***");
        $finish;
    end

endmodule

`default_nettype wire
