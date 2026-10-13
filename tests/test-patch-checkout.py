#!/usr/bin/env python3
"""Check Windows-style patch checkout and apply against the pinned ANGLE tree."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ANGLE = Path(os.environ.get("ANGLE_DIR", str(ROOT / "build/angle")))
PIN = (ROOT / "ANGLE_COMMIT").read_text().strip()


def git(*args, cwd):
    return subprocess.check_output(["git", *args], cwd=cwd)


with tempfile.TemporaryDirectory(prefix="angle-patch-checkout-") as tmp:
    tmp = Path(tmp)
    patch_repo = tmp / "patches"
    patch_repo.mkdir()
    git("init", "-q", cwd=patch_repo)
    # Copy only the inputs to a disposable repo so no real index/config is changed.
    (patch_repo / ".gitattributes").write_bytes((ROOT / ".gitattributes").read_bytes())
    for patch in sorted((ROOT / "patches").glob("*.patch")):
        (patch_repo / patch.name).write_bytes(patch.read_bytes())
    git("add", ".", cwd=patch_repo)

    for autocrlf in ("false", "true"):
        checkout = tmp / ("checkout-" + autocrlf)
        checkout.mkdir()
        git("-c", "core.autocrlf=" + autocrlf, "checkout-index", "--all",
            "--prefix=" + str(checkout) + "/", cwd=patch_repo)
        sources = tmp / ("sources-" + autocrlf)
        sources.mkdir()
        git("init", "-q", cwd=sources)
        patches = sorted(checkout.glob("*.patch"))
        assert patches, "No patches found"
        for patch in patches:
            data = patch.read_bytes()
            assert b"\r\n" not in data, f"{patch.name} checked out with CRLF"
            for line in data.decode().splitlines():
                if line.startswith("--- a/"):
                    name = line[6:]
                    dest = sources / name
                    if not dest.exists():
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_bytes(git("show", PIN + ":" + name, cwd=ANGLE))
        for patch in patches:
            git("apply", "--check", str(patch), cwd=sources)
            git("apply", str(patch), cwd=sources)
            git("apply", "--reverse", "--check", str(patch), cwd=sources)
        print(f"PASS: core.autocrlf={autocrlf}: LF checkout and all patches apply")
