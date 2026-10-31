#!/usr/bin/env python3
"""Apply and record test-input corrections to ANGLE's pinned VK-GL-CTS checkout."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_manifest", ROOT / "scripts/write-build-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


def prepare(root, angle, apply=False):
    pin = (root / "ANGLE_COMMIT").read_text().strip()
    entry = manifest.capture("git", "ls-tree", pin, "--", "third_party/VK-GL-CTS/src", cwd=angle)
    fields = entry.split()
    if len(fields) < 3 or fields[0] != "160000":
        raise RuntimeError("The ANGLE pin does not identify a CTS gitlink")
    cts = angle / "third_party/VK-GL-CTS/src"
    with tempfile.TemporaryDirectory(prefix="angle-cts-patches-") as temporary:
        patch_root = Path(temporary)
        (patch_root / "ANGLE_COMMIT").write_text(fields[2] + "\n")
        (patch_root / "patches").mkdir()
        for patch in sorted((root / "patches-cts").glob("*.patch")):
            shutil.copy2(patch, patch_root / "patches" / patch.name)
        if apply:
            manifest.apply_patch_series(patch_root, cts)
        return manifest.source_identity(patch_root, cts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--angle-dir", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    identity = prepare(ROOT, args.angle_dir.resolve(), args.apply)
    result = json.dumps(identity, indent=2) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")


if __name__ == "__main__":
    main()
