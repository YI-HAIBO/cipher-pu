"""M3-b Rescale 玩具配置 testbench 向量生成器。

玩具配置：N=16, Q_IN=113, Q_OUT=97
生成 10 组随机向量，每组 16 系数
输出：
    tb/ref/tb_rescale_vec_s.hex  (s_data 输入)
    tb/ref/tb_rescale_vec_e.hex  (期望输出)
"""

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REF_DIR = ROOT / "tb" / "ref"

N = 16
Q_IN = 113
Q_OUT = 97
NUM_TESTS = 10
Q_WIDTH = 7
SCALE_BITS = 6  # log2(64) for toy rescale

REF_DIR.mkdir(parents=True, exist_ok=True)


def rescale(s, q_in, q_out, scale_bits):
    """玩具 Rescale：s' = round(s * q_out / q_in / 2^scale_bits) mod q_out"""
    scale = 1 << scale_bits
    # 近似公式：s' = (s * q_out + q_in/2) / (q_in * scale) mod q_out
    val = (s * q_out + q_in // 2) // (q_in * scale)
    return val % q_out


def main():
    print(f"生成 Rescale testbench 向量：N={N}, Q_IN={Q_IN}, Q_OUT={Q_OUT}")
    print(f"SCALE_BITS={SCALE_BITS}, NUM_TESTS={NUM_TESTS}")

    rng = random.Random(42)
    in_vec = []
    exp_vec = []

    for t in range(NUM_TESTS):
        for i in range(N):
            s = rng.randrange(Q_IN)
            e = rescale(s, Q_IN, Q_OUT, SCALE_BITS)
            in_vec.append(s)
            exp_vec.append(e)

    # 写入 hex 文件
    in_file = REF_DIR / "tb_rescale_vec_s.hex"
    exp_file = REF_DIR / "tb_rescale_vec_e.hex"

    with open(in_file, "w") as f:
        for v in in_vec:
            f.write(f"{v:0{Q_WIDTH}x}\n")

    with open(exp_file, "w") as f:
        for v in exp_vec:
            f.write(f"{v:0{Q_WIDTH}x}\n")

    print(f"写入：{in_file.name} ({len(in_vec)} 项)")
    print(f"写入：{exp_file.name} ({len(exp_vec)} 项)")

    # 打印前几项验证
    print("\n前 8 项验证：")
    print(f"{'s':>4} -> {'s\\':>4}  (期望)")
    for i in range(8):
        print(f"{in_vec[i]:>4} -> {exp_vec[i]:>4}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
