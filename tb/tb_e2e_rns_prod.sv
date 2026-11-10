`timescale 1ns / 1ps
`default_nettype none
module tb_e2e_rns_prod;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";

    localparam int LOG_N = 12;
    localparam int N     = 4096;
    localparam int QW    = 42;
    localparam int MW    = 115;
    localparam int NT    = 3;
    localparam real CLK_PERIOD = 10.0;

    logic clk, rst_n;
    logic start, busy, done, error;
    logic [MW-1:0] a_in_data, b_in_data, out_data;
    logic a_in_valid, a_in_ready, b_in_valid, b_in_ready;
    logic out_valid, out_last, out_ready;

    logic [QW-1:0] om1 [0:N/2-1]; logic [QW-1:0] omi1 [0:N/2-1];
    logic [QW-1:0] om2 [0:N/2-1]; logic [QW-1:0] omi2 [0:N/2-1];
    logic [QW-1:0] om3 [0:N/2-1]; logic [QW-1:0] omi3 [0:N/2-1];

    logic [MW-1:0] mem_a   [0:N-1];
    logic [MW-1:0] mem_b   [0:N-1];
    logic [MW-1:0] exp_out [0:N-1];
    logic [MW-1:0] obuf    [0:N-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    initial begin clk = 0; forever #5 clk = ~clk; end
    initial begin rst_n = 0; #20; rst_n = 1; end

    e2e_rns_top #(
        .LOG_N(LOG_N), .N(N), .P_WIDTH(QW), .M_WIDTH(MW), .SCALE(1024),
        .W1(115'h38477b0357aa2be2be3fa0154725f), .W2(115'h047ffffffffa66666662622222222), .W3(115'h287884fcb04d6db6db801dc896b81), .M(115'h6540000007f200000022200000001),
        .P1(42'd77309411329), .P2(42'd206158430209), .P3(42'd2061584302081),
        .N_INV1(42'd77290536961), .N_INV2(42'd206108098561), .N_INV3(42'd2061080985601),
        .TW_ROOT({REPO_ROOT, "/rtl/m5/tw"})
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done), .error(error),
        .a_in_data(a_in_data), .a_in_valid(a_in_valid), .a_in_ready(a_in_ready),
        .b_in_data(b_in_data), .b_in_valid(b_in_valid), .b_in_ready(b_in_ready),
        .out_data(out_data), .out_valid(out_valid), .out_last(out_last),
        .out_ready(out_ready)
    );

    initial begin
        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/om1.hex"}, om1);  $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/omi1.hex"}, omi1);
        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/om2.hex"}, om2);  $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/omi2.hex"}, omi2);
        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/om3.hex"}, om3);  $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/omi3.hex"}, omi3);
    end

    task automatic drive_A;
        integer i;
        begin
            wait (a_in_ready === 1'b1);
            a_in_valid = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                @(negedge clk);
                a_in_data = mem_a[i];
            end
            @(negedge clk);
            a_in_valid = 1'b0;
        end
    endtask

    task automatic drive_B;
        integer i;
        begin
            wait (b_in_ready === 1'b1);
            b_in_valid = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                @(negedge clk);
                b_in_data = mem_b[i];
            end
            @(negedge clk);
            b_in_valid = 1'b0;
        end
    endtask

    task automatic collect_out;
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

    initial begin
        start = 1'b0;
        a_in_valid = 1'b0; b_in_valid = 1'b0;
        a_in_data = '0;    b_in_data = '0;
        out_ready = 1'b1;
        wait (rst_n === 1'b1);
        @(posedge clk);
        #50;

        for (integer v = 0; v < NT; v = v + 1) begin
            case (v)
                0: begin $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/a0.hex"}, mem_a);
                        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/b0.hex"}, mem_b);
                        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/exp0.hex"}, exp_out); end
                1: begin $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/a1.hex"}, mem_a);
                        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/b1.hex"}, mem_b);
                        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/exp1.hex"}, exp_out); end
                default: begin $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/a2.hex"}, mem_a);
                        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/b2.hex"}, mem_b);
                        $readmemh({REPO_ROOT, "/scripts/_e37_e2e_vecs_prod/exp2.hex"}, exp_out); end
            endcase

            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            fork
                drive_A;
                drive_B;
                collect_out;
            join

            begin : cmp_blk
                integer i, errs;
                errs = 0;
                for (i = 0; i < N; i = i + 1) begin
                    if (obuf[i] !== exp_out[i]) begin
                        errs = errs + 1;
                        if (errs <= 3)
                            $display("  [MISMATCH] v%0d i=%0d got=%h want=%h",
                                     v, i, obuf[i], exp_out[i]);
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
            repeat (20) @(posedge clk);
        end

        $display("");
        $display("=== e2e_rns_top N=%0d: PASS=%%0d FAIL=%%0d ===", N, pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("RESULT: ALL PASS");
        else $display("RESULT: %0d FAILED", fail_cnt);
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 6000000);
        $display("TIMEOUT");
        $finish;
    end
endmodule
