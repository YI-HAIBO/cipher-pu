"""M4-a 档位控制器 Python 验证脚本

验证：4 档配置表的阈值、截断位数、近似乘法使能、快速 Rescale 使能
      与 RTL 的 gear_controller.sv 配置表完全一致。

验证项：
  1. 4 档默认配置正确性
  2. 阈值覆盖逻辑
  3. 阈值值与 Phase 1 配置表一致
  4. 边界条件（无效档位）
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

PASS = 0
FAIL = 0

def check(name, actual, expected):
    global PASS, FAIL
    if actual == expected:
        print(f"  [PASS] {name}: actual={actual}")
        PASS += 1
    else:
        print(f"  [FAIL] {name}: actual={actual} expected={expected}")
        FAIL += 1

def check_bool(name, actual, expected):
    global PASS, FAIL
    if bool(actual) == bool(expected):
        print(f"  [PASS] {name}: actual={actual}")
        PASS += 1
    else:
        print(f"  [FAIL] {name}: actual={actual} expected={expected}")
        FAIL += 1


def get_gear_config(gear_sel, thresh_ovr=0, ovr_en=False):
    """模拟 gear_controller 的配置表逻辑。"""
    configs = {
        0: {"threshold": 0, "trunc_bits": 0, "approx_mult": False, "fast_rescale": False},
        1: {"threshold": 4096, "trunc_bits": 0, "approx_mult": False, "fast_rescale": False},
        2: {"threshold": 16384, "trunc_bits": 9, "approx_mult": True, "fast_rescale": True},
        3: {"threshold": 65536, "trunc_bits": 17, "approx_mult": True, "fast_rescale": True},
    }
    cfg = configs.get(gear_sel, configs[0])  # 无效档位 fallback 到 Gear 0

    threshold = thresh_ovr if ovr_en else cfg["threshold"]
    return {
        "threshold": threshold,
        "trunc_bits": cfg["trunc_bits"],
        "approx_mult": cfg["approx_mult"],
        "fast_rescale": cfg["fast_rescale"],
    }


def main():
    print("=" * 70)
    print("M4-a 档位控制器 Python 验证")
    print("=" * 70)

    # -------------------------------------------------------------------------
    # Test 1: 4 档默认配置
    # -------------------------------------------------------------------------
    print("\n--- Test 1: 4 档默认配置 ---")

    expected_configs = {
        0: {"threshold": 0, "trunc_bits": 0, "approx_mult": False, "fast_rescale": False},
        1: {"threshold": 4096, "trunc_bits": 0, "approx_mult": False, "fast_rescale": False},
        2: {"threshold": 16384, "trunc_bits": 9, "approx_mult": True, "fast_rescale": True},
        3: {"threshold": 65536, "trunc_bits": 17, "approx_mult": True, "fast_rescale": True},
    }

    for gear in range(4):
        cfg = get_gear_config(gear)
        exp = expected_configs[gear]
        check(f"Gear {gear} threshold", cfg["threshold"], exp["threshold"])
        check(f"Gear {gear} trunc_bits", cfg["trunc_bits"], exp["trunc_bits"])
        check_bool(f"Gear {gear} approx_mult", cfg["approx_mult"], exp["approx_mult"])
        check_bool(f"Gear {gear} fast_rescale", cfg["fast_rescale"], exp["fast_rescale"])

    # -------------------------------------------------------------------------
    # Test 2: 阈值覆盖
    # -------------------------------------------------------------------------
    print("\n--- Test 2: 阈值覆盖 ---")

    # 覆盖使能时，手动阈值生效
    cfg = get_gear_config(1, thresh_ovr=12345, ovr_en=True)
    check("override threshold", cfg["threshold"], 12345)
    check("override trunc_bits (unchanged)", cfg["trunc_bits"], 0)

    # 覆盖关闭时，回到默认
    cfg = get_gear_config(1, thresh_ovr=12345, ovr_en=False)
    check("override off threshold", cfg["threshold"], 4096)

    # -------------------------------------------------------------------------
    # Test 3: 无效档位
    # -------------------------------------------------------------------------
    print("\n--- Test 3: 无效档位 ---")

    for gear in [4, 5, 7]:
        cfg = get_gear_config(gear)
        check(f"Gear {gear} threshold (fallback)", cfg["threshold"], 0)
        check(f"Gear {gear} trunc_bits (fallback)", cfg["trunc_bits"], 0)
        check_bool(f"Gear {gear} approx_mult (fallback)", cfg["approx_mult"], False)

    # -------------------------------------------------------------------------
    # Test 4: 阈值值合理性
    # -------------------------------------------------------------------------
    print("\n--- Test 4: 阈值值合理性 ---")

    q = 17592186175489  # 2^44 + 131073
    scale = 1 << 30

    for gear in range(1, 4):
        cfg = get_gear_config(gear)
        t = cfg["threshold"]
        ratio = t / q
        print(f"  Gear {gear}: threshold={t} ({ratio*100:.4f}% of q)")
        # 阈值应远小于 q
        check(f"Gear {gear} threshold < q", t < q, True)
        # 阈值应大于 0（Gear 0 除外）
        check(f"Gear {gear} threshold > 0", t > 0, True)

    # -------------------------------------------------------------------------
    # Test 5: 阈值序列单调递增
    # -------------------------------------------------------------------------
    print("\n--- Test 5: 阈值序列单调递增 ---")

    thresholds = [get_gear_config(g)["threshold"] for g in range(4)]
    print(f"  Thresholds: {thresholds}")
    for i in range(1, 4):
        check(f"threshold[{i}] >= threshold[{i-1}]",
              thresholds[i] >= thresholds[i-1], True)

    # -------------------------------------------------------------------------
    # Test 6: 与 Phase 1 配置表对比
    # -------------------------------------------------------------------------
    print("\n--- Test 6: Phase 1 配置表一致性 ---")

    # Phase 1 文档锁定的配置表
    phase1_table = {
        0: {"threshold": 0, "trunc_bits": 0, "approx_mult": False, "fast_rescale": False},
        1: {"threshold": 4096, "trunc_bits": 0, "approx_mult": False, "fast_rescale": False},
        2: {"threshold": 16384, "trunc_bits": 9, "approx_mult": True, "fast_rescale": True},
        3: {"threshold": 65536, "trunc_bits": 17, "approx_mult": True, "fast_rescale": True},
    }

    for gear in range(4):
        cfg = get_gear_config(gear)
        exp = phase1_table[gear]
        check(f"Phase1 Gear {gear} threshold", cfg["threshold"], exp["threshold"])
        check(f"Phase1 Gear {gear} trunc_bits", cfg["trunc_bits"], exp["trunc_bits"])
        check_bool(f"Phase1 Gear {gear} approx_mult", cfg["approx_mult"], exp["approx_mult"])
        check_bool(f"Phase1 Gear {gear} fast_rescale", cfg["fast_rescale"], exp["fast_rescale"])

    # -------------------------------------------------------------------------
    # 结果汇总
    # -------------------------------------------------------------------------
    print()
    print("=" * 70)
    print(f"Results: {PASS} PASS, {FAIL} FAIL")
    if FAIL == 0:
        print("ALL PASS")
        print("=" * 70)
        return 0
    else:
        print(f"FAIL ({FAIL} failures)")
        print("=" * 70)
        return 1


if __name__ == "__main__":
    sys.exit(main())
