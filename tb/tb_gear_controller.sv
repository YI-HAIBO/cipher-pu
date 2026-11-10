// =============================================================================
// tb_gear_controller.sv — M4-a 档位控制器 TB
//
// 测试项：
//   1. 复位后默认值（Gear 0）
//   2. 4 档配置写入 → 回读 → 输出验证
//   3. 阈值覆盖测试（OVR_EN=1）
//   4. 无效地址访问
//   5. 连续读写
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_gear_controller;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam int Q_WIDTH = 45;

    // =========================================================================
    // 信号
    // =========================================================================
    logic               clk;
    logic               rst_n;

    // AXI-Lite
    logic               awvalid, awready;
    logic [4:0]         awaddr;
    logic               awburst;
    logic               wvalid, wready;
    logic [31:0]        wdata;
    logic               bresp, bvalid;
    logic               bready;
    logic               arvalid, arready;
    logic [4:0]         araddr;
    logic               rvalid, rready;
    logic [31:0]        rdata;

    // 档位输出
    logic [Q_WIDTH-1:0] sparsity_threshold;
    logic [7:0]         trunc_bits;
    logic               use_approx_mult;
    logic               use_fast_rescale;
    logic [2:0]         gear_active;

    // =========================================================================
    // DUT
    // =========================================================================
    gear_controller #(
        .Q_WIDTH(Q_WIDTH)
    ) u_dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .awvalid           (awvalid),
        .awready           (awready),
        .awaddr            (awaddr),
        .awburst           (awburst),
        .wvalid            (wvalid),
        .wready            (wready),
        .wdata             (wdata),
        .bresp             (bresp),
        .bvalid            (bvalid),
        .bready            (bready),
        .arvalid           (arvalid),
        .arready           (arready),
        .araddr            (araddr),
        .rvalid            (rvalid),
        .rready            (rready),
        .rdata             (rdata),
        .sparsity_threshold(sparsity_threshold),
        .trunc_bits        (trunc_bits),
        .use_approx_mult   (use_approx_mult),
        .use_fast_rescale  (use_fast_rescale),
        .gear_active       (gear_active)
    );

    // =========================================================================
    // 时钟生成
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // 测试计数器
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    // =========================================================================
    // 任务：AXI-Lite 写
    // =========================================================================
    task automatic axi_write(
        input logic [4:0] addr,
        input logic [31:0] data
    );
        @(posedge clk);
        #1;
        awvalid = 1'b1;
        awaddr  = addr;
        awburst = 1'b0;
        wvalid  = 1'b1;
        wdata   = data;
        bready  = 1'b1;
        @(posedge clk);   // DUT: awvalid_lat<=1, awaddr_lat<=addr
        #1;
        @(posedge clk);   // DUT: wvalid && awvalid_lat -> 写寄存器 + 清 awvalid_lat
        #1;
        awvalid = 1'b0;
        wvalid  = 1'b0;
        bready  = 1'b0;
    endtask

    // =========================================================================
    // 任务：AXI-Lite 读
    // =========================================================================
    task automatic axi_read(
        input  logic [4:0] addr,
        output logic [31:0] data
    );
        @(posedge clk);
        #1;
        arvalid = 1'b1;
        araddr  = addr;
        rready  = 1'b1;
        @(posedge clk);   // DUT: arvalid_lat<=1, araddr_lat<=addr
        #1;
        @(posedge clk);   // rvalid=1, rdata 组合有效
        #1;
        data    = rdata;
        arvalid = 1'b0;
        rready  = 1'b0;
    endtask

    // =========================================================================
    // 任务：检查
    // =========================================================================
    task automatic check(
        input  string        name,
        input  logic         actual,
        input  logic         expected
    );
        if (actual === expected) begin
            $display("  [PASS] %s: actual=%b expected=%b", name, actual, expected);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s: actual=%b expected=%b", name, actual, expected);
            fail_count = fail_count + 1;
        end
    endtask

    task automatic check_val(
        input  string  name,
        input  longint actual,
        input  longint expected
    );
        if (actual === expected) begin
            $display("  [PASS] %s: actual=%0d expected=%0d", name, actual, expected);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s: actual=%0d expected=%0d", name, actual, expected);
            fail_count = fail_count + 1;
        end
    endtask

    // =========================================================================
    // 测试流程
    // =========================================================================
    logic [31:0] read_data;

    initial begin
        // 初始化
        rst_n  = 1'b0;
        awvalid = 1'b0;
        wvalid  = 1'b0;
        arvalid = 1'b0;
        bready  = 1'b0;
        rready  = 1'b0;
        awaddr  = 5'h0;
        wdata   = 32'h0;
        araddr  = 5'h0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("=============================================================");
        $display("M4-a gear_controller TB");
        $display("=============================================================");

        // -----------------------------------------------------------------
        // Test 1: 复位后默认值（Gear 0）
        // -----------------------------------------------------------------
        $display("\n--- Test 1: Reset defaults (Gear 0) ---");
        check("gear_active", gear_active, 3'h0);
        check_val("sparsity_threshold", longint'(sparsity_threshold), longint'(0));
        check_val("trunc_bits", longint'(trunc_bits), longint'(0));
        check("use_approx_mult", use_approx_mult, 1'b0);
        check("use_fast_rescale", use_fast_rescale, 1'b0);

        // -----------------------------------------------------------------
        // Test 2: Gear 1 配置
        // -----------------------------------------------------------------
        $display("\n--- Test 2: Configure Gear 1 ---");
        axi_write(5'h0, 32'd1);  // GEAR_SEL = 1
        repeat (2) @(posedge clk);
        check("gear_active", gear_active, 3'h1);
        check_val("sparsity_threshold", longint'(sparsity_threshold), longint'(4096));
        check_val("trunc_bits", longint'(trunc_bits), longint'(0));
        check("use_approx_mult", use_approx_mult, 1'b0);
        check("use_fast_rescale", use_fast_rescale, 1'b0);

        // -----------------------------------------------------------------
        // Test 3: Gear 2 配置
        // -----------------------------------------------------------------
        $display("\n--- Test 3: Configure Gear 2 ---");
        axi_write(5'h0, 32'd2);  // GEAR_SEL = 2
        repeat (2) @(posedge clk);
        check("gear_active", gear_active, 3'h2);
        check_val("sparsity_threshold", longint'(sparsity_threshold), longint'(16384));
        check_val("trunc_bits", longint'(trunc_bits), longint'(9));
        check("use_approx_mult", use_approx_mult, 1'b1);
        check("use_fast_rescale", use_fast_rescale, 1'b1);

        // -----------------------------------------------------------------
        // Test 4: Gear 3 配置
        // -----------------------------------------------------------------
        $display("\n--- Test 4: Configure Gear 3 ---");
        axi_write(5'h0, 32'd3);  // GEAR_SEL = 3
        repeat (2) @(posedge clk);
        check("gear_active", gear_active, 3'h3);
        check_val("sparsity_threshold", longint'(sparsity_threshold), longint'(65536));
        check_val("trunc_bits", longint'(trunc_bits), longint'(17));
        check("use_approx_mult", use_approx_mult, 1'b1);
        check("use_fast_rescale", use_fast_rescale, 1'b1);

        // -----------------------------------------------------------------
        // Test 5: 阈值覆盖（OVR_EN=1, 手动阈值=12345）
        // -----------------------------------------------------------------
        $display("\n--- Test 5: Threshold override ---");
        axi_write(5'h4, 32'd12345);           // THRESH_LOW = 12345
        axi_write(5'h8, 32'h0);               // THRESH_HIGH = 0
        axi_write(5'hC, 32'd1);               // OVR_EN = 1
        axi_write(5'h0, 32'd1);               // GEAR_SEL = 1
        repeat (2) @(posedge clk);
        check_val("sparsity_threshold (override)", longint'(sparsity_threshold), longint'(12345));

        // 关闭覆盖
        axi_write(5'hC, 32'd0);               // OVR_EN = 0
        repeat (2) @(posedge clk);
        check_val("sparsity_threshold (default)", longint'(sparsity_threshold), longint'(4096));

        // -----------------------------------------------------------------
        // Test 6: 回读测试
        // -----------------------------------------------------------------
        $display("\n--- Test 6: Register readback ---");
        axi_write(5'h0, 32'd2);  // GEAR_SEL = 2
        repeat (2) @(posedge clk);
        axi_read(5'h0, read_data);
        check_val("GEAR_SEL readback", longint'(read_data), longint'(2));

        axi_read(5'h10, read_data);
        check_val("GEAR_STATUS readback", longint'(read_data[2:0]), longint'(2));

        // -----------------------------------------------------------------
        // Test 7: 连续切换
        // -----------------------------------------------------------------
        $display("\n--- Test 7: Continuous gear switching ---");
        for (int g = 0; g < 4; g++) begin
            axi_write(5'h0, 32'(g));
            repeat (2) @(posedge clk);
            check_val("gear_active (cont)", longint'(gear_active), longint'(g));
        end

        // -----------------------------------------------------------------
        // 结果汇总
        // -----------------------------------------------------------------
        $display("\n=============================================================");
        $display("Results: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("ALL PASS");
        end else begin
            $display("FAIL (%0d failures)", fail_count);
        end
        $display("=============================================================");
        $finish;
    end

endmodule
