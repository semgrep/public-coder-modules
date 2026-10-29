"""Exercise the Terraform-rendered startup script with real OpenRC and svlogd.

Run with: TERRAFORM_BIN=terraform python3 -m unittest discover -s modules/t3-server/tests -v
Requires Linux, OpenRC user services, svlogd, curl, and Python 3. No real T3
installation is changed; the server fixture has isolated files and a loopback port.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest

MODULE = Path(__file__).resolve().parents[1]
TERRAFORM = os.environ.get("TERRAFORM_BIN", "terraform")

FIXTURE = r'''#!/usr/bin/env python3
import http.server, json, os, pathlib, signal, sys, time
home = pathlib.Path(os.environ["T3_TEST_HOME"])
state = home / ".t3"
# Fixture binaries are named t3-<channel> or t3-<exact stable version>.
release = os.path.basename(os.path.realpath(sys.argv[0]))[len("t3-"):]
version = {"stable": "1.2.3", "nightly": "1.2.3-nightly.1"}.get(release, release)
channel = "nightly" if "nightly" in version else "stable"
if sys.argv[1] == "--version":
    print("t3 v" + version)
    sys.exit(0)
if sys.argv[1] == "update":
    requested = sys.argv[sys.argv.index("--channel") + 1] if "--channel" in sys.argv else channel
    # A channel switch must stop the server first; a same-channel update may
    # install while it runs, like the real updater.
    if requested != channel:
        for row in (state / "events").read_text().splitlines():
            pid = json.loads(row)["pid"]
            try:
                if pathlib.Path(f"/proc/{pid}/cmdline").read_bytes():
                    sys.exit("update attempted while a server was alive")
            except FileNotFoundError:
                pass
    # latest-<channel> names the newest release; the channel binary otherwise.
    latest = state / ("latest-" + requested)
    target = home / ("t3-" + (latest.read_text().strip() if latest.exists() else requested))
    if not target.exists():
        sys.exit(f"no release {target.name}")
    if os.path.realpath(sys.argv[0]) == str(target):
        print("already on the newest release")
        sys.exit(0)
    # Like the real updater: repoint the launcher this was run through.
    launcher = pathlib.Path(sys.argv[0])
    assert launcher.is_symlink(), launcher
    launcher.unlink()
    launcher.symlink_to(target)
    with (state / "updates").open("a") as f: f.write(str(target) + "\n")
    sys.exit(0)
assert sys.argv[1] == "serve"
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ready")
    def log_message(self, *args): pass
server = http.server.HTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Handler)
with (state / "events").open("a") as f:
    f.write(json.dumps({"pid": os.getpid(), "channel": channel, "version": version, "cwd": os.getcwd(),
        "token": os.environ.get("T3_TEST_TOKEN"), "config": os.environ.get("XDG_CONFIG_HOME"),
        "runtime": os.environ.get("XDG_RUNTIME_DIR"), "path": os.environ.get("PATH"),
        "umask": pathlib.Path("/proc/self/status").read_text().split("Umask:\t", 1)[1][:4]}) + "\n")
print("PAIRING_SECRET_SHOULD_NOT_BE_LOGGED", flush=True)
print("server started", file=sys.stderr, flush=True)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
server.timeout = 0.1
while True:
    server.handle_request()
    print("diagnostic " + "x" * 200, file=sys.stderr, flush=True)
'''


@unittest.skipUnless(all(shutil.which(tool) for tool in [TERRAFORM, "rc-service", "openrc", "svlogd"]),
                     "requires Terraform, OpenRC, and svlogd")
class LifecycleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="t3-backend-test-")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".t3").mkdir()
        self.work = self.root / "project with spaces"
        self.work.mkdir()
        self.runtime = self.root / "openrc-runtime"
        self.env = dict(os.environ, T3_TEST_HOME=str(self.home), T3CODE_HOME=str(self.home / ".t3"),
                        T3_TEST_TOKEN="test-secret-value",
                        XDG_CONFIG_HOME=str(self.root / "agent-config"),
                        XDG_RUNTIME_DIR=str(self.root / "agent-runtime"))
        for release in ["stable", "nightly", "1.2.4", "1.2.5"]:
            binary = self.home / ("t3-" + release)
            binary.write_text(FIXTURE)
            binary.chmod(0o700)
        (self.home / ".local/bin/t3").symlink_to(self.home / "t3-stable")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        # Evaluate the exact production heredoc with Terraform, without a
        # provider or a Coder account. Redirect its home/runtime paths only.
        source = (MODULE / "main.tf").read_text()
        script = source.split("  script = <<-EOT\n", 1)[1].split("\n  EOT", 1)[0]
        (self.root / "main.tf").write_text("locals {\nscript = <<-EOT\n" + script + "\nEOT\n}\n")
        shutil.copy(MODULE / "variables.tf", self.root)
        shutil.copy(MODULE / "openrc.sh", self.root)
        shutil.copy(MODULE / "initial-settings.sh", self.root)

    def render(self, backend, channel="stable", rotation=None, update_on_start=False):
        args = [TERRAFORM, "console", "-var=agent_id=test", f"-var=server_backend={backend}",
                f"-var=channel={channel}", f"-var=port={self.port}",
                f"-var=working_directory={self.work}", f"-var=log_directory={self.root}/logs",
                f"-var=update_on_start={str(update_on_start).lower()}"]
        if rotation is not None:
            args.append("-var=log_rotation=" + json.dumps(rotation))
        result = subprocess.run(args, cwd=self.root, input="jsonencode(local.script)\n",
                                capture_output=True, text=True, timeout=20, check=True)
        script = json.loads(json.loads(result.stdout))
        self.assertTrue(script.startswith("#!/bin/sh\n"))
        script = script.replace("$HOME", "$T3_TEST_HOME")
        script = script.replace('/tmp/t3-openrc-$(id -u)', str(self.runtime))
        return script

    def start(self, backend, channel="stable", rotation=None, expected=0, update_on_start=False):
        result = subprocess.run(["sh"], input=self.render(backend, channel, rotation, update_on_start), env=self.env,
                                text=True, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("PAIRING_SECRET", result.stdout + result.stderr)
        return result

    def events(self):
        path = self.home / ".t3/events"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def wait_for(self, predicate):
        for _ in range(100):
            if predicate(): return
            time.sleep(0.1)
        self.fail("timed out waiting for lifecycle transition")

    def rc(self, *args):
        env = dict(self.env, XDG_CONFIG_HOME=str(self.home / ".t3/openrc-config"),
                   XDG_RUNTIME_DIR=str(self.runtime))
        return subprocess.run(["rc-service", "--user", *args], env=env,
                              text=True, capture_output=True, timeout=40)

    def tearDown(self):
        if self.runtime.exists():
            self.rc("--ifstarted", "t3-server", "stop")
        for event in self.events():
            try: os.kill(event["pid"], signal.SIGTERM)
            except ProcessLookupError: pass
        self.temp.cleanup()

    def test_backends_respawn_and_channel_switch(self):
        self.start("nohup")
        self.start("nohup")
        self.assertEqual(len(self.events()), 1)
        self.start("openrc")
        self.assertEqual(len(self.events()), 2)
        event = self.events()[-1]
        self.assertEqual(event["token"], "test-secret-value")
        self.assertEqual(event["cwd"], str(self.work))
        self.assertEqual(event["config"], self.env["XDG_CONFIG_HOME"])
        self.assertEqual(event["runtime"], self.env["XDG_RUNTIME_DIR"])
        self.assertTrue(event["path"].startswith(f"{self.home}/.local/bin:"), event["path"])
        self.assertEqual(event["umask"], "0022")
        config = self.home / ".t3/openrc-config/rc/rc.conf"
        self.assertNotIn("test-secret-value", config.read_text())
        self.start("openrc")
        self.assertEqual(len(self.events()), 2)
        os.kill(event["pid"], signal.SIGKILL)
        self.wait_for(lambda: len(self.events()) == 3)
        self.start("openrc", "nightly")
        self.assertEqual(self.events()[-1]["channel"], "nightly")
        self.assertEqual(len((self.home / ".t3/updates").read_text().splitlines()), 1)
        self.start("nohup", "nightly")
        self.assertEqual(self.rc("t3-server", "status").returncode, 3)
        count = len(self.events())
        self.start("nohup", "nightly")
        self.assertEqual(len(self.events()), count)
        self.assertNotIn("PAIRING_SECRET", (self.root / "logs/server.log").read_text())

    def updates(self):
        path = self.home / ".t3/updates"
        return path.read_text().splitlines() if path.exists() else []

    def t3(self, *args):
        return subprocess.run([self.home / ".local/bin/t3", *args], env=self.env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=40, check=True).stdout

    def test_update_on_start(self):
        self.start("openrc", update_on_start=True)
        self.assertEqual(len(self.events()), 1)
        self.assertEqual(self.updates(), [])
        # A newer release is installed and the running server restarted on it.
        (self.home / ".t3/latest-stable").write_text("1.2.4")
        self.start("openrc", update_on_start=True)
        self.assertEqual(len(self.events()), 2)
        self.assertEqual(self.events()[-1]["version"], "1.2.4")
        # An unchanged release does not restart the server.
        self.start("openrc", update_on_start=True)
        self.assertEqual(len(self.events()), 2)
        # A failed update keeps serving the installed release.
        (self.home / ".t3/latest-stable").write_text("missing")
        result = self.start("openrc", update_on_start=True)
        self.assertIn("Could not update T3 Code", result.stderr)
        self.assertEqual(len(self.events()), 2)
        self.assertEqual(self.t3("--version"), "t3 v1.2.4\n")

    def test_update_command_restarts_openrc(self):
        self.start("openrc")
        # From a script without --yes, the server is left alone with a hint.
        (self.home / ".t3/latest-stable").write_text("1.2.4")
        self.assertIn("rc-service --user t3-server restart", self.t3("update"))
        self.assertEqual(len(self.events()), 1)
        # --yes restarts the supervised server on the new release.
        (self.home / ".t3/latest-stable").write_text("1.2.5")
        self.t3("update", "--yes")
        self.wait_for(lambda: len(self.events()) == 2)
        self.assertEqual(self.events()[-1]["version"], "1.2.5")
        self.assertEqual(self.rc("t3-server", "status").returncode, 0)
        # Nothing to install: no restart.
        self.t3("update", "--yes")
        time.sleep(1)
        self.assertEqual(len(self.events()), 2)

    def test_rotation_and_logging_reconfiguration(self):
        self.start("openrc")
        self.start("openrc", rotation={"max_size_bytes": 2000, "interval_seconds": 1, "retained_files": 2})
        self.assertEqual(len(self.events()), 2)  # Logging changes restart the service.
        os.kill(self.events()[-1]["pid"], signal.SIGKILL)
        self.wait_for(lambda: len(self.events()) == 3)
        logdir = self.root / "logs"
        self.wait_for(lambda: len(list(logdir.glob("@*.s"))) >= 2)
        time.sleep(2)
        self.assertEqual(len(list(logdir.glob("@*.s"))), 2)
        for path in [logdir / "current", *logdir.glob("@*.s")]:
            self.assertNotIn("PAIRING_SECRET", path.read_text())
        self.assertEqual(logdir.stat().st_mode & 0o777, 0o700)
        self.rc("t3-server", "stop")
        self.assertEqual(self.rc("t3-server", "status").returncode, 3)
        count = len(self.events())
        time.sleep(3)
        self.assertEqual(len(self.events()), count)

    def test_refuses_to_adopt_an_unmanaged_server(self):
        self.start("nohup")
        (self.home / ".t3/server.pid").unlink()
        result = self.start("openrc", expected=1)
        self.assertIn("outside the OpenRC service", result.stderr)
        self.assertEqual(len(self.events()), 1)
