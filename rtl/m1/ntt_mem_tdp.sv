//=============================================================================
// ntt_mem_tdp.sv  —  2 写 + 2 读 True Dual Port 同步读存储器（1 拍读延迟）
//
// 【2026-10-17 重建】原文件被误清空（2 字节），本文件依据：
//   (a) 唯一实例化点 rtl/m1/ntt_unit.sv:267-277 反推端口签名；
//   (b) rtl/m1/BRAM_IP_README.md:154「USE_IP=0 分支是 ntt_mem_tdp.sv 的
//       4 个 always_ff 完全副本」反推内部结构；
//   (c) 同目录 BRAM_IP_README.md 的问题背景段落反推容量/参数语义。
//   原文件无法从 sim/*/ 副本恢复：全仓无任何非空副本，无 git，无 .bak。
//
// 端口签名（ntt_unit.sv:271-277 逐字确定）：
//   ntt_mem_tdp #(.AW($clog2(N)), .DW(Q_WIDTH)) u_mem (
//       .clk, .wea, .waa, .wda, .web, .wab, .wdb, .raa, .rab, .rda, .rdb
//   );
//   - 只有 clk 一个时钟，**无 rst_n**（BRAM 不带复位；带复位阻止推断）
//
// 时序语义：
//   rda(T+1) = mem[raa(T)]，rdb(T+1) = mem[rab(T)]
//   严格 1 拍读延迟。ntt_unit 的 2 级输出缩放流水（ntt_unit.sv:279-297）
//   按此口径对齐 out_valid，改动延迟会破坏数据/控制对齐。
//
// 容量：2**AW * DW bit。生产 N=2^14, Q_WIDTH=45 -> 737,280 bit ≈ 20 x RAMB36E1。
//   该规模 Vivado 2026.1 自动推断失败（Synth 8-2914），生产走 ntt_mem_tdp_prod
//   的 USE_IP=1 官方 IP 分支；本文件服务玩具路径（N<=1024）与仿真回归。
//
// 4 个 always_ff（与 README 记载一致）：写A / 写B / 读地址锁存 / 读数据
//=============================================================================

`timescale 1ns / 1ps

module ntt_mem_tdp #(
    parameter int AW = 12,
    parameter int DW = 45
) (
    input  logic              clk,

    input  logic              wea,
    input  logic [AW-1:0]     waa,
    input  logic [DW-1:0]     wda,
    input  logic              web,
    input  logic [AW-1:0]     wab,
    input  logic [DW-1:0]     wdb,

    input  logic [AW-1:0]     raa,
    input  logic [AW-1:0]     rab,
    output logic [DW-1:0]     rda,
    output logic [DW-1:0]     rdb
);

    localparam int DEPTH = (1 << AW);

    logic [DW-1:0] mem    [0:DEPTH-1];
    logic [AW-1:0] raa_r;
    logic [AW-1:0] rab_r;

    // ---- always_ff 1：写端口 A + 读地址 A 锁存 ------------------------------
    always_ff @(posedge clk) begin
        if (wea) mem[waa] <= wda;
        raa_r <= raa;
    end

    // ---- always_ff 2：写端口 B + 读地址 B 锁存 ------------------------------
    always_ff @(posedge clk) begin
        if (web) mem[wab] <= wdb;
        rab_r <= rab;
    end

    // ---- always_ff 3：读数据 A（同步读，1 拍延迟）---------------------------
    always_ff @(posedge clk) begin
        rda <= mem[raa_r];
    end

    // ---- always_ff 4：读数据 B（同步读，1 拍延迟）---------------------------
    always_ff @(posedge clk) begin
        rdb <= mem[rab_r];
    end

endmodule
