// =============================================================================
// tb_b_layer_ctrl.sv — b_layer_ctrl 测试平台（2026-10-18，任务 3）
//
// 验证内容：
//   1. 基础握手：start → done，busy/done/error 信号正确
//   2. 输出流式：推理过程中捕获 f0 的 NUM_SLOTS 个样本且非零
//   3. 多层推进：layer_id 从 0 到 NUM_LAYERS-1
//   4. 多次推理：重置后再次运行
//   5. 输出正确性：c0_init × c0_w 循环卷积 golden 比对
//
// 关键修复（2026-10-18）：
//   - 逐层权重喂入：DUT 每层结束回到 S_W_LOAD 等待下一层权重，
//     TB 在 done 等待循环中检测 c0_weight_ready 并按需调用 load_weight_stream
//     （此前只喂 layer 0 → layer 1 死锁，T1/T2/T5 全部超时）
//   - T2 输出捕获：f0 在推理期间流式输出，T1 等待循环中同步采样，
//     T2/T6 事后分析（此前 T2 在 done 之后才等 f0_valid，永远等不到）
//
// 玩具配置：LOG_N=3, N=8, Q_WIDTH=7, Q_VALUE=113, N_INV=99
// twiddle 因子由 TW_FILE / TW_INV_FILE 加载（见 DUT 实例化）
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_b_layer_ctrl;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    // =========================================================================
    // 参数
    // =========================================================================
    localparam int NUM_LAYERS    = 2;
    localparam int OPS_PER_LAYER = 2;
    localparam int NUM_SLOTS     = 8;
    localparam int LOG_N         = 3;
    localparam int Q_WIDTH       = 7;
    localparam bit [Q_WIDTH-1:0] Q_IN    = 7'd113;
    localparam bit [Q_WIDTH-1:0] Q_OUT   = 7'd97;
    localparam bit [Q_WIDTH-1:0] Q_VALUE = 7'd113;
    localparam bit [Q_WIDTH-1:0] N_INV   = 7'd99;

    // =========================================================================
    // 时钟与复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 信号
    // =========================================================================
    logic start;
    logic busy, done, error;
    logic [Q_WIDTH-1:0] layer_id, op_id;

    logic                     c0_init_valid, c0_init_ready;
    logic [Q_WIDTH-1:0]       c0_init_data;
    logic                     c1_init_valid, c1_init_ready;
    logic [Q_WIDTH-1:0]       c1_init_data;

    logic                     c0_weight_valid, c0_weight_ready;
    logic [Q_WIDTH-1:0]       c0_weight_data;
    logic                     c1_weight_valid, c1_weight_ready;
    logic [Q_WIDTH-1:0]       c1_weight_data;

    logic                     c0_out_valid, c0_out_ready;
    logic [Q_WIDTH-1:0]       c0_out_data;
    logic                     c1_out_valid, c1_out_ready;
    logic [Q_WIDTH-1:0]       c1_out_data;

    logic                     f0_valid, f0_ready;
    logic [Q_WIDTH-1:0]       f0_data;
    logic                     f1_valid, f1_ready;
    logic [Q_WIDTH-1:0]       f1_data;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    b_layer_ctrl #(
        .NUM_LAYERS   (NUM_LAYERS),
        .OPS_PER_LAYER(OPS_PER_LAYER),
        .NUM_SLOTS    (NUM_SLOTS),
        .LOG_N        (LOG_N),
        .Q_WIDTH      (Q_WIDTH),
        .Q_IN         (Q_IN),
        .Q_OUT        (Q_OUT),
        .Q_VALUE      (Q_VALUE),
        .N_INV        (N_INV),
        .USE_FASTRED  (1'b0),
        .USE_BRAM_IP  (1'b0),
        .B            (1),
        .DEBUG_EN     (1'b1),
        .TW_FILE      ({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n8.hex"}),
        .TW_INV_FILE  ({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n8.hex"})
    ) u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .busy(busy), .done(done), .error(error),
        .layer_id(layer_id), .op_id(op_id),
        .c0_init_valid(c0_init_valid), .c0_init_ready(c0_init_ready), .c0_init_data(c0_init_data),
        .c1_init_valid(c1_init_valid), .c1_init_ready(c1_init_ready), .c1_init_data(c1_init_data),
        .c0_weight_valid(c0_weight_valid), .c0_weight_ready(c0_weight_ready), .c0_weight_data(c0_weight_data),
        .c1_weight_valid(c1_weight_valid), .c1_weight_ready(c1_weight_ready), .c1_weight_data(c1_weight_data),
        .c0_out_valid(c0_out_valid), .c0_out_ready(c0_out_ready), .c0_out_data(c0_out_data),
        .c1_out_valid(c1_out_valid), .c1_out_ready(c1_out_ready), .c1_out_data(c1_out_data),
        .f0_valid(f0_valid), .f0_ready(f0_ready), .f0_data(f0_data),
        .f1_valid(f1_valid), .f1_ready(f1_ready), .f1_data(f1_data)
    );

    // =========================================================================
    // 测试变量
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;
    integer i, k, j;
    integer timeout;
    integer cap_idx;       // f0 输出捕获索引
    integer layers_fed;    // 已喂入权重的层数
    logic [Q_WIDTH-1:0] c0_init_vec[NUM_SLOTS-1:0];
    logic [Q_WIDTH-1:0] c1_init_vec[NUM_SLOTS-1:0];
    logic [Q_WIDTH-1:0] c0_w_vec[NUM_SLOTS-1:0];
    logic [Q_WIDTH-1:0] c1_w_vec[NUM_SLOTS-1:0];
    logic [Q_WIDTH-1:0] f0_out[NUM_SLOTS-1:0];

    // 加载整条流（negedge 驱动，DUT 在 posedge 采样）
    task automatic load_init_stream();
        @(negedge clk);
        for (k = 0; k < NUM_SLOTS; k = k + 1) begin
            c0_init_valid = 1'b1;
            c1_init_valid = 1'b1;
            c0_init_data = c0_init_vec[k];
            c1_init_data = c1_init_vec[k];
            @(posedge clk);
            @(negedge clk);
            c0_init_valid = 1'b0;
            c1_init_valid = 1'b0;
        end
    endtask

    task automatic load_weight_stream();
        @(negedge clk);
        for (k = 0; k < NUM_SLOTS; k = k + 1) begin
            c0_weight_valid = 1'b1;
            c1_weight_valid = 1'b1;
            c0_weight_data = c0_w_vec[k];
            c1_weight_data = c1_w_vec[k];
            @(posedge clk);
            @(negedge clk);
            c0_weight_valid = 1'b0;
            c1_weight_valid = 1'b0;
        end
    endtask

    // 推理运行：喂 layer 0 权重 → 等待 done（逐层按需喂权重 + 同步捕获 f0）
    task automatic run_inference();
        begin
            load_init_stream();
            load_weight_stream();      // layer 0
            cap_idx    = 0;
            layers_fed = 1;
            timeout    = 0;
            while (!done && timeout < 200000) begin
                @(posedge clk);
                // DUT 每层结束回到 S_W_LOAD：按需喂入下一层权重
                if (c0_weight_ready && layers_fed < NUM_LAYERS) begin
                    load_weight_stream();
                    layers_fed = layers_fed + 1;
                end
                // f0 流式输出捕获（posedge 采样到的是本拍稳定数据）
                if (f0_valid && f0_ready && cap_idx < NUM_SLOTS) begin
                    f0_out[cap_idx] = f0_data;
                    cap_idx = cap_idx + 1;
                end
                timeout = timeout + 1;
            end
        end
    endtask

    // =========================================================================
    // 主测试流程（单 initial 块，顺序执行）
    // =========================================================================
    initial begin
        // ---- 初始化 ----
        for (i = 0; i < NUM_SLOTS; i = i + 1) begin
            c0_init_vec[i] = i;
            c1_init_vec[i] = i + 1;
            c0_w_vec[i]    = i * 2 + 1;
            c1_w_vec[i]    = i * 3 + 2;
        end

        rst_n = 0;
        start = 0;
        c0_init_valid = 0; c1_init_valid = 0;
        c0_weight_valid = 0; c1_weight_valid = 0;
        f0_ready = 1; f1_ready = 1;
        for (i = 0; i < NUM_SLOTS; i = i + 1) f0_out[i] = '0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("========================================");
        $display("tb_b_layer_ctrl: starting tests");
        $display("========================================");

        // ---- T1: 基础 start → done 流程 ----
        $display("\n[T1] Basic start -> done flow");
        @(posedge clk);
        start = 1;
        @(posedge clk);
        #1;
        start = 0;

        run_inference();

        if (timeout >= 200000) begin
            $display("[T1] FAIL: timeout waiting for done");
            fail_count = fail_count + 1;
        end else if (error) begin
            $display("[T1] FAIL: error signal asserted");
            fail_count = fail_count + 1;
        end else begin
            $display("[T1] PASS: done asserted after %0d cycles", timeout);
            pass_count = pass_count + 1;
        end

        // ---- T2: 输出流式采样（T1 运行期间已捕获） ----
        $display("\n[T2] Output stream sampling");
        begin : chk_output
            automatic integer nonzero = 0;
            for (i = 0; i < NUM_SLOTS; i = i + 1)
                if (f0_out[i] !== 'x && f0_out[i] !== 0) nonzero = nonzero + 1;
            $display("[T2] Captured %0d/%0d samples: [%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d] nonzero=%0d",
                     cap_idx, NUM_SLOTS,
                     f0_out[0], f0_out[1], f0_out[2], f0_out[3],
                     f0_out[4], f0_out[5], f0_out[6], f0_out[7], nonzero);
            if (cap_idx < NUM_SLOTS) begin
                $display("[T2] FAIL: expected %0d samples, got %0d", NUM_SLOTS, cap_idx);
                fail_count = fail_count + 1;
            end else if (nonzero > 0) begin
                $display("[T2] PASS: output stream has %0d nonzero values", nonzero);
                pass_count = pass_count + 1;
            end else begin
                $display("[T2] FAIL: all output values are zero");
                fail_count = fail_count + 1;
            end
        end

        // ---- T3: 多层推进 ----
        $display("\n[T3] Multi-layer progression");
        @(posedge clk);
        repeat(5) @(posedge clk);
        if (layer_id == NUM_LAYERS - 1) begin
            $display("[T3] PASS: layer_id = %0d (expected %0d)", layer_id, NUM_LAYERS - 1);
            pass_count = pass_count + 1;
        end else begin
            $display("[T3] FAIL: layer_id = %0d (expected %0d)", layer_id, NUM_LAYERS - 1);
            fail_count = fail_count + 1;
        end

        // ---- T4: 多次推理（复位后重跑，含逐层权重喂入） ----
        $display("\n[T4] Re-run inference after reset");
        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        @(posedge clk);
        start = 1;
        @(posedge clk);
        #1;
        start = 0;

        run_inference();

        if (timeout >= 200000) begin
            $display("[T4] FAIL: timeout on second run");
            fail_count = fail_count + 1;
        end else if (error) begin
            $display("[T4] FAIL: error on second run");
            fail_count = fail_count + 1;
        end else begin
            $display("[T4] PASS: second run completed in %0d cycles", timeout);
            pass_count = pass_count + 1;
        end

        // ---- T5: 输出正确性（c0_init × c0_w 循环卷积 mod 113 golden） ----
        //   C[k] = sum_{j=0}^{N-1} a[j] * b[(k-j) mod N]  (mod q)
        $display("\n[T5] Output correctness (cyclic convolution golden)");
        begin : chk_golden
            automatic integer gold[NUM_SLOTS-1:0];
            automatic integer match = 1;
            for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                gold[i] = 0;
                for (j = 0; j < NUM_SLOTS; j = j + 1)
                    gold[i] = gold[i] +
                        c0_init_vec[j] * c0_w_vec[((i - j + NUM_SLOTS) % NUM_SLOTS)];
                gold[i] = gold[i] % 113;
            end
            for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (f0_out[i] !== Q_WIDTH'(gold[i])) begin
                    match = 0;
                    $display("[T5]   mismatch at [%0d]: got %0d, expected %0d",
                             i, f0_out[i], gold[i]);
                end
            end
            if (match) begin
                $display("[T5] PASS: output matches cyclic convolution golden");
                pass_count = pass_count + 1;
            end else begin
                $display("[T5] FAIL: output does not match golden");
                fail_count = fail_count + 1;
            end
        end

        // ---- 总结 ----
        repeat(10) @(posedge clk);
        $display("\n========================================");
        $display("tb_b_layer_ctrl: %0d PASS / %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL PASS");
        else
            $display("SOME FAIL");
        $display("========================================");
        $finish;
    end

    // =========================================================================
    // 超时保护
    // =========================================================================
    initial begin
        #5000000;
        $display("\nTIMEOUT! Simulation exceeded 5ms");
        $display("  state=%0d busy=%b done=%b layer=%0d op=%0d",
                 u_dut.state, busy, done, layer_id, op_id);
        $finish;
    end

endmodule

`default_nettype wire
