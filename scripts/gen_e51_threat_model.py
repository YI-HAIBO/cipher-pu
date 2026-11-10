#!/usr/bin/env python3
"""E51: full-pipeline side-channel threat model — report + JSON generation."""
import io, json, os

ROOT = str(Path(__file__).resolve().parents[1])
OUT = os.path.join(ROOT, "reports", "experiments")

MD = r"""# E51 — 全链路侧信道威胁模型（Full-Pipeline Side-Channel Threat Model）

**日期**：2026-10-26 ｜ **类型**：分析型（文献 + 架构推理 + 已有实验证据交叉，无新硬件）
**上游证据**：E15（软件时序 t-test，p=0.65–0.78，明确不代表硬件）、E39（RTL 级 TVLA + 一阶加性掩码
keyswitch，正控 |t|=43.7/59.7、掩码份额 |t|=0.55，0% 面积 / +33% 每乘延时）
**下游对接**：E52（故障注入攻击分析，待做）；论文 §7.8/§7.9 与补充材料附录 D

---

## 1. 目的与边界

E39 证明的是**单个模块（keyswitch）在一阶 TVLA 下的泄露存在性与对策成本**；E51 回答系统级问题：
整条 CKKS 推理链上，**哪些资产是侧信道目标、哪个模块以什么信道泄露、各需要几阶防护、全链防护的
延时/面积/能耗上界是多少**。本文是威胁模型，不是新测量：所有定量结论标注来源（实测/外推/推理）。

## 2. 攻击者模型（三个层级）

| 层级 | 能力 | 目标 | 本设计下的可行性 |
|---|---|---|---|
| **A1 被动·非画像** | 板级功耗/EM 采集，TVLA/CPA，无先验画像 | 恢复重线性化密钥 (a,b) | E39 已证 keyswitch 密钥寄存器 HW 泄漏 (|t|=43.7/59.7)；CPA 需对 45-bit 系数按 8-bit limb 逐段攻击，估计数百至数千 trace（**估计值，未实测**） |
| **A2 被动·画像 / 高阶** | 预建模板库，二阶/双变量组合分析 | 同上；或推断噪声电平 | 一阶掩码对 A2 不充分；E39 已记录掩码翻转代理残余 |t|=3.40（<4.5），根源是 a₂ = key − a₁ 的序列依赖 |
| **A3 主动·故障** | 时钟/电压毛刺、激光、rowhammer 式扰动 | 破坏正确性以诱导可探测偏差异或绕过掩码 | **E52 待做**；本文仅给出被攻击面清单与防护假设 |

**信任边界假设**（声明而非验证）：主机侧密钥生成与秘密钥 s 永不上板（本设计 s 只存在于主机）；
FPGA 只接收密文与**评估密钥**（重线性化密钥）。若该假设被违反（如上板自举），威胁模型需要重写。

## 3. 资产清单

| 资产 | 位置 | 敏感度 | 生命周期 | 泄漏后果 |
|---|---|---|---|---|
| **A-RLK 重线性化密钥 (a,b)** | `keyswitch_pipe` 的 a_buf/b_buf（BRAM，N×45 bit） | **关键** | 每次密文乘法全程驻留 | b ≈ −a·s + e（mod q，‖e‖ 小）：精确泄漏 (a,b) ⇒ 对可逆 a 做格/取整恢复 s ⇒ **等效私钥泄漏** |
| A-SK 秘密钥 s | 仅主机 | — | 不上板 | 不在本评估范围 |
| A-CT 密文 / 模型权重 | 全链 BRAM 与数据总线 | 中 | 推理全程 | 泄漏权重统计（隐私），不泄漏 s |
| A-RNG 份额重随机化熵 | keyswitch_masked 的每 trace 新鲜份额 | 高（防护前提） | 每次执行 | 若熵退化（固定种子），掩码退化为确定性共享 ⇒ 一阶攻击复活 |
| A-TW 旋转因子表 ω/ω⁻¹ | `ntt_mem_tdp_prod` BRAM | 公开 | 常量 | 无 |

**关键事实**：本链中唯一长期驻留板上的密钥资产是 **A-RLK**，且它只进入 `keyswitch_pipe`
（2 个 poly_mult 实例）。这把一阶防护的"必须做"范围收缩到一个模块。

## 4. 逐模块攻击面与泄露信道

| 阶段/模块 | 处理的资产 | 信道 | 一阶泄露证据/推理 | 所需防护阶 |
|---|---|---|---|---|
| `keyswitch_pipe`（含 2× poly_mult） | **A-RLK, A-CT** | C1 密钥寄存器 HW/toggle；BRAM 数据线 | **实测**（E39）：未掩码 HW 泄漏 \|t\|=43.7/59.7；掩码后 0.55 | **1 阶（已实现并验证）** |
| `approx_poly_mult`×4 → `poly_mult`（NTT+点乘+INTT） | A-CT | C2 数据依赖翻转；BRAM 数据线 | NTT 为线性变换，地址序列固定 → **无密钥依赖**；纯数据信道 | 0 阶（密文不是密钥）；若要保护权重隐私需 1 阶 |
| `ntt_unit` / `ntt_butterfly` / `mod45_fastred` | A-CT | C2 | 同上，组合逻辑数据依赖 | 0 阶 |
| `rescale`×2 | A-CT | C2 | ÷Δ 与模链换模，无密钥 | 0 阶 |
| `activation_approx`（Chebyshev） | A-CT | C2 + C3 系数 ROM 地址 | 多项式系数为公开设计参数 | 0 阶 |
| `noise_monitor` + `adaptive_gear_ctrl` | A-CT 派生统计 | **C4 控制流时序**：档位切换时刻依赖密文噪声电平 | 推理（未实测）：泄漏的是**运行时噪声统计**，非密钥；对 A1/A2 无密钥价值，对权重隐私有间接价值 | 0 阶（接受 + 声明） |
| `ckks_bram` / `ntt_mem_tdp_prod`（BRAM 控制器） | A-RLK 仅 keyswitch 侧；其余 A-CT | C5 BRAM 读/写使能与数据翻转；E34 实测 BRAM 占动态功耗 82–90% | 推理：BRAM 是功耗主成分 → 既是攻击放大器也是噪声底 | keyswitch 侧 1 阶（跟随 keyswitch） |
| `e2e_slot_simd_wrapper` / `fc/conv/maxpool` | A-CT | C2 | 同上 | 0 阶 |
| M6 bringup（JTAG/UART） | 控制接口 | C6 调试端口 | 若启用 ILA/调试读出，存在配置错误读出密钥寄存器的风险；生产配置必须关闭 | 流程性要求 |

信道编号：C1 密钥寄存器状态；C2 组合逻辑数据依赖翻转；C3 数据依赖控制流；C4 统计量驱动的时序；
C5 BRAM 总线活动；C6 调试/配置端口。

## 5. 掩码线性性分析（决定"哪些模块可套用 E39 方案"）

- **keyswitch 是对密钥线性的**：keyswitch 计算 e·a、e·b（e 为密文，a/b 为 RLK）。对加性份额
  a = a₁+a₂：e·a = e·a₁ + e·a₂，单遍只持单份额 → **顺序双通即可一阶安全**，这就是 E39 的构造。
- **NTT 同为线性**：若未来需要掩码 poly_mult，份额可分别过 NTT；但**点乘是双线性**：
  (c₀+d₀掩码)·(c₁+d₁掩码) 需要 Beavers 乘法三元组或等价交互，不能靠简单双通。
  → 结论：**一阶掩码的"便宜路径"只覆盖 keyswitch 与一切"密钥×密文"型运算；
  "密文×密文"型运算（c·d）的一阶防护成本 ≥2× 该模块**（分析结论，未实测）。
- 在本设计中 c·d 的两个因子都是 A-CT（非密钥），因此**对 A1 攻击者（目标=s）而言不需要掩码**——
  这是把一阶防护收缩到 keyswitch 的安全论证，而非成本偷懒。

## 6. 全链防护成本上界（一阶、对 A1）

| 指标 | 未防护（锚点） | 一阶防护（keyswitch 顺序双通） | 来源 |
|---|---|---|---|
| 面积 | 113,586 LUT / 180 BRAM36 | **+0%**（复用同一 keyswitch 实例，仅份额缓冲与 FSM） | E39 生产资源模型 |
| keyswitch 延时 | 2×poly_mult | +100%（双通） | E39 |
| 每次密文乘法 | 6×poly_mult → 8×（**+33%**） | 同左 | E39 |
| 批吞吐 | E21 锚点（100 MHz，100 MHz 操作点数字） | **−25%** | E39 |
| 每乘能耗 | 1.489 mJ/poly_mult·6 | ≈1.489×8 = 1.99 mJ（+33%，功耗锚点 0.698 W 不变，纯时间摊销） | E34 推算 |
| 能效 | 68.8 M ops/J / 1415 samples/W | −25% → ≈51.6 M ops/J / ≈1061 samples/W；对 A100 优势 15.3× → ≈11.5× | E17/E18 推算 |
| 二阶防护 | — | 需每份额独立重随机化 + 门级毛刺建模，成本未评估（|t|=3.40 残余即二阶根信号） | E39 + 分析 |

**未防护模块的剩余风险声明**：A-CT 信道在 A1 攻击者下无密钥价值，但在"权重隐私"威胁下（模型
所有者视角）仍是泄露面；本设计对此**不提供**防护，论文 §9.3 限制项已声明。

## 7. 攻击成功判据 vs 检测判据（诚实边界）

- TVLA 检出 ≠ 密钥恢复：E39 只做一阶泄露存在性判定，无 CPA/模板攻击，无 trace 数估计实测。
- 一阶 TVLA 通过 ≠ 芯片无泄露：只监测了 keyswitch 寄存器，NTT 中间节点、BRAM 地址线未覆盖；
  门级毛刺与布线电容差异未建模。
- 本模型的定量部分（+0% 面积、+33% 延时、−25% 吞吐）来自综合资源模型与 E39 的顺序双通结构，
  属"架构级成本定律"，非板级实测。
- A3（故障）攻击的成功率与防护代价归 E52。

## 8. 与论文的对接

- 主稿 §7.8 末尾追加 4 行威胁模型摘要（attacker tiers + 资产收缩论证 + 成本上界引用）；
  完整模型见**补充材料附录 D**（本报告的正式版本）。
- §9.2 Future Work item 3 更新为引用本威胁模型的剩余项（二阶/毛刺/权重隐私/控制流）。
- 不改动任何功耗/吞吐/能效锚点数字（一阶防护是可选部署，论文报告未防护配置）。
"""

