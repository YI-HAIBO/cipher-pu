# Testbench Directory

SystemVerilog testbenches for CIPHER-PU RTL (40 files).

## Running

```bash
make sim TB=tb_e2e_ckks_mult_ctrl_m4    # single testbench
make verify                             # full regression (15 suites)
```

The runner `scripts/run_sim_vivado.py` drives `xvlog`/`xelab`/`xsim` from the
Vivado 2026.1 installation; results are written to `_sim_runner_out.txt`.

## Testbench Conventions

- **Driver**: stimulus changes on `negedge clk` to avoid race with the DUT's
  `posedge` sampling
- **Start signal**: single-cycle pulse, released on the following `posedge`
- **Assertions**: hard assertions for critical invariants
- **Timeouts**: configurable via the `SIM_TIMEOUT` parameter

## Reference Vectors

Reference vectors are produced by the golden models in
`scripts/golden_*.py` and `scripts/gen_*_vec.py`; hex vectors under `tb/ref/`
are regenerated on demand (`make regen-vec`) and are not committed.

## License

Apache-2.0. See [../LICENSE](../LICENSE).
