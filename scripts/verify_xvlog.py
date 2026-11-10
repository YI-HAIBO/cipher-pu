"""Verify xvlog also works with lib/win64.o in PATH."""
import os
import subprocess

VIVADO = os.environ.get("VIVADO_ROOT", "")
BIN = os.path.join(VIVADO, "bin")
LIB = os.path.join(VIVADO, "lib", "win64.o")
UNWRAPPED = os.path.join(BIN, "unwrapped", "win64.o")

env = os.environ.copy()
env['PATH'] = LIB + ';' + BIN + ';' + UNWRAPPED + ';' + env.get('PATH', '')
env['RDI_BASEROOT'] = os.path.dirname(VIVADO)
env['RDI_APPROOT'] = VIVADO
env['RDI_BINROOT'] = BIN

# Test xvlog
print("=== xvlog.exe --version ===")
r = subprocess.run(
    [os.path.join(UNWRAPPED, 'xvlog.exe'), '--version'],
    capture_output=True, text=True, timeout=15, env=env
)
print(f"RC: {r.returncode} (hex: 0x{r.returncode & 0xFFFFFFFF:08X})")
print(f"STDOUT: {r.stdout[:300]}")
print(f"STDERR: {r.stderr[:300]}")

# Test xsim with an actual file (check if it can run simulations)
print("\n=== xsim.exe -help (check for simulation options) ===")
r = subprocess.run(
    [os.path.join(UNWRAPPED, 'xsim.exe'), '-help'],
    capture_output=True, text=True, timeout=15, env=env
)
print(f"RC: {r.returncode}")
if r.stdout:
    print(f"STDOUT (first 500): {r.stdout[:500]}")
if r.stderr:
    print(f"STDERR (first 200): {r.stderr[:200]}")
