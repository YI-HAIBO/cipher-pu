// =============================================================================
// tb_pm_n8.sv — poly_mult N=8 隔离验证（任务 3 诊断，2026-10-18）
//
// 目的：m4e2e 只在 N=16 玩具配置下验证过 poly_mult 数值正确性；
//   b_layer_ctrl 用 LOG_N=3/N=8，其输出与循环卷积 golden 不符，
//   用本 TB 隔离 poly_mult 在 N=8 下是否正确。
//
// a = [0,1,2,3,4,5,6,7], b = [1,3,5,7,9,11,13,15], q=113
// 期望 C[k] = sum_j a[j]*b[(k-j) mod 8] mod 113
//   = [83, 10, 34, 42, 34, 10, 83, 27]
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_pm_n8;

    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";

    localparam int LOG_N   = 3;
    localparam int N       = 8;
    localparam int Q_WIDTH = 7;
    localparam logic [Q_WIDTH-1:0] Q_VALUE = 7'd113;
    localparam logic [Q_WIDTH-1:0] N_INV   = 7'd99;

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
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n8.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n8.hex"})
    ) uut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done), .error(error),
        .a_in_data(a_in_data), .a_in_valid(a_in_valid), .a_in_ready(a_in_ready),
        .b_in_data(b_in_data), .b_in_valid(b_in_valid), .b_in_ready(b_in_ready),
        .out_data(out_data), .out_valid(out_valid), .out_last(out_last),
        .out_ready(out_ready)
    );

    integer i, timeout, cap;
    logic [Q_WIDTH-1:0] outs[0:N-1];

    initial begin

        a_in_valid = 0;
        b_in_valid = 0;
        out_ready  = 1;
        start      = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // start 脉冲
        @(negedge clk);
        start = 1;
        @(posedge clk);
        #1;
        start = 0;

        // a 流（ready 门控：poly_mult 进入 S_INPUT_A 后一拍才拉 a_in_ready，
        //   首拍驱动会被丢弃 → 必须等 ready 为高再发）
        @(negedge clk);
        for (i = 0; i < N; i = i + 1) begin
            while (!a_in_ready) @(negedge clk);
            a_in_data  = i;
            a_in_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            a_in_valid = 1'b0;
        end

        // b 流（同样 ready 门控）
        @(negedge clk);
        for (i = 0; i < N; i = i + 1) begin
            while (!b_in_ready) @(negedge clk);
            b_in_data  = (2*i+1) % 113;
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
            if (timeout < 60 || timeout % 2000 == 0)
                $display("tb_pm_n8: t=%0d state=%0d aidx=%0d a_rdy=%b a_v=%b b_rdy=%b b_v=%b cap=%0d",
                         timeout, uut.state, uut.a_in_idx, a_in_ready, a_in_valid,
                         b_in_ready, b_in_valid, cap);
            timeout = timeout + 1;
        end

        $display("tb_pm_n8: done=%b error=%b cycles=%0d captured=%0d",
                 done, error, timeout, cap);
        // 中间存储转储：a_mem / b_mem / a_hat / b_hat / c_hat
        for (i = 0; i < N; i = i + 1)
            $display("tb_pm_n8: DUMP a_mem[%0d]=%0d b_mem[%0d]=%0d a_hat[%0d]=%0d b_hat[%0d]=%0d c_hat[%0d]=%0d",
                     i, uut.u_a_mem.mem[i], i, uut.u_b_mem.mem[i],
                     i, uut.u_a_hat_mem.mem[i], i, uut.u_b_hat_mem.mem[i],
                     i, uut.u_c_hat_mem.mem[i]);
        $display("tb_pm_n8: got      [%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                 outs[0], outs[1], outs[2], outs[3], outs[4], outs[5], outs[6], outs[7]);
        $display("tb_pm_n8: expected  [83,10,34,42,34,10,83,27]");
        if (outs[0] == 83 && outs[1] == 10 && outs[2] == 34 && outs[3] == 42 &&
            outs[4] == 34 && outs[5] == 10 && outs[6] == 83 && outs[7] == 27)
            $display("tb_pm_n8: PASS");
        else
            $display("tb_pm_n8: FAIL");
        $finish;
    end

    initial begin
        #2000000;
        $display("tb_pm_n8: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
