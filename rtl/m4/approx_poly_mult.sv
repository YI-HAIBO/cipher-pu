// =============================================================================
// approx_poly_mult.sv  —  近似多项式点乘加速器（密推芯 M4-d，包裹器）
//
// 功能：
//   - 内部例化 M2-c 的 poly_mult（NTT→点乘→INTT，M3/M2 已验证，不修改）
//   - 在 poly_mult 的 out_* 流后加一级输出后处理（1 cycle delay）：
//       * 稀疏掩码：use_approx_mult=1 时，若 out_data < sparsity_threshold
//                    或 (Q_VALUE - out_data) < sparsity_threshold，输出置 0
//       * 截断占位：保留 trunc_bits 输入端口供未来输入侧或点乘侧接入
//                    （当前版本对 poly_mult 输出系数不直接做位截断，
//                      因 poly_mult 内部完成 mod q，直接截断会破坏模运算完整性；
//                      真正的位截断通过 sparse_ntt_unit 时域系数掩码 +
//                      trunc_multiplier 内嵌点乘器实现，属于上层集成策略）
//
// 稀疏检测位置决策：
//   - 主稀疏检测在 sparse_ntt_unit（时域 NTT 前，Phase 1 §3.2 已锁定）
//   - 本模块做**输出侧稀疏掩码**，用于消除 poly_mult 输出的微小数值系数
//     （在 Gear 2/3 加速档下，poly_mult 输出会因稀疏输入产生新的微小项，
//     此处过滤可减少下游 rescale/decryption 阶段的噪声源）
//
// 稀疏模式（Task #84 步骤 4 扩展）：
//   - block_sparse_en=0（元素级，向后兼容）：逐系数检测，
//     |c| < threshold 或 (Q-c) < threshold 时置 0
//   - block_sparse_en=1（块级，新增）：以 B 为块大小，块内 max_abs >= threshold
//     则整块保留，否则整块置 0（B 深度缓冲 + max_abs 决策）
//
// 接口：与 poly_mult 完全兼容 + 4 个档位信号
//   - sparsity_threshold : 稀疏阈值（=0 时无掩码，等价于 poly_mult）
//   - trunc_bits         : 截断位数（当前版本作占位，不影响 poly_mult 输出）
//   - use_approx_mult    : 近似乘法使能（=0 时等价于 poly_mult，透传）
//   - block_sparse_en    : 0=元素级, 1=块级（block_sparse_en=1 需要 B>=1 参数）
//
// 参数：
//   LOG_N      : log2(N)
//   N          : 多项式长度
//   Q_WIDTH    : 系数位宽
//   Q_VALUE    : 素数模
//   N_INV      : N^-1 mod Q（INTT 缩放用）
//   USE_FASTRED: 取模路径选择（透传给 poly_mult）
//
// 使用建议：
//   - 玩具配置: N=16, Q_WIDTH=7, Q_VALUE=113, N_INV=106, USE_FASTRED=0
//   - 生产配置: N=2^14, Q_WIDTH=45, Q_VALUE=2^44+131073, N_INV=17591112433657,
//     USE_FASTRED=1
//
// 时序：额外 1 cycle 延迟（输出后处理寄存器）
//
// 依赖模块：
//   - poly_mult (rtl/m2/poly_mult.sv)  M2-c 已验证的完整点乘加速器
//
// =============================================================================

