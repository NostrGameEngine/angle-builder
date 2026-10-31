#!/usr/bin/env python3
"""Verify ordered, overlapping patches can be reapplied without touching other work."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def git(*args, cwd):
    return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE)


class PatchSeriesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="angle-series-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.angle = self.root / "source"
        self.angle.mkdir()
        self.patches = self.root / "patches"
        self.patches.mkdir()
        (self.root / "scripts").mkdir()
        for name in ("common.sh", "write-build-manifest.py"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        git("init", "-q", cwd=self.angle)
        git("config", "user.name", "Patch Test", cwd=self.angle)
        git("config", "user.email", "patch@example.invalid", cwd=self.angle)
        (self.angle / "source.txt").write_text("one\ntwo\nthree\n")
        (self.angle / "unrelated.txt").write_text("original\n")
        git("add", ".", cwd=self.angle)
        git("commit", "-qm", "Baseline", cwd=self.angle)
        self.pin = git("rev-parse", "HEAD", cwd=self.angle).decode().strip()
        (self.root / "ANGLE_COMMIT").write_text(self.pin + "\n")
        (self.angle / "source.txt").write_text("one\ntwo amended\nthree\n")
        self.first = git("diff", cwd=self.angle)
        (self.patches / "01-first.patch").write_bytes(self.first)
        git("commit", "-qam", "First patch", cwd=self.angle)
        (self.angle / "source.txt").write_text("one\ntwo amended\nextra\nthree\n")
        (self.patches / "02-second.patch").write_bytes(git("diff", cwd=self.angle))
        git("reset", "--hard", self.pin, cwd=self.angle)

    def apply(self):
        env = dict(os.environ, ANGLE_DIR=str(self.angle))
        return subprocess.run(["bash", "-c", 'source "$1"; apply_patches',
                               "patch-test", str(self.root / "scripts/common.sh")],
                              env=env, capture_output=True, text=True)

    def test_overlapping_series_is_idempotent_and_preserves_other_work(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.angle / "unrelated.txt").write_text("user edit\n")
        (self.angle / "user-notes.txt").write_text("untracked edit\n")
        index = (self.angle / ".git/index").read_bytes()
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Complete patch series already applied", result.stdout)
        self.assertEqual((self.angle / "source.txt").read_text(),
                         "one\ntwo amended\nextra\nthree\n")
        self.assertEqual((self.angle / "unrelated.txt").read_text(), "user edit\n")
        self.assertEqual((self.angle / "user-notes.txt").read_text(), "untracked edit\n")
        self.assertEqual((self.angle / ".git/index").read_bytes(), index)

    def test_series_check_accepts_normal_crlf_checkout(self):
        self.assertEqual(self.apply().returncode, 0)
        git("config", "core.autocrlf", "true", cwd=self.angle)
        source = self.angle / "source.txt"
        source.write_bytes(source.read_bytes().replace(b"\n", b"\r\n"))
        before = source.read_bytes()
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Complete patch series already applied", result.stdout)
        self.assertEqual(source.read_bytes(), before)

    def test_existing_prefix_can_be_completed(self):
        subprocess.run(["git", "apply", "-"], input=self.first, cwd=self.angle, check=True)
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.angle / "source.txt").read_text(),
                         "one\ntwo amended\nextra\nthree\n")

    def test_overlapping_prefix_can_be_extended(self):
        self.assertEqual(self.apply().returncode, 0)
        (self.patches / "03-third.patch").write_text(
            "--- a/source.txt\n+++ b/source.txt\n@@ -1,4 +1,4 @@\n"
            " one\n two amended\n-extra\n+extra third\n three\n")
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.angle / "source.txt").read_text(),
                         "one\ntwo amended\nextra third\nthree\n")

    def test_crlf_prefix_can_be_extended(self):
        self.assertEqual(self.apply().returncode, 0)
        git("config", "core.autocrlf", "true", cwd=self.angle)
        source = self.angle / "source.txt"
        source.write_bytes(source.read_bytes().replace(b"\n", b"\r\n"))
        (self.patches / "03-third.patch").write_text(
            "--- a/source.txt\n+++ b/source.txt\n@@ -1,4 +1,4 @@\n"
            " one\n two amended\n-extra\n+extra third\n three\n")
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.read_text(), "one\ntwo amended\nextra third\nthree\n")

    def test_invalid_later_patch_does_not_partially_change_checkout(self):
        subprocess.run(["git", "apply", "-"], input=self.first, cwd=self.angle, check=True)
        before = (self.angle / "source.txt").read_bytes()
        (self.patches / "03-broken.patch").write_text(
            "--- a/unrelated.txt\n+++ b/unrelated.txt\n@@ -1 +1 @@\n"
            "-original\n+replacement\n")
        (self.angle / "unrelated.txt").write_text("user edit outside the applied prefix\n")
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.angle / "source.txt").read_bytes(), before)
        self.assertEqual((self.angle / "unrelated.txt").read_text(),
                         "user edit outside the applied prefix\n")

    def test_edit_to_patched_content_is_rejected_and_preserved(self):
        self.assertEqual(self.apply().returncode, 0)
        (self.angle / "source.txt").write_text("user implementation\n")
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not apply cleanly", result.stderr)
        self.assertEqual((self.angle / "source.txt").read_text(), "user implementation\n")


if __name__ == "__main__":
    unittest.main()
