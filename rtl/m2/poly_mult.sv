//=============================================================================
// poly_mult.sv  —  多项式点乘加速器（密推芯 M2-c，玩具配置）
//
// 目标：
//   C(x) = A(x) * B(x) mod (x^N - 1, q)
//
// 架构：
//   单 ntt_unit 时分复用 3 次：
//     Phase A: 收 A 系数到 a_mem[N]
//     Phase B: 收 B 系数到 b_mem[N]
//     Phase NTT_A: a_mem → ntt_unit(op=NTT) → a_hat_mem
//     Phase NTT_B: b_mem → ntt_unit(op=NTT) → b_hat_mem
//     Phase MUL:   c_hat_mem[i] = a_hat_mem[i] * b_hat_mem[i] mod q
//     Phase INTT:  c_hat_mem → ntt_unit(op=INTT) → out_stream
//
//   注：ntt_unit 内部做 bit-reversal，NTT/INTT 均输入端做置换。
//       本模块不感知 bit-reversal，只喂/收系数并透传。
//
// 接口（AXI-Stream valid/ready，两个输入 + 一个输出）：
//   - a_in_*:  A 系数流
//   - b_in_*:  B 系数流
//   - out_*:   C 系数流（模 q，已含 INTT 的 N^-1 缩放）
//   - start:   单周期启动脉冲
//   - busy/done/error: 状态指示
//
// 时序：单次 poly_mult 约 (2*NTT + N 点乘 + INTT) 周期
//   N=16 时 NTT 约 230 cycles（M1 实测），INTT 类似；总 ~700 cycles 级。
//
// 依赖模块：
//   - ntt_unit (rtl/m1/ntt_unit.sv)   生产版 NTT/INTT 核
//
// 参数：
//   LOG_N   : log2(N)
//   Q_WIDTH : 系数位宽
//   Q_VALUE : 素数模
//   N_INV   : N^-1 mod Q（INTT 缩放用）
//
// 使用建议：
//   仿真验证：N=16, Q_WIDTH=7, Q_VALUE=113, N_INV=106
//   生产配置：N=2^14, Q_WIDTH=45, Q_VALUE=17592186175489, N_INV=17591112433657
//
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module poly_mult #(
    parameter int LOG_N   = 4,
    parameter int N       = 1 << LOG_N,
    parameter int Q_WIDTH = 7,
    parameter logic [Q_WIDTH-1:0] Q_VALUE = 113,
    // 2026-10-06 修复：原为 parameter int（32-bit signed），生产值
    //   17591112433657 被截成 -1073610759，传给 ntt_unit 后符号扩展成
    //   35183298478073 -> INTT 缩放系数错误。玩具 106 不触发该问题。
    parameter logic [Q_WIDTH-1:0] N_INV = 106,
    // 取模路径选择：
    //   USE_FASTRED=0（默认，玩具配置 N=16 q=113）：用组合逻辑 % Q_VALUE
    //   USE_FASTRED=1（生产配置 N=2^14 Q_WIDTH=45 Q_VALUE=2^44+c）：用 mod45_fastred
    //     —— 前提：Q_VALUE = 2^44 + c 且 c = 2^17+1 = 131073
    //     —— 生产配置必须传 USE_FASTRED=1，玩具配置必须 0
    parameter int USE_FASTRED = 0,
    // BRAM 路径选择（2026-10-06 新增，供 N=2^12 仿真回归使用）：
    //   默认 (N >= 2048) 走官方 blk_mem_gen IP（生产综合路径，Synth 8-2914 解除）
    //   显式传 0 时走 ntt_mem_tdp_prod 的自动推断分支（语义等价，无需 IP 仿真模型）
    parameter bit USE_BRAM_IP = (N >= 2048),
    // M-D': twiddle ROM init file ($readmemh, absolute path, cwd-independent)
    parameter string TW_FILE     = "rtl/m5/tw/tw_omega_p1_n16.hex",
    parameter string TW_INV_FILE = "rtl/m5/tw/tw_omegainv_p1_n16.hex"
) (
    input  wire logic               clk,
    input  wire logic               rst_n,

    // 控制
    input  wire logic               start,
    output logic                    busy,
    output logic                    done,
    output logic                    error,

    // A 输入流
    input  wire logic [Q_WIDTH-1:0] a_in_data,
    input  wire logic               a_in_valid,
    output logic                    a_in_ready,

    // B 输入流
    input  wire logic [Q_WIDTH-1:0] b_in_data,
    input  wire logic               b_in_valid,
    output logic                    b_in_ready,

    // C 输出流
    output logic [Q_WIDTH-1:0]      out_data,
    output logic                    out_valid,
    output logic                    out_last,
    input  wire logic               out_ready

);

    // =========================================================================
    // 内部 RAM
    // =========================================================================
    // 生产配置（N=2^14, Q_WIDTH=45）下这 5 个缓冲共 3.686 Mbit。
    //
    // a_hat_mem / b_hat_mem（Task #65，2026-10-06）：
    //   原实现为 reg 数组 + ram_style="block"，但 N=2^12 Q_WIDTH=45 时 Vivado
    //   报 [Synth 8-6849] Infeasible attribute，退回 LUTRAM（每个数组 ~3,840 LUT，
    //   两个实例 = 7,680 LUT，占顶层 LUT as Memory 6,656 的主要来源）。
    //   改为实例化 ckks_bram（简单双端口、1 写 + 1 同步读），读端直接驱动
    //   a_hat_r / b_hat_r（与原注册读行为逐拍等价：原 a_hat_r(T) = a_hat_mem[mul_rd_addr(T-1)]，
    //   新 a_hat_r(T) = mem[mul_rd_addr(T-1)]，二者完全一致，无需预取地址）。
    //   写使能 = state==S_NTT_A/B && ntt_phase==P_COLLECT && ntt_out_valid。
    //
    // a_mem / b_mem / c_hat_mem（Task #62，2026-10-06）：
    //   原实现三者在 FEED 阶段共用同一个读数据寄存器 ntt_in_data（三处分别
    //   赋值），Vivado 无法把一个读寄存器映射到 3 个 BRAM 的输出端口，故报
    //   [Synth 8-6849] Infeasible attribute ram_style="block"，退回 LUTRAM
    //   （N=2^12 实测每个数组约 2,880 LUT，3 个 x 2 实例 = 17,280 LUT）。
    //   改为实例化 ckks_bram（简单双端口、1 写 + 1 同步读），每个数组独占读
    //   数据寄存器 a_mem_r / b_mem_r / c_hat_r，并用「组合预取地址」吸收
    //   1 拍读延迟，逐拍行为与原组合读完全等价（见 u_ntt 实例后的 rd_addr 逻辑）。

    // ckks_bram 实例的读数据寄存器与组合预取地址
    logic [Q_WIDTH-1:0] a_mem_r, b_mem_r, c_hat_r;

    // =========================================================================
    // 顶层状态机
    // =========================================================================
    localparam S_IDLE    = 3'd0;
    localparam S_INPUT_A = 3'd1;
    localparam S_INPUT_B = 3'd2;
    localparam S_NTT_A   = 3'd3;   // 驱动 ntt_unit 做 NTT(A)
    localparam S_NTT_B   = 3'd4;   // 驱动 ntt_unit 做 NTT(B)
    localparam S_MUL     = 3'd5;   // 点乘

    localparam P_FEED    = 1'b0;
    localparam P_COLLECT = 1'b1;
    localparam S_INTT    = 3'd6;   // 驱动 ntt_unit 做 INTT(C_hat)
    localparam S_DONE    = 3'd7;

    logic [2:0] state;

    // 计数与地址
    logic [$clog2(N)-1:0]  a_in_idx;
    // BRAM 注册写地址（修复 xsim 跨模块 always_ff 求值顺序导致写地址错位 1 拍）
    logic [$clog2(N)-1:0]  a_wr_addr_r, b_wr_addr_r;
    logic [Q_WIDTH-1:0]    a_wr_data_r, b_wr_data_r;
    logic                  a_we_r, b_we_r;
    logic [$clog2(N)-1:0]  b_in_idx;
    logic [$clog2(N)-1:0]  ntt_feeder_idx;    // 从 *_mem 喂给 ntt_unit.in_data
    logic [$clog2(N)-1:0]  ntt_collector_idx; // 从 ntt_unit.out_data 收进 *_hat_mem
    logic [$clog2(N)-1:0]  mul_idx;
    logic [$clog2(N)-1:0]  mul_rd_addr; // S_MUL 读地址寄存器（BRAM 规范模板）
    logic [$clog2(N)-1:0]  intt_feeder_idx;
    logic [$clog2(N)-1:0]  out_stream_idx;

    // =========================================================================
    // S_INTT 输出 skid buffer（Task #86，2026-10-11）
    //   块级稀疏模式下 approx_poly_mult 在 S_BL_OUTPUT 阶段拉低 pm_out_ready，
    //   导致 poly_mult S_INTT COLLECT 外部 out_ready=0。原设计无输出捕获寄存器，
    //   ntt_unit 输出在 out_ready=0 时丢失。skid buffer 解耦 ntt_unit 输出
    //   与外部 out_ready：ntt_out_ready 恒 1（只要 skid 未满），out_valid
    //   由 skid 寄存器驱动，外部 out_ready=0 时数据暂存不丢失。
    //   深度 2：S_BL_OUTPUT 持续 B=2 拍，需至少 2 拍缓冲避免 skid 满溢。
    //
    //   Task #86 修复（2026-10-11）：ntt_unit 输出流水线未受 out_ready 门控，
    //   背压期间 REG1/REG2 继续推进产生 stale 数据。背压释放后 2 拍内 out_valid=1
    //   但数据仍为上一轮残留，skid 会捕获重复元素导致 ntt_collector_idx 跑飞。
    //   修复：skid_drain_cnt 2 级计数器，skid_full=1 时置 2，skid_full=0 时每拍减 1，
    //   仅 drain_cnt==0 时允许写入 skid，确保流水线排空后再捕获。
    // =========================================================================
    logic [Q_WIDTH-1:0] skid_data [0:1];
    logic               skid_valid [0:1];
    logic               skid_last [0:1];
    logic               skid_wr_en;
    logic               skid_rd_en;
    logic               skid_empty;
    logic               skid_full;
    logic               skid_has_data;
    logic [1:0]         skid_drain_cnt;

    // skid buffer 控制逻辑
    assign skid_empty = !skid_valid[0] && !skid_valid[1];
    assign skid_full  = skid_valid[0] && skid_valid[1];
    assign skid_has_data = !skid_empty;

    // =========================================================================
    // 点乘取模路径（USE_FASTRED 参数二选一）
    //   注意：wire 依赖 mul_idx，必须在 mul_idx 声明之后
    // =========================================================================
    // 点乘输入寄存器：由 ram_style=block 的 BRAM 同步读喂数。
    //   S_MUL 首拍预取 a_hat[0]/b_hat[0]（BRAM 输出寄存器，1 拍后有效）；
    //   此后每拍预取 mul_idx+1，使「第 k 拍写 c_hat_mem[k]」与改造前一一对应。
    logic [Q_WIDTH-1:0] a_hat_r, b_hat_r;
    logic               mul_primed;

    // =========================================================================
    // 1 级流水线（Task #66，2026-10-06）：乘法 → 取模 之间插寄存器
    //   关键路径：a_hat_r * b_hat_r（45×45=90 bit 乘法）→ mod45_fastred
    //   （纯组合，WNS -6.543 ns 不满足 100 MHz）。在二者之间加 prod_r 寄存器
    //   后，乘法与取模各占一级，预期 WNS 回正。
    //
    //   wr_addr_r / wr_en_r 与 prod_r 同拍延迟，保持写地址/使能/数据三者对齐。
    //   第 1 拍 wr_en_r=0（来自进入 S_MUL 前的 state!=S_MUL），自动跳过
    //   首拍的垃圾乘积，无需额外 valid 标志。
    // =========================================================================
    logic [2*Q_WIDTH-1:0] prod_r;     // 乘法输出寄存器
    logic [$clog2(N)-1:0]  wr_addr_r;  // 写地址延迟 1 拍
    logic                  wr_en_r;    // 写使能延迟 1 拍
    // E49（2026-10-25）：USE_FASTRED=1 时 mod45_fastred 内部加了一拍流水线
    //   （round-1 后插寄存器，劈开 30 级 CARRY8 关键路径），写数据因此延迟
    //   2 拍；写地址/写使能须同步再延 1 拍（wr_addr_r2 / wr_en_r2），
    //   使「第 k 拍写 c_hat_mem[k]」的逐拍语义不变。
    //   USE_FASTRED=0（玩具 % 路径）不经过 fastred，保持原 1 拍写延迟。
    logic [$clog2(N)-1:0]  wr_addr_r2; // 写地址再延迟 1 拍（仅 USE_FASTRED=1 使用）
    logic                  wr_en_r2;   // 写使能再延迟 1 拍（仅 USE_FASTRED=1 使用）

    // 完整乘积：45×45 = 90 bit（对 Q_WIDTH<45 的自然宽度为 2*Q_WIDTH bit）
    wire [2*Q_WIDTH-1:0] prod_full = prod_r;   // Task #66: 从流水线寄存器取

    // 玩具路径：纯组合 %（N=16 q=113，M1 全套已验证，功能正确性无争议）
    wire [Q_WIDTH-1:0] c_hat_pct = prod_full % Q_VALUE;

    // 生产路径：mod45_fastred（要求 Q_VALUE = 2^44 + 131073，Q_WIDTH = 45）
    //   把 2*Q_WIDTH 位乘积拼到 90 bit 送入 fast-red；对 Q_WIDTH=45 无 padding
    wire [90-1:0] prod_raw_90 =
        { {(90 - 2*Q_WIDTH){1'b0}}, prod_full };
    wire [44:0]   c_hat_fastred;
    // LINT-L5: c_hat_fastred 45-bit: Q_WIDTH output

    mod45_fastred #(
        .WIDTH   (45),
        .Q_VALUE (45'd17592186175489),
        .K       (44),
        .SHIFT   (90),
        // E49：生产路径在 round-1 后插一拍流水线，劈开 30 级 CARRY8 链；
        //   玩具配置（USE_FASTRED=0）不选通 fastred 输出，PIPE 无效
        .PIPE    (USE_FASTRED)
    ) u_fastred (
        .clk (clk),
        .x (prod_raw_90),
        .r (c_hat_fastred)
    );

    // 选通：USE_FASTRED=0 走 %；USE_FASTRED=1 走 fast-red
    //   注意：玩具配置 Q_WIDTH=7 时 fast-red 输出被截到 7 bit（数学上等价，
    //   因为 c_hat_fastred 对 q=113 不成立，所以 USE_FASTRED 必须与 Q_VALUE 匹配）
    wire [Q_WIDTH-1:0] c_hat_mod = USE_FASTRED ? c_hat_fastred[Q_WIDTH-1:0]
                                                : c_hat_pct;

    // E49（2026-10-25）：c_hat_mem 写端口地址/使能选通
    //   USE_FASTRED=1（fastred PIPE=1）：写数据延迟 2 拍 → 用 wr_addr_r2/wr_en_r2
    //   USE_FASTRED=0（玩具 % 路径）：写数据延迟 1 拍 → 用原 wr_addr_r/wr_en_r
    //   常数选择在综合时折叠，无额外 mux 开销
    wire [$clog2(N)-1:0] c_hat_waddr = USE_FASTRED ? wr_addr_r2 : wr_addr_r;
    wire                  c_hat_we    = USE_FASTRED ? wr_en_r2   : wr_en_r;

    // =========================================================================
    // ntt_unit 端口（本模块内部信号）
    // =========================================================================
    logic               ntt_start;
    logic               ntt_op_mode;
    logic               ntt_busy;
    logic               ntt_done;
    logic               ntt_error;

    logic [Q_WIDTH-1:0] ntt_in_data;
    logic               ntt_in_valid;
    logic               ntt_in_ready;

    logic [Q_WIDTH-1:0] ntt_out_data;
    logic               ntt_out_valid;
    logic              ntt_phase;   // 0=FEED, 1=COLLECT
    logic               ntt_out_last;
    // Task #86 修复（2026-10-11）：ntt_out_ready 改为组合信号，
    //   确保 ntt_unit 推进与 poly_mult 捕获严格同步（无 1 拍寄存器延迟）。
    //   S_INTT COLLECT 时跟随 out_ready（背压），S_NTT_A/B COLLECT 恒 1，其余 0。
    wire                ntt_out_ready;

    // =========================================================================
    // ntt_unit 实例
    // =========================================================================
    ntt_unit #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VALUE),
        .N_INV(N_INV),
        .USE_FASTRED(USE_FASTRED),
        .USE_BRAM_IP(USE_BRAM_IP),
        .TW_FILE(TW_FILE),
        .TW_INV_FILE(TW_INV_FILE)
    ) u_ntt (
        .clk(clk),
        .rst_n(rst_n),
        .start(ntt_start),
        .op_mode(ntt_op_mode),
        .busy(ntt_busy),
        .done(ntt_done),
        .error(ntt_error),
        .in_data(ntt_in_data),
        .in_valid(ntt_in_valid),
        .in_ready(ntt_in_ready),
        .out_data(ntt_out_data),
        .out_valid(ntt_out_valid),
        .out_last(ntt_out_last),
        .out_ready(ntt_out_ready)
    );

    // Task #86 修复（2026-10-11）：ntt_out_ready 组合驱动
    //   S_INTT COLLECT 时 = !skid_full（skid 未满才接受新数据），
    //   S_NTT_A/B COLLECT 恒 1（内部 BRAM 写入，无背压），
    //   其余状态 0。组合信号确保 ntt_unit 推进与 skid 捕获零延迟同步。
    assign ntt_out_ready =
        (state == S_INTT && ntt_phase == P_COLLECT) ? !skid_full :
        ((state == S_NTT_A || state == S_NTT_B) && ntt_phase == P_COLLECT) ? 1'b1 :
        1'b0;

    // =========================================================================
    // Task #62：a_mem / b_mem / c_hat_mem 的 ckks_bram 实例 + 组合预取地址
    //   预取规则（组合地址，非寄存器）：
    //     rd_addr(T) = feeder_idx(T) + (ntt_in_ready(T) ? 1 : 0)
    //   由寄存器更新律 feeder_idx(T) = feeder_idx(T-1) + ready(T-1) 得
    //     rd_addr(T-1) = feeder_idx(T-1) + ready(T-1) = feeder_idx(T)
    //   于是 ntt_in_data(T) = rdata(T-1) = mem[feeder_idx(T-1)]，
    //     与原组合读 ntt_in_data <= mem[feeder_idx] 逐拍严格等价。
    //   状态进入首拍 feeder_idx=0 且 ready=0 -> rd_addr=0 -> 首字 mem[0] 对齐。
    //   反压停在 N-1 时 rd_addr 钳位 N-1，重读末字；真正的 N 只会出现在
    //   phase 已切换之后，数据不被使用。
    //   注意：地址必须用组合线实现。若改用寄存器存预取地址，会再多一级
    //   延迟（mem[feeder(T-2)]），输入流错位 1 拍，NTT 全毁（已实测失败）。
    // =========================================================================
    wire [LOG_N-1:0] a_rd_addr = (state == S_NTT_A) ?
        ((ntt_feeder_idx >= N-1) ? (N-1) : (ntt_feeder_idx + (ntt_in_ready ? 1'b1 : 1'b0))) : '0;
    wire [LOG_N-1:0] b_rd_addr = (state == S_NTT_B) ?
        ((ntt_feeder_idx >= N-1) ? (N-1) : (ntt_feeder_idx + (ntt_in_ready ? 1'b1 : 1'b0))) : '0;
    wire [LOG_N-1:0] c_rd_addr = (state == S_INTT) ?
        ((intt_feeder_idx >= N-1) ? (N-1) : (intt_feeder_idx + (ntt_in_ready ? 1'b1 : 1'b0))) : '0;

    // Task #84 Step 4：BRAM 写地址/写使能/写数据全部由寄存器捕获，
    //   彻底消除 xsim 跨模块 always_ff 求值顺序导致 waddr 看到 FSM
    //   新值（错位 1 拍）的问题。捕获发生在 FSM 主 always_ff 内，
    //   与 a_in_idx 的递增共享同一 pre-edge 值，语义正确。
    ckks_bram #(.AW(LOG_N), .DW(Q_WIDTH)) u_a_mem (
        .clk(clk),
        .we(a_we_r),
        .waddr(a_wr_addr_r),
        .wdata(a_wr_data_r),
        .raddr(a_rd_addr),
        .rdata(a_mem_r)
    );

    ckks_bram #(.AW(LOG_N), .DW(Q_WIDTH)) u_b_mem (
        .clk(clk),
        .we(b_we_r),
        .waddr(b_wr_addr_r),
        .wdata(b_wr_data_r),
        .raddr(b_rd_addr),
        .rdata(b_mem_r)
    );

    ckks_bram #(.AW(LOG_N), .DW(Q_WIDTH)) u_c_hat_mem (
        .clk(clk),
        // E49：USE_FASTRED=1 时写数据多 1 拍 fastred 流水线延迟，
        //   地址/使能用二级延迟对齐；玩具路径保持原一级延迟
        .we(c_hat_we),
        .waddr(c_hat_waddr),
        .wdata(c_hat_mod),
        .raddr(c_rd_addr),
        .rdata(c_hat_r)
    );

    // NTT(A) 输出缓冲：S_NTT_A COLLECT 写入，S_MUL 读出到 a_hat_r
    ckks_bram #(.AW(LOG_N), .DW(Q_WIDTH)) u_a_hat_mem (
        .clk(clk),
        .we(state == S_NTT_A && ntt_phase == P_COLLECT && ntt_out_valid),
        .waddr(ntt_collector_idx),
        .wdata(ntt_out_data),
        .raddr(mul_rd_addr),
        .rdata(a_hat_r)
    );

    // NTT(B) 输出缓冲：S_NTT_B COLLECT 写入，S_MUL 读出到 b_hat_r
    ckks_bram #(.AW(LOG_N), .DW(Q_WIDTH)) u_b_hat_mem (
        .clk(clk),
        .we(state == S_NTT_B && ntt_phase == P_COLLECT && ntt_out_valid),
        .waddr(ntt_collector_idx),
        .wdata(ntt_out_data),
        .raddr(mul_rd_addr),
        .rdata(b_hat_r)
    );

    // =========================================================================
    // 状态机主逻辑
    //   设计要点：
    //   - 每个 S_NTT_*/S_INTT 状态下分两个子阶段：FEED / COLLECT
    //   - FEED 阶段：ntt_feeder_idx 从 *_mem 逐系数喂给 ntt_unit.in_data
    //   - COLLECT 阶段：ntt_collector_idx 从 ntt_unit.out_data 收进 *_hat_mem
    //     （ntt_unit 的 out 流式输出，一次一个，共 N 个）
    //   - 子状态用 2-bit 位区分
    // =========================================================================


    // 子状态用于 S_MUL 结束判断
    // 复用同一 always_ff 块，通过 ntt_phase 区分

    // =========================================================================
    // S_MUL 读地址计数器
    //   目的：让 *_hat_mem 的读地址是一个「纯寄存器」，满足 Vivado BRAM 推断模板。
    //   在 S_MUL 期间自由递增，离开 S_MUL 时归零（保证进入 S_MUL 首拍地址 = 0）。
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mul_rd_addr <= '0;
        end else if (state == S_MUL) begin
            mul_rd_addr <= (mul_rd_addr == N - 1) ? '0 : (mul_rd_addr + 1'b1);
        end else begin
            mul_rd_addr <= '0;
        end
    end

    // =========================================================================
    // 主 always_ff
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            prod_r           <= '0;
            wr_addr_r        <= '0;
            wr_en_r          <= 1'b0;
            // E49：二级写延迟寄存器复位
            wr_addr_r2       <= '0;
            wr_en_r2         <= 1'b0;
            a_in_idx         <= '0;
            b_in_idx         <= '0;
            ntt_feeder_idx   <= '0;
            ntt_collector_idx<= '0;
            mul_idx          <= '0;
            intt_feeder_idx  <= '0;
            out_stream_idx   <= '0;
            ntt_phase        <= P_FEED;
            // Task #86: skid buffer 复位（2-deep）+ 排空计数器
            skid_data[0]     <= '0;
            skid_data[1]     <= '0;
            skid_valid[0]    <= 1'b0;
            skid_valid[1]    <= 1'b0;
            skid_last[0]     <= 1'b0;
            skid_last[1]     <= 1'b0;
            skid_drain_cnt   <= 2'd0;

            ntt_start        <= 1'b0;
            ntt_op_mode      <= 1'b0;
            ntt_in_valid     <= 1'b0;
            ntt_in_data      <= '0;

            // Task #84 Step 4：BRAM 写寄存器复位
            a_wr_addr_r      <= '0;
            b_wr_addr_r      <= '0;
            a_wr_data_r      <= '0;
            b_wr_data_r      <= '0;
            a_we_r           <= 1'b0;
            b_we_r           <= 1'b0;

            a_in_ready       <= 1'b0;
            b_in_ready       <= 1'b0;
            out_valid        <= 1'b0;
            out_last         <= 1'b0;
            out_data         <= '0;

            busy             <= 1'b0;
            done             <= 1'b0;
            error            <= 1'b0;
        end else begin
            // ---- 流水线寄存器（Task #66，每拍更新）----
            prod_r    <= a_hat_r * b_hat_r;
            wr_addr_r <= mul_idx;
            wr_en_r   <= (state == S_MUL && mul_primed);
            // ---- E49 二级延迟（仅 USE_FASTRED=1 写路径使用）----
            wr_addr_r2 <= wr_addr_r;
            wr_en_r2   <= wr_en_r;
            // ----------------------------------------
            // 单周期脉冲默认清零
            ntt_start    <= 1'b0;
            a_in_ready   <= 1'b0;
            b_in_ready   <= 1'b0;
            out_valid    <= 1'b0;
            out_last     <= 1'b0;
            ntt_in_valid <= 1'b0;
            done         <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy  <= 1'b0;
                    error <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        a_in_idx     <= '0;
                        b_in_idx     <= '0;
                        ntt_feeder_idx<= '0;
                        ntt_collector_idx <= '0;
                        mul_idx      <= '0;
                        intt_feeder_idx <= '0;
                        out_stream_idx  <= '0;
                        ntt_phase    <= P_FEED;
                        ntt_op_mode  <= 1'b0;
                        mul_primed   <= 1'b0;
                        state        <= S_INPUT_A;
                    end
                end

                // ---------------------------------------------------------
                // 收 A 系数到 a_mem
                // ---------------------------------------------------------
                S_INPUT_A: begin
                    a_in_ready <= 1'b1;
                    if (a_in_valid && a_in_ready) begin
                        // Task #84 Step 4：捕获写参数到寄存器，供 u_a_mem 下一拍写入
                        //   a_wr_addr_r/a_wr_data_r/a_we_r 与 a_in_idx 递增共享
                        //   同一 pre-edge 值（同一 always_ff 内 NBA），语义正确。
                        a_wr_addr_r <= a_in_idx;
                        a_wr_data_r <= a_in_data;
                        a_we_r      <= 1'b1;
                        a_in_idx    <= a_in_idx + 1'b1;
                        if (a_in_idx == N - 1) begin
                            a_in_ready <= 1'b0;
                            b_in_idx   <= '0;
                            state      <= S_INPUT_B;
                        end
                    end else begin
                        a_we_r <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                // 收 B 系数到 b_mem
                // ---------------------------------------------------------
                S_INPUT_B: begin
                    b_in_ready <= 1'b1;
                    if (b_in_valid && b_in_ready) begin
                        b_wr_addr_r <= b_in_idx;
                        b_wr_data_r <= b_in_data;
                        b_we_r      <= 1'b1;
                        b_in_idx    <= b_in_idx + 1'b1;
                        if (b_in_idx == N - 1) begin
                            b_in_ready       <= 1'b0;
                            ntt_feeder_idx   <= '0;
                            ntt_collector_idx<= '0;
                            ntt_phase        <= P_FEED;
                            ntt_op_mode      <= 1'b0;   // NTT
                            ntt_start        <= 1'b1;
                            state            <= S_NTT_A;
                        end
                    end else begin
                        b_we_r <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                // NTT(A) — 单 ntt_unit 内部自己完成整个变换
                //   本模块任务：FEED (供数 N 个) + COLLECT (收数 N 个)
                // ---------------------------------------------------------
                S_NTT_A: begin
                    if (ntt_phase == P_FEED) begin
                        // 从 a_mem 逐系数喂给 ntt_unit
                        if (ntt_in_ready) begin
                            ntt_in_valid <= 1'b1;
                            ntt_in_data  <= a_mem_r;          // Task #62: BRAM 同步读
                            ntt_feeder_idx <= ntt_feeder_idx + 1'b1;
                            // 最后一个：本拍发出后转 COLLECT
                            if (ntt_feeder_idx == N - 1) begin
                                ntt_phase         <= P_COLLECT;
                                ntt_collector_idx <= '0;
                            end
                        end
                    end else begin
                        // COLLECT: 收 A_hat 到 a_hat_mem
                        if (ntt_out_valid) begin
                            ntt_collector_idx <= ntt_collector_idx + 1'b1;
                            if (ntt_collector_idx == N - 1) begin
                                ntt_feeder_idx    <= '0;
                                ntt_collector_idx <= '0;
                                ntt_phase         <= P_FEED;
                                ntt_op_mode       <= 1'b0;   // NTT
                                ntt_start         <= 1'b1;
                                state             <= S_NTT_B;
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                // NTT(B) — 同上
                // ---------------------------------------------------------
                S_NTT_B: begin
                    if (ntt_phase == P_FEED) begin
                        if (ntt_in_ready) begin
                            ntt_in_valid <= 1'b1;
                            ntt_in_data  <= b_mem_r;          // Task #62: BRAM 同步读
                            ntt_feeder_idx <= ntt_feeder_idx + 1'b1;
                            if (ntt_feeder_idx == N - 1) begin
                                ntt_phase         <= P_COLLECT;
                                ntt_collector_idx <= '0;
                            end
                        end
                    end else begin
                        // COLLECT: 收 B_hat 到 b_hat_mem
                        if (ntt_out_valid) begin
                            ntt_collector_idx <= ntt_collector_idx + 1'b1;
                            if (ntt_collector_idx == N - 1) begin
                                mul_idx         <= '0;
                                state           <= S_MUL;
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                // 点乘：C_hat[i] = A_hat[i] * B_hat[i] mod q
                //   取模路径由 USE_FASTRED 参数在模块级 wire c_hat_mod 已选通：
                //     USE_FASTRED=0：玩具配置 N=16 q=113，用 % Q_VALUE
                //     USE_FASTRED=1：生产配置 N=2^14 Q_WIDTH=45 q=2^44+c，
                //                    用 mod45_fastred（0 DSP 纯组合归约）
                // ---------------------------------------------------------
                S_MUL: begin
                    // 读由 u_a_hat_mem / u_b_hat_mem 的 BRAM 同步读驱动
                    //  （rdata 直连 a_hat_r / b_hat_r，与原注册读逐拍等价）
                    if (!mul_primed) begin
                        // 预取拍：BRAM 同步读，a_hat_r/b_hat_r 到下一拍才有效
                        mul_primed <= 1'b1;
                        mul_idx    <= '0;
                    end else begin
                        // 写由 u_c_hat_mem.we 完成（wr_en_r，Task #66 流水线延迟 1 拍）
                        if (mul_idx == N - 1) begin
                            mul_idx           <= '0;
                            intt_feeder_idx   <= '0;
                            ntt_collector_idx <= '0;
                            ntt_phase         <= P_FEED;
                            ntt_op_mode       <= 1'b1;   // INTT
                            ntt_start         <= 1'b1;
                            state             <= S_INTT;
                        end else begin
                            mul_idx <= mul_idx + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // INTT(C_hat) — FEED + COLLECT，COLLECT 阶段直接外流输出
                // ---------------------------------------------------------
                S_INTT: begin
                    if (ntt_phase == P_FEED) begin
                        if (ntt_in_ready) begin
                            ntt_in_valid <= 1'b1;
                            ntt_in_data  <= c_hat_r;           // Task #62: BRAM 同步读
                            intt_feeder_idx <= intt_feeder_idx + 1'b1;
                            if (intt_feeder_idx == N - 1) begin
                                ntt_phase          <= P_COLLECT;
                                ntt_collector_idx  <= '0;
                                out_stream_idx     <= '0;
                            end
                        end
                    end else begin
                        // COLLECT + 2-deep skid buffer（Task #86，2026-10-11）
                        // ntt_out_ready = !skid_full（组合），此处处理 skid 写入/读出。
                        // 写入：ntt_unit 有数据且 skid 未满
                        if (ntt_out_valid && !skid_full) begin
                            if (!skid_valid[0]) begin
                                skid_data[0]  <= ntt_out_data;
                                skid_valid[0] <= 1'b1;
                                skid_last[0]  <= (ntt_collector_idx == N - 1);
                            end else begin
                                skid_data[1]  <= ntt_out_data;
                                skid_valid[1] <= 1'b1;
                                skid_last[1]  <= (ntt_collector_idx == N - 1);
                            end
                            ntt_collector_idx <= ntt_collector_idx + 1'b1;
                        end
                        // 读出：skid 有数据且外部 ready
                        if (skid_has_data && out_ready) begin
                            if (skid_valid[0]) begin
                                out_data  <= skid_data[0];
                                out_valid <= 1'b1;
                                out_last  <= skid_last[0];
                                skid_valid[0] <= 1'b0;
                                // S_DONE：最后一个元素转发完毕
                                if (skid_last[0]) state <= S_DONE;
                            end else begin
                                out_data  <= skid_data[1];
                                out_valid <= 1'b1;
                                out_last  <= skid_last[1];
                                skid_valid[1] <= 1'b0;
                                if (skid_last[1]) state <= S_DONE;
                            end
                        end else begin
                            // Task #86 修复（2026-10-11）：清零 out_valid，防止 phantom 数据
                            // 原代码无 else 分支，out_valid 保持 1，块级 FSM 持续捕获重复数据
                            out_valid <= 1'b0;
                        end
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: begin
                    error <= 1'b1;
                    state <= S_IDLE;
                end
            endcase

            // error 透传
            if (ntt_error) error <= 1'b1;
        end
    end

    // =========================================================================
    // out_ready 默认拉高（在 S_INTT COLLECT 状态外，ntt_out_ready 会保持 0）
    // 这里 out_ready 是外部输入端口，无需内部赋值
    // =========================================================================

endmodule

`default_nettype wire
