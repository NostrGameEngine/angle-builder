#!/usr/bin/env python3
"""Verify that build provenance rejects source drift without altering the index."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("manifest", ROOT / "scripts/write-build-manifest.py")
MANIFEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MANIFEST)


class ManifestTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="angle-manifest-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.angle = self.root / "angle"
        self.angle.mkdir()
        (self.root / "patches").mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Manifest Test")
        self.git("config", "user.email", "manifest@example.invalid")
        (self.angle / "source").write_text("upstream\n")
        (self.angle / "other").write_text("preserved\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Upstream")
        self.pin = self.git("rev-parse", "HEAD")
        (self.root / "ANGLE_COMMIT").write_text(self.pin + "\n")
        (self.angle / "source").write_text("patched\n")
        self.patch = self.root / "patches/compatibility.patch"
        self.patch.write_text(self.git("diff") + "\n")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.angle,
                                       stderr=subprocess.PIPE).decode().strip()

    def test_records_verified_tree_and_preserves_real_index(self):
        before = self.git("write-tree")
        identity = MANIFEST.source_identity(self.root, self.angle)
        self.assertEqual(identity["upstream_commit"], self.pin)
        self.assertNotEqual(identity["patched_tree"], identity["upstream_tree"])
        self.assertEqual(identity["patches"][0]["sha256"], MANIFEST.sha256(self.patch))
        self.assertEqual(self.git("write-tree"), before)

    def test_rejects_drift_in_patched_source(self):
        (self.angle / "source").write_text("unexpected edit\n")
        with self.assertRaisesRegex(RuntimeError, "Source differs"):
            MANIFEST.source_identity(self.root, self.angle)

    def test_rejects_unrecorded_tracked_change(self):
        (self.angle / "other").write_text("unexpected edit\n")
        with self.assertRaisesRegex(RuntimeError, "Unrecorded source changes"):
            MANIFEST.source_identity(self.root, self.angle)

    def test_rejects_wrong_upstream(self):
        (self.root / "ANGLE_COMMIT").write_text("0" * 40 + "\n")
        with self.assertRaisesRegex(RuntimeError, "differs from ANGLE_COMMIT"):
            MANIFEST.source_identity(self.root, self.angle)

    def test_rejects_resolved_internal_profile(self):
        # The input can be imported in args.gn; packaging trusts GN's resolved
        # value rather than scanning the argument file's text.
        with patch.object(MANIFEST, "capture", return_value="angle_metal_enable_compute_tests = true"):
            with self.assertRaisesRegex(RuntimeError, "internal Metal compute test profile"):
                MANIFEST.verify_production_profile(self.angle, self.angle / "out")

    def test_accepts_resolved_production_profile(self):
        with patch.object(MANIFEST, "capture", side_effect=[
                "angle_metal_enable_compute_tests = false", "angle_metal_enable_gles31 = false"]):
            self.assertFalse(MANIFEST.verify_production_profile(self.angle, self.angle / "out"))

    def test_rejects_unselected_gles31_package(self):
        with patch.object(MANIFEST, "capture", side_effect=[
                "angle_metal_enable_compute_tests = false", "angle_metal_enable_gles31 = true"]):
            with self.assertRaisesRegex(RuntimeError, "explicitly selected gles30"):
                MANIFEST.verify_production_profile(self.angle, self.angle / "out")

    def test_accepts_explicit_gles31_package_without_test_profile(self):
        with patch.object(MANIFEST, "capture", side_effect=[
                "angle_metal_enable_compute_tests = false", "angle_metal_enable_gles31 = true"]):
            self.assertFalse(MANIFEST.verify_production_profile(self.angle, self.angle / "out", "gles31"))

    def test_rejects_mislabeled_gles31_package(self):
        with patch.object(MANIFEST, "capture", side_effect=[
                "angle_metal_enable_compute_tests = false", "angle_metal_enable_gles31 = false"]):
            with self.assertRaisesRegex(RuntimeError, "explicitly selected gles31"):
                MANIFEST.verify_production_profile(self.angle, self.angle / "out", "gles31")

    def test_rejects_unrecorded_untracked_file(self):
        (self.angle / "unrecorded.h").write_text("unrecorded header\n")
        with self.assertRaisesRegex(RuntimeError, "Unrecorded source files"):
            MANIFEST.source_identity(self.root, self.angle)


if __name__ == "__main__":
    unittest.main()
