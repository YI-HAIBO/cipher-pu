// =============================================================================
// tb_e53_cpa.sv — E53 相关功耗分析（CPA）密钥恢复（RTL 行为级功率模型）v2
//
// v2 修正（2026-11-07）：攻击目标从卷积输出 e2a_buf/e2b_buf 改为
//   **NTT 域点乘中间值** z[k] = NTT(e2)[k] * NTT(a)[k] mod q。
//   理由：e2a_buf 是 poly_mult 的卷积输出（循环卷积），其系数
//   (e2*a)[i] = sum_j e2[j]*a[(i-j) mod N] 依赖全部 a[j]，无法逐系数隔离；
//   而 NTT 域点乘 z[k] 只依赖单个标量密钥系数 NTT(a)[k]（NTT 为环同构），
//   是标准逐系数 CPA 的正确目标。
//
// 装置（玩具 N=16, Q=113, Q_WIDTH=7, USE_FASTRED=0）：
//   u_ks  : keyswitch_pipe          （未掩码基线）
//   u_ksm : keyswitch_pipe_masked   （一阶加性掩码，顺序双通）
//
// 采样对象（poly_mult 内部，S_MUL 阶段）：
//   mul_rd_addr : 点乘索引 k（0..N-1）
//   a_hat_r     : NTT(e2)[k]（BRAM 同步读，公开数据）
//   b_hat_r     : NTT(a)[k] 或 NTT(b)[k]（BRAM 同步读，秘密）
//   prod_r      : 完整乘积 a_hat_r * b_hat_r（14-bit 寄存器，测量对象）
//   流水线关系：prod_r(C) = a_hat_r(C-1) * b_hat_r(C-1)（逐拍精确），
//   因此 Python 侧用相邻 S_MUL 周期对 (C-1, C) 对齐：
//     index = mul_rd_addr(C-1), A = a_hat_r(C-1), B = b_hat_r(C-1),
//     Z = prod_r(C)，并断言 Z == A*B 作为对齐自检。
//
// 掩码版采样内层 u_ksm.u_ks.u_pm_e2a/u_pm_e2b，pass_sel 区分 pass1(a1/b1)/
// pass2(a2/b2)；份额每 trace 新鲜随机 → 无固定密钥可恢复。
//
// 输出：sim/tb_e53_cpa/trace.txt
//   E53DATA <t> <e2_0..e2_15>
//   E53HDR  <t> <unmasked|masked>
//   E53C    <cycle> [<f2a> <i2a> <a2a> <b2a> <p2a> <f2b> <i2b> <a2b> <b2b> <p2b>]
//           未掩码；掩码版前缀 <pass>
//   E53END  <t>
//   其中 f* = 该 poly_mult 当前是否处于 S_MUL（1/0），i=idx, a/b=乘数, p=乘积。
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e53_cpa;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    localparam LOG_N   = 4;
    localparam N       = 16;
    localparam Q_WIDTH = 7;
    localparam Q_VAL   = 113;
    localparam N_INV   = 106;

    localparam NUM_TRACES = 100;        // CPA trace 数

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
    // 文件输出
    // ==================================================================
    integer fd;

    // ==================================================================
    // 测试数据
    // ==================================================================
    integer ti, ki;
    logic [Q_WIDTH-1:0] e0_v [0:N-1];
    logic [Q_WIDTH-1:0] e1_v [0:N-1];
    logic [Q_WIDTH-1:0] e2_v [0:N-1];
    logic [Q_WIDTH-1:0] a_cur [0:N-1];
    logic [Q_WIDTH-1:0] b_cur [0:N-1];
    logic [Q_WIDTH-1:0] a1_cur [0:N-1];
    logic [Q_WIDTH-1:0] b1_cur [0:N-1];
    logic [Q_WIDTH-1:0] a2_cur [0:N-1];
    logic [Q_WIDTH-1:0] b2_cur [0:N-1];

    integer cycle_cnt;

    // S_MUL = 3'd5（poly_mult 内部 localparam）
    localparam [2:0] S_MUL = 3'd5;

    // ------------------------------------------------------------------
    // 逐拍采样：仅在任一 poly_mult 处于 S_MUL 时输出一行
    //   未掩码：u_ks.u_pm_e2a / u_ks.u_pm_e2b
    // ------------------------------------------------------------------
    task automatic dump_cycle_um(integer c);
        integer f2a, f2b;
        f2a = (u_ks.u_pm_e2a.state == S_MUL) ? 1 : 0;
        f2b = (u_ks.u_pm_e2b.state == S_MUL) ? 1 : 0;
        if (f2a || f2b) begin
            $fwrite(fd, "E53C %0d ", c);
            $fwrite(fd, "%0d %0d %0d %0d %0d ", f2a,
                u_ks.u_pm_e2a.mul_rd_addr, u_ks.u_pm_e2a.a_hat_r,
                u_ks.u_pm_e2a.b_hat_r, u_ks.u_pm_e2a.prod_r);
            $fwrite(fd, "%0d %0d %0d %0d %0d\n", f2b,
                u_ks.u_pm_e2b.mul_rd_addr, u_ks.u_pm_e2b.a_hat_r,
                u_ks.u_pm_e2b.b_hat_r, u_ks.u_pm_e2b.prod_r);
        end
    endtask

    // 掩码版：内层 u_ksm.u_ks，前缀 pass_sel
    task automatic dump_cycle_m(integer c);
        integer f2a, f2b;
        f2a = (u_ksm.u_ks.u_pm_e2a.state == S_MUL) ? 1 : 0;
        f2b = (u_ksm.u_ks.u_pm_e2b.state == S_MUL) ? 1 : 0;
        if (f2a || f2b) begin
            $fwrite(fd, "E53C %0d ", c);
            $fwrite(fd, "%0d ", u_ksm.pass_sel);
            $fwrite(fd, "%0d %0d %0d %0d %0d ", f2a,
                u_ksm.u_ks.u_pm_e2a.mul_rd_addr, u_ksm.u_ks.u_pm_e2a.a_hat_r,
                u_ksm.u_ks.u_pm_e2a.b_hat_r, u_ksm.u_ks.u_pm_e2a.prod_r);
            $fwrite(fd, "%0d %0d %0d %0d %0d\n", f2b,
                u_ksm.u_ks.u_pm_e2b.mul_rd_addr, u_ksm.u_ks.u_pm_e2b.a_hat_r,
                u_ksm.u_ks.u_pm_e2b.b_hat_r, u_ksm.u_ks.u_pm_e2b.prod_r);
        end
    endtask

    // ------------------------------------------------------------------
    // 运行未掩码 keyswitch（逐拍采样）
    // ------------------------------------------------------------------
    task automatic run_unmasked();
        while (k_busy) @(negedge clk);
        @(negedge clk);
        k_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        k_start = 1'b0;

        while (!k_e0_r) @(negedge clk);
        for (ki = 0; ki < N; ki = ki + 1) begin
            k_e0_v = 1'b1; k_e1_v = 1'b1; k_e2_v = 1'b1;
            k_a_v  = 1'b1; k_b_v  = 1'b1;
            k_e0_d = e0_v[ki]; k_e1_d = e1_v[ki]; k_e2_d = e2_v[ki];
            k_a_d  = a_cur[ki];  k_b_d  = b_cur[ki];
            @(posedge clk);
            @(negedge clk);
        end
        k_e0_v = 0; k_e1_v = 0; k_e2_v = 0; k_a_v = 0; k_b_v = 0;

        cycle_cnt = 0;
        while (!k_done && cycle_cnt < 40000) begin
            @(posedge clk);
            dump_cycle_um(cycle_cnt);
            cycle_cnt = cycle_cnt + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // 运行掩码 keyswitch（逐拍采样）
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

        cycle_cnt = 0;
        while (!m_done && cycle_cnt < 80000) begin
            @(posedge clk);
            dump_cycle_m(cycle_cnt);
            cycle_cnt = cycle_cnt + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    initial begin

        rst_n = 0;
        k_start = 0; m_start = 0;
        k_e0_v = 0; k_e1_v = 0; k_e2_v = 0; k_a_v = 0; k_b_v = 0;
        m_e0_v = 0; m_e1_v = 0; m_e2_v = 0;
        m_a1_v = 0; m_b1_v = 0; m_a2_v = 0; m_b2_v = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        fd = $fopen("trace.txt", "w");

        // 已知密钥（固定、逐系数不同、非零）
        for (ki = 0; ki < N; ki = ki + 1) begin
            a_cur[ki] = (ki * 7 + 3) % Q_VAL;
            b_cur[ki] = (ki * 11 + 5) % Q_VAL;
        end

        $display("=========================================");
        $display(" E53 CPA Key Recovery v2 (toy N=16)");
        $display(" target: NTT-domain pointwise product");
        $display("=========================================");

        for (ti = 0; ti < NUM_TRACES; ti = ti + 1) begin
            // 随机数据
            for (ki = 0; ki < N; ki = ki + 1) begin
                e0_v[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                e1_v[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                e2_v[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
            end
            // 份额（每 trace 新鲜随机）
            for (ki = 0; ki < N; ki = ki + 1) begin
                a1_cur[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                b1_cur[ki] = ($random % Q_VAL + Q_VAL) % Q_VAL;
                a2_cur[ki] = (a_cur[ki] + Q_VAL - a1_cur[ki]) % Q_VAL;
                b2_cur[ki] = (b_cur[ki] + Q_VAL - b1_cur[ki]) % Q_VAL;
            end

            // 数据行（e2，用于重建 CPA 预测）
            $fwrite(fd, "E53DATA %0d ", ti);
            for (ki = 0; ki < N; ki = ki + 1) $fwrite(fd, "%0d ", e2_v[ki]);
            $fwrite(fd, "\n");

            // ---- 未掩码 ----
            $fwrite(fd, "E53HDR %0d unmasked\n", ti);
            run_unmasked();
            $fwrite(fd, "E53END %0d\n", ti);

            // ---- 掩码 ----
            $fwrite(fd, "E53HDR %0d masked\n", ti);
            run_masked();
            $fwrite(fd, "E53END %0d\n", ti);
        end

        $fclose(fd);
        $display("E53 ALL TRACES DONE");
        $finish;
    end

    // 全局看门狗
    initial begin
        #(600 * 1000000);
        $display("E53 GLOBAL TIMEOUT");
        $finish;
    end

endmodule
