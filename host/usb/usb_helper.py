#!/usr/bin/env python3
"""Relay the foreground iPhone client's HTTP requests over an attached USB cable.

The helper uses the Mac's existing usbmux daemon with a single attached USB
device. It sends only to the private session's IPv4 loopback endpoint.
"""

import argparse
import asyncio
import contextlib
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import socket
import stat
import struct
import tempfile
import time
from xml.parsers.expat import ExpatError

DEVICE_PORT = 49372
HEADER_LIMIT = 16384
BODY_LIMIT = 8192
ALLOWED = {
    ('POST', '/session'),
    ('POST', '/frame'),
    ('POST', '/reset'),
    ('GET', '/status'),
    ('GET', '/native/status'),
    ('GET', '/native/stream'),
}


class Rejected(Exception):
    pass

class SessionGuard:
    """Follow activity-renewed expiry without following a replacement session."""
    def __init__(self, path, initial):
        self.path = Path(path)
        self.identity = {key: initial.get(key) for key in ('host', 'port', 'token', 'pid')}

    def stop_reason(self, now=None):
        try:
            current = read_session(self.path)
            if any(current.get(key) != value for key, value in self.identity.items()):
                return 'session_changed'
            expiry, pid = current.get('expires_at'), current.get('pid')
            if type(expiry) not in (int, float) or not math.isfinite(expiry):
                return 'invalid_session_expiry'
            if expiry <= (time.time() if now is None else now):
                return 'session_expired'
            if type(pid) is not int or pid <= 1:
                return 'invalid_session_pid'
            os.kill(pid, 0)  # Existence check only; never signals/stops the host.
        except ProcessLookupError:
            return 'session_process_gone'
        except (OSError, ValueError, OverflowError, Rejected):
            return 'session_unavailable'
        return None

async def close(writer):
    writer.close()
    with contextlib.suppress(Exception):
        await asyncio.wait_for(writer.wait_closed(), .5)

async def mux_request(reader, writer, message):
    payload = plistlib.dumps({'ClientVersionString': 'MacIPhoneStream-USB-1',
                             'ProgName': 'MacIPhoneStreamUSB', 'kLibUSBMuxVersion': 3,
                             **message}, fmt=plistlib.FMT_XML)
    writer.write(struct.pack('<IIII', len(payload) + 16, 1, 8, 1) + payload)
    await writer.drain()
    length, version, kind, tag = struct.unpack('<IIII', await reader.readexactly(16))
    if version != 1 or kind != 8 or tag != 1 or not 16 <= length <= 1024 * 1024:
        raise Rejected('invalid_mux_reply')
    data = await reader.readexactly(length - 16)
    try:
        reply = plistlib.loads(data)
    except (ValueError, ExpatError, plistlib.InvalidFileException):
        raise Rejected('invalid_mux_payload') from None
    if not isinstance(reply, dict):
        raise Rejected('invalid_mux_payload')
    return reply

async def usb_devices(mux_path='/var/run/usbmuxd'):
    reader, writer = await asyncio.open_unix_connection(mux_path)
    try:
        result = await asyncio.wait_for(mux_request(reader, writer, {'MessageType': 'ListDevices'}), 3)
        records = result.get('DeviceList', [])
        if not isinstance(records, list):
            raise Rejected('invalid_mux_device_list')
        return [
            item for item in records
            if isinstance(item, dict)
            and type(item.get('DeviceID')) is int
            and isinstance(item.get('Properties'), dict)
            and item['Properties'].get('ConnectionType') == 'USB'
        ]
    finally:
        await close(writer)

async def connect_usb(device_id, port, mux_path='/var/run/usbmuxd'):
    reader, writer = await asyncio.open_unix_connection(mux_path, limit=HEADER_LIMIT + 4096)
    try:
        reply = await asyncio.wait_for(mux_request(reader, writer, {
            'MessageType': 'Connect', 'DeviceID': device_id,
            'PortNumber': socket.htons(port)}), 3)
        if reply.get('MessageType') != 'Result' or reply.get('Number') != 0:
            raise Rejected('device_port_unavailable')
        return reader, writer
    except BaseException:
        await close(writer)
        raise

async def authenticate(reader, writer, token):
    greeting = await asyncio.wait_for(reader.readline(), 3)
    parts = greeting.rstrip(b'\n').split(b' ')
    if len(parts) != 2 or parts[0] != b'GSUSB1' or len(parts[1]) != 64:
        raise Rejected('invalid_usb_greeting')
    try:
        challenge = bytes.fromhex(parts[1].decode('ascii'))
    except ValueError:
        raise Rejected('invalid_usb_challenge') from None
    if len(challenge) != 32:
        raise Rejected('invalid_usb_challenge')
    digest = hmac.new(token.encode('ascii'), b'GSUSB1:' + challenge, hashlib.sha256).hexdigest()
    writer.write(b'AUTH ' + digest.encode('ascii') + b'\n')
    await writer.drain()
    if await asyncio.wait_for(reader.readline(), 3) != b'OK\n':
        raise Rejected('usb_authentication_failed')

