// Wrapper: instantiate tb_ntt_cycles with LOG_N=8 (N=256) for cycle scaling check
`default_nettype none
module tb_ntt_cycles_n256_wrap;
    tb_ntt_cycles #(.LOG_N(8)) u_tb();
endmodule
`default_nettype wire
