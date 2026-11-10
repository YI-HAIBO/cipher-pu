//=============================================================================
// tb_ntt_cycles.sv  —  测量 1W2R 后 ntt_unit 每蝶形节拍（A-2 吞吐重算依据）
//
// 用途：不校验数据（喂 0 + 假 twiddle），只统计状态机周期数：
//   total    : start 拉高 -> done 拉高 的周期数
//   compute  : S_COMPUTE 内的周期数
//   input_c  : S_INPUT 内的周期数
//   output_c : S_OUTPUT / S_OUT_PRE 内的周期数
//   bf_cnt   : C_WRITEBACK_B 命中次数（= 蝶形数 = LOG_N*N/2）
//   period   : compute / bf_cnt（每蝶形拍数）
//
// 参数化：LOG_N=4 (N=16) 与 LOG_N=8 (N=256) 两个规模，证明节拍与 N 无关。
// TW_FILE 用假 twiddle（全 1），$readmemh 能装载即可（不校验数值）。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_ntt_cycles #(
    parameter int LOG_N  = 4,
    parameter int N      = 1 << LOG_N,
    parameter int QW     = 14
) ();
    localparam int QVAL = 257;   // 257 是素数且 2^N | 256（仅需 2^LOG_N | q-1 成立即可跑）
    localparam int NINV = 256;   // 仅占位，不校验数值

    logic clk = 0, rst_n = 0;
    logic start, op_mode, busy, done, error;
    logic [QW-1:0] in_data;
    logic in_valid, in_ready;
    logic [QW-1:0] out_data;
    logic out_valid, out_last, out_ready;

    ntt_unit #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(QW), .Q_VALUE(QVAL), .N_INV(NINV),
        .USE_FASTRED(0),
        .TW_FILE("tw_dummy.hex"), .TW_INV_FILE("tw_dummy_inv.hex")
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .op_mode(op_mode), .busy(busy), .done(done), .error(error),
        .in_data(in_data), .in_valid(in_valid), .in_ready(in_ready),
        .out_data(out_data), .out_valid(out_valid), .out_last(out_last), .out_ready(out_ready)
    );

    // 计数器
    integer total=0, compute=0, input_c=0, output_c=0, bf_cnt=0;
    integer n_runs = 2;   // op_mode 0 + 1
    integer run_idx = 0;

    always @(posedge clk) begin
        if (busy) begin
            total <= total + 1;
            if (u_dut.state == 3'd2)      compute <= compute + 1;   // S_COMPUTE
            if (u_dut.state == 3'd1)      input_c <= input_c + 1;   // S_INPUT
            if (u_dut.state == 3'd3 || u_dut.state == 3'd6) output_c <= output_c + 1; // S_OUTPUT/S_OUT_PRE
            if (u_dut.state == 3'd2 && u_dut.comp_state == 3'd5) bf_cnt <= bf_cnt + 1; // C_WRITEBACK_B
        end
    end

    // 时钟 100MHz
    always #5 clk = ~clk;

    integer i;
    initial begin
        in_data = '0; in_valid = 1'b0; out_ready = 1'b1; start = 1'b0; op_mode = 1'b0;
        #30 rst_n = 1;
        @(posedge clk); #1;

        // op_mode 0 (NTT) then 1 (INTT)
        for (run_idx = 0; run_idx < n_runs; run_idx = run_idx + 1) begin
            total=0; compute=0; input_c=0; output_c=0; bf_cnt=0;
            op_mode = (run_idx == 0) ? 1'b0 : 1'b1;
            @(posedge clk); #1;
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;

            // 喂 N 个 0（不等 in_ready 也行，直接每拍给）
            in_valid = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                @(posedge clk); #1;
            end
            in_valid = 1'b0;

            wait (done === 1'b1);
            @(posedge clk); #1;
            wait (busy === 1'b0);
            @(posedge clk); #1;

            $display("RESULT LOG_N=%0d N=%0d mode=%0d  total=%0d compute=%0d input=%0d output=%0d bf=%0d  period=%.3f (expect 9)",
                     LOG_N, N, op_mode, total, compute, input_c, output_c, bf_cnt,
                     (bf_cnt>0) ? compute/real'(bf_cnt) : 0.0);
        end

        $display("*** NTT cycle measurement complete (1W2R) ***");
        $finish;
    end

    initial begin
        #(10 * 200000);
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