class USBDevicePool:
    """USB hotplug selection and one shared, bounded handshake retry gate."""
    def __init__(self, port, mux_path, token, stats):
        self.port, self.mux_path, self.token = port, mux_path, token
        self.stats = stats
        self.device_id = None
        self.available = asyncio.Event()
        self.dial_lock = asyncio.Lock()
        self.retry_after = 0
        self.writers = set()

    async def refresh(self):
        try:
            records = await usb_devices(self.mux_path)
            records = [record for record in records if record['Properties'].get('ConnectionType') == 'USB']
            selected = records[0]['DeviceID'] if len(records) == 1 else None
            state = 'selected' if selected is not None else ('ambiguous' if records else 'waiting')
        except (OSError, EOFError, ValueError, TimeoutError, Rejected):
            selected, state = None, 'enumeration_failed'
        if selected != self.device_id:
            # Cancel only this helper's old tunnels; never carry a socket across
            # detach, changed device handle, or ambiguous device selection.
            for writer in tuple(self.writers): writer.close()
            self.device_id = selected
        self.stats['usb_device_state'] = state
        if selected is None:
            self.available.clear()
        else:
            self.available.set()

    async def connect(self):
        while True:
            await self.available.wait()
            async with self.dial_lock:
                delay = self.retry_after - asyncio.get_running_loop().time()
                if delay > 0: await asyncio.sleep(delay)
                device_id = self.device_id
                if device_id is None: continue
                writer = None
                try:
                    reader, writer = await connect_usb(device_id, self.port, self.mux_path)
                    self.writers.add(writer)
                    await authenticate(reader, writer, self.token)
                    if self.device_id != device_id: raise Rejected('usb_device_changed')
                    return reader, writer
                except BaseException:
                    # Six idle workers share this gate. A closed app/listener
                    # causes at most one failed handshake attempt per 1.5 s.
                    self.retry_after = asyncio.get_running_loop().time() + 1.5
                    if writer: await self.release(writer)
                    raise

    async def release(self, writer):
        self.writers.discard(writer)
        await close(writer)

class Service:
    def __init__(self, metadata):
        host, port, token = metadata['host'], metadata['port'], metadata['token']
        if host != '127.0.0.1':
            raise Rejected('invalid_session_host')
        if type(port) is not int or not 1 <= port <= 65535:
            raise Rejected('invalid_session_port')
        if not isinstance(token, str) or not 16 <= len(token) <= 256 or not all(c.isascii() and (c.isalnum() or c in '-_') for c in token):
            raise Rejected('invalid_session_token')
        self.host, self.port, self.token = host, port, token
        self.authority = f'{host}:{port}'

    def request_head(self, data):
        if len(data) > HEADER_LIMIT or not data.endswith(b'\r\n\r\n'):
            raise Rejected('invalid_request_header')
        try:
            lines = data[:-4].decode('ascii').split('\r\n')
            method, path, version = lines[0].split(' ')
        except (ValueError, UnicodeError):
            raise Rejected('invalid_request_line') from None
        if version != 'HTTP/1.1' or (method, path) not in ALLOWED:
            raise Rejected('forbidden_request')
        headers = {}
        for line in lines[1:]:
            if ':' not in line or line[0] in ' \t':
                raise Rejected('invalid_header')
            key, value = line.split(':', 1)
            key, value = key.lower(), value.strip()
            if key in headers or not key or not all(c.isalnum() or c == '-' for c in key):
                raise Rejected('duplicate_or_invalid_header')
            if any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise Rejected('invalid_header_value')
            headers[key] = value
        if 'transfer-encoding' in headers or 'upgrade' in headers or 'expect' in headers:
            raise Rejected('unsupported_request_framing')
        if not hmac.compare_digest(headers.get('x-session-token', ''), self.token):
            raise Rejected('invalid_session_token')
        length = headers.get('content-length', '0')
        if not length.isascii() or not length.isdigit() or len(length) > 5 or int(length) > BODY_LIMIT:
            raise Rejected('invalid_body_length')
        if method == 'GET' and int(length) != 0:
            raise Rejected('get_body_rejected')
        if method == 'POST' and ('content-length' not in headers or headers.get('content-type', '').split(';')[0] != 'application/json'):
            raise Rejected('json_required')
        headers.update({'host': self.authority, 'origin': 'http://' + self.authority, 'connection': 'close'})
        # Fixed endpoint and fixed application headers: no proxy routing directives.
        permitted = ('host', 'origin', 'connection', 'content-length', 'content-type',
                     'x-session-token', 'x-controller-id', 'x-session-lease')
        head = f'{method} {path} HTTP/1.1\r\n' + ''.join(f'{k}: {headers[k]}\r\n' for k in permitted if k in headers) + '\r\n'
        return head.encode('ascii'), int(length), path


