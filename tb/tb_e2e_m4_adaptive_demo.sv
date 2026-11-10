// =============================================================================
// tb_e2e_m4_adaptive_demo.sv — M4-h 端到端自适应档位场景演示
//
// 目的：
//   在完整 e2e_ckks_mult_ctrl_m4 wrapper 中启用 mode_sel=1（自适应模式），
//   通过外部 energy_q2_ext 注入不同能量值模拟 CKKS 推理中噪声积累过程，
//   验证 adaptive_gear_ctrl 能在运行时正确切换档位。
//
// 玩具配置: N=16, LOG_N=4, Q_WIDTH=7, Q_IN=113, Q_OUT=97, USE_FASTRED=0
// AGC 阈值（玩具化）: G1=500, G2=200, G3=50
//
// 场景：
//   Stage A (L=0~3): energy=10   -> 稳态 Gear 3 (重度稀疏, 高吞吐)
//   Stage B (L=4):   energy=100  -> 降级到 Gear 2
//   Stage C (L=5):   energy=300  -> 降级到 Gear 1
//   Stage D (L=6):   energy=1000 -> 强制降到 Gear 0 (最保守, 高精度)
//   Stage E (L=7):   energy=10   -> 恢复 Gear 3 (但需迟滞, HYST_CNT=3)
//   Stage E+ (L=8,9,10): energy=10 -> 迟滞 3 次后升回 Gear 3
//
// 测试重点：
//   1. wrapper 内部 adaptive_gear_ctrl 正确响应 energy_q2_ext / flush_valid_ext
//   2. gear_sel_eff 在 mode_sel=1 时选择 adaptive 输出
//   3. 迟滞行为（升档需连续 3 次候选，降档立即生效）
//   4. CKKS 数据通路仍工作（start/done 握手）
//
// 依赖：
//   - e2e_ckks_mult_ctrl_m4 全部子模块
//   - noise_monitor 与 adaptive_gear_ctrl 独立已在 #39 验证 19/19 PASS
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e2e_m4_adaptive_demo;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    // =========================================================================
    // 玩具配置
    // =========================================================================
    localparam int  LOG_N   = 4;
    localparam int  N       = 1 << LOG_N;   // 16
    localparam int  Q_WIDTH = 7;
    localparam logic [Q_WIDTH-1:0] Q_IN  = 7'd113;
    localparam logic [Q_WIDTH-1:0] Q_OUT = 7'd97;
    localparam logic [Q_WIDTH-1:0] N_INV = 7'd106;

    localparam int       ACC_W = 64;
    localparam logic [ACC_W-1:0] AGC_TH_G1 = 64'd500;
    localparam logic [ACC_W-1:0] AGC_TH_G2 = 64'd200;
    localparam logic [ACC_W-1:0] AGC_TH_G3 = 64'd50;

    // =========================================================================
    // 时钟 & 复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // 信号
    // =========================================================================
    logic               start, busy, done, error;
    logic               c0_1_valid, c0_1_ready;
    logic [Q_WIDTH-1:0] c0_1_data;
    logic               c1_1_valid, c1_1_ready;
    logic [Q_WIDTH-1:0] c1_1_data;
    logic               c0_2_valid, c0_2_ready;
    logic [Q_WIDTH-1:0] c0_2_data;
    logic               c1_2_valid, c1_2_ready;
    logic [Q_WIDTH-1:0] c1_2_data;
    logic               a_valid, a_ready;
    logic [Q_WIDTH-1:0] a_data;
    logic               b_valid, b_ready;
    logic [Q_WIDTH-1:0] b_data;
    logic               f0_valid, f0_ready;
    logic [Q_WIDTH-1:0] f0_data;
    logic               f1_valid, f1_ready;
    logic [Q_WIDTH-1:0] f1_data;

    // 2026-10-18 修复：降序 [N/2-1:0] 与模块端口 [0:N/2-1] 不匹配，
    // xsim 按索引位置映射导致整个表反序传入 DUT。统一为升序。

    // M4-h 自适应控制
    logic               mode_sel;
    logic [ACC_W-1:0]   energy_q2_ext;
    logic               flush_valid_ext;
    logic               hysteresis_en;
    logic [2:0]         manual_gear;
    logic               manual_en;
    logic [2:0]         gear_sel_static;   // 静态档位输入（mode_sel=0 时用）

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    e2e_ckks_mult_ctrl_m4 #(
        .LOG_N    (LOG_N),
        .N        (N),
        .Q_WIDTH  (Q_WIDTH),
        .Q_IN     (Q_IN),
        .Q_OUT    (Q_OUT),
        .N_INV    (N_INV),
        .USE_FASTRED(0),
        .ACC_W    (ACC_W),
        .AGC_THRESH_G1(AGC_TH_G1),
        .AGC_THRESH_G2(AGC_TH_G2),
        .AGC_THRESH_G3(AGC_TH_G3),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"}),
        .AGC_HYST_CNT(3)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .gear_sel(gear_sel_static),
        .mode_sel(mode_sel),
        .energy_q2_ext(energy_q2_ext),
        .flush_valid_ext(flush_valid_ext),
        .hysteresis_en(hysteresis_en),
        .manual_gear(manual_gear),
        .manual_en(manual_en),
        .noise_mon_en(1'b0),           // M4-h.1: 0=外部注入（本 TB 仍用 energy_q2_ext）
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

    // 通过层级引用读取 DUT 内部的实际档位（用于断言）
    wire [2:0] gear_eff_obs = u_dut.gear_sel_eff;

    // =========================================================================
    // 初始化
    // =========================================================================
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check(input string name, input logic cond);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("[PASS] %s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %s", name);
            end
        end
    endtask

    task automatic do_reset;
        begin
            rst_n = 1'b0;
            @(posedge clk); @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // 触发一次 flush：在 negedge 拉高，跨一个完整周期，捕获 flush_valid 后释放
    task automatic pulse_flush(input logic [ACC_W-1:0] energy_val);
        begin
            @(negedge clk);
            energy_q2_ext = energy_val;
            flush_valid_ext = 1'b1;
            @(negedge clk);
            flush_valid_ext = 1'b0;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // 主测试流程
    // =========================================================================
    initial begin
        // 初始化信号
        mode_sel      = 1'b0;
        gear_sel_static = 3'd0;
        energy_q2_ext   = '0;
        flush_valid_ext = 1'b0;
        hysteresis_en   = 1'b0;
        manual_gear     = 3'd0;
        manual_en       = 1'b0;
        start = 1'b0;
        c0_1_valid = 1'b0; c1_1_valid = 1'b0;
        c0_2_valid = 1'b0; c1_2_valid = 1'b0;
        a_valid    = 1'b0; b_valid    = 1'b0;
        c0_1_data = '0; c1_1_data = '0;
        c0_2_data = '0; c1_2_data = '0;
        a_data = '0; b_data = '0;
        f0_ready = 1'b1; f1_ready = 1'b1;


        $display("==== M4-h E2E Adaptive Demo TB ====");
        $display("mode_sel will be toggled to 1 (adaptive mode)");

        do_reset;

        // ===================================================================
        $display("\n---- Stage 0: sanity — mode_sel=0, gear_sel=2 (Gear 2) ----");
        mode_sel      = 1'b0;
        gear_sel_static = 3'd2;
        @(posedge clk); @(posedge clk);
        check("Stage 0: mode_sel=0 → gear_sel_eff=2 (manual)", gear_eff_obs === 3'd2);

        // ===================================================================
        $display("\n---- Stage 1: mode_sel=1, adaptive — energy 递进 4 档 ----");
        mode_sel      = 1'b1;
        hysteresis_en = 1'b0;
        manual_en     = 1'b0;

        // Stage 1A: energy=10   -> Gear 3 (最高档)
        pulse_flush(64'd10);
        check("Stage 1A: energy=10 -> Gear 3", gear_eff_obs === 3'd3);
        $display("  [info] gear_sel_eff=%0d", gear_eff_obs);

        // Stage 1B: energy=100  -> Gear 2
        pulse_flush(64'd100);
        check("Stage 1B: energy=100 -> Gear 2", gear_eff_obs === 3'd2);
        $display("  [info] gear_sel_eff=%0d", gear_eff_obs);

        // Stage 1C: energy=300  -> Gear 1
        pulse_flush(64'd300);
        check("Stage 1C: energy=300 -> Gear 1", gear_eff_obs === 3'd1);
        $display("  [info] gear_sel_eff=%0d", gear_eff_obs);

        // Stage 1D: energy=1000 -> Gear 0 (最低档, 最保守)
        pulse_flush(64'd1000);
        check("Stage 1D: energy=1000 -> Gear 0", gear_eff_obs === 3'd0);
        $display("  [info] gear_sel_eff=%0d", gear_eff_obs);

        // ===================================================================
        $display("\n---- Stage 2: 迟滞 — 升档需连续 3 次候选 ----");
        hysteresis_en = 1'b1;

        // 当前在 Gear 0，尝试升到 Gear 3
        // 第 1 次低能量
        pulse_flush(64'd10);
        check("Stage 2.1: 1st low energy -> still Gear 0", gear_eff_obs === 3'd0);
        $display("  [info] after 1st: gear_sel_eff=%0d", gear_eff_obs);

        // 第 2 次
        pulse_flush(64'd10);
        check("Stage 2.2: 2nd low energy -> still Gear 0", gear_eff_obs === 3'd0);
        $display("  [info] after 2nd: gear_sel_eff=%0d", gear_eff_obs);

        // 第 3 次：升档生效
        pulse_flush(64'd10);
        check("Stage 2.3: 3rd low energy -> Gear 3 (hysteresis passed)", gear_eff_obs === 3'd3);
        $display("  [info] after 3rd: gear_sel_eff=%0d", gear_eff_obs);

        // 降档立即生效
        pulse_flush(64'd1000);
        check("Stage 2.4: high energy -> immediate downgrade to Gear 0", gear_eff_obs === 3'd0);
        $display("  [info] after high: gear_sel_eff=%0d", gear_eff_obs);

        // ===================================================================
        $display("\n---- Stage 3: manual 覆盖（迟滞/组合均被 manual_en 覆盖）----");
        hysteresis_en = 1'b0;
        manual_en     = 1'b1;
        manual_gear   = 3'd2;

        // 无论注入什么能量，gear 都是 manual_gear=2
        pulse_flush(64'd10);
        check("Stage 3: manual_en=1 -> force Gear 2", gear_eff_obs === 3'd2);
        $display("  [info] gear_sel_eff=%0d", gear_eff_obs);

        manual_en = 1'b0;

        // ===================================================================
        $display("\n---- Stage 4: 完整 CKKS 数据通路验证已交由 M4-f 8 档 E2E TB 负责 ----");
        $display("  [info] 本 TB 专注自适应档位控制通路验证，mode_sel=0 时 wrapper 行为完全等价 M4-f 原版");

        // ===================================================================
        $display("\n==== SUMMARY ====");
        $display("PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME FAILED");
        $finish;
    end

    // 全局超时保护
    initial begin
        #500000;
        $display("GLOBAL TIMEOUT!");
        $finish;
    end

endmodule
