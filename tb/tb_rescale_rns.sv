`timescale 1ns / 1ps
`default_nettype none
module tb_rescale_rns;
    // B-6: REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径；默认中性相对路径
    parameter string REPO_ROOT = ".";
    parameter P_WIDTH = 42;
    parameter M_WIDTH = 115;
    parameter int N_VEC = 20;

    logic clk, rst_n;
    logic s_valid, s_ready, m_valid, m_ready;
    logic [P_WIDTH-1:0] s_data_p1, s_data_p2, s_data_p3;
    logic [P_WIDTH-1:0] m_data_p1, m_data_p2, m_data_p3;

    rescale_rns #(
        .P_WIDTH(P_WIDTH),
        .M_WIDTH(M_WIDTH),
        .SCALE(1024)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data_p1(s_data_p1), .s_data_p2(s_data_p2), .s_data_p3(s_data_p3),
        .m_valid(m_valid), .m_ready(m_ready),
        .m_data_p1(m_data_p1), .m_data_p2(m_data_p2), .m_data_p3(m_data_p3)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer i, pass_cnt, fail_cnt, fd;
    logic [P_WIDTH-1:0] rx1, rx2, rx3, ry1, ry2, ry3;

    initial begin
        rst_n = 0;
        s_valid = 0;
        s_data_p1 = 0; s_data_p2 = 0; s_data_p3 = 0;
        m_ready = 1;
        pass_cnt = 0; fail_cnt = 0;
        #20 rst_n = 1;
        #10;

        fd = $fopen({REPO_ROOT, "/scripts/_e37_rescale_vec.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open vector file");
            $finish;
        end
        for (i = 0; i < N_VEC; i = i + 1) begin
            $fscanf(fd, "%h %h %h %h %h %h", rx1, rx2, rx3, ry1, ry2, ry3);
            @(negedge clk);
            s_data_p1 = rx1;
            s_data_p2 = rx2;
            s_data_p3 = rx3;
            s_valid = 1;
            @(negedge clk);
            s_valid = 0;
            // 3 级流水（Phase 3）：m_valid 在 3 个 posedge 后拉高
            wait(m_valid == 1'b1);
            @(negedge clk);
            if (m_data_p1 === ry1 && m_data_p2 === ry2 && m_data_p3 === ry3) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: i=%0d got=%h,%h,%h exp=%h,%h,%h", i,
                         m_data_p1, m_data_p2, m_data_p3, ry1, ry2, ry3);
            end
        end
        $fclose(fd);
        $display("=== rescale_rns: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("RESULT: ALL PASS");
        else $display("RESULT: %0d FAILED", fail_cnt);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
