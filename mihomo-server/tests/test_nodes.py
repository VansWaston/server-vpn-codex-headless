import base64
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('nodes', ROOT / 'scripts/nodes.py')
nodes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nodes)


class NodeTests(unittest.TestCase):
    def test_provider_formats(self):
        name = '[vless]🇺🇸+UnitedStates3+×1'
        uri = 'vless://dummy@example.invalid:443#' + name
        for text in [uri, base64.b64encode(uri.encode()).decode().rstrip('='),
                     'proxies:\n  - name: "' + name + '"\n    type: vless\n']:
            self.assertEqual(nodes.node_names(text), [name])

    def test_duplicate_and_unnamed_nodes(self):
        for text in ['vless://dummy@example.invalid:443',
                     'proxies:\n  - name: duplicate\n  - name: duplicate\n']:
            with self.assertRaises(ValueError):
                nodes.node_names(text)

    def test_commands_and_failed_validation_preserve_config(self):
        # Use the real Mihomo validator without starting any listener.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for directory_name in ['scripts', 'bin', 'config', 'home/providers']:
                (root / directory_name).mkdir(parents=True)
            for filename in ['scripts/mihomoctl', 'scripts/nodes.py', 'config/config.template.yaml']:
                (root / filename).write_bytes((ROOT / filename).read_bytes())
            (root / 'bin/mihomo').symlink_to(ROOT / 'bin/mihomo')
            config = root / 'home/config.yaml'
            config.write_bytes((ROOT / 'config/config.template.yaml').read_bytes())
            provider = root / 'home/providers/subscription.yaml'
            name = 'test [node]+ name'
            provider.write_text('proxies:\n  - name: "' + name + '"\n    type: socks5\n    server: 127.0.0.1\n    port: 1\n')

            def run(*args):
                return subprocess.run(['bash', str(root / 'scripts/mihomoctl'), *args],
                                      capture_output=True, text=True)

            self.assertEqual(run('nodes').stdout.strip(), name)
            result = run('node', name)
            self.assertEqual(result.returncode, 0, result.stderr)
            parsed = nodes.yaml.safe_load(config.read_text())
            self.assertEqual(parsed['proxy-groups'][0]['filter'], '^test\\ \\[node\\]\\+\\ name$')
            previous = config.read_bytes()
            self.assertNotEqual(run('node', 'missing').returncode, 0)
            self.assertNotEqual(run('node').returncode, 0)
            self.assertNotEqual(run('node', name, 'extra').returncode, 0)
            self.assertEqual(config.read_bytes(), previous)
            config.write_text(config.read_text().replace('mixed-port: 7890', 'mixed-port: invalid'))
            invalid_config = config.read_bytes()
            self.assertNotEqual(run('node', name).returncode, 0)
            self.assertEqual(config.read_bytes(), invalid_config)
            config.write_bytes(previous)
            provider.write_text('proxies:\n  - name: test\n    type: socks5\n    server: 127.0.0.1\n    port: 1\n')
            result = run('node', '--auto')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('filter', nodes.yaml.safe_load(config.read_text())['proxy-groups'][0])
            previous = config.read_bytes()
            driver = r"""
ctl="$1"
shift
source "$ctl" >/dev/null
managed_pids() { printf '123\n'; }
restart_unlocked() {
  if [[ ! -f "$RUN_DIR/restart-attempt" ]]; then
    touch "$RUN_DIR/restart-attempt"
    die 'simulated start failure'
  fi
  touch "$RUN_DIR/recovery-attempt"
}
with_control_lock switch_node test
"""
            result = subprocess.run(['bash', '-c', driver, 'test', str(root / 'scripts/mihomoctl')],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_bytes(), previous)
            self.assertTrue((root / 'run/recovery-attempt').exists())



if __name__ == '__main__':
    unittest.main()
