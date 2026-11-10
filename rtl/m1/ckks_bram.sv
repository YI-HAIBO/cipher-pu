//=============================================================================
// ckks_bram.sv  —  单写口 + 单读口同步读 BRAM（1 拍读延迟）
//
// 【2026-10-17 重建】原文件被误清空（2 字节），本文件依据唯一实例化点
//   （rtl/m2/poly_mult.sv:323,332,341,351,361 共 5 处）反推端口签名后重写。
//   原文件无法从 sim/*/ 副本恢复：全仓无任何非空副本，无 git，无 .bak。
//
// 端口签名（由 poly_mult.sv 实例化点逐字确定）：
//   ckks_bram #(.AW(LOG_N), .DW(Q_WIDTH)) u_xxx (
//       .clk(clk), .we(..), .waddr(..), .wdata(..), .raddr(..), .rdata(..)
//   );
//   - 只有 clk 一个时钟，**无 rst_n**（BRAM 不带复位；带复位会阻止 BRAM 推断）
//   - 参数 AW（地址位宽）/ DW（数据位宽）
//
// 时序语义（关键，来自 poly_mult.sv:300-310 的预取论证）：
//   rdata(T+1) = mem[raddr(T)]
//   即「读地址 -> 读数据」严格 1 拍延迟。poly_mult 的预取式
//   rd_addr(T) = feeder_idx(T) + ready(T) 正是按此 1 拍口径推导的；
//   若改成组合读或 2 拍读，输入流会整体错位 1 拍、NTT 全毁。
//
// BRAM 推断：
//   「写 + 读地址锁存」合并进同一个 always_ff 是 Vivado 推断
//   True_Dual_Port / Simple_Dual_Port 的标准模板写法。
//   地址/数据均为普通逻辑信号，不使用常量数组索引（避免 Synth 8-7186）。
//
// 容量：2**AW * DW bit。生产 AW=12, DW=45 -> 491,520 bit。
//=============================================================================

`timescale 1ns / 1ps

module ckks_bram #(
    parameter int AW = 12,
    parameter int DW = 45
) (
    input  logic              clk,
    input  logic              we,
    input  logic [AW-1:0]     waddr,
    input  logic [DW-1:0]     wdata,
    input  logic [AW-1:0]     raddr,
    output logic [DW-1:0]     rdata
);

    // =========================================================================
    // 存储体与内部寄存器
    //   深度用 1<<AW 显式常数，避免 parameter 参与的位宽计算被拒收。
    // =========================================================================
    localparam int DEPTH = (1 << AW);

    logic [DW-1:0] mem    [0:DEPTH-1];

    // =========================================================================
    // always_ff 1：写端口（独立，避免与读端口相互干扰）
    // =========================================================================
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    // =========================================================================
    // always_ff 2：读数据输出寄存器（同步读，1 拍延迟）
    //   rdata(T+1) = mem[raddr(T)] —— 读地址在周期 T 呈现，数据在周期 T+1
    //   有效。这是 poly_mult 预取式 rd_addr(T) = feeder_idx(T) + ready(T)
    //   与 slot_packer BRAM 化所依赖的口径。
    //
    //   【2026-10-18 重建纠错】原重建误加了 raddr_r 地址寄存级（写成
    //     raddr_r <= raddr; rdata <= mem[raddr_r]），使读延迟变成 2 拍，
    //     与本文件头注释及所有消费者的预取论证不符：poly_mult 的 FEED
    //     路径整体错位 1 拍（pm_n8 实测 a_hat ≠ DFT(a)），slot_packer /
    //     keyswitch_pipe / rescale / approx_poly_mult 同理受损。
    //     现恢复为真正的 1 拍同步读。（Vivado 推断 BRAM 的标准模板本就是
    //     rdata <= mem[raddr]，无需额外地址寄存级。）
    // =========================================================================
    always_ff @(posedge clk) begin
        rdata <= mem[raddr];
    end

endmodule
