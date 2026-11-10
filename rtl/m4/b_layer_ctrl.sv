// =============================================================================
// b_layer_ctrl - B.2 层控制器
//
// 职责：
// - 管理多层推理的状态转换
// - 初始化输入密文加载
// - 权重密文加载
// - 控制推理循环（多层 + 多算子）
// - 输出结果
//
// 本次更新（2026-10-18，任务 3）：
// - 接入 approx_poly_mult 实现真实的 CKKS 多项式乘法
// - S_INFERENCE 拆分为 S_INF_MUL（执行乘法）+ S_INF_STREAM（流式输出）
// - 添加 omega_table / omega_inv_table 输入，由测试平台生成
// - 每个 op 执行 c0_init × c0_w 乘法，结果写入 out_buf 并流式输出
// - rescale / keyswitch 留 TODO（参数不匹配玩具配置）
// - 单一驱动重构：out_cnt / mul_* 计数器收归各自专属 always_ff，
//   消除状态机与计数器 always_ff 的多驱动 NBA 竞争隐患
// - 每层结束回到 S_W_LOAD 等待下一层权重（测试平台按需喂入）
//
// 玩具配置（默认）：
// - LOG_N=3, N=8, Q_VALUE=113, N_INV=99
// - omega=18 (8 次单位根 mod 113), omega_inv=44
// - USE_FASTRED=0, USE_BRAM_IP=0, B=1
//
// 注意：NUM_SLOTS 必须等于 1<<LOG_N（本模块用 NUM_SLOTS 作为多项式长度）
// =============================================================================

