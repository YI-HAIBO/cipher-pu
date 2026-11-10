// =============================================================================
// tb_trunc_mult.sv — M4-c 截断乘法器 TB
//
// 测试项：
//   1. trunc_bits=0: 标准乘法（与 full_product 一致）
//   2. trunc_bits=9: 截断 9 位（结果 = full_product >> 9）
//   3. trunc_bits=17: 截断 17 位（结果 = full_product >> 17）
//   4. 随机向量对比
//   5. 边界值（0, max, mixed）
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_trunc_mult;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam int INPUT_BITS = 45;

    // =========================================================================
    // 信号
    // =========================================================================
    logic [INPUT_BITS-1:0] a;
    logic [INPUT_BITS-1:0] b;
    logic [7:0]            trunc_bits;
    logic [INPUT_BITS-1:0] result;

    // =========================================================================
    // DUT
    // =========================================================================
    trunc_multiplier #(
        .INPUT_BITS(INPUT_BITS),
        .KEEP_BITS(45)
    ) u_dut (
        .a          (a),
        .b          (b),
        .trunc_bits (trunc_bits),
        .result     (result)
    );

    // =========================================================================
    // 测试计数器
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    // =========================================================================
    // 任务：检查
    // =========================================================================
    task automatic check(
        input  string  name,
        input  longint actual,
        input  longint expected
    );
        if (actual === expected) begin
            $display("  [PASS] %s: actual=%0d expected=%0d", name, actual, expected);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s: actual=%0d expected=%0d (diff=%0d)",
                     name, actual, expected, actual - expected);
            fail_count = fail_count + 1;
        end
    endtask

    // =========================================================================
    // 测试流程
    // =========================================================================
    logic [2*INPUT_BITS-1:0] full_prod;
    logic [INPUT_BITS-1:0] expected;
    logic                  monotonic;

    initial begin
        a = '0; b = '0; trunc_bits = '0;
        repeat (4) @(1ns);

        $display("=============================================================");
        $display("M4-c trunc_multiplier TB");
        $display("=============================================================");

        // -----------------------------------------------------------------
        // Test 1: trunc_bits=0, 标准乘法
        // -----------------------------------------------------------------
        $display("\n--- Test 1: trunc_bits=0 (standard) ---");

        // 1a: 小值
        a = 45'd1000; b = 45'd2000; trunc_bits = 8'd0;
        full_prod = a * b;
        expected = full_prod[89:45];
        check("small (1000*2000)", longint'(result), longint'(expected));

        // 1b: 中等值
        a = 45'd100000; b = 45'd200000; trunc_bits = 8'd0;
        full_prod = a * b;
        expected = full_prod[89:45];
        check("medium (100000*200000)", longint'(result), longint'(expected));

        // 1c: 大值
        a = 45'd1000000000; b = 45'd2000000000; trunc_bits = 8'd0;
        full_prod = a * b;
        expected = full_prod[89:45];
        check("large (1e9*2e9)", longint'(result), longint'(expected));

        // 1d: 边界 max
        a = {INPUT_BITS{1'b1}}; b = {INPUT_BITS{1'b1}}; trunc_bits = 8'd0;
        full_prod = a * b;
        expected = full_prod[89:45];
        check("max (2^45-1 * 2^45-1)", longint'(result), longint'(expected));

        // 1e: 零
        a = 45'd0; b = 45'd12345; trunc_bits = 8'd0;
        check("zero (0*12345)", longint'(result), longint'(0));

        // -----------------------------------------------------------------
        // Test 2: trunc_bits=9 (Gear 2)
        // -----------------------------------------------------------------
        $display("\n--- Test 2: trunc_bits=9 (Gear 2) ---");

        // 2a: 小值
        a = 45'd1000; b = 45'd2000; trunc_bits = 8'd9;
        full_prod = a * b;
        expected = full_prod[89:45];  // full_prod >> 9 取高 45 位
        // 实际 expected = (full_prod >> 9)[89:45] = full_prod[98:54]
        // 但 full_prod 只有 90 位，所以 expected = full_prod[89:54]
        // 用移位计算
        begin
            logic [2*INPUT_BITS-1:0] shifted;
            shifted = full_prod >> 9;
            expected = shifted[89:45];
        end
        check("trunc9 small", longint'(result), longint'(expected));

        // 2b: 中等值
        a = 45'd100000; b = 45'd200000; trunc_bits = 8'd9;
        full_prod = a * b;
        begin
            logic [2*INPUT_BITS-1:0] shifted;
            shifted = full_prod >> 9;
            expected = shifted[89:45];
        end
        check("trunc9 medium", longint'(result), longint'(expected));

        // 2c: 大值
        a = 45'd1000000000; b = 45'd2000000000; trunc_bits = 8'd9;
        full_prod = a * b;
        begin
            logic [2*INPUT_BITS-1:0] shifted;
            shifted = full_prod >> 9;
            expected = shifted[89:45];
        end
        check("trunc9 large", longint'(result), longint'(expected));

        // 2d: max
        a = {INPUT_BITS{1'b1}}; b = {INPUT_BITS{1'b1}}; trunc_bits = 8'd9;
        full_prod = a * b;
        begin
            logic [2*INPUT_BITS-1:0] shifted;
            shifted = full_prod >> 9;
            expected = shifted[89:45];
        end
        check("trunc9 max", longint'(result), longint'(expected));

        // -----------------------------------------------------------------
        // Test 3: trunc_bits=17 (Gear 3)
        // -----------------------------------------------------------------
        $display("\n--- Test 3: trunc_bits=17 (Gear 3) ---");

        // 3a: 小值
        a = 45'd1000; b = 45'd2000; trunc_bits = 8'd17;
        full_prod = a * b;
        begin
            logic [2*INPUT_BITS-1:0] shifted;
            shifted = full_prod >> 17;
            expected = shifted[89:45];
        end
        check("trunc17 small", longint'(result), longint'(expected));

        // 3b: 中等值
        a = 45'd100000; b = 45'd200000; trunc_bits = 8'd17;
        full_prod = a * b;
        begin
            logic [2*INPUT_BITS-1:0] shifted;
            shifted = full_prod >> 17;
            expected = shifted[89:45];
        end
        check("trunc17 medium", longint'(result), longint'(expected));

        // 3c: max
        a = {INPUT_BITS{1'b1}}; b = {INPUT_BITS{1'b1}}; trunc_bits = 8'd17;
        full_prod = a * b;
        begin
            logic [2*INPUT_BITS-1:0] shifted;
            shifted = full_prod >> 17;
            expected = shifted[89:45];
        end
        check("trunc17 max", longint'(result), longint'(expected));

        // -----------------------------------------------------------------
        // Test 4: 随机向量
        // -----------------------------------------------------------------
        $display("\n--- Test 4: Random vectors ---");

        for (int i = 0; i < 10; i++) begin
            a = $urandom() % (1 << 30);
            b = $urandom() % (1 << 30);
            trunc_bits = (i % 3 == 0) ? 8'd0 : ((i % 3 == 1) ? 8'd9 : 8'd17);

            full_prod = a * b;
            begin
                logic [2*INPUT_BITS-1:0] shifted;
                case (trunc_bits)
                    8'd0:  shifted = full_prod;
                    8'd9:  shifted = full_prod >> 9;
                    8'd17: shifted = full_prod >> 17;
                    default: shifted = full_prod;
                endcase
                expected = shifted[89:45];
            end
            begin
                string rname;
                $sformatf(rname, "random[%0d] trunc=%0d", i, trunc_bits);
                check(rname, longint'(result), longint'(expected));
            end
        end

        // -----------------------------------------------------------------
        // Test 5: 单调性检查
        // -----------------------------------------------------------------
        $display("\n--- Test 5: Monotonicity check ---");
        // 对于固定 b，a 增大时 result 应单调不减（对于 trunc_bits=0）
        trunc_bits = 8'd0;
        b = 45'd1000000;
        begin
            logic [INPUT_BITS-1:0] prev_result;
            prev_result = '0;
            monotonic = 1'b1;
            for (int a_val = 0; a_val < 100000; a_val = a_val + 10000) begin
                a = 45'(a_val);
                if (result < prev_result) begin
                    monotonic = 1'b0;
                end
                prev_result = result;
            end
            check("monotonic (trunc=0)", monotonic, 1'b1);
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
