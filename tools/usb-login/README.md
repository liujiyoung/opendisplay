# Pre-login USB Screen Sharing relay

This is the local Mac + iPad login path. It uses a trusted USB data cable,
without Wi-Fi, Bonjour, a router, an IP address, or an internet connection.
FileVault must be **off or already unlocked**. This service cannot run while
the data volume that contains it is locked.

The Mac system LaunchDaemon connects through Apple's existing `usbmuxd` to
the selected iPad, then pipes bytes to **127.0.0.1:5900**. The iPad's Mac Login
screen listens on **127.0.0.1:9003** only while the user requests a connection.
It consumes the `ODLOGIN1\n` relay header before handing RFB bytes to the
existing bundled login client. There is no LAN fallback in USB mode.

The relay never authenticates a user, injects input, stores a password, or
changes FileVault, automatic login, Screen Sharing, TCC, or the sender app's
signature. Existing Screen Sharing account authentication and full ARD
encryption remain required. The authenticated login socket is retained during
the foreground handoff, as it is for the existing LAN login path.

## Build and install

With exactly one trusted iPad connected by USB:

```sh
python3 tools/usb-login/build-package.py
python3 tools/usb-login/test_relay.py -v
open 'build/usb-login/OpenDisplay USB Login.pkg'
```

Complete the standard macOS Installer authentication. The package installs:

- `/Library/Application Support/OpenDisplay USB Login/opendisplay-usb-login-relay`
- `/Library/Application Support/OpenDisplay USB Login/config.json`
- `/Library/LaunchDaemons/com.peetzweg.opensidecar.usb-login.plist`

The local config contains the selected iPad's UDID and is generated under
ignored `build/`; device identity is not committed. The binary and config are
root-owned. The daemon runs as the account that built the package, in the
**system** launchd domain without an Aqua session restriction. It does not run
as root. Its owner-readable log is `/Library/Logs/OpenDisplay USB Login/relay.log`.
The installer creates that log with the runtime user's ownership before
starting the service, and verifies that launchd reports it running.

```sh
launchctl print system/com.peetzweg.opensidecar.usb-login
tail '/Library/Logs/OpenDisplay USB Login/relay.log'
```

The new iPad build is also required. In OpenDisplay → **Mac 登录**, select
**USB 数据线**, enter the Mac username/password, and connect. If the desktop
itself still needs login after Screen Sharing authentication, click the
password reference position and enter the password there. Turn off the
input-only toggle when the full login picture is useful. Desktop streaming
resumes through the existing sender's post-login LaunchAgent.

## Validation and limits

`test_relay.py` exercises fragmented RFB greetings, simultaneous multi-megabyte
data in both directions, peer closure, unavailable Screen Sharing, and invalid
configuration. Test destinations are fixed to loopback. Production config
cannot change the Mac target port or choose an arbitrary destination.

iPad tests cover USB mode without a host, loopback-only peers, fragmented relay
headers, byte-exact bidirectional RFB transport, and rejecting an unknown relay
header before authentication, alongside existing login/handoff/input tests.

The Debug-only `-usbLoginProbe YES` launch argument opens the actual iPad USB
listener, exchanges the RFB greeting and security-type offer through the Mac
relay, and closes **before authentication**. It never sends a password or
input. A normal subsequent launch does not run this probe. A successful probe
establishes cable transport; it does not prove password login or cold boot.

Full acceptance requires a physical cold start, with both devices' Wi-Fi off,
no Ethernet, no local Mac login, and the iPad app foreground/unlocked. Verify
USB login, transition to fresh desktop frames, keyboard/trackpad, and a second
lock/unlock. Keep a local keyboard/display available for the first acceptance.
The current live desktop must not be rebooted or logged out automatically by
the build or installation scripts.

On 2026-11-16 the user confirmed the requested USB-only cold-start acceptance
on the M4 Mac mini and 11-inch M1 iPad Pro: Wi-Fi/Ethernet are unnecessary for
the login path, with FileVault off and automatic login off. Read-only checks
confirmed a new Mac boot at 16:34:30 Asia/Shanghai, system relay startup at
16:34:38, and a USB login pipe at 16:41:50. This acceptance covers login and
handoff to desktop streaming/keyboard/trackpad. It does not establish FileVault
pre-unlock support or forced-process-exit recovery; the latter has not been
tested against the retained authenticated session.

## Remove the relay

```sh
sudo launchctl bootout system/com.peetzweg.opensidecar.usb-login
sudo rm /Library/LaunchDaemons/com.peetzweg.opensidecar.usb-login.plist
sudo rm '/Library/Application Support/OpenDisplay USB Login/opendisplay-usb-login-relay'
sudo rm '/Library/Application Support/OpenDisplay USB Login/config.json'
```

The iPad's LAN login option and the original USB desktop streaming remain
available. Removal does not toggle FileVault or automatic login.
