"""Run the production settings initialization rendered by Terraform, in isolation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1]
TERRAFORM = os.environ.get("TERRAFORM_BIN", "terraform")
CALLER_SETTINGS = {
    "defaultModelSelection": {"instanceId": "codex", "model": "gpt-6.1-sol"},
    "defaultRuntimeMode": "auto", "defaultThreadEnvMode": "worktree",
    "addProjectBaseDirectory": "~/git",
}


@unittest.skipUnless(shutil.which(TERRAFORM), "requires Terraform")
class InitialSettingsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="t3-settings-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home with spaces"
        self.state = self.home / ".t3/userdata"
        self.settings = self.state / "settings.json"
        self.env = dict(os.environ, HOME=str(self.home))
        self.env.pop("T3CODE_HOME", None)
        source = (MODULE / "main.tf").read_text()
        # Render and execute the actual startup prefix, stopping before OpenRC,
        # installation, or any command that could touch the real T3 installation.
        script = source.split("  script = <<-EOT\n", 1)[1]
        script = script.split('    ${file("${path.module}/openrc.sh")}', 1)[0]
        (self.root / "main.tf").write_text("locals {\nscript = <<-EOT\n" + script + "\nEOT\n}\n")
        shutil.copy(MODULE / "variables.tf", self.root)
        shutil.copy(MODULE / "initial-settings.sh", self.root)

    def render(self, settings="default"):
        args = [TERRAFORM, "console", "-var=agent_id=test"]
        if settings != "default":
            args.append("-var=initial_settings=" + json.dumps(settings))
        result = subprocess.run(args, cwd=self.root, input="jsonencode(local.script)\n",
                                capture_output=True, text=True, timeout=20, check=True)
        return json.loads(json.loads(result.stdout))

    def start(self, settings="default"):
        result = subprocess.run(["sh"], input=self.render(settings), env=self.env, cwd=self.root,
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_module_defaults_are_empty(self):
        self.start()
        self.assertEqual(json.loads(self.settings.read_text()), {})
        self.assertFalse((self.home / "git").exists())

    def test_caller_settings_and_user_resets_survive_repeated_runs(self):
        self.start(CALLER_SETTINGS)
        self.assertEqual(json.loads(self.settings.read_text()), CALLER_SETTINGS)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)
        custom = '{"defaultRuntimeMode":"full-access"}\n'
        self.settings.write_text(custom)
        self.start({"defaultRuntimeMode": "auto", "branchNamePrefix": "new-default"})
        self.assertEqual(self.settings.read_text(), custom)
        self.settings.unlink()
        self.state.rmdir()
        self.start(CALLER_SETTINGS)
        self.assertFalse(self.state.exists())

    def test_existing_installations_are_never_seeded(self):
        for content in ['{}', '{"defaultModelSelection":null}', 'not valid JSON']:
            with self.subTest(content=content):
                (self.state.parent / "initial-settings-initialized").unlink(missing_ok=True)
                self.state.mkdir(parents=True, exist_ok=True)
                self.settings.write_text(content)
                self.start(CALLER_SETTINGS)
                self.assertEqual(self.settings.read_text(), content)

    def test_existing_database_without_settings_is_preserved(self):
        self.state.mkdir(parents=True)
        (self.state / "statev2.sqlite").touch()
        self.start(CALLER_SETTINGS)
        self.assertFalse(self.settings.exists())

    def test_linked_userdata_is_preserved(self):
        self.state.parent.mkdir(parents=True)
        self.state.symlink_to(self.root / "missing-userdata", target_is_directory=True)
        self.start(CALLER_SETTINGS)
        self.assertTrue(self.state.is_symlink())
        self.assertFalse((self.root / "missing-userdata").exists())

    def test_empty_existing_userdata_is_preserved(self):
        self.state.mkdir(parents=True)
        self.start(CALLER_SETTINGS)
        self.assertFalse(self.settings.exists())

    def test_disabled_initialization_stays_disabled(self):
        self.start(None)
        self.start(CALLER_SETTINGS)
        self.assertFalse(self.settings.exists())

    def test_custom_object_is_not_merged_and_is_shell_safe(self):
        custom = {"branchNamePrefix": "$(touch bad)`touch bad`'\"\n", "enableDeviceSupport": False,
                  "providerInstances": {}, "favorites": None}
        self.start(custom)
        self.assertEqual(json.loads(self.settings.read_text()), custom)
        self.assertFalse((self.root / "bad").exists())

    def test_custom_data_home(self):
        custom_home = self.root / "custom-data"
        self.env["T3CODE_HOME"] = str(custom_home)
        self.start(CALLER_SETTINGS)
        self.assertTrue((custom_home / "userdata/settings.json").exists())
        self.assertFalse(self.settings.exists())

    def test_concurrent_initialization(self):
        script = self.render(CALLER_SETTINGS)
        processes = [subprocess.Popen(["sh"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, env=self.env, cwd=self.root)
                     for _ in range(3)]
        for process in processes:
            process.stdin.write(script)
            process.stdin.close()
            process.stdin = None
        results = [process.communicate(timeout=40) for process in processes]
        for process, (stdout, stderr) in zip(processes, results):
            self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertEqual(json.loads(self.settings.read_text())["defaultRuntimeMode"], "auto")
