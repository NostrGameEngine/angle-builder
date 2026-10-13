#!/usr/bin/env python3
"""Exercise checkout pinning and preservation with real Git and a fake gclient."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def git(*args, cwd):
    return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE).decode().strip()


class CheckoutTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="angle-checkout-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        git("init", "-q", cwd=self.source)
        git("config", "user.name", "Checkout Test", cwd=self.source)
        git("config", "user.email", "checkout@example.invalid", cwd=self.source)
        (self.source / "file").write_text("pinned\n")
        git("add", ".", cwd=self.source)
        git("commit", "-qm", "Pinned source", cwd=self.source)
        self.pin = git("rev-parse", "HEAD", cwd=self.source)
        (self.source / "file").write_text("latest\n")
        git("commit", "-qam", "Latest source", cwd=self.source)
        self.latest = git("rev-parse", "HEAD", cwd=self.source)
        self.angle = self.base / "angle"
        self.depot = self.base / "depot_tools"
        (self.depot / ".git").mkdir(parents=True)
        self.log = self.base / "commands.log"
        gclient = self.depot / "gclient"
        gclient.write_text("""#!/usr/bin/env python3
import ast, os, pathlib, subprocess, sys
args = sys.argv[1:]
with open(os.environ['CHECKOUT_LOG'], 'a') as log:
    log.write(' '.join(args) + '\\n')
if args[0] == 'config':
    spec = args[args.index('--spec') + 1]
    solution = ast.literal_eval(spec.split('=', 1)[1])[0]
    assert solution['name'] == '.' and not solution['managed']
    pathlib.Path('.gclient').write_text(spec)
elif args[0] == 'sync' and not pathlib.Path('.git').exists():
    revision = args[args.index('--revision') + 1]
    assert revision.startswith('.@') and '--no-history' in args
    subprocess.run(['git', 'init', '-q'], check=True)
    subprocess.run(['git', 'fetch', '-q', os.environ['CHECKOUT_SOURCE'], revision[2:]], check=True)
    subprocess.run(['git', 'checkout', '-q', '--detach', 'FETCH_HEAD'], check=True)
else:
    assert args == ['sync']
""")
        gclient.chmod(0o755)
        self.env = dict(os.environ, ANGLE_DIR=str(self.angle),
                        DEPOT_TOOLS_DIR=str(self.depot), ANGLE_PINNED_COMMIT=self.pin,
                        ANGLE_SKIP_SYNC="0", CHECKOUT_SOURCE=str(self.source),
                        CHECKOUT_LOG=str(self.log))

    def run_checkout(self):
        return subprocess.run(["bash", "-c", 'source "$1"; ensure_angle_checkout',
                               "checkout-test", str(ROOT / "scripts/common.sh")],
                              env=self.env, capture_output=True, text=True)

    def clone_latest(self):
        git("clone", "-q", str(self.source), str(self.angle), cwd=self.base)

    def test_fresh_checkout_syncs_only_the_pin(self):
        result = self.run_checkout()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.angle), self.pin)
        self.assertEqual(self.log.read_text().count("sync"), 1)
        self.assertIn("--no-history --revision .@" + self.pin, self.log.read_text())

    def test_modified_source_is_preserved(self):
        self.clone_latest()
        (self.angle / "file").write_text("local edit\n")
        result = self.run_checkout()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to change", result.stderr)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.angle), self.latest)
        self.assertEqual((self.angle / "file").read_text(), "local edit\n")
        self.assertFalse(self.log.exists())

    def test_dependency_gitlink_does_not_block_revision_change(self):
        self.clone_latest()
        git("config", "user.name", "Checkout Test", cwd=self.angle)
        git("config", "user.email", "checkout@example.invalid", cwd=self.angle)
        git("clone", "-q", str(self.source), str(self.angle / "dependency"), cwd=self.base)
        git("update-index", "--add", "--cacheinfo", "160000," + self.pin + ",dependency", cwd=self.angle)
        git("commit", "-qm", "Dependency gitlink", cwd=self.angle)
        self.assertIn("dependency", git("status", "--porcelain", cwd=self.angle))
        result = self.run_checkout()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.angle), self.pin)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.angle / "dependency"), self.latest)
        self.assertEqual(self.log.read_text().strip(), "sync")

    def test_non_repository_is_preserved(self):
        self.angle.mkdir()
        (self.angle / "file").write_text("local directory\n")
        result = self.run_checkout()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a git checkout", result.stderr)
        self.assertEqual((self.angle / "file").read_text(), "local directory\n")


if __name__ == "__main__":
    unittest.main()
