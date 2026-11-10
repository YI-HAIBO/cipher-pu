// ========================================================================= //
// Module: kanal_sparse_prune                                                //
// Title: 稀疏 Kanal 剪枝引擎                                                  //
// Author: Yi (SZPU)                                                          //
// Description: 跳过卷积核中无效通道，提升推理效率                             //
// Date: 2026-10-14                                                           //
// ========================================================================= //

`timescale 1ns / 1ps

module kanal_sparse_prune #(
    parameter int DAT_WIDTH = 7,
    parameter int CHANNELS = 64,
    parameter int BLOCK_SIZE = 8
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [DAT_WIDTH-1:0] cis_tdata,
    input  logic                 cis_tvalid,
    output logic                 cis_tready,

    output logic [DAT_WIDTH-1:0] cos_tdata,
    output logic                 cos_tvalid,
    input  logic                 cos_tready,

    input  logic prune_en,
    output logic                 prune_done
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_RUN  = 2'd1;
    localparam [1:0] STATE_SCAN = 2'd2;
    localparam [1:0] STATE_OUT  = 2'd3;

    // State registers
    logic [1:0] state_reg, state_next;

    // Combinational outputs
    logic cis_tready_comb;
    logic cos_tvalid_comb;
    logic prune_done_comb;

    // Counters
    logic [2:0] ch_cnt_reg, ch_cnt_next;
    logic [5:0] block_idx_reg, block_idx_next;

    // Register outputs
    logic       scan_skip;
    logic       prune_done_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= STATE_IDLE;
            prune_done_reg <= 1'b0;
            ch_cnt_reg <= 3'd0;
            block_idx_reg <= 6'd0;
        end else begin
            state_reg <= state_next;
            prune_done_reg <= prune_done_comb;
            ch_cnt_reg <= ch_cnt_next;
            block_idx_reg <= block_idx_next;
        end
    end

    always_comb begin
        // default assignments
        state_next       = state_reg;
        cis_tready_comb  = 1'b1;
        cos_tvalid_comb  = 1'b0;
        prune_done_comb  = 1'b0;
        ch_cnt_next      = ch_cnt_reg;
        block_idx_next   = block_idx_reg;

        scan_skip = (cis_tdata != 0);

        case (state_reg)
            STATE_IDLE: begin
                if (prune_en) begin
                    state_next = STATE_RUN;
                end
            end

            STATE_RUN: begin
                if (cis_tvalid && cis_tready_comb) begin
                    if (!scan_skip) begin
                        state_next = STATE_SCAN;
                    end else begin
                        cos_tdata = cis_tdata;
                        cos_tvalid_comb = 1'b1;
                        if (cos_tready) begin
                            state_next = STATE_OUT;
                        end
                    end
                end
            end

            STATE_SCAN: begin
                cis_tready_comb = 1'b1;
                if (cis_tvalid) begin
                    ch_cnt_next = ch_cnt_reg + 1;
                    if (ch_cnt_next >= CHANNELS) begin
                        prune_done_comb = 1'b1;
                        state_next = STATE_IDLE;
                    end else begin
                        state_next = STATE_RUN;
                    end
                end
            end

            STATE_OUT: begin
                cis_tready_comb = 1'b1;
                if (cis_tvalid && cos_tvalid_comb) begin
                    if (cos_tready) begin
                        state_next = STATE_RUN;
                    end
                end
            end

            default: state_next = STATE_IDLE;
        endcase
    end

    assign cis_tready = cis_tready_comb;
    assign cos_tvalid = cos_tvalid_comb;
    assign prune_done = prune_done_reg;

endmodule
