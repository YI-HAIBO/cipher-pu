//=============================================================================
// tb_quant_sparse_combine.sv - 低比特量化+稀疏组合引擎测试平台（v3 重写）
//
// 验证点：
//   T1 复位状态
//   T2 量化正确性：out = in >> (INPUT_WIDTH-OUTPUT_WIDTH)
//   T3 稀疏判定：in <= threshold → sparse_enable=1 且不出数
//   T4 边界：q==0 但 in>threshold 仍保留（稀疏由阈值判定而非零值判定）
//   T5 混合流：输出序列/数值正确 + sparse 计数
//   T6 背压：data_ready_in 反压不丢数
//   T7 mask_valid / quant_enable 拍数统计
// 驱动约定：negedge 驱动，posedge 采集。
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_quant_sparse_combine;

    localparam int INPUT_WIDTH    = 16;
    localparam int OUTPUT_WIDTH   = 8;
    localparam int THRESHOLD_BITS = 8;
    localparam int MASK_DEPTH     = 16;
    localparam int SHIFT          = INPUT_WIDTH - OUTPUT_WIDTH;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic                          data_valid_in, data_ready_out;
    logic [INPUT_WIDTH-1:0]        data_in;
    logic                          data_valid_out, data_ready_in;
    logic [OUTPUT_WIDTH-1:0]       data_out;
    logic                          update_en;
    logic [THRESHOLD_BITS-1:0]     threshold;
    logic                          sparse_enable, quant_enable, mask_valid;

    quant_sparse_combine #(
        .INPUT_WIDTH(INPUT_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .THRESHOLD_BITS(THRESHOLD_BITS), .MASK_DEPTH(MASK_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .data_valid_in(data_valid_in), .data_ready_out(data_ready_out), .data_in(data_in),
        .data_valid_out(data_valid_out), .data_ready_in(data_ready_in), .data_out(data_out),
        .update_en(update_en), .threshold(threshold),
        .sparse_enable(sparse_enable), .quant_enable(quant_enable), .mask_valid(mask_valid)
    );

    // 输出监控
    logic [OUTPUT_WIDTH-1:0] out_buf [0:255];
    int out_cnt = 0;
    int sparse_cnt = 0;
    int mask_cnt = 0;
    int quant_cnt = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (sparse_enable) sparse_cnt <= sparse_cnt + 1;
            if (mask_valid)     mask_cnt   <= mask_cnt + 1;
            if (quant_enable)   quant_cnt  <= quant_cnt + 1;
            if (data_valid_out && data_ready_in) begin
                out_buf[out_cnt] <= data_out;
                out_cnt <= out_cnt + 1;
            end
        end
    end

    int pass_count = 0;
    int fail_count = 0;

    logic [THRESHOLD_BITS-1:0] THR;

    task push_beats(input logic [INPUT_WIDTH-1:0] darr [0:63], input int n, input bit bp);
        int i, stall;
        begin
            data_ready_in = 1;
            i = 0; stall = 0;
            while (i < n) begin
                @(negedge clk);
                data_valid_in = 1;
                data_in = darr[i];
                // 背压：喂第 3 拍(i==2)时拉低 ready 3 个周期（临时，非永久）
                if (bp && (i == 2) && (stall < 3)) begin
                    data_ready_in = 0;
                    stall = stall + 1;
                end else begin
                    data_ready_in = 1;
                end
                @(posedge clk);
                if (data_ready_out) i = i + 1;   // 仅当 DUT 接收才推进（防重复/丢失）
            end
            @(negedge clk);
            data_valid_in = 0;
            data_ready_in = 1;
        end
    endtask

    task drain(input int cyc);
        int i; begin for (i=0;i<cyc;i++) @(posedge clk); end
    endtask

    logic [INPUT_WIDTH-1:0] din [0:63];
    logic [OUTPUT_WIDTH-1:0] exp [0:63];
    int exp_n;

    // 依据阈值/移位移位构建期望 kept 序列
    task build_expected(input int n);
        int i; begin
            exp_n = 0;
            for (i=0;i<n;i++) begin
                if (!(din[i] <= {{(INPUT_WIDTH-THRESHOLD_BITS){1'b0}}, THR}))
                    exp[exp_n++] = (din[i] >> SHIFT);
            end
        end
    endtask

    task expect_seq(input string tag);
        int i; begin
            if (out_cnt != exp_n) begin
                $display("  FAIL %s: out_cnt=%0d expected=%0d", tag, out_cnt, exp_n);
                fail_count++; return;
            end
            for (i=0;i<exp_n;i++) if (out_buf[i] !== exp[i]) begin
                $display("  FAIL %s: out[%0d]=%0h expected=%0h", tag, i, out_buf[i], exp[i]);
                fail_count++; return;
            end
            $display("  PASS %s: %0d kept values match", tag, exp_n);
            pass_count++;
        end
    endtask

    initial begin
        rst_n=0; data_valid_in=0; data_in=0; data_ready_in=1; update_en=0;
        THR = 8'h10; threshold = THR;
        out_cnt=0; sparse_cnt=0; mask_cnt=0; quant_cnt=0;

        $display("=== T1: 复位状态 ===");
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        if (!data_valid_out && !sparse_enable) begin
            $display("  PASS T1: 复位干净"); pass_count++;
        end else begin
            $display("  FAIL T1"); fail_count++;
        end

        $display("=== T2: 单拍量化 0x1234 -> 0x12 ===");
        din[0]=16'h1234; build_expected(1);
        push_beats(din,1,0); drain(4);
        expect_seq("T2");
        if (out_cnt==1 && out_buf[0]==16'h12) begin
            $display("  PASS T2: 量化值 = %0h", out_buf[0]); pass_count++;
        end else begin
            $display("  FAIL T2: got %0h", (out_cnt>0)?out_buf[0]:'x); fail_count++;
        end

        $display("=== T3: 单拍稀疏 0x0005 <= thr ===");
        out_cnt=0; sparse_cnt=0;
        din[0]=16'h0005;
        push_beats(din,1,0); drain(4);
        if (sparse_cnt>=1 && out_cnt==0) begin
            $display("  PASS T3: 稀疏跳过，无输出"); pass_count++;
        end else begin
            $display("  FAIL T3: sparse_cnt=%0d out_cnt=%0d", sparse_cnt, out_cnt); fail_count++;
        end

        $display("=== T4: 边界 q==0 但 in>thr 仍保留（0x00FF）===");
        out_cnt=0; sparse_cnt=0;
        din[0]=16'h00FF; build_expected(1);
        push_beats(din,1,0); drain(4);
        if (out_cnt==1 && out_buf[0]==8'h00 && sparse_cnt==0) begin
            $display("  PASS T4: 输出 0x00 且非稀疏"); pass_count++;
        end else begin
            $display("  FAIL T4: out_cnt=%0d sparse_cnt=%0d", out_cnt, sparse_cnt); fail_count++;
        end

        $display("=== T5: 混合流 ===");
        out_cnt=0; sparse_cnt=0;
        din[0]=16'h1234; din[1]=16'h0005; din[2]=16'h00FF; din[3]=16'h0200;
        din[4]=16'h0010; din[5]=16'hABCD;
        build_expected(6);
        push_beats(din,6,0); drain(6);
        expect_seq("T5");
        if (sparse_cnt==2) begin
            $display("  PASS T5: sparse_cnt=%0d (期望 2)", sparse_cnt); pass_count++;
        end else begin
            $display("  FAIL T5: sparse_cnt=%0d 期望 2", sparse_cnt); fail_count++;
        end

        $display("=== T6: 背压 ===");
        out_cnt=0; sparse_cnt=0;
        din[0]=16'h1234; din[1]=16'h0005; din[2]=16'h00FF; din[3]=16'h0200;
        din[4]=16'h0010; din[5]=16'hABCD; din[6]=16'h0F0F; din[7]=16'h1010;
        build_expected(8);
        push_beats(din,8,1); drain(8);
        expect_seq("T6");

        $display("=== T7: mask/quant 拍数（T2-T6 共处理 17 拍，背压只增不减）===");
        if (mask_cnt >= 17 && quant_cnt >= 17) begin
            $display("  PASS T7: mask_cnt=%0d quant_cnt=%0d (>=17)", mask_cnt, quant_cnt); pass_count++;
        end else begin
            $display("  FAIL T7: mask_cnt=%0d quant_cnt=%0d 期望 >=17", mask_cnt, quant_cnt); fail_count++;
        end

        $display("\n============================================================");
        $display("测试总结：PASS: %0d  FAIL: %0d  TOTAL: %0d", pass_count, fail_count, pass_count+fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("✅ 全部测试通过");
        else                 $display("❌ 存在失败用例");
        #100; $finish;
    end

    initial begin
        #200000; $display("ERROR: 仿真超时！"); $finish;
    end

endmodule

`default_nettype wire
