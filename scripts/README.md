# Scripts Directory

Reproducible experiment and build scripts for CIPHER-PU. Only the
reproducible pipeline is committed; one-off debug scripts are excluded.

## Layout

| Group | Contents |
|-------|----------|
| `exp_e*.py` | Experiments E2-E39 (accuracy, security, SCA, benchmarks, ...) |
| `verify_*.py` | Module-level verification drivers |
| `golden_*.py` | Python golden models used as simulation oracles |
| `gen_*.py` / `gen_*.tcl` | Test-vector / BRAM-IP / omega-table generation |
| `run_synth_*.tcl`, `run_impl_*.tcl` | Vivado synthesis and implementation |
| `e34_*.tcl`, `e35_*.tcl` | SAIF power and ablation flows |
| `e34_rns_netlist.tcl`, `e34_rns_saif_power.tcl` | E34 RNS variant: routed netlist export + SAIF power (方案 B anchor) |
| `run_e34_rns_step2.py` | E34 RNS SAIF power flow driver (VCD→SAIF→report_power on xcku5p) |
| `_mdp_tw_gen.py` | RNS twiddle-coefficient `.hex` generation (N=16/4096/16384, p1/p2/p3) |
| `_mdp_xsim_e2e_rns.py`, `_mdp_xsim_e2e_rns_prod.py` | RNS end-to-end xsim regression (toy N=16 / prod N=4096) |
| `run_all.py`, `run_sim_vivado.py`, `sim_runner.py` | Regression entry points |
| `make_figures.py` | Regenerates every paper figure and table |
| `gl_power/` | VCD-to-SAIF converter + gate-level power flow (E30/E34/E34-RNS) |

## Key entry points

```bash
python scripts/run_all.py                       # full regression
python scripts/make_figures.py                  # all figures + tables
python scripts/exp_e39_dare_sca.py              # E39 side-channel experiment
python scripts/run_e34_step2.py                 # routed SAIF power (E34, xcau25p)
python scripts/run_e34_rns_step2.py             # routed SAIF power, RNS variant (E34 方案 B, xcku5p)
python scripts/run_synth_prod_blocks.py         # production synthesis
```

## Requirements

```bash
pip install -r scripts/requirements.txt
```

## License

Apache-2.0. See [../LICENSE](../LICENSE).
