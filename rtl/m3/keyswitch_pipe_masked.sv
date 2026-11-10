// =============================================================================
// keyswitch_pipe_masked.sv — E39 一阶加性掩码（arithmetic sharing）keyswitch
//
// 在 keyswitch_pipe（M3-c，单对重线性化）之上加一阶掩码：
//   keyswitch key (a, b) 分成两个加性份额
//       a = a1 + a2  mod q,   b = b1 + b2  mod q
//   份额分别独立处理（不重叠、不合并），输出再合并：
//       pass1（e0=0,   e1=real, a=a1, b=b1）:
//           f0_p1 = e2*b1        f1_p1 = e1 - e2*a1
//       pass2（e0=real, e1=0,    a=a2, b=b2）:
//           f0_p2 = e0 + e2*b2   f1_p2 = - e2*a2
//       合并： f0 = (f0_p1 + f0_p2) mod q = e0 + e2*(b1+b2) = e0 + e2*b
//             f1 = (f1_p1 + f1_p2) mod q = e1 - e2*(a1+a2) = e1 - e2*a
//
// 密码学性质：mod-q 乘法对加性份额是线性的（d2*(a1+a2) = d2*a1 + d2*a2 mod q），
// 因此任意时刻 a_buf/b_buf/e2a_buf/e2b_buf 等寄存器只持有单一份额，一阶
// （first-order）功耗/翻转泄露与真实密钥统计独立（Distributed Resilience
// Against side-channel Execution, DARE 的最低阶要求）。
//
// 成本模型（E39 评估）：
//   - 本实现 = 顺序双通（2-pass）：面积 0% 额外（复用同一 keyswitch_pipe 实例），
//     延时 +100% keyswitch（+2 次串行 poly_mult）
//   - 备选并行双实例：延时 0%，面积 +1× keyswitch_pipe
//
// 玩具默认参数与 keyswitch_pipe 一致（N=16, Q=113, Q_WIDTH=7, USE_FASTRED=0）。
// =============================================================================

