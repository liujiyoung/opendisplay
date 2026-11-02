"""Install or remove the sender's per-user, post-login launch agent."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['preview', 'install', 'uninstall'])
parser.add_argument('--test-pattern', action='store_true',
                    help='Show the same animated workload for latency comparisons.')
parser.add_argument('--disable-independent-control', action='store_true',
                    help='Use the legacy control path for same-build latency comparisons.')
parser.add_argument('--stress-pattern', action='store_true',
                    help='Use deterministic dense video for bitrate comparisons.')
parser.add_argument('--disable-adaptive-bitrate', action='store_true',
                    help='Use the fixed preset bitrate for same-build comparisons.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
local_label = 'com.peetzweg.opensidecar.headless'
env_file = root / '.env'
if env_file.is_file():
    for line in env_file.read_text().splitlines():
        if line.startswith('LAUNCH_AGENT_LABEL='):
            local_label = line.split('=', 1)[1].strip().strip('"\'')
label = os.environ.get('LAUNCH_AGENT_LABEL', local_label)
app = root / 'build/Build/Products/Debug/OpenDisplay Dev.app'
exe = app / 'Contents/MacOS/OpenDisplay Dev'
agent = Path.home() / 'Library/LaunchAgents' / f'{label}.plist'
logs = Path.home() / 'Library/Logs/OpenDisplay Dev'
domain = f'gui/{os.getuid()}'
config = {
    'Label': label,
    'ProgramArguments': ['/usr/bin/caffeinate', '-s', '/usr/bin/open', '-W', '-a', str(app), '--args',
                         '-mode', 'extend', '-presentation', 'menuBar', '-autostart', 'YES',
                         '-autoReconnectWiFi', 'YES'],
    'WorkingDirectory': str(root),
    'RunAtLoad': True,
    'KeepAlive': True,
    'ThrottleInterval': 10,
    'LimitLoadToSessionType': 'Aqua',
    'ProcessType': 'Interactive',
    'StandardOutPath': str(logs / 'launchd.stdout.log'),
    'StandardErrorPath': str(logs / 'launchd.stderr.log'),
}
if args.test_pattern or args.stress_pattern:
    config['ProgramArguments'] += ['-testPattern', 'YES']
if args.stress_pattern:
    config['ProgramArguments'] += ['-testPatternStress', 'YES']
if args.disable_independent_control:
    config['ProgramArguments'] += ['-disableIndependentControl', 'YES']
if args.disable_adaptive_bitrate:
    config['ProgramArguments'] += ['-disableAdaptiveBitrate', 'YES']
if args.action == 'preview':
    dest = root / '.local/headless-launchagent.plist'
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(plistlib.dumps(config))
    print(dest)
elif args.action == 'install':
    if not exe.is_file():
        raise SystemExit('Build the Mac sender first: tools/local/build.sh mac')
    subprocess.run(['launchctl', 'bootout', f'{domain}/{label}'], capture_output=True)
    running = subprocess.run(['pgrep', '-f', '^' + re.escape(str(exe)) + r'($| )'],
                             capture_output=True, text=True)
    for value in running.stdout.split():
        pid = int(value)
        try:
            os.kill(pid, signal.SIGTERM)
            for _ in range(50):
                time.sleep(0.1)
                os.kill(pid, 0)
            raise SystemExit('Sender did not exit; quit it before installing the login agent.')
        except ProcessLookupError:
            pass
    # Preserve the same stable requirement as run.sh before the first TCC grant.
    signature = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True)
    requirement = 'designated => identifier "com.peetzweg.opensidecar.mac.debug"'
    existing = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, text=True)
    if 'Signature=adhoc' in signature.stderr and requirement not in existing.stdout + existing.stderr:
        subprocess.run(['codesign', '--force', '--sign', '-', '--requirements', '=' + requirement,
                        '--entitlements', str(root / 'Mac/OpenSidecarMac.entitlements'), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    agent.parent.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    agent.write_bytes(plistlib.dumps(config))
    subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
    print(f'Installed post-login sender: {agent}')
else:
    subprocess.run(['launchctl', 'bootout', f'{domain}/{label}'], capture_output=True)
    agent.unlink(missing_ok=True)
    print('Removed OpenDisplay login agent')
