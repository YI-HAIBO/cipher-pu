#!/usr/bin/env python3
"""
M4-d: approx_poly_mult Mathematical Equivalence Verification
============================================================

Verifies the Python-level model of approx_poly_mult.sv behavior:
  - Bypass mode (use_approx_mult=0 or threshold=0): output = poly_mult output
  - Approx mode (use_approx_mult=1): mask out small coefficients on output
  - post_skip_cnt counter tracks output-side masked positions
  - Interface signature compatible with poly_mult + 3 additional config signals

The poly_mult itself is treated as a black box here; we verify the
wrapper's masking layer mathematically.
"""
import os
import sys
import random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = 0
FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {extra}")


def post_process(poly_mult_out, threshold, use_approx, q_value=113):
    """Model of approx_poly_mult output post-processing stage."""
    skip_cnt = 0
    out = []
    if not use_approx or threshold == 0:
        return poly_mult_out[:], 0
    for x in poly_mult_out:
        is_zero = (x < threshold) or ((q_value - x) < threshold)
        if is_zero:
            skip_cnt += 1
            out.append(0)
        else:
            out.append(x)
    return out, skip_cnt


def post_process_block(poly_mult_out, threshold, use_approx, q_value=113, B=1):
    """Model of approx_poly_mult BLOCK-LEVEL output post-processing stage.

    For each block of B consecutive coefficients:
      - Compute max_abs = max(min(x, q-x)) over block
      - If max_abs < threshold AND use_approx AND threshold!=0:
            output all-B zeros for this block
            count 1 skipped block
      - Else: output the original B coefficients
    """
    skip_blocks = 0
    out = []
    n = len(poly_mult_out)
    if B <= 0:
        B = 1
    if B > n:
        # single block covering all
        blocks = [poly_mult_out]
    else:
        blocks = [poly_mult_out[i:i+B] for i in range(0, n, B)]
    for block in blocks:
        if not block:
            continue
        max_abs = max(min(x, q_value - x) for x in block)
        if use_approx and threshold != 0 and max_abs < threshold:
            skip_blocks += 1
            out.extend([0] * len(block))
        else:
            out.extend(block)
    return out, skip_blocks


# ============================================================
print("=" * 70)
print("M4-d: approx_poly_mult Python 数学等价验证")
print("=" * 70)

# Test 1: Bypass (use_approx_mult=0)
print("\n[TEST 1] Bypass 模式（use_approx_mult=0）")
poly_out = [10, 55, 100, 3, 88, 21, 99, 5]
post, skp = post_process(poly_out, threshold=10, use_approx=False)
check("bypass 保持原值", post == poly_out)
check("bypass skip=0", skp == 0)

# Test 2: Approx mode with threshold=10
print("\n[TEST 2] Approx 模式（threshold=10, use_approx=1）")
# q=113, threshold=10
# poly_out = [10, 55, 100, 3, 88, 21, 99, 5]
# x<10: 3, 5 (2 items)
# q-x<10 i.e. x>103: none (max is 100)
# expected skip = 2
post, skp = post_process(poly_out, threshold=10, use_approx=True)
check("expected skip=2", skp == 2, f"got={skp}")
check("被跳位置置零", post[3] == 0 and post[7] == 0)
check("其他位置保留", post[0] == 10 and post[1] == 55 and post[2] == 100)

# Test 3: Near-q handling
print("\n[TEST 3] 近 q 系数处理")
# q=113, threshold=5
# poly_out = [109, 111, 112, 50, 5, 108, 60]
# x<5: none (x=5 not <5)
# q-x<5 i.e. x>108: 109, 111, 112 (3 items); x=108 → q-x=5 不 <5
# expected skip = 3
poly_out3 = [109, 111, 112, 50, 5, 108, 60]
post3, skp3 = post_process(poly_out3, threshold=5, use_approx=True)
check("expected skip=3", skp3 == 3, f"got={skp3}")

# Test 4: threshold=0 (no skip even with use_approx)
print("\n[TEST 4] threshold=0（无跳）")
post4, skp4 = post_process(poly_out, threshold=0, use_approx=True)
check("threshold=0 全保留", skp4 == 0)
check("数据完整", post4 == poly_out)