`timescale 1ns / 1ps

module keyswitch_pipe_masked #(
    parameter int LOG_N           = 4,
    parameter int N               = 1 << LOG_N,
    parameter int Q_WIDTH         = 7,
    parameter logic [Q_WIDTH-1:0] Q_VAL   = 7'd113,
    parameter logic [Q_WIDTH-1:0] N_INV   = 7'd106,
    parameter int USE_FASTRED     = 0,
    // Twiddle ROM init files (transparent to inner poly_mult, M-D')
    parameter string TW_FILE     = "rtl/m5/tw/tw_omega_p1_n16.hex",
    parameter string TW_INV_FILE = "rtl/m5/tw/tw_omegainv_p1_n16.hex"
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  start,
    output logic                  busy,
    output logic                  done,
    output logic                  error,

    // 输入：3 元素密文（AXI-Stream sink）
    input  logic                  e0_valid,
    output logic                  e0_ready,
    input  logic [Q_WIDTH-1:0]    e0_data,
    input  logic                  e1_valid,
    output logic                  e1_ready,
    input  logic [Q_WIDTH-1:0]    e1_data,
    input  logic                  e2_valid,
    output logic                  e2_ready,
    input  logic [Q_WIDTH-1:0]    e2_data,

    // 输入：keyswitch key 份额 1 / 份额 2（a = a1+a2, b = b1+b2 mod q）
    input  logic                  a1_valid,
    output logic                  a1_ready,
    input  logic [Q_WIDTH-1:0]    a1_data,
    input  logic                  b1_valid,
    output logic                  b1_ready,
    input  logic [Q_WIDTH-1:0]    b1_data,
    input  logic                  a2_valid,
    output logic                  a2_ready,
    input  logic [Q_WIDTH-1:0]    a2_data,
    input  logic                  b2_valid,
    output logic                  b2_ready,
    input  logic [Q_WIDTH-1:0]    b2_data,

    // 输出：2 元素密文（与未掩码 keyswitch_pipe 逐系数一致）
    output logic                  f0_valid,
    input  logic                  f0_ready,
    output logic [Q_WIDTH-1:0]    f0_data,
    output logic                  f1_valid,
    input  logic                  f1_ready,
    output logic [Q_WIDTH-1:0]    f1_data

);

    // -------------------------------------------------------------------------
    // wrapper 输入缓冲（7 路）
    // -------------------------------------------------------------------------
    logic [Q_WIDTH-1:0] e0_buf [0:N-1];
    logic [Q_WIDTH-1:0] e1_buf [0:N-1];
    logic [Q_WIDTH-1:0] e2_buf [0:N-1];
    logic [Q_WIDTH-1:0] a1_buf [0:N-1];
    logic [Q_WIDTH-1:0] b1_buf [0:N-1];
    logic [Q_WIDTH-1:0] a2_buf [0:N-1];
    logic [Q_WIDTH-1:0] b2_buf [0:N-1];

    // 两遍输出捕获
    logic [Q_WIDTH-1:0] f0_p1 [0:N-1], f0_p2 [0:N-1];
    logic [Q_WIDTH-1:0] f1_p1 [0:N-1], f1_p2 [0:N-1];
    logic [LOG_N:0]     cap_idx_f0, cap_idx_f1;

    // 合并输出
    logic [Q_WIDTH-1:0] f0_comb [0:N-1];
    logic [Q_WIDTH-1:0] f1_comb [0:N-1];

    // -------------------------------------------------------------------------
    // wrapper FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD,          // 7 路并行加载
        S_P1_START,      // pass1 start 脉冲
        S_P1_DRIVE,      // 驱动内层 keyswitch（e0=0, e1, e2, a1, b1）
        S_P1_RUN,        // 等内层 done（输出捕获中）
        S_P2_START,
        S_P2_DRIVE,      // 驱动内层（e0, e1=0, e2, a2, b2）
        S_P2_RUN,
        S_SUM,           // 合并两遍输出 mod q
        S_OUT_F0,
        S_OUT_F1,
        S_DONE
    } state_t;

    state_t wstate, wstate_next;
    logic [LOG_N:0] widx;          // LOAD/DRIVE/SUM 计数
    logic [LOG_N:0] oidx;          // 输出计数
    logic           pass_sel;      // 0 = pass1, 1 = pass2

    assign busy  = (wstate != S_IDLE);
    assign done  = (wstate == S_DONE);
    assign error = 1'b0;

    // -------------------------------------------------------------------------
    // 内层 keyswitch_pipe 实例（顺序双通复用）
    // -------------------------------------------------------------------------
    logic                  ks_start, ks_busy, ks_done, ks_error;
    logic                  ks_e0_v, ks_e1_v, ks_e2_v, ks_a_v, ks_b_v;
    logic                  ks_e0_r, ks_e1_r, ks_e2_r, ks_a_r, ks_b_r;
    logic [Q_WIDTH-1:0]    ks_e0_d, ks_e1_d, ks_e2_d, ks_a_d, ks_b_d;
    logic                  ks_f0_v, ks_f1_v;
    logic [Q_WIDTH-1:0]    ks_f0_d, ks_f1_d;

    keyswitch_pipe #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VAL(Q_VAL),
        .N_INV(N_INV),
        .USE_FASTRED(USE_FASTRED),
        .TW_FILE(TW_FILE),
        .TW_INV_FILE(TW_INV_FILE)
    ) u_ks (
        .clk(clk), .rst_n(rst_n),
        .start(ks_start), .busy(ks_busy), .done(ks_done), .error(ks_error),
        .e0_valid(ks_e0_v), .e0_ready(ks_e0_r), .e0_data(ks_e0_d),
        .e1_valid(ks_e1_v), .e1_ready(ks_e1_r), .e1_data(ks_e1_d),
        .e2_valid(ks_e2_v), .e2_ready(ks_e2_r), .e2_data(ks_e2_d),
        .a_valid(ks_a_v),   .a_ready(ks_a_r),   .a_data(ks_a_d),
        .b_valid(ks_b_v),   .b_ready(ks_b_r),   .b_data(ks_b_d),
        .f0_valid(ks_f0_v), .f0_ready(1'b1),    .f0_data(ks_f0_d),
        .f1_valid(ks_f1_v), .f1_ready(1'b1),    .f1_data(ks_f1_d)
    );

    // 内层驱动（组合，valid 由内层 ready 门控；data 由 pass 选择）
    assign ks_start = (wstate == S_P1_START) || (wstate == S_P2_START);

    assign ks_e0_v = ((wstate == S_P1_DRIVE) || (wstate == S_P2_DRIVE)) && ks_e0_r;
    assign ks_e1_v = ((wstate == S_P1_DRIVE) || (wstate == S_P2_DRIVE)) && ks_e1_r;
    assign ks_e2_v = ((wstate == S_P1_DRIVE) || (wstate == S_P2_DRIVE)) && ks_e2_r;
    assign ks_a_v  = ((wstate == S_P1_DRIVE) || (wstate == S_P2_DRIVE)) && ks_a_r;
    assign ks_b_v  = ((wstate == S_P1_DRIVE) || (wstate == S_P2_DRIVE)) && ks_b_r;

    wire [Q_WIDTH-1:0] zero_coeff = '0;
    assign ks_e0_d = (wstate == S_P2_DRIVE) ? e0_buf[widx] : zero_coeff;
    assign ks_e1_d = (wstate == S_P1_DRIVE) ? e1_buf[widx] : zero_coeff;
    assign ks_e2_d = e2_buf[widx];
    assign ks_a_d  = (wstate == S_P1_DRIVE) ? a1_buf[widx] : a2_buf[widx];
    assign ks_b_d  = (wstate == S_P1_DRIVE) ? b1_buf[widx] : b2_buf[widx];

    // 内层输出捕获（f0_ready/f1_ready 恒 1，内层输出阶段逐拍流式）
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cap_idx_f0 <= '0;
            cap_idx_f1 <= '0;
        end else begin
            // 每遍开始前清零捕获索引（PASS 进入驱动态的最后一拍）
            if (((wstate == S_P1_DRIVE) || (wstate == S_P2_DRIVE)) &&
                widx == N-1) begin
                cap_idx_f0 <= '0;
                cap_idx_f1 <= '0;
            end else if (ks_f0_v) begin
                if (pass_sel) f0_p2[cap_idx_f0] <= ks_f0_d;
                else          f0_p1[cap_idx_f0] <= ks_f0_d;
                cap_idx_f0 <= cap_idx_f0 + 1'b1;
            end else if (ks_f1_v) begin
                if (pass_sel) f1_p2[cap_idx_f1] <= ks_f1_d;
                else          f1_p1[cap_idx_f1] <= ks_f1_d;
                cap_idx_f1 <= cap_idx_f1 + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // FSM 组合
    // -------------------------------------------------------------------------
    always_comb begin
        wstate_next = wstate;
        case (wstate)
            S_IDLE:     if (start) wstate_next = S_LOAD;
            S_LOAD:     if (widx == N-1) wstate_next = S_P1_START;
            S_P1_START: wstate_next = S_P1_DRIVE;
            S_P1_DRIVE: if (widx >= N) wstate_next = S_P1_RUN;
            S_P1_RUN:   if (ks_done) wstate_next = S_P2_START;
            S_P2_START: wstate_next = S_P2_DRIVE;
            S_P2_DRIVE: if (widx >= N) wstate_next = S_P2_RUN;
            S_P2_RUN:   if (ks_done) wstate_next = S_SUM;
            S_SUM:      if (widx == N-1) wstate_next = S_OUT_F0;
            S_OUT_F0:   if (oidx == N-1) wstate_next = S_OUT_F1;
            S_OUT_F1:   if (oidx == N-1) wstate_next = S_DONE;
            S_DONE:     wstate_next = S_IDLE;
            default:    wstate_next = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // FSM 时序：widx / oidx / pass_sel / 缓冲写入
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wstate    <= S_IDLE;
            widx      <= '0;
            oidx      <= '0;
            pass_sel  <= 1'b0;
        end else begin
            wstate <= wstate_next;
            if (wstate_next != wstate) begin
                case (wstate_next)
                    S_LOAD, S_P1_DRIVE, S_P2_DRIVE, S_SUM: widx <= '0;
                    S_OUT_F0, S_OUT_F1:                    oidx <= '0;
                    default: ;
                endcase
                if (wstate_next == S_P2_START) pass_sel <= 1'b1;
                if (wstate_next == S_P1_START) pass_sel <= 1'b0;
            end else begin
                case (wstate)
                    // widx 递增（数据写入见下方独立 always_ff：保证退出拍
                    // 也完成写入，避免最后一个系数为 X）
                    S_LOAD: if (widx < N) widx <= widx + 1'b1;
                    // DRIVE：widx 跟随内层 LOAD 阶段（ready 高的周期计数）
                    S_P1_DRIVE, S_P2_DRIVE: if (ks_e0_r && widx < N)
                                                widx <= widx + 1'b1;
                    S_SUM: if (widx < N) widx <= widx + 1'b1;
                    S_OUT_F0, S_OUT_F1: oidx <= oidx + 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // 输入缓冲写入（独立于状态切换分支）
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if ((wstate == S_LOAD) && (widx < N)) begin
            if (e0_valid) e0_buf[widx] <= e0_data;
            if (e1_valid) e1_buf[widx] <= e1_data;
            if (e2_valid) e2_buf[widx] <= e2_data;
            if (a1_valid) a1_buf[widx] <= a1_data;
            if (b1_valid) b1_buf[widx] <= b1_data;
            if (a2_valid) a2_buf[widx] <= a2_data;
            if (b2_valid) b2_buf[widx] <= b2_data;
        end
    end

    // -------------------------------------------------------------------------
    // 份额合并（独立于状态切换分支）
    // -------------------------------------------------------------------------
    logic [Q_WIDTH:0] sum_f0, sum_f1;   // 扩位：避免 7 位加法先回绕 mod 128

    always_ff @(posedge clk) begin
        if ((wstate == S_SUM) && (widx < N)) begin
            sum_f0 = {1'b0, f0_p1[widx]} + {1'b0, f0_p2[widx]};
            sum_f1 = {1'b0, f1_p1[widx]} + {1'b0, f1_p2[widx]};
            // f0 = (f0_p1 + f0_p2) mod q（单次减；和 < 2q 恒成立）
            f0_comb[widx] <= (sum_f0 >= {1'b0, Q_VAL}) ?
                             (sum_f0 - {1'b0, Q_VAL}) : sum_f0;
            // f1 = (f1_p1 + f1_p2) mod q（单次减）
            f1_comb[widx] <= (sum_f1 >= {1'b0, Q_VAL}) ?
                             (sum_f1 - {1'b0, Q_VAL}) : sum_f1;
        end
    end

    // -------------------------------------------------------------------------
    // wrapper 端口：ready 仅在 S_LOAD；输出 valid/数据
    // -------------------------------------------------------------------------
    assign e0_ready = (wstate == S_LOAD);
    assign e1_ready = (wstate == S_LOAD);
    assign e2_ready = (wstate == S_LOAD);
    assign a1_ready = (wstate == S_LOAD);
    assign b1_ready = (wstate == S_LOAD);
    assign a2_ready = (wstate == S_LOAD);
    assign b2_ready = (wstate == S_LOAD);

    assign f0_valid = (wstate == S_OUT_F0);
    assign f1_valid = (wstate == S_OUT_F1);
    assign f0_data  = f0_comb[oidx];
    assign f1_data  = f1_comb[oidx];

endmodule
