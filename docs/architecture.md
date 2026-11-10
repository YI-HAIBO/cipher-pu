# System Architecture

## Top-Level Data Flow

```
                    +------------------+
                    |  Host Interface  |
                    |  (AXI4 Stream)   |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  Input Loader    |
                    |  (CT load)       |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  NTT Unit (M1)   |
                    |  (Radix-4)       |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  Poly Mult (M2)  |
                    |  (Pointwise)     |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  INTT Unit (M1)  |
                    |  (Radix-4)       |
                    +--------+---------+
                             |
              +--------------+--------------+
              |              |              |
     +--------v--+   +-------v-----+   +---v---------+
     | Rescale   |   | Noise       |   | Output      |
     | (M3)      |   | Monitor (M4)|   | Store       |
     +--------+--+   +-------+-----+   +-------------+
              |             |
              |    +--------v---------+
              +--> | Adaptive Gear   |
                   | Controller (M4) |
                   +--------+--------+
                            |
                   +--------v--------+
                   | DARE Boot-      |
                   | Strap-Lite (M4) |
                   +-----------------+
```

## Milestones

### M1: NTT Unit
- Radix-4 butterfly network
- Twiddle factor ROM (BRAM)
- fast-red reduction

### M2: Polynomial Multiplication
- NTT → pointwise mult → INTT
- Keyswitch pipeline
- Backpressure handling

### M3: Rescale & E2E Control
- Rescale FSM (RNS → mod switch)
- Noise budget tracking
- E2E mult control

### M4: Adaptive Sparse Feedback
- **Noise Monitor**: Online SNR estimation
- **Adaptive Gear Controller**: Runtime precision/sparsity trade-off
- **DARE Bootstrap-Lite**: Decrypt-reencrypt cycle
- **Structural Block Sparsity**: Block-level pruning

### M5: XDC & Synthesis
- Clock constraints (100 MHz)
- I/O placement
- Timing closure
- Design space exploration (DSE)

### M6: Board Bring-up (NOT VERIFIED)
- Bitstream generation
- ILA logic analyzer
- Timing verification on silicon

## Clock Domains

Single clock domain: `clk_100mhz` (100 MHz)

All modules are synchronous with global reset. No CDC required.

## Memory Map

| Address | Type | Purpose |
|---------|------|---------|
| 0x0000_0000 | BRAM | Plaintext input buffer |
| 0x0000_1000 | BRAM | Ciphertext A |
| 0x0000_2000 | BRAM | Ciphertext B |
| 0x0000_3000 | BRAM | Product ciphertext |
| 0x0000_4000 | BRAM | Output buffer |
| 0x0000_5000 | BRAM | NTT twiddle factors |

## Key Modules

### noise_monitor.sv
Online SNR estimation:
- Samples ciphertext coefficients every cycle
- Computes moving average of variance
- Outputs SNR estimate to gear controller

### adaptive_gear_ctrl.sv
Runtime precision/sparsity trade-off:
- SNR above threshold → full precision
- SNR below threshold → sparse approximation
- SNR critically low → DARE bootstrap trigger

### dare_bootstrap_lite.sv
Decrypt-reencrypt cycle:
- Decrypts ciphertext with secret key
- Freshly encrypts result
- Noise growth: linear (vs. exponential for full Gentry bootstrap)

### block_sparse_mask.sv
Block-level sparsity:
- Identifies zero-sparse blocks in plaintext
- Routes them through bypass path
- Reduces polynomial multiplication count

## Configuration

CKKS parameters (production):
- N = 2^12 (LOG_N = 12)
- Q_WIDTH = 45 bits
- σ_e = 3.2 (Gaussian error)
- Multiplicative depth: 2-3 (with DARE)

All parameters configurable via `parameters.svh`.

## References

- Cheon et al., "Fast Fully Homomorphic Encryption Over the Integers" (CKKS). EuroS&P 2017.
- Albrecht et al., "HomomorphicEncryption.org v1.1". 2024.
- See also: [Design Decisions](design.md), [Algorithm Spec](algorithm_spec.md)
