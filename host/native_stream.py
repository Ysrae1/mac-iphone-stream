"""Bounded native GSV1/GSA1 stream; stdlib only, inert until authorized open()."""
from collections import deque
from dataclasses import dataclass, field, replace
import os
import math
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import threading
import time

from tcp_diagnostics import read_tcp_snapshot

HEADER = struct.Struct(">4sIQII")
MAX_PAYLOAD = 4 * 1024 * 1024
MAX_AUDIO_PAYLOAD = 48_000 * 2 * 4 // 10  # at most 100 ms per packet
START_CODE = re.compile(b"\x00\x00(?:\x00)?\x01")
DEFAULT_CAPTURE = Path(__file__).resolve().parent.parent / "macos/build/StreamCapture.app/Contents/MacOS/StreamCapture"


class NativeError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code
        super().__init__(code)


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class Record:
    kind: bytes
    timestamp_us: int
    a: int
    b: int
    payload: bytes
    keyframe: bool = False
    read_uptime_s: float = field(default=0.0, compare=False, repr=False)

    def wire(self):
        return HEADER.pack(self.kind, len(self.payload), self.timestamp_us, self.a, self.b) + self.payload


def parse_header(header):
    if len(header) != HEADER.size:
        raise ProtocolError("truncated_header")
    kind, length, timestamp, a, b = HEADER.unpack(header)
    if kind not in (b"GSV1", b"GSA1", b"GSH1"):
        raise ProtocolError("invalid_magic")
    if not 1 <= length <= MAX_PAYLOAD:
        raise ProtocolError("invalid_payload_length")
    if kind == b"GSV1" and not (1 <= a <= 4096 and 1 <= b <= 4096):
        raise ProtocolError("invalid_dimensions")
    if kind == b"GSA1" and (a != 48000 or b != 2 or length % 8 or length > MAX_AUDIO_PAYLOAD):
        raise ProtocolError("invalid_audio_format")
    if kind == b"GSH1" and (length != 1 or a != 0 or b != 0):
        raise ProtocolError("invalid_idle_heartbeat")
    return kind, length, timestamp, a, b


def parse_record(header, payload):
    kind, length, timestamp, a, b = parse_header(header)
    if len(payload) != length:
        raise ProtocolError("truncated_payload")
    if kind == b"GSH1" and payload != b"\0":
        raise ProtocolError("invalid_idle_heartbeat")
    keyframe = False
    if kind == b"GSV1":
        previous = None
        nal_types = set()
        for start in START_CODE.finditer(payload):
            if previous is None and start.start() != 0:
                raise ProtocolError("annex_b_required")
            if previous is not None and previous.end() >= start.start():
                raise ProtocolError("empty_nal")
            if start.end() >= len(payload):
                raise ProtocolError("empty_nal")
            nal = payload[start.end()]
            if nal & 128 or not 1 <= nal & 31 <= 23:
                raise ProtocolError("invalid_nal")
            nal_types.add(nal & 31)
            previous = start
        if previous is None or not nal_types.intersection({1, 5}):
            raise ProtocolError("access_unit_missing_picture")
        keyframe = 5 in nal_types
        if keyframe and not {7, 8}.issubset(nal_types):
            raise ProtocolError("idr_missing_parameter_sets")
    return Record(kind, timestamp, a, b, payload, keyframe)


def read_exact(reader, length, *, clean_eof=False):
    data = bytearray()
    while len(data) < length:
        chunk = reader.read(length - len(data))
        if not chunk:
            if clean_eof and not data:
                return None
            raise ProtocolError("truncated_stream")
        data.extend(chunk)
    return bytes(data)


def read_record(reader):
    header = read_exact(reader, HEADER.size, clean_eof=True)
    if header is None:
        return None
    _, length, _, _, _ = parse_header(header)
    return parse_record(header, read_exact(reader, length))


