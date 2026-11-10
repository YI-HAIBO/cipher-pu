# E34: Routed (Post-P&R) Power — Default Activity vs SAIF Gate-Level

**Date:** 2026-10-24  |  **Status:** Completed (both steps)  |  **Total runtime:** 45.7 min (step 2)

**Goal:** upgrade the power anchor from the E30 out-of-context (OOC) synthesis DCP to the
**routed** implementation (`reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp`, the same 100 MHz
P&R checkpoint that produced WNS +0.176 ns), removing the "implementation-state confidence Low"
caveat from the paper's power claims.

## Step 1 — Routed DCP, default (Vivado assumption) activity

`report_power -no_propagation` on the routed checkpoint:

| Metric | Value |
|--------|------:|
| Total on-chip power | 1.295 W |
| Dynamic | 0.836 W |
| Device static | 0.458 W |
| Confidence | Medium |
| CLB logic | 0.296 W |
| Signals | 0.207 W |
| Block RAM | 0.292 W |
| DSPs | 0.021 W |

## Step 2 — Routed DCP + SAIF from gate-level simulation of the routed netlist

Pipeline (reuses the E30 SAIF toolchain, `scripts/gl_power/`):

1. `write_verilog -mode funcsim` on the routed DCP (123 s) — preserves RTL-era net names.
2. Strip the Vivado protected region (lines 1,887,010–1,958,609) → Icarus-compatible netlist (147 s compile).
3. Gate-level simulation with the E30 traffic vector (vvp, 1,869 s, **VCD 4.79 GB**).
4. `vcd_to_saif.py` conversion with TB-hierarchy stripping + routed-DCP name filtering (454 s).
5. `read_saif -strip_path e2e_ckks_mult_ctrl_m4` + `report_power` on the routed DCP (145 s).

**Result:**

| Metric | Value |
|--------|------:|
| Total on-chip power | **0.698 W** |
| Dynamic | **0.244 W** |
| Device static | 0.454 W |
| **Confidence** | **High** |
| Design nets matched | **99% (393,749 / 398,749)** |
| Design state | **routed** |
| Clocks | 0.018 W |
| CLB logic | 0.007 W |
| Signals | 0.011 W |
| **Block RAM** | **0.201 W** (180/300 = 60% util) |
| DSPs | 0.008 W (75/1,200) |

## Cross-anchor comparison (all on the same routed DCP)

| Metric | Default activity | SAIF (gate-level sim) | Delta |
|--------|------:|------:|------:|
| Total | 1.295 W | **0.698 W** | **-46.1%** |
| Dynamic | 0.836 W | 0.244 W | -70.8% |
| CLB logic | 0.296 W | 0.007 W | **-97.6% (42.3x overestimate)** |
| Signals | 0.207 W | 0.011 W | -94.7% |
| Block RAM | 0.292 W | 0.201 W | -31.2% |
| DSPs | 0.021 W | 0.008 W | -62.0% |

## Anchor evolution

| Anchor | Implementation state | Activity source | Total | Confidence |
|--------|----------------------|------------------|------:|----------:|
| E13 (XPower) | routed | default | 1.182 W | — |
| E34 step 1 | routed | default | 1.295 W | Medium |
| E30 | **OOC synthesis** | SAIF, 99% | 0.824 W | High |
| **E34 step 2** | **routed** | **SAIF, 99%** | **0.698 W** | **High** |

The routed SAIF figure is **15.3% below** the OOC SAIF figure (dynamic 0.244 vs 0.369 W, -33.9%):
post-routing optimization (glitch-free routed netlist, accurate interconnect RC) lowers real
dynamic power relative to the OOC estimate with BRAM stubs. The 0.454–0.458 W device-static
floor is essentially unchanged (resource-usage driven).

## Key findings

1. **Headline power revised: 0.698 W** (routed, SAIF, High confidence, 99% annotation). This
   supersedes the 0.824 W OOC anchor used since E30 and removes the
   "implementation-state confidence Low" limitation from the paper.
2. **The "default 50% toggle rate is wildly conservative" conclusion strengthens at the routed
   level too:** CLB logic is overestimated 42.3x (0.296 vs 0.007 W) and dynamic power overall
   3.4x. Any FPGA HE-accelerator power number reported without SAIF/VCD activity should be
   assumed to be several-fold high.
3. **Memory-bound conclusion holds:** BRAM is 82.4% of routed dynamic power (0.201/0.244 W) and
   is the *least* overestimated resource under default activity (1.45x). The design's dynamic
   power is dominated by 180 RAMB36E2 blocks, exactly as the E30 OOC analysis concluded
   (u_ksw 39.6%, u_pm_shared 20.3% at OOC level; the routed netlist is flattened, so
   module attribution is only available at OOC level).
4. **Still chip-level, not board-level:** the 0.454 W is the xcau25p device static floor;
   no board measurement exists (M6 not performed). Card-level comparisons continue to use the
   12 W documented card power.

## Derived metric revisions (paper-wide)

Carrier quantities: 48 MOPS (E17/E21 measured), 468.84 effective poly_mult/s, 1,702 MLP samples/s,
988 CNN samples/s.

| Metric | Old (0.824 W) | **New (0.698 W)** |
|--------|------:|------:|
| Energy efficiency | 58.3M ops/J | **68.8M ops/J** |
| vs cuFHE A100 (4.5M ops/J) | 13.0x | **15.3x** |
| vs CPU OpenFHE (118 ops/J) | 494Kx | **583Kx** |
| CNN samples/W | 1,199 (vs A100 1,250: "approaches") | **1,415 (vs A100 1,250: exceeds by 1.13x)** |
| Energy per effective poly_mult | 1.757 mJ | **1.489 mJ** |
| MLP chip-level samples/s/W | 2,065 | **2,438** |
| MLP chip-level energy/sample | 0.484 mJ | **0.410 mJ** |
| Chip-level upper bound vs Poseidon | 33.1x | **39.1x** |

Card-level comparisons (141.8 vs 62.4 samples/s/W; 7.05 vs 16.0 mJ/sample; 2.27x) are anchored on
documented card powers (12 W vs 225 W) and are **unchanged** by the chip-power revision.

## Files

- Reports: `reports/experiments/e34_routed_power/e34_routed_default.rpt` (step 1),
  `e34_routed_saif.rpt` (step 2), `e34_step{1,2a-2e}.log`
- SAIF: `scripts/gl_power/out_routed/routed.saif`
- Driver: `scripts/run_e34_step2.py`, TCL: `scripts/e34_routed_{netlist,power,saif_power}.tcl`
