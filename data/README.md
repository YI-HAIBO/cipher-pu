# Data Directory

Experiment data backing every table and figure of the manuscript
(`../reports/paper_tcas_en.md`).

## Contents

| File(s) | Experiment |
|---------|------------|
| `e20_security_parameters.json` | E20 raw security scan (empirical fit) |
| `e22_statistical_reliability.json` | E22 multi-seed paired statistics |
| `e24_rotation_bootstrap.json` | E24 rotation / automorphism / DARE primitives |
| `e25_design_space.json` | E25 design-space exploration |
| `e26_security_dse.json` | E26 three-tier security-parameter DSE |
| `e27_security_homeml_verify.md`, `e27b_precision_estimate.{md,json}` | Security-level cross-check and extrapolation |
| `e28_pq_security_verify.{md,json}` | Post-quantum (BKZ.qsieve) re-check |
| `e29_poseidon_comparison.{md,json}` | Poseidon (HPCA'23) baseline comparison |
| `e30_saif_power.{md,json}` | E30 out-of-context SAIF power |
| `e31_sigma_sensitivity.{md,json}` | E31 sigma sensitivity sweep |
| `e32_multimodel_benchmark.{md,json}` | E32 multi-model end-to-end benchmark |
| `e33_real_ciphertext.{md,json}` | E33 real-RLWE RTL execution (12/12 bit-exact) |
| `e34_routed_power.md`, `e34_routed_power/` | E34 routed SAIF power (0.698 W anchor) |
| `e35_ablation.md` | E35 same-device closed-loop ablation |
| `e36_large_sample.{md,json}` | E36 large-sample statistical validation |
| `e38_fmax.md` | E38 post-route frequency ceiling (101.80 MHz) |
| `e39_dare_sca.{md,json}` | E39 RTL dual-proxy TVLA + masking cost |
| `adaptive_sweep.json`, `sparsity_sweep_v2.json` | E6/E10 sweep raw data |
| `experiment_summary.md` | Human-readable summary of all experiments |

## Public datasets

- MNIST: http://yann.lecun.com/exdb/mnist/ (Public Domain)
- CIFAR-10: https://www.cs.toronto.edu/~kriz/cifar-10.html (CC-BY-4.0)

Both are downloaded separately by the benchmark scripts; raw data are not
committed.

## License

Apache-2.0. See [../LICENSE](../LICENSE).