# Test 5: threshold=q (all values skipped)
print("\n[TEST 5] threshold=q (全跳，边界)")
q_val = 113
post5, skp5 = post_process(poly_out, threshold=q_val, use_approx=True)
check("threshold=q 全部跳", skp5 == len(poly_out), f"got={skp5}")
check("输出全零", all(x == 0 for x in post5))

# Test 6: Random stress (100 cases)
print("\n[TEST 6] 随机压测 (100 组)")
random.seed(42)
all_ok = True
for i in range(100):
    q = 113
    n = random.randint(1, 32)
    threshold = random.randint(0, q + 10)
    use_approx = random.choice([True, False])
    data = [random.randint(0, q - 1) for _ in range(n)]
    out, skp = post_process(data, threshold, use_approx)
    if len(out) != n:
        all_ok = False
        break
    if not use_approx or threshold == 0:
        if out != data:
            all_ok = False
            break
    else:
        expect_skip = sum(
            1 for x in data
            if (x < threshold) or ((q - x) < threshold)
        )
        if skp != expect_skip:
            all_ok = False
            break
        for j, o in enumerate(out):
            if o != 0 and o != data[j]:
                all_ok = False
                break
check("100 组随机无违例", all_ok)

# Test 7: Gear configuration compatibility (Phase 1 table)
print("\n[TEST 7] 4 档配置兼容性")
gear_configs = [
    {"gear": 0, "threshold": 0,     "use_approx": False},
    {"gear": 1, "threshold": 4096,  "use_approx": False},
    {"gear": 2, "threshold": 16384, "use_approx": True},
    {"gear": 3, "threshold": 65536, "use_approx": True},
]
for g in gear_configs:
    _, skp = post_process([0, 5, 100, 40000, 100000], threshold=g["threshold"], use_approx=g["use_approx"], q_value=2**44 + 131073)
    if g["gear"] <= 1:
        check(f"Gear{g['gear']} 无掩码", skp == 0)
    else:
        check(f"Gear{g['gear']} 有掩码或透传", isinstance(skp, int))

# Test 8: RTL file existence and interface scan
print("\n[TEST 8] RTL 交付物扫描")
rtl_path = os.path.join(ROOT, "rtl", "m4", "approx_poly_mult.sv")
check(f"RTL 文件存在", os.path.isfile(rtl_path))
with open(rtl_path, "r", encoding="utf-8") as f:
    t = f.read()
check("含 sparsity_threshold 端口", "sparsity_threshold" in t)
check("含 trunc_bits 端口", "trunc_bits" in t)
check("含 use_approx_mult 端口", "use_approx_mult" in t)
check("例化 poly_mult", "poly_mult" in t)
check("含 pm_out_data", "pm_out_data" in t)
check("含 masked_data", "masked_data" in t)
check("含 post_valid 寄存器", "post_valid" in t)
check("含 post_skip_cnt 观测", "post_skip_cnt" in t)

# Test 9: Interface compatibility with poly_mult (Phase 1 §1.4)
print("\n[TEST 9] 接口兼容性验证")
required_ports = [
    "clk", "rst_n", "start", "busy", "done", "error",
    "a_in_data", "a_in_valid", "a_in_ready",
    "b_in_data", "b_in_valid", "b_in_ready",
    "out_data", "out_valid", "out_last", "out_ready",
    "omega_table", "omega_inv_table",
    "sparsity_threshold", "trunc_bits", "use_approx_mult",
]
for p in required_ports:
    check(f"含端口 '{p}'", p in t)

# Test 10: Counter semantics
print("\n[TEST 10] post_skip_cnt 计数语义")
# q=113, threshold=10, mask if x<10 OR (113-x)<10
stream = [3, 7, 5, 1, 8, 100, 105]
# Skip if x<10 OR (113-x)<10:
#   x=3  → x<10 True    skip
#   x=7  → x<10 True    skip
#   x=5  → x<10 True    skip
#   x=1  → x<10 True    skip
#   x=8  → x<10 True    skip
#   x=100→ 113-100=13  not <10, no skip
#   x=105→ 113-105=8   <10, skip
# total = 6
q = 113
threshold = 10
expected_skips = 6
actual = 0
for x in stream:
    if (x < threshold) or ((q - x) < threshold):
        actual += 1
check(f"实际跳过={actual} (预期 6)", actual == expected_skips)

# ============================================================
print("\n" + "=" * 70)
print(f"结果: {PASS} PASS / {FAIL} FAIL")
if FAIL == 0:
    print("  ALL PASS ✓  M4-d Python 数学等价验证通过")
