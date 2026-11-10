"""gen_ntt_vectors.py - 密推芯 M1 Phase 2c：NTT/INTT 批量测试向量准备

功能：
  1. 读入 tb/ref/ref/ 下 gen_ntt_reference.py 生成的 10 组十进制向量
  2. 汇总为 3 个 hex 文件（供 testbench $readmemh 使用）：
       tb/ref/ntt_in_all.hex    : 10 组输入（160 行）
       tb/ref/ntt_out_all.hex   : 10 组期望 NTT 结果（160 行）
       tb/ref/intt_out_all.hex  : 10 组期望 INTT 往返结果（160 行，= 原始输入）
  3. 打印 testbench 需要的 omega / omega_inv 因子表与 N^-1

hex 文件按向量序号 v、系数序号 i 的 row-major 顺序排列：
  第 v*16 + i 行为 向量 v 的第 i 个系数

用法：
  python scripts/gen_ntt_vectors.py
"""
import os
import sys

BASE = str(Path(__file__).resolve().parents[1])
SRC_DIR = os.path.join(BASE, "tb", "ref", "ref")
DST_DIR = os.path.join(BASE, "tb", "ref")

LOG_N = 4
N = 1 << LOG_N
Q = 113
NUM_VECTORS = 10


def read_vecs(prefix):
    """读入 NUM_VECTORS 组向量，返回 list[list[int]]"""
    out = []
    for v in range(NUM_VECTORS):
        path = os.path.join(SRC_DIR, f"{prefix}_{v}.mem")
        with open(path) as f:
            out.append([int(l) for l in f if l.strip()])
    assert len(out) == NUM_VECTORS
    for vec in out:
        assert len(vec) == N, f"向量长度错误: {len(vec)} != {N}"
    return out


def write_hex(vecs, path):
    """写 row-major 十六进制文件（$readmemh 语义）

    注意：必须写十六进制，不是十进制！
      $readmemh 把每行按 16 进制解析，若写成十进制字符串，
      十进制 71 会被当作 0x71 = 113（>= q，非法域元素），
      十进制 104 会被当作 0x104 = 260 并被 7-bit 截断成 4。
    写入后立刻回读模拟 $readmemh 解析，做往返自检。
    """
    with open(path, "w") as f:
        for vec in vecs:
            for c in vec:
                assert 0 <= c < Q, f"系数越界: {c}"
                f.write(f"{c:02x}\n")

    # 回读自检：按 $readmemh 语义（16 进制）解析，必须与源值一致
    with open(path) as f:
        back = [int(l, 16) for l in f if l.strip()]
    flat = [c for vec in vecs for c in vec]
    assert back == flat, f"回读自检失败: {path}"

    n = len(flat)
    print(f"  写入 {path}  ({n} 行, 十六进制, 回读自检 OK)")


def main():
    if not os.path.isdir(SRC_DIR):
        print(f"ERROR: 源向量目录不存在: {SRC_DIR}")
        print("       请先运行 tb/ref/gen_ntt_reference.py")
        sys.exit(1)

    print("=" * 60)
    print("密推芯 M1 Phase 2c - 测试向量准备")
    print(f"N={N}, LOG_N={LOG_N}, q={Q}, vectors={NUM_VECTORS}")
    print("=" * 60)

    inputs = read_vecs("ntt_input")
    ntt_outs = read_vecs("ntt_output")
    intt_outs = read_vecs("intt_output")

    # 交叉校验：INTT 往返必须等于原始输入
    for v in range(NUM_VECTORS):
        assert inputs[v] == intt_outs[v], f"向量 {v} INTT 往返不一致（源数据问题）"
    print(f"\n[OK] 源数据校验通过：{NUM_VECTORS} 组 INTT 往返 == 原始输入")

    write_hex(inputs, os.path.join(DST_DIR, "ntt_in_all.hex"))
    write_hex(ntt_outs, os.path.join(DST_DIR, "ntt_out_all.hex"))
    write_hex(intt_outs, os.path.join(DST_DIR, "intt_out_all.hex"))

    # omega / omega_inv 因子表
    g = 3
    omega = pow(g, (Q - 1) // N, Q)
    omega_inv = pow(omega, -1, Q)
    n_inv = pow(N, -1, Q)
    assert pow(omega, N, Q) == 1
    assert pow(omega_inv, N, Q) == 1
    assert omega * omega_inv % Q == 1

    t_omega = [pow(omega, k, Q) for k in range(N // 2)]
    t_omega_inv = [pow(omega_inv, k, Q) for k in range(N // 2)]

    print("\n" + "=" * 60)
    print("testbench 所需常量")
    print("=" * 60)
    print(f"  Q_VALUE  = {Q}")
    print(f"  N_INV    = {n_inv}   (N^-1 mod q, 用于 INTT 输出缩放)")
    print(f"  omega    = {omega}   (test=40)")
    print(f"  omega_inv= {omega_inv}   (test=65)")
    print(f"  omega_table     = {t_omega}")
    print(f"  omega_inv_table = {t_omega_inv}")

    # 供 testbench 直接粘贴的 SV 初始化语句
    print("\n  // --- omega_table (NTT) ---")
    for k, val in enumerate(t_omega):
        print(f"  omega_table[{k}] = 7'd{val};")
    print("  // --- omega_inv_table (INTT) ---")
    for k, val in enumerate(t_omega_inv):
        print(f"  omega_inv_table[{k}] = 7'd{val};")

    print("\n[OK] 完成")


if __name__ == "__main__":
    main()
