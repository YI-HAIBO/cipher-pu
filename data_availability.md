# Data Availability Statement

## Overview

All data used in this work are available from the corresponding authors upon
reasonable request. Most datasets are from public sources.

## Public Datasets

| Dataset | Source | License |
|---------|--------|---------|
| MNIST | [http://yann.lecun.com/exdb/mnist/](http://yann.lecun.com/exdb/mnist/) | Public Domain |
| CIFAR-10 | [https://www.cs.toronto.edu/~kriz/cifar-10.html](https://www.cs.toronto.edu/~kriz/cifar-10.html) | CC-BY-4.0 |
| CKKS parameters | OpenFHE, SEAL | Apache-2.0 / Apache-2.0 |
| Lattice security estimates | HomomorphicEncryption.org v1.1 | Public Domain |

## Generated Data

The following data were generated during experiments and are available in the
`data/` directory:

| Data | Description | Location |
|------|-------------|----------|
| Vector files | Test vectors for simulation | `tb/ref/*.hex` |
| Sweep results | Sparse/precision/latency sweeps | `reports/experiments/*.json` |
| Benchmark data | Performance and power metrics | `benchmarks/` |
| Synthesis reports | Vivado synthesis outputs | `reports/impl/` (partial) |

## Reproducibility

All experiments can be reproduced by following:

1. Clone this repository: `git clone https://github.com/YI-HAIBO/cipher-pu.git`
2. Install prerequisites: Vivado 2026.1 (with xsim), Python 3.11+ (`pip install -r scripts/requirements.txt`)
3. Run experiments: `make verify` for functional simulation, `make sim TB=<name>` for a single testbench, `make exp EXP=e39` for a single experiment
4. Consult individual experiment reports in `reports/experiments/` for specific parameters

## Random Seed

All random operations use seed 42 for reproducibility. Seed configuration is documented in each experiment script under `scripts/` (see `scripts/exp_e*.py`).

## Contact

For data access requests, contact: haiboyi@szpu.edu.cn

---

**Version**: 1.0  
**Last Updated**: 2026-10-24