class LiveBuffer:
    """Bound video by three packets/4 MiB; audio by 80 ms (one 100 ms packet allowed)."""
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.condition = threading.Condition()
        self.queue = deque()
        self.closed = False
        self.waiting_idr = True
        self.video_dropped = self.audio_dropped = 0
        self.need_keyframe = False
        self.observations = dict(video_queue_age_max_ms=0.0, audio_queue_age_max_ms=0.0,
                                 video_pop_age_max_ms=0.0, audio_pop_age_max_ms=0.0,
                                 video_drop_age=0, video_drop_capacity=0,
                                 video_drop_waiting_idr=0, audio_drop_age=0,
                                 audio_drop_capacity=0)

    def _observe_ages(self, now):
        for at, record in self.queue:
            key = "video_queue_age_max_ms" if record.kind == b"GSV1" else "audio_queue_age_max_ms"
            self.observations[key] = max(self.observations[key], max(0, now - at) * 1000)

    def snapshot(self):
        with self.condition:
            self._observe_ages(self.clock())
            return dict(self.observations)

    def _drop_video(self, reason):
        dropped = sum(record.kind == b"GSV1" for _, record in self.queue)
        self.video_dropped += dropped
        self.observations["video_drop_" + reason] += dropped
        self.queue = deque((at, record) for at, record in self.queue if record.kind != b"GSV1")
        self.waiting_idr = True
        self.need_keyframe = True

    def _purge(self):
        now = self.clock()
        self._observe_ages(now)
        if any(record.kind == b"GSV1" and now - at > .15 for at, record in self.queue):
            self._drop_video("age")
        old = len(self.queue)
        self.queue = deque((at, record) for at, record in self.queue
                           if record.kind != b"GSA1" or now - at <= .08)
        self.audio_dropped += old - len(self.queue)
        self.observations["audio_drop_age"] += old - len(self.queue)

    def push(self, record):
        with self.condition:
            if self.closed:
                return
            self._purge()
            if record.kind == b"GSV1":
                if (sum(r.kind == b"GSV1" for _, r in self.queue) >= 3
                        or sum(len(r.payload) for _, r in self.queue if r.kind == b"GSV1")
                        + len(record.payload) > MAX_PAYLOAD):
                    self._drop_video("capacity")
                if self.waiting_idr and not record.keyframe:
                    self.video_dropped += 1
                    self.observations["video_drop_waiting_idr"] += 1
                    self.need_keyframe = True
                    return
                self.waiting_idr = False
                self.need_keyframe = False
            else:
                # Bound both elapsed queued age and the duration of queued PCM.
                while (sum(len(r.payload) for _, r in self.queue if r.kind == b"GSA1")
                       + len(record.payload) > 48000 * 2 * 4 * .08):
                    old_audio = next((i for i, (_, r) in enumerate(self.queue) if r.kind == b"GSA1"), None)
                    if old_audio is None:
                        break
                    del self.queue[old_audio]
                    self.audio_dropped += 1
                    self.observations["audio_drop_capacity"] += 1
            self.queue.append((self.clock(), record))
            self.condition.notify()

    def pop(self, timeout=.1):
        with self.condition:
            self._purge()
            if not self.queue and not self.closed:
                self.condition.wait(timeout)
                self._purge()
            if not self.queue:
                return None
            at, record = self.queue.popleft()
            key = "video_pop_age_max_ms" if record.kind == b"GSV1" else "audio_pop_age_max_ms"
            self.observations[key] = max(self.observations[key], max(0, self.clock() - at) * 1000)
            return record

    def take_keyframe_request(self):
        with self.condition:
            requested = self.need_keyframe
            self.need_keyframe = False
            return requested

    def close(self):
        with self.condition:
            self.closed = True
            self.queue.clear()
            self.condition.notify_all()


def fresh_metrics():
    return dict(av_path_event_sequence=0, av_path_recent_events=[],
                av_path_capture_packets=0, av_path_send_packets=0,
                av_path_capture_video_first_pts_us=None, av_path_capture_audio_first_pts_us=None,
                av_path_capture_video_last_pts_us=None, av_path_capture_audio_last_pts_us=None,
                av_path_send_video_first_pts_us=None, av_path_send_audio_first_pts_us=None,
                av_path_send_video_last_pts_us=None, av_path_send_audio_last_pts_us=None,
                stream_elapsed_seconds=0.0, payload_bytes_received=0, payload_bytes_sent=0,
                http_chunk_bytes_sent=0, send_calls=0, send_failures=0,
                send_duration_ms_total=0.0, send_duration_ms_max=0.0,
                video_send_duration_ms_total=0.0, video_send_duration_ms_max=0.0,
                audio_send_duration_ms_total=0.0, audio_send_duration_ms_max=0.0,
                socket_send_buffer_bytes=None, socket_send_buffer_read_failed=False,
                socket_send_buffer_initial_bytes=None, socket_send_buffer_bytes_max=None,
                tcp_info_available=False, tcp_info_sample_count=0,
                socket_pending_bytes_available=False, socket_pending_bytes=None,
                socket_pending_bytes_sampled_max=None,
                tcp_send_buffer_used_bytes_sampled_max=None)


