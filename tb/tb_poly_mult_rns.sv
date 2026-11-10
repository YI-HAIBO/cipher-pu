`timescale 1ns / 1ps
`default_nettype none
module tb_poly_mult_rns;
    // B-6: REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径；默认中性相对路径
    parameter string REPO_ROOT = ".";
    localparam int LOG_N = 4;
    localparam int N     = 16;
    localparam int QW    = 42;
    localparam int NT    = 3;
    localparam real CLK_PERIOD = 10.0;

    logic clk, rst_n;
    logic start, busy, done, error;

    // 3 路 A 输入
    logic [QW-1:0] a_d1; logic a_v1; logic a_r1;
    logic [QW-1:0] a_d2; logic a_v2; logic a_r2;
    logic [QW-1:0] a_d3; logic a_v3; logic a_r3;
    // 3 路 B 输入
    logic [QW-1:0] b_d1; logic b_v1; logic b_r1;
    logic [QW-1:0] b_d2; logic b_v2; logic b_r2;
    logic [QW-1:0] b_d3; logic b_v3; logic b_r3;
    // 3 路 C 输出
    logic [QW-1:0] o_d1; logic o_v1; logic o_l1; logic o_r1;
    logic [QW-1:0] o_d2; logic o_v2; logic o_l2; logic o_r2;
    logic [QW-1:0] o_d3; logic o_v3; logic o_l3; logic o_r3;

    // 参考向量（9 个数组）
    logic [QW-1:0] ra1 [0:NT*N-1], rb1 [0:NT*N-1], rc1 [0:NT*N-1];
    logic [QW-1:0] ra2 [0:NT*N-1], rb2 [0:NT*N-1], rc2 [0:NT*N-1];
    logic [QW-1:0] ra3 [0:NT*N-1], rb3 [0:NT*N-1], rc3 [0:NT*N-1];

    // 收集输出
    logic [QW-1:0] ob1 [0:N-1], ob2 [0:N-1], ob3 [0:N-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 时钟 / 复位
    initial begin clk = 0; forever #5 clk = ~clk; end
    initial begin rst_n = 0; #20; rst_n = 1; end

    // DUT
    poly_mult_rns #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(QW),
        .P1(42'd77309411329), .P2(42'd206158430209), .P3(42'd2061584302081),
        .N_INV1(42'd72477573121), .N_INV2(42'd193273528321), .N_INV3(42'd1932735283201),
        .TW_ROOT({REPO_ROOT, "/rtl/m5/tw"})
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done), .error(error),
        .a_in_data_p1(a_d1), .a_in_valid_p1(a_v1), .a_in_ready_p1(a_r1),
        .a_in_data_p2(a_d2), .a_in_valid_p2(a_v2), .a_in_ready_p2(a_r2),
        .a_in_data_p3(a_d3), .a_in_valid_p3(a_v3), .a_in_ready_p3(a_r3),
        .b_in_data_p1(b_d1), .b_in_valid_p1(b_v1), .b_in_ready_p1(b_r1),
        .b_in_data_p2(b_d2), .b_in_valid_p2(b_v2), .b_in_ready_p2(b_r2),
        .b_in_data_p3(b_d3), .b_in_valid_p3(b_v3), .b_in_ready_p3(b_r3),
        .out_data_p1(o_d1), .out_valid_p1(o_v1), .out_last_p1(o_l1), .out_ready_p1(o_r1),
        .out_data_p2(o_d2), .out_valid_p2(o_v2), .out_last_p2(o_l2), .out_ready_p2(o_r2),
        .out_data_p3(o_d3), .out_valid_p3(o_v3), .out_last_p3(o_l3), .out_ready_p3(o_r3)
    );

    // 向量加载
    initial begin
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/a_p1.hex"}, ra1);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/b_p1.hex"}, rb1);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/c_p1.hex"}, rc1);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/a_p2.hex"}, ra2);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/b_p2.hex"}, rb2);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/c_p2.hex"}, rc2);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/a_p3.hex"}, ra3);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/b_p3.hex"}, rb3);
        $readmemh({REPO_ROOT, "/scripts/_e37_pm_rns_vecs/c_p3.hex"}, rc3);
    end

    // 输入/输出任务（直接引用模块级信号）
task automatic inputA_1(input integer v);
    integer i;
    integer got;
    begin
        a_v1 = 1'b1;
        a_d1 = ra1[v*N + 0];
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (a_r1) got = 1;
            end
            if (i < N - 1) begin
                #1;
                a_d1 = ra1[v*N + i + 1];
            end
        end
        #1;
        a_v1 = 1'b0;
    end
endtask
task automatic inputA_2(input integer v);
    integer i;
    integer got;
    begin
        a_v2 = 1'b1;
        a_d2 = ra2[v*N + 0];
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (a_r2) got = 1;
            end
            if (i < N - 1) begin
                #1;
                a_d2 = ra2[v*N + i + 1];
            end
        end
        #1;
        a_v2 = 1'b0;
    end
