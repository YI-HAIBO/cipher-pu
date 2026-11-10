`timescale 1ns / 1ps
`default_nettype none
module tb_rns_merge;
    // B-6: REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径；默认中性相对路径
    parameter string REPO_ROOT = ".";
    parameter P_WIDTH = 42;
    parameter M_WIDTH = 115;
    parameter int N_VEC = 20;

    logic clk, rst_n;
    logic s_valid, s_ready, m_valid, m_ready;
    logic [P_WIDTH-1:0] s_data_p1, s_data_p2, s_data_p3;
    logic [M_WIDTH-1:0] m_data;

    rns_merge #(
        .P_WIDTH(P_WIDTH),
        .M_WIDTH(M_WIDTH),
        .ACC_WIDTH(M_WIDTH + P_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data_p1(s_data_p1), .s_data_p2(s_data_p2), .s_data_p3(s_data_p3),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer i, pass_cnt, fail_cnt, fd;
    logic [M_WIDTH-1:0] rx;          // 期望值 = CRT(x1,x2,x3) = x
    logic [P_WIDTH-1:0] rx1, rx2, rx3;

    initial begin
        rst_n = 0;
        s_valid = 0;
        s_data_p1 = 0; s_data_p2 = 0; s_data_p3 = 0;
        m_ready = 1;
        pass_cnt = 0; fail_cnt = 0;
        #20 rst_n = 1;
        #10;

        fd = $fopen({REPO_ROOT, "/scripts/_e37_rns_vec.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open vector file");
            $finish;
        end
        for (i = 0; i < N_VEC; i = i + 1) begin
            $fscanf(fd, "%h %h %h %h", rx, rx1, rx2, rx3);
            @(negedge clk);
            s_data_p1 = rx1;
            s_data_p2 = rx2;
            s_data_p3 = rx3;
            s_valid = 1;
            @(negedge clk);
            s_valid = 0;
            // 2 级流水：m_valid 在 2 个 posedge 后拉高
            wait(m_valid == 1'b1);
            @(negedge clk);
            if (m_data === rx) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: i=%0d got=%h exp=%h", i, m_data, rx);
            end
        end
        $fclose(fd);
        $display("=== rns_merge: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("RESULT: ALL PASS");
        else $display("RESULT: %0d FAILED", fail_cnt);
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
