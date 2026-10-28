#!/usr/bin/env python3
"""Validate sni_tray.py before a Talk AppImage rebuild."""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SNI = ROOT / "sni_tray.py"


def run(args, extra_env=None, timeout=20):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        args,
        cwd=str(ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def main() -> int:
    failed = 0
    r = run([sys.executable, str(SNI), "--self-test"])
    print(r.stdout.strip() or r.stderr.strip())
    if r.returncode != 0:
        print("FAIL Gio/GLib self-test (python3-gi required)")
        print(r.stderr)
        failed += 1
    else:
        print("PASS Gio/GLib pixmap variant")

    dbus_run = shutil.which("dbus-run-session")
    if not dbus_run:
        print("SKIP bus test (dbus-run-session not installed)")
        return failed

    r = run([dbus_run, "--", sys.executable, str(SNI), "--self-test-bus"], timeout=25)
    print(r.stdout.strip())
    if r.stderr.strip():
        print(r.stderr.strip())
    if r.returncode != 0:
        print("FAIL unique-name Properties.Get via Gio")
        failed += 1
    else:
        print("PASS unique-name Get/GetAll via Gio")
    return failed


if __name__ == "__main__":
    sys.exit(main())
