# -*- coding: utf-8 -*-
"""M-D'：生成 twiddle .hex（$readmemh ROM 初始化）三套 × 3 素数 × (ω, ω⁻¹)。

供 ntt_unit.sv 的 $readmemh ROM 使用，替代原 input 数组（综合成巨型 mux）。
输出到 rtl/m5/tw/：
    tw_omega_p{1..3}_{n16|n4096|n16384}.hex
    tw_omegainv_p{1..3}_{n16|n4096|n16384}.hex
每行一个 42-bit hex（xsim/Vivado $readmemh 兼容）。
校验：omega^N=1、omega*omega_inv=1、NTT∘INTT=identity（gen_omega_tables.verify）。
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from gen_omega_tables import generate_table, format_hex, verify  # noqa: E402

PRIMES = [77309411329, 206158430209, 2061584302081]
QW = 42
OUT = ROOT / "rtl" / "m5" / "tw"

# (N, [omega_p1,p2,p3], [omega_inv_p1,p2,p3])
SETS = {
    "n16": (16,
            [50631443320, 98425511888, 395346182510],
            [46529491216, 116861345673, 393502824234]),
    "n4096": (4096,
              [13082189566, 50364427753, 690026831616],
              [58279994501, 143707733702, 1557486884017]),
    "n16384": (16384,
               [45882479801, 11936980701, 767953144232],
               [42938856489, 182016140628, 491358340514]),
}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for tag, (N, ws, wis) in SETS.items():
        for i in range(3):
            p = PRIMES[i]
            w, wi = ws[i], wis[i]
            t = generate_table(w, p, N)
            ti = generate_table(wi, p, N)
            errs = verify(N, p, w, wi, t, ti)
            if errs:
                print(f"[FAIL] {tag} p{i+1}: {errs}")
                return 3
            (OUT / f"tw_omega_p{i+1}_{tag}.hex").write_text(format_hex(t, QW), encoding="utf-8")
            (OUT / f"tw_omegainv_p{i+1}_{tag}.hex").write_text(format_hex(ti, QW), encoding="utf-8")
            print(f"[OK] {tag} p{i+1}: N={N} entries={len(t)} -> tw_omega_p{i+1}_{tag}.hex")
    print("[DONE] all twiddle .hex generated at", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
