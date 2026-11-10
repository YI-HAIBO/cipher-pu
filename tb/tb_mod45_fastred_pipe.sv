//=============================================================================
// tb_mod45_fastred_pipe.sv — E49：mod45_fastred PIPE=1 流水线版本定向验证
//
//   驱动随机 90-bit x，一个时钟后比对 r == x mod q（期望值用 % 独立计算）。
//   PIPE=1 的语义：r1_pipe 每拍锁存 round-1 组合结果，输出比输入晚 1 拍。
//   逐拍驱动 x_i → 下一拍 r 应等于 reduction(x_i)。
//
//   覆盖：200 随机 + 边界（0, 1, q-1, q, 2q-1, 2^44, 2^90-1, 全 1 等）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_mod45_fastred_pipe;

    localparam logic [44:0] Q = 45'd17592186175489;

    logic clk = 1'b0;
    logic [89:0] x = '0;
    logic [44:0] r;

    always #5 clk = ~clk;

    mod45_fastred #(
        .WIDTH   (45),
        .Q_VALUE (Q),
        .K       (44),
        .SHIFT   (90),
        .PIPE    (1)
    ) dut (
        .clk (clk),
        .x   (x),
        .r   (r)
    );

    integer i;
    integer errors = 0;
    integer tests  = 0;
    logic [89:0] queued [0:511];
    integer nq = 0;

    // 期望值：x % q（独立路径，与 DUT 算法无关）
    function [44:0] expected(input logic [89:0] v);
        expected = v % Q;
    endfunction

    task push(input logic [89:0] v);
        begin
            queued[nq] = v;
            nq = nq + 1;
        end
    endtask

    // 单测：驱动 v，下一拍比对
    task check(input logic [89:0] v);
        begin
            @(negedge clk);      // 驱动落 negedge（铁律）
            x = v;
            @(posedge clk);      // r1_pipe 在此沿锁存 round1(v)
            @(negedge clk);      // 采样落 negedge，r 已稳定
            tests = tests + 1;
            if (r !== expected(v)) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL: x=%0d exp=%0d got=%0d", v, expected(v), r);
            end
        end
    endtask

    initial begin
        // ---- 边界用例 ----
        push(90'd0);
        push(90'd1);
        push(90'd2);
        push({45'd0, Q});               // q
        push({45'd0, Q - 1});           // q-1
        push({45'd0, Q + 1});           // q+1
        push(90'd17592186175488);       // 2^44（q-c 的幂次边界）
        push({1'b1, 89'd0});            // 2^89
        push({90{1'b1}});               // 2^90-1
        push({45'd1, 45'd0});           // 2^45
        push({44'd1, 46'd0});           // 2^46（round-1 负边界）
        push({45'd0, 45'd131073});      // c
        // ---- 随机用例 ----
        for (i = 0; i < 200; i = i + 1) begin
            push({$random, $random, $random});
        end

        for (i = 0; i < nq; i = i + 1) begin
            check(queued[i]);
        end

        $display("TB_MOD45_FASTRED_PIPE: tests=%0d errors=%0d", tests, errors);
        if (errors == 0) $display("TB_MOD45_FASTRED_PIPE: PASS");
        else             $display("TB_MOD45_FASTRED_PIPE: FAIL");
        $finish;
    end

endmodule

`default_nettype wire