@dataclass(eq=False)
class StreamPeer:
    controller: str
    owner_generation: object
    buffer: LiveBuffer
    process: object = None
    started: float = 0
    last_packet: float = 0
    last_keyframe: float = -1
    idle_heartbeat: Record | None = None
    stopped: threading.Event = field(default_factory=threading.Event)
    metrics: dict = field(default_factory=fresh_metrics)
    connection: object = None
    last_socket_observation: float = 0
    previous_path_read: dict = field(default_factory=dict)
    previous_path_send: dict = field(default_factory=dict)


class NativeStreamService:
    """One owner, one stream. Host and service share the relay RLock.

    owner_is_current(controller, lease) authorizes a new GET. owner_is_alive
    checks controller + generation, allowing reset(false) to rotate only lease.
    release_owner is called under the shared lock, only for the current peer;
    replacement, explicit stop and already-invalid owners never release a new peer.
    """
    def __init__(self, *, window_id, width=1280, fps=30, bitrate=6_000_000, audio=True, client_rect=None,
                 send_buffer_mode="64k",
                 capture_command=None, lock=None, owner_is_current=None,
                 owner_is_alive=None, release_owner=None, clock=time.monotonic,
                 process_factory=subprocess.Popen):
        if type(window_id) is not int or not 1 <= window_id <= 0xffffffff:
            raise ValueError("one explicit positive window_id is required")
        if type(width) is not int or not 320 <= width <= 3840 or type(fps) is not int or fps not in (30, 60):
            raise ValueError("invalid capture dimensions/rate")
        if type(bitrate) is not int or not 250_000 <= bitrate <= 160_000_000:
            raise ValueError("bitrate must be 250000..160000000 bits per second")
        if send_buffer_mode not in ("64k", "system"):
            raise ValueError("send_buffer_mode must be 64k or system")
        self.send_buffer_mode = send_buffer_mode
        rect = (0, 0, 1, 1) if client_rect is None else client_rect
        if (not isinstance(rect, (tuple, list)) or len(rect) != 4
                or any(type(value) not in (int, float) or not math.isfinite(value) for value in rect)
                or not (0 <= rect[0] < 1 and 0 <= rect[1] < 1 and 0 < rect[2] <= 1 and 0 < rect[3] <= 1)
                or rect[0] + rect[2] > 1 or rect[1] + rect[3] > 1):
            raise ValueError("client_rect must be normalized x,y,width,height within the window")
        command = [str(DEFAULT_CAPTURE)] if capture_command is None else list(capture_command)
        if not command or not all(isinstance(arg, str) and arg for arg in command):
            raise ValueError("capture command must be nonempty")
        self.command = command + ["--window-id", str(window_id), "--width", str(width), "--fps", str(fps),
                                  "--bitrate", str(bitrate)]
        if audio:
            self.command.append("--audio")
        self.lock = lock or threading.RLock()
        self.owner_is_current = owner_is_current
        self.owner_is_alive = owner_is_alive
        self.release_owner = release_owner
        self.clock, self.process_factory = clock, process_factory
        self._peer = None
        self._previous_path_metrics = None
        self._closed = False
        self._reapers = []
        self._snapshot = dict(available=os.access(command[0], os.X_OK), transport="native",
                              state="ready", active=False, capture_scope="window",
                              window_id=window_id, width=width, height=None, fps=fps, bitrate=bitrate,
                              send_buffer_mode=send_buffer_mode,
                              audio=audio, client_rect_normalized=dict(zip(("x", "y", "width", "height"), rect)),
                              client_rect_source="whole_window_unverified" if client_rect is None else "configured",
                              frames_received=0, frames_sent=0,
                              frames_dropped=0, audio_packets_received=0,
                              audio_packets_sent=0, audio_packets_dropped=0,
                              capture_pid=None, last_error=None, metrics=fresh_metrics())

    def status(self):
        with self.lock:
            result = dict(self._snapshot)
            if self._previous_path_metrics is not None:
                result["previous_av_path"] = {k: v for k, v in self._previous_path_metrics.items() if k.startswith("av_path_")}
            result["client_rect_normalized"] = dict(result["client_rect_normalized"])
            metrics = dict(result["metrics"])
            if self._peer:
                result["frames_dropped"] = self._peer.buffer.video_dropped
                result["audio_packets_dropped"] = self._peer.buffer.audio_dropped
                metrics.update(self._peer.buffer.snapshot())
                metrics["stream_elapsed_seconds"] = max(0, self.clock() - self._peer.started)
            elapsed = metrics["stream_elapsed_seconds"]
            metrics["payload_receive_bytes_per_second"] = metrics["payload_bytes_received"] / elapsed if elapsed else 0.0
            metrics["payload_send_bytes_per_second"] = metrics["payload_bytes_sent"] / elapsed if elapsed else 0.0
            metrics["http_send_bytes_per_second"] = metrics["http_chunk_bytes_sent"] / elapsed if elapsed else 0.0
            result["metrics"] = {key: round(value, 3) if type(value) is float else value for key, value in metrics.items()}
            return result

    def has_active_owner(self, controller, generation):
        """Shared-lock query only: input expiry must not stop a matching live stream."""
        with self.lock:
            peer = self._peer
            return bool(peer is not None and not peer.stopped.is_set()
                        and peer.controller == controller and peer.owner_generation is generation)

    def open(self, *, controller, lease, owner_generation):
        with self.lock:
            if self._closed:
                raise NativeError(503, "native_closed")
            if (not controller or self.owner_is_current is None
                    or not self.owner_is_current(controller, lease)):
                raise NativeError(409, "session_not_owned")
            if not self._snapshot["available"]:
                raise NativeError(503, "capture_helper_missing")
            if self._peer is not None:
                if self._peer.controller != controller:
                    raise NativeError(409, "native_controller_busy")
                self._end_locked(self._peer, "replaced", release=False)
            peer = StreamPeer(controller, owner_generation, LiveBuffer(self.clock),
                              started=self.clock(), last_packet=self.clock())
            peer.metrics["av_path_started_uptime_s"] = peer.started
            try:
                peer.process = self.process_factory(self.command, stdin=subprocess.DEVNULL,
                                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                                    bufsize=0, close_fds=True)
            except OSError:
                self._snapshot.update(state="error", last_error="capture_start_failed")
                raise NativeError(503, "capture_start_failed") from None
            self._peer = peer
            self._snapshot.update(state="starting", active=True, last_error=None,
                                  capture_pid=peer.process.pid, frames_received=0, frames_sent=0,
                                  frames_dropped=0, audio_packets_received=0,
                                  audio_packets_sent=0, audio_packets_dropped=0, height=None,
                                  metrics=peer.metrics)
            threading.Thread(target=self._read, args=(peer,), name="native-capture", daemon=True).start()
            return peer

    def _read(self, peer):
        last_timestamp = {}
        error = "capture_ended"
        try:
            while not peer.stopped.is_set():
                read_began = self.clock()
                record = read_record(peer.process.stdout)
                read_ended = self.clock()
                if record is None:
                    break
                if record.timestamp_us <= last_timestamp.get(record.kind, -1):
                    raise ProtocolError("non_monotonic_timestamp")
                last_timestamp[record.kind] = record.timestamp_us
                record = replace(record, read_uptime_s=read_ended)
                with self.lock:
                    if self._peer is not peer:
                        return
                    peer.last_packet = self.clock()
                    if record.kind == b"GSH1":
                        peer.idle_heartbeat = record
                        continue
                    if record.kind == b"GSV1":
                        peer.idle_heartbeat = None
                    previous = peer.previous_path_read.get(record.kind)
                    elapsed_ms = (read_ended - previous[1]) * 1000 if previous else 0.0
                    wait_ms = (read_ended - read_began) * 1000
                    self._path_coverage(peer, record, "capture")
                    if wait_ms >= 50 or elapsed_ms >= 50:
                        self._path_event(peer, record, 1, read_began, read_ended, previous,
                                         read_wait_ms=wait_ms, packet_interval_ms=elapsed_ms)
                    peer.previous_path_read[record.kind] = (record.timestamp_us, read_ended)
                    peer.metrics["payload_bytes_received"] += len(record.payload)
                    if record.kind == b"GSV1":
                        self._snapshot["frames_received"] += 1
                        self._snapshot.update(width=record.a, height=record.b)
                    else:
                        self._snapshot["audio_packets_received"] += 1
                peer.buffer.push(record)
                self.request_keyframe_if_needed(peer)
        except ProtocolError:
            error = "capture_protocol_error"
        except (OSError, ValueError):
            error = "capture_read_failed"
        finally:
            self.finish(peer, error)

    def request_keyframe_if_needed(self, peer):
        if not peer.buffer.take_keyframe_request():
            return
        with self.lock:
            if self._peer is peer and self.clock() - peer.last_keyframe >= .15:
                peer.last_keyframe = self.clock()
                try:
                    peer.process.send_signal(signal.SIGUSR1)
                except OSError:
                    pass

    def configure_socket(self, peer, connection):
        # Exactly one experiment variable: retain the 64 KiB baseline or leave
        # SO_SNDBUF entirely untouched. Never choose an arbitrary larger buffer.
        try:
            initial = connection.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
        except OSError:
            initial = None
        with self.lock:
            peer.connection = connection
            peer.metrics["socket_send_buffer_initial_bytes"] = initial
        if self.send_buffer_mode == "64k":
            connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
        self.observe_socket(peer, connection)

    def observe_socket(self, peer, connection):
        # Read this connection's effective value, never global network settings.
        try:
            actual = connection.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
        except OSError:
            actual = None
        transport = read_tcp_snapshot(connection)
        with self.lock:
            peer.metrics.update(transport)
            if transport["tcp_info_available"]:
                peer.metrics["tcp_info_sample_count"] += 1
                peer.metrics["tcp_send_buffer_used_bytes_sampled_max"] = max(
                    transport["tcp_send_buffer_used_bytes"], peer.metrics["tcp_send_buffer_used_bytes_sampled_max"] or 0)
            if transport["socket_pending_bytes_available"]:
                peer.metrics["socket_pending_bytes_sampled_max"] = max(
                    transport["socket_pending_bytes"], peer.metrics["socket_pending_bytes_sampled_max"] or 0)
            peer.metrics["socket_send_buffer_bytes"] = actual
            peer.metrics["socket_send_buffer_read_failed"] = actual is None
            if actual is not None:
                peer.metrics["socket_send_buffer_bytes_max"] = max(
                    actual, peer.metrics["socket_send_buffer_bytes_max"] or 0)
            peer.last_socket_observation = self.clock()

    @staticmethod
    def _path_coverage(peer, record, stage):
        # Caller holds service lock. Numeric coverage distinguishes no anomaly
        # from an uninstrumented/overwritten interval. No wire bytes are changed.
        metrics = peer.metrics
        metrics["av_path_" + stage + "_packets"] += 1
        prefix = "av_path_" + stage + ("_video" if record.kind == b"GSV1" else "_audio")
        if metrics[prefix + "_first_pts_us"] is None:
            metrics[prefix + "_first_pts_us"] = record.timestamp_us
        metrics[prefix + "_last_pts_us"] = record.timestamp_us

    @staticmethod
    def _path_event(peer, record, stage, began, ended, previous, **fields):
        metrics = peer.metrics
        metrics["av_path_event_sequence"] += 1
        event = dict(stage=stage, sequence=metrics["av_path_event_sequence"],
                     packet_kind=1 if record.kind == b"GSV1" else 2,
                     source_timestamp_us=record.timestamp_us,
                     begin_uptime_s=began, end_uptime_s=ended, **fields)
        if previous is not None:
            event.update(previous_source_timestamp_us=previous[0], previous_end_uptime_s=previous[1])
        # Replace rather than mutate: an already-returned status snapshot remains coherent.
        metrics["av_path_recent_events"] = (metrics["av_path_recent_events"] + [event])[-64:]

    def write_idle_heartbeat(self, peer, writer):
        with self.lock:
            record, peer.idle_heartbeat = peer.idle_heartbeat, None
            if (self._peer is not peer or not self._snapshot["frames_sent"] or record is None
                    or self.clock() - record.read_uptime_s > .75):
                return
        wire = record.wire()
        writer.write(f"{len(wire):x}\r\n".encode() + wire + b"\r\n")

    def write_record(self, peer, record, writer):
        wire = record.wire()
        chunk = f"{len(wire):x}\r\n".encode() + wire + b"\r\n"
        connection = peer.connection
        if connection is not None and self.clock() - peer.last_socket_observation >= 1:
            self.observe_socket(peer, connection)
        started = self.clock()
        success = False
        try:
            writer.write(chunk)  # BaseHTTPRequestHandler's unbuffered sendall.
            success = True
        finally:
            ended = self.clock()
            milliseconds = max(0, ended - started) * 1000
            kind = "video" if record.kind == b"GSV1" else "audio"
            with self.lock:
                metrics = peer.metrics  # An old peer never mutates replacement metrics.
                previous = peer.previous_path_send.get(record.kind)
                interval_ms = (started - previous[1]) * 1000 if previous else 0.0
                queue_ms = max(0, started - record.read_uptime_s) * 1000 if record.read_uptime_s else 0.0
                self._path_coverage(peer, record, "send")
                if milliseconds >= 50 or queue_ms >= 50 or interval_ms >= 50 or not success:
                    self._path_event(peer, record, 2, started, ended, previous,
                                     send_ms=milliseconds, queue_wait_ms=queue_ms,
                                     packet_interval_ms=interval_ms, success=int(success),
                                     read_uptime_s=record.read_uptime_s)
                peer.previous_path_send[record.kind] = (record.timestamp_us, ended)
                metrics["send_calls"] += 1
                metrics["send_failures"] += int(not success)
                metrics["send_duration_ms_total"] += milliseconds
                metrics["send_duration_ms_max"] = max(metrics["send_duration_ms_max"], milliseconds)
                metrics[kind + "_send_duration_ms_total"] += milliseconds
                metrics[kind + "_send_duration_ms_max"] = max(metrics[kind + "_send_duration_ms_max"], milliseconds)
                if success:
                    metrics["http_chunk_bytes_sent"] += len(chunk)
        self.sent(peer, record)

    def sent(self, peer, record):
        with self.lock:
            if self._peer is peer:
                key = "frames_sent" if record.kind == b"GSV1" else "audio_packets_sent"
                self._snapshot[key] += 1
                peer.metrics["payload_bytes_sent"] += len(record.payload)
                if record.kind == b"GSV1":
                    self._snapshot["state"] = "streaming"

    @staticmethod
    def _reap(process):
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except OSError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        finally:
            if process.stdout:
                process.stdout.close()

    def _end_locked(self, peer, reason, release):
        if self._peer is not peer:
            return False
        self._peer = None
        # Preserve this metrics object: a blocked final send may complete after stop.
        self._previous_path_metrics = peer.metrics
        peer.metrics["av_path_ended_uptime_s"] = self.clock()
        peer.stopped.set()
        peer.connection = None
        peer.metrics.update(peer.buffer.snapshot())
        peer.metrics["stream_elapsed_seconds"] = max(0, self.clock() - peer.started)
        peer.buffer.close()
        self._snapshot.update(active=False, state="stopped" if reason in
                              ("stopped", "replaced", "server_shutdown", "owner_expired") else "error",
                              capture_pid=None, frames_dropped=peer.buffer.video_dropped,
                              audio_packets_dropped=peer.buffer.audio_dropped,
                              last_error=None if reason in ("stopped", "replaced", "server_shutdown", "owner_expired") else reason)
        try:
            peer.process.terminate()
        except OSError:
            pass
        self._reapers = [thread for thread in self._reapers if thread.is_alive()]
        reaper = threading.Thread(target=self._reap, args=(peer.process,), name="native-reap", daemon=True)
        self._reapers.append(reaper)
        reaper.start()
        if release and self.release_owner:
            self.release_owner(peer.controller, peer.owner_generation)
        return True

    def finish(self, peer, reason="stream_disconnected"):
        with self.lock:
            self._end_locked(peer, reason, release=True)

    def tick(self):
        with self.lock:
            peer = self._peer
            if peer is None:
                return
            if self.owner_is_alive and not self.owner_is_alive(peer.controller, peer.owner_generation):
                self._end_locked(peer, "owner_expired", release=False)
            elif self.clock() - peer.last_packet > 10:
                self._end_locked(peer, "capture_timeout", release=True)

    def stop(self, *, controller=None, lease=None):
        with self.lock:
            if self._peer and (controller is None or self._peer.controller == controller):
                self._end_locked(self._peer, "stopped", release=False)

    def close(self):
        with self.lock:
            self._closed = True
            if self._peer:
                self._end_locked(self._peer, "server_shutdown", release=False)
            reapers = list(self._reapers)
        for thread in reapers:
            thread.join(timeout=2.2)
