// =============================================================================
// slot_packer.sv — 多 Slot SIMD 样本打包器（Task #83，BRAM 版）
//
// 将 N/2 个明文样本打包为 N 个多项式系数（Hermitian 对称）：
//   poly[0..N/2-1] = samples[0..N/2-1]
//   poly[N-1-i]    = samples[i]          // 镜像对称
//
// 存储：sbuf[NUM_SLOTS × Q_WIDTH] 使用 BRAM（SDP 模式）
//   - S_LOAD: 逐拍写入样本
//   - S_OUT:  读前 N/2 → poly[0..N/2-1]，再读后 N/2 → poly[N-1..N/2]
//   - 预取：S_LOAD 最后一拍预取 sbuf[0]，BRAM 读延迟 1 拍由 S_OUT 首拍吸收
//
// 接口：AXI4-Stream 握手（sample_in → poly_out）
// =============================================================================

`timescale 1ns / 1ps

module slot_packer #(
    parameter int LOG_N     = 4,
    parameter int N         = 16,
    parameter int Q_WIDTH   = 7,
    parameter int NUM_SLOTS = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start,
    // Sample input (N/2 samples)
    input  logic                  sample_valid,
    output logic                  sample_ready,
    input  logic [Q_WIDTH-1:0]    sample_data,
    // Poly output (N coefficients)
    output logic                  poly_valid,
    input  logic                  poly_ready,
    output logic [Q_WIDTH-1:0]    poly_data,
    // Status
    output logic                  done
);

    // =========================================================================
    // 本地参数
    // =========================================================================
    localparam int IDX_W = $clog2(N);

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam logic [1:0] S_IDLE = 2'd0;
    localparam logic [1:0] S_LOAD = 2'd1;
    localparam logic [1:0] S_OUT  = 2'd2;
    localparam logic [1:0] S_DONE = 2'd3;

    logic [1:0]       state;
    logic [IDX_W-1:0] wr_idx;    // BRAM 写地址
    logic [IDX_W-1:0] out_idx;   // 输出系数索引（0..N-1）

    // =========================================================================
    // BRAM 存储（SDP 模式：1 写端口 + 1 读端口）
    // =========================================================================
    logic [Q_WIDTH-1:0] sbuf [0:NUM_SLOTS-1];
    logic [Q_WIDTH-1:0] sbuf_rd_data;

    // =========================================================================
    // BRAM 写（S_LOAD 期间）
    // =========================================================================
    wire            wr_en   = (state == S_LOAD) && sample_valid;
    wire [IDX_W-1:0] wr_addr = wr_idx;

    always @(posedge clk) begin
        if (wr_en)
            sbuf[wr_addr] <= sample_data;
    end

    // =========================================================================
    // BRAM 读地址生成（组合逻辑）
    // =========================================================================
    // 前半段：out_idx = 0..N/2-1 → rd_addr = out_idx
    // 后半段：out_idx = N/2..N-1 → rd_addr = N-1-out_idx（Hermitian 镜像）
    wire [IDX_W-1:0] rd_addr = (out_idx < NUM_SLOTS[IDX_W-1:0]) ?
                                out_idx :
                                (N[IDX_W-1:0] - 1 - out_idx);

    // =========================================================================
    // BRAM 读使能（预取 + S_OUT）
    // =========================================================================
    // S_LOAD 最后一拍预取 sbuf[0]，S_OUT 期间持续读
    wire rd_en = (state == S_OUT) ||
                 ((state == S_LOAD) && sample_valid &&
                  (wr_idx == NUM_SLOTS[IDX_W-1:0] - 1));

    always @(posedge clk) begin
        sbuf_rd_data <= sbuf[rd_addr];
    end

    // =========================================================================
    // 输出逻辑
    // =========================================================================
    // poly_valid = BRAM 读有效 && 在 S_OUT 状态
    //   屏蔽 S_LOAD 预取拍和 S_DONE 首拍的残余有效信号
    assign poly_valid = rd_en && (state == S_OUT);
    assign poly_ready = 1'b1;  // 永远接受（反压由 out_idx 不递增实现）
    assign poly_data  = sbuf_rd_data;

    assign sample_ready = (state == S_LOAD);

    // =========================================================================
    // 状态机
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            wr_idx  <= '0;
            out_idx <= '0;
            done    <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state  <= S_LOAD;
                        wr_idx <= '0;
                    end
                end

                S_LOAD: begin
                    if (sample_valid) begin
                        wr_idx <= wr_idx + IDX_W'(1);
                        if (wr_idx == NUM_SLOTS[IDX_W-1:0] - 1) begin
                            state   <= S_OUT;
                            out_idx <= '0;
                        end
                    end
                end

                S_OUT: begin
                    // 仅在 poly_ready 时递增 out_idx
                    if (poly_ready) begin
                        out_idx <= out_idx + IDX_W'(1);
                        if (out_idx == N[IDX_W-1:0] - 1) begin
                            state <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
