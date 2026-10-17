"""Offline integration tests: real installer, Screen and runner; fake Codex API."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SESSION = '11111111-2222-3333-4444-555555555555'
FAKE_CODEX = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
if args == ['--version']:
    print('codex-cli 0.162.1')
elif args[:1] == ['login']:
    print('Logged in (offline fixture)')
else:
    assert args[0] == 'exec', args
    assert '--sandbox' in args, args
    assert '--approve-for-me' not in args, args
    assert os.environ['HTTP_PROXY'].endswith(':18791'), os.environ['HTTP_PROXY']
    assert os.environ['ALL_PROXY'] == 'socks5h://127.0.0.1:18791'
    assert pathlib.Path(os.environ['CODEX_HOME']).name == 'codex home'
    prompt = sys.stdin.read()
    if 'fail fixture' in prompt:
        print('offline failure', file=sys.stderr)
        sys.exit(7)
    final = pathlib.Path(args[args.index('-o') + 1])
    if 'resume' in args:
        assert args[-2] == '11111111-2222-3333-4444-555555555555', args
    print(json.dumps({'type':'thread.started','thread_id':'11111111-2222-3333-4444-555555555555'}), flush=True)
    time.sleep(0.3)
    final.write_text('offline result\\n')
    print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'offline result'}}))
    print(json.dumps({'type':'turn.completed'}))
'''


class PortableTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='server toolkit tests ')
        self.base = Path(self.temporary.name)
        self.home = self.base / 'user home'
        self.home.mkdir()
        self.prefix = self.base / 'installed tools'
        self.bin = self.base / 'command bin'
        self.state = self.base / 'private state'
        self.mihomo = self.base / 'existing proxy'
        self.codex = self.base / 'codex executable'
        self.codex.write_text(FAKE_CODEX)
        self.codex.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('CODEX_', 'MIHOMO_', 'SERVER_TOOLKIT_', 'TOOLKIT_', 'XDG_'))}
        self.env['HOME'] = str(self.home)
        self.env['CODEX_HOME'] = str(self.base / 'codex home')
        self.env['SCREENDIR'] = str(self.base / 'screens')
        Path(self.env['SCREENDIR']).mkdir(mode=0o700)

    def tearDown(self):
        # Only test sessions in this test's private socket directory.
        listing = subprocess.run(['screen', '-ls'], env=self.env, capture_output=True, text=True)
        for line in listing.stdout.splitlines():
            token = line.strip().split()[0] if line.strip() else ''
            if '.' in token and token.split('.', 1)[0].isdigit():
                subprocess.run(['screen', '-S', token, '-X', 'quit'], env=self.env, capture_output=True)
        self.temporary.cleanup()

    def run_command(self, *args, ok=True, env=None):
        result = subprocess.run([str(arg) for arg in args], env=env or self.env,
                                capture_output=True, text=True, timeout=60)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def install(self, *extra):
        return self.run_command('bash', ROOT / 'install.sh', '--prefix', self.prefix,
                                '--bin-dir', self.bin, '--state-dir', self.state,
                                '--mihomo-root', self.mihomo, '--port', '18791',
                                '--codex-bin', self.codex, '--skip-core', *extra)

    def mock_proxy_controller(self):
        path = self.prefix / 'mihomo-server/scripts/mihomoctl'
        path.write_text('#!/usr/bin/env bash\ncase ${1:-} in status|start|health) exit 0 ;; *) exit 2 ;; esac\n')

    def workdir_and_prompt(self, text='offline prompt'):
        workdir = self.base / 'git workdir'
        workdir.mkdir(exist_ok=True)
        self.run_command('git', 'init', '-q', workdir)
        prompt = self.base / 'prompt file'
        prompt.write_text(text)
        prompt.chmod(0o600)
        return workdir, prompt

    def wait_for_state(self, attempt, expected):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            value = (attempt / 'state').read_text().strip()
            if value in {'completed', 'failed', 'interrupted'}:
                self.assertEqual(value, expected)
                return
            time.sleep(0.05)
        self.fail(f'Task did not finish: {attempt}')

    def test_existing_proxy_and_reinstall_preserve_runtime(self):
        for name, content in {
            'home/config.yaml': (ROOT / 'mihomo-server/config/config.template.yaml').read_text().replace('7890', '18791'),
            'home/providers/subscription.yaml': 'proxies: []\n',
            'secrets/subscription.curl': 'private fixture\n',
            'logs/mihomo.screen.log': 'keep logs\n',
            'run/mihomo.pid': '123456789\n',
            'bin/mihomo': 'keep core\n',
        }.items():
            path = self.mihomo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        previous = {path: path.read_bytes() for path in self.mihomo.rglob('*') if path.is_file()}
        self.install('--shell-init')
        obsolete_docs = [self.prefix / 'mihomo-server/README.server-vpn.md',
                         self.prefix / 'codex-headless/OPERATIONS.md']
        for path in obsolete_docs:
            path.write_text('obsolete manual\n')
        with (self.prefix / 'toolkit.env').open('a') as config:
            config.write('CODEX_VSCODE_EXTENSIONS=/opt/custom-vscode-extensions\n')
        self.run_command('bash', ROOT / 'install.sh', '--prefix', self.prefix, '--skip-core')
        self.assertTrue(all(not path.exists() for path in obsolete_docs))
        for path, content in previous.items():
            self.assertEqual(path.read_bytes(), content)
        command_env = self.env.copy()
        # A detached worker must be able to find CODEX_HOME from saved config.
        del command_env['CODEX_HOME']
        result = self.run_command('bash', '-c', 'source "$1"; printf "%s|%s|%s" "$MIHOMO_ROOT" "$MIHOMO_PORT" "$CODEX_DEFAULT_HOME"',
                                  'test', self.prefix / 'lib/toolkit.sh', env=command_env)
        self.assertEqual(result.stdout, f'{self.mihomo}|18791|{self.base / "codex home"}')
        self.assertIn('/opt/custom-vscode-extensions', (self.prefix / 'toolkit.env').read_text())
        self.assertEqual((self.home / '.bashrc').read_text().count('# BEGIN server-vpn-codex-headless'), 1)

    def test_exec_resume_and_failure_with_detached_screen(self):
        self.install()
        self.mock_proxy_controller()
        env = self.env.copy()
        del env['CODEX_HOME']
        workdir, prompt = self.workdir_and_prompt()
        ctl = self.bin / 'codexctl'
        self.run_command(ctl, 'exec', 'portable-job', workdir, prompt, 'workspace-write', env=env)
        attempt = self.state / 'codex-headless/jobs/portable-job/attempts/0001'
        self.wait_for_state(attempt, 'completed')
        self.assertEqual((attempt / 'session-id').read_text().strip(), SESSION)
        self.assertEqual(self.run_command(ctl, 'result', 'portable-job', env=env).stdout.strip(), 'offline result')
        self.assertIn('offline result', self.run_command(ctl, 'chat', 'portable-job', env=env).stdout)
        self.run_command(ctl, 'resume', 'portable-job', prompt, env=env)
        second = attempt.parent / '0002'
        self.wait_for_state(second, 'completed')
        self.assertEqual((second / 'session-id').read_text().strip(), SESSION)
        prompt.write_text('fail fixture')
        result = self.run_command(ctl, 'exec', 'failed-job', workdir, prompt, ok=False, env=env)
        self.assertNotEqual(result.returncode, 0)
        failed = self.state / 'codex-headless/jobs/failed-job/attempts/0001'
        self.assertEqual((failed / 'state').read_text().strip(), 'failed')
        self.assertEqual((failed / 'exit-code').read_text().strip(), '7')

    def test_workspace_restriction_and_environment_override(self):
        allowed = self.base / 'allowed'
        allowed.mkdir()
        self.install('--workspace-root', allowed)
        workdir, prompt = self.workdir_and_prompt()
        result = self.run_command(self.bin / 'codexctl', 'exec', 'outside', workdir, prompt, ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / 'codex-headless/jobs/outside').exists())
        env = dict(self.env, MIHOMO_PORT='18792')
        result = self.run_command('bash', '-c', 'source "$1"; toolkit_set_proxy; printf "%s" "$HTTP_PROXY"',
                                  'test', self.prefix / 'lib/toolkit.sh', env=env)
        self.assertEqual(result.stdout, 'http://127.0.0.1:18792')

    def test_installer_check_and_unrelated_command_are_non_destructive(self):
        self.install('--check')
        self.assertFalse(self.prefix.exists())
        self.bin.mkdir()
        existing = self.bin / 'codexctl'
        existing.write_text('unrelated command\n')
        result = self.run_command('bash', ROOT / 'install.sh', '--prefix', self.prefix,
                                  '--bin-dir', self.bin, '--state-dir', self.state,
                                  '--codex-bin', self.codex, '--skip-core', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(existing.read_text(), 'unrelated command\n')
        self.assertFalse(self.prefix.exists())

    def test_source_tree_execution_keeps_runtime_outside_repository(self):
        result = self.run_command('bash', ROOT / 'mihomo-server/scripts/mihomoctl', 'start', ok=False)
        self.assertNotEqual(result.returncode, 0)
        runtime = self.home / '.local/state/server-vpn-codex-headless/mihomo-server'
        self.assertTrue((runtime / 'secrets').is_dir())
        self.assertIn(str(runtime / 'bin/mihomo'), result.stderr)
        self.assertFalse((ROOT / 'mihomo-server/secrets/subscription.curl').exists())
        self.assertFalse((ROOT / 'mihomo-server/home/config.yaml').exists())

    @unittest.skipUnless(os.environ.get('MIHOMO_TEST_BIN'), 'Set MIHOMO_TEST_BIN for real-core lifecycle test')
    def test_real_mihomo_lifecycle_on_private_port(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        self.install('--port', str(port), '--screen-name', f'mihomo-test-{os.getpid()}')
        (self.mihomo / 'bin').mkdir()
        (self.mihomo / 'bin/mihomo').symlink_to(Path(os.environ['MIHOMO_TEST_BIN']).resolve())
        (self.mihomo / 'home/providers').mkdir(parents=True)
        config = (ROOT / 'mihomo-server/config/config.template.yaml').read_text().replace('7890', str(port))
        (self.mihomo / 'home/config.yaml').write_text(config)
        (self.mihomo / 'home/providers/subscription.yaml').write_text(
            'proxies:\n  - name: offline\n    type: socks5\n    server: 127.0.0.1\n    port: 1\n')
        ctl = self.bin / 'mihomoctl'
        try:
            self.run_command(ctl, 'start')
            status = self.run_command(ctl, 'status').stdout
            self.assertIn(f'listen=127.0.0.1:{port}', status)
            self.run_command(ctl, 'start')
            self.assertEqual(self.run_command(ctl, 'status').stdout, status)
            self.run_command(ctl, 'stop')
            result = self.run_command(ctl, 'status', ok=False)
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        finally:
            self.run_command(ctl, 'stop', ok=False)


class ListenerPolicyTests(unittest.TestCase):
    def test_rejects_extra_listener_without_disclosing_content(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.yaml'
            content = (ROOT / 'mihomo-server/config/config.template.yaml').read_text()
            config.write_text(content + '\nexternal-controller: 0.0.0.0:9090\nsecret: PRIVATE_FIXTURE\n')
            result = subprocess.run(['python3', ROOT / 'mihomo-server/scripts/check-config.py', config, '7890'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('PRIVATE_FIXTURE', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
