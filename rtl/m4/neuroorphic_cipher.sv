// ========================================================================= //
// Module: neuroorphic_cipher                                                  //
// Title: 神经形态计算引擎（事件驱动推理）                                     //
// Author: Yi (SZPU)                                                          //
// Description: 基于系数的活动性（activity）动态触发近似计算，突破隐私计算性能瓶颈 //
// Date: 2026-10-14                                                           //
// ========================================================================= //

`timescale 1ns / 1ps

module neuroomorphic_cipher #(
    parameter int LAT_WIDTH = 7,
    parameter int ACT_THRESH = 3,
    parameter int EVENTS = 16
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [LAT_WIDTH-1:0] cis_tdata,
    input  logic                 cis_tvalid,
    output logic                 cis_tready,

    output logic [LAT_WIDTH-1:0] cos_tdata,
    output logic                 cos_tvalid,
    input  logic                 cos_tready,

    input  logic ev_start,
    output logic                 ev_done
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_INIT = 2'd1;
    localparam [1:0] STATE_OUT  = 2'd2;

    // Wiring and registers
    logic [LAT_WIDTH-1:0] abs_val;
    logic [LAT_WIDTH:0]   abs_signed;
    logic [LAT_WIDTH-1:0] coeff_val;
    logic [31:0]          coeff_idx;
    logic                 ev_active;

    // State and counters
    logic [1:0] state;
    logic [1:0] state_next;
    logic       cis_tready_comb;
    logic       cos_tvalid_comb;
    logic       ev_done_comb;

    // Register outputs
    logic       ev_done_reg;

    // --------------------------------------------------------------------- //
    // State logic                                                           //
    // --------------------------------------------------------------------- //
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            ev_done_reg <= 1'b0;
        end else begin
            state <= state_next;
            ev_done_reg <= ev_done_comb;
        end
    end

    always_comb begin
        // default assignments
        state_next       = state;
        cis_tready_comb  = 1'b1;
        cos_tvalid_comb  = 1'b0;
        ev_done_comb     = 1'b0;
        ev_active        = 1'b0;

        case (state)
            STATE_IDLE: begin
                cis_tready_comb = 1'b1;
                if (cis_tvalid && cis_tready_comb) begin
                    abs_signed = $signed({1'b0, cis_tdata});
                    abs_val    = (abs_signed >= 0) ? abs_signed : -abs_signed;
                    if (abs_val >= ACT_THRESH) begin
                        coeff_val = cis_tdata + 1;
                        state_next = STATE_INIT;
                    end else begin
                        cos_tdata = cis_tdata;
                        cos_tvalid_comb = cis_tvalid;
                        if (cos_tready) begin
                            state_next = STATE_IDLE;
                        end else begin
                            state_next = STATE_INIT;
                        end
                    end
                end
            end

            STATE_INIT: begin
                cis_tready_comb = 1'b0;
                coeff_idx = coeff_idx + 1;
                state_next = STATE_OUT;
            end

            STATE_OUT: begin
                cos_tdata = cis_tdata;
                cos_tvalid_comb = 1'b1;
                if (cos_tready) begin
                    state_next = STATE_IDLE;
                end
            end

            default: state_next = STATE_IDLE;
        endcase
    end

    assign cis_tready = cis_tready_comb;
    assign cos_tvalid = cos_tvalid_comb;
    assign ev_done = ev_done_reg;

endmodule
