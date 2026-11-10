// =============================================================================
// tb_e2e_m4_noise_monitor.sv — M4-h.1 noise_monitor 接入 CKKS 数据流验证 (v4)
// =============================================================================
//
// 验证目标：noise_monitor 从「外部注入 demo」升级为「rescale 输出闭环」后的行为。
//
// v4 变更记录
// ---------
// 本 TB 在定位过程中发现并修复了一个自 M3-b 以来的潜伏缺陷：
//   rescale.sv 的 FSM 计数器 count 只在上电复位时清零，不在每次 start 时清零。
//   第二次及之后的操作中 count 从 N 继续递增，使 S_RUNNING -> S_DONE 的
//   (count == N-1) 判定永不成立；s_ready = m_ready && (state==S_RUNNING)
//   因此持续有效，把 wrapper 的 rs*_ridx 一路推到 2N-1，同一批系数被
//   采样/写入两遍（f0_out_buf 只被有效写 N 个，采样点与输出不再一一对应）。
//   定位证据（本 TB 的窗口分项计数，N=16）：
//       修复前：窗口1 nm_a=32 nm_b=32（sum=64 != 2N=32），ridx_max=31
//       修复后：三个窗口均 nm_a=16 nm_b=16（sum=32 = 2N），ridx_max=16
//   修复脚本：scripts/_b2_patch_rescale_count.py
//   同时给 start_ksw / start_rs0 / start_rs1 加了边沿检测，与 pm0/pm1a 一致，
//   见 scripts/_b2_patch_start_edge.py。
//
// 关键设计决策（v3 相对 v1/v2 的修正）
// ------------------------------------
// 1. wrapper 的 `done` 在进入 S_OUT_F0 时即拉高，不是操作真正结束。
//    故用 `busy` 落回 0（FSM 回 S_IDLE）判定操作结束。（v1 用 done 导致提前退出）
// 2. `start` 必须用独立单拍脉冲任务 pulse_start()，每次操作前后都拉低。
//    （v2 把 start 一直留高，导致 FSM 在 S_IDLE 反复重启、窗口被多次重置，
//      sample_count 出现 39 而非 32）
// 3. noise_monitor 的 `sample_count` 是「上一窗口」寄存器，只在 load_start 时锁存。
//    故必须在 flush 之后读，不能在窗口中途读。（v2 的 T1 断言位置错误）
// 4. 断言不硬编码「哪个能量对应哪个档位」，而是：
//      (a) 一致性：档位 == 查表(实测能量)  —— 证明闭环接线正确、能量是唯一驱动
//      (b) 方向性：低幅度能量 < 高幅度能量，且 低能量档位 >= 高能量档位
//    这样阈值取值不影响测试有效性，避免「用被测逻辑的输出定义自己的期望值」。
//
// 反馈环语义
// ----------
//   第 L 次操作的 start 上升沿结算第 L-1 次操作窗口的能量，
//   并据此更新档位；该档位在第 L 次操作的 poly_mult 启动前已稳定生效。
//   即「1 层延迟反馈」，与 CKKS 逐层噪声预算的物理含义一致。
//
// 玩具配置: N=16, LOG_N=4, Q_WIDTH=7, Q_IN=113, Q_OUT=97, USE_FASTRED=0
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e2e_m4_noise_monitor;
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

    localparam int       ACC_W   = 64;
    localparam int       CNT_W   = Q_WIDTH + 9;
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
    // DUT 信号
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

    logic [2:0]       gear_sel_static;
    logic             mode_sel;
    logic [ACC_W-1:0] energy_q2_ext;
    logic             flush_valid_ext;
    logic             hysteresis_en;
    logic [2:0]       manual_gear;
    logic             manual_en;

    logic             noise_mon_en;
    logic [ACC_W-1:0] energy_q2_int;
    logic             nm_flush_valid;
    logic [CNT_W-1:0] nm_sample_count;
    logic             nm_saturated;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    e2e_ckks_mult_ctrl_m4 #(
        .LOG_N    (LOG_N), .N(N), .Q_WIDTH(Q_WIDTH),
        .Q_IN(Q_IN), .Q_OUT(Q_OUT), .N_INV(N_INV), .USE_FASTRED(0),
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
        .noise_mon_en(noise_mon_en),
        .energy_q2_int(energy_q2_int),
        .nm_flush_valid(nm_flush_valid),
        .nm_sample_count(nm_sample_count),
        .nm_saturated(nm_saturated),
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

    wire [2:0] gear_eff_obs = u_dut.gear_sel_eff;

    // =========================================================================
    // TB 侧独立参考模型
    // -------------------------------------------------------------------------
    // noise_monitor 定义：abs_s = min(s, q - s);  energy = sum(abs_s^2) / count
    // TB 在 f0_valid/f1_valid 期间独立累加同一组 rescale 输出系数。
    // f0_data/f1_data 来自 f*_out_buf，而 f*_out_buf 正是由 rs*_m_data 写入，
    // 故两组观测到的是完全相同的系数序列 —— 这是交叉校验 energy 的基础。
    // =========================================================================
    integer           ref_count;
    logic [ACC_W-1:0] ref_sum_sq;

    function automatic logic [ACC_W-1:0] coef_energy(input logic [Q_WIDTH-1:0] c);
        automatic logic [Q_WIDTH:0] a, qm;
        begin
            qm = {1'b0, Q_OUT} - {1'b0, c};
            a  = (c <= qm) ? {1'b0, c} : qm;
            coef_energy = ACC_W'(a * a);
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            ref_sum_sq <= '0;
            ref_count  <= 0;
        end else begin
            if (f0_valid && f0_ready) begin
                ref_sum_sq <= ref_sum_sq + coef_energy(f0_data);
                ref_count  <= ref_count + 1;
            end
            if (f1_valid && f1_ready) begin
                ref_sum_sq <= ref_sum_sq + coef_energy(f1_data);
                ref_count  <= ref_count + 1;
            end
        end
    end

    wire [ACC_W-1:0] ref_energy = (ref_count > 0) ? (ref_sum_sq / ref_count) : '0;

    // =========================================================================
    // 窗口内分项计数（诊断用：验证采样点与实际输出一一对应）
    //   nm_a/nm_b : noise_monitor 采样拍数（按 rescale 0/1 分类）
    //   f0/f1     : TB 参考模型在输出端观测到的拍数
    // 期望：nm_a = f0 = N 且 nm_b = f1 = N（合计 2N），四者必须一致。
    // =========================================================================
    integer dbg_a, dbg_b, dbg_f0, dbg_f1;

    always @(posedge clk) begin
        if (!rst_n) begin
            dbg_a <= 0; dbg_b <= 0; dbg_f0 <= 0; dbg_f1 <= 0;
        end else begin
            if (u_dut.nm_s_valid_a)   dbg_a  <= dbg_a  + 1;
            if (u_dut.nm_s_valid_b)   dbg_b  <= dbg_b  + 1;
            if (f0_valid && f0_ready) dbg_f0 <= dbg_f0 + 1;
            if (f1_valid && f1_ready) dbg_f1 <= dbg_f1 + 1;
        end
    end

    task automatic dbg_dump(input string tag);
        begin
            $display("  [count %s] monitor: rs0=%0d rs1=%0d (sum=%0d) | output: f0=%0d f1=%0d | sample_count=%0d",
                     tag, dbg_a, dbg_b, dbg_a + dbg_b, dbg_f0, dbg_f1,
                     nm_sample_count);
            dbg_a = 0; dbg_b = 0; dbg_f0 = 0; dbg_f1 = 0;
        end
    endtask



    // AGC 查表（TB 侧独立复算，用于一致性断言）
    function automatic logic [2:0] agc_lookup(input logic [ACC_W-1:0] e);
        begin
            if      (e < AGC_TH_G3) agc_lookup = 3'd3;
            else if (e < AGC_TH_G2) agc_lookup = 3'd2;
            else if (e < AGC_TH_G1) agc_lookup = 3'd1;
            else                    agc_lookup = 3'd0;
        end
    endfunction

    // =========================================================================
    // 测试基础设施
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

    // 干净的单拍 start 脉冲：S_IDLE 期间拉高一拍后立即拉低
    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // B4 修复后：noise_monitor 除法器从单周期组合 `/` 改为受控恢复除法
    //（ACC_W+1 拍流水）。能量/档位在 start 后 ACC_W 拍才更新。
    // 本任务等内部 nm_flush_valid（除法完成标志）上升，再采样能量与档位。
    task automatic wait_nm_flush;
        begin : wb
            automatic integer w = 0;
            while (nm_flush_valid !== 1'b1 && w < ACC_W + 16) begin
                @(posedge clk);
                w = w + 1;
            end
            @(posedge clk);   // 能量/档位在此拍后稳定
            @(posedge clk);
        end
    endtask

    integer noise_amp;   // 0=全零(最小能量) 1=小幅度 2=大幅度
    integer ld_idx;

    // 加载一路密文，which: 0=c0_1 1=c1_1 2=c0_2 3=c1_2 4=a 5=b
    task automatic load_stream(input integer which);
        automatic logic [Q_WIDTH-1:0] base;
        automatic logic              rdy;
        begin
            for (ld_idx = 0; ld_idx < N; ld_idx = ld_idx + 1) begin
                case (noise_amp)
                    0:    base = 7'd0;                              // 全零
                    1:    base = 7'((ld_idx * 3 + 1 + which) % 7'd9);   // 小幅度
                    default: base = 7'((ld_idx * 37 + 11 + which * 53) % Q_IN); // 大幅度
                endcase
                @(negedge clk);
                case (which)
                    0: begin c0_1_valid = 1'b1; c0_1_data = base; end
                    1: begin c1_1_valid = 1'b1; c1_1_data = base; end
                    2: begin c0_2_valid = 1'b1; c0_2_data = base; end
                    3: begin c1_2_valid = 1'b1; c1_2_data = base; end
                    4: begin a_valid    = 1'b1; a_data    = base; end
                    5: begin b_valid    = 1'b1; b_data    = base; end
                endcase
                rdy = 1'b0;
                while (rdy !== 1'b1) begin
                    @(posedge clk);
                    case (which)
                        0: rdy = c0_1_ready;
                        1: rdy = c1_1_ready;
                        2: rdy = c0_2_ready;
                        3: rdy = c1_2_ready;
                        4: rdy = a_ready;
                        5: rdy = b_ready;
                    endcase
                    if (rdy !== 1'b1) begin
                        @(negedge clk);
                        case (which)
                            0: begin c0_1_valid = 1'b1; c0_1_data = base; end
                            1: begin c1_1_valid = 1'b1; c1_1_data = base; end
                            2: begin c0_2_valid = 1'b1; c0_2_data = base; end
                            3: begin c1_2_valid = 1'b1; c1_2_data = base; end
                            4: begin a_valid    = 1'b1; a_data    = base; end
                            5: begin b_valid    = 1'b1; b_data    = base; end
                        endcase
                    end
                end
            end
            @(negedge clk);
            c0_1_valid = 1'b0; c1_1_valid = 1'b0;
            c0_2_valid = 1'b0; c1_2_valid = 1'b0;
            a_valid    = 1'b0; b_valid    = 1'b0;
        end
    endtask

    task automatic load_all;
        begin
            load_stream(0); load_stream(1);
            load_stream(2); load_stream(3);
            load_stream(4); load_stream(5);
        end
    endtask

    // 等一次操作真正结束：busy 拉高后再落回 0（FSM 回到 S_IDLE）
    task automatic wait_op_end;
        begin
            while (busy !== 1'b1) @(posedge clk);
            while (busy !== 1'b0) @(posedge clk);
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // 主测试流程
    // =========================================================================
    integer i;
    logic [ACC_W-1:0] e_zero, e_small, e_large;
    logic [2:0]        g_zero, g_small, g_large;
    integer            c_zero, c_small, c_large;

    initial begin
        mode_sel        = 1'b1;
        gear_sel_static = 3'd0;
        energy_q2_ext   = '0;
        flush_valid_ext = 1'b0;
        hysteresis_en   = 1'b0;
        manual_gear     = 3'd0;
        manual_en       = 1'b0;
        noise_mon_en    = 1'b1;
        start = 1'b0;
        c0_1_valid = 1'b0; c1_1_valid = 1'b0;
        c0_2_valid = 1'b0; c1_2_valid = 1'b0;
        a_valid    = 1'b0; b_valid    = 1'b0;
        c0_1_data = '0; c1_1_data = '0;
        c0_2_data = '0; c1_2_data = '0;
        a_data = '0; b_data = '0;
        f0_ready = 1'b1; f1_ready = 1'b1;
        noise_amp = 0;


        $display("==== M4-h.1 Noise Monitor Integration TB (v4) ====");
        $display("Toy: N=%0d Q_WIDTH=%0d Q_IN=%0d Q_OUT=%0d", N, Q_WIDTH, Q_IN, Q_OUT);
        $display("AGC thresholds: G1=%0d G2=%0d G3=%0d", AGC_TH_G1, AGC_TH_G2, AGC_TH_G3);
        $display("");

        do_reset;

        // ===================================================================
        // 窗口 0：全零输入。start #1 时 load_start 触发，count_acc=0，
        // 首窗门控应把这次 flush 挡住（否则 energy=0 会被误判为极低噪声）。
        // ===================================================================
        $display("---- Window 0: all-zero input (tests first-window gating) ----");
        noise_amp = 0;
        ref_sum_sq = '0; ref_count = 0;
        dbg_a = 0; dbg_b = 0; dbg_f0 = 0; dbg_f1 = 0;

        pulse_start;                       // load_start #1（首窗门控生效点）
        @(posedge clk); @(posedge clk);
        check("T0: first window gated (sample_count=0 at flush)",
              nm_sample_count == '0);
        check("T0: gear stays at Gear 0 (no unsafe jump to Gear 3)",
              gear_eff_obs === 3'd0);
        $display("  [info] gear after first flush = %0d", gear_eff_obs);

        load_all;
        wait_op_end;
        $display("  [info] op1 done: ref_count=%0d", ref_count);

        // ===================================================================
        // 窗口 1：仍然全零。start #2 时结算窗口 1 的能量（应≈0）-> Gear 3
        // ===================================================================
        $display("");
        $display("---- Window 1: all-zero again (lowest energy -> highest gear) ----");
        noise_amp = 0;

        pulse_start;                       // load_start #2 -> flush window 1
        wait_nm_flush;                     // B4: 等除法器完成
        e_zero  = energy_q2_int;
        g_zero  = gear_eff_obs;
        c_zero  = int'(nm_sample_count);
        $display("  [info] energy=%0d ref=%0d count=%0d gear=%0d",
                 e_zero, ref_energy, c_zero, g_zero);
        dbg_dump("w1");
        ref_sum_sq = '0; ref_count = 0;     // 读完之后再清，开始累计窗口 2

        check("T1: window 1 sample_count = 2N", nm_sample_count == CNT_W'(2*N));
        check("T3: window 1 energy matches TB reference", e_zero == ref_energy);
        check("T4a: window 1 gear == AGC lookup(measured energy)",
              g_zero == agc_lookup(e_zero));

        load_all;
        wait_op_end;

        // ===================================================================
        // 窗口 2：小幅度输入
        // ===================================================================
        $display("");
        $display("---- Window 2: small-amplitude input ----");
        noise_amp = 1;

        pulse_start;                       // flush window 2
        wait_nm_flush;                     // B4: 等除法器完成
        e_small = energy_q2_int;
        g_small = gear_eff_obs;
        c_small = int'(nm_sample_count);
        $display("  [info] energy=%0d ref=%0d count=%0d gear=%0d",
                 e_small, ref_energy, c_small, g_small);
        dbg_dump("w2");
        ref_sum_sq = '0; ref_count = 0;

        check("T1: window 2 sample_count = 2N", nm_sample_count == CNT_W'(2*N));
        check("T3: window 2 energy matches TB reference", e_small == ref_energy);
        check("T4a: window 2 gear == AGC lookup(measured energy)",
              g_small == agc_lookup(e_small));

        load_all;
        wait_op_end;

        // ===================================================================
        // 窗口 3：大幅度输入 -> 能量应显著升高 -> 档位应下降
        // ===================================================================
        $display("");
        $display("---- Window 3: large-amplitude input (high noise) ----");
        noise_amp = 2;

        pulse_start;                       // flush window 3
        wait_nm_flush;                     // B4: 等除法器完成
        e_large = energy_q2_int;
        g_large = gear_eff_obs;
        c_large = int'(nm_sample_count);
        $display("  [info] energy=%0d ref=%0d count=%0d gear=%0d",
                 e_large, ref_energy, c_large, g_large);
        dbg_dump("w3");
        ref_sum_sq = '0; ref_count = 0;

        check("T1: window 3 sample_count = 2N", nm_sample_count == CNT_W'(2*N));
        check("T3: window 3 energy matches TB reference", e_large == ref_energy);
        check("T4a: window 3 gear == AGC lookup(measured energy)",
              g_large == agc_lookup(e_large));

        load_all;
        wait_op_end;

        // ===================================================================
        // 方向性断言：能量随幅度单调上升，档位随能量单调下降
        // ===================================================================
        $display("");
        $display("---- Directionality: energy up => gear down ----");
        $display("  energies: zero=%0d small=%0d large=%0d", e_zero, e_small, e_large);
        $display("  gears   : zero=%0d small=%0d large=%0d", g_zero, g_small, g_large);

        check("T5a: energy(zero) <= energy(small) <= energy(large)",
              (e_zero <= e_small) && (e_small <= e_large));
        check("T5b: gear(zero) >= gear(small) >= gear(large)",
              (g_zero >= g_small) && (g_small >= g_large));
        check("T5c: large amplitude reaches a strictly worse gear than zero",
              g_large < g_zero);

        // ===================================================================
        // 向后兼容：noise_mon_en=0 时外部注入仍生效
        // ===================================================================
        $display("");
        $display("---- T6: backward compat (noise_mon_en=0) ----");
        noise_mon_en = 1'b0;
        energy_q2_ext   = 64'd10;
        flush_valid_ext = 1'b1;
        @(posedge clk); @(posedge clk);
        flush_valid_ext = 1'b0;
        @(posedge clk);
        check("T6a: ext energy=10 -> Gear 3", gear_eff_obs === 3'd3);
        $display("  [info] gear = %0d", gear_eff_obs);

        energy_q2_ext   = 64'd1000;
        flush_valid_ext = 1'b1;
        @(posedge clk); @(posedge clk);
        flush_valid_ext = 1'b0;
        @(posedge clk);
        check("T6b: ext energy=1000 -> Gear 0", gear_eff_obs === 3'd0);
        $display("  [info] gear = %0d", gear_eff_obs);

        // ===================================================================
        $display("");
        $display("---- health checks ----");
        check("health: nm_saturated never asserted", nm_saturated === 1'b0);
        check("health: error always 0", error === 1'b0);
        check("health: TB reference saw 2N coeffs in last window", ref_count == 2*N);

        $display("");
        $display("==== SUMMARY ====");
        $display("PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME FAILED");
        $finish;
    end

    initial begin
        #50000000;
        $display("GLOBAL TIMEOUT!");
        $finish;
    end

endmodule

`default_nettype wire
