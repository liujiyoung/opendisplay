"""Exercise the compiled relay with real loopback sockets; no Mac credentials."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

BINARY = Path(__file__).resolve().parents[2] / 'build/usb-login/opendisplay-usb-login-relay'


def listener():
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    sock.listen(1)
    sock.settimeout(8)
    return sock


def receive(sock, count):
    data = bytearray()
    while len(data) < count:
        block = sock.recv(min(65536, count - len(data)))
        if not block:
            raise EOFError(f'closed after {len(data)} of {count} bytes')
        data.extend(block)
    return bytes(data)


class RelayTests(unittest.TestCase):
    def exercise_handoff(self, finish):
        with tempfile.TemporaryDirectory() as folder, listener() as tablet, listener() as screen:
            lease_path = Path(folder) / 'face.json'
            session = str(uuid.uuid4())

            def publish(active=True, owner=session):
                pending = lease_path.with_suffix('.pending')
                pending.write_text(json.dumps({'session': owner, 'updatedAt': time.time(), 'active': active}))
                pending.replace(lease_path)

            publish()
            process = subprocess.Popen([str(BINARY), '--test-loopback',
                                        str(tablet.getsockname()[1]),
                                        str(screen.getsockname()[1]), '--once', folder],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                with tablet.accept()[0] as device, screen.accept()[0] as server:
                    device.settimeout(5)
                    self.assertEqual(receive(device, 9), b'ODLOGIN1\n')
                    device.close()
                    finish(server, publish)
                _, log = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, log.decode())
                self.assertIn(b'retaining local Screen Sharing socket after USB detach', log)
                return log
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_same_stream_renews_retention_until_it_ends(self):
        def finish(server, publish):
            server.settimeout(0.7)
            for _ in range(8):
                with self.assertRaises(socket.timeout):
                    server.recv(1)
                publish()
            publish(active=False)
            server.settimeout(4)
            self.assertEqual(server.recv(1), b'')

        log = self.exercise_handoff(finish)
        self.assertIn(b'same receiver resumed streaming', log)
        self.assertIn(b'stream ended', log)

    def test_handoff_expires_without_a_renewal(self):
        def finish(server, _publish):
            server.settimeout(0.7)
            with self.assertRaises(socket.timeout):
                server.recv(1)
            server.settimeout(7)
            self.assertEqual(server.recv(1), b'')

        log = self.exercise_handoff(finish)
        self.assertIn(b'stream continuity expired', log)

    def test_different_sender_cannot_keep_the_old_socket(self):
        def finish(server, publish):
            server.settimeout(0.7)
            with self.assertRaises(socket.timeout):
                server.recv(1)
            publish(owner=str(uuid.uuid4()))
            server.settimeout(4)
            self.assertEqual(server.recv(1), b'')

        log = self.exercise_handoff(finish)
        self.assertIn(b'stream ended', log)

    def test_fragmented_bidirectional_large_transfer_and_peer_close(self):
        # Run twice, on fresh sockets, to catch stale global/connection state.
        for _ in range(2):
            with listener() as tablet, listener() as screen:
                process = subprocess.Popen([str(BINARY), '--test-loopback',
                                            str(tablet.getsockname()[1]),
                                            str(screen.getsockname()[1]), '--once'],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    with tablet.accept()[0] as device, screen.accept()[0] as server:
                        device.settimeout(12)
                        server.settimeout(12)
                        self.assertEqual(receive(device, 9), b'ODLOGIN1\n')
                        # Deliberately fragment the protocol greeting.
                        for part in [b'R', b'FB 003.', b'889\n']:
                            server.sendall(part)
                            time.sleep(0.01)
                        self.assertEqual(receive(device, 12), b'RFB 003.889\n')
                        upstream = os.urandom(2 * 1024 * 1024 + 7)
                        downstream = os.urandom(3 * 1024 * 1024 + 13)
                        failures = []

                        def check(sock, expected):
                            try:
                                self.assertEqual(receive(sock, len(expected)), expected)
                            except Exception as error:
                                failures.append(error)

                        tasks = [threading.Thread(target=check, args=(server, upstream)),
                                 threading.Thread(target=check, args=(device, downstream)),
                                 threading.Thread(target=device.sendall, args=(upstream,)),
                                 threading.Thread(target=server.sendall, args=(downstream,))]
                        for task in tasks:
                            task.start()
                        for task in tasks:
                            task.join(15)
                            self.assertFalse(task.is_alive())
                        self.assertEqual(failures, [])
                    _, log = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, log.decode())
                    self.assertIn(b'USB Screen Sharing byte pipe connected', log)
                    self.assertNotIn(upstream[:32], log)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()

    def test_unavailable_screen_sharing_closes_without_sending_login_header(self):
        with listener() as tablet, listener() as unused:
            port = unused.getsockname()[1]
            unused.close()
            process = subprocess.Popen([str(BINARY), '--test-loopback',
                                        str(tablet.getsockname()[1]), str(port), '--once'],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                with tablet.accept()[0] as device:
                    device.settimeout(5)
                    self.assertEqual(device.recv(9), b'')
                _, log = process.communicate(timeout=5)
                self.assertIn(b'local Screen Sharing unavailable', log)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_invalid_configuration_cannot_choose_arbitrary_destinations(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / 'config.json'
            config.write_text(json.dumps({'deviceUDID': 'not/a/device', 'host': 'example.com'}))
            result = subprocess.run([str(BINARY), '--config', str(config)], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b'no listener or relay started', result.stderr)


if __name__ == '__main__':
    unittest.main()
