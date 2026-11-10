// =============================================================================
// e2e_ckks_bringup.sv - M6 上板 Bring-up 顶层封装
// =============================================================================
// Phase 6 (M6)
//
// 功能：
// - 顶层封装 e2e_ml_infer_wrapper（Phase 5）
// - 添加 ILA 探针（JTAG 调试）
// - 添加状态 LED 输出（板卡可视化）
// - 添加 JTAG 复位同步（rst_n 抖动过滤）
// - 添加健康状态计数器
//
// 上板调试信号：
// - status_led[3:0]  ：4 个 LED 指示（时钟/复位/错误/忙碌）
// - infer_count      ：推理次数计数器（64-bit）
// - cycle_count      ：总时钟周期（64-bit）
// - status           ：状态寄存器（8-bit）
//
// 注意：
// - ILA 核需要 Vivado IP Catalog 生成（Logic Analyzer）
// - 探针数量：8 个信号（约 10 LUT + 1 ISERDES）
// - 探针深度：512 条（默认）
// =============================================================================

`default_nettype none

module e2e_ckks_bringup #(
    parameter int Q_WIDTH      = 45,
    parameter int N            = 4096,
    parameter int LOG_N        = 12,
    parameter int NUM_CLASSES  = 10,
    parameter bit Q_VALUE      = 45'd17592186175489,
    parameter bit N_INV        = 45'd17587891208161,
    parameter int USE_FASTRED  = 1,

    // ILA 配置
    parameter int ILA_PROBE_DEPTH = 512,
    parameter int ILA_PROBE_WIDTH = 32
) (
    input wire logic              clk,
    input wire logic              rst_n,

    // JTAG 控制（可选，用于直接触发推理）
    input wire logic              jtag_start,
    input wire logic [7:0]        jtag_control,

    // 输入密文（简化：直接从内部 BRAM 加载测试向量）
    // 生产环境应从 DDR/HBM 加载
    output logic [7:0]        debug_status,

    // 状态 LED
    output logic [3:0]        status_led,

    // 计数器（ILA 探测）
    output logic [63:0]       cycle_count,
    output logic [31:0]       infer_count,

    // 推理结果
    output logic [7:0]        class_idx,
    output logic [7:0]        class_score,

    // AXI4-Stream 权重加载（上位机通过 JTAG 写入）
    input wire logic [31:0]       axi_wdata,
    input wire logic              axi_wvalid,
    output logic              axi_wready,
    input wire logic [3:0]        axi_waddr_bank,

    // AXI4-Stream 输入加载
    input wire logic [Q_WIDTH-1:0] input_tdata,
    input wire logic               input_valid,
    output logic               input_ready,

    // AXI4-Stream 输出读取
    output logic [Q_WIDTH-1:0] output_tdata,
    output logic               output_valid,
    output logic               output_last,
    input wire logic               output_ready
);

    // =========================================================================
    // 内部信号
    // =========================================================================

    // 主时钟周期计数（64-bit）
    logic [63:0] cycle_cnt;

    // 推理次数计数（32-bit）
    logic [31:0] infer_cnt;

    // 错误计数
    logic [15:0] error_cnt;

    // 健康状态（复位后自增）
    logic [7:0]  health_status;

    // ILA 探针信号（8 个）
    logic [7:0]  probe_0;   // 主状态位
    logic [31:0] probe_1;   // 推理计数
    logic [63:0] probe_2;   // 时钟计数
    logic [1:0]  probe_3;   // 推理控制位
    logic        probe_done;
    logic        probe_error;
    logic        probe_busy;
    logic        probe_start;

    // 层调度器信号（顶层可见）
    logic        layer_start;
    logic [3:0]  layer_idx;
    logic        layer_done;
    logic        layer_error;

    // 权重加载信号
    logic [Q_WIDTH-1:0] w_tdata;
    logic               w_valid;
    logic               w_ready;
    logic               w_last;
    logic [3:0]         w_layer_idx;
    logic [11:0]        w_addr;

    // 输入密文（AXI4-Stream）
    logic [Q_WIDTH-1:0] c0_tdata;
    logic               c0_valid;
    logic               c0_ready;
    logic               c0_last;
    logic [Q_WIDTH-1:0] c1_tdata;
    logic               c1_valid;
    logic               c1_ready;
    logic               c1_last;

    // 推理结果
    logic               wrapper_done;
    logic               wrapper_error;
    logic               wrapper_busy;
    logic [7:0]         result_class_idx;
    logic [7:0]         result_class_score;

    // wrapper 输出密文（AXI4-Stream）
    logic [Q_WIDTH-1:0] out_tdata;
    logic               out_valid;
    logic               out_last;

    // =========================================================================
    // 复位同步（异步复位 → 2 拍同步）
    // =========================================================================

    logic [1:0] rst_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rst_sync <= 2'b00;
        else
            rst_sync <= {rst_sync[0], 1'b1};
    end

    wire rst_n_sync = rst_sync[1];

    // =========================================================================
    // 时钟周期计数
    // =========================================================================

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            cycle_cnt <= 64'd0;
        else
            cycle_cnt <= cycle_cnt + 64'd1;
    end

    assign cycle_count = cycle_cnt;

    // =========================================================================
    // 推理次数计数
    // =========================================================================

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            infer_cnt <= 32'd0;
        else if (wrapper_done && !infer_cnt[31])
            infer_cnt <= infer_cnt + 32'd1;
    end

    assign infer_count = infer_cnt;

    // =========================================================================
    // 错误计数
    // =========================================================================

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            error_cnt <= 16'd0;
        else if (wrapper_error)
            error_cnt <= error_cnt + 16'd1;
    end

    // =========================================================================
    // 健康状态
    // =========================================================================

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            health_status <= 8'h00;
        else if (wrapper_done)
            health_status <= health_status | 8'h01;   // 至少一次推理完成
        else if (wrapper_error)
            health_status <= health_status | 8'h02;   // 发生错误
    end

    assign debug_status = {
        1'b0,
        wrapper_busy,
        wrapper_error,
        wrapper_done,
        rst_n_sync,
        error_cnt[11:8],
        health_status[3:0]
    };

    // =========================================================================
    // 状态 LED
    // =========================================================================

    assign status_led[0] = rst_n_sync;       // LED0：复位释放
    assign status_led[1] = clk;              // LED1：时钟闪烁（100 MHz 会看成一个稳定亮）
    assign status_led[2] = !wrapper_busy;    // LED2：空闲
    assign status_led[3] = wrapper_done;     // LED3：完成

    // =========================================================================
    // JTAG 控制接口（通过 Vivado ILA / Hardware Manager 触发）
    // =========================================================================

    // jtag_start: 单次推理触发（脉冲）
    // jtag_control[0]: 使能 ILA
    // jtag_control[1]: 强制复位
    // jtag_control[2]: 强制错误
    // jtag_control[3:7]: 保留

    wire start_pulsed = jtag_start || (rst_sync[0] && !rst_sync[1]);  // 复位释放时自动触发一次

    // =========================================================================
    // 权重加载接口（简化）
    // =========================================================================

    // 从 axi_wdata 映射到 w_tdata（截断到 Q_WIDTH）
    assign w_tdata     = axi_wdata[Q_WIDTH-1:0];
    assign w_valid     = axi_wvalid;
    assign axi_wready  = w_ready;
    assign w_last      = axi_wvalid && (axi_waddr_bank == 4'd7);
    assign w_layer_idx = axi_waddr_bank;
    assign w_addr      = 12'd0;  // 由 ml_model_config 内部递增

    // =========================================================================
    // 输入密文接口（简化）
    // =========================================================================

    assign c0_tdata = input_tdata;
    assign c0_valid = input_valid;
    assign input_ready = c0_ready;
    assign c0_last  = 1'b0;  // 由外部控制
    assign c1_tdata = input_tdata;
    assign c1_valid = input_valid;
    assign c1_last  = 1'b0;

    // =========================================================================
    // 输出接口
    // =========================================================================

    assign output_tdata = out_tdata;
    assign output_valid = out_valid;
    assign output_last  = out_last;

    // =========================================================================
    // 实例化 e2e_ml_infer_wrapper
    // =========================================================================

    e2e_ml_infer_wrapper #(
        .Q_WIDTH     (Q_WIDTH),
        .N           (N),
        .LOG_N       (LOG_N),
        .NUM_CLASSES (NUM_CLASSES),
        .Q_VALUE     (Q_VALUE),
        .N_INV       (N_INV),
        .USE_FASTRED (USE_FASTRED)
    ) u_e2e (
        .clk           (clk),
        .rst_n         (rst_n_sync),

        // 顶层控制
        .start         (start_pulsed),
        .busy          (wrapper_busy),
        .done          (wrapper_done),
        .error         (wrapper_error),

        // 输入密文
        .c0_tdata      (c0_tdata),
        .c0_valid      (c0_valid),
        .c0_ready      (c0_ready),
        .c0_last       (c0_last),
        .c1_tdata      (c1_tdata),
        .c1_valid      (c1_valid),
        .c1_ready      (c1_ready),
        .c1_last       (c1_last),

        // 权重配置
        .w_tdata       (w_tdata),
        .w_valid       (w_valid),
        .w_ready       (w_ready),
        .w_last        (w_last),
        .w_layer_idx   (w_layer_idx),
        .w_addr        (w_addr),

        // 输出
        .out_tdata     (out_tdata),
        .out_valid     (out_valid),
        .out_last      (out_last),
        .out_ready     (output_ready),

        // 推理结果
        .class_idx     (result_class_idx),
        .class_score   (result_class_score),

        // 状态
        .status        (health_status),

        // 计数器
        .infer_cycles  ()
    );

    assign class_idx    = result_class_idx;
    assign class_score  = result_class_score;

    // =========================================================================
    // ILA 探针绑定
    // =========================================================================

    assign probe_0 = debug_status;
    assign probe_1 = infer_cnt;
    assign probe_2 = cycle_cnt;
    assign probe_3 = {jtag_start, wrapper_busy, wrapper_done, wrapper_error};
    assign probe_done = wrapper_done;
    assign probe_error = wrapper_error;
    assign probe_busy = wrapper_busy;
    assign probe_start = start_pulsed;

    // =========================================================================
    // ILA 核实例化（需要 Vivado IP Catalog 生成）
    // =========================================================================

    // 生成方法：
    // 1. Vivado → IP Catalog → Search "ILA"
    // 2. 创建 IP，配置：
    //    - clk: 100 MHz
    //    - 8 个探针：debug_status(8), infer_cnt(32), cycle_cnt(64),
    //                control_bits(4), done(1), error(1), busy(1), start(1)
    //    - 深度：512
    // 3. 导出 IP，添加到工程
    // 4. 实例化如下（注释掉的模板）

/*
    ila_2_0 #(
        .C_DEPTH     (512),
        .C_DATA_WIDTH(141),  // 8+32+64+4+1+1+1+1 = 112，取 141 对齐
        .C_MMAPPARAM (""),
        .C_BRAM_INIT_FILE ("")
    ) u_ila (
        .clk      (clk),
        .probe0   (probe_0),
        .probe1   (probe_1),
        .probe2   (probe_2),
        .probe3   (probe_3),
        .probe4   (probe_done),
        .probe5   (probe_error),
        .probe6   (probe_busy),
        .probe7   (probe_start)
    );
*/

endmodule

`default_nettype wire
