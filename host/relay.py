"""Authenticated LAN/loopback session and application-local touch delivery."""

import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import re
import secrets
import socket
import threading
import time

from native_stream import NativeError
from trust import private_peer

WATCHDOG = 0.8
MAX_BODY = 8192
MAX_CONTACTS = 10
CONTROLLER = re.compile(r"[0-9a-f]{32}")


class Rejected(Exception):
    def __init__(self, status, code):
        self.status = status
        self.code = code
        super().__init__(code)


def parse_contacts(value):
    if not isinstance(value, list) or len(value) > MAX_CONTACTS:
        raise Rejected(400, "invalid_contacts")
    contacts = []
    seen = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"id", "phase", "x", "y"}:
            raise Rejected(400, "invalid_contact")
        ident, phase, x, y = item["id"], item["phase"], item["x"], item["y"]
        if type(ident) is not int or not 1 <= ident <= 0xffffffff or ident in seen:
            raise Rejected(400, "invalid_identity")
        if type(phase) is not int or phase not in (1, 2, 3):
            raise Rejected(400, "invalid_phase")
        if any(type(v) not in (int, float) or not 0 <= v <= 1 or not math.isfinite(v) for v in (x, y)):
            raise Rejected(400, "invalid_coordinate")
        contacts.append({"id": ident, "phase": phase, "x": float(x), "y": float(y)})
        seen.add(ident)
    return contacts