endtask
task automatic inputA_3(input integer v);
    integer i;
    integer got;
    begin
        a_v3 = 1'b1;
        a_d3 = ra3[v*N + 0];
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (a_r3) got = 1;
            end
            if (i < N - 1) begin
                #1;
                a_d3 = ra3[v*N + i + 1];
            end
        end
        #1;
        a_v3 = 1'b0;
    end
endtask
task automatic inputB_1(input integer v);
    integer i;
    integer got;
    begin
        b_v1 = 1'b1;
        b_d1 = rb1[v*N + 0];
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (b_r1) got = 1;
            end
            if (i < N - 1) begin
                #1;
                b_d1 = rb1[v*N + i + 1];
            end
        end
        #1;
        b_v1 = 1'b0;
    end
endtask
task automatic inputB_2(input integer v);
    integer i;
    integer got;
    begin
        b_v2 = 1'b1;
        b_d2 = rb2[v*N + 0];
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (b_r2) got = 1;
            end
            if (i < N - 1) begin
                #1;
                b_d2 = rb2[v*N + i + 1];
            end
        end
        #1;
        b_v2 = 1'b0;
    end
endtask
task automatic inputB_3(input integer v);
    integer i;
    integer got;
    begin
        b_v3 = 1'b1;
        b_d3 = rb3[v*N + 0];
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (b_r3) got = 1;
            end
            if (i < N - 1) begin
                #1;
                b_d3 = rb3[v*N + i + 1];
            end
        end
        #1;
        b_v3 = 1'b0;
    end
endtask
task automatic outputC_1;
    integer i;
    integer got;
    begin
        o_r1 = 1'b1;
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (o_v1) got = 1;
            end
            ob1[i] = o_d1;
            if (o_l1) o_r1 = 1'b0;
        end
    end
endtask
task automatic outputC_2;
    integer i;
    integer got;
    begin
        o_r2 = 1'b1;
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (o_v2) got = 1;
            end
            ob2[i] = o_d2;
            if (o_l2) o_r2 = 1'b0;
        end
    end
endtask
task automatic outputC_3;
    integer i;
    integer got;
    begin
        o_r3 = 1'b1;
        for (i = 0; i < N; i = i + 1) begin
            got = 0;
            while (!got) begin
                @(posedge clk);
                if (o_v3) got = 1;
            end
            ob3[i] = o_d3;
            if (o_l3) o_r3 = 1'b0;
        end
    end
endtask

    // 主测试
    initial begin
        start = 1'b0;
        a_v1=0; a_v2=0; a_v3=0;
        b_v1=0; b_v2=0; b_v3=0;
        a_d1='0; a_d2='0; a_d3='0;
        b_d1='0; b_d2='0; b_d3='0;
        o_r1=0; o_r2=0; o_r3=0;
        wait (rst_n === 1'b1);
        @(posedge clk);
        #50;

        for (integer v = 0; v < NT; v = v + 1) begin
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            fork
                inputA_1(v);
                inputA_2(v);
                inputA_3(v);
                inputB_1(v);
                inputB_2(v);
                inputB_3(v);
                outputC_1;
                outputC_2;
                outputC_3;
            join
            wait (done === 1'b1);

            begin : cmp_blk
                integer i, errs;
                errs = 0;
                for (i = 0; i < N; i = i + 1) begin
                    if (ob1[i] !== rc1[v*N+i]) begin errs = errs + 1;
                        if (errs<=3) $display("  [P1 MISMATCH] v%0d i=%0d got=%h want=%h", v, i, ob1[i], rc1[v*N+i]); end
                    if (ob2[i] !== rc2[v*N+i]) begin errs = errs + 1;
                        if (errs<=3) $display("  [P2 MISMATCH] v%0d i=%0d got=%h want=%h", v, i, ob2[i], rc2[v*N+i]); end
                    if (ob3[i] !== rc3[v*N+i]) begin errs = errs + 1;
                        if (errs<=3) $display("  [P3 MISMATCH] v%0d i=%0d got=%h want=%h", v, i, ob3[i], rc3[v*N+i]); end
                end
                if (errs == 0) begin
                    $display("  vec%0d: PASS (3 lanes x %0d)", v, N);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("  vec%0d: FAIL (%0d mismatches)", v, errs);
                    fail_cnt = fail_cnt + 1;
                end
            end
            // 多 test 衔接诊断：加长回 IDLE 时间
            repeat(10) @(posedge clk);
        end

        $display("");
        $display("=== poly_mult_rns: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("RESULT: ALL PASS");
        else $display("RESULT: %0d FAILED", fail_cnt);
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 200000);
        $display("TIMEOUT");
        $finish;
    end
endmodule
