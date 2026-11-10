// =============================================================================
// tb_e39_tvla.sv — E39 DARE 侧信道评估：RTL 翻转 TVLA（fixed-vs-random key）
//
// 装置（玩具配置 N=16, Q=113, Q_WIDTH=7, USE_FASTRED=0）：
//   u_ks  : keyswitch_pipe          （未掩码基线）
//   u_ksm : keyswitch_pipe_masked   （一阶加性掩码，顺序双通）
//
// TVLA 协议（fixed-vs-random key，classic Test Vector Leakage Assessment）：
//   - 每 trace：e0/e1/e2 恒为随机数据（两组相同分布）
//   - FIXED 组：keyswitch key (a, b) 固定不变（所有 trace 同一值）
//   - RANDOM 组：每 trace 独立随机 (a, b)
//   - 掩码版：a = a1+a2, b = b1+b2，份额每 trace 独立重新随机化
//   - 采样指标：被监测寄存器阵列的逐拍 Hamming 距离（翻转计数，功耗代理）
//     - 正控（应泄露）：a_buf / b_buf（key 输入缓冲，未掩码版）
//     - 计算路径：e2a_buf / e2b_buf（d2×key 乘积寄存器）
//     - 负控（不应泄露）：e0_buf（数据缓冲，两组同为随机）
//
// 输出：每 trace 一行
//   E39 TRACE key=FIXED|RANDOM um_a=<n> um_b=<n> um_e2a=<n> um_e2b=<n> um_e0=<n>
//                                  m_key=<n> m_e2a=<n> m_e0=<n> match=<n>
//   （match：掩码版输出与未掩码版逐系数一致数，32 为满分）
// Python 侧（exp_e39_dare_sca.py）做 Welch t-test（阈值 |t|>4.5）与报告。
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e39_tvla;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    localparam LOG_N   = 4;
    localparam N       = 16;
    localparam Q_WIDTH = 7;
    localparam Q_VAL   = 113;
    localparam N_INV   = 106;

    localparam NUM_TRACES_PER_GROUP = 24;   // 每组 24 trace → 48 trace/实现

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // 未掩码 keyswitch 信号
    // ------------------------------------------------------------------
    logic                  k_start, k_busy, k_done, k_error;
    logic                  k_e0_v, k_e1_v, k_e2_v, k_a_v, k_b_v;
    logic                  k_e0_r, k_e1_r, k_e2_r, k_a_r, k_b_r;
    logic [Q_WIDTH-1:0]    k_e0_d, k_e1_d, k_e2_d, k_a_d, k_b_d;
    logic                  k_f0_v, k_f1_v;
    logic [Q_WIDTH-1:0]    k_f0_d, k_f1_d;

    // ------------------------------------------------------------------
    // 掩码 keyswitch 信号
    // ------------------------------------------------------------------
    logic                  m_start, m_busy, m_done, m_error;
    logic                  m_e0_v, m_e1_v, m_e2_v;
    logic                  m_a1_v, m_b1_v, m_a2_v, m_b2_v;
    logic                  m_e0_r, m_e1_r, m_e2_r;
    logic                  m_a1_r, m_b1_r, m_a2_r, m_b2_r;
    logic [Q_WIDTH-1:0]    m_e0_d, m_e1_d, m_e2_d;
    logic [Q_WIDTH-1:0]    m_a1_d, m_b1_d, m_a2_d, m_b2_d;
    logic                  m_f0_v, m_f1_v;
    logic [Q_WIDTH-1:0]    m_f0_d, m_f1_d;


    // ------------------------------------------------------------------
    // DUT 实例化
    // ------------------------------------------------------------------
    keyswitch_pipe #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(Q_WIDTH),
        .Q_VAL(Q_VAL), .N_INV(N_INV), .USE_FASTRED(0),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}), .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"})
    ) u_ks (
        .clk(clk), .rst_n(rst_n),
        .start(k_start), .busy(k_busy), .done(k_done), .error(k_error),
        .e0_valid(k_e0_v), .e0_ready(k_e0_r), .e0_data(k_e0_d),
        .e1_valid(k_e1_v), .e1_ready(k_e1_r), .e1_data(k_e1_d),
        .e2_valid(k_e2_v), .e2_ready(k_e2_r), .e2_data(k_e2_d),
        .a_valid(k_a_v),   .a_ready(k_a_r),   .a_data(k_a_d),
        .b_valid(k_b_v),   .b_ready(k_b_r),   .b_data(k_b_d),
        .f0_valid(k_f0_v), .f0_ready(1'b1),   .f0_data(k_f0_d),
        .f1_valid(k_f1_v), .f1_ready(1'b1),   .f1_data(k_f1_d)
    );

    keyswitch_pipe_masked #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(Q_WIDTH),
        .Q_VAL(Q_VAL), .N_INV(N_INV), .USE_FASTRED(0),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}), .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"})
    ) u_ksm (
        .clk(clk), .rst_n(rst_n),
        .start(m_start), .busy(m_busy), .done(m_done), .error(m_error),
        .e0_valid(m_e0_v), .e0_ready(m_e0_r), .e0_data(m_e0_d),
        .e1_valid(m_e1_v), .e1_ready(m_e1_r), .e1_data(m_e1_d),
        .e2_valid(m_e2_v), .e2_ready(m_e2_r), .e2_data(m_e2_d),
        .a1_valid(m_a1_v), .a1_ready(m_a1_r), .a1_data(m_a1_d),
        .b1_valid(m_b1_v), .b1_ready(m_b1_r), .b1_data(m_b1_d),
        .a2_valid(m_a2_v), .a2_ready(m_a2_r), .a2_data(m_a2_d),
        .b2_valid(m_b2_v), .b2_ready(m_b2_r), .b2_data(m_b2_d),
        .f0_valid(m_f0_v), .f0_ready(1'b1),   .f0_data(m_f0_d),
        .f1_valid(m_f1_v), .f1_ready(1'b1),   .f1_data(m_f1_d)
    );

    // ==================================================================
    // 翻转监测器（功耗代理）：被监测寄存器阵列的逐拍 Hamming 距离累加
    // ==================================================================
    integer tog_um_a, tog_um_b, tog_um_e2a, tog_um_e2b, tog_um_e0;
    integer tog_m_key, tog_m_e2a, tog_m_e0;

    logic [Q_WIDTH-1:0] prev_um_a  [0:N-1];
    logic [Q_WIDTH-1:0] prev_um_b  [0:N-1];
    logic [Q_WIDTH-1:0] prev_um_e2a [0:N-1];
    logic [Q_WIDTH-1:0] prev_um_e2b [0:N-1];
    logic [Q_WIDTH-1:0] prev_um_e0  [0:N-1];
    logic [Q_WIDTH-1:0] prev_m_key  [0:N-1];
    logic [Q_WIDTH-1:0] prev_m_e2a  [0:N-1];
    logic [Q_WIDTH-1:0] prev_m_e0   [0:N-1];

    integer hi;

    always @(posedge clk) begin
        for (hi = 0; hi < N; hi = hi + 1) begin
            // 未掩码：a_buf / b_buf（正控）、e2a_buf / e2b_buf（计算路径）、e0_buf（负控）
            tog_um_a   = tog_um_a   + $countones(u_ks.a_buf[hi]   ^ prev_um_a[hi]);
            prev_um_a[hi]  <= u_ks.a_buf[hi];
            tog_um_b   = tog_um_b   + $countones(u_ks.b_buf[hi]   ^ prev_um_b[hi]);
            prev_um_b[hi]  <= u_ks.b_buf[hi];
            tog_um_e2a = tog_um_e2a + $countones(u_ks.e2a_buf[hi] ^ prev_um_e2a[hi]);
            prev_um_e2a[hi] <= u_ks.e2a_buf[hi];
            tog_um_e2b = tog_um_e2b + $countones(u_ks.e2b_buf[hi] ^ prev_um_e2b[hi]);
            prev_um_e2b[hi] <= u_ks.e2b_buf[hi];
            tog_um_e0  = tog_um_e0  + $countones(u_ks.e0_buf[hi]  ^ prev_um_e0[hi]);
            prev_um_e0[hi]  <= u_ks.e0_buf[hi];
            // 掩码：内层 a_buf（顺序双通：pass1 存 a1，pass2 存 a2——
            // 寄存器任意时刻只持单一份额）、e2a_buf（计算路径）、e0_buf（负控）
            tog_m_key  = tog_m_key  + $countones(u_ksm.u_ks.a_buf[hi] ^ prev_m_key[hi]);
            prev_m_key[hi]  <= u_ksm.u_ks.a_buf[hi];
            tog_m_e2a  = tog_m_e2a  + $countones(u_ksm.u_ks.e2a_buf[hi] ^ prev_m_e2a[hi]);
            prev_m_e2a[hi]  <= u_ksm.u_ks.e2a_buf[hi];
            tog_m_e0   = tog_m_e0   + $countones(u_ksm.u_ks.e0_buf[hi] ^ prev_m_e0[hi]);
            prev_m_e0[hi]   <= u_ksm.u_ks.e0_buf[hi];
        end
    end

    // Hamming 权重代理（状态/静态功耗代理）：trace 末对被监测寄存器阵列取 HW
    integer hw_um_a, hw_um_b, hw_um_e0;
    integer hw_m_key, hw_m_e0;

    task automatic sample_hw_um();
        hw_um_a = 0; hw_um_b = 0; hw_um_e0 = 0;
        for (hi = 0; hi < N; hi = hi + 1) begin
            hw_um_a  = hw_um_a  + $countones(u_ks.a_buf[hi]);
            hw_um_b  = hw_um_b  + $countones(u_ks.b_buf[hi]);
            hw_um_e0 = hw_um_e0 + $countones(u_ks.e0_buf[hi]);
        end
    endtask

    task automatic sample_hw_m();
        hw_m_key = 0; hw_m_e0 = 0;
        for (hi = 0; hi < N; hi = hi + 1) begin
            hw_m_key = hw_m_key + $countones(u_ksm.u_ks.a_buf[hi]);
            hw_m_e0  = hw_m_e0  + $countones(u_ksm.u_ks.e0_buf[hi]);
        end
    endtask

    task automatic reset_monitors_um();
        tog_um_a = 0; tog_um_b = 0; tog_um_e2a = 0; tog_um_e2b = 0; tog_um_e0 = 0;
        for (hi = 0; hi < N; hi = hi + 1) begin
            prev_um_a[hi] = u_ks.a_buf[hi];
            prev_um_b[hi] = u_ks.b_buf[hi];
            prev_um_e2a[hi] = u_ks.e2a_buf[hi];
            prev_um_e2b[hi] = u_ks.e2b_buf[hi];
            prev_um_e0[hi] = u_ks.e0_buf[hi];
        end
    endtask

    task automatic reset_monitors_m();
        tog_m_key = 0; tog_m_e2a = 0; tog_m_e0 = 0;
        for (hi = 0; hi < N; hi = hi + 1) begin
            prev_m_key[hi] = u_ksm.u_ks.a_buf[hi];
            prev_m_e2a[hi] = u_ksm.u_ks.e2a_buf[hi];
            prev_m_e0[hi] = u_ksm.u_ks.e0_buf[hi];
        end
    endtask

    // ==================================================================
    // 测试数据
    // ==================================================================
    integer ti, ki;
    logic [Q_WIDTH-1:0] e0_v [0:N-1];
    logic [Q_WIDTH-1:0] e1_v [0:N-1];
    logic [Q_WIDTH-1:0] e2_v [0:N-1];
    // 固定 key（FIXED 组所有 trace 相同）
    logic [Q_WIDTH-1:0] a_fix [0:N-1];
    logic [Q_WIDTH-1:0] b_fix [0:N-1];
    // 当前 trace 的 key 与份额
    logic [Q_WIDTH-1:0] a_cur [0:N-1];
    logic [Q_WIDTH-1:0] b_cur [0:N-1];
    logic [Q_WIDTH-1:0] a1_cur [0:N-1];
    logic [Q_WIDTH-1:0] b1_cur [0:N-1];
    logic [Q_WIDTH-1:0] a2_cur [0:N-1];
    logic [Q_WIDTH-1:0] b2_cur [0:N-1];

    // 未掩码输出捕获
    logic [Q_WIDTH-1:0] kf0 [0:N-1];
    logic [Q_WIDTH-1:0] kf1 [0:N-1];
    // 掩码输出捕获
    logic [Q_WIDTH-1:0] mf0 [0:N-1];
    logic [Q_WIDTH-1:0] mf1 [0:N-1];

    integer match_cnt;
    integer done_cnt;
    integer got_done;
    integer trace_id;

    // ------------------------------------------------------------------
    // 运行未掩码 keyswitch：加载 5 路 → 等 done → 采样 f0/f1
    // ------------------------------------------------------------------
    task automatic run_unmasked();
        // 等上一轮彻底结束（DUT 回 IDLE）后再启动
        while (k_busy) @(negedge clk);

        // start 脉冲
        @(negedge clk);
        k_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        k_start = 1'b0;

        // 等待内层进入 LOAD（ready 变高）
        while (!k_e0_r) @(negedge clk);
        // 5 路并行加载，每拍一个系数（negedge 驱动，posedge 采样）
        for (ki = 0; ki < N; ki = ki + 1) begin
            k_e0_v = 1'b1; k_e1_v = 1'b1; k_e2_v = 1'b1;
            k_a_v  = 1'b1; k_b_v  = 1'b1;
            k_e0_d = e0_v[ki]; k_e1_d = e1_v[ki]; k_e2_d = e2_v[ki];
            k_a_d  = a_cur[ki];  k_b_d  = b_cur[ki];
            @(posedge clk);
            @(negedge clk);
        end
        k_e0_v = 0; k_e1_v = 0; k_e2_v = 0; k_a_v = 0; k_b_v = 0;

        // 等待 done：常驻标志 got_done + 独立计数器（done_wt 兼作标志会首轮即退出）
        done_cnt = 0;
        got_done = 0;
        while (!got_done && done_cnt < 200000) begin
            @(posedge clk);
            if (k_done) got_done = 1;
            done_cnt = done_cnt + 1;
        end
        if (!got_done) $display("E39 WARN: unmasked done timeout");

        // 采样 f0（内层输出在 done 之前已流式完成；此处从 buf 直接读，
        // 与逐拍 valid 握手等价——f0_buf 已在 S_OUTPUT_F0 阶段写满）
        for (ki = 0; ki < N; ki = ki + 1) begin
            kf0[ki] = u_ks.f0_buf[ki];
            kf1[ki] = u_ks.f1_buf[ki];
        end
    endtask

    // ------------------------------------------------------------------
    // 运行掩码 keyswitch：加载 7 路 → 等 done → 读输出 buf
    // ------------------------------------------------------------------
    task automatic run_masked();
        while (m_busy) @(negedge clk);
        @(negedge clk);
        m_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        m_start = 1'b0;

        while (!m_e0_r) @(negedge clk);
        for (ki = 0; ki < N; ki = ki + 1) begin
            m_e0_v = 1'b1; m_e1_v = 1'b1; m_e2_v = 1'b1;
            m_a1_v = 1'b1; m_b1_v = 1'b1; m_a2_v = 1'b1; m_b2_v = 1'b1;
            m_e0_d = e0_v[ki]; m_e1_d = e1_v[ki]; m_e2_d = e2_v[ki];
            m_a1_d = a1_cur[ki]; m_b1_d = b1_cur[ki];
            m_a2_d = a2_cur[ki]; m_b2_d = b2_cur[ki];
            @(posedge clk);
            @(negedge clk);
        end
        m_e0_v = 0; m_e1_v = 0; m_e2_v = 0;
        m_a1_v = 0; m_b1_v = 0; m_a2_v = 0; m_b2_v = 0;

        done_cnt = 0;
        got_done = 0;
        while (!got_done && done_cnt < 400000) begin
            @(posedge clk);
            if (m_done) got_done = 1;
            done_cnt = done_cnt + 1;
        end
        if (!got_done) $display("E39 WARN: masked done timeout");

        for (ki = 0; ki < N; ki = ki + 1) begin
            mf0[ki] = u_ksm.f0_comb[ki];
            mf1[ki] = u_ksm.f1_comb[ki];
        end
    endtask

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    integer gi;
    integer is_fixed;   // 必须是 integer：reg 为 1 bit，is_fixed+1 会回绕导致死循环

    initial begin

        rst_n = 0;
        k_start = 0; m_start = 0;
        k_e0_v = 0; k_e1_v = 0; k_e2_v = 0; k_a_v = 0; k_b_v = 0;
        m_e0_v = 0; m_e1_v = 0; m_e2_v = 0;
        m_a1_v = 0; m_b1_v = 0; m_a2_v = 0; m_b2_v = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // FIXED 组 key = 全零常量（标准 fixed-vs-random TVLA：固定值必须是
        // 与随机分布可区分的常量；若用"固定随机向量"，翻转/HW 统计与随机组
        // 同分布，正控将失去区分力）
        for (ki = 0; ki < N; ki = ki + 1) begin
            a_fix[ki] = '0;
            b_fix[ki] = '0;
        end

        $display("=========================================");
        $display(" E39 DARE Side-Channel TVLA (toy N=16)");
        $display("=========================================");

        trace_id = 0;
        // 交替执行 FIXED 与 RANDOM 组（消除时间漂移）
        for (gi = 0; gi < NUM_TRACES_PER_GROUP; gi = gi + 1) begin
            for (is_fixed = 0; is_fixed <= 1; is_fixed = is_fixed + 1) begin
                // 每条 trace 的随机数据（两组同分布）
                for (ki = 0; ki < N; ki = ki + 1) begin
                    e0_v[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                    e1_v[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                    e2_v[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                end

                if (is_fixed) begin
                    for (ki = 0; ki < N; ki = ki + 1) begin
                        a_cur[ki] = a_fix[ki];
                        b_cur[ki] = b_fix[ki];
                    end
                end else begin
                    for (ki = 0; ki < N; ki = ki + 1) begin
                        a_cur[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                        b_cur[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                    end
                end

                // 份额：a1/b1 随机（两组都重新随机化），a2/b2 = key − a1
                for (ki = 0; ki < N; ki = ki + 1) begin
                    a1_cur[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                    b1_cur[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                    a2_cur[ki] = (a_cur[ki] + Q_VAL - a1_cur[ki]) % Q_VAL;
                    b2_cur[ki] = (b_cur[ki] + Q_VAL - b1_cur[ki]) % Q_VAL;
                end

                // ---- 未掩码 ----
                reset_monitors_um();
                run_unmasked();
                sample_hw_um();
                // ---- 掩码 ----
                reset_monitors_m();
                run_masked();
                sample_hw_m();

                match_cnt = 0;
                for (ki = 0; ki < N; ki = ki + 1) begin
                    if (kf0[ki] === mf0[ki]) match_cnt = match_cnt + 1;
                    if (kf1[ki] === mf1[ki]) match_cnt = match_cnt + 1;
                end

                $display("E39 TRACE t=%0d key=%s um_a=%0d um_b=%0d um_e2a=%0d um_e2b=%0d um_e0=%0d m_key=%0d m_e2a=%0d m_e0=%0d hwa=%0d hwb=%0d hwe0=%0d hwmk=%0d hwme0=%0d match=%0d", trace_id, is_fixed ? "FIXED" : "RANDOM", tog_um_a, tog_um_b, tog_um_e2a, tog_um_e2b, tog_um_e0, tog_m_key, tog_m_e2a, tog_m_e0, hw_um_a, hw_um_b, hw_um_e0, hw_m_key, hw_m_e0, match_cnt);
                trace_id = trace_id + 1;
            end
        end

        $display("E39 ALL TRACES DONE");
        $finish;
    end

    // 全局看门狗
    initial begin
        #(200 * 1000000);
        $display("E39 GLOBAL TIMEOUT");
        $finish;
    end

endmodule
