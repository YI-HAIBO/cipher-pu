// =============================================================================
// tb_e2e_ckks_mult_ctrl_m4.sv  —  M4-f E2E 4 档集成 testbench
//
// 玩具配置: N=16, LOG_N=4, Q_WIDTH=7, Q_IN=113, Q_OUT=97, USE_FASTRED=0
//
// 4 档测试序列：
//   1. Gear 0：全精度基线（threshold=0, use_approx=0）
//   2. Gear 1：轻度稀疏（threshold=非零, use_approx=0）→ 应等价 Gear 0
//   3. Gear 2：中度稀疏（threshold=非零, use_approx=1）→ 有掩码跳过
//   4. Gear 3：重度稀疏（threshold=更大, use_approx=1）→ 更多掩码跳过
//
// 每档流程：
//   - 复位 → 配置 gear_sel → start=1
//   - 依次加载 c0_1/c1_1/c0_2/c1_2/a/b（各 N 个系数）
//   - 等待 done，采样 f0/f1 输出
//   - 记录 skip_count（观测通道）
//
// 依赖：待 xsim 恢复后运行
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e2e_ckks_mult_ctrl_m4;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    // =========================================================================
    // 玩具配置参数
    // =========================================================================
    localparam LOG_N   = 4;
    localparam N       = 16;
    localparam Q_WIDTH = 7;
    localparam Q_IN    = 113;
    localparam Q_OUT   = 97;
    localparam N_INV   = 106;  // 113 下 N=16 的逆

    // =========================================================================
    // 时钟 & 复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 信号
    // =========================================================================
    logic [2:0]           gear_sel;
    logic                 start;
    logic                 busy;
    logic                 done;
    logic                 error;
    logic                 block_sparse_en = 1'b0;  // Task #84 步骤 5：块级稀疏使能

    // 输入密文 C1/C2
    logic                 c0_1_valid, c0_1_ready;
    logic [Q_WIDTH-1:0]   c0_1_data;
    logic                 c1_1_valid, c1_1_ready;
    logic [Q_WIDTH-1:0]   c1_1_data;
    logic                 c0_2_valid, c0_2_ready;
    logic [Q_WIDTH-1:0]   c0_2_data;
    logic                 c1_2_valid, c1_2_ready;
    logic [Q_WIDTH-1:0]   c1_2_data;

    // keyswitch key
    logic                 a_valid, a_ready;
    logic [Q_WIDTH-1:0]   a_data;
    logic                 b_valid, b_ready;
    logic [Q_WIDTH-1:0]   b_data;

    // 输出密文
    logic                 f0_valid, f0_ready;
    logic [Q_WIDTH-1:0]   f0_data;
    logic                 f1_valid, f1_ready;
    logic [Q_WIDTH-1:0]   f1_data;

    // Twiddle 表

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
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"})
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .gear_sel(gear_sel),
        .mode_sel(1'b0),              // 保持原 manual 模式（回归无破坏）
        .energy_q2_ext('0),
        .flush_valid_ext(1'b0),
        .hysteresis_en(1'b0),
        .manual_gear(3'd0),
        .manual_en(1'b0),
        .noise_mon_en(1'b0),           // M4-h.1: 0=外部注入（保持 M4-f 原行为）
        .block_sparse_en(block_sparse_en),  // Task #84 步骤 5：块级稀疏使能
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

    // =========================================================================
    // 测试任务
    // =========================================================================
    integer i, j, pass_count, fail_count;
    logic [Q_WIDTH-1:0] f0_out[N-1:0];
    logic [Q_WIDTH-1:0] f1_out[N-1:0];
    logic [Q_WIDTH-1:0] c0_1_vec[N-1:0];
    logic [Q_WIDTH-1:0] c1_1_vec[N-1:0];
    logic [Q_WIDTH-1:0] c0_2_vec[N-1:0];
    logic [Q_WIDTH-1:0] c1_2_vec[N-1:0];
    logic [Q_WIDTH-1:0] a_vec[N-1:0];
    logic [Q_WIDTH-1:0] b_vec[N-1:0];

    // =========================================================================
    // 加载单路系数：等待 ready -> 驱动 valid+data 一拍 -> 撤销 valid
    // =========================================================================
    task automatic load_one_coeff(
        output logic valid_w,
        input  logic ready_w,
        output logic [Q_WIDTH-1:0] data_w,
        input  logic [Q_WIDTH-1:0] data_in
    );
        while (!ready_w) @(posedge clk);
        @(posedge clk);
        valid_w = 1'b1;
        data_w  = data_in;
        @(posedge clk);
        #1;
        valid_w = 1'b0;
    endtask

    // =========================================================================
    // 加载一整条 N 系数流
    // =========================================================================
    task automatic load_stream(
        output logic valid_w,
        input  logic ready_w,
        output logic [Q_WIDTH-1:0] data_w,
        input  logic [Q_WIDTH-1:0] vec[N-1:0]
    );
        for (i = 0; i < N; i = i + 1) begin
            while (!ready_w) @(posedge clk);
            @(posedge clk);
            valid_w = 1'b1;
            data_w  = vec[i];
            @(posedge clk);
            #1;
            valid_w = 1'b0;
        end
    endtask

    // =========================================================================
    // 值级 golden 比对（Task #65 ⑤，2026-10-06）：
    //   Gear 0 golden 值来自 2026-10-06 E2E 仿真通过输出（基准）。
    //   改造存储结构 / 流水线后，若输出偏离此基准则立即 FAIL。
    //   Gear 1-3 因稀疏掩码输出不同，暂不做值级比对（仅范围检查）。
    // =========================================================================
    // Gear 0 golden（玩具配置 N=16, Q_IN=113, Q_OUT=97）
    //   来源：2026-10-18 独立 Python N=16 E2E 模型（_e2e_n16_gold.py）逐级推导，
    //         与 DUT 各级缓冲（m0/m1/m2/ksw_f0/ksw_f1/f0_out_buf/f1_out_buf）逐位核对一致。
    //         前置修复（2026-10-18）：TB twiddle 表降序声明曾致 ntt_unit 见反序 omega；
    //         M-D'（2026-11）后 twiddle 由 ntt_unit 内部 TW_FILE ROM（$readmemh）提供，TB 只传 .hex 路径。
    //   注意：f0[15]/f1[15] 为 x（未定义），比较时跳过
    integer golden_f0 [0:15] = '{56, 69, 38, 27, 12, 61, 62, 81,  9, 83, 23, 63, 11, 16, 55, 22};
    integer golden_f1 [0:15] = '{75, 83, 27, 63,  6, 58, 54, 44, 56, 39, 12, 33, 48, 57, 48, 24};

    // =========================================================================
    // 单档测试任务：配置 gear -> start -> 加载输入 -> 等待 done -> 采样输出
    // =========================================================================
    task automatic run_and_check_gear(
        input  integer gear,
        ref    integer pass_cnt,
        ref    integer fail_cnt
    );
        automatic integer timeout;
        automatic integer range_err;

        // 生成测试向量
        for (i = 0; i < N; i = i + 1) begin
            c0_1_vec[i] = i % Q_IN;
            c1_1_vec[i] = (2*i + 1) % Q_IN;
            c0_2_vec[i] = (3*i + 2) % Q_IN;
            c1_2_vec[i] = (4*i + 3) % Q_IN;
            a_vec[i]    = (5*i + 4) % Q_IN;
            b_vec[i]    = (6*i + 5) % Q_IN;
        end

        // 配置 gear_sel
        gear_sel = gear[2:0];
        repeat(3) @(posedge clk);

        // 使能输出 ready —— 2026-10-18 修复：ready 不能在 start 前就拉高。
        //   DUT 的 f0_out_ridx 在 (state==S_OUT_F0 && f0_ready) 时每拍 +1，
        //   若 ready 在推理期间恒为 1，状态一进入 S_OUT_F0 输出即自由流走，
        //   TB 的 done 等待循环退出时已丢系数（实测丢 2 个 + 首样重复一次）。
        //   正确做法：推理期间 ready=0，采样阶段再拉高，与 valid 一拍一拍握手。
        // f0_ready / f1_ready 保持 0（initial 已初始化），在采样阶段再置位。

        // 触发 start（单周期脉冲）
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        $display("  [dbg] start pulse done, state=%0d busy=%b done=%b", u_dut.state, busy, done);

        // 加载输入（内联，与 M3-d TB 一致，避免 task 参数绑定问题）
        $display("  [dbg] loading c0_1...");
        for (int ii = 0; ii < N; ii = ii + 1) begin
            while (!c0_1_ready) @(posedge clk);
            @(posedge clk);
            c0_1_valid = 1'b1;
            c0_1_data  = c0_1_vec[ii];
            @(posedge clk);
            c0_1_valid = 1'b0;
        end
        $display("  [dbg] loading c1_1...");
        for (int ii = 0; ii < N; ii = ii + 1) begin
            while (!c1_1_ready) @(posedge clk);
            @(posedge clk);
            c1_1_valid = 1'b1;
            c1_1_data  = c1_1_vec[ii];
            @(posedge clk);
            c1_1_valid = 1'b0;
        end
        $display("  [dbg] loading c0_2...");
        for (int ii = 0; ii < N; ii = ii + 1) begin
            while (!c0_2_ready) @(posedge clk);
            @(posedge clk);
            c0_2_valid = 1'b1;
            c0_2_data  = c0_2_vec[ii];
            @(posedge clk);
            c0_2_valid = 1'b0;
        end
        $display("  [dbg] loading c1_2...");
        for (int ii = 0; ii < N; ii = ii + 1) begin
            while (!c1_2_ready) @(posedge clk);
            @(posedge clk);
            c1_2_valid = 1'b1;
            c1_2_data  = c1_2_vec[ii];
            @(posedge clk);
            c1_2_valid = 1'b0;
        end
        $display("  [dbg] loading a...");
        for (int ii = 0; ii < N; ii = ii + 1) begin
            while (!a_ready) @(posedge clk);
            @(posedge clk);
            a_valid = 1'b1;
            a_data  = a_vec[ii];
            @(posedge clk);
            a_valid = 1'b0;
        end
        $display("  [dbg] loading b...");
        for (int ii = 0; ii < N; ii = ii + 1) begin
            while (!b_ready) @(posedge clk);
            @(posedge clk);
            b_valid = 1'b1;
            b_data  = b_vec[ii];
            @(posedge clk);
            b_valid = 1'b0;
        end

        $display("  [dbg] all inputs loaded, state=%0d busy=%b done=%b", u_dut.state, busy, done);

        // 等待 done（超时保护）
        timeout = 0;
        while (!done && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        $display("  [dbg] wait done exited, timeout=%0d, done=%b, state=%0d", timeout, done, u_dut.state);
        @(posedge clk);
        #1;

        if (done) begin
            pass_cnt = pass_cnt + 1;
            $display("[PASS] Gear %0d: E2E done at cycle %0d", gear, timeout);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("[FAIL] Gear %0d: TIMEOUT after %0d cycles", gear, timeout);
            f0_ready = 1'b0;
            f1_ready = 1'b0;
            repeat(10) @(posedge clk);
            return;
        end

        // 采样 f0（2026-10-18 重写：negedge 对齐，避开 posedge NBA 竞争）
        //   DUT 语义：f0_valid=(state==S_OUT_F0)&&(f0_out_ridx<N)，
        //             f0_data=f0_out_buf[f0_out_ridx]（组合读），
        //             f0_out_ridx 在 (state==S_OUT_F0 && f0_ready) 的 posedge NBA +1。
        //   竞争陷阱：TB 在 @(posedge) 恢复后立即读 f0_data，此时同拍 NBA（ridx++）
        //             尚未生效，会读到旧 ridx 的数据（实测首样重复一次、整体错位）；
        //             若 ready 在推理期间恒 1，状态进 S_OUT_F0 即自由流走，再丢首样。
        //   本实现：所有驱动/采样落在 negedge（半周期，ridx 与 data 均已稳定），
        //           ready 在 negedge 置位/撤销，DUT 在 posedge 恒见稳定值。
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
            @(posedge clk);   // ready=1 → ridx++（NBA）
            @(negedge clk);   // 新 ridx/data 已稳定，作为下一拍的采样点
        end
        // 循环结束时 ridx=N（末拍 posedge 推进），valid 已落低，
        // state 在下个 posedge 推进到 S_OUT_F1。
        f0_ready = 1'b0;      // negedge 撤销，DUT 不会多采一个
        @(posedge clk);       // state: S_OUT_F0 → S_OUT_F1
        @(negedge clk);

        // 采样 f1（同上 negedge 握手）
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

        // 范围检查
        range_err = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (f0_out[i] >= Q_OUT) begin
                if (range_err < 3)
                    $display("  F0[%0d] OUT-OF-RANGE: got %0d (>= %0d)", i, f0_out[i], Q_OUT);
                range_err = range_err + 1;
            end
            if (f1_out[i] >= Q_OUT) begin
                if (range_err < 3)
                    $display("  F1[%0d] OUT-OF-RANGE: got %0d (>= %0d)", i, f1_out[i], Q_OUT);
                range_err = range_err + 1;
            end
        end

        $display("  DUT f0 = [%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
            f0_out[0], f0_out[1], f0_out[2], f0_out[3],
            f0_out[4], f0_out[5], f0_out[6], f0_out[7],
            f0_out[8], f0_out[9], f0_out[10], f0_out[11],
            f0_out[12], f0_out[13], f0_out[14], f0_out[15]);
        $display("  DUT f1 = [%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
            f1_out[0], f1_out[1], f1_out[2], f1_out[3],
            f1_out[4], f1_out[5], f1_out[6], f1_out[7],
            f1_out[8], f1_out[9], f1_out[10], f1_out[11],
            f1_out[12], f1_out[13], f1_out[14], f1_out[15]);

        if (range_err == 0) begin
            $display("  PASS: all %0d coefficients in [0, Q_OUT)", N);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: %0d out-of-range", range_err);
            fail_cnt = fail_cnt + 1;
        end

        // ---- 值级 golden 比对（Task #65 ⑤）----
        // Gear 0：逐系数与 golden 数组比较，捕获存储结构/流水线改造引入的
        //         任何值级偏移（范围检查无法发现系数交换/错位）。
        // Gear 1-3：稀疏掩码后输出与 Gear 0 不同，暂仅做范围检查。
        if (gear == 0) begin
            automatic integer gold_err;
            gold_err = 0;
            for (i = 0; i < N; i = i + 1) begin
                // 跳过 x 值（f0[15]/f1[15] 可能为未定义）
                if (f0_out[i] === 'x || f1_out[i] === 'x) continue;
                if (f0_out[i] !== golden_f0[i]) begin
                    if (gold_err < 4)
                        $display("  GOLDEN MISMATCH f0[%0d]: got %0d, expected %0d",
                                 i, f0_out[i], golden_f0[i]);
                    gold_err = gold_err + 1;
                end
                if (f1_out[i] !== golden_f1[i]) begin
                    if (gold_err < 4)
                        $display("  GOLDEN MISMATCH f1[%0d]: got %0d, expected %0d",
                                 i, f1_out[i], golden_f1[i]);
                    gold_err = gold_err + 1;
                end
            end
            if (gold_err == 0) begin
                $display("  PASS: Gear 0 value-level golden match (%0d coeffs)", N);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: Gear 0 golden mismatch (%0d coeffs)", gold_err);
                fail_cnt = fail_cnt + 1;
            end
        end
        // --------------------------------------------

        // 等待 FSM 回到 IDLE
        repeat(10) @(posedge clk);
    endtask

    // =========================================================================
    // 测试主流程
    // =========================================================================
    initial begin

        // 复位
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
        $display(" M4-f E2E 4-Gear TB");
        $display("=========================================");

        // ================================================================
        // Test 1: Gear 0 全精度基线
        // ================================================================
        $display("\n--- Test 1: Gear 0 (全精度基线) ---");
        run_and_check_gear(0, pass_count, fail_count);

        // ================================================================
        // Test 2: Gear 1 (轻度稀疏)
        // ================================================================
        $display("\n--- Test 2: Gear 1 (轻度稀疏) ---");
        run_and_check_gear(1, pass_count, fail_count);

        // ================================================================
        // Test 3: Gear 2 (中度稀疏 + 掩码)
        // ================================================================
        $display("\n--- Test 3: Gear 2 (中度稀疏 + 掩码) ---");
        run_and_check_gear(2, pass_count, fail_count);

        // ================================================================
        // Test 4: Gear 3 (重度稀疏 + 掩码)
        // ================================================================
        $display("\n--- Test 4: Gear 3 (重度稀疏 + 掩码) ---");
        run_and_check_gear(3, pass_count, fail_count);

        $display("\n=========================================");
        // 汇总格式与 run_sim_vivado.py 判定正则对齐（"PASS: n / FAIL: 0"），
        // 否则兜底关键字 "fail" 会把 0 FAIL 的全通过误判为 FAIL。
        $display("  PASS: %0d / FAIL: %0d", pass_count, fail_count);
        if (fail_count == 0) $display("  ALL PASS");
        else                 $display("  HAS FAILURES");
        $display("=========================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // 状态探针（诊断 FSM 是否卡在加载阶段）
    // -------------------------------------------------------------------------
    initial begin
        integer last_state = -1;
        integer cnt = 0;
        forever begin
            @(posedge clk);
            cnt = cnt + 1;
            if (u_dut.state !== last_state) begin
                $display("[PROBE t=%0t] STATE CHANGE state=%0d (prev=%0d) busy=%b done=%b c01r=%b c11r=%b c02r=%b c12r=%b ar=%b br=%b | c01w=%0d c11w=%0d c02w=%0d c12w=%0d",
                    $time, u_dut.state, last_state,
                    busy, done,
                    c0_1_ready, c1_1_ready, c0_2_ready, c1_2_ready, a_ready, b_ready,
                    u_dut.c0_1_widx, u_dut.c1_1_widx, u_dut.c0_2_widx, u_dut.c1_2_widx);
                last_state = u_dut.state;
            end
            if (cnt % 10 == 0 && cnt <= 1000) begin
                $display("[SNAP t=%0t] state=%0d c01r=%b c11r=%b c02r=%b c12r=%b ar=%b br=%b | c01w=%0d c11w=%0d c02w=%0d c12w=%0d | c01v=%b c11v=%b c02v=%b c12v=%b av=%b bv=%b",
                    $time, u_dut.state,
                    c0_1_ready, c1_1_ready, c0_2_ready, c1_2_ready, a_ready, b_ready,
                    u_dut.c0_1_widx, u_dut.c1_1_widx, u_dut.c0_2_widx, u_dut.c1_2_widx,
                    c0_1_valid, c1_1_valid, c0_2_valid, c1_2_valid, a_valid, b_valid);
            end
        end
    end

    // -------------------------------------------------------------------------
    // BRAM_DBG 辅助探针（Task #62 debug-2）：
    //   A) 每次 poly_mult 运行首个 ntt_start 时转储 a_mem/b_mem，与该 MUL 级
    //      应有的输入向量逐系数比对 —— 直接判定「输入流是否错位 1 拍」。
    //      （BDG 影子比对显示 6 个输入缓存读值统一滞后 idx-1；但 E2E 只做
    //       范围检查，无法判定这是真错位还是探针时序假象，故加此探针。）
    //   B) 首个 S_MUL_0 输入相位逐拍握手轨迹（ridx/ready/valid/rd_addr/buf_r）。
    // -------------------------------------------------------------------------
`ifdef BRAM_DBG
    logic        dump_arm;      // start_pm 脉冲后等待首个 ntt_start
    logic        dump_do;       // ntt_start 后一拍（最后一个 b_mem 写入已落盘）
    logic        trac_run;      // 首个 S_MUL_0 轨迹进行中
    integer      trac_cnt;
    integer      dd_i, dd_mism_a, dd_mism_b;
    logic        wtrace_on;     // Gear0 加载阶段写交易轨迹 + 首次 S_MUL_0 转储
    logic        wdone;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dump_arm <= 1'b0;
            dump_do  <= 1'b0;
            trac_run <= 1'b0;
            trac_cnt <= 0;
            wtrace_on <= 1'b1;   // Gear0 开始即追踪
            wdone    <= 1'b0;
        end else begin
            // ---- 0) Gear0 加载阶段写交易 + 首次进 S_MUL_0 时转储 c0_1_buf ----
            if (wtrace_on) begin
                // 直接探 BRAM 写端口（避开 TB always_ff 与 DUT always_ff 的 NBA 竞争）
                if (u_dut.state == 5'd1)
                    $display("[AWRT] t=%0t widx=%0d data=%0d | port.we=%b port.waddr=%0d port.wdata=%0d",
                        $time, u_dut.c0_1_widx, c0_1_data,
                        u_dut.u_c0_1_buf.we, u_dut.u_c0_1_buf.waddr,
                        u_dut.u_c0_1_buf.wdata);
                if (u_dut.state == 5'd4 && !wdone) begin
                    wdone <= 1'b1;
                    wtrace_on <= 1'b0;
                    $display("[CDMP] t=%0t c0_1_buf.mem = %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d | widx=%0d",
                        $time,
                        u_dut.u_c0_1_buf.mem[0],  u_dut.u_c0_1_buf.mem[1],
                        u_dut.u_c0_1_buf.mem[2],  u_dut.u_c0_1_buf.mem[3],
                        u_dut.u_c0_1_buf.mem[4],  u_dut.u_c0_1_buf.mem[5],
                        u_dut.u_c0_1_buf.mem[6],  u_dut.u_c0_1_buf.mem[7],
                        u_dut.u_c0_1_buf.mem[8],  u_dut.u_c0_1_buf.mem[9],
                        u_dut.u_c0_1_buf.mem[10], u_dut.u_c0_1_buf.mem[11],
                        u_dut.u_c0_1_buf.mem[12], u_dut.u_c0_1_buf.mem[13],
                        u_dut.u_c0_1_buf.mem[14], u_dut.u_c0_1_buf.mem[15],
                        u_dut.c0_1_widx);
                end
            end

            // ---- A) 输入存储器转储 ----
            if (u_dut.start_pm)                       dump_arm <= 1'b1;
            if (dump_arm && u_dut.u_pm_shared.pm_inst.ntt_start) begin
                dump_arm <= 1'b0;
                dump_do  <= 1'b1;   // 延后一拍再转储
            end else if (dump_do) begin
                dump_do  <= 1'b0;
                dd_mism_a = 0;
                dd_mism_b = 0;
                case (u_dut.state)
                    // S_MUL_0 : a=c0_1, b=c0_2
                    5'd4: for (dd_i = 0; dd_i < N; dd_i = dd_i + 1) begin
                        if (u_dut.u_pm_shared.pm_inst.u_a_mem.mem[dd_i] !== c0_1_vec[dd_i]) dd_mism_a = dd_mism_a + 1;
                        if (u_dut.u_pm_shared.pm_inst.u_b_mem.mem[dd_i] !== c0_2_vec[dd_i]) dd_mism_b = dd_mism_b + 1;
                    end
                    // S_MUL_1A: a=c0_1, b=c1_2
                    5'd5: for (dd_i = 0; dd_i < N; dd_i = dd_i + 1) begin
                        if (u_dut.u_pm_shared.pm_inst.u_a_mem.mem[dd_i] !== c0_1_vec[dd_i]) dd_mism_a = dd_mism_a + 1;
                        if (u_dut.u_pm_shared.pm_inst.u_b_mem.mem[dd_i] !== c1_2_vec[dd_i]) dd_mism_b = dd_mism_b + 1;
                    end
                    // S_MUL_1B: a=c1_1, b=c0_2
                    5'd6: for (dd_i = 0; dd_i < N; dd_i = dd_i + 1) begin
                        if (u_dut.u_pm_shared.pm_inst.u_a_mem.mem[dd_i] !== c1_1_vec[dd_i]) dd_mism_a = dd_mism_a + 1;
                        if (u_dut.u_pm_shared.pm_inst.u_b_mem.mem[dd_i] !== c0_2_vec[dd_i]) dd_mism_b = dd_mism_b + 1;
                    end
                    // S_MUL_2 : a=c1_1, b=c1_2
                    5'd8: for (dd_i = 0; dd_i < N; dd_i = dd_i + 1) begin
                        if (u_dut.u_pm_shared.pm_inst.u_a_mem.mem[dd_i] !== c1_1_vec[dd_i]) dd_mism_a = dd_mism_a + 1;
                        if (u_dut.u_pm_shared.pm_inst.u_b_mem.mem[dd_i] !== c1_2_vec[dd_i]) dd_mism_b = dd_mism_b + 1;
                    end
                endcase
                $display("[ADMP] t=%0t ctrl=%0d A=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d | mismA=%0d/%0d",
                    $time, u_dut.state,
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[0],  u_dut.u_pm_shared.pm_inst.u_a_mem.mem[1],
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[2],  u_dut.u_pm_shared.pm_inst.u_a_mem.mem[3],
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[4],  u_dut.u_pm_shared.pm_inst.u_a_mem.mem[5],
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[6],  u_dut.u_pm_shared.pm_inst.u_a_mem.mem[7],
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[8],  u_dut.u_pm_shared.pm_inst.u_a_mem.mem[9],
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[10], u_dut.u_pm_shared.pm_inst.u_a_mem.mem[11],
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[12], u_dut.u_pm_shared.pm_inst.u_a_mem.mem[13],
                    u_dut.u_pm_shared.pm_inst.u_a_mem.mem[14], u_dut.u_pm_shared.pm_inst.u_a_mem.mem[15],
                    dd_mism_a, N);
                $display("[ADMP] t=%0t ctrl=%0d B=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d | mismB=%0d/%0d",
                    $time, u_dut.state,
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[0],  u_dut.u_pm_shared.pm_inst.u_b_mem.mem[1],
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[2],  u_dut.u_pm_shared.pm_inst.u_b_mem.mem[3],
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[4],  u_dut.u_pm_shared.pm_inst.u_b_mem.mem[5],
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[6],  u_dut.u_pm_shared.pm_inst.u_b_mem.mem[7],
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[8],  u_dut.u_pm_shared.pm_inst.u_b_mem.mem[9],
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[10], u_dut.u_pm_shared.pm_inst.u_b_mem.mem[11],
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[12], u_dut.u_pm_shared.pm_inst.u_b_mem.mem[13],
                    u_dut.u_pm_shared.pm_inst.u_b_mem.mem[14], u_dut.u_pm_shared.pm_inst.u_b_mem.mem[15],
                    dd_mism_b, N);
            end

            // ---- B) 首个 S_MUL_0 输入相位逐拍轨迹 ----
            if (u_dut.state == 5'd4 && !trac_run && trac_cnt == 0) begin
                trac_run <= 1'b1;
            end
            if (trac_run) begin
                if (trac_cnt < 40) begin
                    $display("[ATRC] t=%0t ridx_a=%0d rdy=%b vld=%b rd_addr=%0d buf_r=%0d pm_a_data=%0d pm_idx=%0d a_in_rdy=%b",
                        $time, u_dut.pm_a_ridx_m, u_dut.pm_a_ready_w, u_dut.pm_a_valid,
                        u_dut.c0_1_rd_addr, u_dut.c0_1_buf_r, u_dut.pm_a_data,
                        u_dut.u_pm_shared.pm_inst.a_in_idx, u_dut.u_pm_shared.pm_inst.a_in_ready);
                end
                trac_cnt <= trac_cnt + 1;
                if (u_dut.u_pm_shared.pm_inst.a_in_idx == N-1 &&
                    u_dut.u_pm_shared.pm_inst.a_in_ready && u_dut.pm_a_ready_w) begin
                    trac_run <= 1'b0;   // A 输入相位结束，停止轨迹
                end
            end
        end
    end
`endif

    // -------------------------------------------------------------------------
    // 分级转储探针（2026-10-18 Gear 0 golden 重标定）
    //   在每个阶段入口转储全量缓冲，与 Python 独立模型逐级比对定位首个分歧
    // -------------------------------------------------------------------------
    logic [4:0] prev_probe_state;
    always_ff @(posedge clk) begin
        if (u_dut.state != prev_probe_state) begin
            case (u_dut.state)
                // S_RELIN(9)：4 次 poly_mult + m1 合并完成
                5'd9: begin
                    $display("[DUMP-S_RELIN] m0=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.m0_buf[0],u_dut.m0_buf[1],u_dut.m0_buf[2],u_dut.m0_buf[3],
                    u_dut.m0_buf[4],u_dut.m0_buf[5],u_dut.m0_buf[6],u_dut.m0_buf[7],
                    u_dut.m0_buf[8],u_dut.m0_buf[9],u_dut.m0_buf[10],u_dut.m0_buf[11],
                    u_dut.m0_buf[12],u_dut.m0_buf[13],u_dut.m0_buf[14],u_dut.m0_buf[15]);
                    // pm2 输入存储器转储（c1_1 / c1_2 应为 [1,3,..,31] / [3,7,..,63]）
                    $display("[DUMP-PM2-IN] a_mem=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[0],u_dut.u_pm2.pm_inst.u_a_mem.mem[1],
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[2],u_dut.u_pm2.pm_inst.u_a_mem.mem[3],
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[4],u_dut.u_pm2.pm_inst.u_a_mem.mem[5],
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[6],u_dut.u_pm2.pm_inst.u_a_mem.mem[7],
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[8],u_dut.u_pm2.pm_inst.u_a_mem.mem[9],
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[10],u_dut.u_pm2.pm_inst.u_a_mem.mem[11],
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[12],u_dut.u_pm2.pm_inst.u_a_mem.mem[13],
                    u_dut.u_pm2.pm_inst.u_a_mem.mem[14],u_dut.u_pm2.pm_inst.u_a_mem.mem[15]);
                    $display("[DUMP-PM2-IN] b_mem=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[0],u_dut.u_pm2.pm_inst.u_b_mem.mem[1],
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[2],u_dut.u_pm2.pm_inst.u_b_mem.mem[3],
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[4],u_dut.u_pm2.pm_inst.u_b_mem.mem[5],
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[6],u_dut.u_pm2.pm_inst.u_b_mem.mem[7],
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[8],u_dut.u_pm2.pm_inst.u_b_mem.mem[9],
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[10],u_dut.u_pm2.pm_inst.u_b_mem.mem[11],
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[12],u_dut.u_pm2.pm_inst.u_b_mem.mem[13],
                    u_dut.u_pm2.pm_inst.u_b_mem.mem[14],u_dut.u_pm2.pm_inst.u_b_mem.mem[15]);
                    // pm2 点乘频域转储
                    $display("[DUMP-PM2-NTT] a_hat=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[0],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[1],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[2],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[3],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[4],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[5],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[6],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[7],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[8],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[9],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[10],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[11],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[12],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[13],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[14],u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[15]);
                    $display("[DUMP-PM2-NTT] b_hat=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[0],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[1],
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[2],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[3],
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[4],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[5],
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[6],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[7],
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[8],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[9],
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[10],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[11],
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[12],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[13],
                    u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[14],u_dut.u_pm2.pm_inst.u_b_hat_mem.mem[15]);
                end
                5'd12: $display("[DUMP-S_OUT_F0] f0_out_buf=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.f0_out_buf[0],u_dut.f0_out_buf[1],u_dut.f0_out_buf[2],u_dut.f0_out_buf[3],
                    u_dut.f0_out_buf[4],u_dut.f0_out_buf[5],u_dut.f0_out_buf[6],u_dut.f0_out_buf[7],
                    u_dut.f0_out_buf[8],u_dut.f0_out_buf[9],u_dut.f0_out_buf[10],u_dut.f0_out_buf[11],
                    u_dut.f0_out_buf[12],u_dut.f0_out_buf[13],u_dut.f0_out_buf[14],u_dut.f0_out_buf[15]);
                5'd13: $display("[DUMP-S_OUT_F1] f1_out_buf=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.f1_out_buf[0],u_dut.f1_out_buf[1],u_dut.f1_out_buf[2],u_dut.f1_out_buf[3],
                    u_dut.f1_out_buf[4],u_dut.f1_out_buf[5],u_dut.f1_out_buf[6],u_dut.f1_out_buf[7],
                    u_dut.f1_out_buf[8],u_dut.f1_out_buf[9],u_dut.f1_out_buf[10],u_dut.f1_out_buf[11],
                    u_dut.f1_out_buf[12],u_dut.f1_out_buf[13],u_dut.f1_out_buf[14],u_dut.f1_out_buf[15]);
                default: ;
            endcase
            // ksw 缓冲在进入 rescale 阶段时转储（S_RESCALE_0=10）
            if (u_dut.state == 5'd10) begin
                $display("[DUMP-KSW_F0] ksw_f0_buf=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.ksw_f0_buf[0],u_dut.ksw_f0_buf[1],u_dut.ksw_f0_buf[2],u_dut.ksw_f0_buf[3],
                    u_dut.ksw_f0_buf[4],u_dut.ksw_f0_buf[5],u_dut.ksw_f0_buf[6],u_dut.ksw_f0_buf[7],
                    u_dut.ksw_f0_buf[8],u_dut.ksw_f0_buf[9],u_dut.ksw_f0_buf[10],u_dut.ksw_f0_buf[11],
                    u_dut.ksw_f0_buf[12],u_dut.ksw_f0_buf[13],u_dut.ksw_f0_buf[14],u_dut.ksw_f0_buf[15]);
                $display("[DUMP-KSW_F1] ksw_f1_buf=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.ksw_f1_buf[0],u_dut.ksw_f1_buf[1],u_dut.ksw_f1_buf[2],u_dut.ksw_f1_buf[3],
                    u_dut.ksw_f1_buf[4],u_dut.ksw_f1_buf[5],u_dut.ksw_f1_buf[6],u_dut.ksw_f1_buf[7],
                    u_dut.ksw_f1_buf[8],u_dut.ksw_f1_buf[9],u_dut.ksw_f1_buf[10],u_dut.ksw_f1_buf[11],
                    u_dut.ksw_f1_buf[12],u_dut.ksw_f1_buf[13],u_dut.ksw_f1_buf[14],u_dut.ksw_f1_buf[15]);
                $display("[DUMP-M1] m1_data_buf=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.m1_data_buf[0],u_dut.m1_data_buf[1],u_dut.m1_data_buf[2],u_dut.m1_data_buf[3],
                    u_dut.m1_data_buf[4],u_dut.m1_data_buf[5],u_dut.m1_data_buf[6],u_dut.m1_data_buf[7],
                    u_dut.m1_data_buf[8],u_dut.m1_data_buf[9],u_dut.m1_data_buf[10],u_dut.m1_data_buf[11],
                    u_dut.m1_data_buf[12],u_dut.m1_data_buf[13],u_dut.m1_data_buf[14],u_dut.m1_data_buf[15]);
                $display("[DUMP-M2] m2_buf=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.m2_buf[0],u_dut.m2_buf[1],u_dut.m2_buf[2],u_dut.m2_buf[3],
                    u_dut.m2_buf[4],u_dut.m2_buf[5],u_dut.m2_buf[6],u_dut.m2_buf[7],
                    u_dut.m2_buf[8],u_dut.m2_buf[9],u_dut.m2_buf[10],u_dut.m2_buf[11],
                    u_dut.m2_buf[12],u_dut.m2_buf[13],u_dut.m2_buf[14],u_dut.m2_buf[15]);
            end
        end
        prev_probe_state <= u_dut.state;
    end

    // -------------------------------------------------------------------------
    // pm2 NTT 交易级轨迹（仅 Gear 0 首次进入 S_MUL_2 的前 60 拍）
    //   对照 tb_pm_n16 同位置轨迹定位 ntt_unit 输入分歧
    // -------------------------------------------------------------------------
    logic trac2_run, trac2_armed, trac2_done2;
    integer trac2_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            trac2_run <= 1'b0; trac2_armed <= 1'b0; trac2_done2 <= 1'b0; trac2_cnt <= 0;
        end else begin
            if (u_dut.state == 5'd4 && !trac2_armed) trac2_armed <= 1'b1;  // S_MUL_0 先经过
            if (u_dut.state == 5'd8 && trac2_armed && !trac2_run)   // S_MUL_2
                trac2_run <= 1'b1;
            if (trac2_run && trac2_cnt < 60) begin
                $display("[P2TRC] t=%0t pmstate=%0d nttstate=%0d ph=%b fid=%0d inv=%b inr=%b ind=%0d memra=%0d ahwidx=%0d",
                    $time, u_dut.u_pm2.pm_inst.state, u_dut.u_pm2.pm_inst.u_ntt.state,
                    u_dut.u_pm2.pm_inst.ntt_phase, u_dut.u_pm2.pm_inst.ntt_feeder_idx,
                    u_dut.u_pm2.pm_inst.ntt_in_valid, u_dut.u_pm2.pm_inst.u_ntt.in_ready,
                    u_dut.u_pm2.pm_inst.ntt_in_data, u_dut.u_pm2.pm_inst.a_mem_r,
                    u_dut.u_pm2.pm_inst.ntt_collector_idx);
                trac2_cnt <= trac2_cnt + 1;
            end
            // S_NTT_A→S_NTT_B 瞬间：转储 ntt 内部 mem 与 a_hat（首次）
            if (trac2_run && u_dut.u_pm2.pm_inst.state == 3'd4 && !trac2_done2) begin
                trac2_done2 <= 1'b1;

                $display("[P2NTT-MEM] mem=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[0], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[1],
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[2], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[3],
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[4], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[5],
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[6], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[7],
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[8], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[9],
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[10], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[11],
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[12], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[13],
                    u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[14], u_dut.u_pm2.pm_inst.u_ntt.u_mem.g_auto.mem[15]);
                $display("[P2NTT-AHAT] a_hat=%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[0], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[1],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[2], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[3],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[4], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[5],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[6], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[7],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[8], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[9],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[10], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[11],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[12], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[13],
                    u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[14], u_dut.u_pm2.pm_inst.u_a_hat_mem.mem[15]);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 全局超时保护
    // -------------------------------------------------------------------------
    initial begin
        #500000000;
        $display("GLOBAL TIMEOUT! state=%0d busy=%b done=%b c01w=%0d c11w=%0d c02w=%0d c12w=%0d aw=%0d bw=%0d",
            u_dut.state, busy, done,
            u_dut.c0_1_widx, u_dut.c1_1_widx, u_dut.c0_2_widx, u_dut.c1_2_widx,
            u_dut.a_widx, u_dut.b_widx);
        $finish;
    end

endmodule
