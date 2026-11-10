// ========================================================================= //
// Testbench: tb_attention_sparse_opt                                        //
// Author: Yi (SZPU)                                                          //
// Description: 注意力机制优化功能验证                                         //
// Date: 2026-10-14                                                           //
// ========================================================================= //

`timescale 1ns / 1ps

module tb_attention_sparse_opt;

    // --------------------------------------------------------------------- //
    // 参数定义 - 与 DUT 匹配                                                    //
    // --------------------------------------------------------------------- //
    parameter int D_MODEL = 128;
    parameter int NUM_HEADS = 4;
    parameter int HEAD_DIM = 32;
    parameter int BLOCK_SIZE = 16;
    parameter int MAX_BLOCKS = 256;

    // --------------------------------------------------------------------- //
    // 逻辑信号                                                              //
    // --------------------------------------------------------------------- //
    logic        clk;
    logic        rst_n;

    // Q K V input
    logic        q_valid;
    logic        k_valid;
    logic        v_valid;
    logic [D_MODEL-1:0]  q_data;
    logic [D_MODEL-1:0]  k_data;
    logic [D_MODEL-1:0]  v_data;

    // mask input
    logic        mask_valid;
    logic [MAX_BLOCKS-1:0] mask_index;

    // output
    logic        out_valid;
    logic [D_MODEL-1:0]  out_data;
    logic        data_ready_in;
    logic        processing;
    logic        done;

    // --------------------------------------------------------------------- //
    // DUT 实例化                                                              //
    // --------------------------------------------------------------------- //
    attention_sparse_opt #(
        .D_MODEL(D_MODEL),
        .NUM_HEADS(NUM_HEADS),
        .HEAD_DIM(HEAD_DIM),
        .BLOCK_SIZE(BLOCK_SIZE),
        .MAX_BLOCKS(MAX_BLOCKS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .q_valid_in(q_valid),
        .k_valid_in(k_valid),
        .v_valid_in(v_valid),
        .q_data(q_data),
        .k_data(k_data),
        .v_data(v_data),

        .mask_valid(mask_valid),
        .mask_index(mask_index),

        .out_valid(out_valid),
        .out_data(out_data),
        .data_ready_in(data_ready_in),
        .processing(processing),
        .done(done)
    );

    // --------------------------------------------------------------------- //
    // 时钟生成                                                                //
    // --------------------------------------------------------------------- //
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100 MHz
    end

    // --------------------------------------------------------------------- //
    // 测试激励                                                                  //
    // --------------------------------------------------------------------- //
    initial begin
        integer i;

        // 初始化
        rst_n = 0;
        q_valid = 0;
        k_valid = 0;
        v_valid = 0;
        q_data = 0;
        k_data = 0;
        v_data = 0;
        mask_valid = 0;
        mask_index = 0;
        // out_valid is driven only by DUT, we do not assign here


        // 复位
        @(posedge clk);
        #12;
        rst_n = 1;

        // 生成测试向量
        for (i = 0; i < 50; i = i + 1) begin
            @(posedge clk);
            q_data = $urandom() % (1 << D_MODEL);
            k_data = $urandom() % (1 << D_MODEL);
            v_data = $urandom() % (1 << D_MODEL);
            q_valid = 1;
            k_valid = 1;
            v_valid = 1;

            // 等待输出
            while (!out_valid) begin
                @(posedge clk);
            end

            // 采样输出
            $display("Time %0t: attn_out=H%0h", $time, out_data);

            q_valid = 0;
            k_valid = 0;
            v_valid = 0;
            @(posedge clk);
        end

        $display("Simulation completed successfully.");
        $finish;
    end

endmodule