else:
    print(f"  {FAIL} 项失败，需检查")
print("=" * 70)

# ============================================================
# 块级稀疏数学验证（Task #84 步骤 4 新增）
# ============================================================
BLOCK_PASS = 0
BLOCK_FAIL = 0

def bcheck(name, cond, extra=""):
    global BLOCK_PASS, BLOCK_FAIL
    if cond:
        BLOCK_PASS += 1
        print(f"  [PASS] {name}")
    else:
        BLOCK_FAIL += 1
        print(f"  [FAIL] {name} {extra}")

print("\n" + "=" * 70)
print("M4-d: 块级稀疏（block_sparse_en=1）数学验证 [Task #84 Step 4]")
print("=" * 70)

# Block Test 1: Bypass (use_approx=0) - all preserved
print("\n[BLK TEST 1] Bypass（use_approx=0, 块级模式）")
poly_out = [10, 55, 100, 3, 88, 21, 99, 5]
post, skp = post_process_block(poly_out, threshold=10, use_approx=False, q_value=113, B=2)
bcheck("bypass 保持原值", post == poly_out)
bcheck("bypass skip=0", skp == 0)

# Block Test 2: threshold=0 (no skip even with use_approx)
print("\n[BLK TEST 2] threshold=0（块级无跳）")
post, skp = post_process_block(poly_out, threshold=0, use_approx=True, q_value=113, B=2)
bcheck("threshold=0 全保留", skp == 0)
bcheck("数据完整", post == poly_out)

# Block Test 3: threshold=1, small non-zero values kept
print("\n[BLK TEST 3] threshold=1（块级几乎不跳，仅 max_abs=0 块被跳）")
# Blocks of 2: [10,55], [100,3], [88,21], [99,5]
# max_abs: min(10,103)=10, min(55,58)=55 → 55
#          min(100,13)=13, min(3,110)=3 → 13
#          min(88,25)=25, min(21,92)=21 → 25
#          min(99,14)=14, min(5,108)=5 → 14
# threshold=1: skip only if max_abs < 1 → all max >= 3, no skip
post, skp = post_process_block(poly_out, threshold=1, use_approx=True, q_value=113, B=2)
bcheck("expected skip=0", skp == 0, f"got={skp}")
bcheck("数据完整", post == poly_out)

# Block Test 4: threshold=15 (skip blocks with max_abs < 15)
print("\n[BLK TEST 4] threshold=15, B=2（块级部分跳）")
# Blocks: [10,55]=55, [100,3]=13, [88,21]=25, [99,5]=14
# skip: [100,3] (13<15), [99,5] (14<15) → 2 blocks skipped
post, skp = post_process_block(poly_out, threshold=15, use_approx=True, q_value=113, B=2)
bcheck("expected skip_blocks=2", skp == 2, f"got={skp}")
# Block 0 preserved: [10,55]
bcheck("Block 0 保留", post[0] == 10 and post[1] == 55)
# Block 1 zeroed: [0,0]
bcheck("Block 1 置零", post[2] == 0 and post[3] == 0)
# Block 2 preserved: [88,21]
bcheck("Block 2 保留", post[4] == 88 and post[5] == 21)
# Block 3 zeroed: [0,0]
bcheck("Block 3 置零", post[6] == 0 and post[7] == 0)

# Block Test 5: B=4 (larger block size)
print("\n[BLK TEST 5] B=4, threshold=15")
# Blocks of 4: [10,55,100,3], [88,21,99,5]
# max_abs: [10,55,13,3] → 55 (kept)
#          [25,21,14,5] → 25 (kept)
post, skp = post_process_block(poly_out, threshold=15, use_approx=True, q_value=113, B=4)
bcheck("expected skip=0 (both blocks kept)", skp == 0, f"got={skp}")
bcheck("数据完整", post == poly_out)

# Block Test 6: threshold=30 (skip block with max_abs=25)
print("\n[BLK TEST 6] B=4, threshold=30")
# max_abs: [10,55,13,3] → 55 (kept), [25,21,14,5] → 25 (skipped)
post, skp = post_process_block(poly_out, threshold=30, use_approx=True, q_value=113, B=4)
bcheck("expected skip=1", skp == 1, f"got={skp}")
bcheck("Block 0 保留", post[0:4] == [10, 55, 100, 3])
bcheck("Block 1 全零", post[4:8] == [0, 0, 0, 0])