`timescale 1ns / 1ps

module approx_poly_mult #(
    parameter int LOG_N      = 4,
    parameter int N          = 1 << LOG_N,
    parameter int Q_WIDTH    = 7,
    parameter logic [Q_WIDTH-1:0] Q_VALUE    = 113,
    parameter logic [Q_WIDTH-1:0] N_INV      = 106,
    parameter int USE_FASTRED = 0,
    parameter bit USE_BRAM_IP = (N >= 2048),   // 仿真可显式置 0 走自动推断
    parameter int B           = 1,             // 块大小（块级稀疏用，B 必须整除 N）
    // M-D': twiddle ROM init files (transparent to inner poly_mult)
    parameter string TW_FILE     = "rtl/m5/tw/tw_omega_p1_n16.hex",
    parameter string TW_INV_FILE = "rtl/m5/tw/tw_omegainv_p1_n16.hex"
) (
    input  wire logic               clk,
    input  wire logic               rst_n,

    // 档位控制信号（来自 gear_controller）
    input  wire logic [Q_WIDTH-1:0] sparsity_threshold,
    input  wire logic [7:0]         trunc_bits,
    input  wire logic               use_approx_mult,
    input  wire logic               block_sparse_en,   // 0=元素级, 1=块级

    // 控制
    input  wire logic               start,
    output wire logic               busy,
    output wire logic               done,
    output wire logic               error,

    // A 输入流（透传给 poly_mult）
    input  wire logic [Q_WIDTH-1:0] a_in_data,
    input  wire logic               a_in_valid,
    output wire logic               a_in_ready,

    // B 输入流（透传给 poly_mult）
    input  wire logic [Q_WIDTH-1:0] b_in_data,
    input  wire logic               b_in_valid,
    output wire logic               b_in_ready,

    // C 输出流（后处理输出）
    output wire logic [Q_WIDTH-1:0] out_data,
    output wire logic               out_valid,
    output wire logic               out_last,
    input  wire logic               out_ready

);

    // =========================================================================
    // 中间信号：poly_mult 输出 → 后处理输入
    // =========================================================================
    wire [Q_WIDTH-1:0] pm_out_data;
    wire               pm_out_valid;
    wire               pm_out_last;
    wire               pm_out_ready;

    // =========================================================================
    // 例化 poly_mult（M2-c 已交付，不修改）
    // =========================================================================
    poly_mult #(
        .LOG_N      (LOG_N),
        .N          (N),
        .Q_WIDTH    (Q_WIDTH),
        .Q_VALUE    (Q_VALUE),
        .N_INV      (N_INV),
        .USE_FASTRED(USE_FASTRED),
        .USE_BRAM_IP(USE_BRAM_IP),
        .TW_FILE    (TW_FILE),
        .TW_INV_FILE(TW_INV_FILE)
    ) pm_inst (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .busy        (busy),
        .done        (done),
        .error       (error),
        .a_in_data   (a_in_data),
        .a_in_valid  (a_in_valid),
        .a_in_ready  (a_in_ready),
        .b_in_data   (b_in_data),
        .b_in_valid  (b_in_valid),
        .b_in_ready  (b_in_ready),
        .out_data    (pm_out_data),
        .out_valid   (pm_out_valid),
        .out_last    (pm_out_last),
        .out_ready   (pm_out_ready)
    );

    // =========================================================================
    // 输出后处理：稀疏掩码（1 cycle delay）
    //
    // 双路径架构（Task #84 步骤 4）：
    //   路径 A — 元素级（block_sparse_en=0）：
    //     逐系数检测，|c| < threshold 或 (Q-c) < threshold 时置 0
    //     pm_out_ready = !post_valid || out_ready（原逻辑，无额外状态）
    //   路径 B — 块级（block_sparse_en=1）：
    //     B 深度缓冲 → max_abs 决策 → 整块保留或整块置 0
    //     FSM: S_COLLECT (采 B 拍) → S_OUTPUT (发 B 拍) → (循环 / S_DONE)
    //   两路径输出通过 filt_* 信号复用同一个 post 寄存器
    // =========================================================================
    logic [Q_WIDTH-1:0] post_data;
    logic               post_valid;
    logic               post_last;

    // 组合计算 q_val（用于 abs 计算）
    logic [Q_WIDTH-1:0] q_val_logic;
    assign q_val_logic = Q_VALUE;

    // 模式选择：近似模式使能 = use_approx_mult && threshold != 0
    wire approx_en = use_approx_mult && (sparsity_threshold != '0);

    // =========================================================================
    // 路径 A：元素级稀疏掩码（原有逻辑，仅在 !block_sparse_en 时生效）
    // =========================================================================
    wire [Q_WIDTH-1:0] elem_masked_data;
    assign elem_masked_data = approx_en ?
        ((pm_out_data < sparsity_threshold) ||
         ((q_val_logic - pm_out_data) < sparsity_threshold)) ? '0 :
        pm_out_data :
        pm_out_data;

    // =========================================================================
    // 路径 B：块级稀疏掩码（新增，仅在 block_sparse_en && approx_en 时生效）
    // =========================================================================
    localparam int NUM_BLOCKS = (B > 0) ? (N / B) : 1;
    localparam int LOG_B      = (B <= 2) ? 1 : $clog2(B);
    localparam int LOG_NB     = (NUM_BLOCKS <= 2) ? 1 : $clog2(NUM_BLOCKS);

    typedef enum logic [1:0] {S_BL_COLLECT, S_BL_OUTPUT, S_BL_DONE} bl_state_t;
    bl_state_t bl_state, bl_state_next;

    // B 深度数据缓冲（块内系数暂存）+ last flag 缓冲
    logic [Q_WIDTH-1:0] bl_data_buf [0:B-1];
    logic [B-1:0]       bl_last_buf;

    // 计数器
    logic [LOG_B-1:0]   bl_pos;         // 采集阶段块内位置
    logic [LOG_NB-1:0]  bl_block_idx;   // 当前块索引
    logic [LOG_B-1:0]   bl_out_cnt;     // 输出阶段计数

    // 块内最大绝对值 + 决策
    logic [Q_WIDTH-1:0] bl_max_abs;
    logic [Q_WIDTH-1:0] bl_curr_neg;
    logic [Q_WIDTH-1:0] bl_curr_abs;
    logic               bl_keep;

    // 对称模绝对值：min(pm_out_data, Q_VALUE - pm_out_data)
    assign bl_curr_neg = q_val_logic - pm_out_data;
    assign bl_curr_abs = (pm_out_data <= bl_curr_neg) ? pm_out_data : bl_curr_neg;
    // 块决策：max_abs >= threshold 则保留；不启用近似时全部保留
    assign bl_keep = approx_en ? (bl_max_abs >= sparsity_threshold) : 1'b1;

    // 块级握手信号
    wire bl_pm_ready      = (bl_state == S_BL_COLLECT);
    wire bl_filt_valid    = (bl_state == S_BL_OUTPUT);
    wire [Q_WIDTH-1:0] bl_filt_data = bl_keep ? bl_data_buf[bl_out_cnt] : '0;
    wire bl_filt_last     = bl_last_buf[bl_out_cnt];

    // 模式复用：元素级 vs 块级（提前声明，供 always_comb 使用）
    wire use_block_mode = approx_en && block_sparse_en;

    // 后级 post 缓冲的 ready（提前声明，供 always_comb 使用）
    wire post_ready = (!post_valid) || out_ready;

    // -------------------------------------------------------------------------
    // 组合下一状态
    // -------------------------------------------------------------------------
    always_comb begin
        bl_state_next = bl_state;
        case (bl_state)
            S_BL_COLLECT:
                if (pm_out_valid && bl_pm_ready && bl_pos == B-1)
                    bl_state_next = S_BL_OUTPUT;
            S_BL_OUTPUT:
                if (bl_filt_valid && post_ready && bl_out_cnt == B-1)
                    bl_state_next = ((bl_block_idx + 1'b1) == NUM_BLOCKS) ? S_BL_DONE : S_BL_COLLECT;
            S_BL_DONE:
                bl_state_next = S_BL_DONE;
            default:
                bl_state_next = S_BL_COLLECT;
        endcase
    end

    // -------------------------------------------------------------------------
    // 时序：FSM + 寄存器
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
    // LINT-L7: async reset: control registers (BRAM uses sync reset)
        if (!rst_n) begin
            bl_state     <= S_BL_COLLECT;
            bl_pos       <= '0;
            bl_block_idx <= '0;
            bl_out_cnt   <= '0;
            bl_max_abs   <= '0;
        end else if (start) begin
            bl_state     <= S_BL_COLLECT;
            bl_pos       <= '0;
            bl_block_idx <= '0;
            bl_out_cnt   <= '0;
            bl_max_abs   <= '0;
        end else begin
            bl_state <= bl_state_next;
            case (bl_state)
                S_BL_COLLECT: begin
                    if (pm_out_valid && bl_pm_ready && block_sparse_en && approx_en) begin
                        // 缓冲数据
                        bl_data_buf[bl_pos] <= pm_out_data;
                        bl_last_buf[bl_pos]  <= pm_out_last;
                        // 更新块内最大绝对值
                        if (bl_pos == '0)
                            bl_max_abs <= bl_curr_abs;
                        else if (bl_curr_abs > bl_max_abs)
                            bl_max_abs <= bl_curr_abs;
                        // 更新块内位置
                        if (bl_pos == B-1) begin
                            bl_pos     <= '0;
                            bl_out_cnt <= '0;
                        end else begin
                            bl_pos <= bl_pos + 1'b1;
                        end
                    end
                end
                S_BL_OUTPUT: begin
                    if (bl_filt_valid && post_ready && block_sparse_en && approx_en) begin
                        if (bl_out_cnt == B-1) begin
                            bl_out_cnt   <= '0;
                            bl_block_idx <= bl_block_idx + 1'b1;
                        end else begin
                            bl_out_cnt <= bl_out_cnt + 1'b1;
                        end
                    end
                end
                S_BL_DONE: ;
                default: ;
            endcase
        end
    end

    // pm_out_ready：块级用 bl_pm_ready；元素级/旁路用 post_ready
    assign pm_out_ready = use_block_mode ? bl_pm_ready : post_ready;

    // 后处理输入 MUX（filt_*）
    wire [Q_WIDTH-1:0] filt_data;
    wire               filt_valid;
    wire               filt_last;
    assign filt_data  = use_block_mode ? bl_filt_data     : elem_masked_data;
    assign filt_valid = use_block_mode ? bl_filt_valid    : pm_out_valid;
    assign filt_last  = use_block_mode ? bl_filt_last     : pm_out_last;

    // 输出寄存器（1 cycle 延迟）
    always_ff @(posedge clk or negedge rst_n) begin
    // LINT-L7: async reset: control registers (BRAM uses sync reset)
        if (!rst_n) begin
            post_data  <= '0;
            post_valid <= 1'b0;
            post_last  <= 1'b0;
        end else if (filt_valid && post_ready) begin
            post_data  <= filt_data;
            post_valid <= 1'b1;
            post_last  <= filt_last;
        end else if (post_valid && out_ready) begin
            post_valid <= 1'b0;
            post_last  <= 1'b0;
        end
    end

    assign out_data  = post_data;
    assign out_valid = post_valid;
    assign out_last  = post_last;

    // =========================================================================
    // 观测计数器（可选，供未来集成到 sparse_ntt_unit 的 skip_count 汇总）
    // =========================================================================
    // 输出侧跳过的计数：
    //   元素级：跳过的系数数
    //   块级 ：跳过的块数
    // LINT-L5: post_skip_cnt 16-bit: skip counter (max N=65536)
    logic [15:0] post_skip_cnt;

    // 块级 block_end 事件（用于块级 skip 计数）
    wire bl_block_end = (bl_state == S_BL_OUTPUT) && bl_filt_valid &&
                        post_ready && (bl_out_cnt == B-1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_skip_cnt <= 16'd0;
        end else if (start) begin
            post_skip_cnt <= 16'd0;
        end else if (use_block_mode) begin
            // 块级：每块结束时若跳过则计数
            if (bl_block_end && !bl_keep) begin
                post_skip_cnt <= post_skip_cnt + 16'd1;
            end
        end else if (approx_en &&
                     pm_out_valid && pm_out_ready &&
                     ((pm_out_data < sparsity_threshold) ||
                      ((q_val_logic - pm_out_data) < sparsity_threshold))) begin
            // 元素级：逐系数跳过时计数
            post_skip_cnt <= post_skip_cnt + 16'd1;
        end
    end

    // 保留 unused 信号提示综合器（避免 lint 警告）
    wire unused_trunc_bits = &{~trunc_bits, 1'b0};
    wire unused_post_skip  = &{~post_skip_cnt, 1'b0};

endmodule
