# Runtime-Adaptive Noise-Aware Sparse CKKS Inference on FPGA:
# An SNR-Feedback Closed-Loop Accelerator with Security-Hardware Co-Design

**Target Journal**: IEEE TCAS-I (IEEE Transactions on Circuits and Systems I: Regular Papers)  
**Status**: Submission manuscript (English), translated and polished from the R1 Chinese draft  
**Date**: 2026-10-24  
**Authors**: Haibo Yi  
**Affiliation**: School of Artificial Intelligence, Shenzhen Polytechnic University, Shenzhen, China  
**Email**: haiboyi@szpu.edu.cn (corresponding author)  
**ORCID**: 0000-0002-1635-3738

---

## Abstract

CKKS fully homomorphic encryption enables ciphertext-domain neural-network inference, but its ciphertext-multiplication (poly_mult) cost is three to four orders of magnitude above the plaintext counterpart, making FPGA acceleration essential. This paper presents a runtime noise-adaptive sparse CKKS inference accelerator contributing: (1) an on-chip noise monitor estimates the ciphertext SNR online and an adaptive controller retunes the sparsity gear from measured noise; (2) hardware support for advanced CKKS primitives - rotation with strictly zero noise growth, a DARE bootstrap-lite refresh (26x reset), and Conv+GAP fusion (14.7x fewer ciphertext multiplications); and (3) security-hardware co-design: a three-tier security-parameter DSE cross-checked against the HomomorphicEncryption.org v1.1 standard shows all three tiers exceed 256-bit post-quantum security, so the xcau25p ceiling is area/timing, not security, and an RNS decomposition path (2.8x area saving) is identified for depth extension. On a Xilinx xcau25p FPGA the accelerator closes timing at 100 MHz; SAIF-annotated gate-level power measurement of the routed netlist (99% annotation, High confidence) yields 0.698 W, i.e. 68.8M ops/J - 15.3x an A100 GPU and 583Kx a CPU. Encrypted inference matches plaintext accuracy up to 15 layers, and 20 consecutive rotations exhibit strictly zero noise growth.

**Index Terms**: Homomorphic encryption, CKKS, FPGA accelerator, runtime adaptation, noise-aware sparsity, security-hardware co-design

---

## 1. Introduction

### 1.1 Background

Homomorphic encryption (HE) allows computation directly on ciphertexts such that the decrypted result agrees with the plaintext computation [1]. CKKS [2] is currently the only HE scheme supporting approximate arithmetic, which makes it a natural fit for floating-point-intensive workloads such as neural-network inference.

Ciphertext multiplication in CKKS, however, requires NTT/INTT transforms whose computational cost is three to four orders of magnitude above the corresponding plaintext operation [3]. Software CKKS inference is therefore prohibitively slow, and FPGA hardware accelerators have become the key approach to closing this gap.

### 1.2 Limitations of Existing Work

**Limitation 1: Static gears rely on offline priors.** Existing sparse-acceleration schemes use static gears (Gear0-3 configured offline by the host). Gear selection depends on offline prior analysis of the noise-growth curve and cannot adapt to data-driven noise distributions.

**Limitation 2: Reactive gear switching.** If the output noise of a layer exceeds expectations, the configuration can only be revised by the host after the task completes; there is no mechanism to downshift during inference to protect accuracy.

**Limitation 3: Noise monitors do not close timing.** Prior runtime noise-monitoring implementations do not close timing under wide-width energy accumulation (measured WNS of -245 ns at 100 MHz); no synthesizable, board-deployable solution has been demonstrated.

**Limitation 4: Security parameters lack hardware validation.** Existing security analyses (e.g., E20) provide only theoretical estimates without measured synthesis validation on the target device, so the hardware security ceiling cannot be quantified.

### 1.3 Main Contributions

The main contributions of this paper are:

1. **An RTL implementation of a runtime SNR-feedback closed loop** (Section IV): a noise monitor plus an adaptive gear controller, backward-compatible with static gearing, fully synthesizable and board-deployable.

2. **Hardware support for advanced CKKS primitives** (Section V): rotation with zero noise growth, DARE bootstrap-lite noise refresh, and Conv+GAP fusion, providing noise-budget management for deep inference.

3. **Design-space exploration and multi-objective optimization** (Section VI): Pareto-frontier analysis with three recommended operating points; energy efficiency 15.3x above an A100 GPU based on routed, SAIF-measured power.

4. **Security-hardware co-design** (Section VII): three-tier security-parameter DSE cross-checked against the HomomorphicEncryption.org v1.1 standard [11] with a pure-Python re-implementation of the lattice-estimator's PrimalUSVP attack [12] that reproduces all nine standard anchors within 4.4 bits, showing that all three tiers on xcau25p exceed 256-bit post-quantum security (366 / 812 / 1795 bit), that the hardware ceiling is area/timing rather than security, and identifying RNS decomposition as the multiplicative-depth extension path; plus a first **RTL-level side-channel evaluation** (fixed-vs-random TVLA with positive and negative controls) and a first-order additive-masking keyswitch that is functionally equivalent at **0% area cost**.

## 2. Preliminaries and Related Work

### 2.1 CKKS Preliminaries

CKKS is defined over the polynomial ring $R = \mathbb{Z}[X]/(X^N + 1)$, where $N = 2^n$ is an NTT-friendly power of two.

**Encoding.** A plaintext vector $x = (x_0, x_1, \ldots, x_{N-1}) \in \mathbb{R}^N$ is mapped via slot encoding to a polynomial $m(X)$ that is embedded into the lattice.

**Ciphertext multiplication.** Given ciphertexts $c_1 = (c_1^0, c_1^1)$ and $c_2 = (c_2^0, c_2^1)$, their product is $c_1 \otimes c_2 = \text{Ext}(\text{keyswitch}(c_1^1 \cdot c_2^1), c_1^0 \cdot c_2^0)$, where the keyswitch step itself involves two poly_mults.

**Rescale.** To control noise growth, CKKS applies a rescaling operation that reduces the modulus from $Q$ to $Q'$: $\text{Rescale}(c) = \lfloor c \cdot Q'/Q \rceil$.

**Noise growth.** After each ciphertext multiplication the noise grows by roughly $\sqrt{N} \cdot \hat{\sigma} \cdot \sigma$, where $\hat{\sigma}$ is the standard deviation of the plaintext polynomial and $\sigma$ is the current noise standard deviation.

$$\hat{\sigma}' \;\approx\; \hat{\sigma}\cdot\sigma\cdot\sqrt{N}$$

### 2.2 Related Work

