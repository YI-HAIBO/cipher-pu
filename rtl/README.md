# RTL Directory

SystemVerilog RTL source for CIPHER-PU (CKKS homomorphic-encryption FPGA
accelerator, Xilinx xcau25p-ffvb676-1-e, Vivado 2026.1).

## Structure

```
rtl/
├── m1/   # NTT core: ntt_unit, ntt_butterfly, fast_red, mod45_*, ckks_bram,
│         # ntt_mem_tdp(_prod), mult_43x43_horner4, clocks.xdc
├── m2/   # poly_mult + synthesis tops (butterfly45/mod45), poly_mult.xdc,
│         # omega/modulus chain tables (regenerate via scripts/gen_omega_tables.py)
├── m3/   # e2e_ckks_mult_ctrl, keyswitch_pipe, keyswitch_pipe_masked (E39
│         # first-order additive masking), rescale
├── m4/   # runtime noise-adaptive closed loop, sparsity, DARE, NN layers
│         # (noise_monitor, adaptive_gear_ctrl, block_sparse_mask,
│         #  e2e_ckks_mult_ctrl_m4, ablation/, ...)
├── m5/   # RNS multi-modulus extension (M-D/M-D'): e2e_rns_top, poly_mult_rns,
│         # rescale_rns, rns_merge, rns_split, tw/ (twiddle ROM init hex),
│         # e2e_m5.xdc (top-level timing constraints)
└── m6/   # board bring-up (NOT VERIFIED on hardware, see ../ethics.md)
```

58 `.sv` modules in total.

## Twiddle Factor ROM (M-D')

`ntt_unit` / `poly_mult` / `keyswitch_pipe` load twiddle factors from
block-ROM init files via `$readmemh` (parameters `TW_FILE` / `TW_INV_FILE`),
replacing the former `omega_table` / `omega_inv_table` input-port arrays.
Toy and production init files live in `rtl/m5/tw/` (`tw_omega_*` /
`tw_omegainv_*`, N=16/4096/16384, per RNS prime). Regenerate with
`scripts/gen_omega_tables.py`. In the source tree the parameter defaults
carry absolute paths for cwd-independent simulation; relativise them when
publishing (see ../PUSH_GUIDE.md).

## Coding Standards

- 4-space indentation (no tabs)
- `snake_case` for signals/ports, `SNAKE_CASE` for parameters
- Line width <= 100 characters
- Parameterised bit widths (`Q_WIDTH`, `LOG_N`) — no hard-coded widths

## Verification

Every module has a matching testbench in `tb/`. Run the full regression with
`make verify` (or `python scripts/run_all.py`). See `docs/quickstart.md`.

## License

Apache-2.0. See [../LICENSE](../LICENSE).
