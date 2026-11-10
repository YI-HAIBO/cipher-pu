// =============================================================================
// gear_controller.sv — M4-a 档位控制器
//
// 功能：AXI-Lite 从口配置 4 档稀疏近似参数（Gear 0-3），
//       输出稀疏阈值、截断位数、近似乘法使能、快速 Rescale 使能。
//
// 寄存器映射：
//   0x00 GEAR_SEL     [2:0]   R/W  档位选择 0-3
//   0x04 THRESH_LOW   [15:0]  R/W  阈值低 16 位
//   0x08 THRESH_HIGH  [15:0]  R/W  阈值高 16 位（bit[1:0] 保留）
//   0x0C OVR_EN       [0]     R/W  阈值覆盖使能
//   0x10 GEAR_STATUS  [7:0]   R    当前档位 + 配置状态
//
// 4 档默认配置：
//   Gear 0: threshold=0,     trunc=0,  approx=0, fast_rs=0  (全精度基线)
//   Gear 1: threshold=4096,  trunc=0,  approx=0, fast_rs=0  (轻度稀疏)
//   Gear 2: threshold=16384, trunc=9,  approx=1, fast_rs=1  (中度稀疏)
//   Gear 3: threshold=65536, trunc=17, approx=1, fast_rs=1  (重度稀疏)
//
// 接口：AXI-Lite slave + 4 路档位输出（同步到 clk）
// =============================================================================

