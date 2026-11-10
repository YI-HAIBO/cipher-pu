//=============================================================================
// ntt_unit.sv  —  参数化 NTT/INTT 核（密推芯 M1 Phase 3，生产版，素数模）
//
// 架构：
//   - 状态机：IDLE -> INPUT -> COMPUTE (LOG_N 级) -> OUTPUT -> DONE
//   - 寄存器文件：N 个 Q_WIDTH 位系数
//   - LOG_N 级顺序蝴蝶计算（每级 N/2 次蝴蝶）
//   - 蝴蝶子状态机：ISSUE -> WAIT -> WRITEBACK（两拍，1W2R 串行回写）
//
// NTT 算法（Cooley-Tukey DIT，Phase 3 已对齐验证版公式）：
//   Stage s (0..LOG_N-1):
//     stride = 2^s                          // 1, 2, 4, ..., N/2（递增）
//     Butterfly j (0..N/2-1):
//       group     = j / stride
//       offset    = j % stride
//       a_addr    = group * (2*stride) + offset
//       b_addr    = a_addr + stride
//       twiddle_exp = offset * (N / (2*stride))    // 逐 stage 递减步长
//   输入端需 bit-reversal 置换（DIT 结构要求）
//
// INTT（op_mode=1）：
//   - 输入端同样 bit-reversal 置换
//   - 蝴蝶用 (omega^-1)^k 表（omega_inv_table）
//   - 输出前乘 N^-1 完成缩放（N_INV = N^-1 mod q）
//
// 时序：
//   - 蝴蝶 2-cycle 延迟（乘法器 1 cycle + 输出寄存 1 cycle）
//   - ISSUE: 读取 mem, 检查 bf_ready, 触发蝴蝶
//   - WAIT:  wait_cnt 从 2 递减（2 -> 1 -> 0）
//   - WRITEBACK: 捕获 bf_a_out/bf_b_out, 写回 mem
//
// 接口：AXI-Stream 风格 valid/ready 流式 I/O
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module ntt_unit #(
    parameter int LOG_N   = 4,          // N = 2^LOG_N
    parameter int N       = 1 << LOG_N,
    parameter int Q_WIDTH = 43,         // CKKS 中间层常用 43~60 bit
    parameter logic [Q_WIDTH-1:0] Q_VALUE = '0,  // 素数模数（必须 2^LOG_N | Q_VALUE - 1）
    parameter logic [Q_WIDTH-1:0] N_INV   = 1,          // N^-1 mod Q_VALUE（INTT 输出缩放）
    parameter bit USE_FASTRED = 0,      // 1 = 蝴蝶走 fast-red（要求 Q_WIDTH=45 且 q=2^44+c）
    // 1 = 系数存储器走官方 blk_mem_gen IP（生产 N>=2048，避免 Synth 8-2914）
    // 0 = 系数存储器走自动推断（玩具 N<=1024，仿真回归不变）
    parameter bit USE_BRAM_IP = (N >= 2048),
    // M-D': twiddle ROM init file ($readmemh, absolute path, cwd-independent)
    parameter string TW_FILE     = "rtl/m5/tw/tw_omega_p1_n16.hex",
    parameter string TW_INV_FILE = "rtl/m5/tw/tw_omegainv_p1_n16.hex"
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    // 控制
    input  wire logic              start,
    input  wire logic              op_mode,      // 0=NTT, 1=INTT
    output logic              busy,
    output logic              done,
    output logic              error,

    // 输入流
    input  wire logic [Q_WIDTH-1:0] in_data,
    input  wire logic              in_valid,
    output logic              in_ready,

    // 输出流
    output logic [Q_WIDTH-1:0] out_data,
    output logic              out_valid,
    output logic              out_last,
    input  wire logic              out_ready

);

    // =========================================================================
    // 寄存器文件
    // =========================================================================
    // BRAM 友好写法：写操作收敛到 2 个独立 always_ff，使 Vivado 能推断
    // true-dual-port block RAM，而不是把 N × Q_WIDTH bit 溶解成寄存器。
    // 原实现在单一 always_ff 内有 3 处写（S_INPUT 1 处 + C_WRITEBACK 2 处），
    // Vivado 报 Synth 8-4767 / 8-13159，生产规模（N=2^14, Q_WIDTH=45）下
    // 737280 bit 被溶解成寄存器 → 综合内存峰值 33.7 GB 且无法收敛。
    // 注：不强制 ram_style="block"——实测 Vivado 2026.1 在本设计（原 2 写 + 3 读）
    // 下判定 block 不可行并退回 LUTRAM，反而触发 Synth 8-2914。交由工具自选。
    // 【E39b 2026-11-08】系数存储器收敛为 1 写 + 2 读（1W2R）：蝶形两输出
    // 分两拍经唯一写口写入（C_WRITEBACK / C_WRITEBACK_B），从结构上消除
    // Vivado 多端口 RAM 仿真的跨端口写不可见分歧。
    // 系数存储器改由 ntt_mem_tdp（TDP BRAM 模板）承担，核内不再直接声明数组。
    // 原因与实测依据见 rtl/m1/ntt_mem_tdp.sv 头部注释。
    logic [Q_WIDTH-1:0] mem_rd_a, mem_rd_b;   // RAM 同步读输出（1 拍延迟）

    // =========================================================================
    // M-D': twiddle ROM（$readmemh 同步读，替代原 input 数组组合 mux）
    //   原 omega_table[twiddle_exp_calc] 是 N/2:1 组合 mux（N=16384 时 ~185K LUT/实例），
    //   占 poly_mult_rns LUT ~93%。移入 block ROM 同步读后坍缩。
    //   1 拍读延迟：地址 C_ISSUE 呈现 -> 数据 C_RD_DLY 末有效 -> C_LATCH 采样。
    // =========================================================================
    (* ram_style = "block" *) logic [Q_WIDTH-1:0] tw_rom     [0:N/2-1];
    (* ram_style = "block" *) logic [Q_WIDTH-1:0] tw_inv_rom [0:N/2-1];
    logic [Q_WIDTH-1:0] tw_rom_rd, tw_inv_rom_rd;
    initial begin
        $readmemh(TW_FILE,     tw_rom);
        $readmemh(TW_INV_FILE, tw_inv_rom);
    end

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam S_IDLE    = 4'd0;
    localparam S_INPUT   = 4'd1;
    localparam S_COMPUTE = 4'd2;
    localparam S_OUTPUT  = 4'd3;
    localparam S_OUT_PRE = 4'd6;     // 输出预读拍（同步读流水，BRAM 推断所需）
    localparam S_DONE    = 4'd4;
    localparam S_ERROR   = 4'd5;

    logic [3:0] state;

    // 输出路径直接取 RAM 读端口 A 的同步读结果

    // 计数器
    logic [$clog2(N)-1:0] coeff_idx;
    logic [$clog2(LOG_N+1)-1:0] stage_idx;
    logic [$clog2(N/2)-1:0] bf_idx;

    // 蝴蝶地址
    logic [$clog2(N)-1:0] bf_addr_a, bf_addr_b;
    logic [$clog2(N/2)-1:0] twiddle_exp;

    // 子状态机（COMPUTE 内）
    // 【2026-10-18 修复（任务 3）】C_RD_DLY 空拍的必要性：
    //   系数存储器 ntt_mem_tdp_prod 的读路径是 2 级流水（读地址寄存 raa_r
    //   + 输出寄存 rda），即「地址在周期 C 呈现 -> 数据在周期 C+2 可用」。
    //   原实现在 C_ISSUE 呈现地址后只经 1 拍就进 C_LATCH 采样，采到的是
    //   上一个蝴蝶地址的数据（mem[A_{j-1}] 而非 mem[A_j]），整个 NTT 逐
    //   蝴蝶错位。C_ISSUE 与 C_LATCH 之间插入 C_RD_DLY 空拍后，地址在
    //   ISSUE 呈现、数据在 LATCH 周期恰好有效（实测 N=8 逐位匹配期望 DFT，
    //   见 scripts/_ntt_n8_h1_model.py 的 H1 模型复现）。
    //   注意：输出通路（S_OUT_PRE + out_rd_addr 超前 + 2 级缩放流水）本身
    //   就按 2 拍读延迟设计，不受本修复影响。
    localparam C_ISSUE     = 3'd0;
    localparam C_RD_DLY    = 3'd1;   // 读地址 -> 读数据的 1 拍等待（2 级 RAM 流水）
    localparam C_LATCH     = 3'd2;   // 取 RAM 读数据并驱动蝴蝶输入
    localparam C_WAIT      = 3'd3;
    localparam C_WRITEBACK   = 3'd4;  // 1W2R 回写拍 1：bf_a_out -> bf_addr_a
    localparam C_WRITEBACK_B = 3'd5;  // 1W2R 回写拍 2：bf_b_out -> bf_addr_b

    logic [2:0] comp_state;
    logic [1:0] wait_cnt;

    // =========================================================================
    // Bit-reversal 函数（Cooley-Tukey DIT 输入端置换）
    // =========================================================================
    function automatic logic [$clog2(N)-1:0] bit_reverse(input logic [$clog2(N)-1:0] x);
        automatic logic [$clog2(N)-1:0] y;
        for (int b = 0; b < LOG_N; b = b + 1) begin
            y[LOG_N - 1 - b] = x[b];
        end
        return y;
    endfunction

    // =========================================================================
    // 写端口 / 读端口信号声明
    // -------------------------------------------------------------------------
    // 写端口收敛用 assign-only mux（实测 always_comb+if/else 会导致 Vivado 2026.1
    // 报 Synth 8-2914 无法推断 BRAM——见 ram_unit_like.sv L1/L2/L3 全 8-2914，
    // 而 ram_mux_probe.sv u6 的 assign+sel?x:y mux 成功识别为 true dual port）。
    // 语义等价：原 FSM 内 mem[...] <= ... 由 state/comp_state 决定；改用
    // assign-only mux 选出写使能/地址/数据，逐拍等价，不引入额外延迟。
    //
    // 【E39b 1W2R】唯一写口：S_INPUT 装载写、C_WRITEBACK（A 输出）与
    // C_WRITEBACK_B（B 输出）三类写源互斥，蝶形双回写串行化为两拍。
    //
    // 只声明不赋值：实际的 assign 与 u_mem 例化放在文件后部（地址计算之后），
    // 因为它们引用 bf_a_out / a_addr_calc 等后部才声明的信号，
    // SystemVerilog 不允许对变量的前向引用。
    // =========================================================================
    logic                 mem_we_a;
    logic [$clog2(N)-1:0] mem_wa_a;
    logic [Q_WIDTH-1:0]   mem_wd_a;

    // 读端口地址（同样只声明，赋值见文件后部）
    wire [$clog2(N)-1:0] out_rd_addr;
    wire [$clog2(N)-1:0] rd_addr_a;

    // =========================================================================
    // 蝴蝶单元实例（生产版，Horner4 乘法器 + 素数模）
    // =========================================================================
    logic [Q_WIDTH-1:0] bf_a_in, bf_b_in, bf_omega_in;
    logic [Q_WIDTH-1:0] bf_a_out, bf_b_out;
    logic               bf_valid, bf_ready, bf_m_valid;

    // Horner 分解段：HI_W <= 24（DSP48E1 容量），其余给 LO_W
    localparam int BF_HI_W = (Q_WIDTH > 24) ? 24 : (Q_WIDTH - 1);
    localparam int BF_LO_W = Q_WIDTH - BF_HI_W;

    ntt_butterfly #(
        .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(Q_VALUE),
        .HI_W(BF_HI_W),
        .LO_W(BF_LO_W),
        .INVERSE(0),
        .USE_FASTRED(USE_FASTRED)
    ) u_butterfly (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(bf_valid),
        .s_a(bf_a_in),
        .s_b(bf_b_in),
        .s_omega(bf_omega_in),
        .s_ready(bf_ready),
        .m_valid(bf_m_valid),
        .m_a(bf_a_out),
        .m_b(bf_b_out),
        .m_ready(1'b1)
    );

    // =========================================================================
    // 地址计算（Cooley-Tukey DIT，Phase 3 已对齐验证版）
    //   Stage s: stride = 2^s，每组 2*stride 个元素
    //   第 j 个蝴蝶: a = group*2*stride + offset, b = a + stride
    //   twiddle = root^(offset * N/(2*stride))
    // =========================================================================
    wire [$clog2(N)-1:0]   stride         = 1 << stage_idx;              // 1, 2, 4, ..., N/2
    wire [$clog2(N/2)-1:0] bf_idx_div     = bf_idx / stride;             // 组号
    wire [$clog2(N/2)-1:0] bf_idx_mod     = bf_idx % stride;             // 组内位置
    wire [$clog2(N)-1:0]   a_addr_calc    = bf_idx_div * (2*stride) + bf_idx_mod;
    wire [$clog2(N)-1:0]   b_addr_calc    = a_addr_calc + stride;

    // -------------------------------------------------------------------------
    // 2026-10-06（Task #65）：twiddle_exp_calc 移位重写 —— 消除 N=2^12 关键路径
    //
    // 原式：twiddle_exp = bf_idx_mod * (N / (2*stride))
    //   因 stride = 2^stage_idx 且 N = 2^LOG_N：
    //     N / (2*stride) = 2^(LOG_N-1-stage_idx)
    //     bf_idx % stride = bf_idx 的低 stage_idx 位
    //   ⇒ twiddle_exp = (bf_idx[stage_idx-1:0]) << (LOG_N-1-stage_idx)
    //
    // 原写法是两个「变量 × 变量」乘积，综合器实现成 24 级 CARRY8 + LUT 链。
    // 实测关键路径（approx_poly_mult @ N=2^12, xcau25p）：
    //   stage_idx_reg → twiddle_exp_calc_i_* → omega_table 读 mux
    //   → 蝴蝶乘法器 DSP 输入，14.094 ns / 51 级逻辑 / WNS -4.462 ns @100 MHz
    // 移位重写后该段退化为「按 stage 选通的常数移位」（纯连线 + 1 级 mux），
    // 逻辑层数大幅下降；逐拍语义与原式在所有 stage_idx/bf_idx 组合下逐位等价。
    // -------------------------------------------------------------------------
    wire [$clog2(N/2)-1:0] twiddle_exp_calc_w [0:LOG_N-1];
    genvar gs;
    generate
        for (gs = 0; gs < LOG_N; gs = gs + 1) begin : gen_tw
            if (gs == 0) begin : g_s0
                // stage 0：bf_idx % 1 = 0 → twiddle 恒为 0
                assign twiddle_exp_calc_w[0] = '0;
            end else begin : g_sk
                assign twiddle_exp_calc_w[gs] =
                    {bf_idx[gs-1:0], {(LOG_N-1-gs){1'b0}}};
            end
        end
    endgenerate
    wire [$clog2(N/2)-1:0] twiddle_exp_calc = twiddle_exp_calc_w[stage_idx];

    // M-D': twiddle ROM 同步读（1 拍），地址 = twiddle_exp_calc（C_ISSUE 稳定）
    always_ff @(posedge clk) begin
        tw_rom_rd     <= tw_rom[twiddle_exp_calc];
        tw_inv_rom_rd <= tw_inv_rom[twiddle_exp_calc];
    end

    // =========================================================================
    // 写端口 assign（此时 bf_a_out / bf_addr_* / a_addr_calc 均已声明）
    // -------------------------------------------------------------------------
    // 1W2R：唯一写口，三类互斥写源。C_WRITEBACK/C_WRITEBACK_B 为蝶形双回写
    // 的串行化两拍：拍 1 写 bf_addr_a/bf_a_out，拍 2 写 bf_addr_b/bf_b_out。
    // =========================================================================
    wire wr_src_input = (state == S_INPUT) && in_valid && in_ready;
    wire wr_src_wb    = (state == S_COMPUTE) &&
                        ((comp_state == C_WRITEBACK) ||
                         (comp_state == C_WRITEBACK_B));
    wire wr_sel_wb_b  = (state == S_COMPUTE) && (comp_state == C_WRITEBACK_B);

    // 输入端 bit-reversal 地址（预计算 wire，供 mux 复用）
    wire [$clog2(N)-1:0] coeff_bitrev = bit_reverse(coeff_idx);

    // 唯一写口：写源/地址/数据全部 assign-only mux（BRAM 推断友好）
    assign mem_we_a = wr_src_input | wr_src_wb;
    assign mem_wa_a = wr_sel_wb_b ? bf_addr_b :
                      wr_src_wb    ? bf_addr_a : coeff_bitrev;
    assign mem_wd_a = wr_sel_wb_b ? bf_b_out  :
                      wr_src_wb    ? bf_a_out  : in_data;

    // =========================================================================
    // 读端口收敛：mem 只有 2 个读表达式，否则 Vivado 报 Synth 8-2914
    // "Unsupported RAM template"（实测：3 读不可推断；1 写 + 2 读 可推断）。
    //   - 读端口 A：COMPUTE 阶段读 a_addr_calc；OUT_PRE/OUTPUT 阶段读输出索引
    //     （两阶段互斥，故可共用同一表达式）
    //   - 读端口 B：COMPUTE 阶段读 b_addr_calc
    // =========================================================================
    assign out_rd_addr = (state == S_OUTPUT && out_ready)
                           ? (coeff_idx + 1'b1) : coeff_idx;
    assign rd_addr_a   = (state == S_COMPUTE) ? a_addr_calc : out_rd_addr;

    // -------------------------------------------------------------------------
    // 系数存储器实例：1 写 + 2 读（1W2R，E39b）
    //   - USE_BRAM_IP=1（生产 N>=2048）：走官方 blk_mem_gen IP，避免 Synth 8-2914
    //   - USE_BRAM_IP=0（玩具 N<=1024）：走自动推断，仿真回归不变
    // -------------------------------------------------------------------------
    ntt_mem_tdp_prod #(
        .AW($clog2(N)),
        .DW(Q_WIDTH),
        .USE_IP(USE_BRAM_IP)
    ) u_mem (
        .clk (clk),
        .wea (mem_we_a), .waa (mem_wa_a), .wda (mem_wd_a),
        .raa (rd_addr_a), .rab (b_addr_calc),
        .rda (mem_rd_a),  .rdb (mem_rd_b)
    );

    // =========================================================================
    // 输出缩放 2 级流水化（Task #68）：拆分关键路径 + 统一 NTT/INTT 数据延迟
    //
    //   原组合路径（仅 INTT）：mem_rd_a → *N_INV → %Q_VALUE → out_data（~10.8 ns）
    //   拆分后（NTT + INTT 统一走同一条 2 级流水线）：
    //     mem_rd_a → *scale → [REG1] → %Q_VALUE → [REG2] → out_data（组合直出）
    //
    //   scale = op_mode ? N_INV_VAL : 1
    //     NTT:  *1 → %Q_VALUE = mem_rd_a（恒等，合成器应优化掉）
    //     INTT: *N_INV → %Q_VALUE = (mem_rd_a * N^-1) mod q
    //
    //   关键对齐论证：
    //     数据延迟 = 2 拍（REG1 + REG2），out_data 由 REG2 组合直出
    //     控制延迟 = 2 拍（out_valid_int → r1 → r2）
    //     二者严格对齐，NTT/INTT 行为一致。
    //
    //   旧版 bug：out_data 在 always_ff 内再寄一拍（共 3 拍），
    //     而 out_valid 只有 2 拍 → 数据比 valid 晚到 1 拍（INTT）或
    //     早到 1 拍（NTT，因为 NTT 走 mem_rd_a 直出不走流水线）。
    // -------------------------------------------------------------------------
    // 缩放因子：op_mode=1（INTT）用 N_INV，op_mode=0（NTT）用 1（恒等）
    localparam [Q_WIDTH-1:0] N_INV_VAL = N_INV;
    wire [Q_WIDTH-1:0] scale_factor = op_mode ? N_INV_VAL : {{Q_WIDTH-1{1'b0}}, 1'b1};

    // 第 1 级：乘法器输出寄存
    logic [2*Q_WIDTH-1:0] out_scale_prod_r;
    // 第 2 级：取模结果寄存
    logic [Q_WIDTH-1:0]   out_scaled_r;
    // 控制信号流水线（与数据延迟严格对齐：均为 2 拍）
    logic out_valid_int;      // 状态机生成的原始 valid
    logic out_last_int;       // 状态机生成的原始 last
    logic out_valid_r1;       // REG1
    logic out_last_r1;
    logic out_valid_r2;       // REG2（Task #86: 2 级流水，与数据对齐）
    logic out_last_r2;
    logic done_cnt;           // Task #86: S_DONE drain 计数（1 拍）

    // 组合乘法器（输入来自同步读寄存器 mem_rd_a）
    wire [2*Q_WIDTH-1:0] out_scale_prod_comb = mem_rd_a * scale_factor;
    // 组合取模（输入来自流水线第 1 级寄存器）
    wire [Q_WIDTH-1:0]   out_scaled_comb     = out_scale_prod_r % Q_VALUE;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_scale_prod_r <= '0;
            out_scaled_r     <= '0;
            out_valid_r1     <= 1'b0;
            out_last_r1      <= 1'b0;
            out_valid_r2     <= 1'b0;
            out_last_r2      <= 1'b0;
        end else begin
            // =========================================================================
            // Task #86 修复（2026-10-11 v5）：2 级 valid 流水，与数据对齐
            //   数据：out_scale_prod_comb → REG1(out_scale_prod_r) → REG2(out_scaled_r)
            //   Valid：out_valid_int → REG1(out_valid_r1) → REG2(out_valid_r2)
            //   两者均受 out_ready 门控，确保末元素 valid 与数据同步到达输出。
            // =========================================================================
            if (out_ready) begin
                out_scale_prod_r <= out_scale_prod_comb;
                out_scaled_r     <= out_scaled_comb;
                out_valid_r1     <= out_valid_int;
                out_last_r1      <= out_last_int;
                out_valid_r2     <= out_valid_r1;
                out_last_r2      <= out_last_r1;
            end
        end
    end
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            comp_state      <= C_ISSUE;
            coeff_idx       <= '0;
            stage_idx       <= '0;
            bf_idx          <= '0;
            wait_cnt        <= '0;
            bf_addr_a       <= '0;
            bf_addr_b       <= '0;
            twiddle_exp     <= '0;
            bf_a_in         <= '0;
            bf_b_in         <= '0;
            bf_omega_in     <= '0;
            bf_valid        <= 1'b0;
            busy            <= 1'b0;
            done            <= 1'b0;
            error           <= 1'b0;
            in_ready        <= 1'b0;
            out_valid_int   <= 1'b0;
            out_last_int    <= 1'b0;
        end else begin
            // 默认清零状态机内信号
            done          <= 1'b0;
            in_ready      <= 1'b0;
            bf_valid      <= 1'b0;
            out_valid_int <= 1'b0;
            out_last_int  <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy       <= 1'b1;
                        in_ready   <= 1'b1;
                        coeff_idx  <= '0;
                        stage_idx  <= '0;
                        bf_idx     <= '0;
                        comp_state <= C_ISSUE;
                        state      <= S_INPUT;
                    end
                end

                S_INPUT: begin
                    in_ready <= 1'b1;
                    if (in_valid && in_ready) begin
                        coeff_idx <= coeff_idx + 1'b1;
                        if (coeff_idx == N - 1) begin
                            in_ready   <= 1'b0;
                            stage_idx  <= '0;
                            bf_idx     <= '0;
                            comp_state <= C_ISSUE;
                            state      <= S_COMPUTE;
                        end
                    end
                end

                S_COMPUTE: begin
                    case (comp_state)
                        C_ISSUE: begin
                            bf_addr_a   <= a_addr_calc;
                            bf_addr_b   <= b_addr_calc;
                            twiddle_exp <= twiddle_exp_calc;
                            comp_state  <= C_RD_DLY;   // 2026-10-18：等 RAM 2 级读流水
                        end

                        C_RD_DLY: begin
                            // 空拍：读地址 a_addr_calc/b_addr_calc 保持（bf_idx、
                            // stage_idx 未变），mem_rd_a/mem_rd_b 在本拍末变有效，
                            // 供 C_LATCH 采样。
                            comp_state <= C_LATCH;
                        end

                        C_LATCH: begin
                            bf_a_in     <= mem_rd_a;
                            bf_b_in     <= mem_rd_b;
                            bf_omega_in <= op_mode ? tw_inv_rom_rd : tw_rom_rd;
                            if (bf_ready) begin
                                bf_valid   <= 1'b1;
                                comp_state <= C_WAIT;
                                wait_cnt   <= 2'd3;  // Task #70: butterfly 3-cycle (was 2)
                            end
                        end

                        C_WAIT: begin
                            if (wait_cnt > 0) begin
                                wait_cnt <= wait_cnt - 1;
                            end else begin
                                comp_state <= C_WRITEBACK;
                            end
                        end

                        // 1W2R 回写拍 1：bf_a_out -> bf_addr_a（唯一写口）
                        C_WRITEBACK: begin
                            comp_state <= C_WRITEBACK_B;
                        end

                        // 1W2R 回写拍 2：bf_b_out -> bf_addr_b，然后推进蝴蝶
                        C_WRITEBACK_B: begin
                            bf_idx     <= bf_idx + 1'b1;
                            comp_state <= C_ISSUE;
                            if (bf_idx == N/2 - 1) begin
                                bf_idx    <= '0;
                                stage_idx <= stage_idx + 1'b1;
                                if (stage_idx == LOG_N - 1) begin
                                    coeff_idx  <= '0;
                                    // E39b：清零 stage_idx，避免 LOG_N 暂态使
                                    // stride = 1<<LOG_N 在位宽内溢出为 0，进而
                                    // bf_idx/stride 除零产生 X（RTL-vs-网表
                                    // X-init 伪差来源；输出相位这些组合结果不
                                    // 被消费，但保持定义良好更稳健）。NBA 同块
                                    // 后者生效，覆盖上面的 +1。
                                    stage_idx  <= '0;
                                    comp_state <= C_ISSUE;
                                    state      <= S_OUT_PRE;
                                end
                            end
                        end

                        default: comp_state <= C_ISSUE;
                    endcase
                end

                S_OUT_PRE: begin
                    coeff_idx  <= '0;
                    state      <= S_OUTPUT;
                end

                S_OUTPUT: begin
                    // 控制信号送入流水线（不直接驱动输出端口）
                    out_valid_int <= 1'b1;
                    out_last_int  <= (coeff_idx == N - 1);
                    // 数据由 2 级流水线 out_scaled_r 组合直出（见文件尾部 assign）
                    if (out_ready) begin
                        coeff_idx <= coeff_idx + 1'b1;
                        if (coeff_idx == N - 1) begin
                            state <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    // Task #86 修复（2026-10-11）：清零 out_valid_int，防止 phantom 数据
                    // 原代码 S_DONE 未清零 out_valid_int，导致输出完 N 个元素后
                    // 继续输出 valid=1 的 phantom 数据，块级模式下造成数据丢失
                    out_valid_int <= 1'b0;
                    out_last_int  <= 1'b0;
                    done      <= 1'b1;
                    state     <= S_IDLE;
                end

                S_ERROR: begin
                    error <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_ERROR;
            endcase
        end
    end

    // 输出端口：数据由流水线第 2 级组合直出，控制由流水线寄存器驱动
    // Task #86 修复（v5）：valid 也采用 2 级流水，与数据严格对齐
    //   数据：out_scale_prod_comb → REG1 → REG2(out_scaled_r)
    //   Valid：out_valid_int → REG1(out_valid_r1) → REG2(out_valid_r2)
    //   两者均在 out_ready=1 时推进，末元素 valid 与数据同步到达输出。
    assign out_data  = out_scaled_r;
    assign out_valid = out_valid_r2;
    assign out_last  = out_last_r2;

endmodule

`default_nettype wire