JSON = {
    "id": "E51",
    "name": "Full-pipeline side-channel threat model",
    "date": "2026-10-26",
    "type": "analysis",
    "attacker_tiers": [
        {"tier": "A1", "profile": "passive non-profiled (TVLA/CPA, power/EM)",
         "goal": "recover relinearization key (a,b) -> recover s",
         "evidence": "E39 positive control |t|=43.7 (a_buf HW), 59.7 (b_buf HW); "
                     "CPA trace count = estimate only (hundreds-thousands, 8-bit limbs of 45-bit coefficients)"},
        {"tier": "A2", "profile": "passive profiled / higher-order",
         "goal": "same, plus noise-level inference",
         "evidence": "E39 masked toggle proxy residual |t|=3.40 (a2 = key - a1 sequence dependence)"},
        {"tier": "A3", "profile": "active fault injection (clk/vcc glitch, laser)",
         "goal": "break correctness / bypass masking", "evidence": "deferred to E52"},
    ],
    "assets": [
        {"id": "A-RLK", "name": "relinearization key (a,b)",
         "location": "keyswitch_pipe a_buf/b_buf (BRAM)", "sensitivity": "critical",
         "leak_consequence": "b ~ -a*s + e (mod q, small e) => exact (a,b) allows rounding recovery of s"},
        {"id": "A-SK", "name": "secret key s", "location": "host only", "sensitivity": "n/a (never on chip)"},
        {"id": "A-CT", "name": "ciphertexts / model weights", "location": "all BRAMs and buses",
         "sensitivity": "medium", "leak_consequence": "weight statistics, not s"},
        {"id": "A-RNG", "name": "share re-randomization entropy", "location": "keyswitch_masked per-trace shares",
         "sensitivity": "high (masking premise)", "leak_consequence": "degenerate masking revives first-order leak"},
        {"id": "A-TW", "name": "twiddle tables omega/omega^-1", "location": "ntt_mem_tdp_prod BRAM",
         "sensitivity": "public"},
    ],
    "modules": [
        {"module": "keyswitch_pipe", "assets": ["A-RLK", "A-CT"], "channels": ["C1 key register HW/toggle", "C5 BRAM data bus"],
         "first_order_leak": "measured (E39 unmasked |t|=43.7/59.7; masked 0.55)", "required_order": 1,
         "countermeasure": "sequential two-pass additive masking", "cost": "0% area, +100% keyswitch latency"},
        {"module": "approx_poly_mult / poly_mult (NTT+PWM+INTT)", "assets": ["A-CT"], "channels": ["C2 data-dependent toggles"],
         "first_order_leak": "none against s (NTT addressing fixed, no key material)", "required_order": 0,
         "cost": "n/a for A1; >=2x for weight-privacy first-order (bilinear pointwise mult)"},
        {"module": "rescale", "assets": ["A-CT"], "channels": ["C2"], "required_order": 0, "cost": "n/a"},
        {"module": "activation_approx", "assets": ["A-CT"], "channels": ["C2", "C3 coeff ROM address"],
         "required_order": 0, "cost": "public coefficients"},
        {"module": "noise_monitor + adaptive_gear_ctrl", "assets": ["A-CT derived statistics"],
         "channels": ["C4 control-flow timing (gear switching instants depend on ciphertext noise level)"],
         "required_order": 0, "cost": "accepted + declared; leaks noise statistics, not key"},
        {"module": "ckks_bram / ntt_mem_tdp_prod", "assets": ["A-RLK (keyswitch side only)", "A-CT"],
         "channels": ["C5 BRAM bus activity (82-90% of dynamic power, E34)"], "required_order": 1,
         "cost": "follows keyswitch"},
        {"module": "e2e_slot_simd_wrapper / fc / conv / maxpool", "assets": ["A-CT"], "channels": ["C2"],
         "required_order": 0},
        {"module": "m6 bringup (JTAG/UART)", "assets": ["control interface"], "channels": ["C6 debug port"],
         "required_order": 0, "cost": "process requirement: disable ILA/debug readback in production"},
    ],
    "linearity_analysis": {
        "keyswitch_linear_in_key": True,
        "ntt_linear": True,
        "pointwise_mult_bilinear": True,
        "conclusion": "cheap one-order masking covers key x ciphertext ops only; ciphertext x ciphertext needs masked triples (>=2x)",
        "security_argument": "s-targeting attacker (A1) only needs keyswitch masked because c.d factors are non-key A-CT",
    },
    "full_chain_first_order_cost": {
        "area_overhead": "0% (sequential two-pass reuses the keyswitch instance)",
        "keyswitch_latency": "+100%",
        "per_multiplication_latency": "+33% (6->8 poly_mult)",
        "batch_throughput": "-25%",
        "energy_per_multiplication_mJ": {"unmasked": 1.489, "masked": 1.99, "source": "E34 0.698 W anchor, time-amortized"},
        "efficiency": {"unmasked_ops_per_J": 68.8e6, "masked_ops_per_J": 51.6e6,
                       "unmasked_samples_per_W": 1415, "masked_samples_per_W": 1061,
                       "vs_a100": {"unmasked": 15.3, "masked": 11.5}},
    },
    "honest_limits": [
        "TVLA detection != key recovery; no CPA/template attack executed; trace counts are estimates",
        "first-order TVLA pass != leakage-free chip: only keyswitch registers monitored, no NTT mid-nodes/BRAM addresses",
        "no gate-level glitch/IR-drop modelling; behavioural proxies only (E39 scope)",
        "trust boundary (s never on chip) is an assumption of this design, not verified on board",
        "A3 fault analysis deferred to E52",
    ],
    "paper_integration": {"main": "Sec. 7.8 tail (threat model summary, 4 lines)",
                          "supplementary": "Appendix D", "future_work": "Sec. 9.2 item 3 update",
                          "anchors_untouched": "all power/throughput/efficiency anchors (unmasked configuration)"},
}

with io.open(os.path.join(OUT, "e51_sca_threat_model.md"), "w", encoding="utf-8", newline="") as f:
    f.write(MD)
with io.open(os.path.join(OUT, "e51_sca_threat_model.json"), "w", encoding="utf-8") as f:
    json.dump(JSON, f, indent=2, ensure_ascii=False)
print("E51 report + JSON written")
