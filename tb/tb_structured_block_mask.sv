//=============================================================================
// tb_structured_block_mask.sv - 结构化块剪枝引擎测试平台（v3 重写）
//
// 验证点：
//   T1 复位状态
//   T2 mask 加载（keep/prune 写入 + mask_full 未满）
//   T3 基本剪枝：keep 块透传、prune 块丢弃（输出顺序/数值正确）
//   T4 背压：data_ready_in 反压期间不丢数、不乱序
//   T5 连续多块混合流
// 驱动约定：negedge 驱动（posedge 采样前已稳定），输出监控在 posedge 采集。
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_structured_block_mask;

    localparam int BLOCK_SIZE     = 16;
    localparam int MAX_BLOCKS     = 16;
    localparam int BLOCK_KEY_BITS = 4;
    localparam int ARRAY_WIDTH    = 16;
    localparam int IDX_W          = $clog2(MAX_BLOCKS);

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // DUT 信号
    logic                     data_valid_in, data_ready_out;
    logic [ARRAY_WIDTH-1:0]   data_in;
    logic                     data_valid_out, data_ready_in;
    logic [ARRAY_WIDTH-1:0]   data_out;
    logic [BLOCK_KEY_BITS-1:0] block_type;
    logic [15:0]              block_index;
    logic                     mask_update_en;
    logic                     block_valid, block_skip, mask_full;

    structured_block_mask #(
        .BLOCK_SIZE(BLOCK_SIZE), .MAX_BLOCKS(MAX_BLOCKS),
        .BLOCK_KEY_BITS(BLOCK_KEY_BITS), .ARRAY_WIDTH(ARRAY_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .data_valid_in(data_valid_in), .data_ready_out(data_ready_out), .data_in(data_in),
        .data_valid_out(data_valid_out), .data_ready_in(data_ready_in), .data_out(data_out),
        .block_type(block_type), .block_index(block_index), .mask_update_en(mask_update_en),
        .block_valid(block_valid), .block_skip(block_skip), .mask_full(mask_full)
    );

    // 输出监控（posedge 采集）
    logic [ARRAY_WIDTH-1:0] out_buf [0:255];
    int out_cnt = 0;
    int skip_cnt = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (block_skip) skip_cnt <= skip_cnt + 1;
            if (data_valid_out && data_ready_in) begin
                out_buf[out_cnt] <= data_out;
                out_cnt <= out_cnt + 1;
            end
        end
    end

    int pass_count = 0;
    int fail_count = 0;

    // mask 加载一拍
    task load_mask(input int idx, input bit keep);
        begin
            @(negedge clk);
            block_index    = idx[15:0];
            data_in        = keep ? ARRAY_WIDTH'(1) : ARRAY_WIDTH'(0);
            mask_update_en = 1;
            data_valid_in  = 0;
            @(posedge clk);
            @(negedge clk);
            mask_update_en = 0;
        end
    endtask

    // 推入一串数据拍（negedge 驱动，一拍一拍连续）
    task push_beats(input int bidx_arr [0:63], input logic [ARRAY_WIDTH-1:0] darr [0:63],
                    input int n, input bit backpressure);
        int i, stall;
        begin
            data_ready_in = 1;
            i = 0; stall = 0;
            while (i < n) begin
                @(negedge clk);
                data_valid_in = 1;
                block_index   = bidx_arr[i][15:0];
                data_in       = darr[i];
                block_type    = BLOCK_KEY_BITS'(i % 4);
                // 背压：第 2 拍(i==1)拉低 ready 3 个周期（临时）
                if (backpressure && (i == 1) && (stall < 3)) begin
                    data_ready_in = 0;
                    stall = stall + 1;
                end else begin
                    data_ready_in = 1;
                end
                @(posedge clk);            // DUT 采样
                if (data_ready_out) i = i + 1;   // 仅当 DUT 接收才推进
            end
            @(negedge clk);
            data_valid_in = 0;
            data_ready_in = 1;
        end
    endtask

    // 排空流水，等末拍输出
    task drain(input int cyc);
        int i;
        begin
            for (i = 0; i < cyc; i++) @(posedge clk);
        end
    endtask

    // 期望 kept 序列校验
    task expect_kept(input logic [ARRAY_WIDTH-1:0] exp [0:63], input int n, input string tag);
        int i;
        begin
            if (out_cnt != n) begin
                $display("  FAIL %s: out_cnt=%0d expected=%0d", tag, out_cnt, n);
                fail_count = fail_count + 1;
            end else begin
                for (i = 0; i < n; i++) begin
                    if (out_buf[i] !== exp[i]) begin
                        $display("  FAIL %s: out[%0d]=%0h expected=%0h", tag, i, out_buf[i], exp[i]);
                        fail_count = fail_count + 1;
                        return;
                    end
                end
                $display("  PASS %s: %0d kept coeffs match", tag, n);
                pass_count = pass_count + 1;
            end
        end
    endtask

    // 测试数据
    int bidx1 [0:63];
    logic [ARRAY_WIDTH-1:0] d1 [0:63];
    logic [ARRAY_WIDTH-1:0] exp1 [0:63];
    logic [ARRAY_WIDTH-1:0] exp2 [0:63];

    initial begin
        // 初始化
        rst_n = 0; data_valid_in = 0; data_in = 0; data_ready_in = 1;
        block_type = 0; block_index = 0; mask_update_en = 0;
        out_cnt = 0; skip_cnt = 0;

        $display("=== T1: 复位状态 ===");
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        if (!data_valid_out && !block_skip && !mask_full) begin
            $display("  PASS T1: 复位干净");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL T1: vld=%b skip=%b full=%b", data_valid_out, block_skip, mask_full);
            fail_count = fail_count + 1;
        end

        $display("=== T2: mask 加载（块0/2 keep，块1/3 prune）===");
        load_mask(0, 1);
        load_mask(1, 0);
        load_mask(2, 1);
        load_mask(3, 0);
        @(posedge clk);
        if (!mask_full) begin
            $display("  PASS T2: mask 加载完成，mask_full=0");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL T2: mask_full 异常");
            fail_count = fail_count + 1;
        end

        $display("=== T3: 基本剪枝 ===");
        // 输入序列：块0(keep) 0xA5A5, 块1(prune) 0x1234, 块2(keep) 0xBEEF, 块3(prune) 0x0F0F
        bidx1[0]=0; d1[0]=16'hA5A5;
        bidx1[1]=1; d1[1]=16'h1234;
        bidx1[2]=2; d1[2]=16'hBEEF;
        bidx1[3]=3; d1[3]=16'h0F0F;
        exp1[0]=16'hA5A5; exp1[1]=16'hBEEF;
        push_beats(bidx1, d1, 4, 0);
        drain(6);
        expect_kept(exp1, 2, "T3");
        if (skip_cnt == 2) begin
            $display("  PASS T3: skip_cnt=%0d (期望 2)", skip_cnt);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL T3: skip_cnt=%0d 期望 2", skip_cnt);
            fail_count = fail_count + 1;
        end

        $display("=== T4: 背压（data_ready_in 反压）===");
        out_cnt = 0; skip_cnt = 0;
        // 8 拍混合流：块0..3 各两次
        for (int i = 0; i < 8; i++) begin
            bidx1[i] = i % 4;
            d1[i]    = 16'h1000 + ARRAY_WIDTH'(i);
        end
        // 期望 kept：块0,2 的拍 → i=0,2,4,6
        exp2[0]=16'h1000; exp2[1]=16'h1002; exp2[2]=16'h1004; exp2[3]=16'h1006;
        push_beats(bidx1, d1, 8, 1);
        drain(8);
        expect_kept(exp2, 4, "T4");

        $display("=== T5: 连续长流 ===");
        out_cnt = 0; skip_cnt = 0;
        for (int i = 0; i < 40; i++) begin
            bidx1[i] = (i % 2 == 0) ? 2 : 3;   // 偶数 keep(块2)，奇数 prune(块3)
            d1[i]    = 16'h2000 + ARRAY_WIDTH'(i);
        end
        for (int i = 0; i < 20; i++) exp1[i] = 16'h2000 + ARRAY_WIDTH'(2*i);
        push_beats(bidx1, d1, 40, 0);
        drain(8);
        expect_kept(exp1, 20, "T5");

        $display("\n============================================================");
        $display("测试总结：PASS: %0d  FAIL: %0d  TOTAL: %0d", pass_count, fail_count, pass_count+fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("✅ 全部测试通过");
        else                 $display("❌ 存在失败用例");
        #100;
        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("ERROR: 仿真超时！");
        $finish;
    end

endmodule

`default_nettype wire
