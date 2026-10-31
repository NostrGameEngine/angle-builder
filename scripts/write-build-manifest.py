#!/usr/bin/env python3
"""Record and verify the source and toolchain used for a macOS ANGLE build."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


def capture(*args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env).decode().strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_identity(root, angle, allow_unrelated=False, patch_count=None, verify_sources=True):
    pin = (root / "ANGLE_COMMIT").read_text().strip()
    if capture("git", "rev-parse", "HEAD", cwd=angle) != pin:
        raise RuntimeError("ANGLE checkout differs from ANGLE_COMMIT")
    patches = sorted((root / "patches").glob("*.patch"))
    if patch_count is not None:
        patches = patches[:patch_count]
    with tempfile.TemporaryDirectory(prefix="angle-manifest-") as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"))
        capture("git", "read-tree", pin, cwd=angle, env=env)
        for patch in patches:
            capture("git", "apply", "--cached", str(patch), cwd=angle, env=env)
        tree = capture("git", "write-tree", cwd=angle, env=env)
        paths = capture("git", "diff", "--cached", "--name-only", "-z", pin,
                        cwd=angle, env=env).split("\0")
        changed = {path for path in paths if path}
        if verify_sources:
            for path in changed:
                entry = capture("git", "ls-files", "--stage", "--", path, cwd=angle, env=env)
                actual = angle / path
                if not entry:
                    if actual.exists():
                        raise RuntimeError(f"Deleted patch source still exists: {path}")
                    continue
                expected_blob = entry.split()[1]
                # Patch checks allow normal checkout EOL conversion. Package manifests
                # continue to verify the exact source bytes used by the compiler.
                hash_args = ("--path", path) if allow_unrelated else ()
                if not actual.is_file() or capture("git", "hash-object", *hash_args, "--", str(actual),
                                                   cwd=angle) != expected_blob:
                    raise RuntimeError(f"Source differs from the patch series: {path}")
            dirty = capture("git", "diff", "HEAD", "--name-only", "-z",
                            "--ignore-submodules=all", cwd=angle).split("\0")
            unexpected = {path for path in dirty if path} - changed
            if unexpected and not allow_unrelated:
                raise RuntimeError(f"Unrecorded source changes: {sorted(unexpected)}")
            untracked = capture("git", "ls-files", "--others", "--exclude-standard", "-z",
                                cwd=angle).split("\0")
            unexpected = {path for path in untracked if path} - changed
            if unexpected and not allow_unrelated:
                raise RuntimeError(f"Unrecorded source files: {sorted(unexpected)}")
    return {
        "upstream_commit": pin,
        "upstream_tree": capture("git", "rev-parse", pin + "^{tree}", cwd=angle),
        "patched_tree": tree,
        "patches": [{"name": patch.name, "sha256": sha256(patch)} for patch in patches],
    }


def apply_patch_series(root, angle):
    patches = sorted((root / "patches").glob("*.patch"))
    # Build the final tree first, rejecting a broken series before any source edit.
    identity = source_identity(root, angle, allow_unrelated=True, verify_sources=False)
    applied = 0
    for count in range(len(patches), 0, -1):
        try:
            source_identity(root, angle, allow_unrelated=True, patch_count=count)
            applied = count
            break
        except RuntimeError:
            pass
    if applied == len(patches):
        print("Complete patch series already applied")
        return
    remaining = patches[applied:]
    # A later patch can invalidate an earlier reverse-check context. Recognize
    # the longest canonical prefix, then check ALL remaining patches in a
    # disposable tree before changing the user's checkout or real index.
    paths = capture("git", "diff", "--name-only", "-z", identity["upstream_commit"],
                    identity["patched_tree"], cwd=angle).split("\0")
    with tempfile.TemporaryDirectory(prefix="angle-apply-check-") as temporary:
        check = Path(temporary)
        capture("git", "init", "-q", cwd=check)
        capture("git", "config", "core.autocrlf", "false", cwd=check)
        for path in filter(None, paths):
            actual = angle / path
            if not actual.exists():
                continue
            if not actual.is_file() or actual.is_symlink():
                raise RuntimeError("Patch path is not a regular file: " + path)
            target = check / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(actual, target)
            # Simulate canonical Git contents, including Windows CRLF checkouts.
            blob = capture("git", "hash-object", "-w", "--path", path, "--", str(actual), cwd=angle)
            target.write_bytes(subprocess.check_output(["git", "cat-file", "blob", blob], cwd=angle))
        for patch in remaining:
            capture("git", "apply", "--check", str(patch), cwd=check)
            capture("git", "apply", str(patch), cwd=check)
    for patch in remaining:
        capture("git", "apply", str(patch), cwd=angle)
        print("Applied patch: " + patch.name)


def verify_production_profile(angle, out, metal_profile="gles30"):
    # Ask GN for the resolved value so an import() in args.gn cannot bypass the
    # package boundary. Internal integration builds deliberately expose only a
    # partial ES 3.1 profile and must never become release artifacts.
    value = capture(str(angle / "buildtools/mac/gn"), "args", str(out),
                    "--list=angle_metal_enable_compute_tests", "--short", cwd=angle)
    if value.strip() != "angle_metal_enable_compute_tests = false":
        raise RuntimeError("Refusing to package an internal Metal compute test profile: " + value)
    selected = capture(str(angle / "buildtools/mac/gn"), "args", str(out),
                       "--list=angle_metal_enable_gles31", "--short", cwd=angle)
    expected = "true" if metal_profile == "gles31" else "false"
    if selected.strip() != "angle_metal_enable_gles31 = " + expected:
        raise RuntimeError("Metal profile does not match the explicitly selected " + metal_profile +
                           " profile: " + selected)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--angle-dir", required=True, type=Path)
    parser.add_argument("--out-dir", type=Path)
    parser.add_argument("--stage-dir", type=Path)
    parser.add_argument("--metal-profile", choices=("gles30", "gles31"), default="gles30",
                        help="Explicitly select the baseline or experimental macOS package profile")
    parser.add_argument("--build-launcher", choices=("ninja", "autoninja"), default="ninja",
                        help="Record the actual launcher; autoninja may select Siso")
    parser.add_argument("--verify-patches", action="store_true",
                        help="Check the complete applied series, preserving unrelated work")
    parser.add_argument("--apply-patches", action="store_true",
                        help="Validate and apply the remaining canonical patch series")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    angle = args.angle_dir.resolve()
    if args.apply_patches:
        try:
            apply_patch_series(root, angle)
        except (RuntimeError, subprocess.CalledProcessError) as error:
            raise SystemExit("Patch series does not apply cleanly: " + str(error))
        return
    if args.verify_patches:
        source_identity(root, angle, allow_unrelated=True)
        return
    if args.out_dir is None or args.stage_dir is None:
        parser.error("--out-dir and --stage-dir are required to write a manifest")
    out = args.out_dir.resolve()
    stage = args.stage_dir.resolve()
    compute_test_profile = verify_production_profile(angle, out, args.metal_profile)
    manifest = {"schema": 1, "source": source_identity(root, angle)}
    manifest["host"] = {"system": platform.system(), "machine": platform.machine(),
                        "macos": platform.mac_ver()[0]}
    manifest["build"] = {
        "gn_args": (out / "args.gn").read_text(),
        "metal_compute_test_profile": compute_test_profile,
        "metal_profile": args.metal_profile,
        "experimental_metal_gles31": args.metal_profile == "gles31",
        "xcode": capture("xcodebuild", "-version"),
        "sdk_path": capture("xcrun", "--sdk", "macosx", "--show-sdk-path"),
        "sdk_version": capture("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "metal": capture("xcrun", "--find", "metal"),
        "metal_version": capture("xcrun", "metal", "--version"),
        "apple_clang": capture("xcrun", "clang", "--version"),
    }
    gn = angle / "buildtools/mac/gn"
    manifest["build"]["gn"] = capture(str(gn), "--version")
    manifest["build"]["ninja"] = capture(str(angle / "third_party/ninja/ninja"), "--version")
    executor = "ninja"
    if args.build_launcher == "autoninja":
        resolved = capture(str(gn), "args", str(out), "--list=use_siso", "--short", cwd=angle)
        if resolved == "use_siso = true":
            executor = "siso"
        elif resolved != "use_siso = false":
            raise RuntimeError("Cannot identify autoninja's build executor: " + resolved)
    executor_version = (capture(str(angle / "third_party/siso/cipd/siso"), "version")
                        if executor == "siso" else manifest["build"]["ninja"])
    manifest["build"]["executor"] = {"launcher": args.build_launcher, "name": executor,
                                      "version": executor_version}
    clang = angle / "third_party/llvm-build/Release+Asserts/bin/clang"
    if clang.is_file():
        manifest["build"]["chromium_clang"] = capture(str(clang), "--version")
    manifest["binaries"] = {}
    for name in ("libEGL.dylib", "libGLESv2.dylib"):
        binary = stage / name
        manifest["binaries"][name] = {
            "sha256": sha256(binary),
            "architectures": capture("lipo", "-archs", str(binary)),
        }
    stage.mkdir(parents=True, exist_ok=True)
    (stage / "ANGLE_BUILD_MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