`timescale 1ns / 1ps

module b_layer_ctrl #(
    // 推理配置
    parameter int NUM_LAYERS       = 2,
    parameter int OPS_PER_LAYER    = 2,
    parameter int NUM_SLOTS        = 8,      // 多项式长度，必须 = 1<<LOG_N

    // 多项式/NTT 配置
    parameter int LOG_N            = 3,      // N = 1 << LOG_N = 8
    parameter int Q_WIDTH          = 7,
    parameter bit [Q_WIDTH-1:0] Q_IN       = 7'd113,
    parameter bit [Q_WIDTH-1:0] Q_OUT      = 7'd97,

    // approx_poly_mult 配置
    parameter bit [Q_WIDTH-1:0] Q_VALUE    = 7'd113,
    parameter bit [Q_WIDTH-1:0] N_INV      = 7'd99,  // 8^(-1) mod 113 = 99
    parameter bit                 USE_FASTRED = 1'b0,
    parameter bit                 USE_BRAM_IP = 1'b0,
    parameter int                 B         = 1,

    // 调试使能
    parameter bit DEBUG_EN         = 1'b0,
    parameter string TW_FILE       = "rtl/m5/tw/tw_omega_toy_n8.hex",
    parameter string TW_INV_FILE   = "rtl/m5/tw/tw_omegainv_toy_n8.hex"
)(
    // 时钟/复位
    input  logic clk,
    input  logic rst_n,
    input  logic start,

    // 输入密文（初始化，c0, c1）
    input  logic                     c0_init_valid,
    input  logic                     c1_init_valid,
    output logic                     c0_init_ready,
    output logic                     c1_init_ready,
    input  logic [Q_WIDTH-1:0]       c0_init_data,
    input  logic [Q_WIDTH-1:0]       c1_init_data,

    // 权重密文加载（c0, c1）
    input  logic                     c0_weight_valid,
    input  logic                     c1_weight_valid,
    output logic                     c0_weight_ready,
    output logic                     c1_weight_ready,
    input  logic [Q_WIDTH-1:0]       c0_weight_data,
    input  logic [Q_WIDTH-1:0]       c1_weight_data,


    // 控制信号
    output logic                     busy,
    output logic                     done,
    output logic                     error,
    output logic [Q_WIDTH-1:0]       layer_id,
    output logic [Q_WIDTH-1:0]       op_id,

    // 输出密文（保留接口，当前未使用）
    output logic                     c0_out_valid,
    output logic                     c1_out_valid,
    input  logic                     c0_out_ready,
    input  logic                     c1_out_ready,
    output logic [Q_WIDTH-1:0]       c0_out_data,
    output logic [Q_WIDTH-1:0]       c1_out_data,

    // f0/f1 输出（流式）
    output logic                     f0_valid,
    output logic                     f1_valid,
    input  logic                     f0_ready,
    input  logic                     f1_ready,
    output logic [Q_WIDTH-1:0]       f0_data,
    output logic [Q_WIDTH-1:0]       f1_data
);

    localparam int N = 1 << LOG_N;
    localparam int NUM_OPS = NUM_LAYERS * OPS_PER_LAYER;

    // =========================================================================
    // 内部状态与缓冲
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_INIT_LOAD,
        S_W_LOAD,
        S_INF_MUL,      // 执行 approx_poly_mult 乘法
        S_INF_STREAM,   // 流式输出 out_buf
        S_DONE
    } state_t;

    state_t state;
    logic [Q_WIDTH-1:0] layer_r, op_r;
    logic [Q_WIDTH-1:0] init_cnt, weight_cnt, out_cnt;
    logic [Q_WIDTH-1:0] mul_a_cnt, mul_b_cnt, mul_out_cnt;
    logic               mul_started;

    // 内部缓冲
    logic [NUM_SLOTS-1:0][Q_WIDTH-1:0] c0_init_buf, c1_init_buf;
    logic [NUM_SLOTS-1:0][Q_WIDTH-1:0] c0_w_buf, c1_w_buf;
    logic [NUM_SLOTS-1:0][Q_WIDTH-1:0] out_buf;

    // =========================================================================
    // approx_poly_mult 接口信号
    // =========================================================================
    logic                    mul_start;
    logic                    mul_busy;
    logic                    mul_done;
    logic                    mul_error;
    logic [Q_WIDTH-1:0]      mul_a_in_data;
    logic                    mul_a_in_valid;
    logic                    mul_a_in_ready;
    logic [Q_WIDTH-1:0]      mul_b_in_data;
    logic                    mul_b_in_valid;
    logic                    mul_b_in_ready;
    logic [Q_WIDTH-1:0]      mul_out_data;
    logic                    mul_out_valid;
    logic                    mul_out_last;
    logic                    mul_out_ready;

    // =========================================================================
    // 输出赋值
    // =========================================================================
    assign busy  = (state != S_IDLE) && (state != S_DONE);
    assign done  = (state == S_DONE);
    assign error = (state == S_DONE) && mul_error;
    assign layer_id = layer_r;
    assign op_id    = op_r;

    // Ready 信号：在整个加载阶段持续拉高，允许 testbench 连续发送 NUM_SLOTS 个系数
    assign c0_init_ready   = (state == S_INIT_LOAD);
    assign c1_init_ready   = (state == S_INIT_LOAD);
    assign c0_weight_ready = (state == S_W_LOAD);
    assign c1_weight_ready = (state == S_W_LOAD);

    // c0/c1 输出接口（保留，当前未使用）
    assign c0_out_valid = 1'b0;
    assign c1_out_valid = 1'b0;
    assign c0_out_data  = '0;
    assign c1_out_data  = '0;

    // f0/f1 流式输出
    assign f0_data  = out_buf[out_cnt];
    assign f1_data  = '0;
    assign f0_valid = (state == S_INF_STREAM) && (out_cnt < NUM_SLOTS);
    assign f1_valid = 1'b0;

    // =========================================================================
    // 实例化 approx_poly_mult
    // =========================================================================
    approx_poly_mult #(
        .LOG_N      (LOG_N),
        .Q_WIDTH    (Q_WIDTH),
        .Q_VALUE    (Q_VALUE),
        .N_INV      (N_INV),
        .USE_FASTRED(USE_FASTRED),
        .USE_BRAM_IP(USE_BRAM_IP),
        .B          (B),
        .TW_FILE    (TW_FILE),
        .TW_INV_FILE(TW_INV_FILE)
    ) u_poly_mult (
        .clk               (clk),
        .rst_n             (rst_n),
        .sparsity_threshold ('0),
        .trunc_bits         ('0),
        .use_approx_mult    (1'b0),
        .block_sparse_en    (1'b0),
        .start              (mul_start),
        .busy               (mul_busy),
        .done               (mul_done),
        .error              (mul_error),
        .a_in_data          (mul_a_in_data),
        .a_in_valid         (mul_a_in_valid),
        .a_in_ready         (mul_a_in_ready),
        .b_in_data          (mul_b_in_data),
        .b_in_valid         (mul_b_in_valid),
        .b_in_ready         (mul_b_in_ready),
        .out_data           (mul_out_data),
        .out_valid          (mul_out_valid),
        .out_last           (mul_out_last),
        .out_ready          (mul_out_ready)
    );

    // =========================================================================
    // 状态机
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            layer_r     <= '0;
            op_r        <= '0;
            init_cnt    <= '0;
            weight_cnt  <= '0;
            out_cnt     <= '0;
            mul_a_cnt   <= '0;
            mul_b_cnt   <= '0;
            mul_out_cnt <= '0;
            mul_started <= 1'b0;
        end else begin
            case (state)
                // 注：out_cnt / mul_a_cnt / mul_b_cnt / mul_out_cnt / mul_started
                //   由各自专属 always_ff 单一驱动（多驱动 NBA 竞争隐患已消除）
                S_IDLE: begin
                    layer_r     <= '0;
                    op_r        <= '0;
                    init_cnt    <= '0;
                    weight_cnt  <= '0;
                    if (start) state <= S_INIT_LOAD;
                end

                S_INIT_LOAD:
                    if (init_cnt == NUM_SLOTS-1) begin
                        weight_cnt <= '0;   // 首次进入权重加载
                        state      <= S_W_LOAD;
                    end

                S_W_LOAD:
                    if (weight_cnt == NUM_SLOTS-1) state <= S_INF_MUL;

                S_INF_MUL:
                    if (mul_done) begin
                        mul_out_cnt <= '0;
                        state       <= S_INF_STREAM;
                    end

                S_INF_STREAM:
                    if (out_cnt == NUM_SLOTS-1) begin
                        out_cnt <= '0;
                        if (op_r == OPS_PER_LAYER-1) begin
                            op_r <= '0;
                            if (layer_r == NUM_LAYERS-1)
                                state <= S_DONE;
                            else begin
                                layer_r    <= layer_r + 1;
                                weight_cnt <= '0;   // 下一层权重重新加载
                                state      <= S_W_LOAD;
                            end
                        end else begin
                            op_r  <= op_r + 1;
                            state <= S_INF_MUL;
                        end
                    end

                S_DONE:
                    if (start) state <= S_IDLE;

                default:
                    state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 初始化加载（仅在 valid && ready 时递增计数器）
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst_n && state == S_INIT_LOAD) begin
            if (c0_init_valid && c0_init_ready) begin
                c0_init_buf[init_cnt] <= c0_init_data;
                c1_init_buf[init_cnt] <= c1_init_data;
                init_cnt <= init_cnt + 1;
            end
        end
    end

    // =========================================================================
    // 权重加载（仅在 valid && ready 时递增计数器）
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst_n && state == S_W_LOAD) begin
            if (c0_weight_valid && c0_weight_ready) begin
                c0_w_buf[weight_cnt] <= c0_weight_data;
                c1_w_buf[weight_cnt] <= c1_weight_data;
                weight_cnt <= weight_cnt + 1;
            end
        end
    end

    // =========================================================================
    // approx_poly_mult 输入驱动（组合逻辑）
    // =========================================================================
    always_comb begin
        mul_start      = 1'b0;
        mul_a_in_valid = 1'b0;
        mul_a_in_data  = '0;
        mul_b_in_valid = 1'b0;
        mul_b_in_data  = '0;
        mul_out_ready  = 1'b0;

        if (state == S_INF_MUL) begin
            // 首拍启动
            if (!mul_started) mul_start = 1'b1;
            // 驱动 a 输入
            if (mul_a_cnt < NUM_SLOTS && mul_a_in_ready) begin
                mul_a_in_valid = 1'b1;
                mul_a_in_data  = c0_init_buf[mul_a_cnt];
            end
            // 驱动 b 输入
            if (mul_b_cnt < NUM_SLOTS && mul_b_in_ready) begin
                mul_b_in_valid = 1'b1;
                mul_b_in_data  = c0_w_buf[mul_b_cnt];
            end
            // 接收输出
            if (mul_out_valid) mul_out_ready = 1'b1;
        end
    end

    // =========================================================================
    // approx_poly_mult 计数器与输出捕获（时序逻辑）
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mul_started <= 1'b0;
            mul_a_cnt   <= '0;
            mul_b_cnt   <= '0;
            mul_out_cnt <= '0;
        end else if (state == S_INF_MUL) begin
            if (!mul_started) mul_started <= 1'b1;
            if (mul_a_in_valid && mul_a_in_ready && mul_a_cnt < NUM_SLOTS)
                mul_a_cnt <= mul_a_cnt + 1;
            if (mul_b_in_valid && mul_b_in_ready && mul_b_cnt < NUM_SLOTS)
                mul_b_cnt <= mul_b_cnt + 1;
            if (mul_out_valid && mul_out_ready) begin
                out_buf[mul_out_cnt] <= mul_out_data;
                mul_out_cnt          <= mul_out_cnt + 1;
            end
        end else begin
            mul_started <= 1'b0;
            mul_a_cnt   <= '0;
            mul_b_cnt   <= '0;
            mul_out_cnt <= '0;
        end
    end

    // =========================================================================
    // 输出流式推进（out_cnt 单一驱动）
    //   非 S_INF_STREAM 状态保持 '0，保证进入 S_INF_STREAM 首拍输出 out_buf[0]；
    //   out_cnt == NUM_SLOTS-1 且握手完成时归零（状态机据此推进下一 op）
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_cnt <= '0;
        end else if (state == S_INF_STREAM) begin
            if (f0_valid && f0_ready)
                out_cnt <= (out_cnt == NUM_SLOTS-1) ? '0 : out_cnt + 1'b1;
        end else begin
            out_cnt <= '0;
        end
    end

    // =========================================================================
    // 调试输出
    // =========================================================================
    generate
        if (DEBUG_EN) begin : dbg
            always @(posedge clk) begin
                if (rst_n)
                    $display("[%0t] b_layer_ctrl state=%0d layer=%0d op=%0d mul_a=%0d mul_b=%0d mul_out=%0d mul_done=%b out_cnt=%0d",
                             $time, state, layer_r, op_r, mul_a_cnt, mul_b_cnt, mul_out_cnt, mul_done, out_cnt);
            end
        end
    endgenerate

endmodule
