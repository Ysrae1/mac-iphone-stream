import asyncio
import hashlib
import hmac
import json
import os
from pathlib import Path
import plistlib
import secrets
import socket
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch, AsyncMock, Mock
from usb_helper import Service, SessionGuard, USBDevicePool, Rejected, authenticate, connect_usb, forward_one, usb_devices, close

TOKEN = 'offline_test_session_token_123456'

class SessionLifecycleTests(unittest.TestCase):
    def test_renewal_is_allowed_replacement_and_expiry_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.json'
            metadata = {'host': '127.0.0.1', 'port': 12345, 'token': TOKEN, 'pid': 123, 'expires_at': 100}
            path.write_text(json.dumps(metadata))
            path.chmod(0o600)
            guard = SessionGuard(path, metadata)
            with patch('usb_helper.os.kill') as exists:
                self.assertIsNone(guard.stop_reason(now=99))
                exists.assert_called_with(123, 0)
                metadata['expires_at'] = 200; path.write_text(json.dumps(metadata))
                self.assertIsNone(guard.stop_reason(now=101))
                self.assertEqual(guard.stop_reason(now=201), 'session_expired')
                metadata['token'] = 'replacement_token'; path.write_text(json.dumps(metadata))
                self.assertEqual(guard.stop_reason(now=101), 'session_changed')
            path.unlink()
            self.assertEqual(guard.stop_reason(now=101), 'session_unavailable')

    def test_dead_host_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.json'
            metadata = {'host': '127.0.0.1', 'port': 12345, 'token': TOKEN, 'pid': 123, 'expires_at': 200}
            path.write_text(json.dumps(metadata))
            path.chmod(0o600)
            with patch('usb_helper.os.kill', side_effect=ProcessLookupError):
                self.assertEqual(SessionGuard(path, metadata).stop_reason(now=100), 'session_process_gone')

class RequestBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.service = Service({'host': '127.0.0.1', 'port': 12345, 'token': TOKEN})
    def request(self, line='POST /frame HTTP/1.1', headers='', body_length='2'):
        return (f'{line}\r\nHost: 127.0.0.1:9999\r\nOrigin: http://127.0.0.1:9999\r\n'
                f'X-Session-Token: {TOKEN}\r\nX-Controller-Id: owner\r\nX-Session-Lease: lease\r\n'
                f'Content-Type: application/json\r\nContent-Length: {body_length}\r\n{headers}\r\n').encode()
    def test_fixed_host_origin_and_connection_close(self):
        head, length, path = self.service.request_head(self.request())
        self.assertIn(b'host: 127.0.0.1:12345\r\n', head)
        self.assertIn(b'origin: http://127.0.0.1:12345\r\n', head)
        self.assertIn(b'connection: close\r\n', head)
        self.assertIn(b'x-session-lease: lease\r\n', head)
        self.assertEqual((length, path), (2, '/frame'))
    def test_forbidden_targets(self):
        for line in ('CONNECT example.com:80 HTTP/1.1', 'POST http://other/frame HTTP/1.1', 'POST /admin HTTP/1.1'):
            with self.subTest(line=line), self.assertRaises(Rejected):
                self.service.request_head(self.request(line))
    def test_invalid_framing_and_token(self):
        for headers in ('Transfer-Encoding: chunked\r\n', 'Content-Length: 2\r\n', 'X-Session-Token: another\r\n', 'Upgrade: websocket\r\n'):
            with self.subTest(headers=headers), self.assertRaises(Rejected):
                self.service.request_head(self.request(headers=headers))
        with self.assertRaises(Rejected):
            self.service.request_head(self.request().replace(TOKEN.encode(), b'wrong'))
    def test_body_bound(self):
        with self.assertRaises(Rejected): self.service.request_head(self.request(body_length='8193'))

class AsyncBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_late_usb_attach_detach_and_reselection(self):
        stats = {}
        pool = USBDevicePool(49372, 'mock', TOKEN, stats)
        def device(number, kind='USB'):
            return {'DeviceID': number, 'Properties': {'ConnectionType': kind}}
        with patch('usb_helper.usb_devices', new=AsyncMock(side_effect=[[], [device(1)], [], [device(2)], [device(2), device(3)], [device(9, 'Network')]])):
            await pool.refresh(); self.assertFalse(pool.available.is_set())
            await pool.refresh(); self.assertEqual(pool.device_id, 1)
            old_writer = Mock(); pool.writers.add(old_writer)
            await pool.refresh(); self.assertIsNone(pool.device_id); old_writer.close.assert_called_once()
            pool.writers.clear()
            await pool.refresh(); self.assertEqual(pool.device_id, 2)
            await pool.refresh(); self.assertIsNone(pool.device_id); self.assertEqual(stats['usb_device_state'], 'ambiguous')
            await pool.refresh(); self.assertIsNone(pool.device_id); self.assertEqual(stats['usb_device_state'], 'waiting')

    async def test_closed_listener_retries_share_one_gate(self):
        pool = USBDevicePool(49372, 'mock', TOKEN, {})
        pool.device_id = 1; pool.available.set()
        with patch('usb_helper.connect_usb', new=AsyncMock(side_effect=Rejected('closed'))) as dial:
            attempts = [asyncio.create_task(pool.connect()) for _ in range(6)]
            try:
                await asyncio.sleep(.15)
                self.assertEqual(dial.await_count, 1)
            finally:
                for task in attempts: task.cancel()
                await asyncio.gather(*attempts, return_exceptions=True)

    async def test_mux_usb_only_and_network_order(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'mux')
            requests = []
            async def mux(reader, writer):
                try:
                    length, version, message, tag = struct.unpack('<IIII', await reader.readexactly(16))
                    request = plistlib.loads(await reader.readexactly(length - 16)); requests.append(request)
                    if request['MessageType'] == 'ListDevices':
                        result = {'DeviceList': [{'DeviceID': 1, 'Properties': {'ConnectionType': 'Network'}},
                                                 {'DeviceID': 2, 'Properties': {'ConnectionType': 'USB'}}]}
                    else:
                        result = {'MessageType': 'Result', 'Number': 0}
                    payload = plistlib.dumps(result)
                    writer.write(struct.pack('<IIII', len(payload)+16, 1, 8, tag) + payload); await writer.drain()
                    if request['MessageType'] == 'Connect':
                        writer.write(b'payload'); await writer.drain()
                finally: await close(writer)
            server = await asyncio.start_unix_server(mux, path)
            try:
                self.assertEqual([r['DeviceID'] for r in await usb_devices(path)], [2])
                reader, writer = await connect_usb(2, 49372, path)
                self.assertEqual(await reader.readexactly(7), b'payload')
                await close(writer)
                self.assertEqual(requests[-1]['PortNumber'], socket.htons(49372))
            finally: server.close(); await server.wait_closed()

    async def test_authentication_and_real_http_bytes(self):
        observed = []
        async def upstream(reader, writer):
            observed.append(await reader.readuntil(b'\r\n\r\n'))
            observed.append(await reader.readexactly(2))
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{"ok":true}')
            await writer.drain(); await close(writer)
        upstream_server = await asyncio.start_server(upstream, '127.0.0.1', 0)
        service = Service({'host': '127.0.0.1', 'port': upstream_server.sockets[0].getsockname()[1], 'token': TOKEN})
        result = asyncio.get_running_loop().create_future()
        async def device(reader, writer):
            try:
                challenge = bytes(range(32))
                writer.write(b'GSUSB1 ' + challenge.hex().encode() + b'\n'); await writer.drain()
                proof = await reader.readline()
                expected = hmac.new(TOKEN.encode(), b'GSUSB1:' + challenge, hashlib.sha256).hexdigest()
                self.assertEqual(proof, b'AUTH ' + expected.encode() + b'\n')
                writer.write(b'OK\n'); await writer.drain()
                writer.write((f'POST /frame HTTP/1.1\r\nHost: localhost\r\nX-Session-Token: {TOKEN}\r\n'
                              'Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}').encode())
                await writer.drain()
                result.set_result(await reader.read())
            except BaseException as error:
                if not result.done(): result.set_exception(error)
            finally: await close(writer)
        device_server = await asyncio.start_server(device, '127.0.0.1', 0)
        stats = {'requests': 0, 'response_bytes': 0, 'stream_bytes': 0}
        try:
            reader, writer = await asyncio.open_connection('127.0.0.1', device_server.sockets[0].getsockname()[1])
            await authenticate(reader, writer, TOKEN)
            await forward_one(reader, writer, service, stats)
            await close(writer)
            response = await asyncio.wait_for(result, 2)
            self.assertTrue(response.endswith(b'{"ok":true}'))
            self.assertEqual(observed[-1], b'{}')
            self.assertIn(('host: ' + service.authority).encode(), observed[0])
            self.assertEqual(stats['response_bytes'], len(response))
        finally:
            device_server.close(); upstream_server.close()
            await device_server.wait_closed(); await upstream_server.wait_closed()

class HelperLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_cli_reports_ready_then_stops_for_replaced_session(self):
        with tempfile.TemporaryDirectory(prefix='miph-usb-') as temporary:
            directory = Path(temporary)
            session = directory / 'session.json'
            status = directory / 'status.json'
            mux = str(directory / 'mux')
            metadata = dict(host='127.0.0.1', port=12345, token=TOKEN,
                            pid=os.getpid(), expires_at=time.time() + 30)

            def write_session():
                staging = directory / 'session-new.json'
                staging.write_text(json.dumps(metadata))
                staging.chmod(0o600)
                staging.replace(session)

            attach = asyncio.Event()

            async def fake_mux(reader, writer):
                try:
                    length, _, _, tag = struct.unpack('<IIII', await reader.readexactly(16))
                    request = plistlib.loads(await reader.readexactly(length - 16))
                    connect = request['MessageType'] == 'Connect'
                    if connect:
                        reply = dict(MessageType='Result',
                                     Number=0 if request['PortNumber'] == socket.htons(49372) else 1)
                    else:
                        devices = ([dict(DeviceID=7, Properties=dict(ConnectionType='USB'))]
                                   if attach.is_set() else [])
                        reply = dict(DeviceList=devices)
                    payload = plistlib.dumps(reply)
                    writer.write(struct.pack('<IIII', len(payload) + 16, 1, 8, tag) + payload)
                    await writer.drain()
                    if connect and reply['Number'] == 0:
                        challenge = secrets.token_bytes(32)
                        writer.write(b'GSUSB1 ' + challenge.hex().encode() + b'\n')
                        await writer.drain()
                        proof = await reader.readline()
                        expected = hmac.new(TOKEN.encode(), b'GSUSB1:' + challenge, hashlib.sha256)
                        if proof == b'AUTH ' + expected.hexdigest().encode() + b'\n':
                            writer.write(b'OK\n')
                            await writer.drain()
                            await reader.read()
                except (ConnectionError, asyncio.IncompleteReadError):
                    # The helper may close an in-flight channel when its session is replaced.
                    pass
                finally:
                    await close(writer)

            async def wait_for_state(state):
                async with asyncio.timeout(6):
                    while True:
                        if status.exists():
                            current = json.loads(status.read_text())
                            if current['state'] == state:
                                return current
                        await asyncio.sleep(.05)

            write_session()
            server = await asyncio.start_unix_server(fake_mux, mux)
            try:
                helper = Path(__file__).with_name('usb_helper.py')
                process = await asyncio.create_subprocess_exec(
                    sys.executable, '-B', str(helper), '--session-file', str(session),
                    '--status-file', str(status), '--follow-session', '--mux-socket', mux,
                    stdout=asyncio.subprocess.DEVNULL,
                )
                try:
                    waiting = await wait_for_state('waiting')
                    self.assertEqual(waiting['active_sockets'], 0)
                    attach.set()
                    ready = await wait_for_state('connected')
                    self.assertGreaterEqual(ready['active_sockets'], 2)
                    self.assertIsInstance(ready['updated_at'], float)
                    metadata['token'] = secrets.token_urlsafe(24)
                    write_session()
                    self.assertEqual(await asyncio.wait_for(process.wait(), 4), 0)
                    stopped = await wait_for_state('stopped')
                    self.assertEqual(stopped['active_sockets'], 0)
                    self.assertEqual(stopped['stop_reason'], 'session_changed')
                finally:
                    if process.returncode is None:
                        process.kill()
                        await process.wait()
            finally:
                server.close()
                await server.wait_closed()


if __name__ == '__main__':
    unittest.main()
