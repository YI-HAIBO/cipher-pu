// =============================================================================
// ml_model_config.sv - 模型权重配置加载模块
// =============================================================================
// Phase 5 Task 5.3.2
//
// 功能：
// - 6 层权重分 6 个 BRAM bank 存储
// - 权重加载接口（AXI4-Stream）
// - 权重读取接口（供各层模块）
// - 配置状态管理（已加载层掩码）
//
// 接口：见 phase5_architecture.md §1.6
// =============================================================================

`default_nettype none

module ml_model_config #(
    parameter int Q_WIDTH     = 45,
    parameter int NUM_LAYERS  = 7,
    parameter int MAX_WEIGHTS = 4096
) (
    input wire logic               clk,
    input wire logic               rst_n,

    // 权重加载接口（AXI4-Stream）
    input wire logic [Q_WIDTH-1:0] w_tdata,
    input wire logic               w_valid,
    output logic               w_ready,
    input wire logic               w_last,
    input wire logic [3:0]         w_layer_idx,
    input wire logic [11:0]        w_addr,

    // 权重读取接口（供各层模块）
    output logic [Q_WIDTH-1:0] w_read_data,
    output logic               w_read_valid,
    input wire logic               w_read_ready,
    input wire logic [3:0]         w_read_layer_idx,
    input wire logic [11:0]        w_read_addr,

    // 配置控制
    input wire logic               config_start,
    output logic               config_done,
    output logic               config_error,

    // 配置状态
    output logic [6:0]         loaded_layers,  // 已加载层掩码
    output logic               config_busy
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam int IDX_W = $clog2(MAX_WEIGHTS);

    localparam [3:0] S_IDLE        = 4'd0;
    localparam [3:0] S_LOAD_WEIGHT = 4'd1;
    localparam [3:0] S_DONE        = 4'd2;
    localparam [3:0] S_ERROR       = 4'd3;

    // =========================================================================
    // 状态寄存器
    // =========================================================================
    logic [3:0]               state;
    logic [3:0]               state_next;
    logic [6:0]               loaded_layers_reg;
    logic [IDX_W-1:0]         weight_count [0:NUM_LAYERS-1];  // 每层已加载权重数

    // =========================================================================
    // 权重 BRAM（6 个 bank，每 bank MAX_WEIGHTS × Q_WIDTH）
    // =========================================================================
    logic [Q_WIDTH-1:0]        weight_bram [0:NUM_LAYERS*MAX_WEIGHTS-1];

    // =========================================================================
    // 权重加载
    // =========================================================================
    assign w_ready = (state == S_LOAD_WEIGHT) && w_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_LAYERS; i++) begin
                weight_count[i] <= '0;
            end
            loaded_layers_reg <= '0;
        end else if (state == S_LOAD_WEIGHT) begin
            if (w_valid && w_ready) begin
                weight_bram[w_layer_idx * MAX_WEIGHTS + w_addr[IDX_W-1:0]] <= w_tdata;
                weight_count[w_layer_idx] <= weight_count[w_layer_idx] + IDX_W'(1);

                if (w_last) begin
                    loaded_layers_reg[w_layer_idx] <= 1'b1;
                end
            end
        end else if (config_start && state == S_IDLE) begin
            for (int i = 0; i < NUM_LAYERS; i++) begin
                weight_count[i] <= '0;
            end
            loaded_layers_reg <= '0;
        end
    end

    // =========================================================================
    // 权重读取（组合逻辑，直接读 BRAM）
    // =========================================================================
    assign w_read_valid = w_read_ready;
    assign w_read_data  = weight_bram[w_read_layer_idx * MAX_WEIGHTS + w_read_addr[IDX_W-1:0]];

    // =========================================================================
    // 状态机
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= state_next;
        end
    end

    always @(*) begin
        state_next = state;

        case (state)
            S_IDLE: begin
                if (config_start) begin
                    state_next = S_LOAD_WEIGHT;
                end
            end

            S_LOAD_WEIGHT: begin
                // 等待所有层加载完成
                if (loaded_layers_reg == '1) begin
                    state_next = S_DONE;
                end
            end

            S_DONE: begin
                state_next = S_IDLE;
            end

            S_ERROR: begin
                state_next = S_IDLE;
            end

            default: begin
                state_next = S_IDLE;
            end
        endcase
    end

    // =========================================================================
    // 输出
    // =========================================================================
    assign loaded_layers = loaded_layers_reg;
    assign config_done   = (state == S_DONE);
    assign config_error  = (state == S_ERROR);
    assign config_busy   = (state == S_LOAD_WEIGHT);

endmodule
