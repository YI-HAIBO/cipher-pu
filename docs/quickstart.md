# Quick Start

## Prerequisites

1. **Vivado 2026.1** (synthesis, implementation, power analysis)
2. **Vivado xsim** — `xvlog` / `xelab` / `xsim`, shipped with Vivado
   (no third-party simulator is required)
3. **Python 3.11+** with `numpy`, `scipy`, `matplotlib`
   (`pip install -r scripts/requirements.txt`)
4. (Optional) **OpenFHE** for CKKS parameter cross-validation
5. (Optional) **Verilator** for lint

## Installation

```bash
git clone https://github.com/cipher-pu/cipher-pu.git
cd cipher-pu
make setup          # Install Python dependencies
```

## Run Functional Simulation

```bash
make sim-list                      # List available testbenches
make sim TB=tb_e2e_ckks_mult_ctrl_m4   # Single testbench
make verify                        # Full regression (15 suites)
```

The runner drives `xvlog` / `xelab` / `xsim` from the Vivado installation and
writes its log to `_sim_runner_out.txt`. On Windows, invoke Vivado tools
through the `bin/*.bat` loaders; `settings64.bat` alone is not sufficient for
xsim in this flow.

## Run Synthesis and Implementation

```bash
make synth                 # Device default: xcau25p-ffvb676-1-e
make synth DEVICE=xck260   # Different device
make impl                  # Place-and-route
make power                 # Routed SAIF gate-level power (E34)

# With Vivado path override
make synth VIVADO=/path/to/Vivado/2026.1/bin/vivado
```

## Regenerate Reference Vectors

```bash
make regen-vec             # omega tables, NTT vectors, rescale/keyswitch/e2e vectors
```

## Regenerate Figures

```bash
make figures               # All paper figures (PDF/PNG) + LaTeX tables
```

## Run a Single Experiment

```bash
make exp EXP=e39           # exp_e39_dare_sca.py
make exp EXP=e33           # exp_e33_real_ciphertext.py
```

Experiment data land in `data/`; see `data/README.md` for the full index.

## Expected Outputs

- `_sim_runner_out.txt` — simulation regression log
- `reports/figures/` — regenerated figures and tables
- `data/` — experiment JSON/MD results
- Vivado reports under the current working directory (`*.rpt`, `*.dcp`)

## Troubleshooting

### Vivado not found
```bash
export PATH=/path/to/Vivado/2026.1/bin:$PATH
```

### Python modules missing
```bash
python -m pip install -r scripts/requirements.txt
```

### Test vectors missing
```bash
make regen-vec
```

### xsim fails to start
Use the `bin/xvlog.bat` / `bin/xelab.bat` / `bin/xsim.bat` loaders with the
RDI/TCL/PATH environment that Vivado sets up, rather than calling the
executables directly.

## Next Steps

1. `rtl/m1/` — NTT unit RTL
2. `rtl/m4/` — runtime noise-adaptive closed loop
3. `tb/` — testbench examples
4. `scripts/` — experiment and build scripts
5. `data/` — experiment data indexed by the manuscript
