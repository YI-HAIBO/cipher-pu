// =============================================================================
// tb_e33_real_ciphertext.sv  —  E33 真实 RLWE 密文端到端硬件执行
//
// 玩具配置: N=16, LOG_N=4, Q_WIDTH=7, Q_IN=113, Q_OUT=97, N_INV=106
//
// 与 tb_e2e_ckks_mult_ctrl_m4.sv 的区别：
//   - 激励不再是确定性公式，而是由 Python 真实 RLWE 参数生成的密文
//     （真实三元秘密钥 s、离散高斯噪声、真 keyswitch key b = a*s + e_ks）
//   - 全部固定 Gear 0（全精度基线）：E33 的目标是"真实密文 × 真硬件全链"
//   - $readmemh 从 tb/ref/e33_*.hex 加载，$writememh 把 DUT 输出落盘
//     供 Python 做逐系数 bit-exact 比对 / 解密 / 噪声预算分析
//
// 用例布局（NUM_CASES=12，每例 N=16 系数）：
//   case  0-5 : regime UNIFORM（新鲜 RLWE 密文，两分量均均匀）
//   case  6-9 : regime SMALL_C1（真噪声，c1 小范数 → 单对 keyswitch 精确域）
//   case 10-11: regime NOISELESS（零噪声，隔离纯硬件伪影）
//
// 协议铁律（沿用 2026-10-18 修复）：
//   - 输出采样全部落在 negedge（避开 posedge NBA 竞争）
//   - f0_ready/f1_ready 推理期间保持 0，采样阶段再置位
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e33_real_ciphertext;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    localparam LOG_N   = 4;
    localparam N       = 16;
    localparam Q_WIDTH = 7;
    localparam Q_IN    = 113;
    localparam Q_OUT   = 97;
    localparam N_INV   = 106;
    localparam NUM_CASES = 12;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [2:0] gear_sel;
    logic       start;
    logic       busy;
    logic       done;
    logic       error;
    logic       block_sparse_en = 1'b0;

    logic                 c0_1_valid, c0_1_ready;
    logic [Q_WIDTH-1:0]   c0_1_data;
    logic                 c1_1_valid, c1_1_ready;
    logic [Q_WIDTH-1:0]   c1_1_data;
    logic                 c0_2_valid, c0_2_ready;
    logic [Q_WIDTH-1:0]   c0_2_data;
    logic                 c1_2_valid, c1_2_ready;
    logic [Q_WIDTH-1:0]   c1_2_data;
    logic                 a_valid, a_ready;
    logic [Q_WIDTH-1:0]   a_data;
    logic                 b_valid, b_ready;
    logic [Q_WIDTH-1:0]   b_data;

    logic                 f0_valid, f0_ready;
    logic [Q_WIDTH-1:0]   f0_data;
    logic                 f1_valid, f1_ready;
    logic [Q_WIDTH-1:0]   f1_data;


    // ------------------------------------------------------------------
    // 激励 / 期望 / DUT 输出数组（NUM_CASES*N 系数，展平）
    // ------------------------------------------------------------------
    logic [Q_WIDTH-1:0] c0_1_all [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] c1_1_all [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] c0_2_all [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] c1_2_all [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] a_all    [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] b_all    [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] exp_f0_all [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] exp_f1_all [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] dut_f0_all [0:N*NUM_CASES-1];
    logic [Q_WIDTH-1:0] dut_f1_all [0:N*NUM_CASES-1];

    e2e_ckks_mult_ctrl_m4 #(
        .LOG_N    (LOG_N),
        .N        (N),
        .Q_WIDTH  (Q_WIDTH),
        .Q_IN     (Q_IN),
        .Q_OUT    (Q_OUT),
        .N_INV    (N_INV),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"}),
        .USE_FASTRED(0)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .gear_sel(gear_sel),
        .mode_sel(1'b0),
        .energy_q2_ext('0),
        .flush_valid_ext(1'b0),
        .hysteresis_en(1'b0),
        .manual_gear(3'd0),
        .manual_en(1'b0),
        .noise_mon_en(1'b0),
        .block_sparse_en(block_sparse_en),
        .start(start), .busy(busy), .done(done), .error(error),
        .c0_1_valid(c0_1_valid), .c0_1_ready(c0_1_ready), .c0_1_data(c0_1_data),
        .c1_1_valid(c1_1_valid), .c1_1_ready(c1_1_ready), .c1_1_data(c1_1_data),
        .c0_2_valid(c0_2_valid), .c0_2_ready(c0_2_ready), .c0_2_data(c0_2_data),
        .c1_2_valid(c1_2_valid), .c1_2_ready(c1_2_ready), .c1_2_data(c1_2_data),
        .a_valid(a_valid), .a_ready(a_ready), .a_data(a_data),
        .b_valid(b_valid), .b_ready(b_ready), .b_data(b_data),
        .f0_valid(f0_valid), .f0_ready(f0_ready), .f0_data(f0_data),
        .f1_valid(f1_valid), .f1_ready(f1_ready), .f1_data(f1_data)
    );

    integer ci, i;
    integer pass_count, fail_count;
    logic [Q_WIDTH-1:0] c0_1_vec[N-1:0];
    logic [Q_WIDTH-1:0] c1_1_vec[N-1:0];
    logic [Q_WIDTH-1:0] c0_2_vec[N-1:0];
    logic [Q_WIDTH-1:0] c1_2_vec[N-1:0];
    logic [Q_WIDTH-1:0] a_vec[N-1:0];
    logic [Q_WIDTH-1:0] b_vec[N-1:0];
    logic [Q_WIDTH-1:0] f0_out[N-1:0];
    logic [Q_WIDTH-1:0] f1_out[N-1:0];

    // ------------------------------------------------------------------
    // 单例执行：start -> 加载 6 路流 -> 等 done -> negedge 采样 f0/f1
    // ------------------------------------------------------------------
    task automatic run_case(input integer case_idx);
        automatic integer timeout;
        automatic integer mism;
        automatic integer base;

        base = case_idx * N;
        for (i = 0; i < N; i = i + 1) begin
            c0_1_vec[i] = c0_1_all[base + i];
            c1_1_vec[i] = c1_1_all[base + i];
            c0_2_vec[i] = c0_2_all[base + i];
            c1_2_vec[i] = c1_2_all[base + i];
            a_vec[i]    = a_all[base + i];
            b_vec[i]    = b_all[base + i];
        end

        gear_sel = 3'd0;
        repeat(3) @(posedge clk);

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;

        // ---- 加载 c0_1 ----
        for (i = 0; i < N; i = i + 1) begin
            while (!c0_1_ready) @(posedge clk);
            @(posedge clk);
            c0_1_valid = 1'b1;
            c0_1_data  = c0_1_vec[i];
            @(posedge clk);
            c0_1_valid = 1'b0;
        end
        // ---- 加载 c1_1 ----
        for (i = 0; i < N; i = i + 1) begin
            while (!c1_1_ready) @(posedge clk);
            @(posedge clk);
            c1_1_valid = 1'b1;
            c1_1_data  = c1_1_vec[i];
            @(posedge clk);
            c1_1_valid = 1'b0;
        end
        // ---- 加载 c0_2 ----
        for (i = 0; i < N; i = i + 1) begin
            while (!c0_2_ready) @(posedge clk);
            @(posedge clk);
            c0_2_valid = 1'b1;
            c0_2_data  = c0_2_vec[i];
            @(posedge clk);
            c0_2_valid = 1'b0;
        end
        // ---- 加载 c1_2 ----
        for (i = 0; i < N; i = i + 1) begin
            while (!c1_2_ready) @(posedge clk);
            @(posedge clk);
            c1_2_valid = 1'b1;
            c1_2_data  = c1_2_vec[i];
            @(posedge clk);
            c1_2_valid = 1'b0;
        end
        // ---- 加载 a ----
        for (i = 0; i < N; i = i + 1) begin
            while (!a_ready) @(posedge clk);
            @(posedge clk);
            a_valid = 1'b1;
            a_data  = a_vec[i];
            @(posedge clk);
            a_valid = 1'b0;
        end
        // ---- 加载 b ----
        for (i = 0; i < N; i = i + 1) begin
            while (!b_ready) @(posedge clk);
            @(posedge clk);
            b_valid = 1'b1;
            b_data  = b_vec[i];
            @(posedge clk);
            b_valid = 1'b0;
        end

        // ---- 等待 done ----
        timeout = 0;
        while (!done && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(posedge clk);
        #1;

        if (!done) begin
            $display("[FAIL] E33 case %0d: TIMEOUT after %0d cycles", case_idx, timeout);
            fail_count = fail_count + 1;
            f0_ready = 1'b0;
            f1_ready = 1'b0;
            repeat(10) @(posedge clk);
            return;
        end

        // ---- 采样 f0（negedge 握手，同 tb_e2e_ckks_mult_ctrl_m4）----
        @(negedge clk);
        f0_ready = 1'b1;
        for (i = 0; i < N; i = i + 1) begin
            automatic integer f0_wt;
            f0_wt = 0;
            while (!f0_valid && f0_wt < 200) begin
                @(negedge clk);
                f0_wt = f0_wt + 1;
            end
            f0_out[i] = f0_data;
            @(posedge clk);
            @(negedge clk);
        end
        f0_ready = 1'b0;
        @(posedge clk);
        @(negedge clk);

        // ---- 采样 f1 ----
        f1_ready = 1'b1;
        for (i = 0; i < N; i = i + 1) begin
            automatic integer f1_wt;
            f1_wt = 0;
            while (!f1_valid && f1_wt < 200) begin
                @(negedge clk);
                f1_wt = f1_wt + 1;
            end
            f1_out[i] = f1_data;
            @(posedge clk);
            @(negedge clk);
        end
        f1_ready = 1'b0;

        // ---- 落盘 + 逐系数 golden 比对 ----
        mism = 0;
        for (i = 0; i < N; i = i + 1) begin
            dut_f0_all[base + i] = f0_out[i];
            dut_f1_all[base + i] = f1_out[i];
            if (f0_out[i] !== exp_f0_all[base + i]) mism = mism + 1;
            if (f1_out[i] !== exp_f1_all[base + i]) mism = mism + 1;
        end
        if (mism == 0) begin
            $display("[PASS] E33 case %0d: bit-exact vs RTL-exact reference (32/32 coeffs)", case_idx);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] E33 case %0d: %0d/32 coefficients differ from reference", case_idx, mism);
            fail_count = fail_count + 1;
        end

        repeat(10) @(posedge clk);
    endtask

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    initial begin
        $readmemh("../../tb/ref/e33_c0_1.hex", c0_1_all);
        $readmemh("../../tb/ref/e33_c1_1.hex", c1_1_all);
        $readmemh("../../tb/ref/e33_c0_2.hex", c0_2_all);
        $readmemh("../../tb/ref/e33_c1_2.hex", c1_2_all);
        $readmemh("../../tb/ref/e33_a.hex",    a_all);
        $readmemh("../../tb/ref/e33_b.hex",    b_all);
        $readmemh("../../tb/ref/e33_exp_f0.hex", exp_f0_all);
        $readmemh("../../tb/ref/e33_exp_f1.hex", exp_f1_all);

        if (c0_1_all[0] === 1'bx) begin
            $display("E33 HEX LOAD FAILED");
            $finish;
        end


        rst_n = 0;
        start = 0;
        gear_sel = 0;
        c0_1_valid = 0; c1_1_valid = 0; c0_2_valid = 0; c1_2_valid = 0;
        a_valid = 0; b_valid = 0;
        c0_1_data = 0; c1_1_data = 0; c0_2_data = 0; c1_2_data = 0;
        a_data = 0; b_data = 0;
        f0_ready = 0; f1_ready = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        pass_count = 0;
        fail_count = 0;

        $display("=========================================");
        $display(" E33 Real-RLWE-Ciphertext E2E Execution");
        $display("=========================================");

        for (ci = 0; ci < NUM_CASES; ci = ci + 1) begin
            run_case(ci);
        end

        $writememh("e33_dut_f0.hex", dut_f0_all);
        $writememh("e33_dut_f1.hex", dut_f1_all);

        $display("E33 RESULT: %0d PASS / %0d FAIL", pass_count, fail_count);
        if (fail_count == 0) $display("E33 ALL PASS");
        else $display("E33 HAS FAILURES");
        $finish;
    end

    // 全局看门狗
    initial begin
        #(20 * 1000000);
        $display("E33 GLOBAL TIMEOUT");
        $writememh("e33_dut_f0.hex", dut_f0_all);
        $writememh("e33_dut_f1.hex", dut_f1_all);
        $finish;
    end

endmodule
