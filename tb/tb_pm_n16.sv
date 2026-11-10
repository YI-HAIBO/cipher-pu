// =============================================================================
// tb_pm_n16.sv — poly_mult N=16 隔离验证（m4e2e Gear 0 golden 定位，2026-10-18）
//
// 目的：m4e2e Gear 0 值级 golden 与独立 Python 模型不符，DUT m2(c1_1*c1_2)
//   不是循环卷积。用本 TB 隔离 poly_mult 在 N=16 下是否数值正确。
//   输入直接复用 e2e TB 的 pm2 向量：
//     a = c1_1 = (2i+1) mod 113 = [1,3,5,...,31]
//     b = c1_2 = (4i+3) mod 113 = [3,7,11,...,63]
//   期望 C[k] = sum_j a[j]*b[(k-j) mod 16] mod 113
//     = [21,62,88,99,95,76,42,106,42,76,95,99,88,62,21,78]
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_pm_n16;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    localparam int LOG_N   = 4;
    localparam int N       = 16;
    localparam int Q_WIDTH = 7;
    localparam logic [Q_WIDTH-1:0] Q_VALUE = 7'd113;
    localparam logic [Q_WIDTH-1:0] N_INV   = 7'd106;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic                     start, busy, done, error;
    logic [Q_WIDTH-1:0]       a_in_data, b_in_data;
    logic                     a_in_valid, a_in_ready;
    logic                     b_in_valid, b_in_ready;
    logic [Q_WIDTH-1:0]       out_data;
    logic                     out_valid, out_last, out_ready;

    poly_mult #(
        .LOG_N      (LOG_N),
        .N          (N),
        .Q_WIDTH    (Q_WIDTH),
        .Q_VALUE    (Q_VALUE),
        .N_INV      (N_INV),
        .USE_FASTRED(1'b0),
        .USE_BRAM_IP(1'b0),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"})
    ) uut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done), .error(error),
        .a_in_data(a_in_data), .a_in_valid(a_in_valid), .a_in_ready(a_in_ready),
        .b_in_data(b_in_data), .b_in_valid(b_in_valid), .b_in_ready(b_in_ready),
        .out_data(out_data), .out_valid(out_valid), .out_last(out_last),
        .out_ready(out_ready)
    );

    integer i, timeout, cap, mism;
    logic [Q_WIDTH-1:0] outs[0:N-1];
    integer expected[0:15];

    initial begin

        expected[0]=21;  expected[1]=62;  expected[2]=88;  expected[3]=99;
        expected[4]=95;  expected[5]=76;  expected[6]=42;  expected[7]=106;
        expected[8]=42;  expected[9]=76;  expected[10]=95; expected[11]=99;
        expected[12]=88; expected[13]=62; expected[14]=21; expected[15]=78;

        a_in_valid = 0;
        b_in_valid = 0;
        out_ready  = 1;
        start      = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // start 脉冲（negedge 驱动，避开 posedge 竞争）
        @(negedge clk);
        start = 1;
        @(posedge clk);
        #1;
        start = 0;

        // a 流
        @(negedge clk);
        for (i = 0; i < N; i = i + 1) begin
            while (!a_in_ready) @(negedge clk);
            a_in_data  = (2*i+1) % 113;
            a_in_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            a_in_valid = 1'b0;
        end

        // b 流
        @(negedge clk);
        for (i = 0; i < N; i = i + 1) begin
            while (!b_in_ready) @(negedge clk);
            b_in_data  = (4*i+3) % 113;
            b_in_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            b_in_valid = 1'b0;
        end

        cap    = 0;
        timeout = 0;
        while (!done && timeout < 50000) begin
            @(posedge clk);
            if (out_valid) begin
                outs[cap] = out_data;
                cap = cap + 1;
            end
            timeout = timeout + 1;
        end

        $display("tb_pm_n16: done=%b error=%b cycles=%0d captured=%0d",
                 done, error, timeout, cap);
        for (i = 0; i < N; i = i + 1)
            $display("tb_pm_n16: DUMP a_mem[%0d]=%0d b_mem[%0d]=%0d a_hat[%0d]=%0d b_hat[%0d]=%0d c_hat[%0d]=%0d",
                     i, uut.u_a_mem.mem[i], i, uut.u_b_mem.mem[i],
                     i, uut.u_a_hat_mem.mem[i], i, uut.u_b_hat_mem.mem[i],
                     i, uut.u_c_hat_mem.mem[i]);
        $display("tb_pm_n16: got      [%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                 outs[0], outs[1], outs[2], outs[3], outs[4], outs[5], outs[6], outs[7],
                 outs[8], outs[9], outs[10], outs[11], outs[12], outs[13], outs[14], outs[15]);
        $display("tb_pm_n16: expected [21,62,88,99,95,76,42,106,42,76,95,99,88,62,21,78]");
        mism = 0;
        for (i = 0; i < N; i = i + 1)
            if (outs[i] !== expected[i]) mism = mism + 1;
        if (mism == 0)
            $display("tb_pm_n16: PASS");
        else
            $display("tb_pm_n16: FAIL (%0d/16 mismatch)", mism);
        $finish;
    end

    initial begin
        #3000000;
        $display("tb_pm_n16: TIMEOUT");
        $finish;
    end

    // NTT 交易级轨迹（NTT_A/NTT_B 各前 30 拍，供 e2e pm2 对照）
    integer trac_cnt;
    logic trac_done;
    initial begin
        trac_cnt = 0; trac_done = 1'b0;
        forever begin
            @(posedge clk);
            if (rst_n && (uut.state == 3'd3 || uut.state == 3'd4) && trac_cnt < 60) begin
                $display("[N16TRC] t=%0t pmstate=%0d nttstate=%0d ph=%b fid=%0d inv=%b inr=%b ind=%0d memra=%0d colidx=%0d",
                    $time, uut.state, uut.u_ntt.state, uut.ntt_phase,
                    uut.ntt_feeder_idx, uut.ntt_in_valid, uut.u_ntt.in_ready,
                    uut.ntt_in_data, uut.a_mem_r, uut.ntt_collector_idx);
                trac_cnt = trac_cnt + 1;
            end
            // S_NTT_A→S_NTT_B 瞬间：转储 ntt 内部 mem 与 a_hat
            if (rst_n && uut.state == 3'd4 && !trac_done) begin
                trac_done = 1'b1;
                $display("[N16NTT-MEM] mem=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    uut.u_ntt.u_mem.g_auto.mem[0], uut.u_ntt.u_mem.g_auto.mem[1],
                    uut.u_ntt.u_mem.g_auto.mem[2], uut.u_ntt.u_mem.g_auto.mem[3],
                    uut.u_ntt.u_mem.g_auto.mem[4], uut.u_ntt.u_mem.g_auto.mem[5],
                    uut.u_ntt.u_mem.g_auto.mem[6], uut.u_ntt.u_mem.g_auto.mem[7],
                    uut.u_ntt.u_mem.g_auto.mem[8], uut.u_ntt.u_mem.g_auto.mem[9],
                    uut.u_ntt.u_mem.g_auto.mem[10], uut.u_ntt.u_mem.g_auto.mem[11],
                    uut.u_ntt.u_mem.g_auto.mem[12], uut.u_ntt.u_mem.g_auto.mem[13],
                    uut.u_ntt.u_mem.g_auto.mem[14], uut.u_ntt.u_mem.g_auto.mem[15]);
                $display("[N16NTT-AHAT] a_hat=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    uut.u_a_hat_mem.mem[0], uut.u_a_hat_mem.mem[1],
                    uut.u_a_hat_mem.mem[2], uut.u_a_hat_mem.mem[3],
                    uut.u_a_hat_mem.mem[4], uut.u_a_hat_mem.mem[5],
                    uut.u_a_hat_mem.mem[6], uut.u_a_hat_mem.mem[7],
                    uut.u_a_hat_mem.mem[8], uut.u_a_hat_mem.mem[9],
                    uut.u_a_hat_mem.mem[10], uut.u_a_hat_mem.mem[11],
                    uut.u_a_hat_mem.mem[12], uut.u_a_hat_mem.mem[13],
                    uut.u_a_hat_mem.mem[14], uut.u_a_hat_mem.mem[15]);
            end
        end
    end

endmodule

`default_nettype wire
