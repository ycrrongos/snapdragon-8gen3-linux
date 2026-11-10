#!/usr/bin/env python3
"""Bounded, side-effect-free QMI SSREQ service logger over AF_QIPCRTR.

The matching Cerro AOSP pm-service advertises QMI service 53, version 1,
instance 16.  Its requests 0x20, 0x21 and 0x22 ask for system restart,
system shutdown and peripheral restart respectively.  This diagnostic server
never performs or acknowledges those actions: it logs the request and returns
QMI_ERR_NOT_SUPPORTED.
"""

import argparse
import socket
import struct
import sys
import time


QRTR_PORT_CTRL = 0xFFFFFFFE
QRTR_TYPE_NEW_SERVER = 4
QRTR_TYPE_DEL_SERVER = 5
QRTR_TYPE_DEL_CLIENT = 6

SSREQ_SERVICE = 53
SSREQ_VERSION = 1
SSREQ_INSTANCE = 16
SSREQ_WIRE_INSTANCE = SSREQ_VERSION | (SSREQ_INSTANCE << 8)
SSREQ_MESSAGES = {
    0x20: "system-restart",
    0x21: "system-shutdown",
    0x22: "peripheral-restart",
}

QMI_REQUEST = 0x00
QMI_RESPONSE = 0x02
QMI_RESULT_FAILURE = 1
QMI_ERR_NOT_SUPPORTED = 94


def control_packet(command, node=0, port=0):
    return struct.pack(
        "<IIIII",
        command,
        SSREQ_SERVICE,
        SSREQ_WIRE_INSTANCE,
        node,
        port,
    )


def parse_tlvs(payload):
    result = {}
    offset = 0
    while offset < len(payload):
        if len(payload) - offset < 3:
            raise ValueError("truncated TLV header")
        tlv_type, tlv_len = struct.unpack_from("<BH", payload, offset)
        offset += 3
        if len(payload) - offset < tlv_len:
            raise ValueError("truncated TLV value")
        if tlv_type in result:
            raise ValueError(f"duplicate TLV 0x{tlv_type:02x}")
        result[tlv_type] = payload[offset : offset + tlv_len]
        offset += tlv_len
    return result


def failure_response(transaction, message_id):
    payload = struct.pack(
        "<BHHH", 0x02, 4, QMI_RESULT_FAILURE, QMI_ERR_NOT_SUPPORTED
    )
    return struct.pack(
        "<BHHH", QMI_RESPONSE, transaction, message_id, len(payload)
    ) + payload


def self_test():
    assert SSREQ_WIRE_INSTANCE == 0x1001
    assert control_packet(QRTR_TYPE_NEW_SERVER) == struct.pack(
        "<IIIII", 4, 53, 0x1001, 0, 0
    )
    request_payload = struct.pack("<BHI", 1, 4, 4)
    assert struct.unpack("<I", parse_tlvs(request_payload)[1])[0] == 4
    expected = struct.pack(
        "<BHHHBHHH", 2, 0x1234, 0x20, 7, 2, 4, 1, 94
    )
    assert failure_response(0x1234, 0x20) == expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, default=1, help="local QRTR node")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    self_test()
    if args.self_test:
        print("self_test=pass")
        return 0
    if args.timeout <= 0 or args.timeout > 60:
        raise ValueError("timeout must be in (0, 60]")

    family = getattr(socket, "AF_QIPCRTR", None)
    if family is None:
        raise RuntimeError("Python has no AF_QIPCRTR support")

    request_count = 0
    deadline = time.monotonic() + args.timeout
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(min(1.0, args.timeout))
        sock.sendto(
            control_packet(QRTR_TYPE_NEW_SERVER),
            (args.node, QRTR_PORT_CTRL),
        )
        local_node, local_port = sock.getsockname()
        print(
            "server=announced "
            f"service={SSREQ_SERVICE} version={SSREQ_VERSION} "
            f"instance={SSREQ_INSTANCE} node={local_node} port={local_port}",
            flush=True,
        )
        try:
            while time.monotonic() < deadline:
                sock.settimeout(min(1.0, max(0.001, deadline - time.monotonic())))
                try:
                    data, address = sock.recvfrom(4096)
                except TimeoutError:
                    continue

                if len(data) == 20:
                    command = struct.unpack_from("<I", data)[0]
                    if command == QRTR_TYPE_DEL_CLIENT:
                        node, port = struct.unpack_from("<II", data, 4)
                        print(
                            f"control=del-client node={node} port={port}",
                            flush=True,
                        )
                        continue

                if len(data) < 7:
                    print(
                        f"ignored=short source={address[0]}:{address[1]} "
                        f"bytes={len(data)}",
                        flush=True,
                    )
                    continue

                flags, transaction, message_id, payload_len = struct.unpack_from(
                    "<BHHH", data, 0
                )
                if flags != QMI_REQUEST or payload_len != len(data) - 7:
                    print(
                        f"ignored=non-request source={address[0]}:{address[1]} "
                        f"flags=0x{flags:02x} id=0x{message_id:04x} "
                        f"declared={payload_len} actual={len(data) - 7}",
                        flush=True,
                    )
                    continue

                name = SSREQ_MESSAGES.get(message_id, "unsupported")
                ssid = None
                parse_error = None
                try:
                    tlvs = parse_tlvs(data[7:])
                    value = tlvs.get(0x01)
                    if value is None or len(value) != 4:
                        raise ValueError("missing 4-byte SSID TLV 0x01")
                    ssid = struct.unpack("<I", value)[0]
                except ValueError as exc:
                    parse_error = str(exc)

                request_count += 1
                print(
                    f"request={request_count} source={address[0]}:{address[1]} "
                    f"transaction=0x{transaction:04x} id=0x{message_id:04x} "
                    f"name={name} ssid={ssid if ssid is not None else 'invalid'} "
                    f"parse_error={parse_error if parse_error else 'none'}",
                    flush=True,
                )
                sock.sendto(failure_response(transaction, message_id), address)
                print(
                    f"response=failure-not-supported transaction=0x{transaction:04x} "
                    f"id=0x{message_id:04x}",
                    flush=True,
                )
        finally:
            sock.sendto(
                control_packet(
                    QRTR_TYPE_DEL_SERVER,
                    node=local_node,
                    port=local_port,
                ),
                (args.node, QRTR_PORT_CTRL),
            )
            print(f"server=withdrawn requests={request_count}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"server_error={type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
