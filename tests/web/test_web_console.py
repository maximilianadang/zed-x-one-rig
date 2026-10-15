#!/usr/bin/env python3
"""Launcher regression tests. No real SSH, cameras, services, or browser."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOKEN = "a" * 64


class WebConsoleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zed-console-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        # Exercise proper quoting for local repository paths.
        self.root = self.base / "rig with spaces"
        (self.root / "scripts").mkdir(parents=True)
        self.console = self.root / "scripts/zed_web_console.sh"
        shutil.copy2(ROOT / "scripts/zed_web_console.sh", self.console)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.calls = self.base / "calls"
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin",
                        TEST_CALLS=str(self.calls), TEST_TOKEN=TOKEN,
                        TEST_PORT="8877", TEST_FAIL="0", TEST_SSH="0")
        self.executable(self.root / "scripts/zed_web_session.sh", '''
printf 'session\n' >> "$TEST_CALLS"
printf '<%s>\n' "$@" >> "$TEST_CALLS"
echo 'local helper progress' >&2
if [[ "$TEST_FAIL" != 0 ]]; then exit "$TEST_FAIL"; fi
printf 'WEB_PORT=%s\nWEB_TOKEN=%s\n' "$TEST_PORT" "$TEST_TOKEN"
''')
        self.executable(self.bin / "ssh", '''
printf 'ssh\n' >> "$TEST_CALLS"
printf '<%s>\n' "$@" >> "$TEST_CALLS"
[[ "$TEST_SSH" == 1 ]] || exit 91
for arg in "$@"; do
  if [[ "$arg" == -N ]]; then sleep 2; exit 0; fi
done
printf 'WEB_PORT=%s\nWEB_TOKEN=%s\n' "$TEST_PORT" "$TEST_TOKEN"
''')
        self.executable(self.bin / "nc", 'echo nc >> "$TEST_CALLS"; exit 1\n')
        self.executable(self.bin / "open", 'printf "browser <%s>\\n" "$@" >> "$TEST_CALLS"\n')

    def executable(self, path, body):
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def run_console(self, *args):
        return subprocess.run(["bash", str(self.console), *args], env=self.env,
                              text=True, capture_output=True, timeout=10)

    def log(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_local_live_no_ssh_or_port_probe(self):
        result = self.run_console("--local", "--no-open")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"http://127.0.0.1:8877/?mode=live#token={TOKEN}",
                      result.stdout.replace("&token=", "#token="))
        self.assertIn("local helper progress", result.stderr)
        self.assertEqual(self.log(), "session\n<start>\n<--mode>\n<live>\n")

    def test_local_browser_opens(self):
        result = self.run_console("--local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"browser <http://127.0.0.1:8877/?mode=live#token={TOKEN}>",
                      self.log().replace("&token=", "#token="))
        self.assertIn("Closing the browser does not stop recording", result.stdout)

    def test_local_replay(self):
        for options, index in [(["--replay"], "latest"), (["--index", "2"], "2")]:
            with self.subTest(options=options):
                if self.calls.exists(): self.calls.unlink()
                result = self.run_console("--local", "--no-open", *options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"<replay>\n<--index>\n<{index}>\n", self.log())
                self.assertIn("/?mode=replay#token=", result.stdout.replace("&token=", "#token="))
                self.assertNotIn("ssh\n", self.log())

    def test_local_outdoor(self):
        result = self.run_console("--local", "--outdoor", "--no-open")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"<--profile>\n<{self.root}/config/ros2/outdoor.yaml>", self.log())

    def test_invalid_combinations_fail_before_session(self):
        for options in [["--jetson", "zed-jetson"], ["--remote-root", "/tmp/rig"],
                        ["--local-port", "8765"], ["--index", "0"],
                        ["--outdoor", "--replay"]]:
            with self.subTest(options=options):
                result = self.run_console("--local", *options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.log(), "")

    def test_failed_helper_does_not_open_browser(self):
        self.env["TEST_FAIL"] = "7"
        result = self.run_console("--local")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Local Jetson browser session preflight failed", result.stderr)
        self.assertNotIn("browser", self.log())

    def test_bad_gateway_response_does_not_open_browser(self):
        for key, value in [("TEST_PORT", "99999"), ("TEST_TOKEN", "bad-token")]:
            with self.subTest(key=key):
                before = self.env[key]
                self.env[key] = value
                result = self.run_console("--local")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("browser", self.log())
                self.env[key] = before

    def test_remote_tunnel_path_preserved(self):
        self.env["TEST_SSH"] = "1"
        result = self.run_console("--jetson", "zed-jetson", "--remote-root", "/opt/rig",
                                  "--local-port", "8769", "--no-open", "--replay")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log().count("ssh\n"), 2)
        self.assertIn("</opt/rig/scripts/zed_web_session.sh>", self.log())
        self.assertIn("<127.0.0.1:8769:127.0.0.1:8877>", self.log())
        self.assertIn("http://127.0.0.1:8769/?mode=replay#token=",
                      result.stdout.replace("&token=", "#token="))
        self.assertIn("SSH tunnel closed", result.stdout)

    def test_help_documents_local(self):
        result = self.run_console("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("zed_web_console.sh --local", result.stdout)
        self.assertEqual(self.log(), "")


if __name__ == "__main__":
    unittest.main()
