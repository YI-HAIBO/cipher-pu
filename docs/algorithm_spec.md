# Algorithm Specification

## CKKS Scheme Overview

CKKS is a somewhat homomorphic encryption scheme supporting approximate
arithmetic on encrypted floating-point numbers.

### Parameters

- **N**: Ring dimension, power of 2 (N=2^12 for production)
- **q**: Ciphertext modulus (Q_WIDTH = 45 bits)
- **σ_s**: Secret key distribution (uniform discrete for HE Standard v1.1)
- **σ_e**: Error distribution (Gaussian, σ_e = 3.2)
- **Δ**: Scaling factor (2^30 for 30-bit precision)

### Operations

- **Add**: Plaintext or ciphertext + ciphertext
- **Mul**: Ciphertext × ciphertext (with rescaling)
- **Rot**: Rotation by k slots (via automorphism)
- **Rescale**: Reduce modulus after multiplication
- **Bootstrap**: Restore noise budget (DARE variant)

## NTT (Number Theoretic Transformation)

Radix-4 implementation for N=2^12:

```
Log stages = LOG_N / 2 = 6
Per stage: N/4 butterfly ops
Twiddle factor: exp(2πi/N) mod q
Reduction: fast-red (Montgomery-like)
```

Complexity: O(N log N), memory: N polynomials of Q_WIDTH bits.

## fast-red Reduction

Montgomery-like reduction for polynomial mult:

```
r = (a × b) mod q
fast-red:
  t = a × b
  m = (t × q_inv) mod 2^k
  r = (t + m × q) / 2^k
```

Optimized for 45-bit modulus: single-cycle, no LUT.

## DARE Bootstrap-Lite

Decrypt-reencrypt cycle to extend noise budget:

1. **Decrypt**: ct_new = decrypt(ct) (reveals approximate plaintext)
2. **Fresh encrypt**: ct_new = encrypt(plaintext)
3. **Noise reset**: New error term, linear growth across bootstrap

Cost: ~5× faster than full Gentry bootstrap, requires secret key.

## Structural Block Sparsity

Block-level sparsity with runtime adaptation:

1. **Partition**: Split plaintext into B blocks of size N/B
2. **Identify**: Detect zero-sparse blocks (|coeff| < threshold)
3. **Route**: Sparse blocks → bypass path (skip poly mult)
4. **Merge**: Reconstruct result from sparse + dense blocks

Adaptation:
- noise_monitor samples ciphertext coefficients
- Computes SNR = signal_power / noise_power
- Adaptive_gear_ctrl selects sparse/dense path per block

## Noise Budget Tracking

Online tracking across operations:

```
σ²_e(n+1) = σ²_e(n) × (1 + 2N) + σ²_s × (2N - 1)
```

- Rescaling: σ²_e increases by factor (2N - 1)
- Multiplication: σ²_e increases by factor (2N - 1)
- Rotation: σ²_e increases by factor 2
- Bootstrap (DARE): σ²_e resets to σ²_e_initial

## References

- Cheon et al., "Fast Fully Homomorphic Encryption Over the Integers". EuroS&P 2017.
- Albrecht et al., "HomomorphicEncryption.org v1.1". 2024.
- Details in `reports/experiments/` for full derivation.
