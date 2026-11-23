"""Synthetic kernel-ABI responses only; does not construct sockets."""
import errno
import json
from pathlib import Path
import socket
import types
import unittest

from tcp_diagnostics import (SO_NWRITE, TCP_CONNECTION_INFO, TCP_INFO,
                             parse_tcp_info, read_tcp_snapshot)


def fixture():
    return TCP_INFO.pack(4, 8, 9, 0,
        1, 2, 300, 1448, 20000, 80000, 90000, 123456, 100000, 12, 15, 4, 0,
        2 ** 40 + 11, 2 ** 41 + 22, 333, 444, 555, 666, 7)


class TCPDiagnosticsTests(unittest.TestCase):
    def test_layout_matches_c_compiled_sdk_abi_and_unsigned_counters(self):
        abi = json.loads(Path(__file__).with_name("tcp-abi.json").read_text())
        self.assertEqual((TCP_INFO.size, TCP_CONNECTION_INFO, SO_NWRITE),
                         (abi["size"], abi["TCP_CONNECTION_INFO"], abi["SO_NWRITE"]))
        self.assertEqual(abi["tcpi_txpackets"], 56)
        self.assertEqual(abi["tcpi_txretransmitpackets"], 104)
        result = parse_tcp_info(fixture())
        self.assertEqual(result["tcp_state"], 4)
        self.assertEqual(result["tcp_rtt_current_ms"], 12)
        self.assertEqual(result["tcp_rtt_smoothed_ms"], 15)
        self.assertEqual(result["tcp_send_buffer_used_bytes"], 123456)
        self.assertEqual(result["tcp_send_congestion_window_bytes"], 80000)
        self.assertEqual(result["tcp_tx_packets"], 2 ** 40 + 11)
        self.assertEqual(result["tcp_tx_bytes"], 2 ** 41 + 22)
        self.assertEqual(result["tcp_tx_retransmit_bytes"], 333)
        self.assertEqual(result["tcp_tx_retransmit_packets"], 7)
        self.assertEqual(result["tcp_rx_out_of_order_bytes"], 666)

    def test_older_prefix_and_invalid_payload_are_explicit(self):
        self.assertIsNone(parse_tcp_info(fixture()[:104])["tcp_tx_retransmit_packets"])
        for value in (b"" * 112, b"x" * 103, 112, None):
            with self.assertRaises(ValueError): parse_tcp_info(value)

    def test_snapshot_reads_only_the_given_socket(self):
        calls = []
        def get(level, option, *length):
            calls.append((level, option, length))
            return fixture() if option == TCP_CONNECTION_INFO else 65432
        result = read_tcp_snapshot(types.SimpleNamespace(getsockopt=get), platform="darwin")
        self.assertTrue(result["tcp_info_available"])
        self.assertTrue(result["socket_pending_bytes_available"])
        self.assertEqual(result["socket_pending_bytes"], 65432)
        self.assertEqual(calls, [(socket.IPPROTO_TCP, TCP_CONNECTION_INFO, (112,)),
                                 (socket.SOL_SOCKET, SO_NWRITE, ())])

    def test_unsupported_socket_or_platform_is_nonfatal(self):
        def fail(*args):
            raise OSError(errno.ENOPROTOOPT, "unsupported")
        connection = types.SimpleNamespace(getsockopt=fail)
        result = read_tcp_snapshot(connection, platform="darwin")
        self.assertFalse(result["tcp_info_available"])
        self.assertEqual(result["tcp_info_error_errno"], errno.ENOPROTOOPT)
        self.assertEqual(result["socket_pending_error_errno"], errno.ENOPROTOOPT)
        calls = []
        result = read_tcp_snapshot(types.SimpleNamespace(getsockopt=lambda *args: calls.append(args)), platform="linux")
        self.assertFalse(result["tcp_info_available"])
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
