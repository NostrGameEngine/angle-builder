#!/usr/bin/env python3
"""Verify CTS corrections follow the ANGLE gitlink and preserve checkout edits."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cts_patches", ROOT / "scripts/prepare-cts-tests.py")
cts_patches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cts_patches)


def git(*args, cwd):
    return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE).decode().strip()


class CTSPatchesTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="angle-cts-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.angle = self.root / "angle"
        self.cts = self.angle / "third_party/VK-GL-CTS/src"
        self.cts.mkdir(parents=True)
        for repo in (self.angle, self.cts):
            git("init", "-q", cwd=repo)
            git("config", "user.name", "CTS Test", cwd=repo)
            git("config", "user.email", "cts@example.invalid", cwd=repo)
        (self.cts / "executor.cpp").write_text("original\n")
        git("add", ".", cwd=self.cts)
        git("commit", "-qm", "Pinned CTS", cwd=self.cts)
        self.cts_pin = git("rev-parse", "HEAD", cwd=self.cts)
        git("update-index", "--add", "--cacheinfo", "160000", self.cts_pin,
            "third_party/VK-GL-CTS/src", cwd=self.angle)
        git("commit", "-qm", "Pin CTS gitlink", cwd=self.angle)
        (self.root / "ANGLE_COMMIT").write_text(git("rev-parse", "HEAD", cwd=self.angle) + "\n")
        patches = self.root / "patches-cts"
        patches.mkdir()
        (patches / "01-transport.patch").write_text(
            "--- a/executor.cpp\n+++ b/executor.cpp\n@@ -1 +1 @@\n-original\n+bit transport\n")

    def test_apply_and_repeat_preserve_real_indexes(self):
        angle_index = (self.angle / ".git/index").read_bytes()
        cts_index = (self.cts / ".git/index").read_bytes()
        first = cts_patches.prepare(self.root, self.angle, apply=True)
        second = cts_patches.prepare(self.root, self.angle, apply=True)
        self.assertEqual(first, second)
        self.assertEqual(first["upstream_commit"], self.cts_pin)
        self.assertEqual(first["patches"][0]["name"], "01-transport.patch")
        self.assertEqual((self.cts / "executor.cpp").read_text(), "bit transport\n")
        self.assertEqual((self.angle / ".git/index").read_bytes(), angle_index)
        self.assertEqual((self.cts / ".git/index").read_bytes(), cts_index)

    def test_conflicting_edit_is_rejected_and_preserved(self):
        (self.cts / "executor.cpp").write_text("user edit\n")
        with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
            cts_patches.prepare(self.root, self.angle, apply=True)
        self.assertEqual((self.cts / "executor.cpp").read_text(), "user edit\n")

    def test_unpinned_cts_commit_is_rejected_before_edit(self):
        git("commit", "--allow-empty", "-qm", "Unpinned CTS", cwd=self.cts)
        with self.assertRaisesRegex(RuntimeError, "checkout differs"):
            cts_patches.prepare(self.root, self.angle, apply=True)
        self.assertEqual((self.cts / "executor.cpp").read_text(), "original\n")


if __name__ == "__main__":
    unittest.main()
