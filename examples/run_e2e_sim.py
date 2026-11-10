"""
End-to-End CKKS Inference Simulation

Runs a full simulation of CIPHER-PU with encrypted MNIST inference.
"""
import argparse
import os
import sys
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description="Run e2e CKKS inference simulation")
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output-dir", type=str, default="output/")
    args = parser.parse_args()

    print(f"Running e2e CKKS inference simulation")
    print(f"  batch_size = {args.batch_size}")
    print(f"  seed = {args.seed}")
    print(f"  output_dir = {args.output_dir}")

    # Verify scripts directory
    scripts_dir = Path(__file__).parent.parent / "scripts"
    if not scripts_dir.exists():
        print(f"Error: scripts directory not found at {scripts_dir}")
        sys.exit(1)

    # Delegate to actual simulation runner
    print("\nRunning simulation via scripts/run_sim_vivado.py ...")
    import subprocess
    result = subprocess.run([
        sys.executable,
        "scripts/run_sim_vivado.py",
        "--tb", "tb_e2e_ckks_mult_ctrl_m4",
        "--timeout", "600"
    ], capture_output=True, text=True)
    print(result.stdout)
    if result.stderr:
        print("STDERR:", result.stderr)
    sys.exit(result.returncode)

if __name__ == "__main__":
    main()
