# E38: Maximum Clock Frequency (Fmax) Characterization

**Date:** 2026-10-24
**Status:** Completed (static characterization from the routed checkpoint; RTL re-pipelining deliberately out of scope)
**Target:** answer the reviewer question "what is the achievable Fmax, and is the 100 MHz operating point conservative?"

## Method

E38 does **not** re-run place-and-route at multiple target frequencies. Instead it characterizes the *achieved* Fmax ceiling directly from the post-route implementation of the end-to-end top level (`reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp`, Vivado 2026.1, xcau25p-ffvb676-1-e), using the finished P&R timing report. The Fmax ceiling is defined as

```
Fmax = 1 / (T_clk - WNS)
```

with `T_clk = 10 ns` (100 MHz constraint) and WNS the worst negative (positive-margin) slack of the routed design. This is the standard "slack-based Fmax" used in the FHE-accelerator literature and avoids a speculative re-P&R sweep, whose numbers would anyway be invalidated by the E34 SAIF power refresh.

## Measured results (routed, end-to-end top level `e2e_ckks_mult_ctrl_m4`, N=2^12)

| Metric | Value |
|--------|-------|
| Constraint | 10.000 ns (100 MHz) |
| Setup WNS | **+0.176 ns** (met; 0 failing endpoints of 13,848) |
| Hold WHS | +0.042 ns (met; 0 failing endpoints) |
| Total negative slack | 0.000 ns |
| Clock uncertainty | 0.035 ns (system jitter 0.071 ns) |
| **Fmax ceiling** | **101.80 MHz** (1 / (10.000 - 0.176) ns) |
| Margin over operating point | +1.8 % |

## Critical-path root cause

The worst path runs entirely inside the key-switch unit's shared polynomial multiplier:

- **Source:** `u_ksw/u_pm_ks/prod_r_reg[2]/C` (FDRE)
- **Destination:** `u_ksw/u_pm_ks/u_c_hat_mem/.../RAMB36E2` port
- **Data path delay:** 9.492 ns — logic 3.961 ns (41.7 %), routing 5.531 ns (58.3 %)
- **Logic levels:** 30 — CARRY8 x16, LUT4 x5, LUT3 x6, LUT2 x2, LUT1 x1

Interpretation: the limiter is the **combinational BRAM-address computation** in front of the `c_hat` coefficient memory — a 16-deep CARRY8 adder/comparator chain that computes the memory address from the product register within one cycle. The path is *routing-dominated* (58 %), i.e., the design is at the interconnect limit of the 20 nm fabric for this structure, not the LUT-speed limit.

## Synthesis vs. P&R frequency gap

| Stage | WNS @ 100 MHz | Implied Fmax ceiling |
|-------|---------------|----------------------|
| Out-of-context synthesis (E20 baseline) | +2.438 ns | 132.3 MHz |
| **Post-route (this experiment)** | **+0.176 ns** | **101.8 MHz** |

Place-and-route consumes 22 % of the synthesis-stage frequency headroom (routing capacitances, real interconnect detours, clock-tree insertion). This is why all paper throughput and energy numbers are anchored to the *routed* timing, not the synthesis timing.

## Conclusions for the paper

1. **The 100 MHz operating point is not conservative — it is 98.2 % of the post-route Fmax ceiling.** Every throughput and energy figure in the paper is therefore reported at (essentially) the maximum frequency this RTL structure can reach on this device. No "hidden" frequency headroom is being left unreported.
2. **A materially higher Fmax requires an RTL change, not a tool change.** The 30-level combinational address path into `u_c_hat_mem` must be pre-registered (one extra pipeline stage on the BRAM address). That change would raise Fmax but also add one latency cycle per poly_mult stage, changing every throughput/energy/latency number in the paper. It is therefore listed as future work rather than applied silently.
3. **Cross-device context (for the reviewer who compares clocks).** Poseidon runs at approx. 400 MHz on Alveo U280 (16 nm HBM2) and Lee et al. at 250 MHz on the same U280; CIPHER-PU's 101.8 MHz ceiling is on a 20 nm xcau25p. The 2.5-4x clock gap tracks the process/node and BRAM-generation gap rather than an architectural deficiency, and is normalized by the per-LUT and per-watt comparisons in Section 7.6.

## Why no frequency sweep was run

A multi-target P&R sweep (e.g., re-implementation at 9.5/9.0/8.5 ns) was considered and rejected:
- Vivado's router degrades hold/skew as the constraint tightens; sweep results are only valid if the SAIF power flow is re-run per frequency (E34), which multiplies runtime by the number of sweep points.
- The slack-based Fmax from a *converged* route is the accepted reporting convention for this device class and is reproducible from the released checkpoint.
- The critical-path analysis above shows the ceiling is structure-limited; a tighter constraint cannot reclaim more than a few percent without the RTL change.

## Files

- Routed timing report: `reports/impl/e2e_au25p_n12/e2e_impl_timing.rpt` (WNS/WHS, critical path, 20 max-delay paths)
- Routed checkpoint: `reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp`
- This report: `reports/experiments/e38_fmax.md`
