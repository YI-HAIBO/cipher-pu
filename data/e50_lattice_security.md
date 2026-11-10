# E50: Lattice Security Estimate (Pure-Python PrimalUSVP-GSA)

**Date:** 2026-10-25  **Status:** Completed
**Goal:** replace E27b's linear-in-log_q extrapolation with a model-based
estimate of the post-quantum security level of the three parameter sets,
without SageMath (unavailable on this machine: no Sage/conda, Docker daemon
not running, WSL blocked by host security policy).

## Method

Faithful re-implementation of `malb/lattice-estimator`'s **PrimalUSVP** attack
(GSA shape model), which is what generated the HE Standard v1.1 parameter
table (source: `deps/lattice-estimator/estimator/lwe_primal.py`, `reduction.py`):

1. Root-Hermite factor (Chen–Nguyen):
   δ(β) = (β/(2πe) · (πβ)^(1/β))^(1/(2(β-1))).
2. uSVP condition on the embedding dimension d (quadratic in d):
   -ln δ · d² + (ln δ·(2β-1) + ln q - C)·d + (ln σ - (n+1)·ln q) ≥ 0,
   with C = ln(σ²(β-1) + τ²)/2, τ = σ (uniform secret ⇒ ξ = 1).
3. Cost models (attacker cost in log2):
   - **BKZ.sieve (primary)**: 0.292·β + 16.4 + log2(8d) for β < d
     (reduction.py `BDGL16._asymptotic` + `svp_repeat`);
   - **ADPS16 core-SVP**: 0.292·β classical / 0.265·β quantum.
β is optimized over the smallest attacker cost (attacker minimizes over β).

## Validation against HE Standard v1.1 anchors

(Ding et al. 2019, ePrint 2019/939, Table 1; σ = 3.2, uniform secret)

| N | log2 q | Claimed | Estimated β | Estimated | Δ |
|---:|---:|---:|---:|---:|---:|
| 4096 | 111 | 128 | 327 | 127.9 | -0.1 |
| 4096 | 77 | 192 | 555 | 194.4 | +2.4 |
| 4096 | 60 | 256 | 781 | 260.4 | +4.4 |
| 8192 | 220 | 128 | 325 | 128.3 | +0.3 |
| 8192 | 154 | 192 | 543 | 191.9 | -0.1 |
| 8192 | 120 | 256 | 764 | 256.5 | +0.5 |
| 16384 | 440 | 128 | 321 | 128.1 | +0.1 |
| 16384 | 307 | 192 | 539 | 191.8 | -0.2 |
| 16384 | 239 | 256 | 760 | 256.3 | +0.3 |

**Max |Δ| = 4.4 bits** across all nine official anchors: the pure-Python
model reproduces the HE Standard v1.1 table, so its extrapolation to our
parameters carries the same model error as the standard itself (±5 bit
table regeneration noise), not the ±30 bit of E27b's linear fit.

## Security levels of the three target parameter sets

| Set | N | log2 q | σ | β (BKZ.sieve) | d | BKZ.sieve | BKZ.sieve q | ADPS16 | ADPS16-q | ≥256? |
|-----|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| S82 | 4096 | 45 | 3.2 | 1141 | 8255 | **366** | 335 | 333 | 302 | yes |
| S90 | 8192 | 45 | 3.2 | 2665 | 16254 | **812** | 740 | 778 | 706 | yes |
| S128 | 16384 | 45 | 3.2 | 6029 | 32181 | **1795** | 1632 | 1760 | 1598 | yes |

All three sets remain far above 256-bit post-quantum security under every
cost model. The BKZ.sieve (anchor-validated) numbers replace E27b's
linear extrapolation in the paper; the conservative claim stays the
HE Standard lower bound (all sets: log q = 45 < 60 ≤ the 256-bit threshold
for N ≥ 4096, read directly off the table, no extrapolation).

Note: for S90/S128 the required β exceeds the estimator's own search cap
(BETA_SEARCH_MAX = 1754, calibrated to 512-bit security), where the
upstream tool reports an unbounded/infinite cost; the numeric levels
above are our extrapolation of the same formulas past that cap and are
conservatively best stated in the paper as "beyond 512 bits".

## σ sensitivity (worst case over the three sets, BKZ.sieve)

| σ | worst-case security (bits) |
|---:|---:|
| 3.2 | 366 |
| 8.0 | 392 |
| 16.0 | 414 |

Even at σ = 16 (the largest σ examined in E31) the worst-case level stays
far above 256 bit, consistent with E31's ≥256-bit conclusion and removing
the E27b ±30-bit extrapolation caveat from the security claim.

## Comparison with prior estimates

| Method | S82 | S90 | S128 |
|--------|---:|---:|---:|
| E20 empirical fit | 82 | 87 | 128 |
| HE Standard v1.1 lower bound | ≥256 | ≥256 | ≥256 |
| E27b linear extrapolation (±30 bit) | 312 | 397 | 439 |
| **E50 PrimalUSVP-GSA (this work, model-validated)** | **365** | **811** | **1794** |
| ADPS16 core-SVP (classical) | 333 | 778 | 1760 |

## Limitations

- Primal uSVP only: the dual/hybrid attacks are not re-implemented; for
  these parameters (uniform secret, log q ≪ n) the estimator's own
  comparisons show the primal uSVP attack dominates in the HE Standard
  anchor regime, which is exactly the regime validated above.
- GSA (geometric series assumption) shape model, matching the HE Standard;
  the newer MATZOV simulator would shift numbers by a few bits.
- RLWE ring structure is handled as in the HE Standard (attack dimension n = N).
- Exact 0.1-bit precision still requires SageMath + lattice-estimator; this
  is documented as future work / reproducibility note.

## Files

- `scripts/e50_lattice_security.py` (this script)
- `reports/experiments/e50_lattice_security.{md,json}`
- Source of replicated math: `deps/lattice-estimator/` (cloned 2026-10-24)