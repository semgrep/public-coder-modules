"""Exercise setup transitions and failure handling with isolated harness fixtures."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1]


class GuardianSetupTests(unittest.TestCase):
    def fixture(self, harness, records=None):
        temporary = tempfile.TemporaryDirectory(prefix="guardian-test-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        binary = root / harness
        shutil.copyfile(MODULE / "tests" / "fake-harness.py", binary)
        binary.chmod(0o755)
        (root / "plugins.json").write_text(json.dumps(records or []))
        # Only the fake harness writes state; HOME and real harness configuration
        # are untouched. jq and python are the actual installed executables.
        env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "GUARDIAN_TEST_STATE": str(root)}
        return root, env

    def run_setup(self, harness, env, success=True):
        result = subprocess.run(
            ["sh", str(MODULE / "scripts" / f"{harness}.sh")],
            env=env, capture_output=True, text=True, timeout=10,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Guardian", result.stderr)
        return result

    def commands(self, root):
        return [json.loads(line) for line in (root / "commands.jsonl").read_text().splitlines()]

    def record(self, harness, enabled=True, scope="user"):
        if harness == "claude":
            return {"id": "semgrep@claude-plugins-official", "scope": scope, "enabled": enabled}
        return {"pluginId": "semgrep@semgrep-marketplace", "installed": True, "enabled": enabled}

    def test_install_repeat_and_removed_plugin(self):
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                root, env = self.fixture(harness)
                self.run_setup(harness, env)
                initial = self.commands(root)
                expected = "install" if harness == "claude" else "add"
                self.assertTrue(any(c[1:3] == ["plugin", expected] for c in initial))
                if harness == "codex":
                    self.assertEqual(initial[1], [
                        "codex", "plugin", "marketplace", "add", "https://github.com/semgrep/guardian",
                        "--sparse", ".claude-plugin", "--sparse", "plugin",
                    ])
                self.run_setup(harness, env)
                repeated = self.commands(root)[len(initial):]
                self.assertFalse(any(c[1:3] == ["plugin", expected] for c in repeated))
                (root / "plugins.json").write_text("[]")
                self.run_setup(harness, env)
                self.assertTrue(json.loads((root / "plugins.json").read_text())[0]["enabled"])

    def test_disabled_plugin_and_unrelated_plugin_preserved(self):
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                key = "id" if harness == "claude" else "pluginId"
                unrelated = {key: "other@team", "installed": True, "enabled": False, "scope": "user"}
                root, env = self.fixture(harness, [unrelated, self.record(harness, enabled=False)])
                self.run_setup(harness, env)
                records = json.loads((root / "plugins.json").read_text())
                self.assertEqual(records[0], unrelated)
                self.assertTrue(records[1]["enabled"])

    def test_existing_claude_marketplace_is_reused(self):
        root, env = self.fixture("claude")
        (root / "marketplace").touch()
        self.run_setup("claude", env)
        self.assertFalse(any(c[1:4] == ["plugin", "marketplace", "add"] for c in self.commands(root)))

    def test_project_install_does_not_replace_claude_user_install(self):
        root, env = self.fixture("claude", [self.record("claude", scope="project")])
        self.run_setup("claude", env)
        records = json.loads((root / "plugins.json").read_text())
        self.assertEqual([r["scope"] for r in records], ["project", "user"])

    def test_listing_failures_and_unsupported_json_stop_before_mutation(self):
        for harness in ("claude", "codex"):
            for flag in ("GUARDIAN_TEST_LIST_FAIL", "GUARDIAN_TEST_BAD_JSON"):
                with self.subTest(harness=harness, flag=flag):
                    root, env = self.fixture(harness)
                    self.run_setup(harness, {**env, flag: "1"}, success=False)
                    self.assertEqual(self.commands(root), [[harness, "plugin", "list", "--json"]])

    def test_installation_failure_and_unsuccessful_verification(self):
        for harness in ("claude", "codex"):
            for flag in ("GUARDIAN_TEST_MUTATION_FAIL", "GUARDIAN_TEST_NO_EFFECT"):
                with self.subTest(harness=harness, flag=flag):
                    _, env = self.fixture(harness)
                    self.run_setup(harness, {**env, flag: "1"}, success=False)

    def test_claude_load_errors_fail_verification(self):
        record = {**self.record("claude"), "errors": ["Plugin cache is missing"]}
        _, env = self.fixture("claude", [record])
        self.run_setup("claude", env, success=False)


if __name__ == "__main__":
    unittest.main()
