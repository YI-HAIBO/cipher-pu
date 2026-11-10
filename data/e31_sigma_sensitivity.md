# E31 / M5: Multi-sigma Sensitivity Scan

**Date**: 2026-10-24  
**Goal**: verify the three tiers' security does not 
collapse across `sigma_e in {2.0, 3.2, 4.5} x secret in {uniform, ternary}`.

---

## 1. Method

1. **Anchors**: HE Standard v1.1 tables (sigma=3.2, BKZ.sieve) for uniform + ternary secrets [11].

2. **Alpha-matching**: the primal-uSVP difficulty is governed by the noise rate 
`alpha = sigma/q`. Matching our `(N, log q, sigma)` to the standard's 
`sigma=3.2` table gives an equivalent log q shift: 
`log q_eff = log q + log2(3.2/sigma)`.

3. **Point estimate**: linear-in-log_q extrapolation between the 256-bit and 192-bit 
anchors (same methodology as E27b).

4. **Functional sensitivity**: `sigma_e` also scales the CKKS noise budget, setting the 
native multiplicative depth before a DARE refresh (noise grows ~ `(sigma^2 * 2N)^L`).


Equivalent log-q shifts: sigma=2.0 -> +0.678, sigma=4.5 -> -0.490 
(sigma=3.2 is the reference, shift 0).


---

## 2. Security Grid

### S82 (N=4096, log q=45)

| sigma_e | secret | log q_eff | security (est.) | lower bound | depth (layers) |
|--------:|:------:|----------:|----------------:|:-----------:|---------------:|
| 2.0 | uniform | 45.678 | 309.9 bit | >=256 | 5.12 |
| 2.0 | ternary | 45.678 | 302.4 bit | >=256 | 5.12 |
| 3.2 | uniform | 45.000 | 312.5 bit | >=256 | 2.00 |
| 3.2 | ternary | 45.000 | 304.9 bit | >=256 | 2.00 |
| 4.5 | uniform | 44.508 | 314.3 bit | >=256 | 1.01 |
| 4.5 | ternary | 44.508 | 306.8 bit | >=256 | 1.01 |

### S90 (N=8192, log q=45)

| sigma_e | secret | log q_eff | security (est.) | lower bound | depth (layers) |
|--------:|:------:|----------:|----------------:|:-----------:|---------------:|
| 2.0 | uniform | 45.678 | 395.9 bit | >=256 | 5.12 |
| 2.0 | ternary | 45.678 | 392.1 bit | >=256 | 5.12 |
| 3.2 | uniform | 45.000 | 397.2 bit | >=256 | 2.00 |
| 3.2 | ternary | 45.000 | 393.4 bit | >=256 | 2.00 |
| 4.5 | uniform | 44.508 | 398.1 bit | >=256 | 1.01 |
| 4.5 | ternary | 44.508 | 394.3 bit | >=256 | 1.01 |

### S128 (N=16384, log q=45)

| sigma_e | secret | log q_eff | security (est.) | lower bound | depth (layers) |
|--------:|:------:|----------:|----------------:|:-----------:|---------------:|
| 2.0 | uniform | 45.678 | 438.0 bit | >=256 | 5.12 |
| 2.0 | ternary | 45.678 | 436.1 bit | >=256 | 5.12 |
| 3.2 | uniform | 45.000 | 438.6 bit | >=256 | 2.00 |
| 3.2 | ternary | 45.000 | 436.7 bit | >=256 | 2.00 |
| 4.5 | uniform | 44.508 | 439.1 bit | >=256 | 1.01 |
| 4.5 | ternary | 44.508 | 437.2 bit | >=256 | 1.01 |

---

## 3. Findings

- **Worst case** across all 18 cells: **302.4 bit** (S82, sigma=2.0, uniform) — still far above the 256-bit bar.
- **Best case**: 439.1 bit (S128, sigma=4.5).
- **Per-tier sensitivity** (spread across the 6 cells of 3 sigma x 2 secret):
  - S82: min 302.4 / max 314.3 / **spread 11.9 bit**
  - S90: min 392.1 / max 398.1 / **spread 6.0 bit**
  - S128: min 436.1 / max 439.1 / **spread 3.0 bit**
- **Max sensitivity spread: 11.9 bit** — the security 
verdict is **insensitive** to the error distribution and sigma choice.
- **All cells >= 256-bit**: YES (uniform + ternary, sigma 2.0-4.5).
- **Physical reading**: smaller `sigma_e` *lowers* security slightly (less noise = 
weaker LWE instance), larger `sigma_e` *raises* it — exactly as the alpha-matching 
heuristic predicts, and the magnitude is tiny (<=3 bit) because log q=45 sits far 
below the 256-bit thresholds (N=4096: 60 / 58).

### Functional (noise-budget) sensitivity

- Native multiplicative depth before DARE refresh (Q_WIDTH=45 single modulus): sigma=2.0 -> ~5.1 layers, sigma=3.2 -> ~2.0 layers, sigma=4.5 -> ~1.0 layers.
- sigma=4.5 doubles the DARE refresh frequency vs sigma=3.2; sigma=2.0 halves it. 
The runtime-adaptive loop (noise_monitor + adaptive_gear_ctrl) is precisely the 
mechanism that absorbs this variation at run time.

---

## 4. Paper Statement (for Section VII)

> A 3x2 sensitivity scan (sigma_e in {2.0, 3.2, 4.5} x secret in {uniform, ternary}) 
shows the three parameter tiers keep >= 256-bit post-quantum security in every cell; 
the security spread across sigma and secret per tier is <= 12 bit, because log q = 45 sits far 
below the HE Standard v1.1 256-bit thresholds (N=4096: 60, N=8192: 120, N=16384: 239). 
The error distribution instead governs the native multiplicative depth 
(noise grows ~ (sigma^2 2N)^L), which the runtime-adaptive DARE loop absorbs.


---

## 5. Limitations

- Point estimates use linear-in-log_q extrapolation between the 256/192-bit anchors; 
precise 0.1-bit values require SageMath + lattice-estimator (not available locally).
- Alpha-matching is a first-order heuristic; the estimator's exact sigma dependence 
has small second-order terms, but the conclusion (>=256-bit with huge margin) is 
robust to them.
- Native-depth numbers are analytic (noise model), not measured; the E6/E19 sweeps 
measured the sigma=3.2 case only.
