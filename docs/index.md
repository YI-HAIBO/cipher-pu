# Documentation Index

Welcome to the CIPHER-PU documentation. This project accelerates CKKS
(Cheon-Kim-Kim-Song) Fully Homomorphic Encryption on Xilinx UltraScale+ FPGAs.

## Getting Started

- [Quick Start](quickstart.md) - Install, run simulation, generate reports
- [Installation](installation.md) - Vivado, Python, OpenFHE setup
- [Frequently Asked Questions](faq.md) - Common issues and solutions

## Architecture

- [System Architecture](architecture.md) - Top-level design, data flow, clock domains
- [Design Decisions](design.md) - Why we chose CKKS, DARE, and structural sparsity
- [Algorithm Specification](algorithm_spec.md) - CKKS + NTT + fast-red + DARE

## Modules

- [M1: NTT Unit](m1_ntt.md) - Butterfly network, radix-4, twiddle factor
- [M2: Polynomial Multiplication](m2_poly_mult.md) - NTT + pointwise + INTT, keyswitch
- [M3: Rescale & E2E Control](m3_rescale.md) - Rescale FSM, noise budget tracking
- [M4: Adaptive Sparse Feedback](m4_adaptive.md) - Noise monitor, gear controller, DARE
- [M5: XDC & Synthesis](m5_synthesis.md) - Constraints, timing closure, DSE
- [M6: Board Bring-up](m6_bringup.md) - Bitstream, ILA, timing verification (NOT VERIFIED)

## Algorithms

- [NTT Algorithm Spec](ckks_ntt_algorithm_spec.md) - Full specification
- [DARE Bootstrap-Lite](dare.md) - Decrypt-reencrypt cycle, noise analysis
- [Structural Block Sparsity](sparse.md) - Block-level pruning design
- [Noise Budget Tracking](noise_budget.md) - Online SNR estimation

## Experiments

- [E1-E29 Overview](../reports/experiments/) - All experiment reports

## Reports

- [Paper Draft](../reports/paper_tcas_draft.md) - IEEE TCAS-I submission
- [Experiment Summary](../reports/experiments/EXPERIMENT_SUMMARY.md) - All experiments
- [Algorithm Innovation Plan](../reports/algorithm_innovation_plan.md) - Roadmap

## References

- Cheon, et al. "Fast Fully Homomorphic Encryption Over the Integers" (CKKS). 2017.
- Albrecht, et al. "HomomorphicEncryption.org v1.1: Standard and Recommendations". 2024.
- Albrecht, et al. "lattice-estimator" (BKZ.sieve, BKZ.qsieve). GitHub: malb/lattice-estimator.
- Yang, et al. "Poseidon: Practical FHE Accelerator". HPCA 2023.
- Fab, et al. "FAB: Fully-parallel Accelerator for Bootstrappable FHE". ISCA 2022.
- OpenFHE: https://github.com/openfheorg/openfhe-development
- SEAL: https://github.com/microsoft/seal
