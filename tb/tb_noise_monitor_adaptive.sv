// =============================================================================
// tb_noise_monitor_adaptive.sv — M4-h noise_monitor + adaptive_gear_ctrl 联合 TB
//
// 玩具配置: N=16, Q_WIDTH=7, Q=113
//
// 测试用例（严格串行执行，避免 DUT 状态互相干扰）：
//   Test 1: noise_monitor s=[1,...,1]    -> energy=1,   count=16
//   Test 2: noise_monitor s=[0,...,0]    -> energy=0,   count=16
//   Test 3: noise_monitor s=[5,...,5]    -> energy=25
//   Test 3b: noise_monitor s=[108,...]   -> energy=25  (对称：|108-113|=5)
//   Test 4-7: adaptive_gear_ctrl 直接注入不同 energy 值
//   Test 8/8b: 端到端 noise_monitor + adaptive_gear_ctrl
//   Test 9:  迟滞模式：连续 3 次升档候选后 gear 才升
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_noise_monitor_adaptive;

    // =========================================================================
    // 玩具配置
    // =========================================================================
    localparam N        = 16;
    localparam Q_WIDTH  = 7;
    localparam Q_VAL    = 7'd113;

    localparam ACC_W    = 64;
    localparam logic [ACC_W-1:0] THRESH_G1 = 64'd500;
    localparam logic [ACC_W-1:0] THRESH_G2 = 64'd200;
    localparam logic [ACC_W-1:0] THRESH_G3 = 64'd50;

    // =========================================================================
    // 时钟 & 复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 信号
    // =========================================================================
    logic                     load_start;
    logic                     s_valid;
    logic [Q_WIDTH-1:0]       s_data;
    logic [Q_WIDTH-1:0]       q_val_in;
    logic [ACC_W-1:0]         energy_q2_nm;   // noise_monitor output
    logic [ACC_W-1:0]         energy_q2_in;   // adaptive_gear_ctrl input
    logic                     force_energy_en;
    logic [ACC_W-1:0]         force_energy_val;
    logic [Q_WIDTH+8:0]       sample_count;
    logic                     flush_valid;
    logic                     flush_valid_seen;  // 捕获脉冲：单周期 pulse 在采样后立即变 0
    logic [ACC_W-1:0]         energy_q2_sampled; // B4: 除法完成后采样的能量
    logic                     saturated;

    logic [2:0]               gear_sel;
    logic [2:0]               gear_raw;
    logic                     hysteresis_en;
    logic [2:0]               manual_gear;
    logic                     manual_en;

    // energy_q2 mux
    always_comb begin
        if (force_energy_en) energy_q2_in = force_energy_val;
        else                 energy_q2_in = energy_q2_nm;
    end

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    noise_monitor #(
        .Q_WIDTH(Q_WIDTH),
        .N(N),
        .ACC_W(ACC_W)          // 玩具 64；生产默认 106（显式覆盖，避免位宽错配）
    ) u_nm (
        .clk(clk),
        .rst_n(rst_n),
        .load_start(load_start),
        .s_valid(s_valid),
        .s_data(s_data),
        .q_val(q_val_in),
        .energy_q2(energy_q2_nm),
        .sample_count(sample_count),
        .flush_valid(flush_valid),
        .saturated(saturated)
    );

    adaptive_gear_ctrl #(
        .ACC_W(ACC_W),
        .THRESH_G1(THRESH_G1),
        .THRESH_G2(THRESH_G2),
        .THRESH_G3(THRESH_G3),
        .HYST_CNT(3)
    ) u_agc (
        .clk(clk),
        .rst_n(rst_n),
        .energy_q2(energy_q2_in),
        .flush_valid(flush_valid),
        .hysteresis_en(hysteresis_en),
        .manual_gear(manual_gear),
        .manual_en(manual_en),
        .gear_sel(gear_sel),
        .gear_raw(gear_raw)
    );

    // =========================================================================
    // 初始化
    // =========================================================================
    initial begin
        load_start     = 1'b0;
        s_valid        = 1'b0;
        s_data         = '0;
        q_val_in       = Q_VAL;
        hysteresis_en  = 1'b0;
        manual_gear    = '0;
        manual_en      = 1'b0;
        force_energy_en  = 1'b0;
        force_energy_val = '0;
    end

    // =========================================================================
    // 测试辅助 task
    // =========================================================================
    task automatic do_reset;
        rst_n = 1'b0;
        @(posedge clk); @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    task automatic send_coeff(input logic [Q_WIDTH-1:0] val);
        @(negedge clk);
        s_valid = 1'b1;
        s_data  = val;
        @(negedge clk);   // 保持一个完整周期，避免 s_valid=0 与 DUT 采样竞争
        s_valid = 1'b0;
    endtask

    task automatic pulse_load_start;
        // 注（B4 修复后）：noise_monitor 的除法器从单周期组合 `/` 改为
        // 受控恢复除法（ACC_W 拍流水）。flush_valid/energy_q2 因此延迟
        // 到除法完成才有效。本任务等待「延迟的 flush_valid」再采样，
        // 并把最终能量存入 energy_q2_sampled 供断言使用。
        // 单周期脉冲语义不变：flush_valid_seen 仅在真正检测到脉冲后置 1。
        @(negedge clk);
        flush_valid_seen = 1'b0;
        energy_q2_sampled = '0;
        load_start = 1'b1;
        @(posedge clk);            // always_ff 采样到 load_start=1（锁存被除数/重置）
        @(negedge clk);
        load_start = 1'b0;
        // 等除法器完成（flush_valid 上升沿），最多 ACC_W+8 拍
        begin : wait_div
            automatic integer w = 0;
            while (flush_valid !== 1'b1 && w < ACC_W + 8) begin
                @(negedge clk);
                w = w + 1;
            end
            flush_valid_seen = flush_valid_seen | flush_valid;
        end
        @(posedge clk);            // 除法完成、NBA 后 energy_q2 有效
        energy_q2_sampled = energy_q2_nm;
        @(posedge clk);            // 等 adaptive_gear_ctrl 采样 flush_valid 到位
        @(posedge clk);            // 确保 TB 读到更新后的 gear_sel/energy_q2
    endtask

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check(input string name, input logic cond);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("[PASS] %s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %s  (期望 True, 实际 False)", name);
            end
        end
    endtask

    // =========================================================================
    // 主测试（串行执行）
    // =========================================================================
    initial begin
        $display("==== M4-h noise_monitor + adaptive_gear_ctrl TB ====");

        // ===================================================================
        $display("\n---- Test 1: noise_monitor s=[1,...,1] -> energy=1 ----");
        do_reset;
        force_energy_en = 1'b0;
        pulse_load_start;  // 清空累加器
        @(posedge clk);
        for (int i = 0; i < N; i = i + 1) begin
            send_coeff(7'd1);
        end
        pulse_load_start;
        check("Test 1a: flush_valid=1 (single-cycle pulse seen)", flush_valid_seen === 1'b1);
        check("Test 1b: sample_count=16", sample_count === N[Q_WIDTH+8:0]);
        check("Test 1c: energy_q2=1", energy_q2_sampled === 64'd1);
        $display("  [info] energy=%0d count=%0d", energy_q2_nm, sample_count);

        // ===================================================================
        $display("\n---- Test 2: noise_monitor s=[0,...,0] -> energy=0 ----");
        do_reset;
        pulse_load_start;
        for (int i = 0; i < N; i = i + 1) begin
            send_coeff(7'd0);
        end
        pulse_load_start;
        check("Test 2: energy=0 for all-zero", energy_q2_sampled === 64'd0);
        $display("  [info] energy=%0d count=%0d", energy_q2_nm, sample_count);

        // ===================================================================
        $display("\n---- Test 3: noise_monitor s=[5,...,5] -> energy=25 ----");
        do_reset;
        pulse_load_start;
        for (int i = 0; i < N; i = i + 1) begin
            send_coeff(7'd5);
        end
        pulse_load_start;
        check("Test 3: energy=25 for s=5", energy_q2_sampled === 64'd25);
        $display("  [info] energy=%0d count=%0d", energy_q2_nm, sample_count);

        // ===================================================================
        $display("\n---- Test 3b: s=[108,...,108] (对称 |s|=5) -> energy=25 ----");
        do_reset;
        pulse_load_start;
        for (int i = 0; i < N; i = i + 1) begin
            send_coeff(7'd108);
        end
        pulse_load_start;
        check("Test 3b: energy=25 for s=108", energy_q2_sampled === 64'd25);
        $display("  [info] energy=%0d count=%0d", energy_q2_nm, sample_count);

        // ===================================================================
        $display("\n---- Test 4-7: adaptive_gear_ctrl 直接注入 energy ----");
        do_reset;
        hysteresis_en = 1'b0;
        force_energy_en = 1'b1;
        pulse_load_start;  // 空 flush 初始化

        // Test 4: energy=10 -> gear=3
        @(negedge clk); force_energy_val = 64'd10; @(posedge clk);
        pulse_load_start;
        check("Test 4: energy=10 -> gear=3", gear_sel === 3'd3);
        $display("  [info] energy=10  gear_sel=%0d", gear_sel);

        // Test 5: energy=100 -> gear=2
        @(negedge clk); force_energy_val = 64'd100; @(posedge clk);
        pulse_load_start;
        check("Test 5: energy=100 -> gear=2", gear_sel === 3'd2);
        $display("  [info] energy=100  gear_sel=%0d", gear_sel);

        // Test 6: energy=300 -> gear=1
        @(negedge clk); force_energy_val = 64'd300; @(posedge clk);
        pulse_load_start;
        check("Test 6: energy=300 -> gear=1", gear_sel === 3'd1);
        $display("  [info] energy=300  gear_sel=%0d", gear_sel);

        // Test 7: energy=1000 -> gear=0
        @(negedge clk); force_energy_val = 64'd1000; @(posedge clk);
        pulse_load_start;
        check("Test 7: energy=1000 -> gear=0", gear_sel === 3'd0);
        $display("  [info] energy=1000  gear_sel=%0d", gear_sel);

        // ===================================================================
        $display("\n---- Test 8: 端到端 低能量 (s=[1,...,1], energy=1 -> gear=3) ----");
        do_reset;
        force_energy_en = 1'b0;
        hysteresis_en = 1'b0;
        pulse_load_start;
        for (int i = 0; i < N; i = i + 1) begin
            send_coeff(7'd1);
        end
        pulse_load_start;
        check("Test 8a: end-to-end energy=1", energy_q2_sampled === 64'd1);
        check("Test 8b: end-to-end gear=3", gear_sel === 3'd3);
        $display("  [info] energy=%0d gear_sel=%0d", energy_q2_nm, gear_sel);

        // ===================================================================
        $display("\n---- Test 8c: 端到端 高能量 (s=[25,...,25], energy=625 -> gear=0) ----");
        do_reset;
        force_energy_en = 1'b0;
        hysteresis_en = 1'b0;
        pulse_load_start;
        for (int i = 0; i < N; i = i + 1) begin
            send_coeff(7'd25);
        end
        pulse_load_start;
        check("Test 8c-a: energy=625", energy_q2_sampled === 64'd625);
        check("Test 8c-b: gear=0 for high energy", gear_sel === 3'd0);
        $display("  [info] energy=%0d gear_sel=%0d", energy_q2_nm, gear_sel);

        // ===================================================================
        $display("\n---- Test 9: 迟滞模式 ----");
        do_reset;
        hysteresis_en = 1'b1;
        force_energy_en = 1'b1;
        // 先把 gear 定到 0
        force_energy_val = 64'd1000;
        pulse_load_start;
        check("Test 9-prep: gear=0", gear_sel === 3'd0);

        // 第 1 次低能量：候选 gear=3，但迟滞计数=1，未升
        force_energy_val = 64'd10;
        pulse_load_start;
        check("Test 9.1: 1st low energy, gear still 0", gear_sel === 3'd0);
        $display("  [info] after 1st: gear_sel=%0d", gear_sel);

        // 第 2 次：计数=2，仍未升
        pulse_load_start;
        check("Test 9.2: 2nd low energy, gear still 0", gear_sel === 3'd0);
        $display("  [info] after 2nd: gear_sel=%0d", gear_sel);

        // 第 3 次：计数=3，升到 3
        pulse_load_start;
        check("Test 9.3: 3rd low energy, gear=3", gear_sel === 3'd3);
        $display("  [info] after 3rd: gear_sel=%0d", gear_sel);

        // 降档立即生效
        force_energy_val = 64'd1000;
        pulse_load_start;
        check("Test 9.4: high energy -> immediate downgrade to 0", gear_sel === 3'd0);
        $display("  [info] after high: gear_sel=%0d", gear_sel);

        // ===================================================================
        $display("\n==== SUMMARY ====");
        $display("PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL PASS");
        end else begin
            $display("SOME FAILED");
        end
        $finish;
    end

    // 全局超时保护
    initial begin
        #500000;
        $display("GLOBAL TIMEOUT!");
        $finish;
    end

endmodule
