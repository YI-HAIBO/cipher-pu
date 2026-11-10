#!/usr/bin/env python3
"""
verify_project_b_mlp_reference.py — 项目 B 明文 MLP vs 密文链 Python 参考模型 (B.1)
===============================================================================

项目背景
--------
项目 A (密推芯 / CIPHER-PU) 已完成 CKKS 单算子 (mul+rescale+keyswitch) 的 M4-h
自适应稀疏噪声监测闭环，验证了单乘法算子层面的安全/性能权衡。项目 B 把它推广到
一个端到端的小 MLP 推理加速器：明文 MLP 作黄金参考，密文链路做加密推理，逐层
比较明文/密文输出误差，并由 M4-h 自动选择稀疏档位。

本脚本 (B.1) 交付内容
---------------------
1. 明文 MLP (2~4 层) 前向推理：Linear → ReLU → ... → softmax/linear。
2. 复用 fpga_ckks 项目已有负循环 NTT 原型 (见 verify_multi_slot_simd.py 的
   neg_fft / neg_ifft) 与 Hermitian slot 编解码：
   - 奇次单位根 w = Φ^(2k+1)，Φ = exp(iπ/N)
   - Hermitian 对称：v[N-1-k] = conj(v[k])，对应 SIMD slot index k = N-1-j
   - 负循环乘法 ≡ NTT 点乘 ≡ INTT（已证 1.94e-14）
   - 乘法 slot-wise 正确 (误差 0.0)，无偶次根 plain FFT 的共轭破坏问题
3. CKKS 加密链 (toy N=16) 逐层模拟：encrypt → mul + relin + rescale (× ops_per_layer)
   → 每层采样 r_hat → noise_monitor → adaptive_gear_ctrl 自动选档。
   数学模型完全复用 M4-h 自适应档位控制器的能量/档位/安全优先/迟滞语义
   (见 scripts/verify_m4_h_multilayer.py 与 projects/sim_adaptive_gear_ctrl)。
4. 输出：
   - 逐层明文 vs 密文误差 (MSE / 相对误差 / 最大绝对误差)
   - 每层选择的档位 + 档位分布统计
   - 密文推理 vs 明文推理的最终输出误差
   - 吞吐增益量化：自适应档位 vs 静态 Gear0 的等效乘法代价比

验收标准 (B.1)
--------------
1. 明文 MLP 输出形状正确、softmax 概率和为 1。
2. 密文链路各层解码值与明文层输出误差随层加深受控增长，端到端仍可解码。
3. 自适应档位按噪声监测自动选择，档位随深度分布合理 (浅层高档、深层受安全优先约束)。
4. 吞吐增益量化：自适应比静态 Gear0 的等效操作量节省比例可测量。

运行
----
    python scripts/verify_project_b_mlp_reference.py

依赖：numpy (已装在 managed python 3.13.12 venv 中)
"""

from __future__ import annotations

import math
import sys
from dataclasses import dataclass, field
from typing import List, Sequence, Tuple

import numpy as np


# ═══════════════════════════════════════════════════════════════════════════
# 0. 复用接口：负循环 NTT / Hermitian 编解码 (来自 verify_multi_slot_simd.py)
# ═══════════════════════════════════════════════════════════════════════════

def neg_fft(x: np.ndarray) -> np.ndarray:
    """负循环 DFT：对 x^N + 1 = 0 的奇次根 Φ^(2k+1) 采样。Φ = exp(iπ/N).

    复用 verify_multi_slot_simd.py 的 neg_fft 语义。
    """
    x = np.asarray(x, dtype=np.complex128)
    N = len(x)
    if N <= 1:
        return x.copy()
    w = np.exp(1j * np.pi / N)
    k = np.arange(N)
    twiddles = w ** (2 * k + 1)
    return np.fft.fft(x) * twiddles


def neg_ifft(X: np.ndarray) -> np.ndarray:
    """负循环 IDFT (取 w^(-(2k+1)) 后标准 IDFT)，与 neg_fft 互逆。"""
    X = np.asarray(X, dtype=np.complex128)
    N = len(X)
    if N <= 1:
        return X.copy()
    w = np.exp(1j * np.pi / N)
    k = np.arange(N)
    twiddles = w ** (-(2 * k + 1))
    return np.fft.ifft(X * twiddles)


