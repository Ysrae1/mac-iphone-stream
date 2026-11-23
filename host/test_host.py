"""Exercise the real host API with a synthetic, loopback-only capture process."""

import http.client
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import urlsplit

from native_stream import read_record

FIXTURE = r'''#!/usr/bin/env python3
import struct
import sys
import time

def write(kind, timestamp, a, b, payload):
    sys.stdout.buffer.write(struct.pack(">4sIQII", kind, len(payload), timestamp, a, b) + payload)
    sys.stdout.buffer.flush()

write(b"GSV1", 10, 64, 64, b"\x00\x00\x00\x01\x67\x64\x00\x00\x00\x01\x68\x11\x00\x00\x00\x01\x65\x11")
for timestamp in range(1, 100):
    time.sleep(.25)
    write(b"GSH1", timestamp * 250000, 0, 0, b"\0")
'''


class HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        fixture = directory / "capture"
        fixture.write_text(FIXTURE)
        fixture.chmod(0o700)
        self.host = subprocess.Popen(
            [sys.executable, "-B", str(Path(__file__).with_name("main.py")),
             "--state-dir", str(directory / "state"), "--capture", str(fixture),
             "--bind", "127.0.0.1", "--no-bonjour", "--no-usb"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.finish)
        self.lines = queue.Queue()
        self.ident = 0
        self.events = []
        self.controller = "a" * 32

        def receive():
            for raw in self.host.stdout:
                self.lines.put(json.loads(raw))
            self.lines.put(None)

        threading.Thread(target=receive, daemon=True).start()

    def finish(self):
        if self.host.poll() is None:
            self.host.terminate()
        try:
            self.host.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.host.kill()
            self.host.wait(timeout=2)
        for pipe in (self.host.stdin, self.host.stdout, self.host.stderr):
            pipe.close()

    def read_event(self):
        for _ in range(30):
            value = self.lines.get(timeout=4)
            self.assertIsNotNone(value, "host stopped unexpectedly")
            if value.get("event") == "touch":
                return value["contacts"]
        self.fail("no touch event")

    def command(self, command, **arguments):
        self.ident += 1
        message = json.dumps(dict(id=self.ident, command=command, **arguments)).encode() + b"\n"
        self.host.stdin.write(message)
        self.host.stdin.flush()
        for _ in range(30):
            value = self.lines.get(timeout=4)
            self.assertIsNotNone(value, "host stopped unexpectedly")
            if value.get("id") == self.ident:
                return value
            if value.get("event") == "touch":
                self.events.append(value["contacts"])
        self.fail("no host response")

    def select_and_start(self, demo):
        self.assertTrue(self.command("select", window_id=42, window_pid=200, demo=demo)["ok"])
        status = self.command("start")["status"]
        self.assertEqual(status["stream"], "waiting")
        self.link = urlsplit(status["connection_url"])
        self.token = self.link.fragment.removeprefix("token=")

    def request(self, path, body=None, lease=None, token=None):
        connection = http.client.HTTPConnection(self.link.hostname, self.link.port, timeout=3)
        headers = {"Origin": f"http://{self.link.netloc}", "X-Controller-Id": self.controller,
                   "X-Session-Token": self.token if token is None else token}
        if lease is not None:
            headers["X-Session-Lease"] = lease
        if body is not None:
            headers["Content-Type"] = "application/json"
        connection.request("GET" if body is None else "POST", path,
                           None if body is None else json.dumps(body).encode(), headers)
        response = connection.getresponse()
        if path == "/native/stream" and response.status == 200:
            self.addCleanup(connection.close)
            return response
        with response:
            result = response.status, json.loads(response.read())
        connection.close()
        return result

    def touch(self, ident, phase=1):
        return {"id": ident, "phase": phase, "x": .2 * ident, "y": .5}

    def test_demo_stream_idle_heartbeat_watchdog_and_revocation(self):
        self.assertEqual(self.command("start")["error"], "select_window_first")
        self.select_and_start(demo=True)
        self.assertEqual(self.request("/status", token="wrong")[0], 403)
        status, session = self.request("/session", {})
        self.assertEqual(status, 200)
        self.assertEqual(session["native_video"]["client_rect_source"], "configured")
        lease = session["lease"]
        media = self.request("/native/stream", lease=lease)
        self.assertEqual(read_record(media).kind, b"GSV1")
        self.assertEqual(read_record(media).kind, b"GSH1")
        contacts = [self.touch(1), self.touch(2)]
        self.assertEqual(self.request("/frame", {"contacts": contacts}, lease=lease)[0], 200)
        self.assertEqual(self.read_event(), contacts)
        self.assertEqual(self.read_event(), [])  # The input watchdog preserves the live media owner.
        code, session = self.request("/session", {"resume": True})
        self.assertEqual(code, 200)
        self.assertNotEqual(lease, session["lease"])
        self.assertEqual(self.request("/frame", {"contacts": []}, lease=lease)[0], 409)
        self.assertEqual(self.request("/frame", {"contacts": []}, lease=session["lease"])[0], 200)
        _, status = self.request("/status")
        self.assertEqual(status["native_video"]["frames_sent"], 1)
        self.assertEqual(status["native_video"]["audio_packets_sent"], 0)
        self.assertTrue(self.command("stop")["ok"])
        with self.assertRaises(OSError):
            self.request("/status")
        self.assertTrue(self.command("quit")["ok"])
        self.assertEqual(self.host.wait(timeout=4), 0)

    def test_ordinary_window_is_view_only_and_clearing_stops_it(self):
        self.select_and_start(demo=False)
        _, session = self.request("/session", {})
        self.assertEqual(session["native_video"]["client_rect_source"], "whole_window_unverified")
        code, error = self.request("/frame", {"contacts": [self.touch(1)]}, lease=session["lease"])
        self.assertEqual((code, error["error"]), (409, "touch_unavailable"))
        cleared = self.command("select", window_id=None)["status"]
        self.assertIsNone(cleared["window_id"])
        self.assertEqual(cleared["stream"], "idle")
        with self.assertRaises(OSError):
            self.request("/status")
