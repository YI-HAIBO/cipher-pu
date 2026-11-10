`timescale 1ns / 1ps
`default_nettype none
module tb_rns_split;
    // B-6: REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径；默认中性相对路径
    parameter string REPO_ROOT = ".";
    parameter Q_IN_WIDTH = 115;
    parameter P_WIDTH    = 42;
    parameter int N_VEC = 20;

    logic clk, rst_n;
    logic s_valid, s_ready, m_valid, m_ready;
    logic [Q_IN_WIDTH-1:0] s_data;
    logic [P_WIDTH-1:0] m_data_p1, m_data_p2, m_data_p3;

    rns_split #(
        .Q_IN_WIDTH(Q_IN_WIDTH),
        .P_WIDTH(P_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data),
        .m_valid(m_valid), .m_ready(m_ready),
        .m_data_p1(m_data_p1), .m_data_p2(m_data_p2), .m_data_p3(m_data_p3)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer i, pass_cnt, fail_cnt, fd;
    logic [Q_IN_WIDTH-1:0] rx;
    logic [P_WIDTH-1:0] rx1, rx2, rx3;

    initial begin
        rst_n = 0;
        s_valid = 0;
        s_data = 0;
        m_ready = 1;
        pass_cnt = 0; fail_cnt = 0;
        #20 rst_n = 1;
        #10;

        fd = $fopen({REPO_ROOT, "/scripts/_e37_rns_split_vec.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open vector file");
            $finish;
        end
        for (i = 0; i < N_VEC; i = i + 1) begin
            $fscanf(fd, "%h %h %h %h", rx, rx1, rx2, rx3);
            @(negedge clk);
            s_data = rx;
            s_valid = 1;
            @(negedge clk);
            s_valid = 0;
            // 1 级流水：m_valid 在 1 个 posedge 后拉高
            wait(m_valid == 1'b1);
            @(negedge clk);
            if (m_data_p1 === rx1 && m_data_p2 === rx2 && m_data_p3 === rx3) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: i=%0d got=%h,%h,%h exp=%h,%h,%h", i,
                         m_data_p1, m_data_p2, m_data_p3, rx1, rx2, rx3);
            end
        end
        $fclose(fd);
        $display("=== rns_split: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
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
