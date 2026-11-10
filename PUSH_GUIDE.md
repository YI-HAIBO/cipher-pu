# CIPHER-PU Open Source Deployment Guide

**Prepared for**: Yi Haibo (Shenzhen Polytechnic University)  
**Date**: 2026-10-24  
**Purpose**: Push CIPHER-PU to GitHub for IEEE TCAS-I submission

---

## Overview

The `open_source_repo/` directory contains a complete GitHub-ready skeleton
with 31 files (67.3 KB total). This guide walks through pushing to GitHub.

**Prerequisites**:
- GitHub account with a personal or organization account
- Git installed on your system
- The `fpga_ckks/` directory (with real RTL/TB/source files)
- SSH key configured for GitHub (recommended)

---

## Step 1: Review the Skeleton

Before pushing, review these key files:

- `README.md` - **Update author name, affiliation, contact email**
- `LICENSE` - Apache-2.0 (default; change if preferred)
- `CITATION.cff` - **Update ORCID IDs, institution**
- `.github/CODEOWNERS` - **Replace `@cipher-pu/maintainers` with your GitHub handle**
- `.github/FUNDING.yml` - **Update funding profile if applicable**

## Step 2: Verify Real Source Files

The skeleton has `rtl/README.md`, `tb/README.md`, etc. as **index files only**.
Actual RTL/TB/source files live in the parent `fpga_ckks/` directory.

You have two options:

### Option A: Move real files in (recommended)

```bash
# From fpga_ckks/open_source_repo/
cp -r ../rtl/m1 ../rtl/m2 ../rtl/m3 ../rtl/m4 ../rtl/m5 rtl/
cp -r ../tb/tb_*.sv tb/
cp -r ../scripts/run_*.py scripts/
cp -r ../reports/experiments reports/
cp -r ../reports/figures figures/
cp -r ../reports/*.md reports/
cp -r ../benchmarks benchmarks/
```

**Exclude** (per .gitignore):
- `.Xil/`, `xsim.dir/`, `*.log`, `*.jou` - Vivado build artifacts
- `ip_repo/`, `ip_gen_workspace/` - Generated IP (regenerate via Vivado)
- `tb/ref/` - Reference vectors (regenerate via `make regen-vec`)
- `scripts/__pycache__/` - Python cache

### Option B: Push skeleton first, then add

```bash
# Push skeleton as-is (governance files only)
cd open_source_repo
git init
git add .
git commit -m "Initial skeleton for CIPHER-PU open source repository"
git remote add origin https://github.com/cipher-pu/cipher-pu.git
git push -u origin main
```

Then add real source files in subsequent commits.

## Step 3: Initialize Git Repository

```bash
cd fpga_ckks/open_source_repo

# Initialize
git init

# Set branch name to main (default in newer Git versions)
git branch -M main

# Add remote
git remote add origin https://github.com/cipher-pu/cipher-pu.git

# First commit
git add .
git commit -m "Initial commit: CIPHER-PU open source repository

CIPHER-PU: Runtime-Adaptive CKKS Homomorphic Encryption FPGA Accelerator
- CKKS scheme on Xilinx UltraScale+ xcau25p
- Runtime-adaptive sparse feedback loop
- DARE bootstrap-lite
- 1.18 W power, 48.01 MS/s throughput
- 20.5x energy efficiency vs. Poseidon (HPCA'23)
- 256-bit post-quantum security (HE Standard v1.1)

Apache-2.0 license.
"
```

## Step 4: Push to GitHub

### Create GitHub repo first (via web UI)

1. Go to https://github.com/new
2. Repository name: `cipher-pu`
3. Description: "Runtime-Adaptive CKKS Homomorphic Encryption FPGA Accelerator"
4. Public (required for academic visibility)
5. **Do not** initialize with README (we already have one)
6. Add `.gitignore`: Python (we have custom one)
7. Add license: Apache-2.0 (we have custom one)
8. Click "Create repository"

### Push

```bash
git push -u origin main
```

### Set branch protection

- Go to GitHub repo → Settings → Branches
- Add rule for `main`:
  - Require pull request before merging
  - Require status checks to pass
  - Enable linear history (optional)

## Step 5: Configure GitHub Actions

The repo includes `.github/workflows/ci.yml` with:

- **Python lint** (Ruff) + unit tests
- **Verilog lint** (Verilator)
- **Markdown link check**
- **Code style check**

GitHub will automatically run these on every push/PR.

**Note**: Vivado/xsim simulations are NOT run in CI (vendor toolchain
requires local license). Run `make verify` locally before PR.

## Step 6: Post-Push Checklist

- [ ] GitHub repo visible at https://github.com/cipher-pu/cipher-pu
- [ ] README renders correctly with badges
- [ ] CI runs on first push (may fail initially)
- [ ] GitHub Actions tab shows workflow runs
- [ ] CODEOWNERS auto-assigns reviewers (test with a PR)

## Step 7: Update Paper References

After pushing, update the paper draft with the live URL:

```markdown
- GitHub: https://github.com/cipher-pu/cipher-pu
- DOI (if registered via Zenodo): TBD
```

Consider registering with Zenodo for a DOI (recommended for reproducibility):
1. Go to https://zenodo.org/
2. Import GitHub repo
3. Generate DOI
4. Add to README and CITATION.cff

---

## Appendix A: Sample Commit Messages

Follow Conventional Commits:

- `feat(rtl/m4): add adaptive gear controller threshold config`
- `fix(tb): handle backpressure in poly_mult testbench`
- `docs(readme): add Quick Start section`
- `test(tb): add E2E noise monitor coverage`
- `chore(ci): bump ruff to 0.4.x`
- `perf(rtl/m1): optimize ntt_butterfly pipeline depth`

## Appendix B: License Options

- **Apache-2.0** (current) - Patent grant, permissive, industry standard
- **MIT** - Minimal, permissive
- **BSD-3-Clause** - Permissive, patent-unclear
- **GPL-3.0** - Copyleft (not recommended for research code)

Apache-2.0 recommended for academic + industry dual use.

## Appendix C: Contact

- Email: haiboyi@szpu.edu.cn
- Institution: Shenzhen Polytechnic University, Shenzhen, China
- GitHub: https://github.com/cipher-pu

---

**Next steps after push**:

1. Update IEEE TCAS-I submission draft with live URL
2. Register Zenodo DOI (optional but recommended)
3. Add CI badge to paper figure captions
4. Circulate the pushed repository to internal reviewers for feedback
5. Consider adding more contributors via `.github/CODEOWNERS`

**Estimated time to push**: 30-60 minutes (depending on source file cleanup).
