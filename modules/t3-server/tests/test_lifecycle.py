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
channel = "nightly" if "nightly" in sys.argv[0] else "stable"
if sys.argv[1] == "--version":
    print("t3 v1.2.3" + ("-nightly.1" if channel == "nightly" else ""))
    sys.exit(0)
if sys.argv[1] == "update":
    for row in (state / "events").read_text().splitlines():
        pid = json.loads(row)["pid"]
        try:
            if pathlib.Path(f"/proc/{pid}/cmdline").read_bytes():
                sys.exit("update attempted while a server was alive")
        except FileNotFoundError:
            pass
    target = home / ("t3-" + sys.argv[sys.argv.index("--channel") + 1])
    shim = home / ".local/bin/t3"
    shim.unlink()
    shim.symlink_to(target)
    with (state / "updates").open("a") as f: f.write(str(target) + "\n")
    sys.exit(0)
assert sys.argv[1] == "serve"
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ready")
    def log_message(self, *args): pass
server = http.server.HTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Handler)
with (state / "events").open("a") as f:
    f.write(json.dumps({"pid": os.getpid(), "channel": channel, "cwd": os.getcwd(),
        "token": os.environ.get("T3_TEST_TOKEN"), "config": os.environ.get("XDG_CONFIG_HOME"),
        "runtime": os.environ.get("XDG_RUNTIME_DIR")}) + "\n")
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
        self.env = dict(os.environ, T3_TEST_HOME=str(self.home), T3_TEST_TOKEN="test-secret-value",
                        XDG_CONFIG_HOME=str(self.root / "agent-config"),
                        XDG_RUNTIME_DIR=str(self.root / "agent-runtime"))
        for channel in ["stable", "nightly"]:
            binary = self.home / ("t3-" + channel)
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

    def render(self, backend, channel="stable", rotation=None):
        args = [TERRAFORM, "console", "-var=agent_id=test", f"-var=server_backend={backend}",
                f"-var=channel={channel}", f"-var=port={self.port}",
                f"-var=working_directory={self.work}", f"-var=log_directory={self.root}/logs"]
        if rotation is not None:
            args.append("-var=log_rotation=" + json.dumps(rotation))
        result = subprocess.run(args, cwd=self.root, input="jsonencode(local.script)\n",
                                capture_output=True, text=True, timeout=20, check=True)
        script = json.loads(json.loads(result.stdout))
        self.assertTrue(script.startswith("#!/bin/sh\n"))
        script = script.replace("$HOME", "$T3_TEST_HOME")
        script = script.replace('/tmp/t3-openrc-$(id -u)', str(self.runtime))
        return script

    def start(self, backend, channel="stable", rotation=None, expected=0):
        result = subprocess.run(["sh"], input=self.render(backend, channel, rotation), env=self.env,
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
