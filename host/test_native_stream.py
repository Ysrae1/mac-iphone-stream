"""Offline tests: fake pipes/processes only; no sockets or ScreenCaptureKit."""
import io
from pathlib import Path
import signal
import socket
import sys
import threading
import time
import types
import unittest

from native_stream import (DEFAULT_CAPTURE, HEADER, MAX_PAYLOAD, LiveBuffer, NativeError,
                           NativeStreamService, ProtocolError, Record, parse_record,
                           read_record)


def video(timestamp=1, keyframe=False):
    payload = (b"\0\0\0\1\x67\x64\0\0\0\1\x68\x11" if keyframe else b"")
    payload += b"\0\0\0\1" + (b"\x65" if keyframe else b"\x41") + b"\x11"
    return Record(b"GSV1", timestamp, 1280, 720, payload, keyframe)


def audio(timestamp=1, milliseconds=20):
    return Record(b"GSA1", timestamp, 48000, 2, b"\0" * (384 * milliseconds))


class Fragmented(io.BytesIO):
    def read(self, size=-1):
        return super().read(min(size, 3))


class FramingTests(unittest.TestCase):
    def test_fragmented_interleaved_records_and_clean_eof(self):
        source = Fragmented(video(5, True).wire() + audio(3).wire() + video(6).wire())
        self.assertEqual(read_record(source), video(5, True))
        self.assertEqual(read_record(source), audio(3))
        self.assertEqual(read_record(source), video(6))
        self.assertIsNone(read_record(source))
        self.assertEqual(HEADER.size, 24)

    def test_invalid_header_stops_before_unbounded_payload_read(self):
        for fields in ((b"EVIL", 1, 0, 1, 1), (b"GSV1", MAX_PAYLOAD + 1, 0, 1, 1),
                       (b"GSV1", 1, 0, 0, 1), (b"GSA1", 8, 0, 44100, 2),
                       (b"GSA1", 7, 0, 48000, 2), (b"GSA1", 38408, 0, 48000, 2)):
            with self.assertRaises(ProtocolError):
                read_record(io.BytesIO(HEADER.pack(*fields)))

    def test_truncated_and_dependent_keyframes_rejected(self):
        for data in (b"GSV", video().wire()[:-1],
                     HEADER.pack(b"GSV1", 6, 0, 20, 20) + b"\0\0\0\1\x65x"):
            with self.assertRaises(ProtocolError): read_record(io.BytesIO(data))


class BackpressureTests(unittest.TestCase):
    def setUp(self):
        self.now = 1.0
        self.queue = LiveBuffer(lambda: self.now)

    def test_starts_at_idr_and_overflow_discards_complete_dependency_chain(self):
        self.queue.push(video(1))
        self.assertTrue(self.queue.take_keyframe_request())
        self.assertIsNone(self.queue.pop(0))
        for timestamp in range(2, 6):
            self.queue.push(video(timestamp, timestamp == 2))
        self.assertTrue(self.queue.take_keyframe_request())
        self.assertIsNone(self.queue.pop(0))
        self.queue.push(video(6))
        self.queue.push(video(7, True))
        self.assertEqual(self.queue.pop(0), video(7, True))
        self.assertEqual(self.queue.video_dropped, 6)

    def test_age_expiry_never_delivers_stale_video_or_audio(self):
        self.queue.push(video(1, True))
        self.queue.push(audio(1))
        self.now += .16
        self.assertIsNone(self.queue.pop(0))
        self.assertTrue(self.queue.take_keyframe_request())
        self.assertTrue(self.queue.waiting_idr)
        self.assertEqual(self.queue.audio_dropped, 1)

    def test_audio_keeps_latest_duration_without_breaking_video(self):
        self.queue.push(video(1, True))
        for timestamp in range(10):
            self.queue.push(audio(timestamp, 20))
        self.assertEqual(self.queue.pop(0), video(1, True))
        self.assertEqual([self.queue.pop(0).timestamp_us for _ in range(4)], [6, 7, 8, 9])
        self.assertIsNone(self.queue.pop(0))
        self.assertEqual(self.queue.audio_dropped, 6)


    def test_queue_observations_include_expired_records_before_pop(self):
        self.queue.push(video(1, True))
        self.queue.push(audio(1))
        self.now += .09
        self.assertEqual(self.queue.pop(0), video(1, True))
        metrics = self.queue.snapshot()
        self.assertAlmostEqual(metrics["video_queue_age_max_ms"], 90)
        self.assertAlmostEqual(metrics["video_pop_age_max_ms"], 90)
        self.assertAlmostEqual(metrics["audio_queue_age_max_ms"], 90)
        self.assertEqual(metrics["audio_pop_age_max_ms"], 0)
        self.assertEqual(metrics["audio_drop_age"], 1)
        self.assertEqual(metrics["audio_drop_capacity"], 0)
        self.queue.push(video(2, True))
        self.now += .16
        self.assertIsNone(self.queue.pop(0))
        self.assertEqual(self.queue.snapshot()["video_drop_age"], 1)

    def test_capacity_observations_preserve_gop_policy(self):
        for index in range(5):
            self.queue.push(audio(index, 20))
        metrics = self.queue.snapshot()
        self.assertEqual(metrics["audio_drop_capacity"], 1)
        self.assertEqual(metrics["audio_drop_age"], 0)
        for index in range(4):
            self.queue.push(video(index, index == 0))
        metrics = self.queue.snapshot()
        self.assertEqual(metrics["video_drop_capacity"], 3)
        self.assertEqual(metrics["video_drop_waiting_idr"], 1)
        self.assertTrue(self.queue.waiting_idr)