async def forward_one(reader, writer, service, stats):
    head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 45)
    outbound, length, path = service.request_head(head)
    body = await asyncio.wait_for(reader.readexactly(length), 3)
    upstream_reader, upstream_writer = await asyncio.wait_for(
        asyncio.open_connection(service.host, service.port), 3
    )
    stats['requests'] += 1

    async def relay_response():
        while data := await upstream_reader.read(65536):
            writer.write(data)
            await asyncio.wait_for(writer.drain(), 5)
            stats['response_bytes'] += len(data)
            if path == '/native/stream':
                stats['stream_bytes'] += len(data)

    try:
        upstream_writer.write(outbound + body)
        await asyncio.wait_for(upstream_writer.drain(), 3)
        # Device EOF must also close the upstream stream when no media is arriving.
        tasks = (asyncio.create_task(reader.read(1)), asyncio.create_task(relay_response()))
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        await close(upstream_writer)


def read_session(path):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(path, flags), 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Rejected('unsafe_session_file')
        data = stream.read(4097)
        if len(data) > 4096:
            raise Rejected('session_file_too_large')
    value = json.loads(data)
    if not isinstance(value, dict):
        raise Rejected('invalid_session')
    return value


def write_status(path, stats, stop_reason=None):
    if path is None:
        return
    if stop_reason:
        state = 'stopped'
    elif stats['usb_device_state'] in ('ambiguous', 'enumeration_failed'):
        state = 'unavailable'
    elif stats['active_sockets'] >= 2:
        state = 'connected'
    else:
        state = 'waiting'
    descriptor, temp = tempfile.mkstemp(prefix=f'.{path.name}-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump({**stats, 'state': state, 'updated_at': time.time(),
                       'stop_reason': stop_reason}, stream)
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)


async def run(args):
    metadata = read_session(args.session_file)
    service = Service(metadata)
    guard = SessionGuard(args.session_file, metadata)
    if reason := guard.stop_reason():
        raise Rejected(reason)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    stats = dict(usb_device_state='waiting', authenticated_sockets=0,
                 active_sockets=0, requests=0, response_bytes=0, stream_bytes=0)
    pool = USBDevicePool(DEVICE_PORT, args.mux_socket, service.token, stats)

    async def worker():
        while not stop.is_set():
            writer = None
            try:
                reader, writer = await pool.connect()
                stats['authenticated_sockets'] += 1
                stats['active_sockets'] += 1
                await forward_one(reader, writer, service, stats)
            except (OSError, EOFError, asyncio.LimitOverrunError, TimeoutError, Rejected):
                failed = True
            else:
                failed = False
            finally:
                if writer:
                    stats['active_sockets'] -= 1
                    await pool.release(writer)
            # Both failed handshakes and malformed requests are rate limited.
            if failed:
                await asyncio.sleep(.25)

    async def track_devices():
        while not stop.is_set():
            await pool.refresh()
            await asyncio.sleep(2)

    tasks = [asyncio.create_task(worker()) for _ in range(6)]
    tasks.append(asyncio.create_task(track_devices()))
    deadline = math.inf if args.follow_session else loop.time() + 600
    stop_reason = None
    try:
        while not stop.is_set() and loop.time() < deadline:
            stop_reason = guard.stop_reason()
            if stop_reason:
                break
            write_status(args.status_file, stats)
            try:
                await asyncio.wait_for(stop.wait(), 1)
            except TimeoutError:
                pass
    finally:
        stop.set()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        write_status(args.status_file, stats, stop_reason or 'helper_exit')
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.remove_signal_handler(sig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session-file', required=True, type=Path)
    parser.add_argument('--follow-session', action='store_true',
                        help='Continue while the same host session is alive')
    parser.add_argument('--status-file', type=Path)
    parser.add_argument('--mux-socket', default='/var/run/usbmuxd', help=argparse.SUPPRESS)
    try:
        asyncio.run(run(parser.parse_args()))
    except (Rejected, OSError, ValueError, KeyError) as error:
        # Errors can contain local paths. Only report stable codes or names.
        print(json.dumps({'error': str(error) if isinstance(error, Rejected) else type(error).__name__}), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
