"""Read-only Darwin socket counters, checked against macOS SDK27.2 tcp.h/socket.h.

No socket construction, options mutation, endpoint/address lookup or globals.
SO_NWRITE and tcpi_snd_sbbytes include in-flight data; neither is unsent-only.
"""
import socket
import struct
import sys

TCP_CONNECTION_INFO = getattr(socket, "TCP_CONNECTION_INFO", 0x106)
SO_NWRITE = 0x1024
# Four u8 fields, thirteen u32 words (last is TFO bitfield storage), then seven
# aligned u64 counters. The first u64 starts at56; SDK sizeof is112 on arm64.
TCP_INFO = struct.Struct("=4B13I7Q")
TCP_INFO_PREFIX = struct.Struct("=4B13I6Q")


def parse_tcp_info(data):
    if not isinstance(data, bytes) or len(data) < TCP_INFO_PREFIX.size:
        raise ValueError("short_tcp_connection_info")
    values = TCP_INFO_PREFIX.unpack_from(data)
    return {
        "tcp_state": values[0],
        "tcp_retransmit_timeout_ms": values[6],
        "tcp_max_segment_bytes": values[7],
        "tcp_send_congestion_window_bytes": values[9],
        "tcp_send_window_bytes": values[10],
        "tcp_send_buffer_used_bytes": values[11],
        "tcp_rtt_current_ms": values[13],
        "tcp_rtt_smoothed_ms": values[14],
        "tcp_rtt_variance": values[15],
        "tcp_tx_packets": values[17],
        "tcp_tx_bytes": values[18],
        "tcp_tx_retransmit_bytes": values[19],
        "tcp_rx_packets": values[20],
        "tcp_rx_bytes": values[21],
        "tcp_rx_out_of_order_bytes": values[22],
        "tcp_tx_retransmit_packets": struct.unpack_from("=Q", data, 104)[0] if len(data) >= TCP_INFO.size else None,
    }


def read_tcp_snapshot(connection, platform=sys.platform):
    result = {"tcp_info_available": False, "tcp_info_error_errno": None,
              "socket_pending_bytes_available": False, "socket_pending_error_errno": None,
              "socket_pending_bytes": None}
    if platform != "darwin":
        return result
    try:
        data = connection.getsockopt(socket.IPPROTO_TCP, TCP_CONNECTION_INFO, TCP_INFO.size)
        result.update(parse_tcp_info(data))
        result["tcp_info_available"] = True
    except OSError as error:
        result["tcp_info_error_errno"] = error.errno
    except (ValueError, TypeError, struct.error):
        pass
    try:
        pending = connection.getsockopt(socket.SOL_SOCKET, SO_NWRITE)
        if type(pending) is int and pending >= 0:
            result["socket_pending_bytes"] = pending
            result["socket_pending_bytes_available"] = True
    except OSError as error:
        result["socket_pending_error_errno"] = error.errno
    return result
