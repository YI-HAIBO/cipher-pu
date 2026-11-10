//=============================================================================
// ntt_mem_tdp_prod.sv  —  ntt_mem_tdp 的生产包装器（USE_IP 切换）
//
// 【2026-10-17 重建】原文件被误清空（2 字节），本文件依据：
//   (a) 唯一实例化点 rtl/m1/ntt_unit.sv:267-277 反推端口签名；
//   (b) rtl/m1/BRAM_IP_README.md:140-154 的「Wrapper 接口映射」表逐行反推
//       USE_IP=1 分支的 IP 连线；
//   (c) BRAM_IP_README.md:154「USE_IP=0 分支是 ntt_mem_tdp.sv 的 4 个
//       always_ff 完全副本」。
//   原文件无法从 sim/*/ 副本恢复：全仓无任何非空副本，无 git，无 .bak。
//
// 【重要 - 待恢复项】USE_IP=1 分支引用的官方 IP 模块 ntt_mem_bram 来自
//   ip_repo/ntt_mem_bram/，该目录目前在本机不存在（ip_repo 整体丢失）。
//   玩具/仿真路径（USE_IP=0，N<=1024）不触碰该分支，可正常编译与精化；
//   生产综合前需先重跑 scripts/gen_bram_ip_official.py 重建 IP。
//
// 【E39b 2026-11-08 1W2R 改造】接口由 2 写 + 2 读（TDP）收敛为 1 写 + 2 读：
//   蝶形回写的两个输出由 ntt_unit 分两拍经唯一写口串行写入
//   （C_WRITEBACK 写 A 输出，C_WRITEBACK_B 写 B 输出）。动机：Vivado 多端口
//   RAM 仿真中 W1（B 口）写对任何读口不可见（E39b 根因报告 §4.2），1W2R 为
//   单写口广播结构、无目录，等价性有结构保证。写转发逻辑保留并收敛为
//   单写口命中。
//
// 时序语义：rda/rdb 严格 2 拍读延迟（地址周期 C 呈现 -> 数据周期 C+2 可用）。
//   USE_IP=1 时由 IP 的 Register_PortA/B_Output_of_Memory_Core=true 提供。
//=============================================================================

`timescale 1ns / 1ps

module ntt_mem_tdp_prod #(
    parameter int AW = 12,
    parameter int DW = 45,
    parameter int USE_IP = 0          // 0: 自动推断 BRAM; 1: 官方 blk_mem_gen IP
) (
    input  logic              clk,

    // 唯一写口（1W2R）
    input  logic              wea,
    input  logic [AW-1:0]     waa,
    input  logic [DW-1:0]     wda,

    // 两个独立读口
    input  logic [AW-1:0]     raa,
    input  logic [AW-1:0]     rab,
    output logic [DW-1:0]     rda,
    output logic [DW-1:0]     rdb
);

    localparam int DEPTH = (1 << AW);

    generate if (USE_IP) begin : g_ip

        // =====================================================================
        // USE_IP=1：官方 blk_mem_gen 8.4 IP（模块名 ntt_mem_bram），1W2R 配置
        //
        //   端口 A 承担「写 或 读」（地址总线复用，与重建版一致的映射）：
        //     addr_a_eff = wea ? waa : raa
        //   写阶段（wea=1）把写地址送上地址总线并把 ena 拉低（读输出冻结），
        //   避免写入期间组合穿透旧数据；读阶段（wea=0、ena=1）把读地址送上
        //   同一条总线。
        //   端口 B 退化为专职读口（web 恒 0、enb 恒 1），地址 = rab。
        //
        //   【2026-10-24 修】blk_mem_gen 8.4 True_Dual_Port IP 的标准端口名是
        //   .clka/.clkb/.addra/.addrb（无下划线）。
        // =====================================================================
        logic [AW-1:0] addr_a_eff = wea ? waa : raa;

        ntt_mem_bram u_ip_bram (
            .clka    (clk),
            .regcea  (1'b1),
            .ena     (~wea),
            .wea     (wea),
            .addra   (addr_a_eff),
            .dina    (wda),
            .douta   (rda),
            .clkb    (clk),
            .regceb  (1'b1),
            .enb     (1'b1),
            .web     (1'b0),
            .addrb   (rab),
            .dinb    ({DW{1'b0}}),
            .doutb   (rdb)
        );

    end else begin : g_auto

        // =====================================================================
        // USE_IP=0：自动推断 BRAM（玩具路径 / 仿真回归），1 写 + 2 读
        //
        //   【E39b 2026-11-08】原 2W2R 行为模型在综合后多端口 BRAM 仿真中
        //   存在两类语义分歧：同周期 RDW 碰撞（RTL 按写优先、网表按
        //   READ_FIRST）与跨端口可见性（W1 写对读口不可见）。显式写转发
        //   消除了前者；后者在结构上无解，故接口收敛为 1W2R：蝶形两输出
        //   分两拍经唯一写口写入，单写口为广播结构、无目录分歧。
        //
        //   读路径保持纯 BRAM 模板（rda_raw/rdb_raw 无条件同步读，保证
        //   BRAM 推断），转发用独立寄存器 + 输出复用实现：
        //     条件（采样边沿 k 时）：写口在周期 k-2 呈现的写命中本轮注册读
        //     地址（raa_r[k-1] = raa[k-2]），则用写数据覆盖 BRAM 读输出。
        //     该条件与原 NBA 行为模型逐位等价（E39b 回归 dump 已证明）。
        // =====================================================================
        logic [DW-1:0] mem    [0:DEPTH-1];
        logic [AW-1:0] raa_r;
        logic [AW-1:0] rab_r;

        logic          wea_d1;
        logic [AW-1:0] waa_d1;
        logic [DW-1:0] wda_d1;

        logic [DW-1:0] rda_raw, rdb_raw;
        logic          rda_fwd_sel, rdb_fwd_sel;
        logic [DW-1:0] rda_fwd_dat, rdb_fwd_dat;

        wire rda_hit = wea_d1 && (waa_d1 == raa_r);
        wire rdb_hit = wea_d1 && (waa_d1 == rab_r);

        always_ff @(posedge clk) begin
            if (wea) mem[waa] <= wda;
            raa_r <= raa;
            wea_d1 <= wea;  waa_d1 <= waa;  wda_d1 <= wda;
        end

        always_ff @(posedge clk) rab_r <= rab;

        // 纯 RAM 读模板（无条件，保持 BRAM 推断）
        always_ff @(posedge clk) rda_raw <= mem[raa_r];
        always_ff @(posedge clk) rdb_raw <= mem[rab_r];

        // 转发寄存器（独立于 RAM 模板，单写口命中）
        always_ff @(posedge clk) begin
            rda_fwd_sel <= rda_hit;
            rda_fwd_dat <= wda_d1;
        end

        always_ff @(posedge clk) begin
            rdb_fwd_sel <= rdb_hit;
            rdb_fwd_dat <= wda_d1;
        end

        assign rda = rda_fwd_sel ? rda_fwd_dat : rda_raw;
        assign rdb = rdb_fwd_sel ? rdb_fwd_dat : rdb_raw;

    end endgenerate

endmodule
