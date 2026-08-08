#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys

PROJECT_ROOT = r"C:\Users\ANEN\mosaicvpn"
FLUTTER_DIR = os.path.join(PROJECT_ROOT, "flutter")
DIST_DIR = os.path.join(PROJECT_ROOT, "dist", "MosaicVPN")
FLUTTER_SDK_DART = r"C:\Users\ANEN\flutter-sdk\bin\dart.bat"
FLUTTER_SDK_FLUTTER = r"C:\Users\ANEN\flutter-sdk\bin\flutter.bat"

def run_cmd(cmd, cwd=None):
    print(f"Running: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    res = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Error (exit {res.returncode}):\n{res.stderr}\n{res.stdout}")
        sys.exit(res.returncode)
    print("OK")
    return res.stdout

def main():
    print("=== Step 1: Build Go Daemon (mosaicd.exe) ===")
    run_cmd("go build -v -o bin/mosaicd.exe ./cmd/mosaicd", cwd=PROJECT_ROOT)

    print("\n=== Step 2: Build Flutter Windows App (Release) ===")
    run_cmd(f'"{FLUTTER_SDK_FLUTTER}" build windows --release', cwd=FLUTTER_DIR)

    print("\n=== Step 3: Bundle Release Distribution ===")
    if os.path.exists(DIST_DIR):
        try:
            shutil.rmtree(DIST_DIR, ignore_errors=True)
        except Exception:
            pass
    os.makedirs(DIST_DIR, exist_ok=True)

    release_src = os.path.join(FLUTTER_DIR, "build", "windows", "x64", "runner", "Release")
    for item in os.listdir(release_src):
        s = os.path.join(release_src, item)
        d = os.path.join(DIST_DIR, item)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        else:
            shutil.copy2(s, d)

    # Copy mosaicd.exe into release folder & bin/ subfolder for full compatibility
    shutil.copy2(os.path.join(PROJECT_ROOT, "bin", "mosaicd.exe"), os.path.join(DIST_DIR, "mosaicd.exe"))
    bin_sub = os.path.join(DIST_DIR, "bin")
    os.makedirs(bin_sub, exist_ok=True)
    shutil.copy2(os.path.join(PROJECT_ROOT, "bin", "mosaicd.exe"), os.path.join(bin_sub, "mosaicd.exe"))

    print(f"\n=== Release Bundle Created at: {DIST_DIR} ===")
    files = os.listdir(DIST_DIR)
    for f in files:
        size = os.path.getsize(os.path.join(DIST_DIR, f)) if os.path.isfile(os.path.join(DIST_DIR, f)) else "<DIR>"
        print(f"  - {f:<35} {size}")

    # Create ZIP archive
    zip_path = os.path.join(PROJECT_ROOT, "dist", "MosaicVPN-v1.0.0-windows-x64.zip")
    shutil.make_archive(zip_path.replace(".zip", ""), 'zip', DIST_DIR)
    print(f"\n=== Release ZIP Created: {zip_path} ({os.path.getsize(zip_path) / (1024*1024):.2f} MB) ===")

if __name__ == "__main__":
    main()
