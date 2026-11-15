#!/usr/bin/env python3
"""Build a local, root-owned installation of the pre-login USB byte relay.

The package neither changes FileVault nor enables automatic login. The runtime
uses the current account without requiring a GUI session or storing a password.
"""
import getpass
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/usb-login'
LABEL = 'com.peetzweg.opensidecar.usb-login'
INSTALL = Path('/Library/Application Support/OpenDisplay USB Login')


def usb_device():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect('/var/run/usbmuxd')
        payload = plistlib.dumps({'MessageType': 'ListDevices',
                                 'ProgName': 'OpenDisplay USB Login installer'})
        sock.sendall(struct.pack('<IIII', len(payload) + 16, 1, 8, 1) + payload)

        def read(count):
            data = b''
            while len(data) < count:
                chunk = sock.recv(count - len(data))
                if not chunk:
                    raise RuntimeError('usbmuxd closed during discovery')
                data += chunk
            return data

        size, *_ = struct.unpack('<IIII', read(16))
        if not 16 < size < 1024 * 1024:
            raise RuntimeError('Invalid usbmuxd reply')
        reply = plistlib.loads(read(size - 16))
        devices = [entry['Properties']['SerialNumber'] for entry in reply.get('DeviceList', [])
                   if entry.get('Properties', {}).get('ConnectionType') == 'USB']
        if len(devices) != 1:
            raise RuntimeError('Connect exactly one trusted iPad by USB before building this local package')
        return devices[0]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    binary = OUT / 'opendisplay-usb-login-relay'
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path',
                    '/private/tmp/opendisplay-swift-cache',
                    str(ROOT / 'tools/usb-login/main.swift'), str(ROOT / 'Mac/Usbmux.swift'),
                    '-o', str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', LABEL, str(binary)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    stage = OUT / 'package-root'
    scripts = OUT / 'package-scripts'
    shutil.rmtree(stage, ignore_errors=True)
    scripts.mkdir(exist_ok=True)
    destination = stage / INSTALL.relative_to('/')
    destination.mkdir(parents=True)
    shutil.copy2(binary, destination / binary.name)
    os.chmod(destination / binary.name, 0o755)
    (destination / 'config.json').write_text(json.dumps({'deviceUDID': usb_device()}) + '\n')
    os.chmod(destination / 'config.json', 0o644)
    launch = stage / 'Library/LaunchDaemons'
    launch.mkdir(parents=True)
    config = {
        'Label': LABEL,
        'ProgramArguments': [str(INSTALL / binary.name), '--config', str(INSTALL / 'config.json')],
        'UserName': getpass.getuser(),
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
        'ProcessType': 'Background', 'Umask': 0o077,
        'StandardOutPath': '/Library/Logs/OpenDisplay USB Login/relay.log',
        'StandardErrorPath': '/Library/Logs/OpenDisplay USB Login/relay.log',
    }
    (launch / f'{LABEL}.plist').write_bytes(plistlib.dumps(config))
    os.chmod(launch / f'{LABEL}.plist', 0o644)
    postinstall = scripts / 'postinstall'
    postinstall.write_text(f'''#!/bin/sh
set -eu
/usr/bin/install -d -o root -g wheel -m 755 '/Library/Logs/OpenDisplay USB Login'
if [ -L '/Library/Logs/OpenDisplay USB Login/relay.log' ]; then exit 1; fi
/usr/bin/touch '/Library/Logs/OpenDisplay USB Login/relay.log'
/usr/sbin/chown {os.getuid()}:{os.getgid()} '/Library/Logs/OpenDisplay USB Login/relay.log'
/bin/chmod 600 '/Library/Logs/OpenDisplay USB Login/relay.log'
/bin/launchctl bootout system/{LABEL} >/dev/null 2>&1 || true
/bin/launchctl bootstrap system /Library/LaunchDaemons/{LABEL}.plist
/bin/launchctl kickstart system/{LABEL}
/bin/sleep 1
/bin/launchctl print system/{LABEL} | /usr/bin/grep -q 'state = running'
''')
    os.chmod(postinstall, 0o755)
    package = OUT / 'OpenDisplay USB Login.pkg'
    # Exclude Finder/resource-fork metadata from this four-file local package.
    subprocess.run(['xattr', '-cr', str(stage)], check=True)
    subprocess.run(['pkgbuild', '--root', str(stage), '--scripts', str(scripts),
                    '--identifier', LABEL, '--version', '1.0.1', '--ownership', 'recommended',
                    '--filter', r'/\._', '--install-location', '/', str(package)],
                   env={**os.environ, 'COPYFILE_DISABLE': '1'}, check=True)
    print(package)


if __name__ == '__main__':
    main()
