//=============================================================================
// poly_mult_rns.sv  —  RNS 多项式点乘加速器（密推芯 E37 Phase 2）
//
// 功能：
//   对 3 个 RNS 分量并行执行 C_i(x) = A_i(x) * B_i(x) mod (x^N - 1, p_i)
//   每个分量独立走一条 poly_mult 链（收 A -> 收 B -> NTT_A -> NTT_B -> 点乘
//   -> INTT -> 输出），3 路完全并行、互不干扰。
//
// 原理（RNS-CKKS）：
//   大模数域 (M = p1*p2*p3) 的多项式乘法可分解为 3 个小模数域 (p1,p2,p3)
//   的并行乘法。每个小模数位宽 ≤ 42 bit，比单模数 115 bit 更利于 FPGA
//   乘法器/取模实现；3 路并行使吞吐不降，面积近似 ×3。
//
// 接口（AXI-Stream valid/ready，每路分量独立流式）：
//   - a_in_*_p1/p2/p3 : A 系数的 3 个 RNS 分量流
//   - b_in_*_p1/p2/p3 : B 系数的 3 个 RNS 分量流
//   - out_*_p1/p2/p3  : C 系数的 3 个 RNS 分量流（模 p_i，已含 INTT N^-1 缩放）
//   - start           : 单周期启动脉冲（3 路同步启动）
//   - busy/done/error : 状态指示（busy/done 为 3 路逻辑与）
//
// 参数：
//   LOG_N    : log2(N)
//   Q_WIDTH  : 素数分量位宽（本设计 42，覆盖 max bit length of p_i）
//   P1/P2/P3 : 三个素数模数
//   N_INV1..3: 各素数下 N^-1 mod p_i（INTT 缩放）
//
// 依赖：
//   - poly_mult (rtl/m2/poly_mult.sv)，内部再实例化 ntt_unit
//   - twiddle 表由上层（或本模块 generate）提供
//
// 使用说明：
//   3 路 twiddle 表（omega_table_p1/p2/p3 与 omega_inv_table_p1/p2/p3）
//   必须由调用方提供，每组 N/2 个 Q_WIDTH bit 值：
//     omega_table_pi[k] = omega_i^k mod p_i        (k=0..N/2-1)
//     omega_inv_table_pi[k] = (omega_i^-1)^k mod p_i
//   其中 omega_i 为 p_i 的 N 次本原单位根。
//
// 验证：scripts/tb_poly_mult_rns.py（与 Python rns NTT golden 一致）
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module poly_mult_rns #(
    parameter int LOG_N   = 4,
    parameter int N       = 1 << LOG_N,
    parameter int Q_WIDTH = 42,
    parameter logic [Q_WIDTH-1:0] P1 = 42'd77309411329,
    parameter logic [Q_WIDTH-1:0] P2 = 42'd206158430209,
    parameter logic [Q_WIDTH-1:0] P3 = 42'd2061584302081,
    parameter logic [Q_WIDTH-1:0] N_INV1 = 42'd72477573121,
    parameter logic [Q_WIDTH-1:0] N_INV2 = 42'd193273528321,
    parameter logic [Q_WIDTH-1:0] N_INV3 = 42'd1932735283201,
    parameter string TW_ROOT = "rtl/m5/tw"
) (
    input  wire logic               clk,
    input  wire logic               rst_n,

    // 控制（3 路同步）
    input  wire logic               start,
    output logic                    busy,
    output logic                    done,
    output logic                    error,

    // A 输入流（3 路 RNS 分量，并行）
    input  wire logic [Q_WIDTH-1:0] a_in_data_p1,
    input  wire logic               a_in_valid_p1,
    output logic                    a_in_ready_p1,
    input  wire logic [Q_WIDTH-1:0] a_in_data_p2,
    input  wire logic               a_in_valid_p2,
    output logic                    a_in_ready_p2,
    input  wire logic [Q_WIDTH-1:0] a_in_data_p3,
    input  wire logic               a_in_valid_p3,
    output logic                    a_in_ready_p3,

    // B 输入流（3 路 RNS 分量，并行）
    input  wire logic [Q_WIDTH-1:0] b_in_data_p1,
    input  wire logic               b_in_valid_p1,
    output logic                    b_in_ready_p1,
    input  wire logic [Q_WIDTH-1:0] b_in_data_p2,
    input  wire logic               b_in_valid_p2,
    output logic                    b_in_ready_p2,
    input  wire logic [Q_WIDTH-1:0] b_in_data_p3,
    input  wire logic               b_in_valid_p3,
    output logic                    b_in_ready_p3,

    // C 输出流（3 路 RNS 分量，并行）
    output logic [Q_WIDTH-1:0]      out_data_p1,
    output logic                    out_valid_p1,
    output logic                    out_last_p1,
    input  wire logic               out_ready_p1,
    output logic [Q_WIDTH-1:0]      out_data_p2,
    output logic                    out_valid_p2,
    output logic                    out_last_p2,
    input  wire logic               out_ready_p2,
    output logic [Q_WIDTH-1:0]      out_data_p3,
    output logic                    out_valid_p3,
    output logic                    out_last_p3,
    input  wire logic               out_ready_p3

);

    // M-D': twiddle ROM 文件（按 N 选），$readmemh 用绝对路径
    localparam string TW_SUF = (N == 16384) ? "n16384" : ((N == 4096) ? "n4096" : "n16");
    // B-6 方案A：TW_ROOT 由脚本经 --generic_top 注入绝对路径覆盖；
    // 默认中性相对路径（相对仓库根 cwd），未注入时依赖 xsim cwd。
    localparam string TW_FILE_P1     = {TW_ROOT, "/tw_omega_p1_",     TW_SUF, ".hex"};
    localparam string TW_INV_FILE_P1 = {TW_ROOT, "/tw_omegainv_p1_", TW_SUF, ".hex"};
    localparam string TW_FILE_P2     = {TW_ROOT, "/tw_omega_p2_",     TW_SUF, ".hex"};
    localparam string TW_INV_FILE_P2 = {TW_ROOT, "/tw_omegainv_p2_", TW_SUF, ".hex"};
    localparam string TW_FILE_P3     = {TW_ROOT, "/tw_omega_p3_",     TW_SUF, ".hex"};
    localparam string TW_INV_FILE_P3 = {TW_ROOT, "/tw_omegainv_p3_", TW_SUF, ".hex"};

    // 3 路内部状态信号（声明在使用前）
    logic busy1, busy2, busy3;
    logic done1, done2, done3;
    logic error1, error2, error3;

    // 3 路并行 poly_mult（每路独立处理一个 RNS 分量）
    poly_mult #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(P1), .N_INV(N_INV1), .USE_FASTRED(0), .USE_BRAM_IP(0),
        .TW_FILE(TW_FILE_P1), .TW_INV_FILE(TW_INV_FILE_P1)
    ) pm_p1 (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy1), .done(done1), .error(error1),
        .a_in_data(a_in_data_p1), .a_in_valid(a_in_valid_p1), .a_in_ready(a_in_ready_p1),
        .b_in_data(b_in_data_p1), .b_in_valid(b_in_valid_p1), .b_in_ready(b_in_ready_p1),
        .out_data(out_data_p1), .out_valid(out_valid_p1), .out_last(out_last_p1),
        .out_ready(out_ready_p1)
    );

    poly_mult #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(P2), .N_INV(N_INV2), .USE_FASTRED(0), .USE_BRAM_IP(0),
        .TW_FILE(TW_FILE_P2), .TW_INV_FILE(TW_INV_FILE_P2)
    ) pm_p2 (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy2), .done(done2), .error(error2),
        .a_in_data(a_in_data_p2), .a_in_valid(a_in_valid_p2), .a_in_ready(a_in_ready_p2),
        .b_in_data(b_in_data_p2), .b_in_valid(b_in_valid_p2), .b_in_ready(b_in_ready_p2),
        .out_data(out_data_p2), .out_valid(out_valid_p2), .out_last(out_last_p2),
        .out_ready(out_ready_p2)
    );

    poly_mult #(
        .LOG_N(LOG_N), .N(N), .Q_WIDTH(Q_WIDTH),
        .Q_VALUE(P3), .N_INV(N_INV3), .USE_FASTRED(0), .USE_BRAM_IP(0),
        .TW_FILE(TW_FILE_P3), .TW_INV_FILE(TW_INV_FILE_P3)
    ) pm_p3 (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy3), .done(done3), .error(error3),
        .a_in_data(a_in_data_p3), .a_in_valid(a_in_valid_p3), .a_in_ready(a_in_ready_p3),
        .b_in_data(b_in_data_p3), .b_in_valid(b_in_valid_p3), .b_in_ready(b_in_ready_p3),
        .out_data(out_data_p3), .out_valid(out_valid_p3), .out_last(out_last_p3),
        .out_ready(out_ready_p3)
    );

    // 状态聚合：busy/done 为 3 路逻辑与（同步完成）
    assign busy  = busy1 & busy2 & busy3;
    assign done  = done1 & done2 & done3;
    assign error = error1 | error2 | error3;

endmodule
