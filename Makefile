# CIPHER-PU Makefile
# Entry points for simulation, synthesis, power analysis and reporting.
# Every target below invokes a script that is present in this repository.

SHELL := /bin/bash

# Configuration
DEVICE ?= xcau25p-ffvb676-1-e
VIVADO ?= vivado
PYTHON ?= python
TB ?= e2e_ckks_mult_ctrl_m4
EXP ?= e39

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "CIPHER-PU - CKKS Homomorphic Encryption FPGA Accelerator"
	@echo ""
	@echo "Verification:"
	@echo "  make verify          Full functional regression (all testbenches)"
	@echo "  make sim TB=<name>   Run one testbench (see scripts/run_sim_vivado.py --list)"
	@echo "  make lint            RTL lint"
	@echo "  make coverage        Coverage matrix"
	@echo ""
	@echo "Implementation (needs Vivado):"
	@echo "  make synth           Out-of-context block synthesis (LOG_N=12)"
	@echo "  make impl            Implementation / place-and-route"
	@echo "  make power           Routed SAIF gate-level power (E34)"
	@echo "  make bitstream       Not verified (M6); prints a note only"
	@echo ""
	@echo "Analysis:"
	@echo "  make figures        Regenerate all paper figures and tables"
	@echo "  make exp EXP=e39    Run one experiment (exp_e39_dare_sca.py)"
	@echo "  make regen-vec      Regenerate simulation reference vectors"
	@echo ""
	@echo "Variables: DEVICE, VIVADO=path/to/vivado, PYTHON, TB, EXP"

# =================== Verification ===================

.PHONY: verify
verify:
	@echo "Running full regression..."
	@$(PYTHON) scripts/run_all.py

.PHONY: sim
sim:
	@echo "Running testbench: $(TB)"
	@$(PYTHON) scripts/run_sim_vivado.py --only $(TB) --timeout 1200

.PHONY: sim-list
sim-list:
	@$(PYTHON) scripts/run_sim_vivado.py --list

.PHONY: lint
lint:
	@$(PYTHON) scripts/lint_sv.py

.PHONY: coverage
coverage:
	@$(PYTHON) scripts/coverage_matrix.py

# =================== Implementation ===================

.PHONY: synth
synth:
	@echo "Running Vivado block synthesis for $(DEVICE)..."
	$(VIVADO) -mode batch -source scripts/run_synth_prod_blocks.tcl -tclargs $(DEVICE)

.PHONY: impl
impl:
	@echo "Running Vivado implementation for $(DEVICE)..."
	$(VIVADO) -mode batch -source scripts/run_impl_prod_blocks.tcl -tclargs $(DEVICE)

.PHONY: power
power:
	@echo "Routed SAIF gate-level power measurement (E34)..."
	@$(PYTHON) scripts/run_e34_step2.py

.PHONY: bitstream
bitstream:
	@echo "NOTE: M6 (bitstream generation + board bring-up) is NOT verified in this project."
	@echo "See ethics.md and the limitations appendix of the manuscript."
	@echo "No bitstream is produced by this target."

# =================== Analysis ===================

.PHONY: figures
figures:
	@$(PYTHON) scripts/make_figures.py

.PHONY: exp
exp:
	@echo "Running experiment E$(EXP)..."
	@$(PYTHON) scripts/exp_e$(EXP).py

.PHONY: exp-e39
exp-e39:
	@$(PYTHON) scripts/exp_e39_dare_sca.py

.PHONY: exp-e33
exp-e33:
	@$(PYTHON) scripts/exp_e33_real_ciphertext.py

.PHONY: regen-vec
regen-vec:
	@echo "Regenerating reference vectors..."
	@$(PYTHON) scripts/gen_omega_tables.py
	@$(PYTHON) scripts/gen_omega_tables_chain.py
	@$(PYTHON) scripts/gen_ntt_vectors.py
	@$(PYTHON) scripts/gen_tb_rescale_vec.py
	@$(PYTHON) scripts/gen_tb_keyswitch_vec.py
	@$(PYTHON) scripts/gen_tb_e2e_vec.py

# =================== Utilities ===================

.PHONY: setup
setup:
	@$(PYTHON) -m pip install --upgrade pip
	@$(PYTHON) -m pip install -r scripts/requirements.txt
	@echo "Setup complete. Install Vivado separately."

.PHONY: clean
clean:
	@rm -rf __pycache__ .pytest_cache .mypy_cache .ruff_cache
	@find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@rm -f *.jou *.log *.str *.tmp
	@echo "Clean complete."

