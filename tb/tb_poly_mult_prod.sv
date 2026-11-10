//=============================================================================
// tb_poly_mult_prod.sv — poly_mult 生产配置功能测试平台（M2-c 收官）
//
// 配置（USE_FASTRED=1 路径）：
//   N = 16, LOG_N = 4
//   Q_WIDTH = 45, Q_VALUE = 17592186175489 = 2^44 + 131073
//   twiddle 因子（omega=17474076998581, omega_inv=13203937673276）由 TW_FILE 加载
//   N_INV = 16492674539521
//
// 与玩具 TB 的差异：
//   1. Q_WIDTH = 45（玩具 7）
//   2. Q_VALUE = 17592186175489（玩具 113）
//   3. USE_FASTRED = 1（走 mod45_fastred 路径，替代 % 组合取模）
//   4. twiddle 因子由 TW_FILE / TW_INV_FILE 加载（生产值）
//   5. hex 文件名 poly_a_prod.hex / poly_b_prod.hex / poly_expected_prod.hex
//
// 目标：验证 fast-red 归约 + 45-bit 位宽 + 生产 q 组合下，
//       poly_mult 全流程（NTT → 点乘 → INTT）与 Python 参考逐系数对齐。
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_poly_mult_prod;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    // =========================================================================
    // 参数
    //   注意：Q_VALUE / N_INV 都是 45 bit，不能用 int（32-bit 会静默截断，
    //   把 17592186175489 截成 131073，导致所有模运算错乱）
    // =========================================================================
    localparam int                  LOG_N       = 4;
    localparam int                  N           = 1 << LOG_N;
    localparam int                  Q_WIDTH     = 45;
    localparam logic [Q_WIDTH-1:0]  Q_VALUE     = 45'd17592186175489;   // 2^44 + 131073
    localparam logic [Q_WIDTH-1:0]  N_INV       = 45'd16492674539521;
    localparam int                  USE_FASTRED = 1;
    localparam int                  NUM_TESTS   = 10;
    localparam real                 CLK_PERIOD  = 10.0;   // 100 MHz

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
        .USE_FASTRED(USE_FASTRED),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_q3_n16.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_q3_n16.hex"})
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
        $readmemh($sformatf("%s/poly_a_prod.hex",        tbdir), ref_a);
        $readmemh($sformatf("%s/poly_b_prod.hex",        tbdir), ref_b);
        $readmemh($sformatf("%s/poly_expected_prod.hex", tbdir), ref_c);
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
    // DEBUG 状态机跟踪
    // =========================================================================
    logic [2:0] prev_state = 'x;
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if (u_dut.state !== prev_state || u_dut.state == 6 || u_dut.state == 4) begin
                $display("t=%0t SM=%0d(%s) ph=%b feed=%0d col=%0d nttSM=%0d nOutV=%b nOutR=%b outV=%b done=%b",
                    $time, u_dut.state,
                    (u_dut.state==0 ? "IDLE"    : u_dut.state==1 ? "IN_A"   :
                     u_dut.state==2 ? "IN_B"    : u_dut.state==3 ? "NTT_A"  :
                     u_dut.state==4 ? "NTT_B"   : u_dut.state==5 ? "MUL"    :
                     u_dut.state==6 ? "INTT"    : u_dut.state==7 ? "DONE"   : "?"),
                    u_dut.ntt_phase,
                    u_dut.ntt_feeder_idx, u_dut.ntt_collector_idx,
                    u_dut.u_ntt.state,
                    u_dut.ntt_out_valid, u_dut.ntt_out_ready,
                    u_dut.out_valid, u_dut.done);
                prev_state = u_dut.state;
            end
        end
    end

    // =========================================================================
    // 主测试流程
    // =========================================================================
    initial begin
        $display("========================================================");
        $display("Poly Mult PROD Testbench (M2-c 生产配置)");
        $display("N=%0d LOG_N=%0d Q_WIDTH=%0d USE_FASTRED=%0d", N, LOG_N, Q_WIDTH, USE_FASTRED);
        $display("q = %0d (2^44 + 131073)", Q_VALUE);
        $display("twiddle: TW_FILE/TW_INV_FILE, N_INV = %0d", N_INV);
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
                    $display("  vec%0d: PASS (%0d/%0d)", v, N, N);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("  vec%0d: FAIL (%0d/%0d mismatches)", v, errs, N);
                    fail_cnt = fail_cnt + 1;
                end
            end

            @(posedge clk);
        end

        // =========================================================================
        // 汇总
        // =========================================================================
        $display("");
        $display("========================================================");
        $display("SUMMARY - M2-c poly_mult PROD (USE_FASTRED=1)");
        $display("========================================================");
        $display("  PASS: %0d/%0d", pass_cnt, NUM_TESTS);
        $display("  FAIL: %0d/%0d", fail_cnt, NUM_TESTS);
        $display("========================================================");

        if (fail_cnt == 0) begin
            $display("*** ALL TESTS PASSED (%0d vectors, %0d coeffs each) ***",
                     NUM_TESTS, N);
            $display("*** fast-red 生产路径端到端验证通过 ***");
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
        #(CLK_PERIOD * 400000);
        $display("");
        $display("*** TIMEOUT - Test did not complete ***");
        $finish;
    end

endmodule

`default_nettype wire