class Relay:
    def __init__(self, on_touch=None, seconds=300, clock=time.monotonic, wall_clock=time.time):
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.RLock()
        self.clock = clock
        self.seconds = seconds
        self.deadline = clock() + seconds
        self.wall_offset = wall_clock() - clock()
        self.on_touch = on_touch
        self.controller = self.lease = self.generation = None
        self.native = None
        self.active = {}
        self.last_frame = self.last_activity = None
        self.input_suspended = False
        self.closed = False
        self.seq = 0

    def require_open(self):
        if self.closed or self.clock() >= self.deadline:
            raise Rejected(410, "expired")

    def auth(self, token):
        if not token.isascii() or not hmac.compare_digest(token, self.token):
            raise Rejected(403, "invalid_token")
        with self.lock:
            self.require_open()

    def owns(self, controller, lease):
        return bool(not self.closed and self.controller and controller == self.controller
                    and lease and lease.isascii() and hmac.compare_digest(lease, self.lease or ""))

    def require_owner(self, controller, lease):
        self.require_open()
        if not self.owns(controller, lease):
            raise Rejected(409, "session_not_owned")

    def alive(self, controller, generation):
        return not self.closed and self.controller == controller and self.generation is generation

    def release_native(self, controller, generation):
        if self.alive(controller, generation):
            self.release(stop=True)

    def start(self, controller, resume=False):
        with self.lock:
            self.require_open()
            if not CONTROLLER.fullmatch(controller):
                raise Rejected(400, "invalid_controller")
            if resume:
                if self.controller != controller or not self.has_media():
                    raise Rejected(409, "session_not_owned")
                self.release()
                self.input_suspended = True
            elif self.controller and self.controller != controller:
                raise Rejected(409, "controller_busy")
            elif not self.controller:
                self.controller = controller
                self.lease = secrets.token_hex(16)
                self.generation = object()
                self.last_frame = self.clock()
            return {"lease": self.lease, **self.status()}

    def emit(self, contacts):
        self.seq += 1
        if self.on_touch:
            self.on_touch(contacts)

    def frame(self, controller, lease, body):
        with self.lock:
            self.require_owner(controller, lease)
            if not isinstance(body, dict) or set(body) != {"contacts"}:
                raise Rejected(400, "invalid_frame")
            contacts = parse_contacts(body["contacts"])
            if self.input_suspended and contacts:
                raise Rejected(409, "input_resync_required")
            if contacts and not self.on_touch:
                raise Rejected(409, "touch_unavailable")
            active = dict(self.active) if contacts else {}
            for contact in contacts:
                ident, phase = contact["id"], contact["phase"]
                if (phase == 1) == (ident in active):
                    raise Rejected(409, "invalid_lifecycle")
                if phase == 3:
                    del active[ident]
                else:
                    active[ident] = contact
            if len(active) > MAX_CONTACTS:
                raise Rejected(409, "too_many_active")
            if contacts or self.active:
                self.emit(contacts)
            else:
                self.seq += 1
            self.active = active
            self.input_suspended = False
            self.last_frame = self.last_activity = self.clock()
            return {"seq": self.seq, **self.status()}

    def release(self, stop=False):
        if self.active:
            self.emit([])
        self.active.clear()
        self.input_suspended = False
        self.last_frame = self.clock()
        if stop:
            self.controller = self.lease = self.generation = self.last_activity = None
        elif self.controller:
            self.lease = secrets.token_hex(16)

    def reset(self, controller, lease, stop):
        with self.lock:
            self.require_owner(controller, lease)
            self.release(stop=stop)
            if stop:
                self.native.stop(controller=controller, lease=lease)
            return {"lease": self.lease, **self.status()}

    def has_media(self):
        return self.native.has_active_owner(self.controller, self.generation)

    def tick(self):
        with self.lock:
            now = self.clock()
            if self.closed or now >= self.deadline:
                return False
            if self.controller and now - self.last_frame >= WATCHDOG:
                if not self.has_media():
                    self.release(stop=True)
                elif not self.input_suspended:
                    self.release()
                    self.input_suspended = True
            if (self.controller and self.last_activity is not None and now - self.last_activity < WATCHDOG
                    and self.deadline - now <= self.seconds / 2):
                self.deadline = now + self.seconds
            self.native.tick()
            return True

    def close(self):
        with self.lock:
            self.closed = True
            self.release(stop=True)
        self.native.close()

    def status(self):
        with self.lock:
            return {
                "running": self.controller is not None,
                "relay_active": len(self.active),
                "input_suspended": self.input_suspended,
                "expires_at": self.wall_offset + self.deadline,
                "capabilities": {},
                "native_video": self.native.status(),
            }


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, relay):
        self.relay = relay
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(address, Handler)

    def verify_request(self, request, address):
        return private_peer(address[0])

    def handle_error(self, request, address):
        pass  # Never log peer addresses, headers, or request bodies.

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MacIPhoneStream/1"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(2)

    def log_message(self, *args):
        pass

    def header(self, name):
        values = self.headers.get_all(name, [])
        return values[0] if len(values) == 1 else ""

    def send_json(self, status, data, keep_alive=False):
        raw = json.dumps(data, separators=(",", ":"), allow_nan=False).encode()
        self.close_connection = self.close_connection or not keep_alive
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def authorize_request(self, post):
        host = self.header("Host")
        local_ip, local_port = self.connection.getsockname()[:2]
        if host != f"{local_ip}:{local_port}":
            raise Rejected(403, "invalid_host")
        origins = self.headers.get_all("Origin", [])
        if (post or origins) and origins != [f"http://{host}"]:
            raise Rejected(403, "invalid_origin")
        self.server.relay.auth(self.header("X-Session-Token"))

    def body(self):
        if self.headers.get_all("Transfer-Encoding"):
            raise Rejected(400, "transfer_encoding_rejected")
        size = self.header("Content-Length")
        if not re.fullmatch(r"[0-9]{1,5}", size):
            raise Rejected(411, "length_required")
        length = int(size)
        if not 1 <= length <= MAX_BODY:
            raise Rejected(413, "body_size")
        if self.header("Content-Type").split(";")[0].strip() != "application/json":
            raise Rejected(415, "json_required")
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError()
            return json.loads(raw)
        except (ValueError, UnicodeError, RecursionError):
            raise Rejected(400, "invalid_json") from None

    def do_GET(self):
        self.dispatch(post=False)

    def do_POST(self):
        self.dispatch(post=True)

    def dispatch(self, post):
        relay = self.server.relay
        try:
            self.authorize_request(post)
            controller = self.header("X-Controller-Id")
            lease = self.header("X-Session-Lease")
            if post and self.path in ("/session", "/frame", "/reset"):
                body = self.body()
                if self.path == "/session":
                    if body == {}:
                        result = relay.start(controller)
                    elif isinstance(body, dict) and set(body) == {"resume"} and body["resume"] is True:
                        result = relay.start(controller, resume=True)
                    else:
                        raise Rejected(400, "invalid_session")
                elif self.path == "/frame":
                    result = relay.frame(controller, lease, body)
                else:
                    if not isinstance(body, dict) or set(body) != {"stop"} or type(body["stop"]) is not bool:
                        raise Rejected(400, "invalid_reset")
                    result = relay.reset(controller, lease, body["stop"])
                self.send_json(200, result, keep_alive=True)
            elif not post and self.path == "/status":
                self.send_json(200, relay.status())
            elif not post and self.path == "/native/status":
                self.send_json(200, relay.native.status())
            elif not post and self.path == "/native/stream":
                self.stream(controller, lease)
            else:
                raise Rejected(404, "not_found")
        except (Rejected, NativeError) as error:
            try:
                self.send_json(error.status, {"error": error.code})
            except OSError:
                self.close_connection = True
        except OSError:
            self.close_connection = True

    def stream(self, controller, lease):
        relay = self.server.relay
        native = relay.native
        with relay.lock:
            relay.require_owner(controller, lease)
            peer = native.open(controller=controller, lease=lease, owner_generation=relay.generation)
        try:
            self.close_connection = True
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            native.configure_socket(peer, self.connection)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            while not peer.stopped.is_set():
                record = peer.buffer.pop(timeout=.1)
                native.request_keyframe_if_needed(peer)
                if record is None:
                    native.write_idle_heartbeat(peer, self.wfile)
                else:
                    native.write_record(peer, record, self.wfile)
            self.wfile.write(b"0\r\n\r\n")
        finally:
            native.finish(peer)
