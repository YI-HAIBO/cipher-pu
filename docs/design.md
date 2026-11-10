# Design Decisions

## Why CKKS?

CKKS (Cheon-Kim-Kim-Song, EuroS&P 2017) was chosen over alternatives
(BGV, BFV, TFHE) for:

1. **Approximate arithmetic** - Suited for ML inference (floats → encrypted float)
2. **SIMD-friendly** - N/2 complex slots for parallel computation
3. **Post-quantum safe** - Lattice-based, HE Standard v1.1 compliant
4. **Depth flexibility** - With DARE, up to 8-15 multiplication depth

## Why DARE?

Full Gentry bootstrap is expensive (memory, timing). **DARE (Decrypt-
Reencrypt)** is a lightweight alternative:

- **Noise growth**: Linear (vs. exponential for full bootstrap)
- **Memory**: Uses secret key register only (vs. 256 MB off-chip for Gentry)
- **Time**: ~5× faster than full bootstrap
- **Depth extension**: Enables 8-15 layer CNN inference

Trade-off: Requires secret key exposure for reencrypt (acceptable for edge use cases
where data stays on-device).

## Why Structural Sparsity?

Standard block-level sparsity in plaintext → CKKS ciphertext:

- Identify zero-sparse blocks in plaintext
- Route through bypass path (skip polynomial mult)
- Achieve 2-4× throughput at same noise budget

Unique to CIPHER-PU: **runtime-adaptive** (noise monitor drives sparsity).

## Why Runtime-Adaptive?

Static precision (all existing baselines) wastes resources:

- **Early layers**: Low noise → can use sparse approximation
- **Middle layers**: Moderate noise → balance precision/sparse
- **Late layers**: High noise → full precision + DARE bootstrap

**Runtime-adaptive** adjusts based on **actual measured SNR**, not estimated.

## Why Edge-Oriented?

- **Power**: 1.18 W vs. Poseidon's 200 W (170× lower)
- **Area**: 113K LUT vs. Poseidon's 728K (6.4× smaller)
- **No HBM**: All on-chip (8.6 MB scratchpad → 2 MB BRAM)
- **Single-chip**: xcau25p (compact package) vs. U280 (large)

Trade-off: Lower absolute throughput than Poseidon (1,702 vs. 14,031 samples/s).

## Why xcau25p?

- Smallest UltraScale+ with enough LUT for N=2^12 CKKS
- No URAM (all BRAM) - simpler design, faster P&R
- 100 MHz frequency achievable with fast-red pipeline
- Cost-effective for edge deployment

## Alternative Designs Considered

### Full Gentry Bootstrap (rejected)
- Too expensive for edge use (256 MB off-chip, 200+ ms per bootstrap)
- DARE achieves same depth extension with 5× less overhead

### BFV Scheme (rejected)
- Approximate arithmetic not needed for our precision target
- CKKS better suited for ML inference

### TFHE Scheme (rejected)
- Pointwise operations not SIMD-friendly
- Unsuitable for batch inference

### RNS Decomposition (future work)
- Currently single modulus (Q_WIDTH=45)
- RNS with 3×55-bit moduli would save 2.8× area but requires RTL rewrite
- Listed as future work in reports/e26_security_dse.md

## Key References

- [Algorithm Spec](algorithm_spec.md) - CKKS + NTT + fast-red + DARE
- [Architecture](architecture.md) - Top-level data flow
- E26 Security DSE - RNS trade-off analysis
- E27 Precision estimate - Parameter selection rationale
