//=============================================================================
// e2e_rns_top.sv  —  RNS 端到端数据通路（密推芯 E37 Phase 2 集成）
//
// 功能：
//   单模数多项式 A、B → RNS 分解 → 3 路并行同态乘 → 系数域 rescale →
//   CRT 合并 → 单模数结果 C。
//
// 数据通路：
//   A_in(115b) ─┐
//               ├─ 内联取模（%p1/%p2/%p3）→ a_mem_p1/2/3 ─┐
//   B_in(115b) ─┘                                        ├─ poly_mult_rns
//               ─ 内联取模 → b_mem_p1/2/3 ────────────────┘   (3 路并行)
//                                                          ↓
//   pm.out_p1/2/3 ──→ rescale_rns（CRT→居中→÷Δ→重分解）──→ rns_merge ──→ out(115b)
//
// 输入级说明：
//   rns_split 已模块级签核（20/20）；此处为避免 split 流水与 memo 写入的
//   对齐复杂度，直接内联等价组合取模（a_in_data % p_i），行为与 rns_split
//   完全一致（rns_split = 组合取模 + 输出寄存）。
//
// 喂入策略（关键简化）：
//   poly_mult_rns 的 3 路 poly_mult 状态同步（同时 start、同时钟）。
//   e2e_top 同时把 a_in_valid_p* 与 b_in_valid_p* 拉高（数据各自从 memo 读出），
//   pm 内部按 S_IN_A/S_IN_B 阶段分别采样（a_in_ready/b_in_ready 分时有效），
//   互不干扰。addr_a/addr_b 在各自 ready 时递增，N 个后自动停。
//
// 输出链：
//   pm.out_valid_p*（3 路同步）→ rescale.s_valid（恒 ready，3 cycle 流水延迟）
//   → merge.s_valid（再 2 cycle 延迟）→ out。
//   out_last 由 e2e_top 计数 merge 输出（N 个）产生，不依赖 pm.out_last
//   的 3 拍流水对齐。
//
// 接口：
//   - start：单周期脉冲，启动整个流程（先收 A，再收 B，再乘，再输出）
//   - a_in_* / b_in_*：单模数系数流（各 N 个，115 bit）
//   - out_*：单模数结果流（N 个，115 bit）
//
// 参数：
//   LOG_N / N / P_WIDTH / M_WIDTH / SCALE（Δ）
//   W1/W2/W3/M（CRT 权重与模数乘积）、P1/P2/P3（素数）、N_INV1/2/3
//
// 依赖：poly_mult_rns、rescale_rns、rns_merge
// 验证：scripts/tb_e2e_rns.py（与 Python 全链路 golden 一致）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module e2e_rns_top #(
    parameter int LOG_N   = 4,
    parameter int N       = 1 << LOG_N,
    parameter int P_WIDTH = 42,
    parameter int M_WIDTH = 115,
    parameter int SCALE   = 1024,
    parameter logic [M_WIDTH-1:0] W1 = 115'h38477b0357aa2be2be3fa0154725f,
    parameter logic [M_WIDTH-1:0] W2 = 115'h47ffffffffa66666662622222222,
    parameter logic [M_WIDTH-1:0] W3 = 115'h287884fcb04d6db6db801dc896b81,
    parameter logic [M_WIDTH-1:0] M  = 115'h6540000007f200000022200000001,
    parameter logic [P_WIDTH-1:0] P1 = 42'd77309411329,
    parameter logic [P_WIDTH-1:0] P2 = 42'd206158430209,
    parameter logic [P_WIDTH-1:0] P3 = 42'd2061584302081,
    parameter logic [P_WIDTH-1:0] N_INV1 = 42'd72477573121,
    parameter logic [P_WIDTH-1:0] N_INV2 = 42'd193273528321,
    parameter logic [P_WIDTH-1:0] N_INV3 = 42'd1932735283201,
    // B-6 方案A：TW_ROOT 透传给 poly_mult_rns，由脚本 --generic_top 注入绝对路径覆盖
    parameter string TW_ROOT = "rtl/m5/tw"
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    input  wire logic              start,
    output logic                    busy,
    output logic                    done,
    output logic                    error,

    // A 输入流（单模数系数，M_WIDTH bit）
    input  wire logic [M_WIDTH-1:0] a_in_data,
    input  wire logic               a_in_valid,
    output logic                    a_in_ready,

    // B 输入流（单模数系数）
    input  wire logic [M_WIDTH-1:0] b_in_data,
    input  wire logic               b_in_valid,
    output logic                    b_in_ready,

    // 结果输出流（单模数系数）
    output logic [M_WIDTH-1:0]      out_data,
    output logic                    out_valid,
    output logic                    out_last,
    input  wire logic               out_ready

);

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam S_IDLE   = 4'd0;
    localparam S_IN_A   = 4'd1;
    localparam S_IN_B   = 4'd2;
    localparam S_PM     = 4'd3;   // 拉高 pm_start 1 拍
    localparam S_PM_RUN = 4'd4;   // 喂入 + 输出收集
    localparam S_DONE   = 4'd5;

    logic [3:0] state;

    // =========================================================================
    // 系数存储（6 个 memo：a/b × 3 分量）
    // =========================================================================
    logic [P_WIDTH-1:0] a_mem_p1 [0:N-1];
    logic [P_WIDTH-1:0] a_mem_p2 [0:N-1];
    logic [P_WIDTH-1:0] a_mem_p3 [0:N-1];
    logic [P_WIDTH-1:0] b_mem_p1 [0:N-1];
    logic [P_WIDTH-1:0] b_mem_p2 [0:N-1];
    logic [P_WIDTH-1:0] b_mem_p3 [0:N-1];

    logic [$clog2(N)-1:0] wr_ptr;      // 输入级写指针（0..N-1）
    logic [$clog2(N):0]   out_cnt;    // merge 输出计数（0..N）

    // =========================================================================
    // PM（3 路并行同态乘）
    // =========================================================================
    logic               pm_start, pm_busy, pm_done, pm_error;
    logic [P_WIDTH-1:0] pm_a_d1, pm_a_d2, pm_a_d3;
    logic               pm_a_v1, pm_a_v2, pm_a_v3;
    logic               pm_a_r1, pm_a_r2, pm_a_r3;
    logic [P_WIDTH-1:0] pm_b_d1, pm_b_d2, pm_b_d3;
    logic               pm_b_v1, pm_b_v2, pm_b_v3;
    logic               pm_b_r1, pm_b_r2, pm_b_r3;
    logic [P_WIDTH-1:0] pm_o_d1, pm_o_d2, pm_o_d3;
    logic               pm_o_v1, pm_o_v2, pm_o_v3;
    logic               pm_o_l1, pm_o_l2, pm_o_l3;
    logic               pm_o_r1, pm_o_r2, pm_o_r3;

    poly_mult_rns #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(P_WIDTH),
        .P1(P1), .P2(P2), .P3(P3),
        .N_INV1(N_INV1), .N_INV2(N_INV2), .N_INV3(N_INV3),
        .TW_ROOT(TW_ROOT)
    ) u_pm (
        .clk(clk), .rst_n(rst_n),
        .start(pm_start), .busy(pm_busy), .done(pm_done), .error(pm_error),
        .a_in_data_p1(pm_a_d1), .a_in_valid_p1(pm_a_v1), .a_in_ready_p1(pm_a_r1),
        .a_in_data_p2(pm_a_d2), .a_in_valid_p2(pm_a_v2), .a_in_ready_p2(pm_a_r2),
        .a_in_data_p3(pm_a_d3), .a_in_valid_p3(pm_a_v3), .a_in_ready_p3(pm_a_r3),
        .b_in_data_p1(pm_b_d1), .b_in_valid_p1(pm_b_v1), .b_in_ready_p1(pm_b_r1),
        .b_in_data_p2(pm_b_d2), .b_in_valid_p2(pm_b_v2), .b_in_ready_p2(pm_b_r2),
        .b_in_data_p3(pm_b_d3), .b_in_valid_p3(pm_b_v3), .b_in_ready_p3(pm_b_r3),
        .out_data_p1(pm_o_d1), .out_valid_p1(pm_o_v1), .out_last_p1(pm_o_l1), .out_ready_p1(pm_o_r1),
        .out_data_p2(pm_o_d2), .out_valid_p2(pm_o_v2), .out_last_p2(pm_o_l2), .out_ready_p2(pm_o_r2),
        .out_data_p3(pm_o_d3), .out_valid_p3(pm_o_v3), .out_last_p3(pm_o_l3), .out_ready_p3(pm_o_r3)
    );

    // =========================================================================
    // 喂入（6 个 memo → BRAM 同步读 + 1 深 skid 缓冲，满吞吐 valid/ready 握手）
    //   fetch = 缓冲空 或 当前字被消费 → 当拍打出下一地址，下一拍 skid 已持新字
    //   未消费且不预取时 skid 寄存器保持，地址不动（正确保握、无丢字/重复）
    // =========================================================================
    logic [$clog2(N):0]   rd_ptr_a, rd_ptr_b;   // BRAM 读地址（0..N，到 N 停）
    logic                 skid_a_v, skid_b_v;   // skid 持有未消费字
    logic [P_WIDTH-1:0]   skid_a1, skid_a2, skid_a3;
    logic [P_WIDTH-1:0]   skid_b1, skid_b2, skid_b3;

    wire consume_a = pm_a_v1 && pm_a_r1;
    wire consume_b = pm_b_v1 && pm_b_r1;
    wire fetch_a   = (rd_ptr_a < N) && (!skid_a_v || consume_a);
    wire fetch_b   = (rd_ptr_b < N) && (!skid_b_v || consume_b);

    always_ff @(posedge clk) begin
        if (state != S_PM_RUN) begin
            rd_ptr_a <= '0;  rd_ptr_b <= '0;
            skid_a_v <= 1'b0; skid_b_v <= 1'b0;
        end else begin
            if (fetch_a) begin
                skid_a1 <= a_mem_p1[rd_ptr_a[$clog2(N)-1:0]];
                skid_a2 <= a_mem_p2[rd_ptr_a[$clog2(N)-1:0]];
                skid_a3 <= a_mem_p3[rd_ptr_a[$clog2(N)-1:0]];
                rd_ptr_a <= rd_ptr_a + 1'b1;
                skid_a_v <= 1'b1;
            end else if (consume_a) begin
                skid_a_v <= 1'b0;
            end
            if (fetch_b) begin
                skid_b1 <= b_mem_p1[rd_ptr_b[$clog2(N)-1:0]];
                skid_b2 <= b_mem_p2[rd_ptr_b[$clog2(N)-1:0]];
                skid_b3 <= b_mem_p3[rd_ptr_b[$clog2(N)-1:0]];
                rd_ptr_b <= rd_ptr_b + 1'b1;
                skid_b_v <= 1'b1;
            end else if (consume_b) begin
                skid_b_v <= 1'b0;
            end
        end
    end

    assign pm_a_d1 = skid_a1;  assign pm_a_d2 = skid_a2;  assign pm_a_d3 = skid_a3;
    assign pm_b_d1 = skid_b1;  assign pm_b_d2 = skid_b2;  assign pm_b_d3 = skid_b3;
    assign pm_a_v1 = skid_a_v; assign pm_a_v2 = skid_a_v; assign pm_a_v3 = skid_a_v;
    assign pm_b_v1 = skid_b_v; assign pm_b_v2 = skid_b_v; assign pm_b_v3 = skid_b_v;

    // =========================================================================
    // Rescale（系数域）+ Merge
    // =========================================================================
    logic               rs_m_valid;
    logic [P_WIDTH-1:0] rs_m_d1, rs_m_d2, rs_m_d3;
    logic               rs_s_ready;

    // Phase 4 流水化：pm 输出 → rescale 输入之间插 1 级寄存器，
    // 断开 poly_mult DSP 级联链→rescale CRT 合并的跨模块长组合路径。
    logic [P_WIDTH-1:0] pm_o_d1_r, pm_o_d2_r, pm_o_d3_r;
    logic               pm_o_v1_r;

    rescale_rns #(
        .P_WIDTH(P_WIDTH), .M_WIDTH(M_WIDTH), .SCALE(SCALE),
        .W1(W1), .W2(W2), .W3(W3), .M(M),
        .P1(P1), .P2(P2), .P3(P3)
    ) u_rs (
        .clk(clk), .rst_n(rst_n),
        .s_valid(pm_o_v1_r),        // Phase 4: 经寄存器延迟 1 拍
        .s_ready(rs_s_ready),
        .s_data_p1(pm_o_d1_r), .s_data_p2(pm_o_d2_r), .s_data_p3(pm_o_d3_r),
        .m_valid(rs_m_valid),
        .m_ready(1'b1),             // 下游 merge 恒接收
        .m_data_p1(rs_m_d1), .m_data_p2(rs_m_d2), .m_data_p3(rs_m_d3)
    );

    // Phase 4: pm 输出寄存器（纯同步，无异步复位——避免 retiming 优化挂死；
    // rescale 恒 ready 无背压，寄存器值只由 pm 输出驱动，无需复位语义）
    always_ff @(posedge clk) begin
        pm_o_d1_r <= pm_o_d1;
        pm_o_d2_r <= pm_o_d2;
        pm_o_d3_r <= pm_o_d3;
        pm_o_v1_r <= pm_o_v1;
    end

    logic               mg_m_valid;
    logic [M_WIDTH-1:0] mg_m_data;

    rns_merge #(
        .P_WIDTH(P_WIDTH), .M_WIDTH(M_WIDTH),
        .W1(W1), .W2(W2), .W3(W3), .M(M)
    ) u_mg (
        .clk(clk), .rst_n(rst_n),
        .s_valid(rs_m_valid),
        .s_ready(),                 // merge 恒接收，不需回压
        .s_data_p1(rs_m_d1), .s_data_p2(rs_m_d2), .s_data_p3(rs_m_d3),
        .m_valid(mg_m_valid),
        .m_ready(out_ready),
        .m_data(mg_m_data)
    );

    // pm 输出反压：rescale 恒 ready，pm 可连续输出
    assign pm_o_r1 = rs_s_ready;
    assign pm_o_r2 = rs_s_ready;
    assign pm_o_r3 = rs_s_ready;

    // 输出
    assign out_data  = mg_m_data;
    assign out_valid = mg_m_valid;

    // =========================================================================
    // memo 写端口（独立纯同步块：写条件与状态机完全一致，但不带异步复位敏感，
    // 否则 Vivado 拒绝推断 BRAM —— "RAM is sensitive to asynchronous reset"）
    // =========================================================================
    always_ff @(posedge clk) begin
        if (state == S_IN_A && a_in_valid) begin
            // 内联 RNS 分解（等价 rns_split 的组合取模）
            a_mem_p1[wr_ptr] <= a_in_data % P1;
            a_mem_p2[wr_ptr] <= a_in_data % P2;
            a_mem_p3[wr_ptr] <= a_in_data % P3;
        end else if (state == S_IN_B && b_in_valid) begin
            b_mem_p1[wr_ptr] <= b_in_data % P1;
            b_mem_p2[wr_ptr] <= b_in_data % P2;
            b_mem_p3[wr_ptr] <= b_in_data % P3;
        end
    end

    // =========================================================================
    // 状态机 / 控制
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            error    <= 1'b0;
            pm_start <= 1'b0;
            wr_ptr   <= '0;
            out_cnt  <= '0;
            a_in_ready <= 1'b0;
            b_in_ready <= 1'b0;
            out_last   <= 1'b0;
        end else begin
            pm_start <= 1'b0;   // 默认单拍脉冲
            done     <= 1'b0;   // done 单拍
            out_last <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state  <= S_IN_A;
                        busy   <= 1'b1;
                        wr_ptr <= '0;
                        out_cnt <= '0;
                    end
                end

                S_IN_A: begin
                    a_in_ready <= 1'b1;
                    if (a_in_valid) begin
                        if (wr_ptr == N-1) begin
                            state      <= S_IN_B;
                            a_in_ready <= 1'b0;
                            wr_ptr     <= '0;
                        end else begin
                            wr_ptr <= wr_ptr + 1'b1;
                        end
                    end
                end

                S_IN_B: begin
                    b_in_ready <= 1'b1;
                    if (b_in_valid) begin
                        if (wr_ptr == N-1) begin
                            state      <= S_PM;
                            b_in_ready <= 1'b0;
                            wr_ptr     <= '0;
                        end else begin
                            wr_ptr <= wr_ptr + 1'b1;
                        end
                    end
                end

                S_PM: begin
                    pm_start <= 1'b1;
                    state    <= S_PM_RUN;
                end

                S_PM_RUN: begin
                    // A/B 喂入已由 skid 读块管理（rd_ptr_a/rd_ptr_b）
                    // merge 输出计数（TB 需 out_ready=1 跟随）
                    if (mg_m_valid && out_ready) begin
                        if (out_cnt == N-1) begin
                            out_last <= 1'b1;
                            state    <= S_DONE;
                        end else begin
                            out_cnt <= out_cnt + 1'b1;
                        end
                    end
                    if (pm_error) error <= 1'b1;
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