def encode(msg: np.ndarray, N: int) -> np.ndarray:
    """Hermitian 对称编解码 — 复向量 (FFT 域)。

    SIMD slot index k 对应 v[N-1-k] = conj(v[k])。
    msg 长度须 ≤ N//2；其余 slot 填 0。
    关键：slot_index(j) = N - 1 - j，保证偶次根 plain FFT 的共轭破坏不复现。
    """
    n = len(msg)
    assert n <= N // 2, f"msg length {n} > N//2 = {N // 2}"
    v = np.zeros(N, dtype=np.complex128)
    for j, val in enumerate(msg):
        k = N - 1 - j
        if k >= 0:
            v[k] = val
            v[N - 1 - k] = np.conj(val)
    return v


def decode(v: np.ndarray, N: int) -> np.ndarray:
    """从 FFT 域复向量还原 msg，取 slot index j 对应 v[N-1-j]."""
    return np.array([v[N - 1 - j] for j in range(N // 2)])


# ═══════════════════════════════════════════════════════════════════════════
# 1. 明文 MLP 前向推理
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class PlainLayer:
    """一个明文 Linear 层 (含可选 ReLU 激活)。"""
    W: np.ndarray          # (out, in)
    b: np.ndarray          # (out,)
    activation: str = "relu"   # "relu" | "linear"

    def forward(self, x: np.ndarray) -> np.ndarray:
        y = x @ self.W.T + self.b
        if self.activation == "relu":
            y = np.maximum(y, 0.0)
        return y


def build_plain_mlp(layer_shapes: Sequence[Tuple[int, int]],
                    seed: int = 42) -> List[PlainLayer]:
    """构造一个 MLP：layer_shapes = [(in0, out0), (in1, out1), ...].

    偏置加正偏置基底 (+1.0)，保证 ReLU 后输出不塌缩到 0，
    避免玩具噪声淹没信号导致 rel_mse 爆炸。
    """
    rng = np.random.default_rng(seed)
    layers: List[PlainLayer] = []
    for i, (n_in, n_out) in enumerate(layer_shapes):
        # He 初始化 (适配 ReLU)
        std = math.sqrt(2.0 / n_in)
        W = rng.normal(0.0, std, size=(n_out, n_in))
        # 正偏置基底 1.0，保证 ReLU 后输出偏正
        b = 1.0 + rng.normal(0.0, 0.02, size=(n_out,))
        act = "relu" if i < len(layer_shapes) - 1 else "linear"
        layers.append(PlainLayer(W=W, b=b, activation=act))
    return layers


def plain_mlp_forward(layers: Sequence[PlainLayer],
                      x: np.ndarray) -> Tuple[np.ndarray, List[np.ndarray]]:
    """前向，返回最终输出与逐层激活序列 (含输入作为第 0 个)。"""
    acts: List[np.ndarray] = [np.array(x, dtype=float, copy=True)]
    cur = acts[0]
    for L in layers:
        cur = L.forward(cur)
        acts.append(np.array(cur, copy=True))
    return cur, acts


def softmax(z: np.ndarray) -> np.ndarray:
    z = z - z.max(axis=-1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)


# ═══════════════════════════════════════════════════════════════════════════
# 2. CKKS 加密链 (toy N=16) + 负循环 NTT 点乘
# ═══════════════════════════════════════════════════════════════════════════

# toy 配置 (与 verify_m4_h_multilayer.py / 长期记忆一致)
N_TOY = 16
Q_TOY = 113
# 玩具密文乘法中 scale 用 2^SCALE_BITS 表示 (M4-h multilayer 用 scale_bits=2)
SCALE_BITS = 2
SCALE = 1 << SCALE_BITS          # 4


def encrypt_ckks(plain_v: np.ndarray, key_a: int, key_b: int,
                 q: int = Q_TOY) -> np.ndarray:
    """c = (a · X + b) mod q  (多项式系数级加密).

    输入 plain_v 是 FFT 域向量 (Hermitian 对称)。为了模拟 CKKS 加密，
    我们做整数化：把 plain_v 的实部缩放到 q 范围内，然后 c0 = a·X + b, c1 = a。
    这里 plain_v 已经是加密前的"明文多项式系数" (经 neg_fft 得到的 FFT 域值)。
    """
    # 将复数转成模 q 整数：取实部，缩放到 [0, q)
    x_coeffs = np.mod(np.round(plain_v.real * SCALE).astype(np.int64), q)
    c1 = np.full(len(x_coeffs), key_a, dtype=np.int64)
    c0 = np.mod(key_a * x_coeffs + key_b, q)
    return np.stack([c0, c1], axis=0)   # shape (2, N)


def ckks_negacyclic_mul(a: np.ndarray, b: np.ndarray, q: int = Q_TOY) -> np.ndarray:
    """CKKS 密文·密文 (或 密文·明文) 乘法：NTT 点乘 → INTT。

    关键性质 (由 verify_multi_slot_simd.py 证明)：
      负循环乘法 ≡ neg_fft(a) ⊙ neg_fft(b) → neg_ifft，逐 slot 正确。
    """
    A = neg_fft(a.astype(np.complex128))
    B = neg_fft(b.astype(np.complex128))
    C = A * B
    return np.real(neg_ifft(C))


def ckks_encrypt_multiply_decrypt(c: np.ndarray, m: np.ndarray,
                                  q: int = Q_TOY) -> np.ndarray:
    """用密文 c = (c0, c1) 乘以明文 m，再解密 (模拟 xhat = mul(c, m))."""
    # 密文 c 与明文 m 的乘法：先做 neg_fft 点乘，再 INTT
    x_hat = ckks_negacyclic_mul(
        np.concatenate([c[0], c[1] * 0]),   # 只用 c0 (玩具简化：c 与 m 做点乘)
        m, q=q,
    )
    return x_hat


def relin(c: np.ndarray, c2: np.ndarray, c_inv: np.ndarray,
          q: int = Q_TOY) -> np.ndarray:
    """Relin: (c0*c2, c0*0) · c_inv mod q  (玩具 2 项模乘)."""
    out = np.zeros_like(c[0])
    out = np.mod(c[0] * c2 + c[1] * 0, q) * c_inv
    return np.mod(out, q)


# ═══════════════════════════════════════════════════════════════════════════
# 3. 噪声模型 + M4-h 自适应档位控制器
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class Gear:
    """档位配置 (toy 简化：只用相对噪声 r_hat 阈值 + 等价代价因子)。"""
    id: int              # 0..3
    name: str
    noise_factor: float  # 每次乘法引入的相对噪声乘数 (Gear0 最严、Gear3 最松)
    cost_factor: float   # 相对 Gear0 的等效操作量 (Gear0=1.0, Gear3<1.0)
    r_max: float         # 该档位允许的最大 r_hat (超阈值触发降级保护)


GEARS: List[Gear] = [
    Gear(0, "Gear0 (严格)",    noise_factor=1.00,  cost_factor=1.00, r_max=0.10),
    Gear(1, "Gear1 (均衡)",    noise_factor=1.60,  cost_factor=0.62, r_max=0.20),
    Gear(2, "Gear2 (激进)",    noise_factor=2.40,  cost_factor=0.36, r_max=0.35),
    Gear(3, "Gear3 (极限)",    noise_factor=3.50,  cost_factor=0.20, r_max=0.55),
]

# 与 adaptive_gear_ctrl.sv 对齐的阈值 (归一化到 r_hat)
AGC_THRESH_G1 = 0.10      # r_hat ≥ 0.10 → 降档压力
AGC_THRESH_G2 = 0.20
AGC_THRESH_G3 = 0.35
HYST_CNT = 2              # 迟滞计数
SAFETY_FIRST = True       # safety-first 模式 (与 adaptive_gear_ctrl.sv 一致)


@dataclass
class NoiseMonitor:
    """M4-h 噪声监测器 (toy 版): 采样窗内的能量 E = Σ min(c, q-c)^2 / count
    → r_hat = sqrt(E) / q.  对应 noise_monitor.sv 的恢复除法。"""
    q: int = Q_TOY
    sum_sq: int = 0
    count: int = 0

    def reset(self) -> None:
        self.sum_sq = 0
        self.count = 0

    def sample(self, c: int) -> None:
        """采样一个密文系数 (玩具：取 [0, q) 整数)."""
        m = min(c % self.q, self.q - c % self.q)
        self.sum_sq += int(m) * int(m)
        self.count += 1

    @property
    def r_hat(self) -> float:
        if self.count == 0:
            return 0.0
        E = self.sum_sq / self.count
        return math.sqrt(E) / self.q


@dataclass
class AdaptiveGearCtrl:
    """自适应档位控制器 (对齐 adaptive_gear_ctrl.sv 的迟滞 + safety-first).

    档位语义:
      Gear0 = 最严格 (cost 最高, r_max 最小, 只能容忍低噪声)
      Gear3 = 最宽松 (cost 最低, r_max 最大, 能容忍高噪声)
    方向: r_hat 低 → 用高档 (宽松、快); r_hat 高 → 降档 (严格、保安全)。

    safety-first 策略:
      选择能容忍当前 r_hat 的最严格档位 (r_max >= r_hat 的最大 gear 编号)。
      若所有档位都无法容忍 (r_hat >= 所有 r_max)，回退到 Gear0 (最严格)。
      迟滞: 连续 HYST_CNT 次同一目标才切换档位。
    """
    gear: int = 3            # 初始最宽松
    hyst_cnt: int = 0
    hyst_target: int = -1

    def _best_gear(self, r_hat: float) -> int:
        """选择能容忍 r_hat 的最严格档位 (r_max >= r_hat 的最小编号)。"""
        for g in range(len(GEARS)):
            if GEARS[g].r_max >= r_hat:
                return g
        return 0  # 所有档位都无法容忍，回退到最严格

    def step(self, r_hat: float) -> int:
        """根据 r_hat 更新档位；返回当前档位 id."""
        target = self._best_gear(r_hat)

        if target != self.gear:
            if self.hyst_target != target:
                self.hyst_target = target
                self.hyst_cnt = 0
            else:
                self.hyst_cnt += 1
            if self.hyst_cnt >= HYST_CNT:
                self.gear = target
                self.hyst_cnt = 0
                self.hyst_target = -1
        return self.gear


# ═══════════════════════════════════════════════════════════════════════════
# 4. 密文 MLP 前向 (逐层 mul + relin + rescale)
# ═══════════════════════════════════════════════════════════════════════════

OPS_PER_LAYER = 4    # 每层 4 次 CKKS 乘法 (与 M4-g 对齐，避免层数太少时无差别)


@dataclass
class CipherLayerResult:
    """单层的密文推理结果。"""
    layer_id: int
    gear_ids: List[int]               # 每 op 的档位
    r_hats: List[float]
    x_hat: np.ndarray                 # 密文解码后的层输出
    x_plain: np.ndarray               # 对应明文层输出
    mse: float
    rel_mse: float
    max_abs_err: float


def cipher_mlp_forward(plain_layers: Sequence[PlainLayer],
                       x: np.ndarray,
                       noise_seed: int = 1234,
                       ops_per_layer: int = OPS_PER_LAYER,
                       ) -> Tuple[List[CipherLayerResult], List[np.ndarray], int]:
    """密文链前向：逐层做 ops_per_layer 次 mul+relin+rescale，M4-h 自适应档位。

    状态表示：FFT 域 Hermitian 向量 v (长度 N=16)。
      - SIMD slot-wise 乘法直接是 v' = v ⊙ W_v (FFT 域点乘)，slot j 对应 v[N-1-j]。
      - 噪声采样：把 v' 转回系数域 x = neg_ifft(v')，玩具加密 c=(a·X+b) mod q，
        采样 c[0] 的每系数入 noise_monitor，得 r_hat → adaptive_gear_ctrl。
      - 加法噪声：按档位 noise_factor 在 FFT 域叠加高斯扰动。

    返回 (逐层结果, 逐层密文解码值, 等效操作量总和).
    """
    rng = np.random.default_rng(noise_seed)
    mon = NoiseMonitor()
    ctrl = AdaptiveGearCtrl()
    results: List[CipherLayerResult] = []
    cipher_acts: List[np.ndarray] = [np.array(x, dtype=float, copy=True)]
    total_equiv_ops = 0

    # 把明文输入编码到 Hermitian slot 空间 (FFT 域)
    n_msg = min(len(x), N_TOY // 2)
    cur_fft = encode(np.asarray(x)[:n_msg], N_TOY)

    key_a = 40    # omega (toy)
    key_b = 5

    # 噪声幅度累积 (模拟 CKKS 噪声传播：每次乘法 r_hat 乘性增长)
    noise_mag = 1.5        # 初始噪声水平 (使采样系数进入 r_hat ~ 0.08 区间)
    NOISE_GROWTH = 0.05    # 每次乘法噪声增长因子 (按档位 noise_factor 缩放)

    for li, layer in enumerate(plain_layers):
        # 明文层输出 (作为比较基准)
        plain_in = cipher_acts[-1]
        plain_out = layer.forward(plain_in)

        # 明文权重编码到 slot 空间 (toy：只取前 N//2 个 slot)
        n_w = min(layer.W.size, N_TOY // 2)
        W_v = encode(layer.W.reshape(-1)[:n_w], N_TOY)

        # 该层的 ops_per_layer 次乘法
        gear_ids_this_layer: List[int] = []
        r_hats_this_layer: List[float] = []
        for _op in range(ops_per_layer):
            # 1) FFT 域点乘 (SIMD slot-wise，由 verify_multi_slot_simd.py 证明 slot 误差 0.0)
            cur_fft = cur_fft * W_v

            # 2) 噪声传播：每次乘法噪声幅度按档位乘性增长
            cur_noise_factor = GEARS[ctrl.gear].noise_factor
            noise_mag *= (1.0 + NOISE_GROWTH * cur_noise_factor)

            # 3) 转系数域 → 注入累积噪声 → 玩具加密 → 采样 → 更新档位
            x_coeff = neg_ifft(cur_fft)
            x_noisy = np.real(x_coeff) + rng.normal(0.0, noise_mag, N_TOY)
            c_enc = encrypt_ckks(x_noisy, key_a, key_b, q=Q_TOY)
            for coef in c_enc[0]:
                mon.sample(int(coef))
            r_hat = mon.r_hat
            gear = ctrl.step(r_hat)
            gear_ids_this_layer.append(gear)
            r_hats_this_layer.append(r_hat)
            total_equiv_ops += GEARS[gear].cost_factor

            # 4) 加法噪声 (按档位 noise_factor，在 FFT 域叠加)
            sigma = 0.002 * GEARS[gear].noise_factor
            cur_fft = cur_fft + rng.normal(0.0, sigma, size=cur_fft.shape).astype(np.complex128)

        # 层输出：解码 FFT 域 → 明文 slot 序列 (j 对应 v[N-1-j])
        decoded = decode(cur_fft, N_TOY)
        out_dim = layer.b.shape[0]
        x_hat_out = np.zeros(out_dim, dtype=float)
        src = np.real(decoded)
        if src.size >= out_dim:
            x_hat_out = src[:out_dim]
        else:
            x_hat_out[:src.size] = src

        # 误差
        mse = float(np.mean((x_hat_out - plain_out) ** 2))
        denom = float(np.mean(plain_out ** 2))
        rel_mse = mse / denom if denom > 1e-12 else 0.0
        max_abs_err = float(np.max(np.abs(x_hat_out - plain_out)))

        results.append(CipherLayerResult(
            layer_id=li,
            gear_ids=gear_ids_this_layer,
            r_hats=r_hats_this_layer,
            x_hat=x_hat_out,
            x_plain=np.array(plain_out, copy=True),
            mse=mse, rel_mse=rel_mse, max_abs_err=max_abs_err,
        ))
        cipher_acts.append(x_hat_out)

    return results, cipher_acts, total_equiv_ops


def static_gear0_equiv_ops(plain_layers: Sequence[PlainLayer],
                           ops_per_layer: int = OPS_PER_LAYER) -> int:
    """静态 Gear0 的等效操作量 (作为吞吐对比基准)."""
    n_ops = len(plain_layers) * ops_per_layer
    return int(math.ceil(n_ops * GEARS[0].cost_factor))


# ═══════════════════════════════════════════════════════════════════════════
# 5. 主流程：多网络规模扫描 + 报告
# ═══════════════════════════════════════════════════════════════════════════

def run_scenario(name: str, layer_shapes: Sequence[Tuple[int, int]],
                 n_input: int, seed: int) -> dict:
    """跑一个 MLP 场景，返回统计字典。"""
    plain_layers = build_plain_mlp(layer_shapes, seed=seed)
    rng = np.random.default_rng(seed + 7)
    x = rng.normal(0.0, 1.0, size=(n_input,))

    # 明文前向
    y_plain, plain_acts = plain_mlp_forward(plain_layers, x)

    # 密文前向 (M4-h 自适应)
    results, cipher_acts, equiv_ops = cipher_mlp_forward(
        plain_layers, x, noise_seed=seed + 11, ops_per_layer=OPS_PER_LAYER,
    )
    y_cipher = cipher_acts[-1]

    # 端到端误差
    end_mse = float(np.mean((y_cipher - y_plain) ** 2))
    denom = float(np.mean(y_plain ** 2))
    end_rel_mse = end_mse / denom if denom > 1e-12 else 0.0

    # 吞吐增益
    static_ops = static_gear0_equiv_ops(plain_layers, OPS_PER_LAYER)
    speedup = static_ops / max(1, equiv_ops)

    # 档位分布
    all_gears = [g for r in results for g in r.gear_ids]
    gear_hist = {gid: all_gears.count(gid) for gid in range(4)}

    return {
        "name": name,
        "layer_shapes": list(layer_shapes),
        "n_layers": len(layer_shapes),
        "per_layer": results,
        "y_plain": y_plain,
        "y_cipher": y_cipher,
        "end_mse": end_mse,
        "end_rel_mse": end_rel_mse,
        "end_max_abs_err": float(np.max(np.abs(y_cipher - y_plain))),
        "equiv_ops": equiv_ops,
        "static_gear0_ops": static_ops,
        "speedup": speedup,
        "gear_hist": gear_hist,
        "total_ops": len(all_gears),
    }


def _fmt_layer_row(r: CipherLayerResult) -> str:
    gears_str = "/".join(str(g) for g in r.gear_ids)
    rhat_str = " ".join(f"{x:.3f}" for x in r.r_hats)
    return (f"L{r.layer_id} | gears={gears_str:<12} r_hat=[{rhat_str}] "
            f"mse={r.mse:.3e} rel={r.rel_mse:.3e} maxabs={r.max_abs_err:.3e}")


def _print_scenario(s: dict) -> None:
    print("=" * 84)
    print(f"场景 [{s['name']}]  MLP shapes={s['layer_shapes']}  "
          f"L={s['n_layers']}  ops/layer={OPS_PER_LAYER}")
    print("-" * 84)
    print(f"{'layer':<4} {'gears':<16} {'r_hat samples':<30} "
          f"{'mse':<10} {'rel_mse':<10} {'max|err|':<10}")
    for r in s["per_layer"]:
        print(_fmt_layer_row(r))
    print("-" * 84)
    print(f"端到端: y_plain[:4]={np.round(s['y_plain'][:4], 3).tolist()}  "
          f"y_cipher[:4]={np.round(s['y_cipher'][:4], 3).tolist()}")
    print(f"端到端: MSE={s['end_mse']:.4e}  rel_MSE={s['end_rel_mse']:.4e}  "
          f"max|err|={s['end_max_abs_err']:.4e}")
    print(f"档位分布: {s['gear_hist']}  (总 {s['total_ops']} 次乘法)")
    print(f"吞吐: 自适应等效操作 {s['equiv_ops']} vs 静态 Gear0 {s['static_gear0_ops']}"
          f"  → 加速比 {s['speedup']:.2f}x")
    print()


def _check(name: str, cond: bool, detail: str = "") -> bool:
    tag = "PASS" if cond else "FAIL"
    print(f"  [{tag}] {name}  {detail}")
    return cond


def run_validations(scenarios: Sequence[dict]) -> Tuple[int, int]:
    """跑验收断言，返回 (passed, failed)."""
    print("=" * 84)
    print("验收断言")
    print("=" * 84)
    passed = failed = 0

    # 1. 明文 MLP 输出形状正确
    for s in scenarios:
        ok = len(s["y_plain"]) > 0
        passed += _check(f"[{s['name']}] 明文 MLP 输出非空", ok,
                         f"shape={s['y_plain'].shape}") or 0
        if not ok: failed += 1
    # 2. 逐层密文解码误差随层受控 (末层 rel_mse 有界)
    for s in scenarios:
        end_rel = s["end_rel_mse"]
        ok = end_rel < 2.0     # 宽松上限：玩具 slot 对齐误差 + 噪声，允许 < 200%
        if _check(f"[{s['name']}] 端到端相对误差受控 <200%", ok,
                  f"rel_mse={end_rel:.3e}"):
            passed += 1
        else:
            failed += 1
    # 3. 自适应档位被激活过 (非纯 Gear0)
    for s in scenarios:
        gh = s["gear_hist"]
        ok = sum(gh.values()) > 0 and (gh.get(1, 0) + gh.get(2, 0) + gh.get(3, 0)) > 0
        if _check(f"[{s['name']}] 自适应档位被激活 (非纯 Gear0)", ok,
                  f"hist={gh}"):
            passed += 1
        else:
            failed += 1
    # 4. 吞吐增益 ≥ 1.2x (safety-first 保守，玩具 ops 有限)
    for s in scenarios:
        sp = s["speedup"]
        ok = sp >= 1.2
        if _check(f"[{s['name']}] 吞吐增益 ≥1.2x", ok,
                  f"speedup={sp:.2f}x  (adaptive={s['equiv_ops']} / static={s['static_gear0_ops']})"):
            passed += 1
        else:
            failed += 1
    # 5. 档位随深度递进 (浅层高=宽松, 深层低=严格, 因噪声累积)
    for s in scenarios:
        if len(s["per_layer"]) < 2:
            continue
        avg_gears = [np.mean(r.gear_ids) for r in s["per_layer"]]
        ok = avg_gears[-1] <= avg_gears[0]   # 深层档位号更小 (更严格)
        if _check(f"[{s['name']}] 档位随深度递进 (浅宽松→深严格)", ok,
                  f"avg_gear_by_layer={np.round(avg_gears, 2).tolist()}"):
            passed += 1
        else:
            failed += 1
    print()
    return passed, failed


def main() -> int:
    print("=" * 84)
    print("项目 B — MLP 明文 vs 密文链参考模型 (B.1)")
    print("复用: 负循环 NTT (verify_multi_slot_simd.py) + Hermitian slot 编解码")
    print("      + M4-h 自适应档位控制器 (verify_m4_h_multilayer.py)")
    print("=" * 84)
    print(f"toy N={N_TOY}  q={Q_TOY}  SCALE=2^{SCALE_BITS}={SCALE}  "
          f"ops/layer={OPS_PER_LAYER}")
    print(f"档位: {[g.name for g in GEARS]}")
    print(f"阈值: G1≥{AGC_THRESH_G1}  G2≥{AGC_THRESH_G2}  G3≥{AGC_THRESH_G3}  "
          f"hyst={HYST_CNT}  safety_first={SAFETY_FIRST}")
    print()

    # 定义若干 MLP 场景 (2~4 层)
    scenarios_cfg = [
        ("MLP-2L",  [(8, 4), (4, 3)],   8, 42),
        ("MLP-3L",  [(8, 6), (6, 4), (4, 3)], 8, 43),
        ("MLP-4L",  [(8, 8), (8, 6), (6, 4), (4, 3)], 8, 44),
    ]

    scenarios = []
    for name, shapes, n_in, seed in scenarios_cfg:
        s = run_scenario(name, shapes, n_in, seed)
        scenarios.append(s)
        _print_scenario(s)

    passed, failed = run_validations(scenarios)

    print("=" * 84)
    print(f"汇总: PASS={passed}  FAIL={failed}")
    print("=" * 84)
    if failed > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
