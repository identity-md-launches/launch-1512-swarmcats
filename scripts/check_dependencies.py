#!/usr/bin/env python3
"""Verify vendored release files against the recorded SHA-256 hashes, without a network."""

import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    packages = json.loads((root / "dependencies.lock.json").read_text())
    for package in packages:
        for relative, expected in package["files"].items():
            path = root / "lib" / package["name"] / relative
            if not path.is_file():
                raise SystemExit(f"Missing dependency file: {path}")
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise SystemExit(f"Dependency file differs from pinned release: {path}")
        print(f"Verified {package['name']} {package['release']}: {len(package['files'])} files")


if __name__ == "__main__":
    main()