class FakePipe:
    def __init__(self):
        self.condition = threading.Condition()
        self.data = bytearray()
        self.closed = False

    def read(self, length):
        with self.condition:
            self.condition.wait_for(lambda: self.closed or self.data, timeout=2)
            chunk = bytes(self.data[:length])
            del self.data[:length]
            return chunk

    def put(self, data):
        with self.condition:
            self.data.extend(data)
            self.condition.notify_all()

    def close(self):
        with self.condition:
            self.closed = True
            self.condition.notify_all()


class FakeProcess:
    pid = 987654
    def __init__(self, *args, **kwargs):
        self.args = args
        self.stdout = FakePipe()
        self.signals = []
        self.terminated = False

    def send_signal(self, number):
        self.signals.append(number)

    def terminate(self):
        self.terminated = True
        self.stdout.close()

    def kill(self):
        self.terminate()

    def wait(self, timeout=None):
        return 0


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.owner = "a" * 32
        self.lease = "lease1"
        self.generation = object()
        self.now = 1.0
        self.released = []
        self.processes = []
        def make(*args, **kwargs):
            process = FakeProcess(*args, **kwargs)
            self.processes.append(process)
            return process
        self.service = NativeStreamService(window_id=123, capture_command=[sys.executable],
            owner_is_current=lambda controller, lease: controller == self.owner and lease == self.lease,
            owner_is_alive=lambda controller, generation: controller == self.owner and generation is self.generation,
            release_owner=lambda controller, generation: self.released.append((controller, generation)),
            clock=lambda: self.now, process_factory=make)
        self.addCleanup(self.service.close)

    def open(self):
        return self.service.open(controller=self.owner, lease=self.lease, owner_generation=self.generation)

    def test_inert_construction_bad_lease_and_explicit_capture_scope(self):
        self.assertEqual(self.processes, [])
        with self.assertRaises(NativeError):
            self.service.open(controller=self.owner, lease="bad", owner_generation=self.generation)
        peer = self.open()
        args = peer.process.args[0]
        self.assertIn("--window-id", args)
        self.assertEqual(args[args.index("--window-id") + 1], "123")
        self.assertIn("--audio", args)
        self.assertNotIn("--display-id", args)

    def test_native_high_profile_helper_and_phone_resolution(self):
        service = NativeStreamService(window_id=10618, width=2622, fps=60)
        self.addCleanup(service.close)
        self.assertEqual(service.command[0], str(DEFAULT_CAPTURE))
        self.assertIn("StreamCapture.app", DEFAULT_CAPTURE.parts)
        self.assertIn("2622", service.command)
        self.assertIn("--window-id", service.command)
        for width in (319, 3841):
            with self.assertRaises(ValueError): NativeStreamService(window_id=10618, width=width)
        maximum = NativeStreamService(window_id=10618, width=3840)
        self.addCleanup(maximum.close)
        packet = Record(b"GSV1", 1, 2622, 1262, video(1, True).payload, True)
        self.assertEqual(read_record(io.BytesIO(packet.wire())), packet)

    def test_bitrate_is_explicit_validated_and_reported(self):
        service = NativeStreamService(window_id=123, bitrate=40_000_000)
        self.addCleanup(service.close)
        self.assertEqual(service.command[service.command.index("--bitrate") + 1], "40000000")
        self.assertEqual(service.status()["bitrate"], 40_000_000)
        self.assertEqual(self.service.status()["bitrate"], 6_000_000)
        maximum = NativeStreamService(window_id=123, bitrate=160_000_000)
        self.addCleanup(maximum.close)
        self.assertEqual(maximum.command[maximum.command.index("--bitrate") + 1], "160000000")
        self.assertEqual(maximum.status()["bitrate"], 160_000_000)
        for bitrate in (249999, 160000001, True):
            with self.assertRaises(ValueError): NativeStreamService(window_id=123, bitrate=bitrate)

    def test_client_rect_is_explicit_metadata_and_validated(self):
        self.assertEqual(self.service.status()["client_rect_source"], "whole_window_unverified")
        self.assertEqual(self.service.status()["client_rect_normalized"],
                         dict(x=0, y=0, width=1, height=1))
        for rect in ((0, 0, 1.1, 1), (0, -.1, 1, 1), (0, 0, 0, 1),
                     (0, float("nan"), 1, 1), (0, .1, 1, .9000000005), (0, 0, 1)):
            with self.assertRaises(ValueError): NativeStreamService(window_id=123, client_rect=rect)
        service = NativeStreamService(window_id=123, client_rect=(0, 28 / 467, 1, 439 / 467))
        self.addCleanup(service.close)
        self.assertEqual(service.status()["client_rect_source"], "configured")
        self.assertAlmostEqual(service.status()["client_rect_normalized"]["y"], 28 / 467)
        changed = service.status()
        changed["client_rect_normalized"]["y"] = 0
        self.assertAlmostEqual(service.status()["client_rect_normalized"]["y"], 28 / 467)

    def test_old_disconnect_cannot_release_replacement(self):
        old = self.open()
        replacement = self.open()
        self.assertTrue(old.process.terminated)
        self.service.finish(old)
        self.assertEqual(self.released, [])
        self.assertFalse(replacement.stopped.is_set())
        self.service.finish(replacement)
        self.assertEqual(self.released, [(self.owner, self.generation)])
        self.assertTrue(replacement.process.terminated)
        self.assertFalse(self.service.status()["active"])

    def test_lease_rotation_preserves_stream_generation_change_stops(self):
        peer = self.open()
        self.lease = "lease2"
        self.service.tick()
        self.assertFalse(peer.stopped.is_set())
        self.generation = object()
        self.service.tick()
        self.assertTrue(peer.stopped.is_set())
        self.assertEqual(self.released, [])

    def test_reader_parses_and_requests_idr_and_releases_on_bad_record(self):
        peer = self.open()
        peer.process.stdout.put(video().wire())
        until = time.monotonic() + 1
        while not peer.process.signals and time.monotonic() < until:
            time.sleep(.002)
        self.assertEqual(peer.process.signals, [signal.SIGUSR1])
        peer.process.stdout.put(video(2, True).wire() + audio(1).wire())
        record = peer.buffer.pop(timeout=1)
        self.assertEqual(record, video(2, True))
        self.service.sent(peer, record)
        self.assertEqual(self.service.status()["state"], "streaming")
        peer.process.stdout.put(b"X" * 24)
        self.assertTrue(peer.stopped.wait(timeout=1))
        self.assertEqual(self.service.status()["last_error"], "capture_protocol_error")
        self.assertEqual(self.released, [(self.owner, self.generation)])

    def test_system_send_buffer_performs_no_set_and_retains_existing_bounds(self):
        peer = self.open()
        calls = []
        connection = types.SimpleNamespace(getsockopt=lambda *args: 131072,
            setsockopt=lambda *args: calls.append(args))
        self.service.send_buffer_mode = "system"
        self.service.configure_socket(peer, connection)
        metrics = self.service.status()["metrics"]
        self.assertEqual(calls, [])
        self.assertEqual(metrics["socket_send_buffer_initial_bytes"], 131072)
        self.assertEqual(metrics["socket_send_buffer_bytes"], 131072)
        peer.buffer.push(audio())
        self.now += .081
        self.assertIsNone(peer.buffer.pop(0))
        self.assertEqual(peer.buffer.audio_dropped, 1)
        with self.assertRaises(ValueError): NativeStreamService(window_id=123, send_buffer_mode="huge")

    def test_system_buffer_growth_is_observed_at_bounded_frequency(self):
        peer = self.open()
        self.service.send_buffer_mode = "system"
        actual = [131072]
        reads = []
        def get(*args):
            if args[1] != socket.SO_SNDBUF:
                raise OSError("unsupported test observation")
            reads.append(self.now)
            return actual[0]
        connection = types.SimpleNamespace(getsockopt=get,
            setsockopt=lambda *args: self.fail("system mode must not set buffer size"))
        self.service.configure_socket(peer, connection)
        self.assertEqual(len(reads), 2)
        self.service.write_record(peer, audio(), io.BytesIO())
        self.assertEqual(len(reads), 2)
        actual[0] = 262144
        self.now += 1.1
        self.service.write_record(peer, audio(2), io.BytesIO())
        metrics = self.service.status()["metrics"]
        self.assertEqual(len(reads), 3)
        self.assertEqual(metrics["socket_send_buffer_initial_bytes"], 131072)
        self.assertEqual(metrics["socket_send_buffer_bytes"], 262144)
        self.assertEqual(metrics["socket_send_buffer_bytes_max"], 262144)

    def test_baseline_sets_only_original_64k_and_reads_effective_value(self):
        peer = self.open()
        calls = []
        sizes = iter([131072, 65536])
        def get(*args):
            if args[1] != socket.SO_SNDBUF:
                raise OSError("unsupported test observation")
            return next(sizes)
        connection = types.SimpleNamespace(getsockopt=get, setsockopt=lambda *args: calls.append(args))
        self.service.configure_socket(peer, connection)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-1], 65536)
        self.assertEqual(self.service.status()["send_buffer_mode"], "64k")
        metrics = self.service.status()["metrics"]
        self.assertEqual(metrics["socket_send_buffer_initial_bytes"], 131072)
        self.assertEqual(metrics["socket_send_buffer_bytes"], 65536)

    def test_write_metrics_use_actual_write_time_and_complete_chunk_bytes(self):
        peer = self.open()
        output = io.BytesIO()
        def write(data):
            self.now += .125
            return output.write(data)
        self.service.observe_socket(peer, types.SimpleNamespace(getsockopt=lambda *args: 131072))
        record = video(1, True)
        self.service.write_record(peer, record, types.SimpleNamespace(write=write))
        wire = record.wire()
        expected = f"{len(wire):x}\r\n".encode() + wire + b"\r\n"
        self.assertEqual(output.getvalue(), expected)
        metrics = self.service.status()["metrics"]
        self.assertEqual(metrics["socket_send_buffer_bytes"], 131072)
        self.assertFalse(metrics["socket_send_buffer_read_failed"])
        self.assertEqual(metrics["send_calls"], 1)
        self.assertEqual(metrics["send_duration_ms_total"], 125)
        self.assertEqual(metrics["send_duration_ms_max"], 125)
        self.assertEqual(metrics["video_send_duration_ms_total"], 125)
        self.assertEqual(metrics["audio_send_duration_ms_total"], 0)
        self.assertEqual(metrics["payload_bytes_sent"], len(record.payload))
        self.assertEqual(metrics["http_chunk_bytes_sent"], len(expected))
        self.assertEqual(metrics["http_send_bytes_per_second"], len(expected) / .125)
        self.assertEqual(self.service.status()["frames_sent"], 1)

    def test_failed_write_is_observed_without_claiming_partial_bytes_delivered(self):
        peer = self.open()
        def fail(data):
            self.now += .25
            raise BrokenPipeError()
        with self.assertRaises(BrokenPipeError):
            self.service.write_record(peer, audio(), types.SimpleNamespace(write=fail))
        metrics = self.service.status()["metrics"]
        self.assertEqual(metrics["send_calls"], 1)
        self.assertEqual(metrics["send_failures"], 1)
        self.assertEqual(metrics["audio_send_duration_ms_max"], 250)
        self.assertEqual(metrics["payload_bytes_sent"], 0)
        self.assertEqual(metrics["http_chunk_bytes_sent"], 0)
        self.assertEqual(self.service.status()["audio_packets_sent"], 0)
        self.service.finish(peer)
        self.now += 1
        self.assertEqual(self.service.status()["metrics"]["stream_elapsed_seconds"], .25)

    def test_old_peer_metrics_never_pollute_replacement(self):
        old = self.open()
        replacement = self.open()
        self.service.write_record(old, audio(), io.BytesIO())
        self.assertEqual(old.metrics["send_calls"], 1)
        self.assertEqual(self.service.status()["metrics"]["send_calls"], 0)
        self.assertEqual(replacement.metrics["send_calls"], 0)

    def test_stalled_capture_times_out_and_releases(self):
        peer = self.open()
        self.now += 11
        self.service.tick()
        self.assertTrue(peer.stopped.is_set())
        self.assertEqual(self.service.status()["last_error"], "capture_timeout")
        self.assertEqual(len(self.released), 1)


if __name__ == "__main__":
    unittest.main()