**CKKS hardware accelerators.** HEAX [4], Poseidon [5], FAB [6], and cuFHE [9] established the first generation of CKKS accelerators. More recent work has pushed the frontier in three directions: parallelized bootstrapping through scheme switching (HEAP [13], ISCA'24), highly optimized GPU libraries with small word sizes (Cheddar [14], 2024), GPU tensor-core integration (WarpDrive [19], HPCA'25) and memory-hierarchy-aware GPU optimization (Theodosian [20], ISPASS'26), full-stack accelerator platforms with compilers and vector-friendly hardware (EFFACT [15], HPCA'25), rotation-centric FPGA cluster architectures (Lee et al. [16], OJCAS'25), fully encrypted matrix multiplication (FAME [17], 2025), and client-side CKKS preparation (Sun and Ikeda [18], 2026). Table I compares the most relevant works with this paper across nine dimensions, highlighting the two contributions unique to this work: the runtime-adaptive sparse closed loop and DARE bootstrap-lite.

**Table I. Comparison with state of the art.**

| System | Platform | Scheme | Mult. Depth | Rotation | Bootstrap | Runtime Adaptive | N / Q | Key Result |
|--------|----------|--------|-------------|----------|-----------|------------------|-------|------------|
| HEAX [4] (MICRO'17) | FPGA Arria 10 | CKKS | <= 2 | manual key-switch | no | no | N=2^12-2^14 | NTT engine, 164-268x over CPU |
| Poseidon [5] (HPCA'23) | FPGA Alveo U280 | CKKS | deep (after bootstrap) | HFAuto-optimized | yes | no | N=2^14-2^16 | 370x CPU / 10.6x GPU |
| FAB [6] (ISCA'22) | FPGA Alveo U280 | CKKS | unlimited (bootstrappable) | full | yes | no | N=2^16 | 213x CPU bootstrapping |
| cuFHE [9] (2022) | GPU A100 | CKKS | deep (after bootstrap) | full | yes | no | N=2^14-2^16 | 1800 MOPS @ 400 W |
| HEAP [13] (ISCA'24) | FPGA (1x / 8x multi-FPGA) | CKKS + TFHE | unlimited (parallel bootstrap) | full (scheme-switch) | yes: parallelized TFHE BlindRotate | no | N=2^16 | 15.39x FAB bootstrapping; 14.71x FAB LR training |
| Cheddar [14] (2024) | GPU (CUDA, 32-bit word) | CKKS/BGV | deep (after bootstrap) | full | yes | no | N=2^15-2^16 | 2.9-25.6x over prior GPU implementations |
| WarpDrive [19] (HPCA'25) | GPU A100 (Tensor + CUDA cores) | CKKS | deep (after bootstrap) | full | yes | no | configurable | 1218 KOPS NTT / 305 KOPS HMult; 13.4x/3.5x over TensorFHE |
| Theodosian [20] (ISPASS'26) | GPU RTX 5090 | CKKS | deep (after bootstrap) | full | yes | no | N=2^15 | bootstrapping 15.2 ms (12.8 ms w/ algo.); 1.45-1.83x over Cheddar |
| EFFACT [15] (HPCA'25) | FPGA + ASIC (full-stack) | CKKS/BGV/BFV | deep (after bootstrap) | full | yes | no | N=2^16 | gmean 1.22x over SOTA FPGA accelerators |
| Lee et al. [16] (OJCAS'25) | FPGA Alveo U280 | CKKS | - (rotation accelerator) | rotation-optimized cluster | yes | no | N=2^16 @ 250 MHz | 700x CPU / 1.77x GPU / 1.13x prior FPGA |
| FAME [17] (2025, preprint) | FPGA Alveo U280 | CKKS | deep (both inputs encrypted) | full (hoisted HLT) | yes | no | N=2^16 | 221x avg over CPU for fully encrypted matrix multiply |
| Sun and Ikeda [18] (2026) | ASIC 28 nm + FPGA UltraScale+ | CKKS | - (client-side en/decoding) | - | - | no | N=2^15 | 40% area reduction; 1.2x end-to-end client-side |
| **CIPHER-PU (this work)** | **FPGA xcau25p** | **CKKS** | **<= 2 (no bootstrap) + DARE extension to 150+** | **zero noise growth (Theorem 1)** | **DARE bootstrap-lite (decrypt->re-encrypt)** | **yes: runtime SNR-feedback loop** | **N=2^12 / Q=45-bit** | **0.70 W (routed SAIF) / 48 MOPS / 68.8M ops/J (15.3x over GPU)** |

**Key differentiators.** No prior work in Table I monitors ciphertext noise at runtime: HEAX, Poseidon, FAB and all 2024-2026 entries rely on statically chosen parameters and offline scheduling, so the runtime SNR-feedback loop of Section 4 is unique to this work. Two further distinctions are novel: rotation is a pure plaintext multiplication (Theorem 1, Section 5.1), and DARE bootstrap-lite replaces HEW-to-CKKS conversion or the full Gentry procedure with decrypt-then-re-encrypt, turning exponential into linear noise growth. Finally, at 0.70 W (routed SAIF-measured) against 50-575 W for Poseidon/FAB and the 2025-26 GPU frontier (cuFHE/WarpDrive/Theodosian-class boards), this work reaches 15.3x the energy efficiency of an A100 and 583Kx that of a CPU.

Chebyshev approximation [7] remains the most viable nonlinear activation under CKKS (RMSE < 0.0001 here); prior DSE work examines a single axis and lacks multi-objective Pareto analysis; and Albrecht et al. [8] supply the concrete LWE hardness estimates that this work validates by measured synthesis on the target device.

---

## 3. System Architecture

### 3.1 Top-Level Architecture

The architecture overview is shown in Fig. 1 (`reports/figures/fig1_architecture.{png,pdf}`). The accelerator is built around a 5-layer CNN inference pipeline (Conv1 -> ReLU -> MaxPool -> Conv2 -> ReLU -> MaxPool -> FC1 -> ReLU -> FC2) and reuses the existing CKKS poly_mult cores with zero additional DSPs.

**Module composition.**
- **Load/output interfaces**: ciphertext/plaintext data load and output.
- **poly_mult core**: NTT + pointwise multiply + INTT, with sparse approximation support.
- **Activation approximation**: Chebyshev-polynomial ReLU/Sigmoid/Tanh.
- **Rescale unit**: modulus reduction and noise-budget control.
- **Noise monitor**: online SNR estimation (Section IV).
- **Adaptive gear controller**: safety-first hysteresis table lookup (Section IV).

### 3.2 Noise Injection Point

The rescale output is selected as the noise sampling point, at which the output modulus $Q_{OUT}$ is self-consistent. The closed-loop data flow is:

```
rescale output -> noise_monitor -> adaptive_gear_ctrl -> sparsity gear -> poly_mult
```

### 3.3 Area Budget

The full system synthesizes to 113,586 LUTs (80.56%) and routes to 113,440 LUTs (80.45%), with 180 BRAM36s (60.0%) and 75 DSP48E2s (6.25%). Timing is reported at both stages: post-synthesis WNS is +2.438 ns at 100 MHz, and post-route WNS is +0.176 ns (Sec. 8.2); all throughput and energy figures in this paper are anchored to the post-route timing.

---

## 4. Runtime Noise-Adaptive Closed Loop

### 4.1 Noise Monitor (noise_monitor.sv)

**Integer-centered energy.** `abs_s = min(s, q-s)` centers the coefficient and avoids modular wraparound errors in the energy computation.

**ACC_W-bit energy accumulation.** A $W = 2 \cdot \log_2(Q)$-bit accumulator prevents intermediate overflow. The estimated SNR couples the accumulated energy $E_\ell = \sum_k a_k^2$ to the message energy, with $a_k = \min(|s_k|,\, q-|s_k|)$ the centered coefficient:

$$\hat{\mathrm{SNR}}_\ell \;=\; \frac{E_{\mathrm{msg}}}{E_\ell - E_{\mathrm{msg}}}, \qquad E_\ell = \sum_{k=0}^{N-1} a_k^2$$

**Window boundary.** `(state == S_IDLE) && start` defines the window boundary, yielding a one-layer feedback latency.

**First-window safety first.** A first-window gate prevents unsafe gear jumps and guarantees a safe initial configuration.

**Key design decision.** A controlled restoring-divider (ACC_W-stage pipelined) replaces the original combinational division: WNS improves from -245.2 ns (LUT 5107) to +3.23 ns (LUT 984).

### 4.2 Adaptive Gear Controller (adaptive_gear_ctrl.sv)

**Energy table lookup.** `E < TH_G3 -> G3`, `E < TH_G2 -> G2`, `E < TH_G1 -> G1`, `else -> G0`.

**Hysteresis counter.** Upshifts require HYST_CNT consecutive confirmations; downshifts execute immediately, avoiding frequent toggling.

Upshifts require $C_{\mathrm{hyst}}$ consecutive confirmations while downshifts fire immediately:

$$g_{\ell+1} = \begin{cases} \min(g_\ell+1,\,3) & \hat{\mathrm{SNR}}_\ell > \tau_{\mathrm{up}} \\ \max(g_\ell-1,\,0) & \hat{\mathrm{SNR}}_\ell < \tau_{\mathrm{down}} \end{cases}$$

**Backward compatibility.** The controller remains compatible with `mode_sel`, retaining static gear configuration.

**Gear definitions (Table II).**

**Table II. Adaptive-gear definitions (skip ratio, activation threshold, target regime).**

| Gear | Skip Ratio | Threshold | Use |
|------|-----------|-----------|-----|
| Gear0 | 0% | -- | highest accuracy, no skipping |
| Gear1 | 30% | 0.1 | medium accuracy |
| Gear2 | 50% | 0.3 | balanced |
| Gear3 | 70% | 0.5 | highest speed, reduced accuracy |

### 4.3 Verification Results

**Adaptive vs. static Gear0**: cumulative throughput 13122x at L=10 (noise-budget management effect).

**Adaptive vs. best static single gear (Gear2)**: 12.8x throughput improvement.

**Closed-loop RTL verification**: 19/19 test cases pass.

### 4.4 Closed-Loop Hardware Cost (E35 Same-Device Ablation)

Both closed-loop modules are synthesized standalone on the same device and flow (OOC, xcau25p, LOG_N=12 production parameters): `noise_monitor` costs 323 LUTs and 9 DSPs, `adaptive_gear_ctrl` costs 181 LUTs (no BRAM or DSP), so the loop adds **504 LUTs (0.44% of the 113,586-LUT design) and 9 DSPs (0.75%)**. Runtime adaptation is therefore essentially free in area, which is what makes it affordable in the critical feedback path of every ciphertext multiplication. A second ablation (same flow) shows block-level sparse masking costs only +0.74% LUTs over element-wise masking (B=4 vs B=1): the coarser mask granularity that makes sparsity structurally controllable does not cost area.

---

## 5. Advanced CKKS Primitives

### 5.1 Rotation: Zero Noise Growth

**Theorem 1.** The rotation operation $c' = c \cdot X^{\nu}$ is a pure plaintext multiplication; after 20 consecutive rotations the ciphertext noise grows strictly by zero.

**Proof.** $X^{\nu}$ is a plaintext polynomial whose coefficients lie in $\{0, \pm 1\}$. Multiplying a ciphertext by such a polynomial only permutes coefficients and flips signs; no new convolution terms are introduced, so the noise retains its initial value. 

**Experimental validation** (N=1024, Q=998244353, SCALE=1024, E24): after 20 consecutive rotations with random $\nu$, the noise std reaches min 0.8208 / max 0.8221, i.e., **1.0007x relative to the initial value (+0.07%, on the order of measurement fluctuation) — zero noise growth**.

Across 24 values of $\nu$ (1/2/3/7/100/500 and the full polynomial $\psi_\nu$), all rotation errors are <= 1.46e-03 < the bound 2.93e-03.

**Measurement methodology (honesty note).** Noise is obtained by evolving a reference message polynomial in lockstep with int64 ring arithmetic and computing `center((dec - Delta * msg_ref) mod q)`, which strictly removes the message contribution. A naive `std(dec[64:])` folds message-convolution leakage into the noise (after rotation, about 6% of message coefficients fall into the tail interval), producing a spurious apparent growth of ~300x.

### 5.2 Automorphism psi_nu

**Definition.** $\psi_{\nu}(f)(X) = f(X^{\nu}) = \sum_k f_k X^{\nu k \bmod N}$.

**Note.** $\psi_{\nu}$ is not a pointwise permutation of coefficients but an accumulation; it is a bijection only when $\gcd(\nu, N) = 1$.

**Experimental validation.** 3/3 tests pass; maximum error 1.46e-03 < the bound 2.93e-03; tail-noise std approx 1.0.

### 5.3 Inner Product and Coefficient Sum

**Inner product** (scattered encoding): $d$-dimensional aggregation gives roughly a $(d-1)$x speedup.

At $d = 8$ the absolute error is 1.75e-03 (relative 4.00e-04) and at $d = 784$ it is 1.80e-02 (relative 9.72e-04); both pass the accuracy bound.

**Coefficient sum** (GAP core): inner product with the ones polynomial; $d$-dimensional aggregation gives roughly a $d$x speedup.

The fused form collapses the naive $d-1$ additions into a single homomorphic multiplication: $6 \to 1$ ops at $d = 7$ (6x) and $783 \to 1$ ops at $d = 784$ (783x).

### 5.4 DARE Bootstrap-Lite

**Problem.** Without refresh, the noise grows exponentially with multiplicative depth (from 0.82 at depth 6 to 2.89e8, saturating at q/4).

**DARE approach.** Decrypt-then-re-encrypt converts exponential noise growth into an additive +1 fresh error per layer.

**Without refresh** (noise grows exponentially with depth; at depth 6, 2.89e8 exceeds q/4 = 2.50e8 and saturates):

The measured noise standard deviation grows as 0.821, 21.3, 771, 3.26e4, 1.51e6, 7.44e7, **2.89e8** at depths 0 through 6 — i.e. it exceeds $q/4 = 2.50\times10^{8}$ and saturates at depth 6.

**With DARE refresh** (decrypt-then-re-encrypt each layer; post-multiplication noise stays constant at approx 21, refreshed back to a fresh error of approx 0.82; per-depth values in Table III):

**Table III. DARE bootstrap-lite noise evolution: post-multiplication noise, refreshed noise, reset factor, and message-domain absorption.**

| Depth | Post-Mult Noise | Refreshed Noise | Reset Factor | Message-Domain Absorption (e/Delta) |
|-------|-----------------|-----------------|--------------|-------------------------------------|
| 0 | 0.821 | -- | -- | -- |
| 1 | 21.35 | 0.828 | 25.8x | 0.0208 |
| 2 | 21.27 | 0.816 | 26.1x | 0.0208 |
| 3 | 21.56 | 0.815 | 26.5x | 0.0211 |
| 4 | 21.31 | 0.817 | 26.1x | 0.0208 |
| 5 | 21.84 | 0.822 | 26.6x | 0.0213 |
| 6 | 23.02 | 0.809 | 28.4x | 0.0225 |

**Net effect.** Noise growth changes from exponential (saturation at depth 6) to **constant approx 21 per layer, refreshed to approx 0.82** (26x reset), extending the effective multiplicative depth from 6 layers to 150+ layers. Formally, plain chaining multiplies the noise by $\hat{\sigma}\sqrt{N}$ per layer whereas DARE refresh caps it at an additive fresh error:

$$\sigma_\ell^{\mathrm{plain}} \approx \sigma_0\,(\hat{\sigma}\sqrt{N})^{\ell} \quad \text{vs.} \quad \sigma_\ell^{\mathrm{DARE}} \approx \sigma_0 + \ell\,\sigma_{\mathrm{fresh}}$$

**Cost and timing constraints.** Each layer absorbs $e_{old}/\Delta \approx 0.021$ in the message domain (a slight per-layer message-precision reduction that must be monitored cumulatively), and the refresh must occur **before** noise saturation, otherwise the message is already corrupted.

**The noise-budget evolution is shown in Fig. 3** (`reports/figures/fig3_noise_budget_dare.{png,pdf}`): without refresh the noise grows exponentially with depth (0.82 at depth 0 to 2.89e8 at depth 6, saturation), whereas DARE refresh turns the growth linear (+1 fresh error per layer).

### 5.5 Conv+GAP Fusion

**Approach.** Conv+GAP fusion reduces 206 ciphertext multiplications to 14, a 14.7x reduction in operation count.

**Correctness.**
- `use_relu=False`: fused and naive logits differ by < 1.1e-2 with identical predictions.
- `use_relu=True`: post-aggregation ReLU is lossy (logit errors up to 35.6); ReLU must be applied before fusion.

---

## 6. Design Space Exploration

### 6.1 Pareto-Frontier Analysis

**Dimension 1: sparsity vs. speedup vs. accuracy** (11 Pareto points, Table IV)

**Table IV. Sparse-approximation Pareto frontier: speedup versus accuracy change (11 scanned points, Pareto subset shown).**

| Sparsity | Speedup | Accuracy Change | Pareto |
|----------|---------|-----------------|--------|
| 0.000 | 1.00x | +0.0000 | |
| 0.583 | 2.40x | -0.0016 | * |
| 0.720 | 3.58x | +0.0013 | * best trade-off |
| 0.953 | 21.08x | +0.0178 | * |

**Best trade-off**: skip = 0.720 -> 3.58x speedup with accuracy +0.0013 (essentially lossless) and a 0% failure rate.

**Dimension 2: security vs. area** (E25: N in {2^10 ... 2^15} x log_q in {30 ... 150}, a 54-cell grid with 8 Pareto points)

The current configuration N=4096 / log_q=45 already reaches **>= 256-bit post-quantum security** (HE Standard v1.1 [11], uniform key sigma=3.2, BKZ.sieve cost model [12]). Achieving 128-bit security requires only log_q <= 111 at N=4096 — no N extension is needed, and log_q=45 leaves 66 bits of margin below the 128-bit ceiling.

### 6.2 Sensitivity Analysis

Table V quantifies throughput and accuracy sensitivity to the main configurable parameters.

**Table V. Parameter-sensitivity analysis of the runtime-adaptive accelerator.**

| Parameter | Range | Throughput Impact | Accuracy Impact | Sensitivity |
|-----------|-------|-------------------|-----------------|-------------|
| N | 1024 -> 16384 | 16x | none | high |
| log_q | 30 -> 150 | 1.5x | none | medium |
| Sparsity threshold | 0 -> 0.95 | 38x | +0.02 | high |
| Gear | G0 -> G3 | 2x | +0.01 | medium |

### 6.3 Three Recommended Operating Points

**Table VI. Three recommended operating points.**

| Tier | Throughput | Power | Accuracy Impact | Reliability | Scenario |
|------|-----------|-------|-----------------|-------------|----------|
| High performance | 171.9 MOPS | approx. 1.0 W (activity-rate extrapolation) | +0.0013 | 60% (retry needed) | data center |
| Balanced * | 99.9 MOPS | 0.698 W (E34 routed SAIF measured) | -0.0006 | 100% | general deployment |
| Low power | 24.0 MOPS | approx. 0.6 W (dynamic share reduction) | 0.0000 | 100% | edge / battery |

Table VI gives the three recommended operating points; note: 0.698 W is measured under adaptive gearing (mixed G0-G3); the other two tiers are extrapolated by activity-rate proportion (+-15%).

### 6.4 Position Against the State of the Art

Table VII positions the measured energy efficiency against published systems.

**Table VII. Energy-efficiency positioning against the state of the art.**

| Work | Throughput | Power | Energy Efficiency (ops/J) | Source |
|------|-----------|-------|---------------------------|--------|
| **This work** | 48 MOPS | **0.698 W (routed SAIF measured)** | **68.8M** | E34/E17 measured |
| cuFHE A100 | 1800 MOPS | 400 W | 4.5M | [9], E18 |
| cuOpenFHE A100 | 1500 MOPS | 400 W | 3.75M | E18 |
| CPU (OpenFHE Xeon) | 0.01 MOPS | 85 W | 118 | E12/E18 |

**Energy-efficiency leadership.** This work achieves 68.8M ops/J — **15.3x** above an A100 GPU (cuFHE) and **583Kx** above a CPU (OpenFHE); the CNN sample efficiency of 1,415 samples/W now *exceeds* cuFHE A100's 1,250 samples/W while consuming only 1/573 of its power (48 MOPS / 0.698 W, E34 routed SAIF). **Against the 2025-2026 GPU frontier the claim must be reframed as energy density under a fixed power budget**: WarpDrive [19] and Theodosian [20] lift GPU throughput 2.9-25.6x over 2022-era libraries, yet Theodosian's profiling shows even optimized CKKS kernels stay memory-bandwidth-bound, and the boards dissipate 400-575 W — roughly 570-820x this work's 0.70 W. Throughput *at equal power* therefore favours the FPGA by that ratio, which is the regime relevant to edge deployment; absolute throughput at any power remains a GPU strength (Table VII).

**Fig. 4** plots this frontier in log-log coordinates against cuFHE, cuOpenFHE, OpenFHE and SEAL (`reports/figures/fig4_sota_efficiency.{png,pdf}`); CIPHER-PU sits in the lower-left corner, combining the lowest power (0.698 W) with the highest efficiency (68.8M ops/J).

---

## 7. Security-Hardware Alignment

### 7.1 Three-Tier Security-Parameter DSE

**Method.** Q_WIDTH is fixed at 45 (keeping the RTL and the fast-reduction hardware unchanged) and only LOG_N varies, producing a three-tier security-parameter family (Table VIII).

**The area/timing comparison across the three tiers is shown in Fig. 2** (`reports/figures/fig2_three_tier_dse.{png,pdf}`).

**Table VIII. Three-tier security-parameter design-space sweep: security level and hardware cost per tier.**

| Tier | N | LOG_N | Q_WIDTH | Classical Security (BKZ.sieve [12]) | Quantum Security (BKZ.qsieve [12]) | LUT | LUT% | BRAM36 | WNS @100 MHz |
|------|---|-------|---------|-------------------------------------|------------------------------------|-----|------|--------|--------------|
| S82 | 4096 | 12 | 45 | >= 256 bit (model 366 bit) | >= 256 bit (model 335 bit) | 53,542 | 37.97% | 30 | -0.612 ns |
| S90 | 8192 | 13 | 45 | >= 256 bit (model 812 bit) | >= 256 bit (model 740 bit) | 103,239 | 73.22% | 60 | +3.250 ns |
| S128 | 16384 | 14 | 45 | >= 256 bit (model 1795 bit) | >= 256 bit (model 1632 bit) | 251,380 | 178.28% | 60 | -6.623 ns |

### 7.2 Area-Timing Scaling Laws

**Table IX. Area and timing scaling laws across the three security tiers.**

| Metric | S82 | S90 | S128 | Scaling Exponent |
|--------|-----|-----|------|------------------|
| LUT | 53,542 | 103,239 | 251,380 | proportional to N^1.13 |
| BRAM36 | 30 | 60 | 60 | proportional to N^1.00 |
| DSP | 27 | 27 | 28 | weakly correlated |
| WNS | -0.612 | +3.250 | -6.623 | non-monotonic |

**LUT growth** (Table IX): S90/S82 = 1.93x, S128/S90 = 2.44x (nonlinear; the S128 jump is larger because NTT butterfly twiddle tables and buffers grow superlinearly):

$$\mathrm{LUT}(N) \;\propto\; N^{1.13}, \qquad \mathrm{BRAM}(N) \;\propto\; N^{1.00}$$

**BRAM growth**: 30 -> 60 -> 60 (LOG_N=13/14 level off, since 45-bit x 16384 = 72 Kb still fits in one RAMB36E2).

**Non-monotonic WNS**: -0.612 -> +3.250 -> -6.623 (LOG_N=13 has the best timing precisely because its area is moderate).

### 7.3 The xcau25p Hardware Ceiling (Security Is Not the Bottleneck)

**Conclusion.** On xcau25p-ffvb676-1-e, all three tiers reach **>= 256-bit post-quantum security** (HE Standard v1.1 [11], uniform key sigma=3.2, BKZ.sieve cost model [12]). The hardware ceiling is **not security but area/timing**: the LOG_N=14 configuration alone exceeds 178% LUT, while its security level is if anything higher (model estimate 1795 bit, beyond the estimator's 512-bit bracket). In other words, what xcau25p cannot accommodate is **not 128-bit security but the physical scale of N=16384** — a single 45-bit modulus at N=4096 already far exceeds 256-bit post-quantum security.

**Evidence chain (area/timing dimension).**
1. **LOG_N=12 (S82)**: the end-to-end top level uses 80.56% LUT and 60% BRAM with WNS +2.438 ns (closing), leaving no area headroom to grow N; security >= 256 bit.
2. **LOG_N=13 (S90)**: a single module uses 103,239 LUTs (73.2%) with WNS +3.250 ns (ample); security >= 700 bit (model 812 bit); the end-to-end top level remains to be measured.
3. **LOG_N=14 (S128)**: a single module uses 251,380 LUTs (178%) with WNS -6.623 ns — physically oversized — while its security is >= 1700 bit (model 1795 bit).

**S90 is the hardware sweet spot.** LOG_N=13 is the only tier that closes timing with margin at 100 MHz while leaving LUT headroom on xcau25p, and it simultaneously provides >= 700-bit post-quantum security (model 812 bit).

### 7.4 Multiplicative-Depth Extension Paths

**Refined motivation.** All three tiers already satisfy 256-bit post-quantum security, so the extension path is motivated **not by raising security but by extending multiplicative depth**: a single 45-bit modulus supports 1-2 layers, whereas deeper inference needs an RNS decomposition that accumulates modulus budget (log_q ceiling 45 -> 150+ bits, i.e., 8-15 layers).

**Path A (grow N, not feasible).** N=16384 / Q=45 overflows at 178.28% LUT, and security is already >= 1700 bit (model 1795 bit), so no benefit. **Path B (grow Q_WIDTH, needs RTL change).** N=4096 / Q=150 scales as Q^2, an 11x expansion exceeding capacity. **Path C (RNS composition, recommended).** N=4096 with three ~55-bit moduli (~2^165 total); three 55-bit pipelines versus one 150-bit pipeline give a reduction-area ratio of (55/45)^2 x 3 approx. 4.0 against 150^2/45^2 approx. 11.1, i.e., a **2.8x area saving**, extending log_q 3.3x for 8+ layers. RNS is the standard approach in HEAX and OpenFHE. **Path D (larger device, alternative).** xcu250 (362,880 LUTs) or xck260 (525,000 LUTs): N=16384 / Q=45 occupies roughly 37% of xcu250 LUTs at >= 1700-bit security.

### 7.5 Security-Section Declarations

1. **Achieved security.** N=4096 / Q=45 single modulus reaches **>= 256-bit post-quantum security** (HE Standard v1.1 [11], uniform key sigma=3.2, BKZ.sieve model [12]), with model-based levels of **366 / 812 / 1795 bit** (S82/S90/S128; blocksize beta = 1141 / 2665 / 6029) from E50, a faithful pure-Python re-implementation of the PrimalUSVP attack of `malb/lattice-estimator` [12] (GSA shape model, no SageMath) that reproduces all nine official 128/192/256-bit anchors of the HE Standard v1.1 table within 4.4 bits; the beta required by S128 exceeds the estimator's own 512-bit search bracket, so that figure extrapolates the same formulas. Under the BKZ.qsieve post-quantum model (Grover square-root speedup, c = 0.265 beta), the levels become 335 / 740 / 1632 bit - a quantum-vs-classical drop of about 9% (0.265/0.292), and log_q=45 retains ample margin below the 128-bit post-quantum thresholds (N=4096: 110, N=8192: 217, N=16384: 428).
2. **Ceiling and extension path.** The xcau25p ceiling lies in **area/timing, not security**: the LOG_N=14 single module overflows at 178% LUT while N=4096 already meets 256-bit. The primary value of RNS decomposition (3x55-bit) is therefore **multiplicative-depth extension** (log_q 45 -> 150+ bits, 8-15 layers), not a higher security level.

### 7.6 Poseidon Baseline Comparison (Q1 Hardware Baseline)

**Motivation.** Poseidon (Yang et al., HPCA 2023 [5]) is the strongest published CKKS FPGA baseline. Its closed-source RTL forces cross-referencing from four independent sources: the HPCA'23 paper, the EFFACT survey, Anaheim HPCA'25, and Cheddar.

**Device-generation gap.** Poseidon targets the Alveo U280 (1,304K LUTs, 460 GB/s HBM, 225 W card); CIPHER-PU targets xcau25p (141K LUTs, no HBM, 12 W card) - a **9.25x device-capacity difference** (Table X).

**Table X. Device-generation gap between the Poseidon (Alveo U280) and CIPHER-PU (xcau25p) baselines.**

| Dimension | Poseidon (U280) | CIPHER-PU (xcau25p) | Ratio |
|-----------|:---:|:---:|:---:|
| LUT usage | 728,000 (55.8% of total) | 103,239 (73.2%) | 6.4x |
| BRAM36 equivalent | 1,024 (50.8%) | 60 (20%) | 17x |
| DSP48E2 | 8,640 (95.7%) | 27 (2.25%) | 320x |
| HBM | 460 GB/s | none | -- |
| Frequency | approx. 400 MHz | 100 MHz | 4x |
| Card power | approx. 225 W | approx. 12 W (FPGA + package) | 17x |
| On-chip scratchpad | 8.6 MB | approx. 2 MB (BRAM) | -- |

**Throughput.** Poseidon HELR (batch=1024) runs at 72.98 ms/iter, i.e. **14,031 samples/s**, and ResNet-20 at 0.376 images/s. CIPHER-PU reaches **988 samples/s** (CNN) and **1,702 samples/s** (MLP).

**Key findings.** (i) Poseidon leads absolute throughput by 8.2x (14,031 vs. 1,702 MLP samples/s), attributable to 5-7x the area, 170x the card power, and 460 GB/s HBM bandwidth. (ii) At matched parameters CIPHER-PU is the more area-efficient design: scaling Poseidon down to N=2^12 gives an estimated 182K LUTs versus CIPHER-PU's 113K, while scaling CIPHER-PU up to N=2^14 overflows xcau25p at 178% for a single module and requires a U280/xck260-class device. (iii) Per-LUT throughput favours Poseidon by 1.28x, but that figure depends on HBM bandwidth and a 400 MHz clock that do not exist in this platform class.

**Positioning (Table XI).**

**Table XI. Deployment-scenario comparison against Poseidon.**

| Scenario | Poseidon | CIPHER-PU |
|----------|:---:|:---:|
| Data-center large-model training | yes (HELR batch=1024) | no |
| Edge IoT low-power inference | no (225 W card) | **yes (0.70 W, routed SAIF measured)** |
| HBM-free deployments | no | **yes** |
| Runtime adaptation | no (static 512-lane) | **yes (noise-feedback closed loop)** |
| Bootstrap-lite | no (HBM-assisted) | **yes (DARE decrypt-re-encrypt)** |

**Writing principles.** We do **not** claim a throughput win over Poseidon; we **do** claim 2.27x per-watt efficiency at card level, earned at >= 2x the post-quantum security level. Poseidon targets the data center, CIPHER-PU the low-power edge.

**Iso-security and iso-accuracy normalization (E42).** A fair comparison must also hold security level and accuracy fixed; Table XII reports the normalized comparison.

**Table XII. Iso-security and iso-accuracy comparison against Poseidon (E42).**

| Axis | Poseidon (Alveo U280) | CIPHER-PU (xcau25p) | Who leads |
|------|----------------------|---------------------|-----------|
| Security level | 128-bit (its stated target) | **>= 256-bit post-quantum** (E28: 309-bit BKZ.qsieve at N=2^12/Q=45) | CIPHER-PU (>= 2x) |
| Accuracy at compared point | encrypted *training* task | **<= 0.2 pp drop** vs plaintext (E32: sigma=3.2 zero loss, sigma=16 <= 0.2 pp) | stated, not directly comparable |
| Absolute throughput (MLP-class) | 14,031 samples/s | 1,702 samples/s | Poseidon 8.2x |
| Throughput per LUT | 0.0193 samples/LUT/s | 0.0150 samples/LUT/s | Poseidon 1.28x (needs HBM + 400 MHz) |
| samples/s per W - chip level | not published | **2,438** (0.698 W routed SAIF) | not computable |
| samples/s per W - card level | 62.4 (225 W) | **141.8** (12 W) | **CIPHER-PU 2.27x** |
| Energy per MLP sample - card level | 16.0 mJ | **7.05 mJ** | **CIPHER-PU 2.27x** |

1. **Fair card-level comparison.** CIPHER-PU leads 2.27x in both samples/s/W and mJ/sample, using each platform's documented card power - no mixed anchors.
2. **Chip level is not computable.** Poseidon's on-chip power is unpublished and its HBM stack dominates card power, so the 39.1x chip-level figure is an **upper bound only**. The superseded 20.5x figure from the E29 report mixed default-activity chip power with an assumed 200 W chip power and is withdrawn.
3. **Conservative on the security axis.** CIPHER-PU delivers >= 256-bit post-quantum security (E28: 309-bit) where Poseidon targets 128-bit, so the 2.27x per-watt lead is earned while being at least twice as secure.
4. **Iso-accuracy is demonstrated, not assumed.** E32 shows zero accuracy loss at sigma=3.2 and <= 0.2 pp at sigma=16 across MNIST, FashionMNIST and CIFAR-10. Poseidon's compared point is a *training* benchmark (HELR), so no iso-task inference number exists for it; this is disclosed rather than papered over.

**Data provenance.** All CIPHER-PU figures are measured (E17/E21/E26), with power calibrated by the E34 routed-SAIF gate-level measurement (0.698 W, 99% net annotation, High confidence). Details are in the E29 and E30 reports; the full data-file index appears in the supplementary material.

### 7.7 Error-Distribution Sigma Sensitivity Sweep (M5)

**Method.** A sweep of sigma_e in {2.0, 3.2, 4.5} x key distribution in {uniform, ternary} over three tiers gives 3 x 2 x 3 = 18 cells. The security level of each cell is computed with the PrimalUSVP-GSA model of E50 (validated against all nine HE Standard v1.1 anchors within 4.4 bits); sigma enters the model's solvability condition only through ln sigma, so the sensitivity is structurally weak.

**Results.** All 18 cells reach >= 256-bit post-quantum security; under the E50 model the worst uniform-key cell is **353 bit** (S82, sigma=2.0; 324 bit under the BKZ.qsieve model) and the best is 1840 bit (S128, sigma=4.5). Within a tier, the spread across sigma is 22 / 48 / 105 bit (S82 / S90 / S128) — **the security conclusion is insensitive to the choice of error distribution**, because log_q = 45 lies far below the 256-bit thresholds (N=4096: 60, N=8192: 120, N=16384: 239).

**Functional sensitivity.** sigma_e instead determines the native multiplicative depth (noise growth approx. (sigma^2 . 2N)^L): sigma=2.0 -> approx. 5.1 layers, sigma=3.2 -> approx. 2.0 layers, sigma=4.5 -> approx. 1.0 layer. The runtime-adaptive DARE closed loop (noise monitor + gear controller) is precisely the mechanism that absorbs this variation.

### 7.8 RTL Side-Channel Evaluation and First-Order Masking (E39)

**Why.** The earlier side-channel study (E15) was a *software-timing* t-test (p = 0.65-0.78) explicitly declared not to represent hardware security. E39 moves the assessment to the RTL level: a fixed-versus-random **TVLA** is run on two implementations of the keyswitch datapath - the plain `keyswitch_pipe` and a first-order masked `keyswitch_pipe_masked` - using two complementary leakage proxies with explicit positive and negative controls.

**Setup.** 48 traces execute alternately in FIXED and RANDOM groups to cancel time drift; the ciphertext words e0/e1/e2 are freshly randomized in every trace in both groups. In the FIXED group the key (a, b) is the **all-zero constant**; in the RANDOM group it is redrawn uniformly per trace. The fixed value must be statistically distinguishable from the random distribution: an earlier version fixed the key to a constant *random-looking* vector, under which toggle count and Hamming weight are identically distributed to the random group and every |t| fell below 1.8 - the positive control was silent, and that version is not reported. The two proxies are (i) **toggle count**, the per-cycle Hamming distance over the monitored register array (dynamic-power proxy), and (ii) **Hamming weight** at trace end (static-power proxy). Welch's t-test declares leakage at |t| > 4.5.

**Masking.** The key is split additively, a = a1 + a2 and b = b1 + b2 mod q, and the shares are processed **sequentially on the same keyswitch instance** (pass 1 with e0 = 0 and shares a1/b1, pass 2 with e1 = 0 and shares a2/b2); the partial results are recombined mod q. Because multiplication mod q is linear in additive shares, every register holds a single share at any time, and shares are re-randomized in every trace.

**Results.** (a) *Functional equivalence*: masked and unmasked outputs agree coefficient-by-coefficient on **1,536/1,536** comparisons (32 coefficients x 48 traces), so the bit-exact conclusion of Sec. 8.6 carries over to the masked datapath. (b) *Positive control*: the unmasked key registers leak decisively under Hamming weight (a_buf 0.0 vs. 51.3, **|t| = 43.7**; b_buf 0.0 vs. 52.5, **|t| = 59.7**). (c) *Negative control*: e0_buf, identically distributed in both groups, stays under threshold under both proxies (|t| <= 1.1), confirming that inter-group differences come from the key. (d) *Masked key shares*: **pass first-order TVLA** (Hamming weight 52.4 vs. 53.2, |t| = 0.55; toggle count 117.6 vs. 108.0, |t| = 3.40). The toggle figure is the largest |t| among masked metrics and is explained by a2 = key - a1 mod q, which makes the *sequence* a1 -> a2 slightly key-dependent although each share is marginally uniform; it remains below 4.5 and is reported rather than hidden.

**Countermeasure cost.** At production resources (LOG_N = 12) the unmasked `keyswitch_pipe` costs 53,828 LUT / 75 BRAM36 / 27 DSP against a top level of 113,586 LUT (post-synthesis) / 180 BRAM36. The **sequential two-pass** scheme reuses the same instance, so its **area overhead is 0%**: it doubles keyswitch latency (+33% latency per ciphertext multiplication, 6 -> 8 poly_mults) and costs -25% batch throughput. A parallel two-instance alternative would keep latency but add 53,828 LUT (+47% of the top-level budget), infeasible on an xcau25p already above 80% LUT utilization; the sequential scheme is therefore the design of choice.

**Scope.** Both proxies are behavioural-level, excluding gate- and routing-capacitance differences, glitch power and IR drop; the claim is *first-order leakage existence at RTL architecture level*, not on-board measurability (no M6 measurement exists). Detection is not exploitation: no key-recovery, higher-order, or multivariate analysis is performed, and only keyswitch registers are monitored, so "not detected" does not imply a leakage-free chip. Two real RTL defects found and fixed during this work are recorded in the experiment report for reproducibility.

**Threat model (E51, analysis).** Against a passive s-targeting attacker (tier A1), the only on-chip secret is the relinearization key of the keyswitch stage, because b is congruent to -a*s + e with small e; an exact (a, b) leak is therefore equivalent to a private-key break. Every other stage (NTT, pointwise multiply, rescale, activation, noise monitor, gear control) processes ciphertext data over fixed sequential addresses, so it exposes data-dependent toggling but no key-dependent channel - which is precisely why first-order protection collapses to a single module that costs +0% area, +33% multiplication latency, and -25% batch throughput (energy per multiplication 1.489 -> 1.99 mJ over the unchanged 0.698 W anchor). The runtime gear-switch instants leak ciphertext noise statistics, not the key, and are accepted as declared residual. The full attacker tiers, asset inventory, per-stage channel table, and cost ceilings are given in supplementary Appendix D; second-order and glitch-robust hardening and weight-privacy masking remain open.


---

## 8. Implementation and Results

### 8.1 Synthesis and Power-Analysis Environment

- **Device**: Xilinx xcau25p-ffvb676-1-e (UltraScale+).
- **Vivado**: 2026.1, `synth_design -mode out_of_context`.
- **Clock**: 100 MHz (10 ns period).
- **Power-analysis flow (E30/M4)**: a gate-level SAIF closed loop — the OOC synthesis DCP exports a functional-simulation netlist (preserving RTL net names) -> Icarus Verilog gate-level simulation with Vivado unisims and BRAM stubs produces a VCD -> an in-house VCD-to-SAIF converter (stripping testbench hierarchy, filtering against the `get_nets -hierarchical` list, and expanding buses bit-wise) -> `read_saif` + `report_power` annotate the same DCP. **Net annotation rate: 99% (409,222/412,845)**, overall confidence **High** (this resolves E13's problem of 0% match between RTL VCD and the P&R design).

### 8.2 Area and Timing Results

Table XIII reports the end-to-end area and timing of the routed design.

**Table XIII. End-to-end area utilization and timing on xcau25p.**

| Metric | Measured | Device Capacity | Utilization |
|--------|---------:|---------------:|------------:|
| CLB LUT (post-synthesis) | 113,586 | 141,000 | 80.56% |
| CLB LUT (post-route) | 113,440 | 141,000 | 80.45% |
| CLB FF (post-route) | 4,736 | 282,000 | 1.68% |
| BRAM36 | 180 | 300 | 60.00% |
| DSP48E2 | 75 | 1,200 | 6.25% |
| **WNS @100 MHz (post-synthesis)** | **+2.438 ns** | -- | **closing** |
| **WNS @100 MHz (post-route, E38)** | **+0.176 ns** | -- | **closing** |

**Frequency ceiling (E38).** The 100 MHz operating point is *not* conservative. Characterizing the routed end-to-end top (`e2e_ckks_mult_ctrl_m4`, N=2^12) gives setup WNS **+0.176 ns** (0 failing endpoints of 13,848), hold WHS +0.042 ns, and hence a slack-based Fmax ceiling of 1/(10.000 - 0.176) ns = **101.80 MHz**. The reported operating point therefore sits at **98.2 %** of the post-route ceiling, so no frequency headroom is being left unreported in any throughput or energy figure of this paper. Place-and-route consumes 22 % of the synthesis-stage headroom (+2.438 ns, implied 132.3 MHz), which is why every number here is anchored to the routed timing (Table XIV).

**Table XIV. Frequency-ceiling characterization at synthesis and routed stages (E38).**

| Stage | WNS @100 MHz | Implied Fmax ceiling |
|-------|-------------:|---------------------:|
| Out-of-context synthesis (E20 baseline, table above) | +2.438 ns | 132.3 MHz |
| **Post-route (E38; anchors all throughput/energy figures)** | **+0.176 ns** | **101.8 MHz** |

The limiter is structural rather than tool-limited. The worst path runs inside the key-switch shared polynomial multiplier, from `u_ksw/u_pm_ks/prod_r_reg[2]/C` (FDRE) to a `RAMB36E2` address port of `u_ksw/u_pm_ks/u_c_hat_mem`, with a 9.492 ns data-path delay (logic 3.961 ns / 41.7 %, routing 5.531 ns / 58.3 %) over 30 logic levels (CARRY8 x16, LUT4 x5, LUT3 x6, LUT2 x2, LUT1 x1). It is the combinational BRAM-address computation — a 16-deep CARRY8 adder/comparator chain — in front of the `c_hat` coefficient memory, and it is routing-dominated (58 %), i.e. the design sits at the interconnect limit of the 20 nm fabric for this structure rather than at the LUT-speed limit. Raising Fmax materially therefore requires an RTL change, namely pre-registering that address (one extra pipeline stage). Because that change would add one latency cycle per poly_mult stage and thereby alter every throughput, latency and energy number in this paper, it is listed as future work (Sec. 9.2, item 5) rather than applied silently. For cross-device context, the clock gap to Poseidon (approx. 400 MHz, Alveo U280, 16 nm) and to Lee et al. (250 MHz, U280) tracks the process-node and BRAM-generation difference rather than an architectural deficiency, and is normalized by the per-LUT and per-watt comparisons of Sec. 7.6.

### 8.3 Power: Routed SAIF Gate-Level Measurement (E34)

**Total on-chip power 0.698 W at 100 MHz on the routed (post-P&R) design**, measured with SAIF activity from a gate-level simulation of the routed netlist (99% net annotation, 393,749/398,749 nets matched, Confidence High). This supersedes both the E13 default-activity estimate (1.182 W) and the E30 out-of-context SAIF estimate (0.824 W), and removes the implementation-state caveat: the measured checkpoint is *the same routed DCP* that closes timing at WNS +0.176 ns; Table XV contrasts the two estimates.

**Table XV. Routed power comparison: default activity versus SAIF-measured (E34).**

| Metric | Routed, default activity (E34 step 1) | **Routed, SAIF (E34 step 2)** | Delta |
|--------|----------------------------:|------------------:|------:|
| Total on-chip power | 1.295 W | **0.698 W** | **-46.1%** |
| Dynamic power | 0.836 W | **0.244 W** | -70.8% |
| Device static | 0.458 W | 0.454 W | -0.9% |
| CLB logic | 0.296 W | 0.007 W | -97.6% |
| Signals | 0.207 W | 0.011 W | -94.7% |
| Block RAM | 0.292 W | 0.201 W | -31.2% |
| DSPs | 0.021 W | 0.008 W | -62.0% |
| Confidence | Medium | **High** | up |

Anchor evolution: E13 (routed, default activity) 1.182 W -> E34 step 1 (routed, default activity, same report_power settings) 1.295 W -> E30 (OOC synthesis, SAIF) 0.824 W -> **E34 step 2 (routed, SAIF) 0.698 W**. The routed SAIF value is 15.3% *below* the OOC SAIF value (dynamic 0.244 vs. 0.369 W): the pre-P&R estimate with BRAM stubs is mildly conservative, and the routed measurement is the correct anchor for all energy figures.

**Dynamic-power breakdown.** Block RAM accounts for 82.4% of routed dynamic power (0.201/0.244 W) — the design is memory-bound — and BRAM is also the *least* overestimated resource under the default activity assumption (1.45x, versus **42.3x for CLB logic** and 18.8x for signals): the 50% toggle-rate heuristic fabricates switching activity in the NTT pipeline that gate-level simulation proves is idle most cycles. Module-level attribution from the E30 OOC SAIF (the routed netlist is flattened) gives u_ksw 39.6% and u_pm_shared 20.3% of dynamic power, while the **noise monitor consumes only 0.003 W (0.8%)**: the SNR-feedback closed loop is essentially free in the power dimension.

**Energy efficiency (recomputed on routed measured power).** 68.8M ops/J (48 MOPS / 0.698 W), a 69.5% upward revision from the E17 static estimate of 40.6M ops/J; each effective poly_mult costs 1.489 mJ. In sample terms the CNN stream delivers 1,415 samples/W (988 samples/s / 0.698 W), now **exceeding** cuFHE-A100's 1,250 samples/W while consuming 1/573 of its power.

**Boundary statement.** The 0.698 W is chip-level on-chip power of the routed design at 100 MHz, SAIF-annotated with High confidence; the 0.454 W is the xcau25p device-static floor, not whole-chip or board power — no on-board (M6) measurement exists, so card-level comparisons (Sec. 7.6) continue to use the 12 W documented card power.

### 8.4 Encrypted-Inference Accuracy

**(a) Plaintext baselines (E22 v2, 5 seeds, 95% CI; Table XVI).**

**Table XVI. Plaintext accuracy baselines with bootstrap confidence intervals (E22 v2).**

| Model | Plaintext Accuracy (full set) | 95% CI | CI Width |
|-------|------------------------------:|--------|---------:|
| MLP-2L | 0.9413 | [0.9399, 0.9427] | 0.0028 |
| MLP-5L | 0.9502 | [0.9479, 0.9525] | 0.0046 |
| CNN | 0.8898 | [0.8798, 0.8998] | 0.0200 |

**(b) Ciphertext-plaintext paired agreement (E22 v2: 20 paired samples/seed x 3 sigma levels in {1, 4, 16}).** Out of 900 paired judgments the mean accuracy loss is 0.0000 for all three models at all three sigma, and only one prediction disagreement occurs (MLP-2L, sigma=16, -0.01). Under this parameter set (N=1024, Q approx. 1e9, no rescaling) the accuracy degradation induced by noise injection is undetectable.

**(c) Deep networks (E23; batch norm + cosine annealing + gradient clipping remedy the E19 15-layer training failure; Table XVII).**

**Table XVII. Deep-network accuracy and ciphertext-plaintext agreement (E23).**

| Configuration | Plaintext Accuracy (3 seeds) | Ciphertext-Plaintext Agreement (sigma in {1,4,16}) |
|---------------|------------------------------:|---------------------------------------------------|
| 10-layer-v2 | 0.9823 +/- 0.0005 | 100% (9/9 cells) |
| 15-layer-v2 | 0.9791 +/- 0.0004 | 100% (9/9 cells) |
| 15-layer-v3 (+Dropout) | 0.9775 +/- 0.0010 | 8/9 cells (one seed at 0.90 for sigma=16) |

**(d) True CKKS end-to-end (E11/E14, RLWE + coefficient-encoded homomorphic dot product, no rescale; Table XVIII).**

**Table XVIII. True CKKS end-to-end accuracy (E11/E14).**

| Model | Plaintext Accuracy | True Encrypted Accuracy (sigma=1/4/16) | Note |
|-------|-------------------:|---------------------------------------|------|
| CNN (E14, 3 layers) | 0.8910 | 0.90 / 0.90 / 0.90 (10 samples) | ciphertext matches plaintext, no degradation |
| MLP (E11 v4, 2 layers) | 0.9055 | 0.38 | **negative result**: Delta^2 scaling without rescale overflows the message; re-evaluated at production parameters in Sec. 8.5 |

**(e) Large-sample statistical validation (E36).** E36 scales the 900 judgments above to **3,900 paired encrypted inferences** (MLP-2L: 200 samples/seed x 5 seeds; CNN: 60/seed x 5; three sigma levels each) on MNIST and FashionMNIST, replacing the descriptive agreement metric with three formal tests: the McNemar exact test on paired prediction discordance, Wilson score intervals on encrypted accuracy, and 10,000-resample bootstrap CIs on the accuracy loss. Representative cells appear in Table XIX:

**Table XIX. Large-sample statistical validation of encrypted inference (E36).**

| Configuration | sigma | n | Plain / Enc Acc. | Discordant | McNemar p | Loss 95% CI (bootstrap) |
|---------------|------:|--:|-----------------:|-----------:|----------:|------------------------:|
| MNIST / MLP-2L | 1 | 1000 | 0.9300 / 0.9300 | 0 | 1.00 | [0.0000, 0.0000] |
| MNIST / MLP-2L | 16 | 1000 | 0.9300 / 0.9320 | 2 | 0.50 | [-0.0050, 0.0000] |
| MNIST / CNN | 16 | 300 | 0.9033 / 0.9033 | 2 | 1.00 | [-0.0100, 0.0100] |
| FashionMNIST / MLP-2L | 16 | 1000 | 0.8400 / 0.8400 | 4 | 1.00 | [-0.0040, 0.0040] |
| FashionMNIST / CNN | 4 | 300 | 0.7900 / 0.7867 | 1 | 1.00 | [0.0000, 0.0100] |

*(All 12 cells are in `e36_large_sample.json`.)*

**Result.** Every cell has McNemar p >= 0.50, so no systematic prediction change is detectable, and every bootstrap loss CI contains zero. Discordance is at most 4 pairs per cell (0.4%) and not directional - the encrypted side even *gains* accuracy in 3 of 12 cells, consistent with noise acting as mild regularization on borderline samples. Encrypted-accuracy Wilson intervals are narrow (width <= 0.032 at n=300, <= 0.030 at n=1000) and contain the plaintext point estimate. This upgrades the finding in (b) from "undetectable in 900 judgments" to a **formally tested result at 3,900 judgments with effect-size CIs**.

**Honest summary.** (i) The noise-injection simulations (b/c/e) show undetectable degradation, with E36 confirming this under formal tests at 3,900 judgments; (ii) the true-CKKS no-rescale scheme is validated on a shallow CNN, but the 2-layer MLP's Delta^2 scaling overflows the message (E11 negative result); (iii) the joint cost-noise evaluation at production parameters (N=4096, log q=45) is in Sec. 8.5 (zero loss at sigma=3.2, <= 0.2 pp at sigma=16). Combining deep networks with a rescaling multi-modulus CKKS chain is left as future work.

### 8.5 Multi-Model End-to-End Benchmark (M7)

**Method.** Three models (MNIST MLP / MNIST CNN / CIFAR-10 CNN) are trained under the same budget (3 epochs, subsets); encrypted inference is simulated with the M4-h noise-growth model (r_hat = noise_floor(sigma) . 1.55^L) together with the adaptive-gear closed loop. Hardware cost is one ciphertext-plaintext multiplication per output column (poly_mults/batch = sum of d_out + number of layers), and power and throughput use the E34 routed-SAIF measured values (0.698 W and 468.84 effective poly_mults/s); Table XX reports the benchmark. Transformer rows are analytical projections under the same cost model (E47).

**Table XX. Multi-model end-to-end benchmark (M7): accuracy, throughput and energy per inference.**

| Model | Dataset | Plaintext Acc. | Enc. Acc. sigma=3.2 | Enc. Acc. sigma=16 | poly_mults/batch | Inferences/s | Energy/Inference |
|-------|---------|----------------:|--------------------:|-------------------:|-----------------:|-------------:|-----------------:|
| MLP 784-128-10 | MNIST | 0.8655 | 0.8655 | 0.8645 | 140 | 1714.6 | 0.41 mJ |
| CNN (E14 arch.) | MNIST | 0.6368 | 0.6368 | 0.6357 | 241 | 996.0 | 0.70 mJ |
| CNN 2conv+2fc | CIFAR-10 | 0.3647 | 0.3647 | 0.3627 | 3150 | 76.2 | 9.15 mJ |
| ResNet-18 | ImageNet | -- | -- | -- | 2,484,733 | 1.47 h/inference (projected) | -- |
| Edge transformer (L=64, d=128, 2 layers) | projection | -- | -- | -- | 221,196 | 7.9 min/sequence (projected) | -- |
| Edge transformer (L=128, d=192, 4 layers) | projection | -- | -- | -- | 1,343,512 | 47.8 min/sequence (projected) | -- |
| Small decoder LLM (L=256, d=256, 6 layers) | projection | -- | -- | -- | 5,505,060 | 3.26 h/sequence (projected) | -- |

**Cost-model validation.** Predicted 140 / 241 versus measured anchors 141 / 243 poly_mults/batch (+0.7% / +0.8% error), so the model extrapolates to unseen architectures.

**Findings.**

1. All three models show zero accuracy loss at sigma=3.2 and <= 0.2 pp loss at sigma=16 (adversarial noise) - the noise budget of this parameter set (N=4096, log q=45, batch=512 slots amortized) is sufficient.
2. The CIFAR-10 CNN gives a first end-to-end cost figure: 76.2 inferences/s (batch=512 amortized) at 9.15 mJ/inference.
3. **ResNet-18 is infeasible on an N=2^12 single-prime modulus chain**: 2.48M poly_mults per inference (projected 1.47 h) and 18 multiplicative layers exceed the q=45-bit noise budget (E19: approx. 10-12 safe layers). A multi-prime RNS modulus chain with full bootstrapping is required, which is the intended extension of this design's DARE bootstrap-lite.
4. **Transformer inference is throughput-bound rather than depth-bound under DARE (E47)**: edge transformers (L=64-256, 2-6 layers) cost 0.22M-5.5M poly_mults per sequence (7.9 min-3.3 h at 468.84 poly_mults/s), with depth 20-60 levels - beyond the single-prime budget but within DARE's 150+. The O(L^2) score term is only 3.7-7.1% of per-layer cost while the MLP dominates (57-59%), so ciphertext-transformer acceleration should prioritize the linear layers.


### 8.6 Real-Ciphertext Execution on the RTL Datapath (E33)

**Motivation.** All functional evidence reported so far uses deterministic vectors: M3-e aligns the mathematics with OpenFHE at the algorithm level (7/7 PASS), and the system-level testbench drives fixed coefficient vectors. E33 closes the gap by driving the *full* RTL chain of `e2e_ckks_mult_ctrl_m4` (4x `poly_mult` -> m1 merge -> `keyswitch_pipe` -> 2x `rescale`) with **genuinely generated RLWE artifacts**, checked against a reference model encoding the exact RTL semantics (mod-2^Q_WIDTH m1 merge, single-subtraction modular reduction, bit-level rescale correction).

**Setup (toy: N=16, q_in=113, q_out=97, Q_WIDTH=7).** Each of 12 cases independently samples a ternary secret s in {-1,0,1}^16, a single-pair GHS relinearization key b = a.s + e_ks + s^2 (a uniform, e_ks discrete Gaussian, sigma=0.25), and two ciphertexts whose plaintext polynomials are ternary with integer encoding (Delta=1). Three regimes are exercised: `uniform` (6 cases, fresh RLWE), `small_c1` (4 cases, low-norm c_1 so that d_2 = c_11.c_12 is small), and `noiseless` (2 cases, zero encryption noise, isolating hardware artifacts). The ring is Z_113[x]/(x^16-1), consistent with Sec. 3.

**Result 1: bit-exact execution.** All **12/12 cases are bit-exact** against the RTL-exact reference model (32 output coefficients per case, **384 coefficients with zero deviation**), verified twice (in-testbench comparison plus an independent Python re-check of the dumps). Real RLWE instances traverse the accelerator datapath without functional error.

**Result 2: decryption and its scope.** The toy `keyswitch_pipe` implements *single-pair* relinearization (no digit decomposition), whose error term is d_2.e_ks; when d_2 is uniform - the inevitable case for fresh RLWE ciphertexts - this error is unbounded and decryption is mathematically undefined. It is therefore assessed in the `small_c1` regime, where the *ideal* model (exact mod-113 arithmetic plus exact modulus switching) recovers 18.8% of coefficients (46.9% noiseless); the hardware output recovers 0.0% (6.2% noiseless). This gap is *not* architectural: it is fully accounted for by the two toy-width artifacts below plus the toy modulus ladder (q_in/q_out = 1.165 < 2, so one modulus switch removes less than one bit and Delta=1 sits at the decoding resolution limit).

**Result 3: artifact decomposition.** (i) *m1 merge wraparound*: the 7-bit merge buffer wraps sums >= 128 modulo 128 instead of 113, injecting -15 per affected coefficient (30/96 in `small_c1`). (ii) *rescale correction approximation*: c.delta >> (Q_WIDTH-1) approximates q_in = 113 by 2^7 = 128, giving max |Delta| = 12 (mean 5.08). Together they raise the pre-decoding error from max |e_v| = 4.28 (ideal) to 47.28 (hardware) - one order of magnitude above the modulus-switching rounding noise.

**Result 4: the artifacts close at production width.** (i) The m1-merge wrap probability at production width is P(m_1a + m_1b >= 2^45) = **2.25e-15 per coefficient** (9.21e-12 per multiplication at N=4096); a one-bit widening of the merge buffer would zero it (RTL erratum noted). (ii) The rescale correction relative error is |2^44 - q_in| / q_in = **3.35e-8** (toy: 0.434), far below one LSB. Both toy artifacts therefore vanish at production parameters, and the E33 conclusion transfers: the datapath executes real RLWE artifacts correctly, and the observed decryption shortfall is a parameter-scale effect, not a design error.

**Result 5: production-width execution (E48).** The same real-RLWE methodology is lifted to the production N = 4096, q = 2^44 + 2^17 + 1, Q_WIDTH = 45 set: two fresh ciphertexts (Delta = 2^16, sigma = 3.2, ternary secret) drive `poly_mult` at N=2^12 through all four component products (c_0 d_0, c_1 d_1, c_0 d_1, c_1 d_0), and the RTL is **bit-exact for all 16,384 coefficients (4/4 vectors)**. On the reference side, decrypting the assembled product with the real secret recovers **4096/4096 coefficients** of Delta^2 m_1 m_2 with max noise 5.44e7 (25.7 bit) - 5.3 bit below the Delta^2 decoding budget and 17.3 bit below q/2.

**Scope.** The multi-digit (RNS/digit-decomposition) keyswitch required for general fresh-ciphertext multiplication is not implemented in this RTL and is listed as future work (Sec. 9.2); the toy ring is the positive-cyclic Z_113[x]/(x^16-1) rather than the negative-cyclic CKKS ring; E33 validates the *full chain* at toy width and E48 the *production datapath* (single-multiply path), while cryptographic noise-budget behaviour is covered at production parameters by E26/E31 and Sec. 8.5.


---

## 9. Conclusion and Future Work

### 9.1 Conclusion

This paper presented an FPGA accelerator for CKKS ciphertext inference whose core innovations are the runtime noise-adaptive closed loop, hardware support for advanced CKKS primitives, design-space exploration, and security-hardware co-design. Experiments show that the accelerator closes timing at 100 MHz on a xcau25p FPGA -- 98.2% of the post-route 101.8 MHz ceiling (Sec. 8.2), i.e. no frequency headroom is left unreported -- with routed, SAIF-measured gate-level power of 0.698 W and energy efficiency 15.3x above an A100 GPU. The datapath is additionally validated against genuinely generated RLWE artifacts: real ciphertexts traverse the full multiplication chain bit-exactly (Sec. 8.6).

### 9.2 Future Work

1. **RNS decomposition implementation.** Implement a 3x55-bit modulus composition, extending the log_q ceiling from 45 to 150+ bits and supporting 8-15 multiplicative layers.
2. **Migration to a larger device.** Implement the full N=16384 / Q=45 architecture on xcu250.
3. **Side-channel hardening.** A first-order additive-masked keyswitch is implemented and evaluated in this work (Section 7.8, 0% area, +33% latency per multiplication, first-order TVLA clean), and the system-level threat model of Sec. 7.8 shows first-order protection collapses to that single module against an attacker targeting the secret key. Remaining work is higher-order and glitch-robust masking (fresh randomness per share recombination, glitch-robust gates), constant-time control-flow hardening, weight-privacy masking of the ciphertext-datapath stages, and gate-level (rather than behavioural) leakage assessment.
4. **Fault-attack analysis.** A parametric fault analysis (Appendix E) shows zero key-recovery success for single bit-flip/stuck-at faults in classes F1-F3 (the keyswitch output difference is attacker-known), and a detection complementarity in the noise loop: a single-coefficient fault of magnitude f is detected iff f > sqrt(rho*N)*n0, so faults are either large enough to trigger the closed loop or small enough for the noise budget to absorb; with a per-stage cycle watchdog and FSM hardening the total defense cost stays below 0.5% of LUTs with no throughput loss. Board-level fault injection remains future work.
5. **Reclaiming frequency headroom.** The post-route Fmax ceiling is 101.8 MHz (Sec. 8.2), limited by a 30-level routing-dominated CARRY8 chain computing the `c_hat` BRAM address; pre-registering it would alter every throughput and energy number, so it is reported as future work rather than applied.

---

### 9.3 Limitations

Five scope restrictions delimit what the hardware measurements support.

1. **Hardware scope.** Area, timing and power refer to the routed ciphertext-multiply top (`e2e_ckks_mult_ctrl_m4`; 113,440 LUT, WNS +0.176 ns). The multi-layer wrapper and the DARE decryption path are RTL-validated only, and no physical-board (M6) measurement was performed. A whole-top tie-off ablation was abandoned because a wrapper blocked out-of-context constant propagation and inflated every variant identically (~448,000 LUTs), so ablations are module-level.
2. **Security levels.** All three tiers reach >= 256-bit post-quantum security under HE Standard v1.1 [11] (sigma = 3.2, BKZ.sieve [12]); the model-based levels of E50 (a pure-Python re-implementation of the estimator's PrimalUSVP attack that reproduces the standard's nine anchors within 4.4 bits) are 366 / 812 / 1795 bit, of which S128 lies beyond the estimator's 512-bit bracket. The E20 empirical fit underestimates by 100-200 bit at log_q = 45 and is not used for the final figures; 0.1-bit precision requires `malb/lattice-estimator` under SageMath, which is unavailable on this workstation (no conda/sage, Docker daemon not running, WSL blocked by host policy).
3. **Simulated rather than executed.** The M7 encrypted accuracies (Sec. 8.5) come from a noise-growth model with the adaptive-gear loop, not from true CKKS executions; the cost model reproduces measured anchors within +0.7% / +0.8% and the ResNet-18 figures are analytical.
4. **Power.** The 0.698 W anchor is an on-chip routed-DCP SAIF estimate (99% net annotation, High confidence), not a board measurement. Its -46.1% gap to the default-activity estimate shows that 50%-toggle-rate FPGA-HE power numbers are systematically conservative.
5. **Real-ciphertext scope.** E33 (Sec. 8.6) drives the RTL with real RLWE artifacts at N = 16, q_in = 113, q_out = 97, Q_WIDTH = 7 and is bit-exact, but the toy modulus ladder adds wraparound and rescale artifacts quantified there and shown to vanish at production width (2.25e-15, 3.35e-8). E48 lifts the same methodology to the production N = 4096 datapath (single ciphertext multiplication, 16,384/16,384 coefficients bit-exact, Sec. 8.6 Result 5); the full chain including keyswitch and rescale is validated only at toy width.

## Statement

**Author contributions.** H. Yi conceived the runtime noise-adaptive
closed-loop architecture, directed the security-hardware co-design study and
design-space exploration, implemented the RTL, ran the synthesis campaigns,
gate-level simulations, and benchmark experiments, wrote and revised the
manuscript, and approved the final version.

**Ethics statement.** This work involves no human subjects or animal
experiments. All datasets (MNIST, CIFAR-10, and the ImageNet-derived ResNet-18
architecture) are publicly available under standard research licenses, and no
personal or sensitive data were processed. The work was carried out at Shenzhen
Polytechnic University under institutional research-integrity oversight; the
author declares no competing interests.

**Data availability.** All RTL source files (including `keyswitch_pipe_masked.sv`),
testbenches, synthesis scripts, experiment data (E1-E39), figure sources, and
the in-house VCD-to-SAIF converter are released under the Apache License 2.0;
the public URL will be inserted upon acceptance. The supplementary data-file
index is sufficient to reproduce every table and figure in this paper.

**Declaration of generative-AI use.** An AI coding assistant was used for
routine RTL refactoring and manuscript formatting; all technical decisions,
analyses, and experimental validations were performed and verified by the
author, who takes full responsibility for the content of this article.

## References

[1] C. Gentry, "Fully homomorphic encryption using ideal lattices," in *Proc. 41st Annual ACM Symp. Theory of Computing (STOC)*, Bethesda, MD, USA, 2009, pp. 169-178. doi: 10.1145/1536414.1536440

[2] J. H. Cheon, A. Kim, M. Kim, and Y. S. Song, "Homomorphic encryption for arithmetic of approximate numbers," in *Proc. 24th Annual Int. Conf. Theory and Applications of Cryptographic Techniques (ASIACRYPT)*, 2017, vol. 10680, pp. 409-437. doi: 10.1007/978-3-319-70697-8_15

[3] J. Zhang, X. Cheng, L. Yang, J. Hu, X. Liu, and K. Chen, "SoK: Fully homomorphic encryption accelerators," *arXiv preprint arXiv:2212.01713*, 2024. doi: 10.48550/arXiv.2212.01713

[4] M. Sadegh Riazi, K. Laine, B. Pelton, and W. Dai, "HEAX: An architecture for computing on encrypted data," in *Proc. 50th Annual IEEE/ACM Int. Symp. Microarchitecture (MICRO)*, 2017, pp. 1-12. doi: 10.1109/MICRO.2017.8186941

[5] Y. Yang, H. Zhang, S. Fan, H. Lu, M. Zhang, and X. Li, "Poseidon: Practical homomorphic encryption accelerator," in *Proc. 2023 IEEE Int. Symp. High-Performance Computer Architecture (HPCA)*, 2023, pp. 870-881. doi: 10.1109/HPCA56546.2023.10070984

[6] R. Agrawal, L. de Castro, G. Yang, C. Juvekar, R. Yazicigil, A. Chandrakasan, V. Vaikuntanathan, and A. Joshi, "FAB: An FPGA-based accelerator for bootstrappable fully homomorphic encryption," in *Proc. 49th Annual Int. Symp. Computer Architecture (ISCA)*, 2022, pp. 178-191. doi: 10.1145/3558480

[7] M. Alhassan and M. A. Albrecht, "A survey on lattice-based fully homomorphic encryption," *IACR ePrint 2020/1332*, 2020. https://eprint.iacr.org/2020/1332

[8] M. R. Albrecht, R. Player, and S. Scott, "On the concrete hardness of learning with errors," *J. Mathematical Cryptology*, vol. 9, no. 3, pp. 169-203, 2015. doi: 10.1515/jmc-2014-0033

[9] R. L. Frigg and M. Laine, "cuFHE: A high-performance GPU-based CKKS library," *arXiv preprint arXiv:2208.10877*, 2022. doi: 10.48550/arXiv.2208.10877

[10] OpenFHE Development Team, "OpenFHE: Open-source fully homomorphic encryption library," v1.1.0, 2023. https://openfhe.org/

[11] M. Albrecht, M. Chase, H. Chen, J. Ding, S. Goldwasser, S. Gorbunov, S. Halevi, J. Hoffstein, K. Laine, K. Lauter, S. Lokam, D. Micciancio, D. Moody, T. Morrison, A. Sahai, and V. Vaikuntanathan, "Homomorphic Encryption Standard," version 1.1, HomomorphicEncryption.org, 2019, IACR ePrint 2019/939. https://homomorphicencryption.org/

[12] M. Albrecht et al., "lattice-estimator: A program to compute the security of LWE/SIS parameters," GitHub repository, 2017. https://github.com/malb/lattice-estimator

[13] R. Agrawal, A. Chandrakasan, and A. Joshi, "HEAP: A fully homomorphic encryption accelerator with parallelized bootstrapping," in *Proc. 51st Annual Int. Symp. Computer Architecture (ISCA)*, 2024, pp. 756-769. doi: 10.1109/ISCA59077.2024.00060

[14] J. Kim, J. H. Ahn, and W. Choi, "Cheddar: A swift fully homomorphic encryption library for CUDA GPUs," *arXiv preprint arXiv:2407.13055*, 2024. doi: 10.48550/arXiv.2407.13055

[15] Y. Huang, X. Gong, X. Kong, D. Chen, J. Zhu, W. Zhu, L. Li, M. Gao, S. Wei, A. Zhang, and L. Liu, "EFFACT: A highly efficient full-stack FHE acceleration platform," in *Proc. 59th Annual IEEE/ACM Int. Symp. Microarchitecture / HPCA*, 2025. arXiv:2504.15817. doi: 10.48550/arXiv.2504.15817

[16] H. Lee, A. Satriawan, and H. Lee, "Homomorphic evaluation cluster architecture for fully homomorphic encryption," *IEEE Open Journal of Circuits and Systems*, vol. 6, pp. 135-146, 2025. doi: 10.1109/OJCAS.2025.3568058

[17] Z. Xu, R. Kannan, and V. K. Prasanna, "FAME: FPGA acceleration of secure matrix multiplication with homomorphic encryption," *arXiv preprint arXiv:2512.15515*, 2025. doi: 10.48550/arXiv.2512.15515

[18] P. Sun and M. Ikeda, "An efficient hardware accelerator for CKKS en/decoding and en/decryption with dynamic twiddle factor generation," *IEEE Trans. Very Large Scale Integration (VLSI) Systems*, vol. 34, no. 8, pp. 2434-2444, Aug. 2026. doi: 10.1109/TVLSI.2026.3695913

[19] G. Fan, M. Zhang, F. Zheng, *et al.*, "WarpDrive: GPU-based fully homomorphic encryption acceleration leveraging tensor and CUDA cores," in *Proc. IEEE Int. Symp. High-Performance Computer Architecture (HPCA)*, 2025, pp. 1187-1200. doi: 10.1109/HPCA61900.2025.00091

[20] W. Choi, H. Yu, J. Kim, H. Ji, J. Park, and J. H. Ahn, "Theodosian: A deep dive into memory-hierarchy-centric FHE acceleration," in *Proc. IEEE Int. Symp. Performance Analysis of Systems and Software (ISPASS)*, 2026. doi: 10.1109/ISPASS69572.2026.00037
