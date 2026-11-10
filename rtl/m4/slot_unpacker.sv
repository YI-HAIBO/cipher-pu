// =============================================================================
// slot_unpacker.sv — 多 Slot SIMD 样本解包器（Task #83）
//
// 将 N 个多项式系数解包为 N/2 个样本：
//   samples[0..N/2-1] = poly[0..N/2-1]（前 N/2 直通）
//   poly[N/2..N-1] 被忽略
//
// 接口：AXI4-Stream 握手（poly_in → sample_out）
// =============================================================================

`timescale 1ns / 1ps

module slot_unpacker #(
    parameter int LOG_N     = 4,
    parameter int N         = 16,
    parameter int Q_WIDTH   = 7,
    parameter int NUM_SLOTS = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start,
    // Poly input (N coefficients)
    input  logic                  poly_valid,
    output logic                  poly_ready,
    input  logic [Q_WIDTH-1:0]    poly_data,
    // Sample output (N/2 samples)
    output logic                  sample_valid,
    input  logic                  sample_ready,
    output logic [Q_WIDTH-1:0]    sample_data,
    // Status
    output logic                  done
);

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam logic [1:0] S_IDLE = 2'd0;
    localparam logic [1:0] S_RUN  = 2'd1;
    localparam logic [1:0] S_DONE = 2'd2;

    logic [1:0]       state;
    logic [$clog2(N):0] cnt;   // 0..N

    // =========================================================================
    // 组合逻辑：poly_ready / sample_valid / sample_data
    // =========================================================================
    // poly_ready：S_RUN 期间持续接受 poly 输入（消费全部 N 个系数）
    // sample_valid：仅前 NUM_SLOTS 个系数输出为样本（cnt < NUM_SLOTS）
    assign poly_ready   = (state == S_RUN);
    assign sample_valid = (state == S_RUN) && (cnt < NUM_SLOTS[$clog2(N):0]);
    assign sample_data  = poly_data;

    // =========================================================================
    // 状态机
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cnt   <= '0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_RUN;
                        cnt   <= '0;
                    end
                end

                S_RUN: begin
                    // 消费全部 N 个 poly 系数（poly_ready 始终为 1，无需 sample_ready 门控）
                    if (poly_valid && poly_ready) begin
                        cnt <= cnt + 1'b1;
                        if (cnt == N[$clog2(N):0] - 1) begin
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
