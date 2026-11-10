// =============================================================================
// maxpool_layer_e2e.sv - 2×2 MaxPool 密文推理单元（逐 slot 点算版）
// =============================================================================
// Phase 5 Task 5.2.5
//
// 【2026-10-18 重做】原版在 T4 hang，根因是设计级错误 + 6 处时序/接口缺陷：
//
//   设计级错误（根本原因）：
//   (E1) 用 poly_mult 实现 max(a,b)=(a+b+|a-b|)/2 —— 语义根本错误。
//        密文多项式的系数即 NTT 域 slot 值，max 必须逐 slot 点算；
//        poly_mult 算的是循环卷积 a(x)·b(x) mod (x^N-1)，≠ 逐点乘。
//        用 N 次 poly_mult 逼近 Horner 既不对（卷积≠点乘）又慢 2 个数量级。
//   时序/接口缺陷：
//   (E2) pm_start 被两个 always 块双驱动（L275 + L286-295）→ 竞态。
//   (E3) diff_bram / acc_bram 只读不写：a-b 减法、acc*x+c 累加数据通路未接。
//   (E4) coeff_ready = (state==S_LOAD_COEFFS) && coeff_valid —— 依赖 valid，
//        TB 在 valid=0 后轮询 coeff_ready → 永久死锁。
//   (E5) m_valid = (state==S_OUTPUT) && m_ready —— AXI valid 不得由 consumer 决定。
//   (E6) pool_done 单拍脉冲，TB 的 @(posedge) 轮询与 DUT always_ff 同事件周期
//        存在调度竞争，1 拍 done 会被漏采。
//
// 本版设计（纯逐 slot 点算，不实例化 poly_mult / ntt_unit）：
//
//   对每对 (x, y) 的每个 slot i：
//     diff = (x[i] - y[i]) mod Q                        // 逐点减法
//     acc  = Horner 求 |diff| 的 POLY_ORDER 阶多项式近似  // 12 次 45×45 MAC
//            acc = c[P]; for k=P-1..0: acc = (acc·diff + c[k]) mod Q
//     res  = (x[i] + y[i] + acc) · Q_HALF mod Q         // Q_HALF=(Q+1)/2 是 2 的逆元
//   3 对串联（2×2 MaxPool）：
//     pair0 = (A, B) → m1        pair1 = (C, D) → m2        pair2 = (m1, m2) → out
//
//   Q_HALF 的正确性：2·Q_HALF = Q + 1 ≡ 1 (mod Q)，故 ·Q_HALF 即 ÷2。
//
// 时序（每 slot 18 拍，N=16 → 288 拍/pair，3 pair ≈ 864 拍；N=4096 → 233k 拍）：
//   C_REQ0 (1): BRAM 读 slot_idx 的 x,y（1 拍读延迟）
//   C_REQ1 (1): 装载 diff/acc，启动第 1 次 MAC (mul=c[P], b=diff)
//   C_MAC  (12): 每次 1 拍：acc <= (mac_out + c[step]) mod Q，链式流水
//   C_SUM  (1): sum = (x + y + acc) mod Q
//   C_MUL2 (1): 启动 mul_a=sum, mul_b=Q_HALF
//   C_STORE(1): res <= sum·Q_HALF mod Q，写回当前 pair 的结果 BRAM
//   C_NEXT (1): slot_idx++ / pair_idx++ / 收尾
//
// 面积（生产 N=4096, Q_WIDTH=45）：
//   7 × 4096 × 45-bit BRAM（4 输入 + m1 + m2 + out）= 1.26 MB，落 BRAM36
//   + 33 × 32-bit 系数存储 + 1 个 45×45 乘法器（DSP）+ 1 个 mod45_barrett
//   注：本版不再例化 poly_mult，省掉其内部 5 个 BRAM 与 NTT 通路。
//
// 接口：保持与原版一致（omega_table / omega_inv_table / N_INV / in_sel 保留
//       以兼容上层 wrapper，本实现不使用）。
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module maxpool_layer_e2e #(
    parameter int Q_WIDTH     = 45,
    parameter int N           = 4096,
    parameter int LOG_N       = 12,
    parameter int POLY_ORDER  = 12,          // |x| 多项式阶数
    parameter int COEFF_WIDTH = 32,          // 多项式系数位宽（signed）
    // 修正 (E7)：原版写成 `parameter bit Q_VALUE = 45'd...`（1-bit 截 45-bit 值），
    //   导致透传给 poly_mult 的 Q_VALUE 被截成 1 bit。改为参数化位宽。
    parameter logic [Q_WIDTH-1:0] Q_VALUE = 45'd17592186175489,
    parameter logic [Q_WIDTH-1:0] N_INV   = 45'd17587891208161,
    parameter int USE_FASTRED = 1
) (
    input  wire logic               clk,
    input  wire logic               rst_n,

    // 层控制
    input  wire logic               pool_start,
    output logic               pool_busy,
    output logic               pool_done,
    output logic               pool_error,

    // 输入流（AXI4-Stream，4 个多项式按 state 顺序加载，in_sel 仅做标注）
    input  wire logic [1:0]         in_sel,
    input  wire logic [Q_WIDTH-1:0] s_tdata,
    input  wire logic               s_valid,
    output logic               s_ready,
    input  wire logic               s_last,

    // 输出流（AXI4-Stream，最终 maxpool 结果）
    output logic [Q_WIDTH-1:0] m_tdata,
    output logic               m_valid,
    output logic               m_last,
    input  wire logic               m_ready,

    // 系数配置（|x| 多项式系数，有符号定点）
    input  wire logic [COEFF_WIDTH-1:0] coeff_data,
    input  wire logic               coeff_valid,
    output logic               coeff_ready,
    input  wire logic [4:0]         coeff_addr,

    // Twiddle 因子（保留端口以兼容上层；本实现不使用）
    input  wire logic [Q_WIDTH-1:0] omega_table     [0:N/2-1],
    input  wire logic [Q_WIDTH-1:0] omega_inv_table [0:N/2-1]
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam int IDX_W    = $clog2(N);
    localparam int COEFF_COUNT = POLY_ORDER + 1;

    // 2 的逆元 mod Q：2 · Q_HALF = Q + 1 ≡ 1 (mod Q)
    localparam logic [Q_WIDTH-1:0] Q_HALF =
        (Q_VALUE + {{(Q_WIDTH-1){1'b0}}, 1'b1}) >> 1;

    // Barrett 预计算常数 V = floor(2^90 / Q)，仅对生产模数 Q=2^44+2^17+1 成立
    localparam logic [45:0] V_VALUE = 46'd70368743653372;

    // =========================================================================
    // 顶层状态
    // =========================================================================
    localparam logic [3:0] S_IDLE        = 4'd0;
    localparam logic [3:0] S_LOAD_A      = 4'd1;
    localparam logic [3:0] S_LOAD_B      = 4'd2;
    localparam logic [3:0] S_LOAD_C      = 4'd3;
    localparam logic [3:0] S_LOAD_D      = 4'd4;
    localparam logic [3:0] S_LOAD_COEFFS = 4'd5;
    localparam logic [3:0] S_CALC        = 4'd6;
    localparam logic [3:0] S_OUTPUT      = 4'd7;
    localparam logic [3:0] S_DONE        = 4'd8;

    // slot 内子状态
    localparam logic [3:0] C_REQ0         = 4'd0;
    localparam logic [3:0] C_REQ1         = 4'd1;
    localparam logic [3:0] C_MAC_DSP      = 4'd2;  // DSP 输出寄存
    localparam logic [3:0] C_MAC_BAR1     = 4'd3;  // Barrett Stage1→mu_reg（E12 第 2 级）
    localparam logic [3:0] C_MAC_BAR2     = 4'd4;  // Barrett Stage2→prod_mod_reg（E12 第 3 级）
    localparam logic [3:0] C_MAC_ADD      = 4'd5;  // 累加 + mul_a 反馈（E12 第 4 级）
    localparam logic [3:0] C_SUM          = 4'd6;
    localparam logic [3:0] C_MUL2         = 4'd7;  // 置定 ÷2 乘法输入
    localparam logic [3:0] C_MUL2_DSP     = 4'd8;  // ÷2 DSP 输出寄存
    localparam logic [3:0] C_MUL2_BAR1    = 4'd9;  // ÷2 Barrett Stage1→mu_reg
    localparam logic [3:0] C_MUL2_BAR2    = 4'd10; // ÷2 Barrett Stage2→prod_mod_reg
    localparam logic [3:0] C_STORE        = 4'd11; // ÷2 BRAM 写回
    localparam logic [3:0] C_NEXT         = 4'd12;

    // =========================================================================
    // 寄存器
    // =========================================================================
    logic [3:0]       state;
    logic [3:0]       state_next;
    logic [3:0]       cs;          // slot 子状态机（4-bit，9 状态含流水级）
    logic [IDX_W-1:0] stream_idx;
    logic [4:0]       coeff_cnt;
    logic [IDX_W-1:0] slot_idx;
    logic [1:0]       pair_idx;
    logic [4:0]       mac_step;
    logic [2:0]       done_cnt;
    logic [IDX_W-1:0] output_idx;

    // slot 计算寄存器
    logic [Q_WIDTH-1:0] xa_r;      // 当前 slot 的 x
    logic [Q_WIDTH-1:0] ya_r;      // 当前 slot 的 y
    logic [Q_WIDTH-1:0] diff_r;    // (x - y) mod Q
    logic [Q_WIDTH-1:0] acc_r;     // Horner 累加器
    logic [Q_WIDTH-1:0] sum_r;     // (x + y + acc) mod Q

    // 乘法器控制（1 个 45×45 MAC，Horner 与最终 ÷2 时分复用）
    // 关键：mul_a/mul_b 寄存器化，prod_mod 是纯组合输出。
    //   若把 prod_mod 再寄存成 mac_out 再在下一状态读，会在同一 posedge
    //   读到上一拍的旧值（第一次 C_MAC 读到复位值 0）→ 整个 Horner 链错。
    //   故 MAC 结果必须直接用组合 prod_mod，每拍 mul_a/mul_b 更新一次、
    //   下一拍 prod_mod 即为本拍输入的乘积，无错位。
    logic [Q_WIDTH-1:0] mul_a;
    logic [Q_WIDTH-1:0] mul_b;

    // =========================================================================
    // 数据存储
    // =========================================================================
    // 输入缓冲（4 个多项式）
    // 修正 (E10)：加 RAM_STYLE="block" 强制 BRAM36E 推断。
    //   Vivado 默认对 4K×45 的 "Implied" memory 选 LUT 分布式 RAM（吃 22400 LUT），
    //   而非 BRAM36（仅占 ~1.5 BRAM tile）。加此属性后落 RAMB36/FIFO。
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] a_bram [0:N-1];
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] b_bram [0:N-1];
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] c_bram [0:N-1];
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] d_bram [0:N-1];

    // 中间结果（pair0 → m1，pair1 → m2）
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] m1_bram [0:N-1];
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] m2_bram [0:N-1];

    // 最终输出（pair2）
    (* RAM_STYLE = "block" *) logic [Q_WIDTH-1:0] out_bram [0:N-1];

    // 系数存储（原始 signed，使用时现场转 mod Q 表示）
    logic signed [COEFF_WIDTH-1:0] coeff_bram [0:COEFF_COUNT-1];

    // =========================================================================
    // 模 Q 算术函数
    // =========================================================================
    // (a - b) mod Q，a,b ∈ [0, Q)
    function automatic logic [Q_WIDTH-1:0] sub_mod_q(
        input logic [Q_WIDTH-1:0] a,
        input logic [Q_WIDTH-1:0] b
    );
        logic [Q_WIDTH:0] d;
        d = (a >= b) ? ({1'b0, a} - {1'b0, b})
                     : ({1'b0, a} - {1'b0, b} + {1'b0, Q_VALUE});
        return d[Q_WIDTH-1:0];
    endfunction

    // (a + b) mod Q，a,b ∈ [0, Q)，s < 2Q < 2^46，1 次条件减收敛
    function automatic logic [Q_WIDTH-1:0] add2_mod_q(
        input logic [Q_WIDTH-1:0] a,
        input logic [Q_WIDTH-1:0] b
    );
        logic [Q_WIDTH:0] s;
        logic [Q_WIDTH-1:0] r;
        s = {1'b0, a} + {1'b0, b};
        if (s >= {1'b0, Q_VALUE}) s = s - {1'b0, Q_VALUE};
        r = s[Q_WIDTH-1:0];
        return r;
    endfunction

    // (a + b + c) mod Q，a,b,c ∈ [0, Q)，s < 3Q < 2^47，2 次条件减收敛
    function automatic logic [Q_WIDTH-1:0] add3_mod_q(
        input logic [Q_WIDTH-1:0] a,
        input logic [Q_WIDTH-1:0] b,
        input logic [Q_WIDTH-1:0] c
    );
        logic [Q_WIDTH+1:0] s;
        logic [Q_WIDTH+1:0] qe;
        qe = {2'b0, Q_VALUE};
        s  = {2'b0, a} + {2'b0, b} + {2'b0, c};
        s  = (s >= qe) ? s - qe : s;
        s  = (s >= qe) ? s - qe : s;
        return s[Q_WIDTH-1:0];
    endfunction

    // signed 32-bit 系数 → [0, Q) 的模表示（负系数映射为 Q - |c|）
    function automatic logic [Q_WIDTH-1:0] to_mod_q(
        input logic signed [COEFF_WIDTH-1:0] cv
    );
        logic signed [Q_WIDTH:0] v;
        logic [Q_WIDTH:0] nv;
        logic [Q_WIDTH-1:0] r;
        v  = cv;
        nv = 0 - v;                      // |v|（v<0 时为正）
        if (v >= '0) r = v[Q_WIDTH-1:0];
        else         r = Q_VALUE - nv[Q_WIDTH-1:0];
        return r;
    endfunction

    // =========================================================================
    // BRAM 读出（pair_idx 选择源多项式，1 拍读延迟，显式建模与综合一致）
    // 修正 (E11)：原 case 内联读 → Vivado 无法推断 BRAM36（读端口条件激活）。
    //   改为：每个 BRAM 始终有独立读端口（wire 直连），再用 mux 选输出。
    // =========================================================================
    logic [Q_WIDTH-1:0] x_rd;
    logic [Q_WIDTH-1:0] y_rd;
    logic [Q_WIDTH-1:0] x_bram_r;
    logic [Q_WIDTH-1:0] y_bram_r;

    // 每个 BRAM 独立读端口（始终活跃，满足 BRAM 推断条件）
    wire [Q_WIDTH-1:0] a_rd  = a_bram[slot_idx];
    wire [Q_WIDTH-1:0] b_rd  = b_bram[slot_idx];
    wire [Q_WIDTH-1:0] c_rd  = c_bram[slot_idx];
    wire [Q_WIDTH-1:0] d_rd  = d_bram[slot_idx];
    wire [Q_WIDTH-1:0] m1_rd = m1_bram[slot_idx];
    wire [Q_WIDTH-1:0] m2_rd = m2_bram[slot_idx];

    // pair_idx 选择哪一对输入
    assign x_rd = (pair_idx == 2'd0) ? a_rd  :
                  (pair_idx == 2'd1) ? c_rd  :
                  (pair_idx == 2'd2) ? m1_rd : '0;
    assign y_rd = (pair_idx == 2'd0) ? b_rd  :
                  (pair_idx == 2'd1) ? d_rd  :
                  (pair_idx == 2'd2) ? m2_rd : '0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_bram_r <= '0;
            y_bram_r <= '0;
        end else begin
            x_bram_r <= x_rd;
            y_bram_r <= y_rd;
        end
    end

    // =========================================================================
    // 45×45 MAC + Barrett 归约（4 级流水：DSP→reg→Barrett1→reg→Barrett2→reg→add）
    // 修正 (E12)：原版 mul_b→DSP→Barrett→add→mul_a 单拍 19.85ns（WNS -10ns）。
    //   3 级流水后 WNS -3.85ns，瓶颈在 Barrett 内部 6 DSP 链（13.6ns/44 级）。
    //   将 Barrett 拆为 2 子级：Stage1=u*V→mu, Stage2=mu*Q→t→r。
    //   MAC: C_MAC_DSP→C_MAC_BAR1→C_MAC_BAR2→C_MAC_ADD（4 拍/步）。
    //   ÷2:  C_MUL2_DSP→C_MUL2_BAR1→C_MUL2_BAR2→C_STORE（4 拍）。
    // =========================================================================
    wire [2*Q_WIDTH-1:0] prod_raw     = mul_a * mul_b;   // 90-bit 满积（组合）
    logic [2*Q_WIDTH-1:0] prod_raw_reg;                   // 流水寄存器（DSP 输出）
    logic [45:0]         mu_reg;                          // 流水寄存器（Barrett Stage1）
    logic [Q_WIDTH-1:0]  prod_mod_reg;                   // 流水寄存器（Barrett Stage2）

    // --- Barrett Stage 1（组合，从 prod_raw_reg 计算 mu）---
    //   u = x >> (K-1) = x[89:44]
    //   uv = u * V_VALUE (46×46=92 bit)
    //   mu = uv >> (K+1) = uv[91:46]
    localparam logic [44:0] Q_VAL = Q_VALUE;
    localparam logic [45:0] V_VAL = V_VALUE;
    wire [45:0] bar_u   = prod_raw_reg[89:44];
    wire [91:0] bar_uv  = bar_u * V_VAL;
    wire [45:0] bar_mu  = bar_uv[91:46];

    // --- Barrett Stage 2（组合，从 mu_reg + prod_raw_reg 计算 r）---
    //   muq = mu * Q (46×45=91 bit)
    //   t   = x - muq
    //   t0  = t >= Q ? t - Q : t
    //   t1  = t0 >= Q ? t0 - Q : t0
    //   r   = t1[44:0]
    wire [91:0] bar_muq = mu_reg * Q_VAL;
    wire [91:0] bar_t   = {2'b0, prod_raw_reg} - bar_muq;
    wire [91:0] bar_t0  = (bar_t  >= {87'b0, Q_VAL}) ? bar_t  - {87'b0, Q_VAL} : bar_t;
    wire [91:0] bar_t1  = (bar_t0 >= {87'b0, Q_VAL}) ? bar_t0 - {87'b0, Q_VAL} : bar_t0;
    wire [Q_WIDTH-1:0] bar_r = bar_t1[Q_WIDTH-1:0];

    // 修正 (E12)：new_acc 用寄存后的 prod_mod_reg
    wire [Q_WIDTH-1:0] coeff_sel = to_mod_q(coeff_bram[mac_step]);
    wire [Q_WIDTH-1:0] new_acc   = add2_mod_q(prod_mod_reg, coeff_sel);

    // =========================================================================
    // 输入 / 系数握手
    // =========================================================================
    assign s_ready     = (state == S_LOAD_A) || (state == S_LOAD_B) ||
                         (state == S_LOAD_C) || (state == S_LOAD_D);
    // 修正 (E4)：不再依赖 coeff_valid，避免 TB 在 valid=0 后轮询死锁
    assign coeff_ready = (state == S_LOAD_COEFFS);

    // =========================================================================
    // 顶层状态跳转（组合）
    // =========================================================================
    always_comb begin
        state_next = state;
        case (state)
            S_IDLE:
                if (pool_start) state_next = S_LOAD_A;
            S_LOAD_A:
                if (s_last) state_next = S_LOAD_B;
            S_LOAD_B:
                if (s_last) state_next = S_LOAD_C;
            S_LOAD_C:
                if (s_last) state_next = S_LOAD_D;
            S_LOAD_D:
                if (s_last) state_next = S_LOAD_COEFFS;
            S_LOAD_COEFFS:
                if (coeff_cnt >= COEFF_COUNT[4:0]) state_next = S_CALC;
            S_CALC:
                if (pair_idx == 2'd2 && slot_idx == IDX_W'(N-1) && cs == C_NEXT)
                    state_next = S_OUTPUT;
            S_OUTPUT:
                if (output_idx == IDX_W'(N-1)) state_next = S_DONE;
            S_DONE:
                if (done_cnt >= 3'd6) state_next = S_IDLE;   // 修正 (E6)：保持 7 拍
            default:
                state_next = S_IDLE;
        endcase
    end

    // =========================================================================
    // BRAM 写入（无复位 always @(posedge clk) 块，让 Vivado 能推断 BRAM36）
    // 修正 (E9)：原版把 7 个 4096×45-bit 的 BRAM 写操作放在
    //   `always @(posedge clk or negedge rst_n)` 里 → 异步复位阻断 BRAM
    //   推断 → 综合器试图用 184320 bit 寄存器实现 → 超容量报错。
    // 修法：所有 BRAM 写入收敛进本无复位块；主 FSM 块只管控制信号。
    // =========================================================================
    always @(posedge clk) begin
        // 输入流写入 4 个输入 BRAM（S_LOAD_* 期间）
        // 修正 (E11)：用显式 if 替代 case，每个 BRAM 独立写使能，利于 BRAM 推断
        if (s_valid && s_ready && state == S_LOAD_A) a_bram[stream_idx] <= s_tdata;
        if (s_valid && s_ready && state == S_LOAD_B) b_bram[stream_idx] <= s_tdata;
        if (s_valid && s_ready && state == S_LOAD_C) c_bram[stream_idx] <= s_tdata;
        if (s_valid && s_ready && state == S_LOAD_D) d_bram[stream_idx] <= s_tdata;

        // 计算结果写回（S_CALC 期间的 C_STORE）
        // 修正 (E12)：用 prod_mod_reg（Barrett 输出寄存）替代组合 prod_mod
        if (state == S_CALC && cs == C_STORE) begin
            if (pair_idx == 2'd0) m1_bram[slot_idx]  <= prod_mod_reg;
            if (pair_idx == 2'd1) m2_bram[slot_idx]  <= prod_mod_reg;
            if (pair_idx == 2'd2) out_bram[slot_idx] <= prod_mod_reg;
        end
    end

    // =========================================================================
    // 主 FSM / 控制寄存器（单一 always 块，杜绝双驱动；BRAM 写入见上块）
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cs         <= C_REQ0;
            stream_idx <= '0;
            coeff_cnt  <= '0;
            slot_idx   <= '0;
            pair_idx   <= 2'd0;
            mac_step   <= '0;
            done_cnt   <= 3'd0;
            output_idx <= '0;
            xa_r       <= '0;
            ya_r       <= '0;
            diff_r     <= '0;
            acc_r      <= '0;
            sum_r      <= '0;
            mul_a      <= '0;
            mul_b      <= '0;
            prod_raw_reg <= '0;
            mu_reg       <= '0;
            prod_mod_reg <= '0;
        end else begin
            state <= state_next;

            // -----------------------------------------------------------------
            // 输入多项式加载时的索引推进（BRAM 写入已移至上方无复位块）
            // -----------------------------------------------------------------
            if (s_valid && s_ready) begin
                stream_idx <= (s_last) ? '0 : stream_idx + IDX_W'(1);
            end

            // -----------------------------------------------------------------
            // 系数加载
            // -----------------------------------------------------------------
            // 修正 (E8)：进入 S_LOAD_COEFFS 必须清零 coeff_cnt。否则第二遍连续
            //   池化时 coeff_cnt 仍为第一遍的 13，进态即判 >= 13 提前跳 S_CALC，
            //   而 TB 还在发 A 多项式（s_ready=0）→ while(!s_ready) 永久阻塞（T7 超时）。
            if (state == S_LOAD_D && s_last) coeff_cnt <= 5'd0;

            if (state == S_LOAD_COEFFS && coeff_valid) begin
                coeff_bram[coeff_addr] <= $signed(coeff_data);
                coeff_cnt  <= coeff_cnt + 5'd1;
            end

            // -----------------------------------------------------------------
            // 进入 S_CALC 首拍：初始化 slot 子状态机
            // -----------------------------------------------------------------
            if (state_next == S_CALC && state != S_CALC) begin
                cs         <= C_REQ0;
                pair_idx   <= 2'd0;
                slot_idx   <= '0;
                output_idx <= '0;
            end

            // -----------------------------------------------------------------
            // slot 计算子状态机（仅 S_CALC 期间推进）
            // 修正 (E3)：diff / acc / sum 全部真正写入数据通路
            // -----------------------------------------------------------------
            if (state == S_CALC) begin
                case (cs)
                    C_REQ0: begin
                        // 等 x_bram_r / y_bram_r 装载当前 slot_idx 的值
                    end
                    C_REQ1: begin
                        // 装载本 slot 的 diff / acc 初值，置定第 1 次 MAC 输入
                        xa_r     <= x_bram_r;
                        ya_r     <= y_bram_r;
                        diff_r   <= sub_mod_q(x_bram_r, y_bram_r);
                        acc_r    <= to_mod_q(coeff_bram[POLY_ORDER]);
                        mul_a    <= to_mod_q(coeff_bram[POLY_ORDER]);
                        mul_b    <= sub_mod_q(x_bram_r, y_bram_r);
                        mac_step <= POLY_ORDER[4:0] - 5'd1;
                    end
                    C_MAC_DSP: begin
                        // E12 第 1 级：DSP 输出寄存
                        prod_raw_reg <= prod_raw;
                    end
                    C_MAC_BAR1: begin
                        // E12 第 2 级：Barrett Stage1 → mu_reg
                        mu_reg <= bar_mu;
                    end
                    C_MAC_BAR2: begin
                        // E12 第 3 级：Barrett Stage2 → prod_mod_reg
                        prod_mod_reg <= bar_r;
                    end
                    C_MAC_ADD: begin
                        // E12 第 4 级：累加 + mul_a 反馈
                        acc_r <= new_acc;
                        if (mac_step != 5'd0) begin
                            mul_a    <= new_acc;
                            mul_b    <= diff_r;
                            mac_step <= mac_step - 5'd1;
                        end
                    end
                    C_SUM: begin
                        sum_r <= add3_mod_q(xa_r, ya_r, acc_r);
                    end
                    C_MUL2: begin
                        // 置定 ÷2 乘法输入：mul_a=sum, mul_b=Q_HALF
                        mul_a <= sum_r;
                        mul_b <= Q_HALF;
                    end
                    C_MUL2_DSP: begin
                        // E12 ÷2 第 1 级：DSP 输出寄存
                        prod_raw_reg <= prod_raw;
                    end
                    C_MUL2_BAR1: begin
                        // E12 ÷2 第 2 级：Barrett Stage1 → mu_reg
                        mu_reg <= bar_mu;
                    end
                    C_MUL2_BAR2: begin
                        // E12 ÷2 第 3 级：Barrett Stage2 → prod_mod_reg
                        prod_mod_reg <= bar_r;
                    end
                    C_STORE: begin
                        // BRAM 写入已在上方无复位块完成（用 prod_mod_reg）
                    end
                    C_NEXT: begin
                        // slot / pair 推进
                        if (slot_idx != IDX_W'(N-1)) begin
                            slot_idx <= slot_idx + IDX_W'(1);
                        end else if (pair_idx != 2'd2) begin
                            pair_idx <= pair_idx + 2'd1;
                            slot_idx <= '0;
                        end
                    end
                    default: ;
                endcase

                // 子状态跳转（E12：MAC 4 拍/步 + ÷2 4 拍）
                case (cs)
                    C_REQ0:       cs <= C_REQ1;
                    C_REQ1:       cs <= C_MAC_DSP;
                    C_MAC_DSP:    cs <= C_MAC_BAR1;
                    C_MAC_BAR1:   cs <= C_MAC_BAR2;
                    C_MAC_BAR2:   cs <= C_MAC_ADD;
                    C_MAC_ADD:    cs <= (mac_step == 5'd0) ? C_SUM : C_MAC_DSP;
                    C_SUM:        cs <= C_MUL2;
                    C_MUL2:       cs <= C_MUL2_DSP;
                    C_MUL2_DSP:   cs <= C_MUL2_BAR1;
                    C_MUL2_BAR1:  cs <= C_MUL2_BAR2;
                    C_MUL2_BAR2:  cs <= C_STORE;
                    C_STORE:      cs <= C_NEXT;
                    C_NEXT:       cs <= C_REQ0;
                    default:      cs <= C_REQ0;
                endcase
            end

            // -----------------------------------------------------------------
            // 输出流（修正 E5：valid 不依赖 ready）
            // -----------------------------------------------------------------
            if (state == S_OUTPUT && m_valid && m_ready) begin
                output_idx <= output_idx + IDX_W'(1);
            end

            // -----------------------------------------------------------------
            // done 脉冲计数（S_DONE 保持 7 拍，防 TB 轮询漏采）
            // -----------------------------------------------------------------
            if (state == S_DONE) begin
                done_cnt <= (done_cnt >= 3'd6) ? 3'd0 : done_cnt + 3'd1;
            end else begin
                done_cnt <= 3'd0;
            end
        end
    end

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign m_valid = (state == S_OUTPUT);
    assign m_last  = (state == S_OUTPUT) && (output_idx == IDX_W'(N-1));
    assign m_tdata = out_bram[output_idx];

    assign pool_busy  = (state != S_IDLE) && (state != S_DONE);
    assign pool_done  = (state == S_DONE);
    assign pool_error = 1'b0;

endmodule
