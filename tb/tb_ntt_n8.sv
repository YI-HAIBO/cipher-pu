// =============================================================================
// tb_ntt_n8.sv — ntt_unit N=8 隔离验证（任务 3 诊断，2026-10-18）
//
// 输入 a = [0,1,2,3,4,5,6,7]（op_mode=0 NTT）
// 期望 DFT (q=113, w=18)：[28, 47, 56, 40, 109, 65, 49, 58]
// 同时转储内部 mem：输入端 bit-reversal 后应为 [0,4,2,6,1,5,3,7]
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_ntt_n8;
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

    logic                     start, op_mode, busy, done, error;
    logic [Q_WIDTH-1:0]       in_data;
    logic                     in_valid, in_ready;
    logic [Q_WIDTH-1:0]       out_data;
    logic                     out_valid, out_last, out_ready;

    ntt_unit #(
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
        .start(start), .op_mode(op_mode),
        .busy(busy), .done(done), .error(error),
        .in_data(in_data), .in_valid(in_valid), .in_ready(in_ready),
        .out_data(out_data), .out_valid(out_valid), .out_last(out_last),
        .out_ready(out_ready)
    );

    integer i, timeout, cap;
    logic [Q_WIDTH-1:0] outs[0:N-1];

    initial begin

        in_valid  = 0;
        out_ready = 1;
        start     = 0;
        op_mode   = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        @(negedge clk);
        start = 1;
        @(posedge clk);
        #1;
        start = 0;

        // 输入流（ready 门控）
        @(negedge clk);
        for (i = 0; i < N; i = i + 1) begin
            while (!in_ready) @(negedge clk);
            in_data  = i;
            in_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            in_valid = 1'b0;
        end

        cap    = 0;
        timeout = 0;
        // 采满 N 个输出才退出；done 早于末拍 out_valid 拉高，若按 done 退出会漏采 out[7]。
        while (cap < N && timeout < 10000) begin
            @(posedge clk);
            if (out_valid) begin
                outs[cap] = out_data;
                cap = cap + 1;
            end
            timeout = timeout + 1;
        end

        $display("tb_ntt_n8: done=%b error=%b cycles=%0d cap=%0d", done, error, timeout, cap);
        // 转储内部存储（输入 BR 后应为 [0,4,2,6,1,5,3,7]，计算后为 DFT 自然序）
        for (i = 0; i < N; i = i + 1)
            $display("tb_ntt_n8: DUMP mem[%0d]=%0d", i, uut.u_mem.g_auto.mem[i]);
        $display("tb_ntt_n8: out  [%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                 outs[0], outs[1], outs[2], outs[3], outs[4], outs[5], outs[6], outs[7]);
        $display("tb_ntt_n8: exp  [28,47,56,40,109,65,49,58]");
        // 逐位判定（runner 依据此行判 PASS/FAIL）
        begin
            automatic integer gold8 [0:7] = '{28, 47, 56, 40, 109, 65, 49, 58};
            automatic integer np = 0;
            automatic integer nf = 0;
            for (i = 0; i < N; i = i + 1) begin
                if (outs[i] === gold8[i]) np = np + 1;
                else begin
                    nf = nf + 1;
                    $display("tb_ntt_n8: MISMATCH out[%0d] got %0d exp %0d", i, outs[i], gold8[i]);
                end
            end
            $display("tb_ntt_n8: PASS: %0d / FAIL: %0d", np, nf);
            if (nf == 0) $display("tb_ntt_n8: PASS");
            else         $display("tb_ntt_n8: FAIL");
        end
        $finish;
    end

    initial begin
        #500000;
        $display("tb_ntt_n8: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
