#!/usr/bin/env python3
"""Build the Linux release tarball with correct POSIX permissions.

git-bash on Windows stores files on NTFS, which carries no POSIX exec bit.
`chmod +x` there is a no-op and GNU tar records mode 0644 for everything, so
users who extract the published archive hit "Permission denied" on every
binary.

This builds the tarball directly so the executables get 0755 while the
data/ and lib/ payload keeps 0644.

Usage:  make_linux_tar.py <staged_dir> <output.tar.gz>

<staged_dir> is the directory that becomes the archive root (e.g. .../MosaicVPN).
"""

from __future__ import annotations

import sys
import tarfile
from pathlib import Path

# Files that must be executable after extraction.
EXECUTABLES = {"mosaic_vpn", "mosaicd", "mosaic", "sing-box"}


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    staged = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()

    if not staged.is_dir():
        print(f"error: staged dir not found: {staged}", file=sys.stderr)
        return 1

    root = staged.name  # archive root, e.g. "MosaicVPN"
    missing = sorted(name for name in EXECUTABLES if not (staged / name).is_file())
    if missing:
        print(f"error: missing executables in {staged}: {missing}", file=sys.stderr)
        return 1

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()

    def reset(info: tarfile.TarInfo) -> tarfile.TarInfo:
        # Normalise ownership so the archive does not leak the build account.
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        if info.isdir():
            info.mode = 0o755
        elif Path(info.name).name in EXECUTABLES and Path(info.name).parent.name == root:
            info.mode = 0o755
        else:
            info.mode = 0o644
        return info

    with tarfile.open(output, "w:gz") as tar:
        tar.add(staged, arcname=root, filter=reset)

    # Verify rather than trust: re-open and assert the modes we intended.
    with tarfile.open(output, "r:gz") as tar:
        modes = {m.name: m.mode for m in tar.getmembers()}
    for name in EXECUTABLES:
        mode = modes.get(f"{root}/{name}")
        if mode is None:
            print(f"error: {name} missing from archive", file=sys.stderr)
            return 1
        if not mode & 0o111:
            print(f"error: {name} is not executable (mode {mode:o})", file=sys.stderr)
            return 1

    print(f"    linux tar: {len(modes)} entries, executables 0755")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
