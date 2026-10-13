#!/usr/bin/env python3
"""Export the two launch ABIs from forge build artifacts, or check committed exports."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail on missing or stale ABI exports")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for name in ("LaunchToken", "SwarmCats"):
        artifact = root / "out" / f"{name}.sol" / f"{name}.json"
        if not artifact.is_file():
            parser.error(f"{artifact} is missing; run forge build first")
        contents = json.dumps(json.loads(artifact.read_text())["abi"], indent=2) + "\n"
        destination = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not destination.is_file() or destination.read_text() != contents:
                parser.error(f"{destination} is stale; run python3 scripts/export_abis.py")
            print(f"ABI matches build: {name}")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(contents)
            print(f"Exported {destination.relative_to(root)}")


if __name__ == "__main__":
    main()
