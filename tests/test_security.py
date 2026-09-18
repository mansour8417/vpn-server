"""Portable regression tests; never install packages or modify the host.

The embedded manager runs in a temporary directory with root/ownership checks
simulated and Xray/systemd/flock stubbed. These tests cover shell/data handling
and configuration transactions, not Linux permissions, actual locking, Xray
compatibility, or network isolation.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / 'install.sh').read_text()
MANAGER = INSTALLER.split("<<'VPN_MANAGER_EOF'\n", 1)[1].split('\nVPN_MANAGER_EOF', 1)[0]


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.state = self.base / 'state'
        self.state.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, TEST_STATE=str(self.state))
        self.config = self.state / 'config.json'
        self.meta = self.state / 'server.env'
        self.config.write_text(json.dumps({
            'inbounds': [{'settings': {'clients': [
                {'id': 'admin-uuid', 'email': 'admin', 'flow': 'xtls-rprx-vision'}]},
                'streamSettings': {'realitySettings': {'shortIds': ['admin-short-id']}}}]
        }))
        self.config.chmod(0o640)
        self.meta.write_text('SERVER_IP=vpn.example.com\nPORT=443\nSNI=www.example.com\nPUBLIC_KEY=' + 'A'*43 + '\n')
        self.meta.chmod(0o600)
        self.stub('stat', '''#!/usr/bin/env python3
import os, sys, stat
if sys.argv[2] == '%u': print(1000 if os.environ.get('UNSAFE_OWNER') else 0)
else: print(oct(stat.S_IMODE(os.stat(sys.argv[3]).st_mode))[2:])
''')
        self.stub('chown', '#!/bin/sh\nexit 0\n')
        self.stub('flock', '#!/bin/sh\nexit 0\n')
        self.stub('qrencode', '#!/bin/sh\nexit 0\n')
        self.stub('systemctl', '''#!/bin/sh
if [ -f "$TEST_STATE/restart-fail" ]; then exit 1; fi
exit 0
''')
        self.stub('xray', '''#!/usr/bin/env python3
import json, os, pathlib, sys, uuid
if sys.argv[1] == 'uuid': print(uuid.uuid4())
elif sys.argv[1] == 'run':
    json.load(open(sys.argv[-1]))
    sys.exit(1 if (pathlib.Path(os.environ['TEST_STATE']) / 'invalid').exists() else 0)
else: sys.exit(2)
''')
        guard = '[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }'
        self.assertEqual(MANAGER.count(guard), 1)
        self.script = self.base / 'vpn'
        adapted = MANAGER.replace(guard, ': # root check bypassed only in sandbox harness')
        adapted = adapted.replace('export PATH=/usr/sbin:/usr/bin:/sbin:/bin',
                                   f'export PATH="{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin"')
        adapted = adapted.replace('XRAY_DIR=/usr/local/etc/xray', f'XRAY_DIR="{self.state}"')
        adapted = adapted.replace('XRAY=/usr/local/bin/xray', f'XRAY="{self.bin}/xray"')
        self.script.write_text(adapted)

    def stub(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_manager(self, *args, ok=True):
        p = subprocess.run(['bash', str(self.script), *args], env=self.env,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if ok:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        return p

    def test_shell_syntax(self):
        for source in (INSTALLER, MANAGER):
            p = subprocess.run(['bash', '-n'], input=source, text=True, capture_output=True)
            self.assertEqual(p.returncode, 0, p.stderr)

    def test_bad_arguments_rejected_before_root_or_side_effects(self):
        for args in (['--host'], ['--port', '0'], ['--port', '65536'],
                     ['--port', '443;id'], ['--sni', 'a"b'],
                     ['--host', '$(touch /tmp/never)'], ['--host', 'a\nb'],
                     ['--host', 'a..b'], ['--port', '00443']):
            p = subprocess.run(['bash', str(ROOT / 'install.sh'), *args],
                               text=True, capture_output=True)
            self.assertNotEqual(p.returncode, 0)
            self.assertNotIn('run as root', p.stderr)
            self.assertNotIn('installing dependencies', p.stdout)

    def test_metadata_is_never_executed(self):
        marker = self.base / 'executed'
        self.meta.write_text(f'SERVER_IP=$(touch {marker})\nPORT=443\nSNI=example.com\nPUBLIC_KEY=' + 'A'*43 + '\n')
        self.run_manager('list', ok=False)
        self.assertFalse(marker.exists())

    def test_reject_unknown_metadata(self):
        with self.meta.open('a') as f:
            f.write('INJECTED=anything\n')
        self.run_manager('list', ok=False)

    def test_reject_unsafe_owner(self):
        self.env['UNSAFE_OWNER'] = '1'
        self.assertIn('unsafe ownership', self.run_manager('list', ok=False).stderr)

    def test_reject_writable_state(self):
        self.state.chmod(0o777)
        self.assertIn('writable path', self.run_manager('list', ok=False).stderr)

    def test_reject_metadata_symlink(self):
        target = self.base / 'metadata'
        self.meta.rename(target)
        self.meta.symlink_to(target)
        self.assertIn('symlink', self.run_manager('list', ok=False).stderr)

    def test_user_lifecycle_and_pairing(self):
        for name in ('alice', 'middle person', 'last'):
            self.run_manager('add', name)
        before = json.loads(self.config.read_text())['inbounds'][0]
        keep_id = before['streamSettings']['realitySettings']['shortIds'][3]
        self.run_manager('del', 'middle person')
        after = json.loads(self.config.read_text())['inbounds'][0]
        self.assertEqual([c['email'] for c in after['settings']['clients']], ['admin', 'alice', 'last'])
        self.assertEqual(after['streamSettings']['realitySettings']['shortIds'][2], keep_id)
        self.assertIn('sid=' + keep_id, self.run_manager('link', 'last').stdout)
        self.run_manager('del', 'admin', ok=False)
        self.run_manager('add', 'alice', ok=False)
        self.run_manager('link', 'missing', ok=False)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.state.glob('.config.*')), [])
        self.assertEqual(list(self.state.glob('.backup.*')), [])

    def test_candidate_failure_preserves_original(self):
        original = self.config.read_bytes()
        (self.state / 'invalid').touch()
        self.run_manager('add', 'alice', ok=False)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual(list(self.state.glob('.config.*')), [])

    def test_restart_failure_restores_original(self):
        original = self.config.read_bytes()
        (self.state / 'restart-fail').touch()
        p = self.run_manager('add', 'alice', ok=False)
        self.assertIn('original configuration restored', p.stderr)
        self.assertEqual(self.config.read_bytes(), original)

    def test_name_validation(self):
        for name in ('', 'a\nb', 'a\tb', 'a'*65):
            self.run_manager('add', name, ok=False)

    def test_update_does_not_execute_remote_code(self):
        self.stub('curl', '#!/bin/sh\ntouch "$TEST_STATE/downloaded"\nexit 1\n')
        p = self.run_manager('update', ok=False)
        self.assertIn('disabled', p.stderr)
        self.assertFalse((self.state / 'downloaded').exists())

    def test_fresh_install_refuses_existing_config(self):
        s = INSTALLER.replace('XRAY_DIR=/usr/local/etc/xray', f'XRAY_DIR="{self.state}"', 1)
        s = s.replace('[[ $EUID -eq 0 ]] || die "run as root (sudo bash install.sh)"', ':', 1)
        path = self.base / 'install'
        path.write_text(s)
        p = subprocess.run(['bash', str(path)], text=True, capture_output=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('refusing to overwrite', p.stderr)
        self.assertNotIn('installing dependencies', p.stdout)

    def test_current_tree_has_no_persian_text(self):
        for path in ROOT.rglob('*'):
            if path.is_file() and '__pycache__' not in path.parts:
                self.assertIsNone(re.search('[\u0600-\u06ff]', path.read_text()), str(path))


if __name__ == '__main__':
    if not shutil.which('jq'):
        raise SystemExit('Install jq before running these tests.')
    unittest.main(verbosity=2)