`timescale 1ns / 1ps

module gear_controller #(
    parameter int Q_WIDTH = 45
) (
    input  logic               clk,
    input  logic               rst_n,

    // AXI-Lite 从口
    input  logic               awvalid,
    output logic               awready,
    input  logic [4:0]         awaddr,
    input  logic               awburst,
    input  logic               wvalid,
    output logic               wready,
    input  logic [31:0]        wdata,
    output logic               bresp,
    output logic               bvalid,
    input  logic               bready,
    input  logic               arvalid,
    output logic               arready,
    input  logic [4:0]         araddr,
    output logic               rvalid,
    input  logic               rready,
    output logic [31:0]        rdata,

    // 档位输出（同步到 clk）
    output logic [Q_WIDTH-1:0] sparsity_threshold,
    output logic [7:0]         trunc_bits,
    output logic               use_approx_mult,
    output logic               use_fast_rescale,
    output logic [2:0]         gear_active
);

    // =========================================================================
    // 内部寄存器
    // =========================================================================
    logic [2:0]   gear_sel_reg;
    logic [15:0]  thresh_low_reg;
    logic [15:0]  thresh_high_reg;
    logic         ovr_en_reg;

    // =========================================================================
    // AXI-Lite 写地址锁存
    // =========================================================================
    logic [4:0]   awaddr_lat;
    logic         awvalid_lat;

    // =========================================================================
    // AXI-Lite 读地址锁存
    // =========================================================================
    logic [4:0]   araddr_lat;
    logic         arvalid_lat;

    // =========================================================================
    // 写通道：地址锁存 + 数据写入
    // =========================================================================
    assign awready = !awvalid_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awvalid_lat <= 1'b0;
            awaddr_lat  <= 5'h0;
        end else if (awvalid && !awvalid_lat) begin
            awvalid_lat <= 1'b1;
            awaddr_lat  <= awaddr;
        end else if (wvalid && awvalid_lat) begin
            awvalid_lat <= 1'b0;
        end
    end

    assign wready = awvalid_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gear_sel_reg    <= 3'h0;
            thresh_low_reg  <= 16'h0;
            thresh_high_reg <= 16'h0;
            ovr_en_reg      <= 1'b0;
        end else if (wvalid && awvalid_lat) begin
            case (awaddr_lat)
                5'h0: gear_sel_reg    <= wdata[2:0];
                5'h4: thresh_low_reg  <= wdata[15:0];
                5'h8: thresh_high_reg <= wdata[15:0];
                5'hC: ovr_en_reg      <= wdata[0];
                default: ;
            endcase
        end
    end

    // =========================================================================
    // 写响应
    // =========================================================================
    assign bvalid = wvalid && awvalid_lat;
    assign bresp  = 1'b0;  // OKAY

    // =========================================================================
    // 读通道：地址锁存 + 数据回读
    // =========================================================================
    assign arready = !arvalid_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arvalid_lat <= 1'b0;
            araddr_lat  <= 5'h0;
        end else if (arvalid && !arvalid_lat) begin
            arvalid_lat <= 1'b1;
            araddr_lat  <= araddr;
        end else if (rvalid && arvalid_lat) begin
            arvalid_lat <= 1'b0;
        end
    end

    assign rvalid = arvalid_lat;

    always_comb begin
        rdata = 32'h0;
        case (araddr_lat)
            5'h0:  rdata = {28'h0, gear_sel_reg};
            5'h4:  rdata = {16'h0, thresh_low_reg};
            5'h8:  rdata = {16'h0, thresh_high_reg};
            5'hC:  rdata = {31'h0, ovr_en_reg};
            5'h10: rdata = {24'h0, 3'h0, gear_sel_reg};  // GEAR_STATUS
            default: rdata = 32'h0;
        endcase
    end

    // =========================================================================
    // 档位配置计算（组合逻辑）
    // =========================================================================
    // 4 档阈值常量（用位拼接构造，避免参数算术在拼接中的 Vivado 兼容问题）
    localparam logic [Q_WIDTH-1:0] THRESH_GEAR0 = '0;          // 0
    localparam logic [Q_WIDTH-1:0] THRESH_GEAR1 = 'h1000;   // 4096 = 2^12
    localparam logic [Q_WIDTH-1:0] THRESH_GEAR2 = 'h4000;   // 16384 = 2^14
    localparam logic [Q_WIDTH-1:0] THRESH_GEAR3 = 'h10000;  // 65536 = 2^16

    logic [Q_WIDTH-1:0] threshold_raw;
    logic [7:0]         trunc_bits_raw;
    logic               approx_mult_raw;
    logic               fast_rescale_raw;

    // 手动覆盖值
    logic [Q_WIDTH-1:0] threshold_ovr;
    assign threshold_ovr = {thresh_high_reg[13:0], thresh_low_reg};

    always_comb begin
        // 默认值
        threshold_raw    = '0;
        trunc_bits_raw   = 8'h00;
        approx_mult_raw  = 1'b0;
        fast_rescale_raw = 1'b0;

        // 4 档配置表
        case (gear_sel_reg)
            3'h0: begin
                threshold_raw    = THRESH_GEAR0;
                trunc_bits_raw   = 8'h00;
                approx_mult_raw  = 1'b0;
                fast_rescale_raw = 1'b0;
            end
            3'h1: begin
                threshold_raw    = THRESH_GEAR1;
                trunc_bits_raw   = 8'h00;
                approx_mult_raw  = 1'b0;
                fast_rescale_raw = 1'b0;
            end
            3'h2: begin
                threshold_raw    = THRESH_GEAR2;  // 16384 = 2^14
                trunc_bits_raw   = 8'h09;
                approx_mult_raw  = 1'b1;
                fast_rescale_raw = 1'b1;
            end
            3'h3: begin
                threshold_raw    = THRESH_GEAR3;
                trunc_bits_raw   = 8'h11;                          // 17
                approx_mult_raw  = 1'b1;
                fast_rescale_raw = 1'b1;
            end
            default: begin
                threshold_raw    = '0;
                trunc_bits_raw   = 8'h00;
                approx_mult_raw  = 1'b0;
                fast_rescale_raw = 1'b0;
            end
        endcase
    end

    // 覆盖使能
    always_comb begin
        if (ovr_en_reg) begin
            sparsity_threshold = threshold_ovr;
        end else begin
            sparsity_threshold = threshold_raw;
        end
        trunc_bits       = trunc_bits_raw;
        use_approx_mult  = approx_mult_raw;
        use_fast_rescale = fast_rescale_raw;
        gear_active      = gear_sel_reg;
    end

endmodule
