"""Mac iPhone Stream host for one explicitly selected window."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import quote, urlencode

from native_stream import NativeStreamService
from relay import Relay, Server
import trust


ROOT = Path(__file__).resolve().parent
SERVICE_TYPE = "_miph-stream._tcp"
MAX_COMMAND = 8192


def terminate(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def lan_address():
    # Determine the OS-selected source address without transmitting a packet.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            probe.connect(("192.0.2.1", 9))
            chosen = probe.getsockname()[0]
        except OSError:
            return None
    return chosen if trust.private_peer(chosen) and not chosen.startswith("127.") else None


class Output:
    def __init__(self):
        self.lock = threading.Lock()

    def send(self, value):
        line = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        with self.lock:
            try:
                print(line, flush=True)
            except BrokenPipeError:
                pass  # Closing stdin also tears down this host.


class Session:
    def __init__(self, address, state_dir, capture, window_id, window_pid, on_touch, use_usb):
        self.relay = Relay(on_touch)
        command = [str(capture)]
        if window_pid is not None:
            command.extend(["--window-pid", str(window_pid)])
        self.relay.native = NativeStreamService(
            window_id=window_id, width=1920, fps=60, bitrate=20_000_000,
            capture_command=command, client_rect=(0, 0, 1, 1) if on_touch else None,
            lock=self.relay.lock, owner_is_current=self.relay.owns,
            owner_is_alive=self.relay.alive, release_owner=self.relay.release_native,
        )
        self.server = Server((address, 0), self.relay)
        self.port = self.server.server_port
        self.worker = threading.Thread(target=self.server.serve_forever, args=(.1,), daemon=True)
        self.transport = None
        self.runtime = None
        self.usb_state = "unavailable"
        try:
            if use_usb:
                self.prepare_usb(state_dir)
            self.worker.start()
        except BaseException:
            self.server.server_close()
            self.clean_usb()
            raise

    def prepare_usb(self, state_dir):
        self.runtime = tempfile.TemporaryDirectory(dir=state_dir, prefix="session-")
        runtime = Path(self.runtime.name)
        self.usb_session = runtime / "session.json"
        self.usb_status = runtime / "usb.json"
        self.usb_expiration = None
        self.persist_usb_session()
        try:
            self.transport = subprocess.Popen(
                [sys.executable, "-B", str(ROOT / "usb/usb_helper.py"), "--session-file",
                 str(self.usb_session), "--follow-session", "--status-file", str(self.usb_status)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            self.usb_state = "waiting"
        except OSError:
            self.clean_usb()

    def persist_usb_session(self):
        expiry = self.relay.wall_offset + self.relay.deadline
        if expiry != self.usb_expiration:
            trust.atomic_json(
                self.usb_session,
                {"host": "127.0.0.1", "port": self.port, "token": self.relay.token,
                 "pid": os.getpid(), "expires_at": expiry},
            )
            self.usb_expiration = expiry

    def clean_usb(self):
        try:
            terminate(self.transport)
        finally:
            self.transport = None
            if self.runtime is not None:
                self.runtime.cleanup()
                self.runtime = None
            self.usb_state = "unavailable"

    def maintain(self):
        if not self.relay.tick():
            return False
        if self.transport is not None:
            if self.transport.poll() is not None:
                self.clean_usb()
            else:
                try:
                    self.persist_usb_session()
                except OSError:
                    self.clean_usb()
        return True

    def usb(self):
        if self.transport is not None:
            try:
                status = json.loads(self.usb_status.read_text())
                if time.time() - status["updated_at"] <= 4:
                    value = status.get("state")
                    if value in ("waiting", "connected", "unavailable"):
                        return value
            except (OSError, ValueError, KeyError, TypeError):
                pass
        return self.usb_state

    def url(self, address):
        return f"http://{address}:{self.port}/#token={self.relay.token}"

    def close(self):
        try:
            self.relay.close()
        finally:
            try:
                self.server.shutdown()
                self.server.server_close()
            finally:
                self.clean_usb()


class Host:
    def __init__(self, args, output):
        self.args = args
        self.output = output
        self.lock = threading.RLock()
        self.window_id = self.window_pid = None
        self.demo = False
        self.session = None
        self.service_error = None
        self.trust = None
        self.trust_server = None
        self.advertiser = None
        self.address = None

    def begin(self):
        host_id, tls = trust.identity(self.args.state_dir)
        self.trust = trust.Trust(self.args.state_dir, host_id)
        server = trust.HTTPServer((self.args.bind, 0), trust.Handler)
        server.trust = self.trust
        server.tls = tls
        server.operation = self.remote
        thread = threading.Thread(target=server.serve_forever, args=(.1,), daemon=True)
        try:
            thread.start()
        except RuntimeError:
            server.server_close()
            raise
        self.trust_server = server
        if not self.args.no_bonjour:
            try:
                self.advertiser = subprocess.Popen(
                    ["/usr/bin/dns-sd", "-R", self.trust.name, SERVICE_TYPE, "local.",
                     str(server.server_port), "protocol=1", "host_id=" + host_id],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except OSError:
                pass  # Direct QR/address pairing is still available.

    def maintain(self):
        with self.lock:
            if self.session is not None and not self.session.maintain():
                self.stop_stream()

    def touch(self, contacts):
        self.output.send({"event": "touch", "contacts": contacts})

    def start_stream(self):
        if self.session is not None:
            return
        if self.window_id is None:
            raise trust.Rejected("select_window_first")
        if not self.args.capture.is_file() or not os.access(self.args.capture, os.X_OK):
            raise trust.Rejected("capture_helper_missing")
        self.session = Session(
            self.args.bind, self.args.state_dir, self.args.capture, self.window_id,
            self.window_pid, self.touch if self.demo else None, not self.args.no_usb,
        )

    def stop_stream(self):
        current, self.session = self.session, None
        if current is not None:
            current.close()

    def select(self, request):
        window_id = request.get("window_id")
        window_pid = request.get("window_pid")
        demo = request.get("demo", False)
        if (window_id is not None and (type(window_id) is not int or not 1 <= window_id <= 0xffffffff)
                or window_pid is not None and (type(window_pid) is not int or not 1 <= window_pid <= 0x7fffffff)
                or type(demo) is not bool):
            raise trust.Rejected("invalid_window")
        if window_id is None:
            window_pid, demo = None, False
        if (window_id, window_pid, demo) != (self.window_id, self.window_pid, self.demo):
            self.stop_stream()
            self.window_id, self.window_pid, self.demo = window_id, window_pid, demo

    def remote(self, operation, local_ip, device_id):
        with self.lock:
            with self.trust.lock:
                if device_id not in self.trust.devices:
                    raise trust.Rejected("untrusted_device", 403)
            if operation == "start":
                try:
                    self.start_stream()
                except trust.Rejected as error:
                    message = "请先在 Mac 主机中选一个窗口。" if error.code == "select_window_first" else "Mac 无法启动串流。"
                    return {"state": "error", "message": message}
                except OSError:
                    return {"state": "error", "message": "Mac 无法启动串流。"}
            if self.session is None:
                return {"state": "stopped", "message": "Mac 串流已停止。"}
            return {"state": self.stream_state(), "url": self.session.url(local_ip)}

    def stream_state(self):
        if self.session is None:
            return "idle"
        media = self.session.relay.native.status()
        return "connected" if media.get("active") else "waiting"

    def status(self):
        trust_status = (self.trust.local({"command": "status"}) if self.trust is not None else
                        {"pairing_open": False, "pending": [], "devices": []})
        address = self.address
        invitation = None
        if address and trust_status["pairing_open"] and self.trust_server is not None:
            fragment = urlencode(
                {"gs-pair": 1, "host_id": self.trust.host_id, "service": self.trust.name, "domain": "local."},
                quote_via=quote,
            )
            invitation = f"https://{address}:{self.trust_server.server_port}/#{fragment}"
        media_error = self.session.relay.native.status().get("last_error") if self.session else None
        # A client disconnect is expected and permits another client to connect.
        if media_error in ("stream_disconnected", "stopped", "replaced", "owner_expired"):
            media_error = None
        return {
            "service_error": self.service_error or media_error,
            "window_id": self.window_id,
            "stream": self.stream_state(),
            "connection_url": self.session.url(address or "127.0.0.1") if self.session else None,
            "invitation": invitation,
            "pairing_open": trust_status["pairing_open"],
            "pending": trust_status["pending"],
            "devices": trust_status["devices"],
            "usb": self.session.usb() if self.session else "idle",
        }

    def command(self, request):
        command = request.get("command")
        with self.lock:
            if command in ("status", "start", "open-pairing"):
                self.address = self.args.bind if self.args.bind != "0.0.0.0" else lan_address()
            if command == "select":
                self.select(request)
            elif command == "start":
                self.start_stream()
            elif command == "stop":
                self.stop_stream()
            elif command in ("open-pairing", "close-pairing", "approve", "deny", "revoke"):
                if self.trust_server is None:
                    raise trust.Rejected("trust_unavailable")
                self.trust.local(request)
                if command == "revoke":
                    self.stop_stream()  # Revocation must also invalidate issued media tokens.
            elif command != "status":
                raise trust.Rejected("invalid_command")
            return self.status()

    def close(self):
        try:
            with self.lock:
                self.stop_stream()
        finally:
            try:
                if self.trust_server is not None:
                    self.trust_server.shutdown()
                    self.trust_server.server_close()
            finally:
                terminate(self.advertiser)


def serve(args):
    output = Output()
    trust.private_directory(args.state_dir)
    path = args.state_dir / "host.lock"
    with os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            output.send({"event": "error", "error": "host_already_running"})
            return 1
        stop = threading.Event()
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, lambda *_: stop.set())
        host = Host(args, output)
        try:
            try:
                host.begin()
            except (OSError, ValueError, trust.Rejected, subprocess.TimeoutExpired):
                host.service_error = "trust_unavailable"

            commands = queue.Queue(maxsize=16)

            def read_commands():
                buffered = bytearray()
                while not stop.is_set():
                    try:
                        chunk = os.read(sys.stdin.fileno(), MAX_COMMAND)
                    except OSError:
                        break
                    if not chunk:
                        break
                    buffered.extend(chunk)
                    while (end := buffered.find(b"\n")) >= 0:
                        if end + 1 > MAX_COMMAND:
                            commands.put(None)
                            return
                        commands.put(bytes(buffered[:end + 1]))
                        del buffered[:end + 1]
                    if len(buffered) >= MAX_COMMAND:
                        break
                commands.put(None)

            threading.Thread(target=read_commands, daemon=True).start()
            while not stop.is_set():
                host.maintain()
                try:
                    raw = commands.get(timeout=.05)
                except queue.Empty:
                    continue
                if raw is None:
                    break
                identifier = None
                try:
                    request = json.loads(raw)
                    if not isinstance(request, dict) or type(request.get("id")) is not int:
                        raise ValueError("invalid request id")
                    identifier = request["id"]
                    if request.get("command") == "quit":
                        output.send({"id": identifier, "ok": True, "status": host.status()})
                        break
                    output.send({"id": identifier, "ok": True, "status": host.command(request)})
                except trust.Rejected as error:
                    output.send({"id": identifier, "ok": False, "error": error.code})
                except (OSError, ValueError, TypeError, RecursionError):
                    output.send({"id": identifier, "ok": False, "error": "host_request_failed"})
        finally:
            stop.set()
            host.close()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--bind", default="0.0.0.0", choices=("0.0.0.0", "127.0.0.1"))
    parser.add_argument("--no-bonjour", action="store_true")
    parser.add_argument("--no-usb", action="store_true")
    args = parser.parse_args()
    return serve(args)


if __name__ == "__main__":
    raise SystemExit(main())