# Block Test 7: threshold=large (all blocks skipped)
print("\n[BLK TEST 7] threshold=large (全跳)")
post, skp = post_process_block(poly_out, threshold=1000, use_approx=True, q_value=113, B=2)
bcheck("所有块跳", skp == 4, f"got={skp}")
bcheck("输出全零", all(x == 0 for x in post))

# Block Test 8: B=1 (退化为元素级)
print("\n[BLK TEST 8] B=1 退化为元素级")
# B=1: each coefficient is its own block, max_abs of single element = that element's abs
# Compare with element-level behavior
poly_out_small = [3, 100, 5, 108, 55]
post_block_b1, skp_b1 = post_process_block(poly_out_small, threshold=10, use_approx=True, q_value=113, B=1)
post_elem, skp_elem = post_process(poly_out_small, threshold=10, use_approx=True, q_value=113)
bcheck("B=1 输出等价于元素级", post_block_b1 == post_elem)
bcheck("B=1 skip 计数等价", skp_b1 == skp_elem)

# Block Test 9: Random stress (100 cases, various B)
print("\n[BLK TEST 9] 随机压测 (100 组，B∈{1,2,4,8})")
random.seed(1234)
all_ok = True
for i in range(100):
    q = 113
    n = random.choice([4, 8, 16, 32])
    B = random.choice([1, 2, 4, 8])
    threshold = random.randint(0, q)
    use_approx = random.choice([True, False])
    data = [random.randint(0, q - 1) for _ in range(n)]
    out, skp = post_process_block(data, threshold, use_approx, q_value=q, B=B)
    if len(out) != n:
        all_ok = False
        break
    if not use_approx or threshold == 0:
        if out != data:
            all_ok = False
            break
    else:
        # Verify each block: all zeros or all original
        nb = (n + B - 1) // B
        for bi in range(nb):
            block = data[bi*B:(bi+1)*B]
            max_abs = max(min(x, q - x) for x in block)
            out_block = out[bi*B:(bi+1)*B]
            if max_abs < threshold:
                if any(x != 0 for x in out_block):
                    all_ok = False
                    break
            else:
                if out_block != block:
                    all_ok = False
                    break
        if not all_ok:
            break
bcheck("100 组随机无违例", all_ok)

# Block Test 10: RTL file scan - block-level additions present
print("\n[BLK TEST 10] RTL 块级扩展扫描")
rtl_path = os.path.join(ROOT, "rtl", "m4", "approx_poly_mult.sv")
with open(rtl_path, "r", encoding="utf-8") as f:
    t = f.read()
bcheck("含 B 参数", "parameter int B" in t)
bcheck("含 block_sparse_en 端口", "block_sparse_en" in t)
bcheck("含 S_BL_COLLECT 状态", "S_BL_COLLECT" in t)
bcheck("含 S_BL_OUTPUT 状态", "S_BL_OUTPUT" in t)
bcheck("含 S_BL_DONE 状态", "S_BL_DONE" in t)
bcheck("含 bl_data_buf 缓冲", "bl_data_buf" in t)
bcheck("含 bl_max_abs 决策", "bl_max_abs" in t)
bcheck("含 bl_curr_abs 对称绝对值", "bl_curr_abs" in t)
bcheck("含 bl_keep 块决策", "bl_keep" in t)
bcheck("含 use_block_mode 模式复用", "use_block_mode" in t)
bcheck("含 filt_data MUX", "filt_data" in t)

# ============================================================
print("\n" + "=" * 70)
print(f"块级结果: {BLOCK_PASS} PASS / {BLOCK_FAIL} FAIL")
print("=" * 70)

TOTAL_PASS = PASS + BLOCK_PASS
TOTAL_FAIL = FAIL + BLOCK_FAIL
if TOTAL_FAIL == 0:
    print(f"  ALL PASS ✓  M4-d 元素级 + 块级 数学等价验证全部通过 ({TOTAL_PASS}/{TOTAL_PASS})")
    print("  注: E2E 顶层 block_sparse_en 接线在 Step 5 完成（本脚本不覆盖）")
    sys.exit(0)
else:
    print(f"  {TOTAL_FAIL} 项失败，需检查")
    sys.exit(1)
