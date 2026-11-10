#!/usr/bin/env python3
"""Issue one read-only DHMS client-size query over AF_QIPCRTR."""

import argparse
import socket
import struct
import sys


MEM_QUERY_SIZE = 0x0024
TRANSACTION = 0x4401


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
        result[tlv_type] = payload[offset : offset + tlv_len]
        offset += tlv_len
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    family = getattr(socket, "AF_QIPCRTR", None)
    if family is None:
        raise RuntimeError("Python has no AF_QIPCRTR support")

    client_id = 1
    proc_id = 0
    payload = (
        struct.pack("<BHI", 0x01, 4, client_id)
        + struct.pack("<BHI", 0x10, 4, proc_id)
    )
    request = struct.pack(
        "<BHHH", 0x00, TRANSACTION, MEM_QUERY_SIZE, len(payload)
    ) + payload

    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(args.timeout)
        sock.sendto(request, (args.node, args.port))
        while True:
            data, address = sock.recvfrom(4096)
            if len(data) < 7:
                continue
            flags, transaction, message_id, payload_len = struct.unpack_from(
                "<BHHH", data, 0
            )
            if transaction != TRANSACTION or message_id != MEM_QUERY_SIZE:
                continue
            if flags != 0x02:
                raise ValueError(f"unexpected response flags 0x{flags:02x}")
            if payload_len != len(data) - 7:
                raise ValueError("QMI payload length mismatch")
            tlvs = parse_tlvs(data[7:])
            break

    result_tlv = tlvs.get(0x02)
    size_tlv = tlvs.get(0x10)
    if result_tlv is None or len(result_tlv) != 4:
        raise ValueError("missing QMI result TLV")
    result, error = struct.unpack("<HH", result_tlv)
    size = (
        struct.unpack("<I", size_tlv)[0]
        if size_tlv is not None and len(size_tlv) == 4
        else None
    )
    print(f"response_node={address[0]} response_port={address[1]}")
    print(f"result={result} error={error} client_id={client_id} proc_id={proc_id}")
    print(f"size={size if size is not None else 'absent'}")
    return 0 if result == 0 and error == 0 and size == 5 * 1024 * 1024 else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"probe_error={type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
