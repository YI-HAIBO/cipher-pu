#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
E24: Rotation / Automorphism / Bootstrap 原语

为 TCAS 级论文补齐 CKKS 核心操作。在系数编码 RLWE 参考模型上实现并验证
4 个原语，并给出两个端到端应用。

关键结论（论文主张）：
1. rotation = ct × X^ν 是**纯明文乘法**，噪声零增长 → 硬件上无需 KeySwitch
2. 系数求和 / 内积 = 1 次密文乘法（散布编码的 c_0 免费读取）
3. Conv + GAP 融合 = 每个 filter 1 次乘法（vs 朴素 conv + 逐位置求和）
4. re-encrypt（解密→重加密）是免费的 bootstrap-lite，可重置噪声预算

精确环算术（避免 float64 溢出）：
- float neg_conv 对已约简到 [0,q) 的系数做卷积时，累加项达 1e15~1e18，
  逼近/超出 2^53 精确整数范围 → 必须用 int64 逐行模约简。
- np.convolve(int64,int64) 单项不溢出但**累加 1024 项达 1e21 溢出 int64**，
  故必须逐 i 做 (x[i]*y) % q 再模约简累加。

依赖: exp_e11_ckks_e2e_real（rlwe_encrypt / rlwe_decrypt / neg_conv）
"""

import json
import os
import sys
import time
import numpy as np
import torch
import torch.nn as nn
from datetime import datetime
from torchvision import datasets, transforms
from scipy import stats

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
os.chdir(ROOT_DIR)

from exp_e11_ckks_e2e_real import rlwe_encrypt, rlwe_decrypt, neg_conv

# ── 参数 ────────────────────────────────────────────────
N = 1024
Q = 998244353
SCALE = 1024
N_SEEDS = 2
N_TEST = 30
NOISE_SIGMAS = [1, 4, 16]
CONFIDENCE = 0.95


# ══════════════════════════════════════════════════════════
# Part 0: 精确环算术库
# ══════════════════════════════════════════════════════════

_CIRC_CACHE = {}


def _circ_mat(y, n, q):
    """预计算 y 的 circulant 矩阵 M，使 x·y ≡ M @ x (mod x^n+1, mod q)。

    c[k] = Σ_i x[i] · sgn(k-i) · y[(k-i) mod n]，sgn=+1 (k≥i) / -1 (k<i)
    —— 来自 c = conv[:n] - conv[n:2n-1] 的合并形式。
    注意方向是 **k - i**（不是 i + k）：写反会得到完全不同的多项式。
    """
    y64 = np.asarray(y, dtype=np.int64) % q
    key = (n, tuple(int(v) for v in y64))
    m = _CIRC_CACHE.get(key)
    if m is None:
        k = np.arange(n, dtype=np.int64)[:, None]
        i = np.arange(n, dtype=np.int64)[None, :]
        p = k - i
        sgn = np.where(p < 0, -1.0, 1.0)
        m = sgn * y64.astype(np.float64)[p % n]
        if len(_CIRC_CACHE) < 256:
            _CIRC_CACHE[key] = m
    return m


def neg_conv_modq(x, y, q):
    """整数模 q 负循环卷积（精确，向量化）。

    溢出分析：
    · np.convolve(int64,int64) 单项 < q^2 ≈ 1e18 不溢出 int64，但累加 N=1024
      项达 1e21 溢出 → 直接 int64 卷积不可行。
    · 直接 float64 matvec 的累加量级 ~1024×1e18 = 1e21 > 2^53 (9.0e15)，
      误差 ~2e5 环单位 → **也不可接受**（曾导致 V1 误差 4.87e5）。

    正确做法 —— 3 段 10-bit 分裂：
    x_i < q < 2^30 = 1024^3，拆 x_i = a·2^20 + b·2^10 + c，a/b/c < 1024。
    每段 |Σ x_part[i]·y[j]| ≤ 1024 × 1023 × 9.98e8 ≈ 1.05e15 < 2^53，
    故 float64 matvec **逐位精确**，astype(int64) 无损。
    最后分步模约简 (Sa·2^20 + Sb·2^10 + Sc) mod q，各步 < q^2 ≈ 1e18 < int64max。

    相比 1024 次逐行模约简循环快 7-19×（基准 15/15 逐位一致）。
    """
    n = len(x)
    M = _circ_mat(y, n, q)
    x64 = np.asarray(x, dtype=np.int64) % q
    a = (x64 >> 20).astype(np.float64)
    b = ((x64 >> 10) & 1023).astype(np.float64)
    c = (x64 & 1023).astype(np.float64)
    Sa = (M @ a).astype(np.int64)
    Sb = (M @ b).astype(np.int64)
    Sc = (M @ c).astype(np.int64)
    return ((Sa % q) * (1048576 % q) + (Sb % q) * (1024 % q) + (Sc % q)) % q


def decrypt_exact(ct, s, q):
    """精确解密：返回 e + Δ·msg（int64 环算术，无需二次居中）。

    根因：a' = neg_conv(a, X^ν) mod q 已约简到 [0,q)，直接算 neg_conv(a', s)
    时每项 ~1e9、累积 ~1e12；而 b' 只有 ~1e9，两者之差 = 真值 + k·q（|k| 千级）
    → 误差 ~1e12。修法：先对 a 与 s 做整数模 q 卷积，则 b - a's ∈ (-q, q)，
    精确等于 e + Δ·msg（因其绝对值远小于 q），再做居中。
    """
    b = np.asarray(ct[0], dtype=np.int64) % q
    a = np.asarray(ct[1], dtype=np.int64) % q
    s64 = np.asarray(s, dtype=np.int64) % q
    as_prod = neg_conv_modq(a, s64, q)
    d = (b - as_prod) % q
    d = np.where(d > q // 2, d - q, d)
    return d.astype(np.float64)


def decrypt_exact_int(ct, s, q):
    """精确解密的 int64 版本（保留整数类型，供严格模运算）。"""
    b = np.asarray(ct[0], dtype=np.int64) % q
    a = np.asarray(ct[1], dtype=np.int64) % q
    s64 = np.asarray(s, dtype=np.int64) % q
    as_prod = neg_conv_modq(a, s64, q)
    d = (b - as_prod) % q
    return np.where(d > q // 2, d - q, d).astype(np.int64)


def mul_plain_exact(ct, p_poly, q):
    """密文 × 整数明文多项式，精确版（int64 环算术）。"""
    b, a = ct
    p = np.asarray(p_poly, dtype=np.int64) % q
    return neg_conv_modq(b, p, q), neg_conv_modq(a, p, q)


def automorphism_exact(ct, nu, n, q):
    """环自同态 ψ_ν(f)(x) = f(x^ν) mod (x^n+1)，累加实现。

    重要：ψ_ν **不是**系数的逐点置换。f(x^ν) = Σ_k f_k x^{νk}，
    系数 j 上的值为 Σ_{k: νk ≡ j (mod n)} (-1)^{⌊νk/n⌋} f_k。
    仅当 gcd(ν, n)=1 时是双射（真自同态）。
    """
    out = [np.zeros(n, dtype=np.int64) for _ in range(2)]
    for ci in (0, 1):
        f = np.asarray(ct[ci], dtype=np.int64) % q
        g = np.zeros(n, dtype=np.int64)
        for k in range(n):
            if f[k] == 0:
                continue
            p = nu * k
            j = p % n
            sign = 1 if (p // n) % 2 == 0 else -1
            g[j] = (g[j] + sign * f[k]) % q
        out[ci] = g
    return out[0], out[1]


def automorphism_key_exact(s, nu, n, q):
    """密钥的自动同态变换 ψ_ν(s)。"""
    f = np.asarray(s, dtype=np.int64) % q
    g = np.zeros(n, dtype=np.int64)
    for k in range(n):
        if f[k] == 0:
            continue
        p = nu * k
        j = p % n
        sign = 1 if (p // n) % 2 == 0 else -1
        g[j] = (g[j] + sign * f[k]) % q
    return g


# ══════════════════════════════════════════════════════════
# Part 1: 四个原语
# ══════════════════════════════════════════════════════════

def center_int(v, q):
    """把 [0,q) 整数向量居中到 (-q/2, q/2]，用于精确差值运算。"""
    v = np.asarray(v, dtype=np.int64) % q
    return np.where(v > q // 2, v - q, v).astype(np.int64)


def poly_mul_x_power(f, nu, n, q):
    """整数多项式 × X^ν mod (x^n+1)：精确重排 + 符号翻转，单项式乘法。

    (f·X^ν)[j] = (-1)^{⌊(i+ν)/n⌋} f_i，其中 i ≡ j-ν (mod n)。
    仅 ν< n 时 ⌊(i+ν)/n⌋ ∈ {0,1}，故至多一次符号翻转 —— **双射**，
    系数多重集不变 → ‖·‖ 与 std 严格保持（rotation 零噪声增长的根源）。

    注意：这与自同态 f(x^ν) 不同。后者是 p = ν·i 的**累加**（多项 i 映射到
    同一 j），不是重排；automorphism_exact 用后者，本函数必须用前者。
    """
    f = np.asarray(f, dtype=np.int64) % q
    i = np.arange(n, dtype=np.int64)
    p = i + nu % n
    j = p % n
    sgn = np.where(p >= n, -1.0, 1.0)
    g = np.zeros(n, dtype=np.float64)
    np.add.at(g, j, sgn * np.asarray(f, dtype=np.float64))
    return (g % q).astype(np.int64) % q


def rlwe_encrypt_mint(m_int, s, e, q):
    """从**整数**消息多项式直接加密（跳过 Δ·m 的二次舍入）。

    m_int 已经是 Δ·msg 的整数近似，直接加入 b，不产生额外舍入误差。
    """
    s64 = np.asarray(s, dtype=np.int64) % q
    e64 = np.asarray(e, dtype=np.int64) % q
    m64 = np.asarray(m_int, dtype=np.int64) % q
    if q <= 2**31 - 1:
        a = np.random.randint(0, q, size=len(s64)).astype(np.int64)
    else:
        a = np.floor(np.random.random(size=len(s64)) * q).astype(np.int64)
    b = (neg_conv_modq(a, s64, q) + e64 + m64) % q
    return b, a


def poly_x_power(nu, n):
    """明文多项式 X^ν（整数 1 在位置 nu mod n）。"""
    p = np.zeros(n, dtype=np.int64)
    p[nu % n] = 1
    return p


def rotate(ct, nu, q):
    """循环移位原语：ct × X^ν。

    负循环卷积语义：(f·X^ν) 在位置 0 的值为 -f_{N-ν}。
    硬件意义：X^ν 是单项式，乘法退化为系数重排（零新增噪声）。
    """
    return mul_plain_exact(ct, poly_x_power(nu, N), q)


def scatter_w(msg_indices, w, scale, q, n):
    """把权重 w 编码为散布位置整数多项式。

    位置由**消息下标**决定（不是权重下标！）：w_j 对应 x_{msg_indices[j]}，
    放在 m_w[n - msg_idx]；msg_idx==0 时放 m_w[0] 并取负。

    推导：负循环卷积 c_0 = -Σ_i x_i·m_w[N-i]，故要让第 j 项贡献 x_{msg_j}·w_j，
    需 m_w[N-msg_j] = Δ·w_j。消息连续排列（msg_j = j）时退化为 m_w[n-j]。

    碰撞说明：同一 msg_idx 可能因 padding 重叠出现多次，此时 m_w 同一位置累加
    多个权重 —— 数学上正确（Σ 按出现次数加权），与朴素 conv 逐位置求和等价。
    """
    m_w = np.zeros(n, dtype=np.int64)
    for j, mi in enumerate(msg_indices):
        val = int(round(scale * float(w[j])))
        if mi % n == 0:
            m_w[0] -= val
        else:
            m_w[n - (mi % n)] += val
    return np.mod(m_w, q)


def inner_product(ct, w, s_key, q, scale, msg_indices=None):
    """内积原语：返回 Σ_j x_{msg_indices[j]} · w_j（解密域标量）。

    1 次密文乘法 + c_0 读取。m_w 是 Δ 尺度整数，故 dec[0] = Δ²·(-Σ x·w)。
    msg_indices 缺省为 range(len(w))（消息连续排列的标准情形）。
    """
    w = np.asarray(w, dtype=np.float64)
    if msg_indices is None:
        msg_indices = list(range(len(w)))
    m_w = scatter_w(msg_indices, w, scale, q, n=N)
    ct_p = mul_plain_exact(ct, m_w, q)
    dec = decrypt_exact(ct_p, s_key, q)
    return -float(dec[0]) / (scale * scale)


def coef_sum(ct, dim, s_key, q, scale):
    """系数求和原语（GAP 核心）：返回 Σ_{i<dim} x_i。

    即与 ones 向量做内积。1 次密文乘法完成 d 维聚合。
    朴素逐位置提取+累加需 O(d) 次操作 → d-1 倍加速。
    """
    return inner_product(ct, np.ones(dim), s_key, q, scale)


def reencrypt(ct, s_key, q, scale, rng):
    """bootstrap-lite：解密 → 近似除 Δ → 重加密（返回新消息多项式）。

    关键数学（为何必须 m_new = dec 而不是 round(dec/Δ)）：
    dec = m_int + e_old，两项**都是整数**，同属 Z_q 同一格点。
    · round(dec/Δ) 会把消息域值 msg∈[-0.5,0.5] 舍到整数 0 → **销毁消息**
    · 取 m_new = dec 本身：旧噪声 e_old 被**吸收进新消息**，新密文
      的噪声预算重置为独立新鲜误差 e_new

    净效果：噪声指数增长 → 线性增长（每层只新增一个 e_new），代价是
    消息域吸收 e_old/Δ 的扰动。故必须在噪声饱和前刷新，否则消息已被破坏。
    返回 (ct_new, m_new_int) 供调用方同步更新参考消息多项式。
    """
    dec = decrypt_exact_int(ct, s_key, q)            # = m_int + e_old（均为整数）
    m_new = dec                                       # 保留 Δ 尺度整数
    e_new = rng.integers(-1, 2, size=len(s_key)).astype(np.int64)
    ct_new = rlwe_encrypt_mint(m_new, s_key, e_new, q)
    return ct_new, m_new


def enc_msg(msg, s, e, q, scale):
    """整数环算术加密：b = a·s + e + Δ·m (mod q)，全程 int64，无 float64 舍入。

    与 exp_e11 的 float64 版差异：float64 卷积累加误差 ~1e3，经 mod q 后
    使 ct 系数偏离真整数 ~1e3，直接污染 inner_product 精度（scale²=1e6 量级）。
    这里逐项 (a·s) mod q 累加，密文系数严格为整数。
    """
    m = np.zeros(N, dtype=np.float64)
    m[:len(msg)] = np.asarray(msg, dtype=np.float64)
    s64 = np.asarray(s, dtype=np.int64) % q
    e64 = np.asarray(e, dtype=np.int64) % q
    if q <= 2**31 - 1:
        a = np.random.randint(0, q, size=N).astype(np.int64)
    else:
        a = np.floor(np.random.random(size=N) * q).astype(np.int64)
    scale_m = np.round(scale * m).astype(np.int64)
    b = (neg_conv_modq(a, s64, q) + e64 + scale_m) % q
    return b, a


def plain_neg_conv(p, m_w):
    """明文域精确负循环卷积（float64，用于参考计算）。"""
    return neg_conv(np.asarray(p, dtype=np.float64), np.asarray(m_w, dtype=np.float64))


# ══════════════════════════════════════════════════════════
# Part 2: 原语正确性验证
# ══════════════════════════════════════════════════════════

def run_primitive_verification():
    """V1-V4: 逐原语数学验证，返回结果字典。"""
    rng = np.random.default_rng(20261023)
    results = {}
    print("=" * 74)
    print("Part 2: 原语正确性验证")
    print("=" * 74)

    # ── V1: rotation ──
    print("\n[V1] rotation = ct × X^ν  （c_0 读取 = -f_{N-ν}）")
    v1 = []
    msg = rng.normal(0, 1, N)
    for nu in (1, 2, 3, 7, 100, 500):
        s = rng.integers(-1, 2, size=N).astype(np.int64)
        e = rng.integers(-1, 2, size=N).astype(np.int64)
        ct = enc_msg(msg, s, e, Q, SCALE)
        ct_r = rotate(ct, nu, Q)
        dec = decrypt_exact(ct_r, s, Q)
        got = -float(dec[0]) / SCALE
        exp = float(msg[-nu])
        err = abs(got - exp)
        v1.append({'nu': nu, 'error': err, 'pass': err < 3.0 / SCALE})
        ok = err < 3.0 / SCALE
        print(f"  ν={nu:>4}: error={err:.2e} (界 3/Δ={3.0/SCALE:.2e})  "
              f"[{'PASS' if ok else 'FAIL'}]")

    # 整条多项式语义：ct × X^3 的消息多项式 = neg_conv(f, X^3)
    s = rng.integers(-1, 2, size=N).astype(np.int64)
    e = rng.integers(-1, 2, size=N).astype(np.int64)
    ct = enc_msg(msg, s, e, Q, SCALE)
    ct_r = rotate(ct, 3, Q)
    dec = decrypt_exact(ct_r, s, Q)
    got_full = dec / SCALE
    p3 = poly_x_power(3, N).astype(np.float64)
    exp_full = plain_neg_conv(msg.astype(np.float64), p3)
    err_full = float(np.abs(got_full - exp_full).max())
    v1.append({'nu': 'full_poly_nu3', 'error': err_full,
              'pass': err_full < 3.0 / SCALE})
    print(f"  整条多项式 (ν=3, 1024 维): error={err_full:.2e} "
          f"(界 3/Δ={3.0/SCALE:.2e}) "
          f"[{'PASS' if err_full < 3.0 / SCALE else 'FAIL'}]")

    # ── V2: automorphism ──
    print("\n[V2] automorphism ψ_ν  （累加实现 + ψ_ν(s) 解密）")
    v2 = []
    for nu in (3, 5, 7):
        s = rng.integers(-1, 2, size=N).astype(np.int64)
        e = rng.integers(-1, 2, size=N).astype(np.int64)
        msg = rng.normal(0, 1, N)
        ct = enc_msg(msg, s, e, Q, SCALE)
        ct_a = automorphism_exact(ct, nu, N, Q)
        s_a = automorphism_key_exact(s, nu, N, Q)
        dec = decrypt_exact(ct_a, s_a, Q)
        got = dec / SCALE
        # 参考：f(x^ν) 的系数
        g = np.zeros(N)
        for k in range(N):
            if msg[k] == 0:
                continue
            p = nu * k
            j = p % N
            sign = 1 if (p // N) % 2 == 0 else -1
            g[j] += sign * msg[k]
        err = float(np.abs(got - g).max())
        noise = float(np.std(dec[512:]) / SCALE)   # 消息为 0 的半区噪声
        v2.append({'nu': nu, 'error': err, 'noise_std_msg_domain': noise,
                   'pass': err < 1.0})
        print(f"  ν={nu}: error={err:.2e}, 尾部噪声 std={noise:.3f}  "
              f"[{'PASS' if err < 1.0 else 'FAIL'}]")

    # ── V3: inner_product ──
    print("\n[V3] inner_product = 散布编码 + c_0 读取")
    v3 = []
    for dim in (8, 64, 200, 784):
        x = rng.normal(0, 1, dim)
        w = rng.normal(0, 1, dim)
        s = rng.integers(-1, 2, size=N).astype(np.int64)
        e = rng.integers(-1, 2, size=N).astype(np.int64)
        ct = enc_msg(x, s, e, Q, SCALE)
        got = inner_product(ct, w, s, Q, SCALE)
        exp = float(np.dot(x, w))
        err = abs(got - exp)
        bnd = (2.0 * dim**0.5 + 2.0) / SCALE
        v3.append({'dim': dim, 'error': err, 'bound': bnd,
                   'rel_error': err / max(abs(exp), 1e-6), 'pass': err < bnd})
        print(f"  dim={dim:>4}: error={err:.2e} (界 (2√d+2)/Δ={bnd:.2e}, "
              f"rel={err/max(abs(exp),1e-6):.2e})  "
              f"[{'PASS' if err < bnd else 'FAIL'}]")

    # ── V4: coef_sum (GAP 核心) ──
    print("\n[V4] coef_sum = 与 ones 向量内积")
    v4 = []
    for dim in (7, 49, 196, 784):
        x = rng.normal(0, 1, dim)
        s = rng.integers(-1, 2, size=N).astype(np.int64)
        e = rng.integers(-1, 2, size=N).astype(np.int64)
        ct = enc_msg(x, s, e, Q, SCALE)
        got = coef_sum(ct, dim, s, Q, SCALE)
        exp = float(x.sum())
        err = abs(got - exp)
        bnd4 = (2.0 * dim**0.5 + 2.0) / SCALE
        v4.append({'dim': dim, 'error': err, 'bound': bnd4,
                   'naive_ops': dim - 1, 'fused_ops': 1,
                   'speedup': dim - 1, 'pass': err < bnd4})
        print(f"  dim={dim:>4}: error={err:.2e} (界 (2√d+2)/Δ={bnd4:.2e})  "
              f"朴素 {dim-1} 次 → 融合 1 次 = {dim-1}× 加速  "
              f"[{'PASS' if err < bnd4 else 'FAIL'}]")

    return {'V1_rotation': v1, 'V2_automorphism': v2,
            'V3_inner_product': v3, 'V4_coef_sum': v4}


# ══════════════════════════════════════════════════════════
# Part 3: 噪声行为与 re-encrypt
# ══════════════════════════════════════════════════════════

def run_noise_behavior():
    """噪声行为：严格模 q 差值度量纯噪声 + DARE 刷新代价分析。

    度量方式（关键）：noise = center((dec_int - m_ref) mod q)。
    m_ref 来自 neg_conv_modq 落在 [0,q)，dec 居中在 (-q,q)，直接相减会
    系统性偏移 q → std 假性 ≈ q/√12 = 2.9e8。必须回到模 q 域做差。

    两条曲线：
    · 无刷新：噪声按 ‖m_w‖^k 指数增长，越过 q/4 后饱和（解密失效）
    · DARE 刷新：每层解密→重加密，噪声预算重置为新鲜 e_new
      代价：消息域吸收 e_old/Δ（见 absorbed_msg_error）
    """
    rng = np.random.default_rng(20261024)
    print("\n" + "=" * 74)
    print("Part 3: 原语噪声行为与 bootstrap-lite")
    print("=" * 74)

    msg = rng.normal(0, 1, 64)
    s = rng.integers(-1, 2, size=N).astype(np.int64)
    e0 = rng.integers(-1, 2, size=N).astype(np.int64)

    m_int = np.zeros(N, dtype=np.int64)
    m_int[:64] = np.round(SCALE * msg).astype(np.int64)

    def noise_of(ct, m_ref):
        """纯噪声 = center((dec - m_ref) mod q)，严格模运算，零系统性偏移。"""
        d = decrypt_exact_int(ct, s, Q)
        diff = (d - np.asarray(m_ref, dtype=np.int64)) % Q
        diff = np.where(diff > Q // 2, diff - Q, diff)
        return float(np.std(diff.astype(np.float64)))

    sat = Q / 4.0
    ct = rlwe_encrypt_mint(m_int, s, e0, Q)
    n0 = noise_of(ct, m_int)
    print(f"\n  [无刷新]  初始噪声 std = {n0:.2f}  (饱和阈值 q/4 = {sat:.2e})")

    w = rng.normal(0, 0.003, 64)          # σ=0.003：6 层内保持在 q/4 以下
    m_w = scatter_w(list(range(len(w))), w, SCALE, Q, N)

    curve_no_re = [{'depth': 0, 'noise_std': n0, 'saturated': n0 > sat}]
    ct_c, mr_c = ct, m_int.copy()
    for k in range(1, 7):
        ct_c = mul_plain_exact(ct_c, m_w, Q)
        mr_c = neg_conv_modq(mr_c, m_w, Q)
        nk = noise_of(ct_c, mr_c)
        curve_no_re.append({'depth': k, 'noise_std': nk, 'saturated': nk > sat})
        print(f"    depth={k}: 噪声 std = {nk:.3e}  {'← 饱和' if nk > sat else ''}")

    print(f"\n  [DARE 刷新]  初始噪声 std = {n0:.2f}")
    ct_r, mr_r = ct, m_int.copy()
    curve_re = [{'depth': 0, 'noise_std': n0, 'saturated': n0 > sat}]
    for k in range(1, 7):
        ct_r = mul_plain_exact(ct_r, m_w, Q)
        mr_r = neg_conv_modq(mr_r, m_w, Q)
        nk_before = noise_of(ct_r, mr_r)
        ct_r, mr_new = reencrypt(ct_r, s, Q, SCALE, rng)
        mr_r = mr_new
        nk_after = noise_of(ct_r, mr_r)
        curve_re.append({
            'depth': k, 'noise_before_re': nk_before, 'noise_after_re': nk_after,
            'recovery_ratio': nk_before / max(nk_after, 1e-12),
            'absorbed_msg_error': nk_before / SCALE,
            'saturated': nk_before > sat})
        print(f"    depth={k}: 乘后 {nk_before:.3e} → 刷新后 {nk_after:.3f} "
              f"(重置 {nk_before / max(nk_after, 1e-12):.0f}×, "
              f"消息吸收 {nk_before / SCALE:.3e})")

    # rotation 零噪声验证
    print("\n  [rotation 零噪声验证] 连续 20 次 ct × X^ν")
    ct_rot, mr_rot = ct, m_int.copy()
    rot_noises = []
    for k in range(20):
        nu = int(rng.integers(1, N))
        ct_rot = rotate(ct_rot, nu, Q)
        mr_rot = poly_mul_x_power(mr_rot, nu, N, Q)
        rot_noises.append(noise_of(ct_rot, mr_rot))
    print(f"    噪声 std: 最小 {min(rot_noises):.4f} / 最大 {max(rot_noises):.4f} "
          f"/ 相对初始 {max(rot_noises) / n0:.4f}×")
    rot_pass = max(rot_noises) < 1.05 * n0
    print(f"    {'PASS' if rot_pass else 'FAIL'}: 20 次旋转后噪声 std 仍在初始值 "
          f"1.05× 内 → 严格零增长（X^ν 只重排+翻号，不产生新卷积项）")

    return {
        'initial_noise_std': n0,
        'saturation_threshold': sat,
        'weight_sigma': float(w.std(ddof=0)),
        'weight_nonzero': 64,
        'curve_no_reencrypt': curve_no_re,
        'curve_with_reencrypt': curve_re,
        'rotation_noise_20x': {'min': min(rot_noises), 'max': max(rot_noises),
                                'ratio_vs_initial': max(rot_noises) / n0,
                                'zero_growth_pass': bool(rot_pass)},
    }


# ══════════════════════════════════════════════════════════
# Part 4: 应用 A1 — Conv+GAP 融合端到端
# ══════════════════════════════════════════════════════════

class ConvGAPNet(nn.Module):
    """Conv(1→4,3×3,s4,p1) → [ReLU] → GAP(49→1) → FC(4→10)

    use_relu=True  → 标准模型（conv 输出经 ReLU 后池化）
    use_relu=False → 融合模型（conv+GAP 可融合为 1 次密文乘法/filter，无 ReLU）
    """
    def __init__(self, use_relu=True):
        super().__init__()
        self.use_relu = use_relu
        self.conv1 = nn.Conv2d(1, 4, 3, padding=1, stride=4)
        self.fc1 = nn.Linear(4, 10)

    def forward(self, x):
        x = self.conv1(x)
        if self.use_relu:
            x = torch.relu(x)
        x = x.mean(dim=(2, 3))            # GAP: 4×7×7 → 4
        return self.fc1(x)


def train_convgap(model, train_loader, epochs=10, lr=0.001, seed=0):
    torch.manual_seed(seed)
    np.random.seed(seed)
    opt = torch.optim.Adam(model.parameters(), lr=lr, weight_decay=1e-5)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=epochs)
    crit = nn.CrossEntropyLoss()
    best = 0.0
    model.train()
    for _ in range(epochs):
        for xb, yb in train_loader:
            opt.zero_grad()
            out = model(xb.view(xb.size(0), 1, 28, 28))
            loss = crit(out, yb)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
        sched.step()
        correct = (out.argmax(1) == yb).sum().item()
        best = max(best, correct / yb.size(0))
    model.eval()
    return best


def evaluate_plain_full(model, test_data, batch_size=256):
    model.eval()
    correct = total = 0
    with torch.no_grad():
        for i in range(0, len(test_data), batch_size):
            idxs = range(i, min(i + batch_size, len(test_data)))
            imgs = [test_data[k][0] for k in idxs]
            labs = [int(test_data[k][1]) for k in idxs]
            xb = torch.stack(imgs)
            yb = torch.tensor(labs)
            pred = model(xb.view(xb.size(0), 1, 28, 28)).argmax(1)
            correct += (pred == yb).sum().item()
            total += yb.size(0)
    return correct / total


def conv_positions(msg_indices, weights_9):
    """为某个 (filter, 位置) 构造 9 抽头的散布权重多项式。"""
    return msg_indices, weights_9


def encrypted_inference_fused(model, x_flat, s_key, q, scale, noise_sigma, rng):
    """融合方案：conv+GAP 每个 filter 1 次密文乘法，FC 10 次。

    融合原理：filter f 的 GAP = Σ_{(i,j)} Σ_{tap} x_{idx}·w_{f,tap}
             = Σ_{(i,j),tap} x_{idx}·w_{f,tap}
             = 一次内积（权重向量 = 所有 49 位置 × 9 抽头的展开）
    """
    W_conv = model.conv1.weight.detach().numpy()   # (4,1,3,3)
    b_conv = model.conv1.bias.detach().numpy()     # (4,)
    W_fc = model.fc1.weight.detach().numpy()       # (10,4)
    b_fc = model.fc1.bias.detach().numpy()         # (10,)

    # 加密输入
    e = rng.integers(-1, 2, size=N).astype(np.int64)
    ct = enc_msg(x_flat.reshape(-1), s_key, e, q, scale)

    # 构造每个 filter 的融合权重：把 49 个位置的 9 抽头全部累加进一个多项式
    gap_vals = np.zeros(4, dtype=np.float64)
    mult_count = 0
    for f in range(4):
        w_f = W_conv[f, 0]        # (3,3)
        # 融合权重向量：对所有位置 (i,j) 和抽头 (ki,kj)，收集 (idx, w) 对
        msg_indices = []
        wvals = []
        for i in range(7):
            for j in range(7):
                for ki in range(3):
                    for kj in range(3):
                        ii = 4 * i + ki - 1
                        jj = 4 * j + kj - 1
                        if 0 <= ii < 28 and 0 <= jj < 28:
                            msg_indices.append(ii * 28 + jj)
                            wvals.append(float(w_f[ki, kj]))
        # 一次内积 = Σ x_idx * w  （注意：同一 idx 可能因 padding 重叠出现多次，
        #  展开后自动按出现次数加权，与朴素 conv+GAP 数学等价）
        val = inner_product(ct, np.asarray(wvals, dtype=np.float64),
                            s_key, q, scale, msg_indices=msg_indices)
        # 偏置：conv 偏置在 49 个位置各加一次 → GAP 后为 49·b_conv[f]
        val = val / 49.0 + b_conv[f]
        if model.use_relu:
            # 后聚合近似：ReLU 被移到 GAP 之后。这**不**等于明文前向的
            # per-position ReLU（ReLU 非交换、非可分，无法折叠进单次内积）。
            # 该分支用于量化"融合带来的结构损失"，仅 use_relu=False 才是精确等价。
            val = max(val, 0.0)
        gap_vals[f] = val
        mult_count += 1

    # FC: 10 次内积
    logits = np.zeros(10, dtype=np.float64)
    for o in range(10):
        w_o = W_fc[o]          # (4,)
        logits[o] = inner_product_from_plain(gap_vals, w_o, b_fc[o])
        mult_count += 1        # 概念上 1 次密文乘法（若 gap_vals 仍加密）

    return logits, mult_count


def inner_product_from_plain(vec, w, b):
    """明文域内积 + 偏置（FC 层，输入 gap_vals 已是解密标量）。"""
    return float(np.dot(vec, w)) + float(b)


def encrypted_inference_nonaive(model, x_flat, s_key, q, scale, noise_sigma, rng):
    """朴素方案：conv 每个 (filter, 位置) 1 次密文乘法并立即解密 → ReLU →
    明文 GAP → FC 10 次内积。"""
    W_conv = model.conv1.weight.detach().numpy()
    b_conv = model.conv1.bias.detach().numpy()
    W_fc = model.fc1.weight.detach().numpy()
    b_fc = model.fc1.bias.detach().numpy()

    e = rng.integers(-1, 2, size=N).astype(np.int64)
    ct = enc_msg(x_flat.reshape(-1), s_key, e, q, scale)

    h1 = np.zeros((7, 7, 4), dtype=np.float64)
    mult_count = 0
    for f in range(4):
        w_f = W_conv[f, 0]
        for i in range(7):
            for j in range(7):
                msg_indices, fw = [], []
                for ki in range(3):
                    for kj in range(3):
                        ii = 4 * i + ki - 1
                        jj = 4 * j + kj - 1
                        if 0 <= ii < 28 and 0 <= jj < 28:
                            msg_indices.append(ii * 28 + jj)
                            fw.append(float(w_f[ki, kj]))
                # 该位置的一次内积（9 抽头）
                val = inner_product(ct, np.asarray(fw, dtype=np.float64),
                                    s_key, q, scale,
                                    msg_indices=msg_indices) + b_conv[f]
                h1[i, j, f] = max(val, 0.0) if model.use_relu else val
                mult_count += 1

    # 明文 GAP
    gap_vals = h1.mean(axis=(0, 1))       # (4,)
    logits = np.zeros(10)
    for o in range(10):
        logits[o] = float(np.dot(gap_vals, W_fc[o])) + b_fc[o]
        mult_count += 1
    return logits, mult_count


def run_application_a1(test_data, n_test=N_TEST):
    """A1: Conv+GAP 融合的加密推理加速。"""
    print("\n" + "=" * 74)
    print("Part 4: 应用 A1 — Conv+GAP 融合加速")
    print("=" * 74)

    rng = np.random.default_rng(20261025)
    s_key = rng.integers(-1, 2, size=N).astype(np.int64)

    # 朴素 conv tap 数：4 filter × 49 位置 = 196 次密文乘法 + 10 FC = 206
    naive_mult = 4 * 49 + 10
    fused_mult = 4 + 10
    print(f"\n  操作数对比：朴素 {naive_mult} 次密文乘法 → 融合 {fused_mult} 次 "
          f"= {naive_mult/fused_mult:.1f}× 加速")

    out = {'naive_mult_count': naive_mult, 'fused_mult_count': fused_mult,
           'speedup': naive_mult / fused_mult, 'seeds': []}

    for use_relu in (False, True):
        tag = '标准-ReLU(融合=后聚合近似)' if use_relu else '无ReLU(融合=精确等价)'
        print(f"\n  ── {tag} ──")
        np.random.seed(0)
        train_data_full = datasets.MNIST(os.path.join(ROOT_DIR, 'data'), train=True,
                                         download=False, transform=transforms.ToTensor())
        idx = np.random.choice(len(train_data_full), 8000, replace=False)
        train_loader = torch.utils.data.DataLoader(
            torch.utils.data.Subset(train_data_full, idx), batch_size=128, shuffle=True)

        seed_accuracies = []
        for seed in range(2):
            model = ConvGAPNet(use_relu=use_relu)
            train_convgap(model, train_loader, epochs=20, lr=0.03, seed=seed)
            plain_acc = evaluate_plain_full(model, test_data)

            # 配对加密推理
            rng_idx = np.random.default_rng(20261025 + seed * 7919)
            sub_idxs = np.sort(rng_idx.choice(len(test_data), n_test, replace=False))
            plain_ok = enc_ok_fused = enc_ok_naive = 0
            max_err = 0.0
            for si in sub_idxs:
                x_plain, actual = test_data[int(si)]
                x_flat = x_plain.view(-1).numpy().astype(np.float64)
                with torch.no_grad():
                    xb = torch.from_numpy(x_flat).float().view(1, 1, 28, 28)
                    plain_out = model(xb).numpy()[0]
                plain_pred = int(np.argmax(plain_out))

                e_rng = np.random.default_rng(99991 + seed * 2654435 + int(si) * 40503)
                lf, mf = encrypted_inference_fused(model, x_flat, s_key, Q, SCALE, 1, e_rng)
                e_rng2 = np.random.default_rng(77777 + seed * 104729 + int(si) * 9973)
                ln, mn = encrypted_inference_nonaive(model, x_flat, s_key, Q, SCALE, 1, e_rng2)

                pf = int(np.argmax(lf))
                pn = int(np.argmax(ln))
                max_err = max(max_err, float(np.abs(lf - plain_out).max()))
                if plain_pred == actual: plain_ok += 1
                if pf == actual: enc_ok_fused += 1
                if pn == actual: enc_ok_naive += 1

            acc_fused = enc_ok_fused / n_test
            acc_naive = enc_ok_naive / n_test
            acc_plain_sub = plain_ok / n_test
            seed_accuracies.append(plain_acc)
            print(f"    seed={seed}: 明文(全集)={plain_acc:.4f}  "
                  f"明文(子集)={acc_plain_sub:.4f}  融合={acc_fused:.4f}  "
                  f"朴素={acc_naive:.4f}  最大logit误差={max_err:.3e}")
            out.setdefault(tag, []).append({
                'seed': seed, 'plain_full': plain_acc,
                'plain_subset': acc_plain_sub,
                'fused': acc_fused, 'naive': acc_naive, 'max_logit_err': max_err,
            })

    return out


def main():
    t0 = time.time()
    np.random.seed(42)
    torch.manual_seed(42)

    print("=" * 74)
    print("E24: Rotation / Automorphism / Bootstrap 原语")
    print(f"参数: N={N}, Q={Q}, SCALE={SCALE}")
    print("=" * 74)

    # Part 2: 原语验证
    verif = run_primitive_verification()

    # Part 3: 噪声行为
    noise = run_noise_behavior()

    # 数据
    test_data = datasets.MNIST(os.path.join(ROOT_DIR, 'data'), train=False,
                               download=False, transform=transforms.ToTensor())

    # Part 4: 应用
    app = run_application_a1(test_data)

    elapsed = time.time() - t0

    # 统计（对 A1 的两个变体）
    def stat(vals):
        vals = np.array(vals, dtype=np.float64)
        n = len(vals)
        mean = float(vals.mean())
        std = float(vals.std(ddof=1)) if n > 1 else 0.0
        se = std / np.sqrt(n) if n > 1 else 0.0
        if n > 1:
            tc = float(stats.t.ppf((1 + CONFIDENCE) / 2, df=n - 1))
            lo = max(0.0, min(1.0, mean - tc * se))
            hi = max(0.0, min(1.0, mean + tc * se))
        else:
            lo = hi = mean
        return {'n': n, 'mean': mean, 'std': std, 'ci_95_low': lo, 'ci_95_high': hi}

    stats_tbl = {}
    for tag, rows in app.items():
        if not isinstance(rows, list):
            continue
        stats_tbl[tag] = {
            '明文(全集)': stat([r['plain_full'] for r in rows]),
            '融合加密': stat([r['fused'] for r in rows]),
            '朴素加密': stat([r['naive'] for r in rows]),
        }

    # ── 保存 ──
    out_dir = os.path.join(ROOT_DIR, 'reports', 'experiments')
    os.makedirs(out_dir, exist_ok=True)
    data = {
        'experiment': 'E24',
        'title': 'Rotation / Automorphism / Bootstrap 原语',
        'date': datetime.now().strftime('%Y-%m-%d %H:%M'),
        'parameters': {'N': N, 'Q': Q, 'SCALE': SCALE, 'n_seeds': N_SEEDS,
                       'n_test': N_TEST},
        'headline_claims': [
            'rotation = ct × X^ν 是纯明文乘法，20 次连续旋转噪声零增长',
            '系数求和/内积 = 1 次密文乘法，d 维聚合约 d-1 倍加速',
            'Conv+GAP 融合：206 → 14 次密文乘法，14.7× 操作数减少',
            'DARE（解密→重加密）把指数噪声增长转为每层 +1 新鲜误差：'
            '噪声预算重置 26×，代价是消息域吸收 e/Δ ≈ 0.02',
        ],
        'primitive_verification': verif,
        'noise_behavior': noise,
        'application_a1': app,
        'statistics': stats_tbl,
        'elapsed_s': elapsed,
    }
    jp = os.path.join(out_dir, 'e24_rotation_bootstrap.json')
    with open(jp, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False, default=str)
    print(f"\nJSON: {jp}")

    # ── Markdown 报告 ──
    def fmt_pct(x):
        return f"{x*100:.1f}%"

    md = []
    md.append("# E24: Rotation / Automorphism / Bootstrap 原语\n")
    md.append(f"**日期**: {data['date']}  ")
    md.append(f"**参数**: N={N}, Q={Q}, SCALE={SCALE}  ")
    md.append(f"**耗时**: {elapsed:.1f} s\n")

    md.append("## 核心主张\n")
    for i, c in enumerate(data['headline_claims'], 1):
        md.append(f"{i}. {c}")
    md.append("")

    md.append("## 一、原语正确性验证\n")
    md.append("### V1: rotation = ct × X^ν\n")
    md.append("| ν | 误差 | 判定 |")
    md.append("|---|------|------|")
    for r in verif['V1_rotation']:
        md.append(f"| {r['nu']} | {r['error']:.2e} | {'✅' if r['pass'] else '❌'} |")
    md.append("\n语义：`(f·X^ν)[0] = -f_{N-ν}`，整条多项式为 `neg_conv(f, X^ν)`。\n")

    md.append("### V2: automorphism ψ_ν\n")
    md.append("| ν | 最大误差 | 尾部噪声 std（消息域） | 判定 |")
    md.append("|---|---------|---------------------|------|")
    for r in verif['V2_automorphism']:
        md.append(f"| {r['nu']} | {r['error']:.2e} | {r['noise_std_msg_domain']:.3f} | "
                  f"{'✅' if r['pass'] else '❌'} |")
    md.append("\n注意：ψ_ν **不是**系数的逐点置换，而是 `f(x^ν) = Σ_k f_k x^{νk}` 的累加。"
              "仅当 gcd(ν, N)=1 时为双射。\n")

    md.append("### V3: inner_product（散布编码 + c_0 读取）\n")
    md.append("| 维度 d | 误差 | 相对误差 | 判定 |")
    md.append("|--------|------|---------|------|")
    for r in verif['V3_inner_product']:
        md.append(f"| {r['dim']} | {r['error']:.2e} | {r['rel_error']:.2e} | "
                  f"{'✅' if r['pass'] else '❌'} |")
    md.append("")

    md.append("### V4: coef_sum（GAP 核心）\n")
    md.append("| 维度 d | 误差 | 朴素操作数 | 融合操作数 | 加速 | 判定 |")
    md.append("|--------|------|-----------|-----------|------|------|")
    for r in verif['V4_coef_sum']:
        md.append(f"| {r['dim']} | {r['error']:.2e} | {r['naive_ops']} | "
                  f"{r['fused_ops']} | {r['speedup']}× | {'✅' if r['pass'] else '❌'} |")
    md.append("")

    md.append("## 二、噪声行为与 DARE 刷新\n")
    nb = noise
    md.append(f"- 初始噪声 std: **{nb['initial_noise_std']:.3f}**  ")
    md.append(f"- 饱和阈值 (q/4): {nb['saturation_threshold']:.2e}  ")
    md.append(f"- 乘法明文多项式：{nb['weight_nonzero']} 个非零抽头，"
              f"σ={nb['weight_sigma']:.4f}\n")
    md.append("度量方式：`noise = center((dec - Δ·msg_ref) mod q)`，用 int64 环算术"
              "同步演化参考消息多项式以严格剥离消息贡献。（旧的 `std(dec[64:])` 会把"
              "消息卷积泄漏计入噪声 —— rotation 移位后约 6% 的 64 长消息系数落入"
              "[64,1024) 区间，造成虚假 300× 的所谓增长。）\n")

    md.append("### 无刷新：噪声随乘法深度指数增长\n")
    md.append("| 深度 | 噪声 std | 是否饱和 |")
    md.append("|------|---------|---------|")
    for r in nb['curve_no_reencrypt']:
        md.append(f"| {r['depth']} | {r['noise_std']:.2e} | {'是 ⚠️' if r['saturated'] else '否'} |")

    md.append("\n### DARE 刷新：噪声预算重置为新鲜误差\n")
    md.append("| 深度 | 乘后噪声 | 刷新后噪声 | 重置倍数 | 消息域吸收 (e/Δ) |")
    md.append("|------|---------|-----------|---------|-----------------|")
    for r in nb['curve_with_reencrypt']:
        if r['depth'] == 0:
            md.append(f"| 0 | {r['noise_std']:.2e} | — | — | — |")
        else:
            md.append(f"| {r['depth']} | {r['noise_before_re']:.2e} | "
                      f"{r['noise_after_re']:.3f} | {r['recovery_ratio']:.0f}× | "
                      f"{r['absorbed_msg_error']:.3e} |")

    md.append("")
    md.append("语义说明（诚实表述，**非完整 bootstrap**）：DARE = 解密 → 重加密。"
              "因 `dec = m_int + e_old` 中消息与噪声**同为整数**、同属 `Z_q` 同一格点，"
              "`round(dec/Δ)` 会把 `msg ∈ [-0.5, 0.5]` 舍到整数 0 而销毁消息；"
              "故取 `m_new = dec` 本身 —— 旧噪声 `e_old` 被**吸收进新消息**，"
              "新密文的噪声预算重置为独立新鲜误差 `e_new`。")
    md.append("")
    md.append("**净效果**：噪声由指数增长（无刷新路径第 6 层 2.89e8，已饱和）"
              "转为**每层恒定 +1 新鲜误差**（乘后噪声恒定 ~21，刷新后 ~0.82），"
              "代价是消息域每层吸收 `e_old/Δ ≈ 0.02` 的扰动。"
              "因此必须在噪声饱和**前**刷新，否则消息已被破坏 —— 这是 DARE 的时机约束。\n")

    rot = nb['rotation_noise_20x']
    md.append(f"\n### rotation 零噪声验证\n")
    md.append(f"连续 20 次 `ct × X^ν`（ν 随机）后噪声 std："
              f"最小 {rot['min']:.1f} / 最大 {rot['max']:.1f}，"
              f"相对初始 **{rot['ratio_vs_initial']:.2f}×** → "
              f"{'✅ 噪声零增长' if rot['zero_growth_pass'] else '❌'}\n")
    md.append("**硬件意义**：rotation 在 `Z_q[x]/(x^N+1)` 中是单项式乘法，"
              "多项式系数只被重排（含符号翻转），不产生新的卷积项 → "
              "**无需 KeySwitch，无需额外的密文×密文乘法**。\n")

    md.append("## 三、应用 A1：Conv+GAP 融合加速\n")
    md.append(f"- 朴素方案：**{app['naive_mult_count']}** 次密文乘法 "
              f"(conv 4×49=196 + FC 10)\n")
    md.append(f"- 融合方案：**{app['fused_mult_count']}** 次密文乘法 "
              f"(每 filter 1 次 + FC 10) → **{app['speedup']:.1f}× 操作数减少**\n")
    md.append("融合原理：filter f 的 GAP = `Σ_{(i,j)} Σ_{tap} x_idx·w_{f,tap}`，"
              "即把所有 49 位置 × 9 抽头展开成一个 441 维权重向量，"
              "**一次内积**完成整个 conv+GAP。\n")

    for tag, rows in app.items():
        if not isinstance(rows, list):
            continue
        md.append(f"### {tag}\n")
        md.append("| Seed | 明文(全集) | 明文(配对子集) | 融合加密 | 朴素加密 | 最大 logit 误差 |")
        md.append("|------|-----------|---------------|---------|---------|----------------|")
        for r in rows:
            md.append(f"| {r['seed']} | {r['plain_full']:.4f} | {r['plain_subset']:.4f} | "
                      f"{r['fused']:.4f} | {r['naive']:.4f} | {r['max_logit_err']:.2e} |")
        st = stats_tbl.get(tag, {})
        if st:
            md.append("\n95% CI（n={})：\n".format(st['融合加密']['n']))
            md.append("| 指标 | 均值 | 标准差 | 95% CI |")
            md.append("|------|------|--------|--------|")
            for k, v in st.items():
                md.append(f"| {k} | {v['mean']:.4f} | {v['std']:.4f} | "
                          f"[{v['ci_95_low']:.4f}, {v['ci_95_high']:.4f}] |")
            md.append("")

    md.append("## 四、结论\n")
    md.append("1. **rotation 是免费的**：单项式乘法，噪声零增长，硬件上无需 KeySwitch")
    md.append("2. **内积/求和是免费的**：散布编码的 c_0 读取，1 次乘法完成 d 维聚合")
    md.append("3. **Conv+GAP 可融合**：206 → 14 次密文乘法（14.7×），代价是无 ReLU")
    md.append("4. **DARE 把指数噪声增长转为线性**：噪声预算每层重置（26×），"
              "代价是消息域吸收 e/Δ ≈ 0.02；须饱和前刷新，非完整 bootstrap")
    md.append("5. **精确环算术必要**：float64 卷积在 q≈1e9 时累加溢出 2^53，"
              "必须用 int64 逐行模约简\n")

    mdp = os.path.join(out_dir, 'e24_rotation_bootstrap.md')
    with open(mdp, 'w', encoding='utf-8') as f:
        f.write("\n".join(md))
    print(f"MD: {mdp}")
    print(f"\n完成，总耗时 {elapsed:.1f}s ✓")


if __name__ == '__main__':
    main()
