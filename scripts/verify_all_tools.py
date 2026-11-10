"""Verify all three simulation tools work with the new env helper."""
import os
import subprocess
import sys
sys.path.insert(0, os.path.dirname(__file__))
from vivado_env import get_env, get_exe

env = get_env()

for tool in ['xvlog', 'xelab', 'xsim']:
    exe = get_exe(tool)
    exists = os.path.exists(exe)
    print(f"\n=== {tool} ===")
    print(f"Path: {exe}")
    print(f"Exists: {exists}")
    if exists:
        r = subprocess.run(
            [exe, '--version'],
            capture_output=True, text=True, timeout=15, env=env
        )
        print(f"RC: {r.returncode}")
        if r.stdout:
            print(f"OUT: {r.stdout[:200]}")
        if r.stderr:
            print(f"ERR: {r.stderr[:200]}")
