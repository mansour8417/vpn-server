"""Opt-in Xray smoke test. Requires a verified Xray binary/assets and network.

Usage: python3 tests/smoke_xray.py /absolute/path/to/xray /absolute/path/to/assets
Starts unprivileged loopback listeners only. Uses ephemeral keys and cleans up.
This does not exercise systemd, UFW, Linux ownership, or Hyper-V.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def wait_port(port, process):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError('Xray exited during startup')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                return
        except OSError:
            time.sleep(.05)
    raise RuntimeError('Xray listener did not start')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = dict(os.environ, XRAY_LOCATION_ASSET=str(Path(sys.argv[2]).resolve()))
    root = Path(__file__).resolve().parents[1]
    installer = (root / 'install.sh').read_text()
    template = installer.split('cat > "$CONFIG" <<EOF\n', 1)[1].split('\nEOF', 1)[0]
    rules_code = installer.split("routing_rules='", 1)[1].split('\ncat > "$CONFIG"', 1)[0]
    key_lines = subprocess.check_output([binary, 'x25519'], env=env, text=True).splitlines()
    private, public = (line.split()[-1] for line in key_lines[:2])
    uid = subprocess.check_output([binary, 'uuid'], env=env, text=True).strip()
    server_port, socks_port = free_port(), free_port()
    render_env = dict(env, PRIVATE_KEY=private, UUID=uid, SHORT_ID='0123456789abcdef',
                      PORT=str(server_port), SNI='www.samsung.com', BLOCK_TORRENT='1')
    rendered = subprocess.check_output(['bash', '-c', "routing_rules='" + rules_code + '\ncat <<EOF\n' + template + '\nEOF'],
                                       env=render_env, text=True)
    server = json.loads(rendered)
    server['inbounds'][0]['listen'] = '127.0.0.1'
    client = {
        'log': {'loglevel': 'warning'},
        'inbounds': [{'listen': '127.0.0.1', 'port': socks_port, 'protocol': 'socks',
                      'settings': {'auth': 'noauth', 'udp': False}}],
        'outbounds': [{'protocol': 'vless', 'settings': {'vnext': [
            {'address': '127.0.0.1', 'port': server_port, 'users': [
                {'id': uid, 'encryption': 'none', 'flow': 'xtls-rprx-vision'}]}]},
            'streamSettings': {'network': 'tcp', 'security': 'reality', 'realitySettings': {
                'serverName': 'www.samsung.com', 'fingerprint': 'chrome',
                'publicKey': public, 'shortId': '0123456789abcdef'}}}]
    }
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        server['log']['error'] = str(tmp / 'server-error.log')
        paths = []
        for name, config in [('server', server), ('client', client)]:
            path = tmp / (name + '.json')
            path.write_text(json.dumps(config))
            path.chmod(0o600)
            subprocess.run([binary, 'run', '-test', '-config', str(path)], env=env, check=True,
                           stdout=subprocess.DEVNULL)
            paths.append(path)
        processes = []
        try:
            with (tmp / 'process.log').open('w') as log:
                for path, port in zip(paths, (server_port, socks_port)):
                    p = subprocess.Popen([binary, 'run', '-config', str(path)], env=env, stdout=log, stderr=log)
                    processes.append(p)
                    wait_port(port, p)
                curl = ['curl', '--silent', '--show-error', '--fail', '--max-time', '30',
                        '--noproxy', '', '--socks5-hostname', f'127.0.0.1:{socks_port}']
                result = subprocess.run(curl + ['https://example.com'], text=True, capture_output=True)
                if result.returncode or 'Example Domain' not in result.stdout:
                    raise RuntimeError('Tunnel request failed: ' + result.stderr)
                # A reachable local HTTP listener must not be reachable through the proxy.
                with socket.socket() as local:
                    local.bind(('127.0.0.1', 0)); local.listen()
                    blocked = subprocess.run(curl + [f'http://127.0.0.1:{local.getsockname()[1]}'], capture_output=True)
                    local.settimeout(.2)
                    try:
                        conn, _ = local.accept(); conn.close()
                        raise AssertionError('Private destination was reached')
                    except socket.timeout:
                        pass
                    if blocked.returncode == 0:
                        raise AssertionError('Private destination request unexpectedly succeeded')
                print('PASS: generated configuration, REALITY HTTPS tunnel, and direct loopback destination blocking')
        finally:
            for p in processes:
                p.terminate()
            for p in processes:
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: p.kill(); p.wait()


if __name__ == '__main__':
    main()
