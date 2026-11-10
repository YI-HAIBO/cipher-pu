//=============================================================================
// tb_ntt_unit.sv  —  ntt_unit 完整测试平台（密推芯 M1 Phase 2c）
//
// 测试目标：
//   1. NTT 批量验证：10 组随机向量（Python 参考模型生成）
//   2. INTT 往返验证：NTT -> INTT 应还原原始系数（验证 op_mode=1 路径）
//   3. 与 tb/ref/gen_ntt_reference.py 参考模型逐系数对齐
//
// 测试配置：
//   N = 16, LOG_N = 4, q = 113 (prime, 2^4 | q-1)
//   omega = 40, omega_inv = 65, N_INV = 106 (= 16^-1 mod 113)
//
// 向量文件（由 scripts/gen_ntt_vectors.py 生成，row-major: v*16+i）：
//   ntt_in_all.hex     : 10 组输入系数
//   ntt_out_all.hex    : 10 组期望 NTT 结果
//   intt_out_all.hex   : 10 组期望 INTT 往返结果（= 原始输入）
//   注意：这些文件必须与 xsim 工作目录同目录，或用 +tbdir=<dir> 指定
//
// 关键时序约定（沿用 Phase 2b 已验证的握手，勿改）：
//   - DUT in_ready/out_valid 均为寄存器输出
//   - AXI-Stream 握手：valid+data 需在时钟沿之前设置，DUT 在 posedge 采样
//   - @(posedge clk) 之后必须 #1 等 NBA 更新，否则读到的是上一 cycle 的值
//   - 最后一个输入/输出不等握手（DUT 在该 posedge 会拉低 in_ready/out_valid）
//   - 每次变换约 230 cycle；20 次变换预留 200000ns
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_ntt_unit;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam int    LOG_N      = 4;
    localparam int    N          = 1 << LOG_N;       // 16
    localparam int    Q_WIDTH    = 7;
    localparam int    Q_VALUE    = 113;
    localparam int    N_INV      = 106;              // 16^-1 mod 113
    localparam int    NUM_TESTS  = 10;
    localparam real   CLK_PERIOD = 10.0;             // 100 MHz

    // 向量目录（可用 +tbdir=<dir> 覆盖）
    string tbdir = ".";

    // =========================================================================
    // 信号
    // =========================================================================
    logic clk;
    logic rst_n;
    logic start;
    logic op_mode;
    logic busy;
    logic done;
    logic error;

    logic [Q_WIDTH-1:0] in_data;
    logic in_valid;
    logic in_ready;

    logic [Q_WIDTH-1:0] out_data;
    logic out_valid;
    logic out_last;
    logic out_ready;

    // Twiddle 因子表
    logic [Q_WIDTH-1:0] omega_table     [0:N/2-1];
    logic [Q_WIDTH-1:0] omega_inv_table [0:N/2-1];

    // 参考向量（10 组 x 16）
    logic [Q_WIDTH-1:0] ref_in  [0:NUM_TESTS*N-1];
    logic [Q_WIDTH-1:0] ref_ntt [0:NUM_TESTS*N-1];
    logic [Q_WIDTH-1:0] ref_rtt [0:NUM_TESTS*N-1];

    // 当前测试向量暂存
    logic [Q_WIDTH-1:0] input_mem    [0:N-1];
    logic [Q_WIDTH-1:0] expected_mem [0:N-1];
    logic [Q_WIDTH-1:0] output_mem   [0:N-1];

    // 统计
    integer ntt_pass_cnt   = 0;
    integer ntt_fail_cnt   = 0;
    integer intt_pass_cnt  = 0;
    integer intt_fail_cnt  = 0;
    integer last_errs      = 0;    // compare_results 的结果暂存

    // =========================================================================
    // 时钟生成
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 复位
    // =========================================================================
    initial begin
        rst_n = 0;
        #20;
        rst_n = 1;
    end

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    ntt_unit_test #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VALUE),
        .N_INV(N_INV)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .op_mode(op_mode),
        .busy(busy),
        .done(done),
        .error(error),
        .in_data(in_data),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .out_data(out_data),
        .out_valid(out_valid),
        .out_last(out_last),
        .out_ready(out_ready),
        .omega_table(omega_table),
        .omega_inv_table(omega_inv_table)
    );

    // =========================================================================
    // Twiddle 因子初始化
    //   omega = 40 :  omega^k  = 40^k mod 113
    //   omega_inv = 65 : (65)^k mod 113
    //   两表均由 tb/ref/gen_ntt_reference.py 计算并与 Python 模型交叉验证
    // =========================================================================
    initial begin
        omega_table[0] = 7'd1;    omega_inv_table[0] = 7'd1;
        omega_table[1] = 7'd40;   omega_inv_table[1] = 7'd65;
        omega_table[2] = 7'd18;   omega_inv_table[2] = 7'd44;
        omega_table[3] = 7'd42;   omega_inv_table[3] = 7'd35;
        omega_table[4] = 7'd98;   omega_inv_table[4] = 7'd15;
        omega_table[5] = 7'd78;   omega_inv_table[5] = 7'd71;
        omega_table[6] = 7'd69;   omega_inv_table[6] = 7'd95;
        omega_table[7] = 7'd48;   omega_inv_table[7] = 7'd73;
    end

    // =========================================================================
    // 参考向量加载
    // =========================================================================
    initial begin
        if (!$value$plusargs("tbdir=%s", tbdir)) begin
            tbdir = ".";
        end
        $display("[TB] Loading reference vectors from: %s", tbdir);
        $readmemh($sformatf("%s/ntt_in_all.hex",    tbdir), ref_in);
        $readmemh($sformatf("%s/ntt_out_all.hex",   tbdir), ref_ntt);
        $readmemh($sformatf("%s/intt_out_all.hex",  tbdir), ref_rtt);
    end

    // =========================================================================
    // 输入任务（AXI-Stream 协议）
    //   关键：不在 @(posedge) 的 active region 里用阻塞赋值关闭 in_valid
    //   做法：循环结束后用 #1 延迟关闭 in_valid
    // =========================================================================
    task automatic input_coefficients;
        automatic integer i;
        begin
            in_valid = 1'b1;
            in_data  = input_mem[0];
            for (i = 0; i < N; i = i + 1) begin
                if (i == N - 1) begin
                    // 最后一个系数：DUT 在此 posedge 采样后转 S_COMPUTE，in_ready 变 0
                    // 不需要等 in_ready，只需等一个 posedge 让 DUT 采样
                    @(posedge clk);
                    #1;
                end else begin
                    // 非最后系数：等 in_ready=1 握手完成
                    forever begin
                        @(posedge clk);
                        #1;
                        if (in_ready) break;
                    end
                    // 准备下一个数据
                    in_data = input_mem[i + 1];
                end
            end
            #1;
            in_valid = 1'b0;
        end
    endtask

    // =========================================================================
    // 输出任务（AXI-Stream 协议）
    //   关键：@(posedge) 后必须 #1 等 NBA 更新，否则读到的是上一 cycle 的 out_data
    // =========================================================================
    task automatic output_coefficients;
        automatic integer i;
        begin
            out_ready = 1'b1;
            for (i = 0; i < N; i = i + 1) begin
                if (i == N - 1) begin
                    // 最后一个输出：DUT 在此 posedge 输出 out_data 后转 S_DONE，out_valid 变 0
                    // 不需要等 out_valid，只需等一个 posedge 让 DUT 输出
                    @(posedge clk);
                    #1;
                end else begin
                    // 非最后输出：等 out_valid=1 握手完成
                    forever begin
                        @(posedge clk);
                        #1;
                        if (out_valid) break;
                    end
                end
                output_mem[i] = out_data;
                if (out_last) begin
                    out_ready = 1'b0;
                end
            end
        end
    endtask

    // =========================================================================
    // 比较任务：返回错误个数（0 = 全部通过）
    //   仅在出错时逐系数打印，避免日志过长
    // =========================================================================
    task automatic compare_results(input string test_name);
        automatic integer i;
        begin
            last_errs = 0;
            for (i = 0; i < N; i = i + 1) begin
                if (expected_mem[i] != output_mem[i]) begin
                    last_errs = last_errs + 1;
                    $display("    [MISMATCH] idx=%0d expected=%0d actual=%0d",
                             i, expected_mem[i], output_mem[i]);
                end
            end
            if (last_errs == 0) begin
                $display("    %s: %0d/%0d PASS", test_name, N, N);
            end else begin
                $display("    %s: %0d/%0d FAIL", test_name, last_errs, N);
            end
        end
    endtask

    // =========================================================================
    // 功能覆盖率（M1 Phase 2c）
    //   xsim 2026.1 仅支持 SV Functional Coverage（--cov_db_dir），不支持代码覆盖率
    //   通过层级引用观测 DUT 内部状态机
    //   注意：xsim 的 $get_coverage(cg,"item") 忽略第二参数、一律返回 covergroup
    //         总分，故每个 coverpoint 独立成 covergroup，逐项取 "score" 才是真值
    // =========================================================================
    covergroup cg_opmode @(posedge clk);
        option.per_instance = 1;
        m : coverpoint op_mode { bins ntt = {0}; bins intt = {1}; }
    endgroup

    // 主状态机：S_IDLE=0, S_INPUT=1, S_COMPUTE=2, S_OUTPUT=3, S_DONE=4
    covergroup cg_state @(posedge clk);
        option.per_instance = 1;
        s : coverpoint u_dut.state {
            bins s_idle    = {0};
            bins s_input   = {1};
            bins s_compute = {2};
            bins s_output  = {3};
            bins s_done    = {4};
        }
    endgroup

    // 计算子状态机：C_ISSUE=0, C_WAIT=1, C_WRITEBACK=2
    covergroup cg_comp @(posedge clk);
        option.per_instance = 1;
        c : coverpoint u_dut.comp_state {
            bins c_issue = {0};
            bins c_wait  = {1};
            bins c_write = {2};
        }
    endgroup

    // LOG_N=4 级流水线：stage 0..3 全部须走到
    covergroup cg_stage @(posedge clk);
        option.per_instance = 1;
        st : coverpoint u_dut.stage_idx { bins stg = {0, 1, 2, 3}; }
    endgroup

    // 每级 8 个蝴蝶 / 16 个系数 / twiddle 指数 0..7
    covergroup cg_bf @(posedge clk);
        option.per_instance = 1;
        b : coverpoint u_dut.bf_idx;
    endgroup

    covergroup cg_idx @(posedge clk);
        option.per_instance = 1;
        ix : coverpoint u_dut.coeff_idx;
    endgroup

    covergroup cg_tw @(posedge clk);
        option.per_instance = 1;
        tw : coverpoint u_dut.twiddle_exp;
    endgroup

    // 交叉：主状态 x 子状态（5x3=15 个组合，部分结构性不可达）
    covergroup cg_cross_sm @(posedge clk);
        option.per_instance = 1;
        sm : cross u_dut.state, u_dut.comp_state;
    endgroup

    cg_opmode     g_opmode = new();
    cg_state      g_state  = new();
    cg_comp       g_comp   = new();
    cg_stage      g_stage  = new();
    cg_bf         g_bf     = new();
    cg_idx        g_idx    = new();
    cg_tw         g_tw     = new();
    cg_cross_sm   g_xsm    = new();

    always @(posedge clk) begin
        if (rst_n) begin
            g_opmode.sample();
            g_state.sample();
            g_comp.sample();
            g_stage.sample();
            g_bf.sample();
            g_idx.sample();
            g_tw.sample();
            g_xsm.sample();
        end
    end

    // =========================================================================
    // 自记录式覆盖率（位图）
    //   xsim 2026.1 的 $get_coverage(cg,"score") 忽略句柄参数、恒返回同一聚合值，
    //   无法给出逐项明细。故用位图自行记录命中，结束时打印命中数与缺项。
    //   结果确定可复现，不依赖 xsim 覆盖率管线；covergroup 仅用于产出 covinfo。
    // =========================================================================
    logic [1:0]   hit_op    = '0;     // op_mode: 0=NTT, 1=INTT
    logic [4:0]   hit_state = '0;     // 主状态 S_IDLE..S_DONE
    logic [2:0]   hit_comp  = '0;     // 子状态 C_ISSUE/C_WAIT/C_WRITEBACK
    logic [3:0]   hit_stage = '0;     // stage 0..3
    logic [7:0]   hit_bf    = '0;     // bf_idx 0..7
    logic [15:0]  hit_idx   = '0;     // coeff_idx 0..15
    logic [7:0]   hit_tw    = '0;     // twiddle_exp 0..7
    logic [14:0]  hit_cross = '0;     // state x comp_state = 5x3

    always @(posedge clk) begin
        if (rst_n) begin
            hit_op[op_mode] <= 1'b1;
            if (u_dut.state < 5)
                hit_state[u_dut.state] <= 1'b1;
            if (u_dut.comp_state < 3)
                hit_comp[u_dut.comp_state] <= 1'b1;
            if (u_dut.stage_idx < 4)
                hit_stage[u_dut.stage_idx] <= 1'b1;
            hit_bf[u_dut.bf_idx]        <= 1'b1;
            hit_idx[u_dut.coeff_idx]    <= 1'b1;
            hit_tw[u_dut.twiddle_exp]   <= 1'b1;
            if (u_dut.state < 5 && u_dut.comp_state < 3)
                hit_cross[u_dut.state * 3 + u_dut.comp_state] <= 1'b1;
        end
    end

    // popcount
    function automatic integer popcount(input logic [31:0] x);
        automatic integer i, n;
        begin
            n = 0;
            for (i = 0; i < 32; i = i + 1) begin
                if (x[i]) n = n + 1;
            end
            return n;
        end
    endfunction

    // 列出未命中的下标
    function automatic string missing_list(input logic [15:0] mask, input integer n);
        automatic string s;
        automatic integer i;
        begin
            s = "";
            for (i = 0; i < n; i = i + 1) begin
                if (!mask[i]) begin
                    s = {s, (s.len() > 0 ? ", " : ""), $sformatf("%0d", i)};
                end
            end
            if (s.len() == 0) s = "无";
            return s;
        end
    endfunction

    // =========================================================================
    // 主测试流程
    // =========================================================================
    initial begin
        $display("========================================================");
        $display("NTT Unit Testbench (M1 Phase 2c)");
        $display("N=%0d, LOG_N=%0d, q=%0d, omega=40, omega_inv=65, N_INV=%0d",
                 N, LOG_N, Q_VALUE, N_INV);
        $display("Vectors: %0d  |  Checks: NTT + INTT round-trip", NUM_TESTS);
        $display("========================================================");

        // 初始化信号
        start     = 1'b0;
        op_mode   = 1'b0;
        in_valid  = 1'b0;
        in_data   = '0;
        out_ready = 1'b0;

        // 等待复位完成 + 向量加载完成
        wait (rst_n === 1'b1);
        @(posedge clk);
        #50;   // 留出 $readmemh 非阻塞加载时间

        for (integer v = 0; v < NUM_TESTS; v = v + 1) begin
            // -----------------------------------------------------------------
            // 阶段 A: NTT (op_mode=0)
            // -----------------------------------------------------------------
            for (integer i = 0; i < N; i = i + 1) begin
                input_mem[i]    = ref_in[v*N + i];
                expected_mem[i] = ref_ntt[v*N + i];
            end

            op_mode = 1'b0;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            input_coefficients;
            output_coefficients;
            wait (busy === 1'b0);
            @(posedge clk);

            compare_results($sformatf("vec%0d NTT", v));
            if (last_errs == 0) begin
                ntt_pass_cnt = ntt_pass_cnt + 1;
            end else begin
                ntt_fail_cnt = ntt_fail_cnt + 1;
            end

            // -----------------------------------------------------------------
            // 阶段 B: INTT (op_mode=1) — 输入 = 上一步 NTT 结果
            // -----------------------------------------------------------------
            for (integer i = 0; i < N; i = i + 1) begin
                input_mem[i]    = output_mem[i];      // NTT 结果作为 INTT 输入
                expected_mem[i] = ref_rtt[v*N + i];   // 期望还原为原始系数
            end

            op_mode = 1'b1;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            input_coefficients;
            output_coefficients;
            wait (busy === 1'b0);
            @(posedge clk);

            compare_results($sformatf("vec%0d INTT", v));
            if (last_errs == 0) begin
                intt_pass_cnt = intt_pass_cnt + 1;
            end else begin
                intt_fail_cnt = intt_fail_cnt + 1;
            end
        end

        // =========================================================================
        // 汇总
        // =========================================================================
        $display("");
        $display("========================================================");
        $display("SUMMARY - M1 Phase 2c");
        $display("========================================================");
        $display("  NTT  : %0d/%0d pass, %0d fail", ntt_pass_cnt, NUM_TESTS, ntt_fail_cnt);
        $display("  INTT : %0d/%0d pass, %0d fail", intt_pass_cnt, NUM_TESTS, intt_fail_cnt);
        $display("========================================================");

        if (ntt_fail_cnt == 0 && intt_fail_cnt == 0) begin
            $display("*** ALL PASS - NTT + INTT round-trip verified (%0d vectors) ***",
                     NUM_TESTS);
        end else begin
            $display("*** FAIL - %0d NTT + %0d INTT mismatches ***",
                     ntt_fail_cnt, intt_fail_cnt);
        end
        $display("========================================================");

        // =========================================================================
        // 功能覆盖率报告（位图自记录，命中数 + 缺项明细）
        // =========================================================================
        $display("");
        $display("========================================================");
        $display("FUNCTIONAL COVERAGE REPORT");
        $display("========================================================");
        $display("  %-24s %5s  缺项: %s", "op_mode (NTT/INTT)",
                 $sformatf("%0d/2", popcount(hit_op)),          missing_list(hit_op, 2));
        $display("  %-24s %5s  缺项: %s", "state (5)",
                 $sformatf("%0d/5", popcount(hit_state)),       missing_list(hit_state, 5));
        $display("  %-24s %5s  缺项: %s", "comp_state (3)",
                 $sformatf("%0d/3", popcount(hit_comp)),        missing_list(hit_comp, 3));
        $display("  %-24s %5s  缺项: %s", "stage (0..3)",
                 $sformatf("%0d/4", popcount(hit_stage)),       missing_list(hit_stage, 4));
        $display("  %-24s %5s  缺项: %s", "bf_idx (0..7)",
                 $sformatf("%0d/8", popcount(hit_bf)),          missing_list(hit_bf, 8));
        $display("  %-24s %5s  缺项: %s", "coeff_idx (0..15)",
                 $sformatf("%0d/16", popcount(hit_idx)),        missing_list(hit_idx, 16));
        $display("  %-24s %5s  缺项: %s", "twiddle_exp (0..7)",
                 $sformatf("%0d/8", popcount(hit_tw)),          missing_list(hit_tw, 8));
        $display("  %-24s %5s  缺项: %s", "cross state x comp",
                 $sformatf("%0d/15", popcount(hit_cross)),      missing_list(hit_cross, 15));
        $display("========================================================");

        #100;
        $finish;
    end

    // =========================================================================
    // 看门狗（防止仿真卡死）
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 20000);  // 200000ns
        $display("");
        $display("*** TIMEOUT - Test did not complete in time ***");
        $finish;
    end

endmodule
