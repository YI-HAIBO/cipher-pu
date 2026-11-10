`timescale 1ns / 1ps
`default_nettype none
module tb_e2e_rns;
    // B-6: REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径；默认中性相对路径
    parameter string REPO_ROOT = ".";

    localparam int LOG_N = 4;
    localparam int N     = 16;
    localparam int QW    = 42;
    localparam int MW    = 115;
    localparam int NT    = 3;
    localparam real CLK_PERIOD = 10.0;

    logic clk, rst_n;
    logic start, busy, done, error;
    logic [MW-1:0] a_in_data, b_in_data, out_data;
    logic a_in_valid, a_in_ready, b_in_valid, b_in_ready;
    logic out_valid, out_last, out_ready;

    // 参考向量
    logic [MW-1:0] mem_a   [0:NT*N-1];
    logic [MW-1:0] mem_b   [0:NT*N-1];
    logic [MW-1:0] exp_out [0:NT*N-1];
    logic [MW-1:0] obuf    [0:N-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 时钟 / 复位
    initial begin clk = 0; forever #5 clk = ~clk; end
    initial begin rst_n = 0; #20; rst_n = 1; end

    e2e_rns_top #(
        .LOG_N(LOG_N), .N(N), .P_WIDTH(QW), .M_WIDTH(MW), .SCALE(1024),
        .W1(115'h38477b0357aa2be2be3fa0154725f), .W2(115'h047ffffffffa66666662622222222), .W3(115'h287884fcb04d6db6db801dc896b81), .M(115'h6540000007f200000022200000001),
        .P1(42'd77309411329), .P2(42'd206158430209), .P3(42'd2061584302081),
        .N_INV1(42'd72477573121), .N_INV2(42'd193273528321), .N_INV3(42'd1932735283201),
        .TW_ROOT({REPO_ROOT, "/rtl/m5/tw"})
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done), .error(error),
        .a_in_data(a_in_data), .a_in_valid(a_in_valid), .a_in_ready(a_in_ready),
        .b_in_data(b_in_data), .b_in_valid(b_in_valid), .b_in_ready(b_in_ready),
        .out_data(out_data), .out_valid(out_valid), .out_last(out_last),
        .out_ready(out_ready)
    );

    // 参考向量加载
    initial begin
        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs/a.hex"}, mem_a);
        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs/b.hex"}, mem_b);
        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs/exp.hex"}, exp_out);
    end

    // =============== 输入任务（negedge 驱动）===============
    // 时序对齐分析：a_in_ready 在 DUT 进入 S_IN_A 的下一 posedge 置 1；
    // wait 解析于该 posedge 的 NBA 区，随后第一个 @(negedge clk) 即同一周期
    // 的下降沿，此时给出 mem[0]；写发生在下一 posedge（write #0）。
    // 之后每个 negedge 给出 mem[i]，下一 posedge 写入 mem[i]，共 N 次。
    task automatic drive_A(input integer v);
        integer i;
        begin
            wait (a_in_ready === 1'b1);
            a_in_valid = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                @(negedge clk);
                a_in_data = mem_a[v*N + i];
            end
            @(negedge clk);
            a_in_valid = 1'b0;
        end
    endtask

    task automatic drive_B(input integer v);
        integer i;
        begin
            wait (b_in_ready === 1'b1);
            b_in_valid = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                @(negedge clk);
                b_in_data = mem_b[v*N + i];
            end
            @(negedge clk);
            b_in_valid = 1'b0;
        end
    endtask

    // =============== 输出任务（posedge 采样寄存器输出）===============
    task automatic collect_out(input integer v);
        integer i;
        begin
            i = 0;
            while (i < N) begin
                @(posedge clk);
                if (out_valid === 1'b1) begin
                    obuf[i] = out_data;
                    i = i + 1;
                end
            end
        end
    endtask

    // =============== 主测试 ===============
    initial begin
        start = 1'b0;
        a_in_valid = 1'b0; b_in_valid = 1'b0;
        a_in_data = '0;    b_in_data = '0;
        out_ready = 1'b1;
        wait (rst_n === 1'b1);
        @(posedge clk);
        #50;

        for (integer v = 0; v < NT; v = v + 1) begin
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            fork
                drive_A(v);
                drive_B(v);
                collect_out(v);
            join

            begin : cmp_blk
                integer i, errs;
                errs = 0;
                for (i = 0; i < N; i = i + 1) begin
                    if (obuf[i] !== exp_out[v*N+i]) begin
                        errs = errs + 1;
                        if (errs <= 3)
                            $display("  [MISMATCH] v%0d i=%0d got=%h want=%h",
                                     v, i, obuf[i], exp_out[v*N+i]);
                    end
                end
                if (error) begin
                    $display("  [ERROR FLAG] v%0d pm_error asserted", v);
                    errs = errs + 1;
                end
                if (errs == 0) begin
                    $display("  vec%0d: PASS (%0d coefficients, 115-bit)", v, N);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("  vec%0d: FAIL (%0d mismatches)", v, errs);
                    fail_cnt = fail_cnt + 1;
                end
            end
            wait (done === 1'b1);
            // pm 内部回 IDLE 需 >1 拍，多 test 衔接留余量
            repeat (20) @(posedge clk);
        end

        $display("");
        $display("=== e2e_rns_top: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("RESULT: ALL PASS");
        else $display("RESULT: %0d FAILED", fail_cnt);
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 300000);
        $display("TIMEOUT");
        $finish;
    end
endmodule
