// =============================================================================
// e2e_ablation_wrapper.sv  —  E35: same-device ablation harness
//
// Purpose: give the paper honest same-device/same-flow ablation baselines for
// the two headline contributions of CIPHER-PU:
//
//   ABL_MODE = 0  "block-sparse" : gear 3 (approx multiply + fast rescale ON,
//                                      threshold 2^16) with block-level sparse
//                                      masking — the full CIPHER-PU datapath
//   ABL_MODE = 1  "element-sparse": gear 3 with element-wise sparse masking
//                                      only (block_sparse_en = 0) — isolates the
//                                      block-mask contribution
//   ABL_MODE = 2  "naive"         : gear 0 — no sparsity, no approximate
//                                      multiply, no fast rescale: the
//                                      conventional full-precision CKKS
//                                      ciphertext-multiply datapath
//
// The runtime adaptive closed loop (noise_monitor + adaptive_gear_ctrl) sits
// outside this multiply top in the system wrapper; its standalone cost is
// measured separately in the E35 report and added analytically.
//
// The comparison is apples-to-apples: identical RTL tree, identical synthesis
// flow, identical device (xcau25p), identical parameters (LOG_N/Q_WIDTH),
// identical clock constraint. What changes between variants is only what the
// tie-offs allow the synthesizer to prune.
//
// Varying only the control tie-offs (rather than editing the datapath RTL)
// guarantees the ablation cannot accidentally perturb the multiply pipeline,
// so any LUT/BRAM/power delta is attributable to the pruned control logic.
//
//NOTE: this wrapper is a synthesis-only harness (E35). It is NOT intended as
// a simulation top and has no self-checking stimulus.
// =============================================================================

`timescale 1ns / 1ps

module e2e_ablation_wrapper #(
    parameter int LOG_N           = 12,
    parameter int N               = 1 << LOG_N,
    parameter int Q_WIDTH         = 45,
    parameter logic [Q_WIDTH-1:0] Q_IN  = 45'd17592186175489,
    parameter logic [Q_WIDTH-1:0] Q_OUT = 45'd17592186372097,
    parameter logic [Q_WIDTH-1:0] N_INV = 45'd17587891208161,
    parameter int USE_FASTRED     = 1,
    parameter int ABL_MODE        = 0    // 0=full, 1=no-adaptive, 2=naive
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start,
    output logic                  busy,
    output logic                  done,
    output logic                  error,

    // ciphertext C1 stream
    input  logic                  c0_1_valid,
    output logic                  c0_1_ready,
    input  logic [Q_WIDTH-1:0]    c0_1_data,
    input  logic                  c1_1_valid,
    output logic                  c1_1_ready,
    input  logic [Q_WIDTH-1:0]    c1_1_data,
    // ciphertext C2 stream
    input  logic                  c0_2_valid,
    output logic                  c0_2_ready,
    input  logic [Q_WIDTH-1:0]    c0_2_data,
    input  logic                  c1_2_valid,
    output logic                  c1_2_ready,
    input  logic [Q_WIDTH-1:0]    c1_2_data,
    // keyswitch key streams
    input  logic                  a_valid,
    output logic                  a_ready,
    input  logic [Q_WIDTH-1:0]    a_data,
    input  logic                  b_valid,
    output logic                  b_ready,
    input  logic [Q_WIDTH-1:0]    b_data,
    // result ciphertext stream
    output logic                  f0_valid,
    input  logic                  f0_ready,
    output logic [Q_WIDTH-1:0]    f0_data,
    output logic                  f1_valid,
    input  logic                  f1_ready,
    output logic [Q_WIDTH-1:0]    f1_data,
    // twiddle factor tables
    input  logic [Q_WIDTH-1:0]    omega_table     [0:N/2-1],
    input  logic [Q_WIDTH-1:0]    omega_inv_table [0:N/2-1]
);

    // -------------------------------------------------------------------------
    // Ablation tie-offs
    // -------------------------------------------------------------------------
    localparam logic BLOCK_SPARSE_ON = (ABL_MODE == 0) ? 1'b1 : 1'b0;
    localparam logic [2:0] FIXED_GEAR = (ABL_MODE == 2) ? 3'h0 : 3'h3;

    logic [2:0]  gear_sel;
    logic        mode_sel;
    logic [63:0] energy_q2_ext;
    logic        flush_valid_ext;
    logic        hysteresis_en;
    logic [2:0]  manual_gear;
    logic        manual_en;
    logic        noise_mon_en;
    logic        block_sparse_en;

    always_comb begin
        // gear selection: adaptive path in full mode, fixed manual gear otherwise
        gear_sel      = FIXED_GEAR;
        manual_gear   = FIXED_GEAR;
        manual_en     = 1'b1;              // static (manual) gear in all variants;
                                           // the adaptive loop is measured separately
        mode_sel      = 1'b0;              // 0 = manual mode
        noise_mon_en  = 1'b0;              // external injection; monitor not in this top
        block_sparse_en = BLOCK_SPARSE_ON; // block-level vs element-level masking
        hysteresis_en = 1'b0;
        energy_q2_ext   = '0;              // external noise injection never used in synth
        flush_valid_ext = 1'b0;
    end

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    e2e_ckks_mult_ctrl_m4 #(
        .LOG_N     (LOG_N),
        .N         (N),
        .Q_WIDTH   (Q_WIDTH),
        .Q_IN      (Q_IN),
        .Q_OUT     (Q_OUT),
        .N_INV     (N_INV),
        .USE_FASTRED (USE_FASTRED)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .gear_sel         (gear_sel),
        .start            (start),
        .busy             (busy),
        .done             (done),
        .error            (error),
        .mode_sel         (mode_sel),
        .energy_q2_ext    (energy_q2_ext),
        .flush_valid_ext  (flush_valid_ext),
        .hysteresis_en    (hysteresis_en),
        .manual_gear      (manual_gear),
        .manual_en        (manual_en),
        .noise_mon_en     (noise_mon_en),
        .block_sparse_en  (block_sparse_en),
        .c0_1_valid       (c0_1_valid),
        .c0_1_ready       (c0_1_ready),
        .c0_1_data        (c0_1_data),
        .c1_1_valid       (c1_1_valid),
        .c1_1_ready       (c1_1_ready),
        .c1_1_data        (c1_1_data),
        .c0_2_valid       (c0_2_valid),
        .c0_2_ready       (c0_2_ready),
        .c0_2_data        (c0_2_data),
        .c1_2_valid       (c1_2_valid),
        .c1_2_ready       (c1_2_ready),
        .c1_2_data        (c1_2_data),
        .a_valid          (a_valid),
        .a_ready          (a_ready),
        .a_data           (a_data),
        .b_valid          (b_valid),
        .b_ready          (b_ready),
        .b_data           (b_data),
        .f0_valid         (f0_valid),
        .f0_ready         (f0_ready),
        .f0_data          (f0_data),
        .f1_valid         (f1_valid),
        .f1_ready         (f1_ready),
        .f1_data          (f1_data),
        .omega_table      (omega_table),
        .omega_inv_table  (omega_inv_table)
    );

endmodule
