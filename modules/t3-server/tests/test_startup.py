"""Exercise the rendered Coder startup script with a local T3 launcher stub."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1]
TEMPLATE = (MODULE / "main.tf").read_text().split("script = <<-EOT\n", 1)[1].split("\n  EOT", 1)[0]
TEMPLATE = "\n".join(line[4:] for line in TEMPLATE.splitlines())


def write_executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)


class StartupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.events = self.root / "events"
        write_executable(
            self.bin / "curl",
            '#!/bin/sh\ncase "$*" in *install.sh*) cat "$MOCK_INSTALLER" ;; *) '
            '[ -f "$HOME/.t3/ready" ] ;; esac\n',
        )
        write_executable(self.bin / "openrc-run", '#!/bin/sh\nexit 0\n')
        write_executable(self.bin / "supervise-daemon", '#!/bin/sh\nexit 0\n')
        write_executable(
            self.bin / "rc-service",
            '#!/bin/sh\n'
            'case "$3" in\n'
            '  status) [ -f "$HOME/.t3/openrc-running" ] ;;\n'
            '  stop) echo "service stop" >> "$MOCK_EVENTS"; '
            'rm -f "$HOME/.t3/openrc-running" "$HOME/.t3/ready" ;;\n'
            '  start) echo "service start" >> "$MOCK_EVENTS"; '
            '"$HOME/.t3/serve-openrc"; touch "$HOME/.t3/openrc-running" ;;\n'
            '  *) exit 1 ;;\n'
            'esac\n',
        )
        self.installer = self.root / "installer"
        self.installer.write_text(
            '#!/bin/sh\n'
            'printf "install %s %s\\n" "${T3CODE_CHANNEL:-}" "${T3CODE_VERSION:-}" >> "$MOCK_EVENTS"\n'
            'case "${T3CODE_VERSION:-${T3CODE_CHANNEL:-stable}}" in '
            'nightly|*-nightly.*) target=nightly ;; *) target=stable ;; esac\n'
            'mkdir -p "$HOME/.local/bin"\n'
            'ln -sfn "$MOCK_ROOT/$target" "$HOME/.local/bin/t3"\n'
        )
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:/usr/bin:/bin",
                        XDG_RUNTIME_DIR=str(self.runtime), XDG_CONFIG_HOME=str(self.home / '.config'),
                        MOCK_ROOT=str(self.root), MOCK_EVENTS=str(self.events),
                        MOCK_INSTALLER=str(self.installer))
        for channel, version in (("stable", "0.0.46"), ("nightly", "0.0.46-nightly.20261005.1")):
            other = "nightly" if channel == "stable" else "stable"
            write_executable(
                self.root / channel,
                '#!/bin/sh\n'
                f'case "$1" in\n'
                f'  --version) echo "t3 v{version}" ;;\n'
                '  update) printf "update %s\\n" "$*" >> "$MOCK_EVENTS"; '
                'ln -sfn "$MOCK_ROOT/$3" "$HOME/.local/bin/t3" ;;\n'
                '  serve) echo "serve $0" >> "$MOCK_EVENTS"; '
                'touch "$HOME/.t3/ready" ;;\n'
                '  *) exit 1 ;;\n'
                'esac\n',
            )

    def installed(self, channel):
        local_bin = self.home / ".local/bin"
        local_bin.mkdir(parents=True, exist_ok=True)
        (local_bin / "t3").symlink_to(self.root / channel)

    def start(self, channel="stable", version=None, expected_status=0):
        script = TEMPLATE
        replacements = {
            '${var.t3_version == null ? "curl -fsSL https://t3.codes/install.sh | T3CODE_CHANNEL=${var.channel} sh" : "curl -fsSL https://t3.codes/install.sh | T3CODE_VERSION=${var.t3_version} sh"}':
                'curl -fsSL https://t3.codes/install.sh | '
                + (f'T3CODE_VERSION={version} sh' if version else f'T3CODE_CHANNEL={channel} sh'),
            '${var.port}': '3773',
            '${var.working_directory}': str(self.home),
            '${base64encode(join("\\n", [for repository in var.initial_repositories : "${repository.url}\\t${repository.directory}"]))}': '',
            '${var.channel}': channel,
            '${var.t3_version == null ? "" : var.t3_version}': version or '',
            '${var.public_domain}': '',
        }
        for original, replacement in replacements.items():
            script = script.replace(original, replacement)
        script = script.replace('$${', '${')
        self.assertNotIn('${var.', script)
        path = self.root / 'startup.sh'
        path.write_text(script)
        result = subprocess.run(['/bin/sh', str(path)], env=self.env, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, expected_status, result.stderr)
        return self.events.read_text().splitlines() if self.events.exists() else []

    def test_first_install_uses_selected_channel(self):
        events = self.start('nightly')
        self.assertIn('install nightly ', events)
        self.assertFalse(any(line.startswith('update ') for line in events))

    def test_stable_to_nightly(self):
        self.installed('stable')
        events = self.start('nightly')
        self.assertIn('update update --channel nightly --allow-downgrade --yes', events)
        self.assertIn('serve ' + str(self.root / 'nightly'), events)
        self.assertIn('service start', events)
        self.assertIn('supervisor=supervise-daemon',
                      (self.home / '.config/rc/init.d/t3-code').read_text())
        self.assertFalse((self.home / '.t3/server.pid').exists())

    def test_nightly_to_stable(self):
        self.installed('nightly')
        events = self.start('stable')
        self.assertIn('update update --channel stable --allow-downgrade --yes', events)
        self.assertIn('serve ' + str(self.root / 'stable'), events)

    def test_unchanged_channel_does_not_update(self):
        self.installed('nightly')
        events = self.start('nightly')
        self.assertFalse(any(line.startswith(('install ', 'update ')) for line in events))

    def test_openrc_service_stops_before_switch_and_stays_up_when_unchanged(self):
        self.installed('stable')
        self.start('stable')
        self.events.unlink()
        events = self.start('nightly')
        self.assertLess(events.index('service stop'),
                        events.index('update update --channel nightly --allow-downgrade --yes'))
        self.assertLess(events.index('update update --channel nightly --allow-downgrade --yes'),
                        events.index('service start'))
        self.events.unlink()
        events = self.start('nightly')
        self.assertFalse(any(line.startswith(('service ', 'update ')) for line in events))

    def test_openrc_service_restarts_when_server_configuration_changes(self):
        self.installed('stable')
        self.start('stable')
        (self.home / '.t3/service-config').write_text('9000|/old/project\n')
        self.events.unlink()
        events = self.start('stable')
        self.assertIn('service stop', events)
        self.assertIn('service start', events)
        self.assertFalse(any(line.startswith('update ') for line in events))

    def test_unknown_running_server_blocks_switch(self):
        self.installed('stable')
        (self.home / '.t3').mkdir()
        (self.home / '.t3/ready').touch()
        events = self.start('nightly', expected_status=1)
        self.assertFalse(any(line.startswith('update ') for line in events))

    def test_exact_version_takes_precedence_and_disables_switch(self):
        events = self.start('nightly', '0.0.46')
        self.assertIn('install  0.0.46', events)
        self.assertFalse(any(line.startswith('update ') for line in events))
        self.events.unlink()
        events = self.start('nightly', '0.0.46')
        self.assertFalse(any(line.startswith(('install ', 'update ')) for line in events))


if __name__ == '__main__':
    unittest.main()
