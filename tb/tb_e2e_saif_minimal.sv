// =============================================================================
// tb_e2e_saif_minimal.sv — E13 SAIF 生成最小测试台
//
// 用途：驱动 e2e_ckks_mult_ctrl_m4 完成一次完整密文乘法，产生足够的切换活动
//       以生成有统计意义的 SAIF 文件。
//
// 玩具配置: N=16, LOG_N=4, Q_WIDTH=7, Q_IN=113, Q_OUT=97, N_INV=106
//
// 简化说明：
//   - 不做功能验证（复用 tb_e2e_ckks_mult_ctrl_m4 的参考数据）
//   - 仅驱动 DUT 接口完成一次完整流程
//   - 仿真时间 ~50000ns，覆盖完整 FSM 链路
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_e2e_saif_minimal;
    // B-6 方案A：REPO_ROOT 由脚本经 --generic_top 注入仓库绝对路径覆盖；
    // 默认中性相对路径（"."=仓库根 cwd），未注入时依赖 xsim 的 cwd。
    parameter string REPO_ROOT = ".";


    // =========================================================================
    // 玩具配置参数
    // =========================================================================
    localparam LOG_N   = 4;
    localparam N       = 16;
    localparam Q_WIDTH = 7;
    localparam Q_IN    = 113;
    localparam Q_OUT   = 97;
    localparam N_INV   = 106;

    // =========================================================================
    // 时钟 & 复位
    // =========================================================================
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // DUT 信号
    // =========================================================================
    logic [2:0]           gear_sel;
    logic                 start;
    logic                 busy;
    logic                 done;
    logic                 error;

    logic                 mode_sel;
    logic [63:0]          energy_q2_ext;
    logic                 flush_valid_ext;
    logic                 hysteresis_en;
    logic [2:0]           manual_gear;
    logic                 manual_en;
    logic                 noise_mon_en;
    logic                 block_sparse_en;

    // C1
    logic                 c0_1_valid;
    logic                 c0_1_ready;
    logic [Q_WIDTH-1:0]   c0_1_data;
    logic                 c1_1_valid;
    logic                 c1_1_ready;
    logic [Q_WIDTH-1:0]   c1_1_data;

    // C2
    logic                 c0_2_valid;
    logic                 c0_2_ready;
    logic [Q_WIDTH-1:0]   c0_2_data;
    logic                 c1_2_valid;
    logic                 c1_2_ready;
    logic [Q_WIDTH-1:0]   c1_2_data;

    // Key
    logic                 a_valid;
    logic                 a_ready;
    logic [Q_WIDTH-1:0]   a_data;
    logic                 b_valid;
    logic                 b_ready;
    logic [Q_WIDTH-1:0]   b_data;

    // Output
    logic                 f0_valid;
    logic                 f0_ready;
    logic [Q_WIDTH-1:0]   f0_data;
    logic                 f1_valid;
    logic                 f1_ready;
    logic [Q_WIDTH-1:0]   f1_data;

    // Twiddle tables

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    e2e_ckks_mult_ctrl_m4 #(
        .LOG_N(LOG_N),
        .N(N),
        .Q_WIDTH(Q_WIDTH),
        .Q_IN(Q_IN),
        .Q_OUT(Q_OUT),
        .N_INV(N_INV),
        .TW_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omega_toy_n16.hex"}),
        .TW_INV_FILE({REPO_ROOT, "/rtl/m5/tw/tw_omegainv_toy_n16.hex"}),
        .USE_FASTRED(0)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .gear_sel(gear_sel),
        .start(start),
        .busy(busy),
        .done(done),
        .error(error),
        .mode_sel(mode_sel),
        .energy_q2_ext(energy_q2_ext),
        .flush_valid_ext(flush_valid_ext),
        .hysteresis_en(hysteresis_en),
        .manual_gear(manual_gear),
        .manual_en(manual_en),
        .noise_mon_en(noise_mon_en),
        .block_sparse_en(block_sparse_en),
        .c0_1_valid(c0_1_valid),
        .c0_1_ready(c0_1_ready),
        .c0_1_data(c0_1_data),
        .c1_1_valid(c1_1_valid),
        .c1_1_ready(c1_1_ready),
        .c1_1_data(c1_1_data),
        .c0_2_valid(c0_2_valid),
        .c0_2_ready(c0_2_ready),
        .c0_2_data(c0_2_data),
        .c1_2_valid(c1_2_valid),
        .c1_2_ready(c1_2_ready),
        .c1_2_data(c1_2_data),
        .a_valid(a_valid),
        .a_ready(a_ready),
        .a_data(a_data),
        .b_valid(b_valid),
        .b_ready(b_ready),
        .b_data(b_data),
        .f0_valid(f0_valid),
        .f0_ready(f0_ready),
        .f0_data(f0_data),
        .f1_valid(f1_valid),
        .f1_ready(f1_ready),
        .f1_data(f1_data)
    );


    // =========================================================================
    // 输入数据（使用与 tb_e2e_ckks_mult_ctrl_m4 相同的测试向量）
    // =========================================================================
    logic [Q_WIDTH-1:0] c0_1_vec [0:N-1];
    logic [Q_WIDTH-1:0] c1_1_vec [0:N-1];
    logic [Q_WIDTH-1:0] c0_2_vec [0:N-1];
    logic [Q_WIDTH-1:0] c1_2_vec [0:N-1];
    logic [Q_WIDTH-1:0] a_vec    [0:N-1];
    logic [Q_WIDTH-1:0] b_vec    [0:N-1];

    integer              load_idx;
    logic                load_c0_1, load_c1_1, load_c0_2, load_c1_2, load_a, load_b;
    logic                c0_1_done, c1_1_done, c0_2_done, c1_2_done, a_done, b_done;

    // =========================================================================
    // 控制流程
    // =========================================================================
    initial begin
        // 默认值
        gear_sel       = 3'h0;
        start          = 1'b0;
        mode_sel       = 1'b0;
        energy_q2_ext  = 64'd0;
        flush_valid_ext = 1'b0;
        hysteresis_en  = 1'b0;
        manual_gear    = 3'h0;
        manual_en      = 1'b0;
        noise_mon_en   = 1'b0;
        block_sparse_en = 1'b0;

        c0_1_valid = 1'b0; c0_1_data = '0;
        c1_1_valid = 1'b0; c1_1_data = '0;
        c0_2_valid = 1'b0; c0_2_data = '0;
        c1_2_valid = 1'b0; c1_2_data = '0;
        a_valid    = 1'b0; a_data    = '0;
        b_valid    = 1'b0; b_data    = '0;
        f0_ready   = 1'b1;
        f1_ready   = 1'b1;

        load_idx   = 0;
        load_c0_1  = 1'b0;
        load_c1_1  = 1'b0;
        load_c0_2  = 1'b0;
        load_c1_2  = 1'b0;
        load_a     = 1'b0;
        load_b     = 1'b0;

        // 复位
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 加载测试向量（简单非零值，确保切换活动）
        for (load_idx = 0; load_idx < N; load_idx = load_idx + 1) begin
            c0_1_vec[load_idx] = Q_WIDTH'(load_idx * 3 + 1);
            c1_1_vec[load_idx] = Q_WIDTH'(load_idx * 5 + 2);
            c0_2_vec[load_idx] = Q_WIDTH'(load_idx * 7 + 3);
            c1_2_vec[load_idx] = Q_WIDTH'(load_idx * 9 + 4);
            a_vec[load_idx]    = Q_WIDTH'(load_idx * 11 + 5);
            b_vec[load_idx]    = Q_WIDTH'(load_idx * 13 + 6);
        end

        // ---- 加载 C1 ----
        $display("[TB] Loading C1...");
        load_c0_1 = 1'b1;
        load_c1_1 = 1'b1;
        for (load_idx = 0; load_idx < N; load_idx = load_idx + 1) begin
            c0_1_data = c0_1_vec[load_idx];
            c1_1_data = c1_1_vec[load_idx];
            c0_1_valid = 1'b1;
            c1_1_valid = 1'b1;
            @(posedge clk);
            #1;
        end
        c0_1_valid = 1'b0;
        c1_1_valid = 1'b0;
        load_c0_1 = 1'b0;
        load_c1_1 = 1'b0;

        // ---- 加载 C2 ----
        $display("[TB] Loading C2...");
        load_c0_2 = 1'b1;
        load_c1_2 = 1'b1;
        for (load_idx = 0; load_idx < N; load_idx = load_idx + 1) begin
            c0_2_data = c0_2_vec[load_idx];
            c1_2_data = c1_2_vec[load_idx];
            c0_2_valid = 1'b1;
            c1_2_valid = 1'b1;
            @(posedge clk);
            #1;
        end
        c0_2_valid = 1'b0;
        c1_2_valid = 1'b0;
        load_c0_2 = 1'b0;
        load_c1_2 = 1'b0;

        // ---- 加载 Key ----
        $display("[TB] Loading key...");
        load_a = 1'b1;
        load_b = 1'b1;
        for (load_idx = 0; load_idx < N; load_idx = load_idx + 1) begin
            a_data = a_vec[load_idx];
            b_data = b_vec[load_idx];
            a_valid = 1'b1;
            b_valid = 1'b1;
            @(posedge clk);
            #1;
        end
        a_valid = 1'b0;
        b_valid = 1'b0;
        load_a = 1'b0;
        load_b = 1'b0;

        // ---- 启动 ----
        $display("[TB] Starting multiplication...");
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;

        // ---- 等待完成 ----
        $display("[TB] Waiting for done...");
        while (!done) begin
            @(posedge clk);
            #1;
        end
        $display("[TB] Done detected at t=%0t", $time);

        // 保持输出使能，多跑几拍确保活动记录完整
        repeat (200) @(posedge clk);

        $display("[TB] Simulation complete.");
        $finish;
    end

    // =========================================================================
    // VCD 泛波（替代 SAIF：xsim open_saif 在本版生成空文件）
    // =========================================================================
    initial begin
        $dumpfile("e2e.vcd");
        $dumpvars(0, tb_e2e_saif_minimal);
    end

endmodule