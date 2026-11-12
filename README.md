# CIPHER-PU: Runtime-Adaptive CKKS Homomorphic Encryption FPGA Accelerator

**Runtime SNR-driven adaptive sparsity + DARE bootstrap-lite for edge-deployable privacy-preserving inference**

![CI](https://github.com/YI-HAIBO/cipher-pu/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Device](https://img.shields.io/badge/FPGA-Xilinx%20UltraScale%2B%20xcau25p-orange.svg)
![Security](https://img.shields.io/badge/Security-256--bit%20PQ-green.svg)

## Overview

CIPHER-PU is an FPGA-accelerated CKKS (Cheon-Kim-Kim-Song) Fully Homomorphic Encryption (FHE) accelerator designed for **edge-deployable, low-power privacy-preserving inference**. It targets the Xilinx UltraScale+ xcau25p device (141K LUT, 300 BRAM36, 1200 DSP48E2, no URAM) and achieves:

- **0.698 W** total on-chip power (routed, SAIF-annotated, High confidence)
- **48.01 MS/s** effective throughput, **1,702 MLP samples/s**, **988 CNN samples/s**
- **2.27× per-watt card-level efficiency** vs. Poseidon (Alveo U280, E42), 39.1× chip-level, and 14.6× / 58.4× when normalized per-LUT-per-card-watt (E54)
- **≥ 256-bit post-quantum security** (HE Standard v1.1, BKZ.sieve + BKZ.qsieve)
- **Runtime adaptive sparse feedback loop** (noise monitor + adaptive gear controller) — unique contribution
- **DARE bootstrap-lite** via decrypt-reencrypt — reduces noise growth from exponential to linear

## Key Contributions

1. **Runtime-Adaptive Sparse Feedback Loop**: Online SNR estimation drives automatic precision/sparsity trade-off. Unmatched by static baselines (HEAX, Poseidon, FAB).

2. **DARE Bootstrap-Lite**: Replaces full Gentry bootstrap with decrypt-reencrypt cycle, converting noise growth from exponential to linear across multiple layers.

3. **Structural Block Sparsity**: Block-level pruning integrated with CKKS polynomial multiplication, reducing compute while preserving encrypted inference precision.

4. **Edge-Oriented Design**: 7.05× smaller than Poseidon (103K module vs 728K LUT), 286× lower power, no HBM dependency.

## Device & Configuration

| Parameter | Value |
|-----------|-------|
| Device | Xilinx UltraScale+ xcau25p-ffvb676-1-e |
| CKKS N | 2^12 (LOG_N=12, production) / 2^13 (DSE sweet spot) |
| Q_WIDTH | 45 bits |
| Frequency | 100 MHz |
| WNS @100MHz | +0.176 ns post-route (synthesis: +2.438 ns) |
| Fmax ceiling | 101.80 MHz post-route |
| Power | 0.698 W (routed SAIF) |
| Security | ≥ 256-bit (BKZ.sieve) / ≥ 256-bit (BKZ.qsieve) |

## Quick Start

### Prerequisites

- **Vivado 2026.1** (used for synthesis, implementation and power)
- **Vivado xsim** (`xvlog` / `xelab` / `xsim`) for functional simulation
- **Python 3.11+** for scripts and testbench generation
- **OpenFHE** (optional) for cross-validation with CKKS parameters

### Installation

```bash
git clone https://github.com/YI-HAIBO/cipher-pu.git
cd cipher-pu
make verify     # Run functional simulation
make synth      # Run Vivado synthesis
make report     # Generate resource/timing reports
```

### Running the End-to-End Simulation

```bash
# Single testbench
make sim TB=tb_e2e_ckks_mult_ctrl_m4

# Full regression suite
make verify                      # Full regression (15 suites)
```

### Generating Testbench Reference Data

```bash
python scripts/gen_ntt_vectors.py        # NTT reference vectors
python scripts/gen_tb_e2e_vec.py         # End-to-end test vectors
```

## Directory Structure

```
cipher-pu/
├── rtl/                    # SystemVerilog RTL source
│   ├── m1/                 # NTT unit, butterfly (M1 milestone)
│   ├── m2/                 # Polynomial multiplication, keyswitch (M2)
│   ├── m3/                 # Rescale, e2e CKKS mult control (M3)
│   ├── m4/                 # Adaptive sparse, noise monitor, DARE (M4)
│   ├── m5/                 # RNS multi-modulus extension, twiddle ROM (M5)
│   └── m6/                 # Bitstream, board bring-up (M6 - not verified)
├── tb/                     # SystemVerilog testbenches
├── scripts/                # Python utility scripts
├── ip_repo/                # Generated Vivado IP (BRAM, etc.)
├── benchmarks/             # Throughput/power/energy metrics
├── reports/                # Experiment reports (E1-E54)
│   └── experiments/        # 54 experiment reports
├── docs/                   # Design documents
├── figures/                # Paper figures (SVG/PDF/PNG)
├── data/                   # Benchmark datasets & seeds
├── examples/               # End-to-end usage examples
├── LICENSE                 # Apache-2.0
├── Makefile                # Build/verify/synth entry points
├── CONTRIBUTING.md         # Contribution guidelines
├── CITATION.cff            # Academic citation metadata
├── CODE_OF_CONDUCT.md      # Contributor Covenant
├── SECURITY.md             # Security vulnerability reporting
├── ethics.md               # Ethics statement
└── data_availability.md    # Data availability statement
```

## Experiments

54 experiments conducted (E1-E54). See `reports/experiments/` for detailed reports:

| Experiment | Topic | Report |
|-----------|-------|--------|
| E1-E3 | Baseline CKKS implementation | `e1_*.md` |
| E4 | Rotation / Automorphism | `e4_rotation_bootstrap.md` |
| E5 | Adaptive sparse feedback | `e5_adaptive_sparse.md` |
| E6-E10 | Sparse sweep, precision, latency | `e6_*.md` - `e10_*.md` |
| E11-E15 | Rescale, DARE, throughput | `e11_*.md` - `e15_*.md` |
| E16-E20 | Power, area, timing, DSE | `e16_*.md` - `e20_*.md` |
| E21-E25 | Benchmark, Poseidon, HEAX comparison | `e21_*.md` - `e25_*.md` |
| E26-E29 | Security DSE, BKZ.sieve, BKZ.qsieve, E29 Poseidon | `e26_*.md` - `e29_*.md` |

## Performance Highlights

| Metric | CIPHER-PU | Poseidon (U280) | HEAX (Arria 10) | cuFHE (A100) |
|--------|:---:|:---:|:---:|:---:|
| samples/s | 1,702 | 14,031 | 20.5M | 800 |
| Power (W) | 0.698 | ~200 | ~25 | 250 |
| samples/s/W | **1,440** | 70.2 | 820 | 3.2 |
| ops/W | **4.06×10⁷** | 7×10⁴ | — | — |
| LUT | 113K | 728K | 690K | — |
| Security (bit) | ≥256 | — | — | ≥128 |

**CIPHER-PU achieves 2.27× per-watt card-level efficiency vs. Poseidon (E42), 39.1× chip-level, and 451× vs. cuFHE (A100); normalized per-LUT-per-card-watt it leads 14.6× / 58.4× (E54).**

## Security Analysis

All parameters verified with HomomorphicEncryption.org v1.1 standard:

| Parameter Set | N | LOG_N | Q_WIDTH | Classical (BKZ.sieve) | Post-Quantum (BKZ.qsieve) |
|:-------------:|:---:|:---:|:---:|:---:|:---:|
| S82 | 4096 | 12 | 45 | ≥256-bit (366 bit, E50) | ≥256-bit (335 bit, E50) |
| S90 | 8192 | 13 | 45 | ≥256-bit (812 bit, E50) | ≥256-bit (740 bit, E50) |
| S128 | 16384 | 14 | 45 | ≥256-bit (1795 bit, E50) | ≥256-bit (1632 bit, E50) |

Security levels computed with the E50 PrimalUSVP-GSA re-implementation, validated on all nine HE Standard v1.1 anchors within 4.4 bit (SageMath not available on the author's workstation).

## Design Principles

1. **Edge-Oriented**: 0.698 W power, single-chip deployment, no HBM dependency
2. **Runtime Adaptivity**: Noise feedback drives dynamic precision trade-off
3. **Post-Quantum Safe**: ≥256-bit security verified with HE Standard v1.1
4. **Reproducible**: Open-source RTL, testbenches, simulation scripts, vector generation
5. **Transparent**: All experiment data publicly archived in `reports/experiments/`

## Limitations

- **M6 bitstream + board bring-up not verified**: User explicitly excluded from scope. Reports marked accordingly.
- **Power anchor**: 0.698 W is the routed (post-P&R) SAIF measurement at 99% net
  annotation (High confidence); the earlier XPower static estimate of 1.182 W is retained
  in the experiment data for historical comparison only.
- **Poseidon RTL not open source**: Poseidon comparison uses four-source cross-reference (HPCA'23 + EFFACT 2025 + Anaheim HPCA'25 + Cheddar 2024).
- **LOG_N=14 (S128)**: Single module overflows 178% LUT on xcau25p; requires larger device (U280/xck260).
- **RNS depth extension (E37, M-D')**: A 3-prime 115-bit RNS path on xcku5p (3-way parallel, 13,600 LUT / 88 BRAM / 48 DSP) closes timing at 100 MHz (WNS +0.077 ns) and extends safe depth to 8-10 layers; routed power 0.647 W (SAIF).

## Citation

If you use CIPHER-PU in your research, please cite:

```bibtex
@misc{cipher-pu-2026,
  author       = {Yi, Haibo},
  title        = {CIPHER-PU: Runtime-Adaptive CKKS Homomorphic Encryption FPGA Accelerator for Edge Deployment},
  howpublished = {Submitted to IEEE TCAS-I},
  year         = {2026},
  url          = {https://github.com/YI-HAIBO/cipher-pu},
  note         = {Work in progress}
}
```

Or use `CITATION.cff` in your citation manager.

## Contributors

- **Yi Haibo** — School of Artificial Intelligence, Shenzhen Polytechnic University, Professor (PI)

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

## Contact

- Email: haiboyi@szpu.edu.cn
- ORCID: 0000-0002-1635-3738
- Institution: School of Artificial Intelligence, Shenzhen Polytechnic University, Shenzhen, China

---

**Version**: 1.0.0 (preprint)  
**Status**: Under review at IEEE TCAS-I  
**License**: Apache-2.0
