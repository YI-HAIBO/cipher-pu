//=============================================================================
// tb_poly_mult_n12.sv — poly_mult N=2^12 降级路径功能回归（q3 统一参数集）
//
// 配置（USE_FASTRED=1 路径）：
//   N = 4096, LOG_N = 12
//   Q_WIDTH = 45, Q_VALUE = 17592186175489 = q3 = 2^44 + 131073
//   omega  = 13482285337619  （g=11 的 N 次单位根，omega^N = 1，正循环）
//   omega_inv = 11888153632024
//   N_INV  = 17587891208161  = 4096^-1 mod q3
//   USE_BRAM_IP = 0（走 ntt_mem_tdp_prod 自动推断分支，无需 IP 仿真模型；
//                 语义与 blk_mem_gen IP 分支等价，综合路径仍走 IP）
//
// 目的：在架构改造（时分复用 / 缓冲 BRAM 化 / 流水化）之前建立功能基线，
//       验证 q3 + N=2^12 + fast-red 组合下 poly_mult 与 Python 参考逐系数对齐。
//
// 与 tb_poly_mult_prod.sv（N=16）的差异：
//   1. LOG_N=12，omega/omega_inv 表从 hex 文件加载（2048 项，硬编码不现实）
//   2. USE_BRAM_IP=0
//   3. NUM_TESTS=4（N=4096 仿真较慢）
//   4. 去掉逐拍状态机跟踪（打印量过大）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_poly_mult_n12;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    localparam int                  LOG_N       = 12;
    localparam int                  N           = 1 << LOG_N;   // 4096
    localparam int                  Q_WIDTH     = 45;
    localparam logic [Q_WIDTH-1:0]  Q_VALUE     = 45'd17592186175489;   // q3
    localparam logic [Q_WIDTH-1:0]  N_INV       = 45'd17587891208161;
    localparam int                  USE_FASTRED = 1;
    localparam bit                  USE_BRAM_IP = 0;            // 自动推断分支
    localparam int                  NUM_TESTS   = 4;
    localparam real                 CLK_PERIOD  = 10.0;         // 100 MHz

    string tbdir = ".";

    logic clk;
    logic rst_n;

    logic start;
    logic busy;
    logic done;
    logic error;

    logic [Q_WIDTH-1:0] a_in_data;
    logic               a_in_valid;
    logic               a_in_ready;

    logic [Q_WIDTH-1:0] b_in_data;
    logic               b_in_valid;
    logic               b_in_ready;

    logic [Q_WIDTH-1:0] out_data;
    logic               out_valid;
    logic               out_last;
    logic               out_ready;


    logic [Q_WIDTH-1:0] ref_a  [0:NUM_TESTS*N-1];
    logic [Q_WIDTH-1:0] ref_b  [0:NUM_TESTS*N-1];
    logic [Q_WIDTH-1:0] ref_c  [0:NUM_TESTS*N-1];

    logic [Q_WIDTH-1:0] out_buf [0:N-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 0;
        #20;
        rst_n = 1;
    end

    poly_mult #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VALUE),
        .N_INV(N_INV),
        .USE_FASTRED(USE_FASTRED),
        .USE_BRAM_IP(USE_BRAM_IP),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_q3_n4096.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_q3_n4096.hex"})
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
    // 加载 twiddle 表与参考向量
    // =========================================================================
    initial begin
        if (!$value$plusargs("tbdir=%s", tbdir)) begin
            tbdir = ".";
        end
        $display("[TB] Loading vectors from: %s", tbdir);
        $readmemh($sformatf("%s/poly_a_n12.hex",       tbdir), ref_a);
        $readmemh($sformatf("%s/poly_b_n12.hex",       tbdir), ref_b);
        $readmemh($sformatf("%s/poly_expected_n12.hex", tbdir), ref_c);
    end

    // =========================================================================
    // A 输入任务
    // =========================================================================
    task automatic input_A(int v);
        automatic integer i;
        begin
            a_in_valid = 1'b1;
            a_in_data  = ref_a[v*N + 0];
            for (i = 0; i < N; i = i + 1) begin
                forever begin
                    @(posedge clk);
                    if (a_in_ready) break;
                end
                if (i < N - 1) begin
                    #1;
                    a_in_data = ref_a[v*N + i + 1];
                end
            end
            #1;
            a_in_valid = 1'b0;
        end
    endtask

    // =========================================================================
    // B 输入任务
    // =========================================================================
    task automatic input_B(int v);
        automatic integer i;
        begin
            b_in_valid = 1'b1;
            b_in_data  = ref_b[v*N + 0];
            for (i = 0; i < N; i = i + 1) begin
                forever begin
                    @(posedge clk);
                    if (b_in_ready) break;
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
    // =========================================================================
    task automatic output_C;
        automatic integer i;
        begin
            out_ready = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                forever begin
                    @(posedge clk);
                    if (out_valid) break;
                end
                out_buf[i] = out_data;
                if (out_last) out_ready = 1'b0;
            end
        end
    endtask

    // =========================================================================
    // 主测试流程
    // =========================================================================
    initial begin
        $display("========================================================");
        $display("Poly Mult N=2^12 Regression (q3 unified, USE_FASTRED=1)");
        $display("N=%0d LOG_N=%0d Q_WIDTH=%0d USE_FASTRED=%0d USE_BRAM_IP=%0d",
                 N, LOG_N, Q_WIDTH, USE_FASTRED, USE_BRAM_IP);
        $display("q = %0d (2^44 + 131073)", Q_VALUE);
        $display("omega = 13482285337619, omega_inv = 11888153632024");
        $display("N_INV = %0d", N_INV);
        $display("Vectors: %0d  |  Coeffs/vector: %0d", NUM_TESTS, N);
        $display("========================================================");

        start      = 1'b0;
        a_in_valid = 1'b0;
        b_in_valid = 1'b0;
        a_in_data  = '0;
        b_in_data  = '0;
        out_ready  = 1'b0;

        wait (rst_n === 1'b1);
        @(posedge clk);
        #50;

        for (integer v = 0; v < NUM_TESTS; v = v + 1) begin
            $display("  [vec %0d] start @ %0t ...", v, $time);
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            fork
                input_A(v);
                input_B(v);
                output_C;
            join

            wait (done === 1'b1);

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
                    $display("  vec%0d: PASS (%0d/%0d) @ %0t", v, N, N, $time);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("  vec%0d: FAIL (%0d/%0d mismatches)", v, errs, N);
                    fail_cnt = fail_cnt + 1;
                end
            end

            @(posedge clk);
        end

        $display("");
        $display("========================================================");
        $display("SUMMARY - poly_mult N=2^12 (q3, USE_FASTRED=1)");
        $display("========================================================");
        $display("  PASS: %0d/%0d", pass_cnt, NUM_TESTS);
        $display("  FAIL: %0d/%0d", fail_cnt, NUM_TESTS);
        $display("========================================================");

        if (fail_cnt == 0) begin
            $display("*** ALL TESTS PASSED (%0d vectors, %0d coeffs each) ***",
                     NUM_TESTS, N);
            $display("*** N=2^12 + q3 + fast-red 功能基线建立 ***");
        end else begin
            $display("*** %0d/%0d FAILED ***", fail_cnt, NUM_TESTS);
        end
        $display("========================================================");

        #100;
        $finish;
    end

    // =========================================================================
    // 看门狗（N=4096，4 向量，留足余量）
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 8000000);
        $display("");
        $display("*** TIMEOUT - Test did not complete ***");
        $finish;
    end

endmodule

`default_nettype wire
