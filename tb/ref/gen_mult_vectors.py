"""
gen_mult_vectors.py  —  生成 43x43 乘法器参考向量

生成 3 个文件：
  a_input.mem  : 43-bit 输入 A（每行 $readmemh 格式，8 hex 位/字）
  b_input.mem  : 43-bit 输入 B
  p_ref.mem    : 86-bit 参考输出（$readmemh 支持 17 hex 位/字）

用法：
    python gen_mult_vectors.py --count 1000 --seed 20261003

CKKS 场景提示：
  实际使用时 A、B 是 CKKS 系数，取值范围 [0, q-1]，其中 q = 2^43。
  随机向量已覆盖全范围，可作为通用参考。
"""

import argparse
import random
import os


def fmt43(v: int) -> str:
    """43-bit 无符号整数 → 11 hex 位字符串"""
    return f"{v:011x}"


def fmt86(v: int) -> str:
    """86-bit 无符号整数 → 22 hex 位字符串"""
    return f"{v:022x}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=20261003)
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()

    random.seed(args.seed)

    # 边界值（必须包含）
    boundary = [
        (0, 0),
        (0, 1),
        (1, 1),
        (1, 2**43 - 1),
        (2**43 - 1, 1),
        (2**43 - 1, 2**43 - 1),
        (1, 2**22),        # 2^22 附近
        (2**22, 2**22),    # 分解边界
        (2**23, 2**23),
        (2**43 - 2, 2**43 - 2),
    ]

    # 随机值
    randoms = [(random.getrandbits(43), random.getrandbits(43))
               for _ in range(args.count - len(boundary))]

    all_pairs = boundary + randoms

    # 写文件（$readmemh 格式：每行一个 hex 字）
    with open(os.path.join(args.outdir, "a_input.mem"), "w") as fa, \
         open(os.path.join(args.outdir, "b_input.mem"), "w") as fb, \
         open(os.path.join(args.outdir, "p_ref.mem"),   "w") as fp:

        for a, b in all_pairs:
            fa.write(fmt43(a) + "\n")
            fb.write(fmt43(b) + "\n")
            p = (a * b) & ((1 << 86) - 1)
            fp.write(fmt86(p) + "\n")

    print(f"Generated {len(all_pairs)} vectors to {args.outdir}")
    print(f"  a_input.mem, b_input.mem, p_ref.mem")


if __name__ == "__main__":
    main()
